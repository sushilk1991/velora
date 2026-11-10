import AppKit
import CoreFoundation
import Foundation

/// App-owned adapters: the CLI and MCP never open engine or dictionary files directly.
/// The broker invokes this on a worker; all mutable app owners are entered on main.
final class LocalWorkflowService {
    static let commands = [
        "modes_list", "modes_validate", "modes_init", "vocabulary_list",
        "vocabulary_add", "vocabulary_remove", "meetings_list", "meetings_search",
        "meetings_show", "meetings_export", "format_text", "model_status", "paste_last",
    ]
    private let history: HistoryStore
    private let meetings: MeetingStore
    private let dictionary: DictionaryRepository
    private let formatter: TextFormattingClient
    private let policy: AgentAccessPolicy
    private let accessEnabled: () -> Bool
    private let engineReady: () -> Bool
    private let modesDirectory: URL
    private let inserter = TextInserter()
    private var activeFormats: [UUID: String] = [:]

    init(history: HistoryStore, meetings: MeetingStore, dictionary: DictionaryRepository,
         supervisor: EngineSupervisor?, policy: AgentAccessPolicy = .shared,
         accessEnabled: @escaping () -> Bool, engineReady: @escaping () -> Bool,
         modesDirectory: URL = AppConfig.modesDirectory) {
        self.history = history
        self.meetings = meetings
        self.dictionary = dictionary
        formatter = TextFormattingClient(supervisor: supervisor)
        self.policy = policy
        self.accessEnabled = accessEnabled
        self.engineReady = engineReady
        self.modesDirectory = modesDirectory
    }

    func revoke() {
        dispatchPrecondition(condition: .onQueue(.main))
        for id in Array(activeFormats.values) { formatter.cancel(id) }
        activeFormats.removeAll()
    }

