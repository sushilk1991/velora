import Combine
import Foundation

extension Notification.Name {
    static let veloraDictionaryDidChange = Notification.Name("VeloraDictionaryDidChange")
}

enum DictionarySource: String, Codable, CaseIterable {
    case added = "Added"
    case learned = "Learned"
    case automatic = "Auto"
}

struct DictionaryRow: Identifiable, Equatable {
    let id: String
    let writeAs: String
    let heardAs: String?
    let source: DictionarySource
    let isSoftCorrection: Bool
}

enum DictionaryRepositoryError: Error, LocalizedError {
    case missingEntry
    case notManual
    case duplicateEntry(String)
    case conflictingRule(heardAs: String, existingWriteAs: String)
    case couldNotPersist
    case couldNotProject

    var errorDescription: String? {
        switch self {
        case .missingEntry: return "That dictionary entry no longer exists."
        case .notManual: return "Learned entries must be forgotten rather than edited."
        case .duplicateEntry(let writeAs):
            return "“\(writeAs)” is already in your Personal Dictionary."
        case .conflictingRule(let heardAs, let existingWriteAs):
            return "When Velora hears “\(heardAs)”, it already writes “\(existingWriteAs)”. Edit that entry instead."
        case .couldNotPersist: return "Velora could not save the dictionary on this Mac."
        case .couldNotProject: return "Velora saved the dictionary but could not update the speech engine."
        }
    }
}

struct DictionaryImportResult: Equatable {
    let added: Int
    let keptExisting: Int
}

/// Canonical local owner for all portable dictionary state. Engine files are
/// projections: the cloud coordinator and Settings mutate this repository,
/// then the repository persists first, projects second, and requests a reload.
final class DictionaryRepository: ObservableObject {
    @Published private(set) var rows: [DictionaryRow] = []
    @Published private(set) var lastError: String?

    private(set) var document: DictionaryDocument
    private let stateURL: URL
    private let configURL: URL
    private let learning: LearningStore
    private let autoVocab: AutoVocabStore
    private let deviceID: String
    private let now: () -> Date
    private let reload: () -> Void
    private var projectionIsCurrent = false

    static var defaultStateURL: URL {
        AppConfig.veloraDirectory.appendingPathComponent("dictionary_sync.json")
    }

