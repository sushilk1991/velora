import Combine
import Foundation

// Full snapshots replace the list; only known schema/enums can enable recovery.
enum DownloadKind: String, Decodable { case stt, cleanup }
enum DownloadPhase: String, Decodable {
    case queued, downloading, verifying, loading, retry_wait, ready, failed
}
enum DownloadResume: String, Decodable {
    case none, partial, completed_files, file_restarted
}
enum DownloadAction: String { case retry = "retry_download", restart = "restart_download" }

struct DownloadError: Decodable, Equatable {
    let category: String
    let code: String
    let message: String
    let retryable: Bool
}

struct ModelDownload: Decodable, Equatable, Identifiable {
    let model: String
    let kind: DownloadKind
    let revision: String?
    let attempt: String
    let state: DownloadPhase
    let bytesReceived: Int64
    let bytesTotal: Int64?
    let retryIndex: Int
    let retryAt: Double?
    let error: DownloadError?
    let resume: DownloadResume
    let retryAllowed: Bool
    let restartAllowed: Bool
    let activeModel: String?

    var id: String { "\(kind.rawValue):\(model)" }
    var fraction: Double? {
        guard state == .downloading, let bytesTotal, bytesTotal > 0 else { return nil }
        return min(1, Double(bytesReceived) / Double(bytesTotal))
    }
}

struct DownloadSnapshot: Decodable, Equatable {
    private static let supportedSchema = 1
    let schema: Int
    let engineID: String
    let sequence: Int64
    let snapshot: Bool
    let downloads: [ModelDownload]

    // Strict decoding rejects a malformed full list, never silently dropping a protected item.
    static func parse(_ object: [String: Any]) -> DownloadSnapshot? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let value = try? decoder.decode(DownloadSnapshot.self, from: data),
              value.schema == supportedSchema, value.snapshot, !value.engineID.isEmpty,
              value.sequence >= 0,
              Set(value.downloads.map(\.id)).count == value.downloads.count,
              value.downloads.allSatisfy({
                  !$0.model.isEmpty && !$0.attempt.isEmpty && $0.bytesReceived >= 0
                      && $0.retryIndex >= 0
              }) else { return nil }
        guard value.downloads.allSatisfy({ item in
            (item.bytesTotal.map { $0 >= item.bytesReceived } ?? true)
                && (item.retryAt.map { $0.isFinite && $0 >= 0 } ?? true)
        }) else { return nil }
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case schema, engineID = "engineId", sequence, snapshot, downloads
    }
}

// Supervisor -> DownloadState -> onboarding / Models. Connection fences every action.
final class DownloadState: ObservableObject {
    @Published private(set) var snapshot: DownloadSnapshot?
    @Published private(set) var isCurrent = false
    @Published private(set) var speechReady = false
    @Published private(set) var writingReady = false
    @Published private(set) var pending: [DownloadKind: String] = [:]
    @Published private(set) var selectionErrors: [DownloadKind: String] = [:]
    private var selectionRequests: [DownloadKind: String] = [:]
    private var connected = false
    private var writingLoadedStatus: Bool?
    private var send: (([String: Any]) -> Void)?

    var downloads: [ModelDownload] { snapshot?.downloads ?? [] }
    var protectedModels: Set<String> {
        Set(downloads.flatMap { [$0.model, $0.activeModel].compactMap { $0 } })
            .union(pending.values)
    }

    func bind(_ send: @escaping ([String: Any]) -> Void) { self.send = send }

    func connect() {
        connected = true
        isCurrent = false
        speechReady = false
        writingReady = false
        send?(["cmd": "download_status"])
        send?(["cmd": "status"])
    }

    func disconnect() {
        connected = false
        isCurrent = false
        speechReady = false
        writingReady = false
    }

    func invalidate() { isCurrent = false }

