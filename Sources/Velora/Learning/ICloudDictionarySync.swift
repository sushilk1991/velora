import Combine
import Foundation

enum DictionarySyncTransportError: Error, Equatable {
    case unavailable
    case waitingForDownload
    case io(String)
}

/// An archived `FileManager.ubiquityIdentityToken`. Archive bytes are not an
/// account identifier: the same token can have different keyed-archive
/// representations. Account boundaries must compare the unarchived objects.
struct DictionaryAccountIdentity {
    let archivedToken: Data

    func matches(storedData: Data) -> Bool {
        guard let current = Self.unarchive(archivedToken) else { return false }

        if let stored = Self.unarchive(storedData), current.isEqual(stored) {
            return true
        }

        // Velora 0.4 stored the archive as base64 text. Accept it once so an
        // upgrade does not look like an Apple Account change; the next
        // successful sync rewrites the marker in the canonical binary form.
        guard
            let encoded = String(data: storedData, encoding: .utf8),
            let legacyArchive = Data(base64Encoded: encoded),
            let stored = Self.unarchive(legacyArchive)
        else { return false }
        return current.isEqual(stored)
    }

    static func fixture(
        _ value: String,
        format: PropertyListSerialization.PropertyListFormat = .binary
    ) -> DictionaryAccountIdentity {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.outputFormat = format
        archiver.encode(value as NSString, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        return DictionaryAccountIdentity(archivedToken: archiver.encodedData)
    }

    private static func unarchive(_ data: Data) -> NSObject? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        defer { unarchiver.finishDecoding() }
        return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSObject
    }
}

protocol DictionarySyncTransport: AnyObject {
    func fetchAccountIdentity(
        completion: @escaping (Result<DictionaryAccountIdentity, DictionarySyncTransportError>) -> Void)
    func readVersions(
        completion: @escaping (Result<[Data], DictionarySyncTransportError>) -> Void)
    func write(
        _ data: Data,
        resolvingConflicts: Bool,
        completion: @escaping (Result<Void, DictionarySyncTransportError>) -> Void)
    func startObserving(_ onChange: @escaping () -> Void)
    func stopObserving()
    var folderURL: URL? { get }
}

enum DictionarySyncStatus: Equatable {
    case idle
    case syncing
    case synced
    case localOnly
    case waitingForDownload
    case accountChanged
    case error(String)
}

enum DictionaryAccountDecision: Equatable {
    case keepLocal
    case useCloud
    case merge
}

/// Lifecycle-owned local-first reconciler. The transport performs every iCloud
/// filesystem operation off-main; callbacks return to the main queue before
/// touching the observable repository or status.
final class ICloudDictionarySync: ObservableObject {
    @Published private(set) var status: DictionarySyncStatus = .idle

    private enum ReconcileStrategy {
        case merge
        case useCloud
    }

    private let repository: DictionaryRepository
    private let transport: DictionarySyncTransport
    private let identityURL: URL
    private let debounceDelay: TimeInterval
    private let reconciliationQueue: DispatchQueue
    private var notificationToken: NSObjectProtocol?
    private var debounceWork: DispatchWorkItem?
    private var started = false
    private var inFlight = false
    private var syncAgain = false
    private var applyingRemote = false
    private var pendingIdentity: DictionaryAccountIdentity?

    init(
        repository: DictionaryRepository,
        transport: DictionarySyncTransport = ICloudDocumentsDictionaryTransport(),
        identityURL: URL = AppConfig.veloraDirectory
            .appendingPathComponent("dictionary_icloud_identity"),
        debounceDelay: TimeInterval = 0.5,
        reconciliationQueue: DispatchQueue = DispatchQueue(
            label: "com.velora.dictionary.reconcile", qos: .utility)
    ) {
        self.repository = repository
        self.transport = transport
        self.identityURL = identityURL
        self.debounceDelay = debounceDelay
        self.reconciliationQueue = reconciliationQueue
    }

    deinit { stop() }

    var folderURL: URL? { transport.folderURL }

    func start() {
        guard !started else { return }
        started = true
        notificationToken = NotificationCenter.default.addObserver(
            forName: .veloraDictionaryDidChange,
            object: repository,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.applyingRemote else { return }
            self.requestSync()
        }
        transport.startObserving { [weak self] in self?.requestSync() }
        syncNow()
    }

