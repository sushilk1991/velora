import AppIntents
import Foundation
import UniformTypeIdentifiers

/// Shortcuts uses the same owner-only broker and grants as the CLI. No intent
/// reads private stores directly or obtains a microphone capability.
enum ShortcutBridge {
    static func call(_ command: String, _ arguments: [String: Any] = [:], timeout: Int = 120,
                     waitForEngine: Bool = false) async throws -> [String: Any] {
        let cancellation = ControlClientCancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            let result = try await Task.detached(priority: .userInitiated) {
                do {
                    let deadline = ProcessInfo.processInfo.systemUptime + (waitForEngine ? 90 : 10)
                    while true {
                        if cancellation.isCancelled { throw CancellationError() }
                        do {
                            let status = try LocalControlClient.send(command: "status", timeoutSeconds: 3,
                                                                      cancellation: cancellation)
                            guard status["access_enabled"] as? Bool == true else {
                                throw ControlClientError.remote(.disabled)
                            }
                            let capabilities = status["capabilities"] as? [String] ?? []
                            guard capabilities.contains(command) else {
                                throw ControlClientError.remote(LocalWorkflowService.denied(command))
                            }
                            if !waitForEngine || status["engine_ready"] as? Bool == true { break }
                        } catch ControlClientError.appUnavailable {
                            // openAppWhenRun may return before the app broker binds.
                        }
                        guard ProcessInfo.processInfo.systemUptime < deadline else {
                            throw ShortcutInputError.notReady
                        }
                        try await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
                return try LocalControlClient.send(command: command, arguments: arguments, timeoutSeconds: timeout,
                                                   cancellation: cancellation)
            }.value
            try Task.checkCancellation()
            return result
        }, onCancel: { cancellation.cancel() })
    }
    static func text(_ payload: [String: Any]) -> String { payload["text"] as? String ?? "" }
}

struct VeloraGetLastResultIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Last Velora Result"
    static var description = IntentDescription("Return the latest dictation text. Requires local integration and history access in Velora.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let payload = try await ShortcutBridge.call("recent", ["limit": 1])
        let rows = payload["records"] as? [[String: Any]] ?? []
        return .result(value: rows.first?["text"] as? String ?? "")
    }
}

struct VeloraReformatTextIntent: AppIntent {
    static var title: LocalizedStringResource = "Reformat Text with Velora"
    static var description = IntentDescription("Format supplied text on your Mac without saving or pasting it. Uses built-in writing modes and requires local integration access.")
    static var openAppWhenRun = true
    @Parameter(title: "Text") var text: String
    @Parameter(title: "Mode", default: "Default") var mode: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await ShortcutBridge.call("format_text", ["text": text, "mode": mode], waitForEngine: true)
        return .result(value: ShortcutBridge.text(result))
    }
}

struct VeloraTranscribeFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Transcribe File with Velora"
    static var description = IntentDescription("Transcribe an audio or video file on your Mac. Returns text without saving a sidecar or changing the clipboard.")
    static var openAppWhenRun = true
    @Parameter(title: "Recording") var recording: IntentFile

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        try Task.checkCancellation()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("velora-shortcut-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let suffix = URL(fileURLWithPath: recording.filename).pathExtension
        let staged = temporary.appendingPathComponent("input").appendingPathExtension(suffix.isEmpty ? "audio" : suffix)
        if let source = recording.fileURL {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let info = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard info.isRegularFile == true else { throw ShortcutInputError.notFile }
            guard let size = info.fileSize, size <= 1_073_741_824 else { throw ShortcutInputError.tooLarge }
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: source, to: staged)
            }.value
        } else {
            let data = recording.data
            guard data.count <= 1_073_741_824 else { throw ShortcutInputError.tooLarge }
            try data.write(to: staged, options: .atomic)
        }
        try Task.checkCancellation()
        let stagedInfo = try staged.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard stagedInfo.isRegularFile == true else { throw ShortcutInputError.notFile }
        guard let stagedSize = stagedInfo.fileSize, stagedSize <= 1_073_741_824 else { throw ShortcutInputError.tooLarge }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        let result = try await ShortcutBridge.call("transcribe", ["path": staged.path], timeout: 360, waitForEngine: true)
        return .result(value: ShortcutBridge.text(result))
    }
}

enum ShortcutInputError: LocalizedError {
    case tooLarge, notFile, notReady
    var errorDescription: String? {
        switch self {
        case .tooLarge: return "Use a recording smaller than 1 GB."
        case .notFile: return "Choose one audio or video file."
        case .notReady: return "Velora is still starting its speech and writing models. Try again when it is ready."
        }
    }
}

struct VeloraMeetingEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Velora meeting")
    static var defaultQuery = VeloraMeetingQuery()
    let id: String
    let title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct VeloraMeetingQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [VeloraMeetingEntity] {
        var found: [VeloraMeetingEntity] = []
        for id in identifiers.prefix(100) {
            let result = try await ShortcutBridge.call("meetings_show", ["meeting_id": id])
            found.append(VeloraMeetingEntity(id: id, title: result["title"] as? String ?? "Meeting"))
        }
        return found
    }
    func suggestedEntities() async throws -> [VeloraMeetingEntity] {
        let result = try await ShortcutBridge.call("meetings_list", ["limit": 20])
        return (result["meetings"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? String, let title = $0["title"] as? String else { return nil }
            return VeloraMeetingEntity(id: id, title: title)
        }
    }
}

enum VeloraShortcutExportFormat: String, AppEnum {
    case markdown, text, srt, vtt
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Export format")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .markdown: "Markdown", .text: "Plain text", .srt: "SRT timed transcript", .vtt: "VTT timed transcript"
    ]
}

struct VeloraExportMeetingIntent: AppIntent {
    static var title: LocalizedStringResource = "Export Velora Meeting"
    static var description = IntentDescription("Return a meeting transcript or notes as a file. Requires local integration and meeting access. Timed exports may use coarse audio-block timings.")
    static var openAppWhenRun = true
    @Parameter(title: "Meeting") var meeting: VeloraMeetingEntity
    @Parameter(title: "Format", default: .markdown) var format: VeloraShortcutExportFormat

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let payload = try await ShortcutBridge.call("meetings_export", ["meeting_id": meeting.id, "format": format.rawValue])
        let suffix = format == .markdown ? "md" : format == .text ? "txt" : format.rawValue
        return .result(value: IntentFile(data: Data(ShortcutBridge.text(payload).utf8),
            filename: "Velora meeting." + suffix, type: .plainText))
    }
}