    @discardableResult
    func apply(_ value: DownloadSnapshot) -> Bool {
        guard connected else { return false }
        if let old = snapshot, old.engineID == value.engineID, value.sequence < old.sequence {
            return false
        }
        if snapshot?.engineID != value.engineID {
            speechReady = false
            writingReady = false
            writingLoadedStatus = nil
            pending = [:]
            selectionRequests = [:]
            selectionErrors = [:]
        }
        // Idle unload changes cleanup_loaded without changing the coordinator's adoption snapshot.
        if primaryWritingKey(snapshot) != primaryWritingKey(value) {
            writingLoadedStatus = nil
        }
        snapshot = value
        isCurrent = true
        // active_model is live adoption; an auxiliary ready item is not primary readiness.
        if value.downloads.contains(where: { $0.kind == .stt && $0.state == .ready && $0.activeModel == $0.model }) {
            speechReady = true
        }
        writingReady = writingLoadedStatus ?? (primaryWritingKey(value) != nil)
        for item in value.downloads where item.state == .ready && item.model == item.activeModel {
            accept(model: item.model, kind: item.kind)
        }
        return true
    }

    private func primaryWritingKey(_ value: DownloadSnapshot?) -> String? {
        guard let item = value?.downloads.first(where: {
            $0.kind == .cleanup && $0.state == .ready && $0.activeModel == $0.model
        }) else { return nil }
        return "\(item.model):\(item.attempt)"
    }

    func readiness(speech: Bool?, writing: Bool?) {
        guard connected else { return }
        if let speech { speechReady = speech }
        if let writing {
            writingLoadedStatus = writing
            writingReady = writing
        }
    }

    func select(model: String, kind: DownloadKind) {
        guard connected, isCurrent, !model.isEmpty else { return }
        let requestID = UUID().uuidString
        pending[kind] = model
        selectionRequests[kind] = requestID
        selectionErrors[kind] = nil
        send?(["cmd": "set_model", "model": model, "kind": kind.rawValue,
               "request_id": requestID])
    }

    func accept(model: String, kind: DownloadKind, requestID: String? = nil) {
        guard pending[kind] == model else { return }
        if let requestID, requestID != selectionRequests[kind] { return }
        pending[kind] = nil
        selectionRequests[kind] = nil
        selectionErrors[kind] = nil
    }

    // Only an identified rejection can settle a request; unscoped errors may belong to other work.
    func reject(model: String, kind: DownloadKind, requestID: String, message: String) {
        guard connected, pending[kind] == model, selectionRequests[kind] == requestID else { return }
        pending[kind] = nil
        selectionRequests[kind] = nil
        selectionErrors[kind] = message
    }

    func canAct(_ item: ModelDownload, _ action: DownloadAction) -> Bool {
        guard connected, isCurrent,
              downloads.contains(item) else { return false }
        return action == .retry ? item.retryAllowed : item.restartAllowed
    }

    func request(_ item: ModelDownload, _ action: DownloadAction) {
        guard canAct(item, action) else { return }
        // Invalidate until the accepted/rejected authoritative snapshot arrives.
        isCurrent = false
        send?(["cmd": action.rawValue, "model": item.model,
               "kind": item.kind.rawValue, "attempt": item.attempt])
        send?(["cmd": "download_status"])
    }
}

// Per-phase deadlines are measured from receipt, not edit submission.
enum EditPhase: String { case loading, inference }
struct EditDeadline {
    private(set) var id: String?
    private(set) var deadline: Date?
    private(set) var phase: EditPhase?

    mutating func start(id: String, now: Date, budget: TimeInterval) {
        self.id = id
        deadline = now.addingTimeInterval(budget)
        phase = nil
    }

    mutating func receive(id: String?, phase: EditPhase, budget: TimeInterval, now: Date) -> Bool {
        guard let id, id == self.id, budget.isFinite, budget > 0 else { return false }
        self.phase = phase
        deadline = now.addingTimeInterval(budget)
        return true
    }

    mutating func clear() { self = EditDeadline() }
}
