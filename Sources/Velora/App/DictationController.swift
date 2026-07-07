import AppKit
import AVFoundation
import Foundation

/// Notification posted after text is successfully inserted (onboarding's
/// try-it step listens for this to gate "Finish").
extension Notification.Name {
    static let veloraDictationInserted = Notification.Name("VeloraDictationInserted")
}

/// Observes the dictation flow for UI (menubar icon states).
protocol DictationControllerDelegate: AnyObject {
    func dictationController(_ controller: DictationController, didChangePhase phase: DictationController.Phase)
}

/// The full dictation state machine: hotkey → HUD + audio + engine `start` →
/// release → `stop` → `final` event → insert → history. Main-thread only.
///
/// Hotkey semantics (hold mode, docs/SPEC.md):
/// - hold ≥ 0.35 s, release → transcribe (push-to-talk)
/// - double-tap (down-up-down within 0.35 s) → recording locks on;
///   the next tap (or Esc) ends it
/// - a single short tap that never becomes a double-tap → cancel
/// - Esc always cancels cleanly; nothing is inserted
final class DictationController: NSObject {
    enum Phase: Equatable {
        case idle
        case recording(locked: Bool)
        /// Short tap released; recording continues briefly awaiting a second
        /// tap (double-tap lock) before being cancelled.
        case awaitingSecondTap
        case transcribing
    }

    /// Hold shorter than this is a "tap"; also the double-tap window.
    private static let tapThreshold: TimeInterval = 0.35
    /// Give up on the engine this long after `stop`.
    private static let transcribeTimeout: TimeInterval = 20

    weak var delegate: DictationControllerDelegate?

    private let config = AppConfig.shared
    private let capture = AudioCapture()
    private let contextTracker: AppContextTracker
    private let hud: HUDPanel
    private let inserter = TextInserter()
    private let history: HistoryStore
    private let sounds: SoundPlayer
    private let supervisor: EngineSupervisor

    private(set) var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            delegate?.dictationController(self, didChangePhase: phase)
        }
    }

    private var sessionID = ""
    private var sessionContext: AppContext?
    private var recordingStart: Date?
    private var hotkeyDownAt: Date?
    private var rawTranscript: String?
    private var tapWindowTimer: Timer?
    private var transcribeTimer: Timer?

    init(
        supervisor: EngineSupervisor,
        contextTracker: AppContextTracker,
        hud: HUDPanel,
        history: HistoryStore,
        sounds: SoundPlayer
    ) {
        self.supervisor = supervisor
        self.contextTracker = contextTracker
        self.hud = hud
        self.history = history
        self.sounds = sounds
        super.init()
        hud.model.onRetry = { [weak self] in self?.retryFromError() }
    }

    var isRecording: Bool {
        switch phase {
        case .recording, .awaitingSecondTap: return true
        default: return false
        }
    }

    // MARK: - Menubar entry point

    /// Menubar "Start/Stop Dictation" — always toggle semantics.
    func toggleFromMenu() {
        switch phase {
        case .idle:
            startRecording(locked: true)
        case .recording, .awaitingSecondTap:
            stopAndTranscribe()
        case .transcribing:
            break
        }
    }

    // MARK: - Error retry

    private func retryFromError() {
        hud.transition(to: .hidden(.cancel))
        phase = .idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.startRecording(locked: true)
        }
    }

    // MARK: - Recording lifecycle

    private func startRecording(locked: Bool) {
        guard phase == .idle else { return }

        // Secure input (password fields): refuse with an error HUD.
        guard !SecureInput.isActive else {
            showError("Secure input active — dictation unavailable")
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            showError("Microphone access needed")
            return
        }
        guard supervisor.isReady else {
            showError("Speech engine is starting…")
            return
        }

        sessionID = UUID().uuidString
        sessionContext = contextTracker.current
        rawTranscript = nil
        recordingStart = Date()

        supervisor.send([
            "cmd": "start",
            "session": sessionID,
            "context": sessionContext?.payload ?? [:],
        ])

        hud.model.levels.reset()
        hud.model.recordingStart = recordingStart
        hud.transition(to: .listening)
        sounds.play(.start)

        let client = supervisor.client
        do {
            try capture.start(
                onChunk: { data in client.send(audio: data) },
                onLevel: { [weak self] level in self?.hud.model.levels.push(level) })
        } catch {
            supervisor.send(["cmd": "cancel", "session": sessionID])
            showError(error.localizedDescription)
            return
        }

        phase = .recording(locked: locked)
    }

    private func stopAndTranscribe() {
        guard isRecording else { return }
        tapWindowTimer?.invalidate()
        tapWindowTimer = nil

        capture.stop()
        sounds.play(.stop)
        supervisor.send(["cmd": "stop", "session": sessionID])
        hud.transition(to: .transcribing)
        phase = .transcribing

        transcribeTimer?.invalidate()
        transcribeTimer = Timer.scheduledTimer(
            withTimeInterval: Self.transcribeTimeout, repeats: false
        ) { [weak self] _ in
            guard let self, self.phase == .transcribing else { return }
            self.supervisor.send(["cmd": "cancel", "session": self.sessionID])
            self.showError("Transcription timed out")
        }
    }

    /// Esc or explicit cancel: stop everything, insert nothing.
    func cancel() {
        guard phase != .idle else { return }
        tapWindowTimer?.invalidate()
        tapWindowTimer = nil
        transcribeTimer?.invalidate()
        transcribeTimer = nil

        capture.stop()
        supervisor.send(["cmd": "cancel", "session": sessionID])
        hud.model.recordingStart = nil
        hud.transition(to: .hidden(.cancel))
        phase = .idle
    }

    private func showError(_ message: String) {
        capture.stop()
        transcribeTimer?.invalidate()
        transcribeTimer = nil
        tapWindowTimer?.invalidate()
        tapWindowTimer = nil
        sounds.play(.error)
        hud.transition(to: .error(message))
        phase = .idle
    }

    // MARK: - Engine events

    /// Routed here by the AppDelegate from the supervisor.
    func handleEngineEvent(_ event: EngineEvent) {
        switch event {
        case .transcript(let session, let raw, _):
            guard session == sessionID else { return }
            rawTranscript = raw

        case .final(let session, let text, let raw, let mode, let cleanupMs, _):
            guard session == sessionID, phase == .transcribing else { return }
            transcribeTimer?.invalidate()
            transcribeTimer = nil
            finishInsertion(
                text: text, raw: raw.isEmpty ? (rawTranscript ?? text) : raw,
                mode: mode, cleanupMs: cleanupMs)

        case .error(let session, let message):
            // Only errors scoped to the active session may end the dictation;
            // global or foreign-session errors are logged and ignored.
            if session == sessionID, phase != .idle {
                showError(message)
            } else {
                NSLog("Velora: engine error (session %@): %@", session ?? "none", message)
            }

        default:
            break
        }
    }

    /// Routed here by the AppDelegate on supervisor state changes: an engine
    /// crash or disconnect mid-dictation fails fast instead of leaving the
    /// user hanging until the transcribe timeout.
    func handleEngineStateChange(_ state: EngineSupervisor.State) {
        guard phase != .idle else { return }
        switch state {
        case .ready, .connecting:
            break
        case .stopped, .launching, .degraded:
            showError("Engine crashed — restarting")
        }
    }

    private func finishInsertion(text: String, raw: String, mode: String?, cleanupMs: Int?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Nothing recognized — treat as a quiet cancel, not an error.
            hud.transition(to: .hidden(.cancel))
            phase = .idle
            return
        }

        let context = sessionContext

        // Recheck the target immediately before synthesizing input: focus may
        // have moved (or a secure field taken over) while transcribing. Never
        // paste/type blind — fall back to the clipboard and tell the user.
        var fallbackMessage: String?
        if SecureInput.isActive {
            fallbackMessage = "Secure field — copied to clipboard"
        } else if let target = context?.bundleID,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier != target {
            fallbackMessage = "Focus changed — copied to clipboard"
        }

        if let fallbackMessage {
            inserter.copyToClipboard(text)
            sounds.play(.error)
            hud.transition(to: .error(fallbackMessage))
            phase = .idle
        } else {
            inserter.insert(text, targetBundleID: context?.bundleID)
            hud.transition(to: .inserted)
            phase = .idle
        }

        let durationMs = recordingStart.map { Int(-$0.timeIntervalSinceNow * 1000) } ?? 0
        history.insert(
            DictationRecord(
                timestamp: Date(),
                bundleID: context?.bundleID,
                appName: context?.appName,
                raw: raw,
                final: text,
                mode: mode,
                durationMs: durationMs,
                cleanupMs: cleanupMs))

        guard fallbackMessage == nil else { return }

        NotificationCenter.default.post(name: .veloraDictationInserted, object: text)

        // Inserted state holds 600 ms after the 150 ms flash + morph.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 + 0.6) { [weak self] in
            guard let self, self.hud.model.state == .inserted else { return }
            self.hud.model.recordingStart = nil
            self.hud.transition(to: .hidden(.success))
        }
    }
}

