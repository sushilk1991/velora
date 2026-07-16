import AppKit
import Foundation
import UniformTypeIdentifiers

struct FileTranscriptionResult {
    let text: String
    let path: String
    let mode: String?
    let durationMs: Int
    let sttMs: Int
}

enum FileTranscriptionError: LocalizedError {
    case busy
    case engineUnavailable
    case invalidFile(String)
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .busy: return "Another file transcription is already running"
        case .engineUnavailable: return "The speech engine is still starting"
        case .invalidFile(let message): return message
        case .cancelled: return "Transcription cancelled"
        case .failed(let message): return message
        }
    }
}

/// "Transcribe Audio File…": file picker → engine `transcribe_file` job →
/// progress in the menubar menu → transcript to the clipboard + a sidecar
/// "<name> transcript.txt" next to the source + a HUD toast.
///
/// One job at a time (the engine enforces the same); a live dictation always
/// wins — the engine pauses the job between chunks while a session is active.
final class FileTranscriber {
    private let supervisor: EngineSupervisor
    private let hud: HUDPanel
    /// Transient+concealed clipboard writes (clipboard managers must not
    /// index a whole meeting transcript — same posture as dictation text).
    private let inserter = TextInserter()
    /// The dictation controller owns the HUD; only toast when it's free.
    private let hudIsFree: () -> Bool

    /// Non-nil while a job runs ("Transcribing… 45%"); drives the menu item.
    private(set) var progressLabel: String?
    private var sourceURL: URL?
    private var jobID: String?
    private var requestedMode: String?
    private var agentRequestID: UUID?
    private var agentCompletion: ((Result<FileTranscriptionResult, FileTranscriptionError>) -> Void)?
    /// Terminal lifecycle gate: no picker callback or broker dispatch can
    /// create a new engine job once application termination has started.
    private var terminating = false
    /// Fires if the engine never acknowledges the command (dropped while
    /// disconnected) so the menu can't get stuck on "Preparing…".
    private var ackTimer: Timer?
    /// Called on every progress/state change so the menubar can refresh.
    var onStateChange: (() -> Void)?

    var isTranscribing: Bool { progressLabel != nil }

    init(supervisor: EngineSupervisor, hud: HUDPanel, hudIsFree: @escaping () -> Bool) {
        self.supervisor = supervisor
        self.hud = hud
        self.hudIsFree = hudIsFree
    }

    // MARK: - Entry points

