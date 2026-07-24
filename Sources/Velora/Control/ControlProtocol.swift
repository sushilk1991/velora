import Foundation

/// Stable, deliberately small protocol for the app-owned local control socket.
/// It is separate from the engine protocol: the app owns history, consent,
/// microphone authority, and the only engine connection.
struct ControlRequest {
    static let version = 1
    static let maxBytes = 1_048_576

    let id: String
    let command: String
    let arguments: [String: Any]

    enum ParseError: LocalizedError {
        case tooLarge
        case invalidJSON
        case unsupportedVersion
        case invalidID
        case invalidCommand
        case invalidArguments

        var errorDescription: String? {
            switch self {
            case .tooLarge: return "request is too large"
            case .invalidJSON: return "request is not a JSON object"
            case .unsupportedVersion: return "unsupported protocol version"
            case .invalidID: return "request id must be a non-empty string"
            case .invalidCommand: return "command must be a short identifier"
            case .invalidArguments: return "arguments must be a JSON object"
            }
        }
    }

    static func parse(_ data: Data) throws -> ControlRequest {
        guard data.count <= maxBytes else { throw ParseError.tooLarge }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any]
        else { throw ParseError.invalidJSON }
        guard (payload["version"] as? NSNumber)?.intValue == version else {
            throw ParseError.unsupportedVersion
        }
        guard let id = payload["id"] as? String,
              !id.isEmpty, id.utf8.count <= 128 else { throw ParseError.invalidID }
        guard let command = payload["command"] as? String,
              !command.isEmpty, command.utf8.count <= 64,
              command.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).contains($0)
              })
        else { throw ParseError.invalidCommand }
        let arguments: [String: Any]
        if payload["arguments"] == nil {
            arguments = [:]
        } else if let supplied = payload["arguments"] as? [String: Any] {
            arguments = supplied
        } else {
            throw ParseError.invalidArguments
        }
        return ControlRequest(id: id, command: command, arguments: arguments)
    }

    var payload: [String: Any] {
        ["version": Self.version, "id": id, "command": command, "arguments": arguments]
    }
}

struct ControlFailure: Error, Equatable {
    let code: String
    let message: String

    static let disabled = ControlFailure(
        code: "access_disabled",
        message: "Local CLI and agent access is disabled in Velora Settings")
}

struct ControlResponse {
    let id: String
    let result: [String: Any]?
    let failure: ControlFailure?

    static func success(id: String, result: [String: Any]) -> ControlResponse {
        ControlResponse(id: id, result: result, failure: nil)
    }

    static func error(id: String, _ failure: ControlFailure) -> ControlResponse {
        ControlResponse(id: id, result: nil, failure: failure)
    }

    var payload: [String: Any] {
        var object: [String: Any] = [
            "version": ControlRequest.version,
            "id": id,
            "ok": failure == nil,
        ]
        if let result { object["result"] = result }
        if let failure {
            object["error"] = ["code": failure.code, "message": failure.message]
        }
        return object
    }

    func encodedLine() -> Data? {
        guard JSONSerialization.isValidJSONObject(payload),
              var data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.sortedKeys])
        else { return nil }
        data.append(0x0A)
        return data
    }
}

/// Pure capability router. It has no microphone or input-synthesis verbs; later
/// stages add those behind separate, consent-requiring callbacks.
final class LocalControlRouter {
    typealias AsyncCapability = (
        [String: Any], @escaping (Result<[String: Any], ControlFailure>) -> Void
    ) -> (() -> Void)

    static let maxResults = 100
    static let maxQueryCharacters = 500
    static let maxTranscriptCharacters = 20_000

    private let history: HistoryStore
    private let accessEnabled: () -> Bool
    private let engineReady: () -> Bool
    private let typingWPM: () -> Int
    private let transcribeFile: AsyncCapability?
    private let listen: AsyncCapability?

    init(
        history: HistoryStore,
        accessEnabled: @escaping () -> Bool,
        engineReady: @escaping () -> Bool,
        typingWPM: @escaping () -> Int,
        transcribeFile: AsyncCapability? = nil,
        listen: AsyncCapability? = nil
    ) {
        self.history = history
        self.accessEnabled = accessEnabled
        self.engineReady = engineReady
        self.typingWPM = typingWPM
        self.transcribeFile = transcribeFile
        self.listen = listen
    }