// MARK: - HotkeyMonitorDelegate

extension DictationController: HotkeyMonitorDelegate {
    func hotkeyDown() {
        switch (config.hotkeyMode, phase) {
        case (.toggle, .idle):
            startRecording(locked: true)
        case (.toggle, .recording), (.toggle, .awaitingSecondTap):
            stopAndTranscribe()
        case (.toggle, .transcribing):
            break

        case (.hold, .idle):
            hotkeyDownAt = Date()
            startRecording(locked: false)
        case (.hold, .awaitingSecondTap):
            // Second tap within the window → lock recording on.
            tapWindowTimer?.invalidate()
            tapWindowTimer = nil
            phase = .recording(locked: true)
        case (.hold, .recording(locked: true)):
            // Tap while locked → finish.
            stopAndTranscribe()
        case (.hold, .recording(locked: false)), (.hold, .transcribing):
            break
        }
    }

    func hotkeyUp() {
        guard config.hotkeyMode == .hold else { return }
        guard case .recording(locked: false) = phase else { return }

        let heldFor = hotkeyDownAt.map { -$0.timeIntervalSinceNow } ?? 0
        if heldFor >= Self.tapThreshold {
            stopAndTranscribe()
        } else {
            // Short tap: keep recording briefly; second tap locks, timeout cancels.
            phase = .awaitingSecondTap
            tapWindowTimer?.invalidate()
            tapWindowTimer = Timer.scheduledTimer(
                withTimeInterval: Self.tapThreshold, repeats: false
            ) { [weak self] _ in
                guard let self, self.phase == .awaitingSecondTap else { return }
                self.cancel()
            }
        }
    }

    func escapePressed() {
        switch phase {
        case .recording, .awaitingSecondTap, .transcribing:
            cancel()
        case .idle:
            // Dismiss a lingering error HUD.
            if case .error = hud.model.state {
                hud.transition(to: .hidden(.cancel))
            }
        }
    }
}