    func stop() {
        guard started else { return }
        started = false
        debounceWork?.cancel()
        debounceWork = nil
        if let notificationToken {
            NotificationCenter.default.removeObserver(notificationToken)
            self.notificationToken = nil
        }
        transport.stopObserving()
    }

    func requestSync() {
        guard started else { return }
        guard pendingIdentity == nil else {
            status = .accountChanged
            return
        }
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncNow() }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceDelay, execute: work)
    }

    func syncNow() {
        guard started else { return }
        guard pendingIdentity == nil else {
            status = .accountChanged
            return
        }
        if inFlight {
            syncAgain = true
            return
        }
        inFlight = true
        status = .syncing
        transport.fetchAccountIdentity { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.handle(error)
            case .success(let identity):
                let stored = self.storedIdentity()
                if let stored, !identity.matches(storedData: stored) {
                    self.pendingIdentity = identity
                    self.status = .accountChanged
                    self.finish(allowQueuedSync: false)
                    return
                }
                if stored == nil, !self.persistIdentity(identity) {
                    self.status = .error(
                        "Velora could not secure the iCloud account boundary. Sync is paused.")
                    self.finish(allowQueuedSync: false)
                    return
                }
                self.reconcile(identity: identity, strategy: .merge)
            }
        }
    }

    func resolveAccountChange(_ decision: DictionaryAccountDecision) {
        guard let identity = pendingIdentity else { return }
        debounceWork?.cancel()
        debounceWork = nil
        syncAgain = false
        inFlight = true
        status = .syncing
        do {
            try repository.resetDeviceLearningState()
        } catch {
            status = .error(
                "Velora could not clear pending learning from the previous Apple Account. Sync is paused.")
            finish(allowQueuedSync: false)
            return
        }
        switch decision {
        case .keepLocal:
            publishCurrent(identity: identity, resolvingConflicts: true)
        case .useCloud:
            reconcile(identity: identity, strategy: .useCloud)
        case .merge:
            reconcile(identity: identity, strategy: .merge)
        }
    }

    private func reconcile(identity: DictionaryAccountIdentity, strategy: ReconcileStrategy) {
        transport.readVersions { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.handle(error)
            case .success(let payloads):
                self.reconciliationQueue.async { [weak self] in
                    dispatchPrecondition(condition: .notOnQueue(.main))
                    guard let self else { return }
                    do {
                        let remote = try self.mergedRemote(payloads)
                        let canonical = try remote?.encoded()
                        DispatchQueue.main.async { [weak self] in
                            self?.applyReconciliation(
                                remote: remote,
                                remoteCanonical: canonical,
                                payloadCount: payloads.count,
                                identity: identity,
                                strategy: strategy)
                        }
                    } catch {
                        DispatchQueue.main.async { [weak self] in
                            self?.handleReconciliationFailure(error)
                        }
                    }
                }
            }
        }
    }

    private func applyReconciliation(
        remote: DictionaryDocument?,
        remoteCanonical: Data?,
        payloadCount: Int,
        identity: DictionaryAccountIdentity,
        strategy: ReconcileStrategy
    ) {
        guard started else { return }
        do {
            applyingRemote = true
            defer { applyingRemote = false }
            switch strategy {
            case .merge:
                if let remote {
                    try repository.mergeRemote(remote)
                }
            case .useCloud:
                try repository.replace(with: remote ?? DictionaryDocument())
            }
            try repository.ensureProjectionCurrent()
            let current = try repository.syncData()
            if payloadCount == 1 && remoteCanonical == current {
                completeWithoutWrite(identity: identity)
            } else {
                publishCurrent(
                    identity: identity,
                    resolvingConflicts: payloadCount > 1)
            }
        } catch {
            handleReconciliationFailure(error)
        }
    }

    private func handleReconciliationFailure(_ error: Error) {
        guard started else { return }
        NSLog("Velora: iCloud dictionary reconciliation failed: \(error)")
        switch error {
        case DictionaryRepositoryError.couldNotProject:
            status = .error(
                "The Personal Dictionary was saved on this Mac, but the speech engine could not be updated. Restart Velora and try again.")
        case DictionaryRepositoryError.couldNotPersist:
            status = .error(
                "Velora could not save the merged Personal Dictionary on this Mac. iCloud was left unchanged.")
        default:
            status = .error(
                "The iCloud dictionary is unreadable or from a newer Velora version. Your local dictionary was kept.")
        }
        finish()
    }

    private func mergedRemote(_ payloads: [Data]) throws -> DictionaryDocument? {
        var merged: DictionaryDocument?
        for payload in payloads {
            let document = try DictionaryDocument.decode(payload)
            merged = merged.map { $0.merged(with: document) } ?? document
        }
        return merged
    }

    private func publishCurrent(
        identity: DictionaryAccountIdentity,
        resolvingConflicts: Bool
    ) {
        do {
            let data = try repository.syncData()
            transport.write(data, resolvingConflicts: resolvingConflicts) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.completeWithoutWrite(identity: identity)
                case .failure(let error):
                    self.handle(error)
                }
            }
        } catch {
            status = .error("Velora could not prepare the personal dictionary for iCloud.")
            finish()
        }
    }

    private func completeWithoutWrite(identity: DictionaryAccountIdentity) {
        guard persistIdentity(identity) else {
            status = .error(
                "Velora synced the dictionary but could not secure the Apple Account boundary. Sync is paused.")
            finish(allowQueuedSync: false)
            return
        }
        pendingIdentity = nil
        status = .synced
        finish()
    }

    private func handle(_ error: DictionarySyncTransportError) {
        switch error {
        case .unavailable:
            status = .localOnly
        case .waitingForDownload:
            status = .waitingForDownload
        case .io(let detail):
            NSLog("Velora: iCloud dictionary transport failed: \(detail)")
            status = .error("iCloud Drive could not sync the dictionary. Try again.")
        }
        finish()
    }

    private func finish(allowQueuedSync: Bool = true) {
        inFlight = false
        if allowQueuedSync && syncAgain {
            syncAgain = false
            requestSync()
        } else if !allowQueuedSync {
            syncAgain = false
        }
    }

    private func storedIdentity() -> Data? {
        guard let data = try? Data(contentsOf: identityURL), !data.isEmpty else { return nil }
        return data
    }

    @discardableResult
    private func persistIdentity(_ identity: DictionaryAccountIdentity) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: identityURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try identity.archivedToken.write(to: identityURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: identityURL.path)
            return true
        } catch {
            NSLog("Velora: failed to persist iCloud identity boundary: \(error)")
            return false
        }
    }
}