    /// Async facade used by the socket server. Read-only commands complete
    /// immediately; long-running capabilities retain the one client request
    /// until the app-owned workflow finishes or fails.
    @discardableResult
    func handle(
        _ request: ControlRequest,
        completion: @escaping (ControlResponse) -> Void
    ) -> (() -> Void)? {
        guard request.command == "transcribe" || request.command == "listen" else {
            completion(handle(request))
            return nil
        }
        guard accessEnabled() else {
            completion(.error(id: request.id, .disabled))
            return nil
        }
        guard let mode = validatedMode(request.arguments) else {
            completion(.error(id: request.id, ControlFailure(
                code: "invalid_arguments",
                message: "mode must be a non-empty name of at most 128 characters")))
            return nil
        }

        let capability: AsyncCapability?
        var arguments = request.arguments
        if let mode { arguments["mode"] = mode } else { arguments.removeValue(forKey: "mode") }
        if request.command == "transcribe" {
            guard let path = validatedPath(arguments) else {
                completion(.error(id: request.id, ControlFailure(
                    code: "invalid_arguments",
                    message: "transcribe requires an absolute audio file path")))
                return nil
            }
            arguments["path"] = path
            capability = transcribeFile
        } else {
            capability = listen
        }
        guard let capability else {
            completion(.error(id: request.id, ControlFailure(
                code: "capability_unavailable", message: "Capability is unavailable")))
            return nil
        }
        return capability(arguments) { result in
            switch result {
            case .success(let payload):
                completion(.success(id: request.id, result: payload))
            case .failure(let failure):
                completion(.error(id: request.id, failure))
            }
        }
    }

    func handle(_ request: ControlRequest) -> ControlResponse {
        if request.command == "status" {
            return .success(id: request.id, result: status())
        }
        guard accessEnabled() else { return .error(id: request.id, .disabled) }
        switch request.command {
        case "recent":
            return .success(
                id: request.id,
                result: ["records": records(history.recent(limit: limit(request.arguments)))])
        case "search":
            guard let query = query(request.arguments) else {
                return .error(id: request.id, ControlFailure(
                    code: "invalid_arguments", message: "search requires a non-empty query"))
            }
            return .success(
                id: request.id,
                result: [
                    "query": query,
                    "records": records(history.page(
                        limit: limit(request.arguments), offset: 0, search: query)),
                ])
        case "stats":
            return .success(id: request.id, result: stats())
        default:
            return .error(id: request.id, ControlFailure(
                code: "unknown_command", message: "Unknown command: \(request.command)"))
        }
    }

    private func status() -> [String: Any] {
        let enabled = accessEnabled()
        return [
            "app_running": true,
            "engine_ready": engineReady(),
            "access_enabled": enabled,
            "protocol_version": ControlRequest.version,
            "capabilities": enabled ? capabilities : [],
        ]
    }

    private var capabilities: [String] {
        var values = ["recent", "search", "stats"]
        if transcribeFile != nil { values.append("transcribe") }
        if listen != nil { values.append("listen") }
        return values
    }

    /// A missing mode is valid. A present value is trimmed and bounded; this
    /// still permits user-authored custom mode names.
    private func validatedMode(_ arguments: [String: Any]) -> String?? {
        guard let supplied = arguments["mode"] else { return .some(nil) }
        guard let raw = supplied as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 128,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        return .some(value)
    }

    private func validatedPath(_ arguments: [String: Any]) -> String? {
        guard let raw = arguments["path"] as? String,
              !raw.isEmpty, raw.utf8.count <= 4_096,
              raw.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: raw).standardizedFileURL.path
    }

    private func limit(_ arguments: [String: Any]) -> Int {
        let raw = (arguments["limit"] as? NSNumber)?.intValue ?? 10
        return min(Self.maxResults, max(1, raw))
    }

    private func query(_ arguments: [String: Any]) -> String? {
        guard let raw = arguments["query"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(Self.maxQueryCharacters))
    }

    /// The public record projection is an allow-list. In particular it omits
    /// raw transcript, bundle id, audio path, session id, and learning state.
    private func records(_ source: [DictationRecord]) -> [[String: Any]] {
        source.map { record in
            let text = String(record.final.prefix(Self.maxTranscriptCharacters))
            var item: [String: Any] = [
                "timestamp": ISO8601DateFormatter().string(from: record.timestamp),
                "text": text,
                "truncated": text.count < record.final.count,
                "duration_ms": record.durationMs,
            ]
            if let appName = record.appName { item["app_name"] = appName }
            if let mode = record.mode { item["mode"] = mode }
            return item
        }
    }

    private func stats() -> [String: Any] {
        let insights = history.insights()
        let wpm = typingWPM()
        func window(_ value: HistoryStore.WindowStats) -> [String: Any] {
            var result: [String: Any] = [
                "dictations": value.count,
                "words": value.words,
                "speaking_ms": value.spokenMs,
                "minutes_saved": value.minutesSaved(typingWPM: wpm),
                "quality_observations": value.qualityObserved,
            ]
            if let rate = value.zeroEditRate { result["zero_edit_rate"] = rate }
            if let coverage = value.observationCoverage {
                result["observation_coverage"] = coverage
            }
            if let latency = value.averageSttMs { result["average_stt_ms"] = latency }
            if let latency = value.averageCleanupWallMs {
                result["average_cleanup_wall_ms"] = latency
            }
            if let latency = value.averageFinalizationMs {
                result["average_finalization_ms"] = latency
            }
            return result
        }
        return [
            "typing_wpm": wpm,
            "today": window(insights.today),
            "last_7_days": window(insights.week),
            "last_30_days": window(insights.month),
            "all_time": window(insights.allTime),
            "current_streak_days": insights.currentStreak,
            "longest_streak_days": insights.longestStreak,
        ]
    }
}
