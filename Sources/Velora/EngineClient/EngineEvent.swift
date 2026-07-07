import Foundation

/// Events emitted by velora-engine over the control channel.
/// See docs/ARCHITECTURE.md "Wire protocol".
enum EngineEvent {
    /// Engine finished startup (STT model preloaded) and is ready for `start`.
    case ready

    /// Streaming partial transcript (P1 HUD display; parsed but unused in P0 UI).
    case partial(session: String, text: String)

    /// Raw transcript available (before LLM cleanup).
    case transcript(session: String, raw: String, ms: Int)

    /// Final text to insert. `cleanupApplied == false` means `text` carries the
    /// raw transcript (cleanup skipped, failed, or over budget).
    case final(
        session: String, text: String, raw: String, mode: String?,
        cleanupMs: Int?, cleanupApplied: Bool)

    /// Engine-reported error, optionally scoped to a session.
    case error(session: String?, message: String)

    /// Response to `ping`.
    case pong

    /// Response to `status`.
    case status([String: Any])

    /// Anything this client version doesn't know; ignored but logged.
    case unknown([String: Any])

    /// Decodes an event from a JSON control frame payload.
    static func parse(_ object: [String: Any]) -> EngineEvent {
        let name = (object["event"] as? String) ?? (object["reply"] as? String) ?? ""
        switch name {
        case "ready":
            return .ready
        case "partial":
            return .partial(
                session: object["session"] as? String ?? "",
                text: object["text"] as? String ?? "")
        case "transcript":
            return .transcript(
                session: object["session"] as? String ?? "",
                raw: object["raw"] as? String ?? "",
                ms: object["ms"] as? Int ?? 0)
        case "final":
            return .final(
                session: object["session"] as? String ?? "",
                text: object["text"] as? String ?? "",
                raw: object["raw"] as? String ?? (object["text"] as? String ?? ""),
                mode: object["mode"] as? String,
                cleanupMs: object["cleanup_ms"] as? Int,
                cleanupApplied: object["cleanup_applied"] as? Bool ?? false)
        case "error":
            return .error(
                session: object["session"] as? String,
                message: object["message"] as? String
                    ?? object["error"] as? String ?? "Engine error")
        case "pong":
            return .pong
        case "status":
            return .status(object)
        default:
            return .unknown(object)
        }
    }
}