/// Production iCloud Documents transport. Container lookup and coordinated
/// file reads/writes run on a dedicated utility queue; only completions and
/// metadata notifications return to the main queue.
final class ICloudDocumentsDictionaryTransport: NSObject, DictionarySyncTransport {
    static let containerIdentifier = "iCloud.com.velora.app"
    static let fileName = "Velora Dictionary.json"

    private let fileManager: FileManager
    private let containerURLProvider: () -> URL?
    private let identityTokenProvider: () -> Any?
    private let workQueue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let cacheLock = NSLock()
    private var cachedFolderURL: URL?
    private var metadataQuery: NSMetadataQuery?
    private var metadataObservers: [NSObjectProtocol] = []

    init(
        fileManager: FileManager = .default,
        containerURLProvider: @escaping () -> URL? = {
            FileManager.default.url(
                forUbiquityContainerIdentifier: ICloudDocumentsDictionaryTransport.containerIdentifier)
        },
        identityTokenProvider: @escaping () -> Any? = {
            FileManager.default.ubiquityIdentityToken
        },
        workQueue: DispatchQueue = DispatchQueue(
            label: "com.velora.dictionary.icloud", qos: .utility),
        callbackQueue: DispatchQueue = .main
    ) {
        self.fileManager = fileManager
        self.containerURLProvider = containerURLProvider
        self.identityTokenProvider = identityTokenProvider
        self.workQueue = workQueue
        self.callbackQueue = callbackQueue
    }

