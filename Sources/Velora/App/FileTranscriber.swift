import AppKit
import Foundation
import UniformTypeIdentifiers

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
        guard !isTranscribing else { return }
        guard supervisor.isReady else {
            // EngineClient silently drops writes while disconnected — the job
            // would never start and the menu would stick on "Preparing…".
            showToast(symbol: "hourglass", message: "Speech engine is starting — try again in a moment")
            return
        }
        sourceURL = url
        progressLabel = "Preparing…"
        onStateChange?()
        veloraLog("Velora: transcribe_file requested (\(url.pathExtension), \((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) bytes)")
        supervisor.send(["cmd": "transcribe_file", "path": url.path, "id": UUID().uuidString])
        // The engine acks immediately (before decoding); no ack = the command
        // was lost in a reconnect window.
        ackTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            guard let self, self.isTranscribing else { return }
            veloraLog("Velora: transcribe_file never acknowledged — clearing")
            self.fail("engine did not respond")
        }
    }

    func cancel() {
        guard isTranscribing else { return }
        supervisor.send(["cmd": "transcribe_cancel"])
    }

    // MARK: - Engine events (routed by the AppDelegate)

    func handle(_ event: EngineEvent) {
        switch event {
        case .transcribeAccepted:
            ackTimer?.invalidate()
            ackTimer = nil
        case .transcribeStarted(_, let durationS, let chunks):
            // Ghost guard: after a local failure (engine restart) a surviving
            // engine job must not resurrect the UI — its events are ignored.
            guard isTranscribing else { return }
            ackTimer?.invalidate()
            ackTimer = nil
            progressLabel = chunks > 1 ? "Transcribing… 0%" : "Transcribing…"
            onStateChange?()
            veloraLog("Velora: transcribe_file started (\(Int(durationS))s audio, \(chunks) chunks)")
        case .transcribeProgress(_, let fraction):
            guard isTranscribing else { return }
            progressLabel = "Transcribing… \(Int((fraction * 100).rounded()))%"
            onStateChange?()
        case .transcribed(_, _, let text, let sttMs):
            guard isTranscribing else { return }
            veloraLog("Velora: transcribe_file done (\(text.count) chars, \(sttMs)ms)")
            finish(text: text)
        case .transcribeFailed(_, let error):
            guard isTranscribing else { return }
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

    private func finish(text: String) {
        let source = sourceURL
        reset()
        guard !text.isEmpty else {
            showToast(symbol: "exclamationmark.triangle.fill", message: "No speech found in file")
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
        reset()
        let message = error == "cancelled" ? "Transcription cancelled" : "Transcription failed: \(error)"
        showToast(symbol: error == "cancelled" ? "xmark.circle.fill" : "exclamationmark.triangle.fill",
                  message: message)
    }

    private func reset() {
        ackTimer?.invalidate()
        ackTimer = nil
        progressLabel = nil
        sourceURL = nil
        onStateChange?()
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
