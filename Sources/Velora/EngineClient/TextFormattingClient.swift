import Foundation

struct TextFormattingResult: Equatable {
    let raw: String
    let text: String
    let mode: String
    let reason: String
    let cleanupApplied: Bool
    let cleanupMs: Int

    var explanation: String {
        let operation: String
        switch reason {
        case "snippet": operation = "Saved snippet inserted as literal text"
        case "cleanup_disabled": operation = "Writing cleanup is off"
        case "formatting_off": operation = "No writing model"
        case "short_utterance": operation = "Light cleanup for a short passage"
        case "smart_terminal": operation = "Conservative terminal formatting"
        case "cleanup_unavailable": operation = "Writing model unavailable; basic cleanup only"
        case "empty_transcript": operation = "No words to format"
        default:
            operation = cleanupApplied ? "Writing cleanup applied" : "Basic cleanup only"
        }
        return "\(mode) · \(operation)"
    }
}

struct TextFormattingFailure: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

/// Main-thread-only, correlated requests shared by History and the mode editor.
/// Completing one request never pastes, updates History, or saves a mode.
final class TextFormattingClient {
    private struct Pending {
        let completion: (Result<TextFormattingResult, TextFormattingFailure>) -> Void
        let timeout: DispatchWorkItem
    }
    private weak var supervisor: EngineSupervisor?
    private var pending: [String: Pending] = [:]
    private var observer: NSObjectProtocol?
    private var stateObserver: NSObjectProtocol?

    init(supervisor: EngineSupervisor?) {
        self.supervisor = supervisor
        observer = NotificationCenter.default.addObserver(
            forName: .veloraEngineTextFormatted, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let event = note.object as? EngineEvent else { return }
            switch event {
            case .textFormatted(let id, let result): self.finish(id, .success(result))
            case .textFormatFailed(let id, let error, let code):
                self.finish(id, .failure(TextFormattingFailure(code: code, message: error)))
            default: break
            }
        }
        stateObserver = NotificationCenter.default.addObserver(
            forName: .veloraEngineStateChanged, object: supervisor, queue: .main
        ) { [weak self] _ in
            guard let self, self.supervisor?.state != .ready else { return }
            for id in Array(self.pending.keys) {
                self.finish(id, .failure(TextFormattingFailure(
                    code: "disconnected", message: "The writing engine disconnected. Try again when it is ready.")))
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
        for (id, request) in pending {
            request.timeout.cancel()
            supervisor?.send(["cmd": "format_text_cancel", "request_id": id])
        }
    }

    @discardableResult
    func format(
        _ text: String, mode: Mode? = nil, modeName: String? = nil,
        bundleID: String? = nil, appName: String? = nil, personalContext: Bool = true,
        completion: @escaping (Result<TextFormattingResult, TextFormattingFailure>) -> Void
    ) -> String? {
        guard let supervisor, supervisor.state == .ready else {
            completion(.failure(TextFormattingFailure(code: "unavailable",
                message: "The writing engine is not ready. Try again shortly.")))
            return nil
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 60_000 else {
            completion(.failure(TextFormattingFailure(code: "invalid_arguments",
                message: "Enter between 1 and 60,000 characters to format.")))
            return nil
        }
        let id = UUID().uuidString
        var command: [String: Any] = ["cmd": "format_text", "request_id": id, "text": text]
        command["personal_context"] = personalContext
        if let mode {
            command["inline_mode"] = Self.modePayload(mode)
        } else if let modeName {
            command["mode"] = modeName
        }
        if let bundleID { command["bundle_id"] = bundleID }
        if let appName { command["app_name"] = appName }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.pending[id] != nil else { return }
            self.supervisor?.send(["cmd": "format_text_cancel", "request_id": id])
            self.finish(id, .failure(TextFormattingFailure(code: "timeout",
                message: "The preview timed out. Your original text is unchanged.")))
        }
        pending[id] = Pending(completion: completion, timeout: timeout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: timeout)
        supervisor.send(command)
        return id
    }

    func cancel(_ requestID: String) {
        guard pending[requestID] != nil else { return }
        supervisor?.send(["cmd": "format_text_cancel", "request_id": requestID])
        finish(requestID, .failure(TextFormattingFailure(code: "cancelled", message: "Preview cancelled.")))
    }

    static func modePayload(_ mode: Mode) -> [String: Any] {
        var replacements: [String: String] = [:]
        for item in mode.replacements { replacements[item.key] = item.value }
        return ["name": mode.name, "prompt": mode.prompt, "formatting": mode.formatting,
                "apps": mode.apps, "vocabulary": mode.vocabulary, "replacements": replacements]
    }

    private func finish(_ id: String, _ result: Result<TextFormattingResult, TextFormattingFailure>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        if case .failure(let failure) = result, failure.code != "cancelled" {
            ActivityStore.shared.record(.formattingFailed)
        }
        request.completion(result)
    }
}