    var folderURL: URL? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedFolderURL
    }

    func fetchAccountIdentity(
        completion: @escaping (
            Result<DictionaryAccountIdentity, DictionarySyncTransportError>
        ) -> Void
    ) {
        workQueue.async { [weak self] in
            guard let self else { return }
            let result: Result<DictionaryAccountIdentity, DictionarySyncTransportError>
            do {
                guard let token = self.identityTokenProvider() else {
                    result = .failure(.unavailable)
                    self.complete(result, completion)
                    return
                }
                let data = try NSKeyedArchiver.archivedData(
                    withRootObject: token, requiringSecureCoding: false)
                result = .success(DictionaryAccountIdentity(archivedToken: data))
            } catch {
                result = .failure(.io("identity token: \(error.localizedDescription)"))
            }
            self.complete(result, completion)
        }
    }

    func readVersions(
        completion: @escaping (Result<[Data], DictionarySyncTransportError>) -> Void
    ) {
        workQueue.async { [weak self] in
            guard let self else { return }
            let result: Result<[Data], DictionarySyncTransportError>
            do {
                let documentURL = try self.resolveDocumentURL()
                guard self.fileManager.fileExists(atPath: documentURL.path) else {
                    result = .success([])
                    self.complete(result, completion)
                    return
                }
                let values = try documentURL.resourceValues(forKeys: [
                    .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
                ])
                if values.isUbiquitousItem == true,
                   values.ubiquitousItemDownloadingStatus != .current {
                    try? self.fileManager.startDownloadingUbiquitousItem(at: documentURL)
                    result = .failure(.waitingForDownload)
                    self.complete(result, completion)
                    return
                }
                var payloads = [try self.coordinatedRead(documentURL)]
                for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: documentURL) ?? [] {
                    payloads.append(try self.coordinatedRead(version.url))
                }
                result = .success(payloads)
            } catch let error as DictionarySyncTransportError {
                result = .failure(error)
            } catch {
                result = .failure(.io("read: \(error.localizedDescription)"))
            }
            self.complete(result, completion)
        }
    }

    func write(
        _ data: Data,
        resolvingConflicts: Bool,
        completion: @escaping (Result<Void, DictionarySyncTransportError>) -> Void
    ) {
        workQueue.async { [weak self] in
            guard let self else { return }
            let result: Result<Void, DictionarySyncTransportError>
            do {
                let documentURL = try self.resolveDocumentURL()
                try self.coordinatedWrite(data, to: documentURL)
                if resolvingConflicts {
                    for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: documentURL) ?? [] {
                        version.isResolved = true
                    }
                    try NSFileVersion.removeOtherVersionsOfItem(at: documentURL)
                }
                result = .success(())
            } catch let error as DictionarySyncTransportError {
                result = .failure(error)
            } catch {
                result = .failure(.io("write: \(error.localizedDescription)"))
            }
            self.complete(result, completion)
        }
    }

    func startObserving(_ onChange: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.metadataQuery == nil else { return }
            let query = NSMetadataQuery()
            query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
            query.predicate = NSPredicate(
                format: "%K == %@", NSMetadataItemFSNameKey, Self.fileName)
            let center = NotificationCenter.default
            for name in [
                NSNotification.Name.NSMetadataQueryDidFinishGathering,
                NSNotification.Name.NSMetadataQueryDidUpdate,
            ] {
                self.metadataObservers.append(center.addObserver(
                    forName: name, object: query, queue: .main
                ) { _ in onChange() })
            }
            self.metadataQuery = query
            query.start()
        }
    }

    func stopObserving() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.metadataQuery?.stop()
            self.metadataQuery = nil
            let center = NotificationCenter.default
            self.metadataObservers.forEach(center.removeObserver)
            self.metadataObservers = []
        }
    }

    private func resolveDocumentURL() throws -> URL {
        guard let container = containerURLProvider() else {
            throw DictionarySyncTransportError.unavailable
        }
        let folder = container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Personal Dictionary", isDirectory: true)
        try fileManager.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        cacheLock.lock()
        cachedFolderURL = folder
        cacheLock.unlock()
        return folder.appendingPathComponent(Self.fileName)
    }

    private func coordinatedRead(_ url: URL) throws -> Data {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) {
            coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw DictionarySyncTransportError.io("empty coordinated read") }
        return try result.get()
    }

    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: Error?
        let options: NSFileCoordinator.WritingOptions = fileManager.fileExists(atPath: url.path)
            ? .forReplacing : []
        coordinator.coordinate(writingItemAt: url, options: options, error: &coordinationError) {
            coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: .atomic)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: coordinatedURL.path)
            }
            catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    private func complete<T>(
        _ result: Result<T, DictionarySyncTransportError>,
        _ completion: @escaping (Result<T, DictionarySyncTransportError>) -> Void
    ) {
        callbackQueue.async { completion(result) }
    }
}