    func handle(_ arguments: [String: Any],
                completion: @escaping (Result<[String: Any], ControlFailure>) -> Void) -> (() -> Void) {
        let token = UUID()
        let cancellation = WorkflowCancellation()
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completion(.failure(ControlFailure(code: "app_unavailable", message: "Velora is shutting down")))
                return
            }
            guard !cancellation.isCancelled else { return }
            let command = arguments["_command"] as? String ?? ""
            let finish: (Result<[String: Any], ControlFailure>) -> Void = { [weak self] result in
                guard !cancellation.isCancelled else { return }
                guard let self, self.accessEnabled() else { completion(.failure(.disabled)); return }
                guard AgentAccessPolicy.required(for: command).allSatisfy(self.policy.allows) else {
                    completion(.failure(Self.denied(command))); return
                }
                completion(result)
            }
            guard self.accessEnabled() else { finish(.failure(.disabled)); return }
            guard AgentAccessPolicy.required(for: command).allSatisfy(self.policy.allows) else {
                finish(.failure(Self.denied(command))); return
            }
            if command == "format_text" {
                guard let text = arguments["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.unicodeScalars.count <= 60_000 else {
                    finish(.failure(Self.invalid("format requires 1–60,000 characters of text"))); return
                }
                let mode: String?
                if let supplied = arguments["mode"] {
                    guard let name = supplied as? String, !name.isEmpty, name.count <= 128 else {
                        finish(.failure(Self.invalid("mode must be a name of at most 128 characters"))); return
                    }
                    mode = name
                } else { mode = nil }
                let id = self.formatter.format(text, modeName: mode, personalContext: false) { [weak self] result in
                    self?.activeFormats.removeValue(forKey: token)
                    switch result {
                    case .success(let value): finish(.success([
                        "text": value.text, "mode": value.mode, "reason": value.reason,
                        "cleanup_applied": value.cleanupApplied, "cleanup_ms": value.cleanupMs,
                    ]))
                    case .failure(let error): finish(.failure(ControlFailure(code: error.code, message: error.message)))
                    }
                }
                if let id { self.activeFormats[token] = id }
                return
            }
            if command == "paste_last" { self.deliverLast(arguments, completion: finish); return }
            do { finish(.success(try self.execute(command, arguments: arguments))) }
            catch let error as ControlFailure { finish(.failure(error)) }
            catch { finish(.failure(ControlFailure(code: "operation_failed", message: error.localizedDescription))) }
        }
        return { [weak self] in
            cancellation.cancel()
            DispatchQueue.main.async {
                guard let self, let id = self.activeFormats.removeValue(forKey: token) else { return }
                self.formatter.cancel(id)
            }
        }
    }

    private func execute(_ command: String, arguments: [String: Any]) throws -> [String: Any] {
        switch command {
        case "modes_list":
            let modes = Mode.loadAll(from: modesDirectory).prefix(Self.limit(arguments))
            return ["modes": modes.map { ["name": $0.name, "formatting": $0.formatting] }]
        case "modes_validate":
            guard let text = arguments["document"] as? String,
                  text.utf8.count <= ModeRecipeDocument.maximumBytes else {
                throw Self.invalid("Supply a recipe document of at most 256 KB")
            }
            let mode = try ModeRecipeDocument.decode(Data(text.utf8))
            return ["valid": true, "name": mode.name, "formatting": mode.formatting,
                    "saved": false, "app_assignments_applied": false]
        case "modes_init":
            let name = try Self.text(arguments, "name", maximum: 100, fallback: "Custom mode")
            var mode: Mode
            if let recipe = arguments["recipe"] as? String {
                guard let selected = ModeRecipe.all.first(where: { $0.id == recipe }) else {
                    throw Self.invalid("Unknown recipe. Choose work-update, issue-report, meeting-follow-up, or structured-note")
                }
                mode = selected.mode
            } else {
                mode = Mode(name: name, prompt: "Clean up the dictated words conservatively. Preserve meaning, names, numbers, and uncertainty. Add no facts.",
                            formatting: "light", apps: [], vocabulary: [], replacements: [])
            }
            mode.name = name
            let data = try ModeRecipeDocument.encode(mode)
            return ["document": String(decoding: data, as: UTF8.self), "saved": false]
        case "vocabulary_list":
            return ["entries": dictionary.rows.prefix(Self.limit(arguments)).map(Self.dictionaryEntry)]
        case "vocabulary_add":
            let writeAs = try Self.text(arguments, "write_as", maximum: 200)
            let heardAs = try arguments["heard_as"].map { _ in try Self.text(arguments, "heard_as", maximum: 200) }
            return ["entry": Self.dictionaryEntry(try dictionary.add(writeAs: writeAs, heardAs: heardAs))]
        case "vocabulary_remove":
            guard Self.explicitTrue(arguments["confirm"]) else {
                throw Self.invalid("Removing vocabulary requires confirm: true (CLI: --yes)")
            }
            let id = try Self.text(arguments, "entry_id", maximum: 512)
            try dictionary.remove(id: id)
            return ["removed": true, "entry_id": id]
        case "meetings_list":
            return ["meetings": meetings.recentMetadata(limit: Self.limit(arguments)).map(Self.meetingMetadata)]
        case "meetings_search":
            let query = try Self.text(arguments, "query", maximum: LocalControlRouter.maxQueryCharacters)
            return ["query": query, "meetings": meetings.search(query, limit: Self.limit(arguments)).map {
                ["id": $0.meetingID, "title": String($0.title.prefix(512)),
                 "started_at": ISO8601DateFormatter().string(from: $0.startedAt),
                 "snippet": String($0.snippet.prefix(2_000))]
            }]
        case "meetings_show", "meetings_export":
            let id = try Self.text(arguments, "meeting_id", maximum: 128)
            guard let record = meetings.record(id: id) else {
                throw ControlFailure(code: "not_found", message: "That meeting no longer exists")
            }
            if command == "meetings_export" {
                let raw = arguments["format"] as? String ?? "markdown"
                guard let format = MeetingExportFormat(rawValue: raw == "text" ? "plainText" : raw) else {
                    throw Self.invalid("format must be markdown, text, srt, or vtt")
                }
                let text = record.export(format: format)
                guard text.utf8.count <= 512 * 1_024 else {
                    throw ControlFailure(code: "result_too_large", message: "Export this longer recording from the Meetings window")
                }
                var result: [String: Any] = ["meeting_id": id, "format": raw, "text": text]
                if format.usesCueTiming { result["timing_notice"] = MeetingExportFormat.timingNotice }
                return result
            }
            var result = Self.meetingMetadata(record)
            result["summary"] = String(record.notes.summary.prefix(LocalControlRouter.maxTranscriptCharacters))
            result["decisions"] = record.notes.decisions.prefix(100).map { String($0.prefix(2_000)) }
            result["action_items"] = record.notes.actionItems.prefix(100).map {
                ["text": String($0.prefix(2_000)), "completed": record.notes.completedActionItems.contains($0)] as [String: Any]
            }
            var remaining = LocalControlRouter.maxTranscriptCharacters
            var segments: [[String: Any]] = []
            for segment in record.segments.prefix(Self.limit(arguments)) where remaining > 0 {
                let text = String(segment.text.prefix(remaining))
                remaining -= text.count
                segments.append(["start_ms": segment.startMs, "end_ms": segment.endMs,
                                 "speaker": segment.speaker.displayName, "text": text])
            }
            result["segments"] = segments
            result["truncated"] = segments.count < record.segments.count || remaining == 0
            return result
        case "model_status":
            let config = AppConfig.shared
            return ["engine_ready": engineReady(),
                    "configured_speech_model": Self.publicModel(config.sttModel),
                    "configured_cleanup_model": Self.publicModel(config.cleanupModel ?? "")]
        default: throw ControlFailure(code: "unknown_command", message: "Unknown workflow command")
        }
    }

    private func deliverLast(_ arguments: [String: Any],
                             completion: @escaping (Result<[String: Any], ControlFailure>) -> Void) {
        guard let delivery = arguments["delivery"] as? String, ["copy", "paste"].contains(delivery) else {
            completion(.failure(Self.invalid("Choose an explicit copy or paste delivery"))); return
        }
        guard let record = history.recent(limit: 1).first, !record.final.isEmpty else {
            completion(.failure(ControlFailure(code: "not_found", message: "No dictation is available"))); return
        }
        inserter.copyToClipboard(record.final)
        guard delivery == "paste" else { completion(.success(["delivery": "copied"])); return }
        guard let bundle = arguments["target_bundle_id"] as? String,
              !bundle.isEmpty, bundle.count <= 512,
              let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundle,
              bundle != DictationRecord.ownBundleID,
              Permissions.accessibilityGranted, TextInserter.canPostEvents, !SecureInput.isActive,
              let target = ScreenContext.focusedElement(of: app) else {
            completion(.success(["delivery": "copied", "reason": "Target unavailable; no input was posted"])); return
        }
        // One guarded paste, never an asynchronous typing sequence that could
        // outlive a revoked grant. Terminal-like targets keep the manual-copy path.
        guard !AppConfig.shared.typingFallbackApps.contains(bundle) else {
            completion(.success(["delivery": "copied", "reason": "This app uses manual clipboard delivery for agent requests"])); return
        }
        let text = TextInsertionBoundary.adjusted(record.final,
            boundary: ScreenContext.selectionBoundary(of: target), mode: record.mode)
        let posted = inserter.insertViaPasteboard(text, targetBundleID: bundle, targetElement: target,
            additionalDeliveryCheck: { [weak self] in
                guard let self else { return false }
                return self.accessEnabled() && self.policy.allows(.history) && self.policy.allows(.delivery)
            })
        completion(.success(["delivery": posted ? "paste_requested" : "copied"]))
    }

    static func denied(_ command: String) -> ControlFailure {
        ControlFailure(code: "capability_disabled", message: "Permission for \(command) is disabled in Velora Settings › Advanced")
    }
    private static func invalid(_ message: String) -> ControlFailure {
        ControlFailure(code: "invalid_arguments", message: message)
    }
    private static func limit(_ arguments: [String: Any]) -> Int {
        min(100, max(1, (arguments["limit"] as? NSNumber)?.intValue ?? 10))
    }
    private static func text(_ arguments: [String: Any], _ key: String, maximum: Int,
                             fallback: String? = nil) throws -> String {
        if let supplied = arguments[key], !(supplied is String) {
            throw invalid("\(key) must be text")
        }
        guard let raw = (arguments[key] as? String) ?? fallback else {
            throw invalid("\(key) is required")
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.unicodeScalars.count <= maximum,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw invalid("\(key) must be nonempty text of at most \(maximum) characters")
        }
        return value
    }
    private static func explicitTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue
    }
    private static func dictionaryEntry(_ row: DictionaryRow) -> [String: Any] {
        var result: [String: Any] = ["id": row.id, "write_as": row.writeAs, "source": row.source.rawValue]
        if let heard = row.heardAs { result["heard_as"] = heard }
        return result
    }
    private static func meetingMetadata(_ record: MeetingRecord) -> [String: Any] {
        ["id": record.id, "title": String(record.title.prefix(512)),
         "started_at": ISO8601DateFormatter().string(from: record.startedAt),
         "duration_ms": record.durationMs, "status": record.status.rawValue,
         "notes_partial": record.notes.partial]
    }
    private static func publicModel(_ id: String) -> String {
        if id.hasPrefix("/") || id.hasPrefix("~") || id.hasPrefix("file:")
            || id.contains("\\") || id.split(separator: "/").contains("..") {
            return "Local model"
        }
        return String(id.prefix(512))
    }
}

private final class WorkflowCancellation {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