    func pickAndTranscribe() {
        guard !isTranscribing else { return }
        let panel = NSOpenPanel()
        panel.title = "Transcribe Audio File"
        panel.message = "Choose a voice memo, meeting recording, or any audio file."
        panel.prompt = "Transcribe"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.transcribe(url: url)
        }
    }

    func transcribe(url: URL) {
        start(url: url, mode: nil, agentRequestID: nil, completion: nil)
    }

    /// Programmatic file transcription for the local broker. Unlike the menu
    /// workflow this returns the result only to the requester: it never writes
    /// the clipboard, a sidecar file, or a HUD toast.
    func transcribeForAgent(
        url: URL,
        mode: String?,
        requestID: UUID,
        completion: @escaping (Result<FileTranscriptionResult, FileTranscriptionError>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        start(url: url, mode: mode, agentRequestID: requestID, completion: completion)
    }

    private func start(
        url: URL,
        mode: String?,
        agentRequestID: UUID?,
        completion: ((Result<FileTranscriptionResult, FileTranscriptionError>) -> Void)?
    ) {
        guard !terminating else {
            completion?(.failure(.cancelled))
            return
        }
        guard !isTranscribing else {
            completion?(.failure(.busy))
            return
        }
        guard url.isFileURL, url.path.utf8.count <= 4_096 else {
            completion?(.failure(.invalidFile("The audio path is invalid")))
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            completion?(.failure(.invalidFile("Audio file not found")))
            return
        }
        guard supervisor.isReady else {
            // EngineClient silently drops writes while disconnected — the job
            // would never start and the menu would stick on "Preparing…".
            if completion != nil {
                completion?(.failure(.engineUnavailable))
            } else {
                showToast(symbol: "hourglass", message: "Speech engine is starting — try again in a moment")
            }
            return
        }
        let id = UUID().uuidString
        sourceURL = url
        jobID = id
        requestedMode = mode
        self.agentRequestID = agentRequestID
        agentCompletion = completion
        progressLabel = "Preparing…"
        onStateChange?()
        veloraLog("Velora: transcribe_file requested (\(url.pathExtension), \((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) bytes)")
        var command: [String: Any] = ["cmd": "transcribe_file", "path": url.path, "id": id]
        if let mode { command["mode"] = mode }
        supervisor.send(command)
        // The engine acks immediately (before decoding); no ack = the command
        // was lost in a reconnect window.
        ackTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self, self.isTranscribing else { return }
            veloraLog("Velora: transcribe_file never acknowledged — clearing")
            self.fail("engine did not respond")
        }
    }

    func cancel() {
        guard isTranscribing, let jobID else { return }
        supervisor.send(["cmd": "transcribe_cancel", "id": jobID])
    }

    func cancelAgentRequest(_ requestID: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard agentRequestID == requestID else { return }
        cancel()
    }

    /// Cancels and locally completes an in-flight job without waiting for an
    /// engine event that may never arrive during process teardown. Late events
    /// are ignored because reset clears the exact job id before completion.
    func cancelForTermination() {
        dispatchPrecondition(condition: .onQueue(.main))
        terminating = true
        guard isTranscribing else { return }
        let completion = agentCompletion
        if let jobID {
            supervisor.send(["cmd": "transcribe_cancel", "id": jobID])
        }
        reset()
        completion?(.failure(.cancelled))
    }

    // MARK: - Engine events (routed by the AppDelegate)

    func handle(_ event: EngineEvent) {
        switch event {
        case .transcribeAccepted(let id):
            guard matches(id) else { return }
            ackTimer?.invalidate()
            ackTimer = nil
        case .transcribeStarted(let id, let durationS, let chunks):
            // Ghost guard: after a local failure (engine restart) a surviving
            // engine job must not resurrect the UI — its events are ignored.
            guard isTranscribing, matches(id) else { return }
            ackTimer?.invalidate()
            ackTimer = nil
            progressLabel = chunks > 1 ? "Transcribing… 0%" : "Transcribing…"
            onStateChange?()
            veloraLog("Velora: transcribe_file started (\(Int(durationS))s audio, \(chunks) chunks)")
        case .transcribeProgress(let id, let fraction):
            guard isTranscribing, matches(id) else { return }
            progressLabel = "Transcribing… \(Int((fraction * 100).rounded()))%"
            onStateChange?()
        case .transcribed(let id, _, let text, let mode, let durationS, let sttMs):
            guard isTranscribing, matches(id) else { return }
            veloraLog("Velora: transcribe_file done (\(text.count) chars, \(sttMs)ms)")
            finish(text: text, mode: mode, durationS: durationS, sttMs: sttMs)
        case .transcribeFailed(let id, let error):
            guard isTranscribing, matches(id) else { return }
            veloraLog("Velora: transcribe_file failed: \(error)")
            fail(error)
        default:
            break
        }
    }

    /// An engine crash/restart mid-job means no completion event will ever
    /// arrive — clear the stuck state and tell the user.
    func handleEngineStateChange(_ state: EngineSupervisor.State) {
        guard isTranscribing else { return }
        switch state {
        case .ready, .connecting:
            break
        case .stopped, .launching, .degraded:
            fail("engine restarted")
        }
    }

    // MARK: - Completion

    private func finish(text: String, mode: String?, durationS: Double, sttMs: Int) {
        let source = sourceURL
        let completion = agentCompletion
        let requested = requestedMode
        reset()
        guard !text.isEmpty else {
            if let completion {
                completion(.failure(.failed("No speech found in file")))
            } else {
                showToast(symbol: "exclamationmark.triangle.fill", message: "No speech found in file")
            }
            return
        }
        if let completion {
            completion(.success(FileTranscriptionResult(
                text: text,
                path: source?.path ?? "",
                mode: mode ?? requested,
                durationMs: max(0, Int((durationS * 1_000).rounded())),
                sttMs: sttMs)))
            return
        }
        inserter.copyToClipboard(text)

        var savedSidecar = false
        if let source, let sidecar = Self.sidecarURL(for: source) {
            do {
                try text.write(to: sidecar, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: sidecar.path)
                savedSidecar = true
            } catch {
                veloraLog("Velora: transcript sidecar write failed: \(error.localizedDescription)")
            }
        }
        showToast(
            symbol: "doc.text.fill",
            message: savedSidecar ? "Transcript copied · saved next to audio" : "Transcript copied")
    }

    /// "<name> transcript.txt", counting up ("… transcript 2.txt") instead of
    /// overwriting an existing (possibly user-edited) transcript.
    static func sidecarURL(for source: URL) -> URL? {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        for i in 1...99 {
            let name = i == 1 ? "\(base) transcript.txt" : "\(base) transcript \(i).txt"
            let candidate = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func fail(_ error: String) {
        let completion = agentCompletion
        reset()
        if let completion {
            completion(.failure(error == "cancelled" ? .cancelled : .failed(error)))
            return
        }
        let message = error == "cancelled" ? "Transcription cancelled" : "Transcription failed: \(error)"
        showToast(symbol: error == "cancelled" ? "xmark.circle.fill" : "exclamationmark.triangle.fill",
                  message: message)
    }

    private func reset() {
        ackTimer?.invalidate()
        ackTimer = nil
        progressLabel = nil
        sourceURL = nil
        jobID = nil
        requestedMode = nil
        agentRequestID = nil
        agentCompletion = nil
        onStateChange?()
    }

    private func matches(_ eventID: String?) -> Bool {
        eventID != nil && eventID == jobID
    }

    private func showToast(symbol: String, message: String) {
        guard hudIsFree() else { return }
        hud.transition(to: .notice(symbol: symbol, message: message))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self] in
            // Only hide OUR toast — a different notice shown meanwhile keeps
            // its own timer (review finding).
            guard let self,
                  case .notice(let s, let m) = self.hud.model.state,
                  s == symbol, m == message
            else { return }
            self.hud.transition(to: .hidden(.success))
        }
    }
}