    init(
        stateURL: URL = DictionaryRepository.defaultStateURL,
        configURL: URL = AppConfig.configFileURL,
        learnedURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".velora/learned.json"),
        autoURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".velora/auto_learned.json"),
        deviceID: String = DictionaryRepository.persistedDeviceID(),
        now: @escaping () -> Date = Date.init,
        reload: @escaping () -> Void = {}
    ) {
        self.stateURL = stateURL
        self.configURL = configURL
        learning = LearningStore(url: learnedURL)
        autoVocab = AutoVocabStore(url: autoURL)
        self.deviceID = deviceID
        self.now = now
        self.reload = reload

        if let data = try? Data(contentsOf: stateURL),
           let decoded = try? DictionaryDocument.decode(data) {
            document = decoded
        } else {
            document = Self.migrate(
                configURL: configURL,
                learning: learning,
                autoVocab: autoVocab,
                deviceID: deviceID,
                at: now())
        }
        if !persist(document) {
            lastError = DictionaryRepositoryError.couldNotPersist.localizedDescription
        }
        projectionIsCurrent = project(document)
        if !projectionIsCurrent {
            lastError = DictionaryRepositoryError.couldNotProject.localizedDescription
        }
        refreshRows()
    }

    @discardableResult
    func add(writeAs: String, heardAs: String? = nil) throws -> DictionaryRow {
        let date = now()
        let desired = try DictionaryEntry.manual(
            writeAs: writeAs,
            heardAs: normalizedOptional(heardAs),
            deviceID: deviceID,
            at: date,
            generation: document.generation(for: .manual))
        let entry: DictionaryEntry
        if let existing = document.entry(id: desired.logicalKey) {
            if isActive(existing) { throw collisionError(existing: existing, desired: desired) }
            entry = try existing.readding(
                writeAs: desired.writeAs, deviceID: deviceID, at: date)
                .withGeneration(document.generation(for: .manual))
        } else {
            entry = desired
        }
        try commit(document.upserting(entry))
        return row(for: entry)
    }

    func update(id: String, writeAs: String, heardAs: String? = nil) throws {
        guard let existing = document.entry(id: id), !existing.deleted else {
            throw DictionaryRepositoryError.missingEntry
        }
        guard existing.namespace == .manual else { throw DictionaryRepositoryError.notManual }
        let date = now()
        let desired = try DictionaryEntry.manual(
            writeAs: writeAs,
            heardAs: normalizedOptional(heardAs),
            deviceID: deviceID,
            at: date,
            generation: document.generation(for: .manual))
        var next = document
        if desired.logicalKey == existing.logicalKey {
            next = next.upserting(try existing.revising(
                writeAs: desired.writeAs, deviceID: deviceID, at: date))
        } else {
            next = next.upserting(existing.deleting(deviceID: deviceID, at: date))
            if let collision = next.entry(id: desired.logicalKey) {
                if isActive(collision) {
                    throw collisionError(existing: collision, desired: desired)
                }
                let replacement = try collision.readding(
                    writeAs: desired.writeAs, deviceID: deviceID, at: date)
                    .withGeneration(next.generation(for: .manual))
                next = next.upserting(replacement)
            } else {
                next = next.upserting(desired)
            }
        }
        try commit(next)
    }

    /// Converts a learned correction into an explicit user-owned rule in one
    /// transaction, so failure cannot leave both or neither entry active.
    func promoteLearned(
        id: String,
        writeAs: String,
        heardAs: String
    ) throws {
        guard let existing = document.entry(id: id), isActive(existing) else {
            throw DictionaryRepositoryError.missingEntry
        }
        guard existing.namespace == .learned else { throw DictionaryRepositoryError.notManual }
        let date = now()
        let desired = try DictionaryEntry.manual(
            writeAs: writeAs,
            heardAs: heardAs,
            deviceID: deviceID,
            at: date,
            generation: document.generation(for: .manual))
        var next = document
        if let collision = document.entry(id: desired.logicalKey) {
            if isActive(collision) {
                throw collisionError(existing: collision, desired: desired)
            }
            next = next.upserting(try collision.readding(
                writeAs: desired.writeAs, deviceID: deviceID, at: date)
                .withGeneration(next.generation(for: .manual)))
        } else {
            next = next.upserting(desired)
        }
        next = next.upserting(existing.deleting(deviceID: deviceID, at: date))
        try commit(next)
    }

    func remove(id: String) throws {
        guard let existing = document.entry(id: id), isActive(existing) else {
            throw DictionaryRepositoryError.missingEntry
        }
        var next = document.upserting(existing.deleting(deviceID: deviceID, at: now()))
        // A removed auto term becomes an explicit ban so the device-local miner
        // cannot immediately nominate it again.
        if existing.kind == .autoTerm,
           let ban = try? DictionaryEntry.automatic(
               term: existing.writeAs,
               banned: true,
               deviceID: deviceID,
               at: now(),
               generation: next.generation(for: .auto)) {
            next = next.upserting(ban)
        }
        try commit(next)
    }

    func clear(_ namespace: DictionaryNamespace) throws {
        var next = document
        let activeAutoTerms = namespace == .auto
            ? document.activeEntries.filter { $0.kind == .autoTerm }
            : []
        next = next.clearing(namespace, deviceID: deviceID, at: now())
        if namespace == .auto {
            for term in activeAutoTerms {
                if let ban = try? DictionaryEntry.automatic(
                    term: term.writeAs,
                    banned: true,
                    deviceID: deviceID,
                    at: now(),
                    generation: next.generation(for: .auto)) {
                    next = next.upserting(ban)
                }
            }
        }
        try commit(next)
    }

    /// Pull newly committed edit-learning into canonical state. This is called
    /// after DictationController observes an edit and again at launch.
    @discardableResult
    func observeCorrections(
        _ corrections: [(wrong: String, right: String)]
    ) -> [(wrong: String, right: String)] {
        let committed = learning.observe(corrections)
        if !committed.isEmpty { captureLearning() }
        return committed
    }

    func captureLearning() {
        let snapshot = learning.portableSnapshot()
        var next = document
        let date = now()
        for (wrong, right) in snapshot.replacements {
            if let entry = try? DictionaryEntry.learned(
                wrong: wrong, right: right, soft: false,
                deviceID: deviceID, at: date,
                generation: next.generation(for: .learned)) {
                next = upsertingCaptured(entry, into: next, at: date)
            }
        }
        for (wrong, right) in snapshot.softReplacements {
            if let entry = try? DictionaryEntry.learned(
                wrong: wrong, right: right, soft: true,
                deviceID: deviceID, at: date,
                generation: next.generation(for: .learned)) {
                next = upsertingCaptured(entry, into: next, at: date)
            }
        }
        for term in snapshot.standaloneVocabulary {
            if let entry = try? DictionaryEntry.manual(
                writeAs: term, deviceID: deviceID, at: date,
                generation: next.generation(for: .manual)) {
                next = upsertingCaptured(entry, into: next, at: date)
            }
        }
        guard next != document else { return }
        do { try commit(next) } catch { lastError = error.localizedDescription }
    }

    /// Pull confirmed miner terms/bans into canonical state without copying its
    /// candidates or history checkpoint.
    func captureAutoVocabulary() {
        let snapshot = autoVocab.portableSnapshot()
        var next = document
        let date = now()
        for term in snapshot.terms {
            if let entry = try? DictionaryEntry.automatic(
                term: term, banned: false, deviceID: deviceID, at: date,
                generation: next.generation(for: .auto)) {
                next = upsertingCaptured(entry, into: next, at: date)
            }
        }
        for term in snapshot.banned {
            if let entry = try? DictionaryEntry.automatic(
                term: term, banned: true, deviceID: deviceID, at: date,
                generation: next.generation(for: .auto)) {
                next = upsertingCaptured(entry, into: next, at: date)
            }
        }
        guard next != document else { return }
        do { try commit(next) } catch { lastError = error.localizedDescription }
    }

    func snapshot() -> DictionaryDocument { document }

    /// Explicit account-boundary action: unlike normal remote sync/import,
    /// this replaces local portable state instead of merging it.
    func replace(with replacement: DictionaryDocument) throws {
        try commit(replacement, preservingDeviceLearning: false)
    }

    /// A user export is a portable snapshot, not synchronization history.
    /// Tombstones and clear generations stay in the private sync document so a
    /// deleted name cannot leak into a file the user intentionally shares.
    func exportData() throws -> Data {
        try DictionaryDocument(entries: document.activeEntries).encoded()
    }

    /// iCloud reconciliation needs tombstones and clear generations to prevent
    /// deleted entries from returning on another Mac.
    func syncData() throws -> Data { try document.encoded() }

    /// An Apple Account decision moves only confirmed canonical entries. Local
    /// pending corrections and miner candidates must not cross the boundary.
    func resetDeviceLearningState() throws {
        projectionIsCurrent = false
        guard project(document, preservingDeviceLearning: false) else {
            lastError = DictionaryRepositoryError.couldNotProject.localizedDescription
            throw DictionaryRepositoryError.couldNotProject
        }
        projectionIsCurrent = true
        lastError = nil
        reload()
    }

    /// Explicit file import is additive. Unlike cloud reconciliation, imported
    /// clear generations and tombstones never delete local entries; the user is
    /// choosing terms to add, not replacing this Mac's synchronization history.
    @discardableResult
    func importData(_ data: Data) throws -> DictionaryImportResult {
        let incoming = try decodeImport(data)
        var next = document
        var added = 0
        var keptExisting = 0
        let date = now()
        for entry in incoming.activeEntries {
            if next.activeEntries.contains(where: { $0.logicalKey == entry.logicalKey }) {
                keptExisting += 1
                continue
            }
            let imported: DictionaryEntry
            if let inactive = next.entry(id: entry.logicalKey) {
                imported = try inactive.readding(
                    writeAs: entry.writeAs, deviceID: deviceID, at: date)
                    .withGeneration(next.generation(for: entry.namespace))
            } else {
                imported = entry.withGeneration(next.generation(for: entry.namespace))
            }
            next = next.upserting(imported)
            added += 1
        }
        if next != document { try commit(next) }
        return DictionaryImportResult(added: added, keptExisting: keptExisting)
    }

    /// Decode completely before touching local state. Corrupt/newer cloud data
    /// cannot replace the last valid local document.
    @discardableResult
    func applyRemote(_ data: Data) -> Bool {
        do {
            let incoming = try DictionaryDocument.decode(data)
            try mergeRemote(incoming)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func applyRemote(_ incoming: DictionaryDocument) -> Bool {
        do {
            try mergeRemote(incoming)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Throwing form used by iCloud sync so transport/decode failures are not
    /// conflated with a valid document that could not be persisted or
    /// projected into the live speech engine.
    func mergeRemote(_ incoming: DictionaryDocument) throws {
        let merged = document.merged(with: incoming)
        if merged != document {
            try commit(merged)
        } else {
            try ensureProjectionCurrent()
        }
    }

    func ensureProjectionCurrent() throws {
        guard !projectionIsCurrent else { return }
        guard project(document) else {
            lastError = DictionaryRepositoryError.couldNotProject.localizedDescription
            throw DictionaryRepositoryError.couldNotProject
        }
        projectionIsCurrent = true
        lastError = nil
        reload()
    }

    private func isActive(_ entry: DictionaryEntry) -> Bool {
        document.isActive(entry)
    }

    private func collisionError(
        existing: DictionaryEntry,
        desired: DictionaryEntry
    ) -> DictionaryRepositoryError {
        if existing.writeAs.caseInsensitiveCompare(desired.writeAs) == .orderedSame {
            return .duplicateEntry(existing.writeAs)
        }
        return .conflictingRule(
            heardAs: desired.heardAs ?? desired.writeAs,
            existingWriteAs: existing.writeAs)
    }

    private func commit(
        _ next: DictionaryDocument,
        preservingDeviceLearning: Bool = true
    ) throws {
        guard persist(next) else { throw DictionaryRepositoryError.couldNotPersist }
        document = next
        refreshRows()
        projectionIsCurrent = false
        guard project(next, preservingDeviceLearning: preservingDeviceLearning) else {
            lastError = DictionaryRepositoryError.couldNotProject.localizedDescription
            NotificationCenter.default.post(name: .veloraDictionaryDidChange, object: self)
            throw DictionaryRepositoryError.couldNotProject
        }
        projectionIsCurrent = true
        lastError = nil
        reload()
        NotificationCenter.default.post(name: .veloraDictionaryDidChange, object: self)
    }

    private func persist(_ document: DictionaryDocument) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try document.encoded().write(to: stateURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
            return true
        } catch {
            NSLog("Velora: failed to persist personal dictionary: \(error)")
            return false
        }
    }

    private func project(
        _ document: DictionaryDocument,
        preservingDeviceLearning: Bool = true
    ) -> Bool {
        let active = document.activeEntries
        let manual = active.filter { $0.namespace == .manual }
        let manualVocabulary = Self.deduplicated(manual.map(\.writeAs))
        var manualReplacements: [String: String] = [:]
        for entry in manual where entry.kind == .manualReplacement {
            if let heard = entry.heardAs {
                manualReplacements[Self.normalized(heard)] = entry.writeAs
            }
        }
        guard AppConfig.applyManualDictionary(
            .init(vocabulary: manualVocabulary, replacements: manualReplacements),
            at: configURL) else { return false }

        var hard: [String: String] = [:]
        var soft: [String: String] = [:]
        for entry in active where entry.namespace == .learned {
            guard let heard = entry.heardAs else { continue }
            if entry.kind == .learnedSoft {
                soft[Self.normalized(heard)] = entry.writeAs
            } else {
                hard[Self.normalized(heard)] = entry.writeAs
            }
        }
        guard learning.applyPortableSnapshot(
            .init(
                replacements: hard,
                softReplacements: soft,
                standaloneVocabulary: []),
            preservingPendingCounts: preservingDeviceLearning)
        else { return false }

        let autoTerms = active.filter { $0.kind == .autoTerm }.map(\.writeAs)
        let autoBans = active.filter { $0.kind == .autoBan }.map(\.writeAs)
        guard autoVocab.applyPortableSnapshot(
            .init(terms: autoTerms, banned: autoBans),
            preservingDeviceState: preservingDeviceLearning)
        else { return false }
        return true
    }

    private func refreshRows() {
        let banned = Set(document.activeEntries.filter { $0.kind == .autoBan }.map {
            Self.normalized($0.writeAs)
        })
        rows = document.activeEntries.compactMap { entry in
            if entry.kind == .autoBan { return nil }
            if entry.kind == .autoTerm && banned.contains(Self.normalized(entry.writeAs)) {
                return nil
            }
            return row(for: entry)
        }.sorted {
            let comparison = $0.writeAs.localizedCaseInsensitiveCompare($1.writeAs)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    private func row(for entry: DictionaryEntry) -> DictionaryRow {
        let source: DictionarySource
        switch entry.namespace {
        case .manual: source = .added
        case .learned: source = .learned
        case .auto: source = .automatic
        }
        return DictionaryRow(
            id: entry.logicalKey,
            writeAs: entry.writeAs,
            heardAs: entry.heardAs,
            source: source,
            isSoftCorrection: entry.kind == .learnedSoft)
    }

    private func upsertingCaptured(
        _ captured: DictionaryEntry,
        into document: DictionaryDocument,
        at date: Date
    ) -> DictionaryDocument {
        guard let existing = document.entry(id: captured.logicalKey) else {
            return document.upserting(captured)
        }
        if isActive(existing) && existing.writeAs == captured.writeAs { return document }
        let next = existing.deleted
            ? try? existing.readding(writeAs: captured.writeAs, deviceID: deviceID, at: date)
            : try? existing.revising(writeAs: captured.writeAs, deviceID: deviceID, at: date)
        return next.map { document.upserting($0.withGeneration(captured.generation)) } ?? document
    }

    private func decodeImport(_ data: Data) throws -> DictionaryDocument {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           root["schema_version"] == nil {
            let legacy = try JSONDecoder().decode(LearningStore.PortableSnapshot.self, from: data)
            let date = now()
            var entries = legacy.replacements.compactMap { wrong, right in
                try? DictionaryEntry.learned(
                    wrong: wrong, right: right, soft: false,
                    deviceID: deviceID, at: date)
            }
            entries += legacy.softReplacements.compactMap { wrong, right in
                try? DictionaryEntry.learned(
                    wrong: wrong, right: right, soft: true,
                    deviceID: deviceID, at: date)
            }
            entries += legacy.standaloneVocabulary.compactMap { term in
                try? DictionaryEntry.manual(writeAs: term, deviceID: deviceID, at: date)
            }
            return DictionaryDocument(entries: entries)
        }
        return try DictionaryDocument.decode(data)
    }

    private static func migrate(
        configURL: URL,
        learning: LearningStore,
        autoVocab: AutoVocabStore,
        deviceID: String,
        at date: Date
    ) -> DictionaryDocument {
        var entries: [DictionaryEntry] = []
        let manual = AppConfig.manualDictionarySnapshot(at: configURL)
        entries += manual.vocabulary.compactMap {
            try? DictionaryEntry.manual(writeAs: $0, deviceID: deviceID, at: date)
        }
        entries += manual.replacements.compactMap { heard, written in
            try? DictionaryEntry.manual(
                writeAs: written, heardAs: heard, deviceID: deviceID, at: date)
        }
        let learned = learning.portableSnapshot()
        entries += learned.replacements.compactMap { wrong, right in
            try? DictionaryEntry.learned(
                wrong: wrong, right: right, soft: false, deviceID: deviceID, at: date)
        }
        entries += learned.softReplacements.compactMap { wrong, right in
            try? DictionaryEntry.learned(
                wrong: wrong, right: right, soft: true, deviceID: deviceID, at: date)
        }
        entries += learned.standaloneVocabulary.compactMap {
            try? DictionaryEntry.manual(writeAs: $0, deviceID: deviceID, at: date)
        }
        let auto = autoVocab.portableSnapshot()
        entries += auto.terms.compactMap {
            try? DictionaryEntry.automatic(
                term: $0, banned: false, deviceID: deviceID, at: date)
        }
        entries += auto.banned.compactMap {
            try? DictionaryEntry.automatic(
                term: $0, banned: true, deviceID: deviceID, at: date)
        }
        return DictionaryDocument(entries: entries)
    }

    private func normalizedOptional(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    private static func deduplicated(_ terms: [String]) -> [String] {
        var seen: Set<String> = []
        return terms.filter { seen.insert(normalized($0)).inserted }
    }

    private static func persistedDeviceID() -> String {
        let key = "velora.dictionary.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let identifier = UUID().uuidString.lowercased()
        UserDefaults.standard.set(identifier, forKey: key)
        return identifier
    }
}
