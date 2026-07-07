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
/// - short tap (< 0.35 s) → recording locks on immediately;
///   the next tap (or Esc) stops it and transcribes
/// - Esc always cancels cleanly; nothing is inserted
final class DictationController: NSObject {
    enum Phase: Equatable {
        case idle
        case recording(locked: Bool)
        case transcribing

        /// Short label for log lines.
        var label: String {
            switch self {
            case .idle: return "idle"
            case .recording(let locked): return locked ? "recording(locked)" : "recording(hold)"
            case .transcribing: return "transcribing"
            }
        }
    }

    /// Hold shorter than this is a "tap" (which locks recording on).
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
            NSLog("Velora: phase %@ → %@", oldValue.label, phase.label)
            delegate?.dictationController(self, didChangePhase: phase)
        }
    }

    private var sessionID = ""
    /// The session the user explicitly cancelled (Esc / stuck-transcribe / error).
    /// A late `final` for this id must be ignored; a `final` for the current
    /// `sessionID` that is NOT this one is always honored, even if `phase`
    /// drifted (e.g. a missed hotkeyUp left us in `.recording`), so a valid
    /// transcription is never silently lost.
    private var cancelledSessionID: String?
    private var sessionContext: AppContext?
    private var recordingStart: Date?
    private var transcribeStartedAt: Date?
    private var hotkeyDownAt: Date?
    private var rawTranscript: String?
    private var transcribeTimer: Timer?
    /// When set, the error HUD's action button runs this instead of retrying
    /// dictation (e.g. "Open Settings" for a missing Accessibility grant).
    private var errorRetryAction: (() -> Void)?

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
        if case .recording = phase { return true }
        return false
    }

    // MARK: - Menubar entry point

    /// Menubar "Start/Stop Dictation" — always toggle semantics.
    func toggleFromMenu() {
        switch phase {
        case .idle:
            startRecording(locked: true)
        case .recording:
            stopAndTranscribe()
        case .transcribing:
            break
        }
    }

    // MARK: - Error retry

    private func retryFromError() {
        hud.transition(to: .hidden(.cancel))
        phase = .idle
        if let action = errorRetryAction {
            errorRetryAction = nil
            hud.model.retryTitle = "Retry"
            action()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.startRecording(locked: true)
        }
    }

    // MARK: - Recording lifecycle

    private func startRecording(locked: Bool) {
        guard phase == .idle else { return }

        // A fresh press supersedes any lingering error/fallback HUD: clear its
        // one-shot retry action so we start clean (the transition to
        // `.listening` below replaces the error visual).
        errorRetryAction = nil
        hud.model.retryTitle = "Retry"

        // Secure input (password fields): refuse with an error HUD.
        guard !SecureInput.isActive else {
            NSLog("Velora: recording refused — secure input active")
            showError("Secure input active — dictation unavailable")
            return
        }
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            NSLog("Velora: recording refused — mic auth status=%ld", micStatus.rawValue)
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            showError("Microphone access needed")
            return
        }
        guard supervisor.isReady else {
            NSLog("Velora: recording refused — engine not ready")
            showError("Speech engine is starting…")
            return
        }

        sessionID = UUID().uuidString
        sessionContext = contextTracker.current
        rawTranscript = nil
        recordingStart = Date()

        // Context chip: the target app's actual icon + the client-side
        // detected mode label (ModeCategory mirrors the engine's map).
        let targetApp = contextTracker.frontmost ?? NSWorkspace.shared.frontmostApplication
        hud.model.beginSession(context: HUDSessionContext(
            appIcon: targetApp?.icon,
            modeName: ModeCategory.displayName(forBundleID: sessionContext?.bundleID)))

        NSLog(
            "Velora: engine start session=%@ target=%@",
            sessionID, sessionContext?.bundleID ?? "unknown")
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
                onLevel: { [weak self] bands in self?.hud.model.levels.push(bands) })
        } catch {
            supervisor.send(["cmd": "cancel", "session": sessionID])
            showError(error.localizedDescription)
            return
        }

        phase = .recording(locked: locked)
    }

    private func stopAndTranscribe() {
        guard isRecording else { return }

        capture.stop()
        sounds.play(.stop)
        NSLog("Velora: engine stop session=%@", sessionID)
        supervisor.send(["cmd": "stop", "session": sessionID])
        hud.transition(to: .transcribing)
        phase = .transcribing
        armTranscribeTimeout()
    }

    /// (Re)arms the stop→final watchdog. Reset on `transcript` progress so a
    /// slow LLM cleanup after a long batch (whisper) decode doesn't trip it.
    /// A late `final` that arrives after this fires is still honored (see the
    /// `.final` handler) unless the user explicitly cancelled.
    private func armTranscribeTimeout() {
        transcribeStartedAt = Date()
        transcribeTimer?.invalidate()
        transcribeTimer = Timer.scheduledTimer(
            withTimeInterval: Self.transcribeTimeout, repeats: false
        ) { [weak self] _ in
            guard let self, self.phase == .transcribing else { return }
            NSLog("Velora: transcribe timeout — session=%@", self.sessionID)
            self.supervisor.send(["cmd": "cancel", "session": self.sessionID])
            self.showError("Transcription timed out")
        }
    }

    /// If we've been stuck in `.transcribing` past the timeout with no engine
    /// result, cancel the wedged session and return to `.idle` so the hotkey
    /// works again. Returns true when a reset happened.
    @discardableResult
    private func resetIfStuckTranscribing() -> Bool {
        guard phase == .transcribing else { return false }
        let elapsed = transcribeStartedAt.map { -$0.timeIntervalSinceNow } ?? 0
        guard elapsed >= Self.transcribeTimeout else { return false }
        NSLog("Velora: hotkey while stuck transcribing %.1fs — self-resetting", elapsed)
        transcribeTimer?.invalidate()
        transcribeTimer = nil
        supervisor.send(["cmd": "cancel", "session": sessionID])
        hud.model.recordingStart = nil
        hud.transition(to: .hidden(.cancel))
        phase = .idle
        return true
    }

    /// Esc or explicit cancel: stop everything, insert nothing.
    func cancel() {
        guard phase != .idle else { return }
        transcribeTimer?.invalidate()
        transcribeTimer = nil

        // Mark this session cancelled so a late `final` for it is refused
        // (the user explicitly gave up on it).
        cancelledSessionID = sessionID
        capture.stop()
        NSLog("Velora: engine cancel session=%@", sessionID)
        supervisor.send(["cmd": "cancel", "session": sessionID])
        hud.model.recordingStart = nil
        hud.transition(to: .hidden(.cancel))
        phase = .idle
    }

    private func showError(_ message: String) {
        capture.stop()
        transcribeTimer?.invalidate()
        transcribeTimer = nil
        errorRetryAction = nil
        hud.model.retryTitle = "Retry"
        NSLog("Velora: error HUD — %@", message)
        sounds.play(.error)
        hud.transition(to: .error(message))
        phase = .idle
    }

    // MARK: - Engine events

    /// Routed here by the AppDelegate from the supervisor.
    func handleEngineEvent(_ event: EngineEvent) {
        switch event {
        case .partial(let session, let text):
            // Live transcript: stream the running partial into the HUD pill.
            guard session == sessionID, phase != .idle else { return }
            if hud.model.transcriptTail.isEmpty, !text.isEmpty {
                NSLog("Velora: first partial session=%@ chars=%ld", session, text.count)
            }
            hud.model.updatePartial(text)

        case .transcript(let session, let raw, _):
            guard session == sessionID else { return }
            rawTranscript = raw
            // Keep the final recognized text visible under the transcribing
            // shimmer even if no partial covered the last words.
            hud.model.updatePartial(raw)
            // Progress signal: the engine has decoded and is now formatting.
            // Refresh the timeout so a slow LLM cleanup after a long batch
            // transcription doesn't trip the stop→final deadline.
            if phase == .transcribing { armTranscribeTimeout() }

        case .final(let session, let text, let raw, let mode, let cleanupMs, _, let audio):
            // Honor a valid final for the CURRENT session even if phase drifted
            // from .transcribing — a missed hotkeyUp can leave us in .recording,
            // or a timeout can have reset us to .idle. The only final we refuse
            // is one for a session the user explicitly cancelled. Never silently
            // lose a real transcription.
            guard session == sessionID, session != cancelledSessionID else {
                NSLog("Velora: ignoring final for session=%@ (current=%@ cancelled=%@)",
                      session, sessionID, cancelledSessionID ?? "none")
                return
            }
            NSLog("Velora: engine final session=%@ chars=%ld phase=%@", session, text.count, phase.label)
            transcribeTimer?.invalidate()
            transcribeTimer = nil
            // If we never observed the stop edge, capture is still running — stop
            // it now so the mic releases and we don't keep streaming audio.
            if isRecording { capture.stop() }
            finishInsertion(
                text: text, raw: raw.isEmpty ? (rawTranscript ?? text) : raw,
                mode: mode, cleanupMs: cleanupMs, audio: audio)

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

    private func finishInsertion(text: String, raw: String, mode: String?, cleanupMs: Int?, audio: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Nothing recognized — treat as a quiet cancel, not an error.
            hud.transition(to: .hidden(.cancel))
            phase = .idle
            return
        }

        let context = sessionContext

        // Own-window insertion (onboarding try-it): the TextEditor lives inside
        // Velora's own window. AppContextTracker deliberately ignores Velora's
        // own activations, so `context.bundleID` is some *other* app while the
        // real frontmost is us — the "focus changed" guard below would always
        // divert to the clipboard and nothing would land in the box. When we
        // ourselves are frontmost, insert straight into our key window's
        // focused text view via the responder chain (zero TCC), skip the
        // fallback, and still fire the inserted notification.
        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.velora.app"
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ownBundleID,
           inserter.insertIntoOwnWindow(text) {
            NSLog("Velora: insert method=own-window session=%@ chars=%ld", sessionID, text.count)
            errorRetryAction = nil
            hud.model.retryTitle = "Retry"
            hud.transition(to: .inserted)
            phase = .idle
            recordHistory(text: text, raw: raw, context: context, mode: mode, cleanupMs: cleanupMs, audio: audio)
            NotificationCenter.default.post(name: .veloraDictationInserted, object: text)
            scheduleInsertedHide()
            return
        }

        // Recheck the target immediately before synthesizing input: the
        // Accessibility grant may be missing (posting CGEvents would silently
        // no-op), focus may have moved, or a secure field taken over while
        // transcribing. Never paste/type blind — fall back to the clipboard
        // and tell the user.
        let trusted = Permissions.accessibilityGranted
        let canPost = TextInserter.canPostEvents
        var fallbackMessage: String?
        var isPermissionFallback = false
        if !trusted || !canPost {
            NSLog(
                "Velora: insertion blocked — accessibility trusted=%@ canPostEvents=%@",
                trusted ? "yes" : "no", canPost ? "yes" : "no")
            fallbackMessage = "Permission needed — text copied to clipboard"
            isPermissionFallback = true
        } else if SecureInput.isActive {
            fallbackMessage = "Secure field — copied to clipboard"
        } else if let target = context?.bundleID,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier != target {
            fallbackMessage = "Focus changed — copied to clipboard"
        }

        if let fallbackMessage {
            NSLog("Velora: insert fallback session=%@ — %@", sessionID, fallbackMessage)
            inserter.copyToClipboard(text)
            errorRetryAction = nil
            hud.model.retryTitle = "Retry"
            if isPermissionFallback {
                // The error HUD's action button opens the Accessibility pane
                // (after re-registering the TCC prompt for this signature).
                hud.model.retryTitle = "Open Settings"
                errorRetryAction = {
                    Permissions.promptAccessibility()
                    Permissions.openAccessibilitySettings()
                }
            }
            sounds.play(.error)
            hud.transition(to: .error(fallbackMessage))
            phase = .idle
        } else {
            inserter.insert(text, targetBundleID: context?.bundleID)
            hud.transition(to: .inserted)
            phase = .idle
        }

        recordHistory(text: text, raw: raw, context: context, mode: mode, cleanupMs: cleanupMs, audio: audio)

        guard fallbackMessage == nil else { return }

        NotificationCenter.default.post(name: .veloraDictationInserted, object: text)
        scheduleInsertedHide()
    }

    private func recordHistory(
        text: String, raw: String, context: AppContext?, mode: String?, cleanupMs: Int?, audio: String?
    ) {
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
                cleanupMs: cleanupMs,
                audioPath: audio))
    }

    /// Inserted state holds 600 ms after the 150 ms flash + morph, then hides.
    private func scheduleInsertedHide() {
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
        // Self-heal a wedged transcribe: normally `transcribeTimer` recovers,
        // but a missed event or a hung engine shouldn't strand the hotkey. If
        // we're still transcribing well past the timeout, reset to idle first
        // so this press starts a fresh dictation instead of being swallowed.
        if phase == .transcribing { resetIfStuckTranscribing() }

        switch (config.hotkeyMode, phase) {
        case (.toggle, .idle):
            startRecording(locked: true)
        case (.toggle, .recording):
            stopAndTranscribe()
        case (.toggle, .transcribing):
            break

        case (.hold, .idle):
            hotkeyDownAt = Date()
            startRecording(locked: false)
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
            // Short tap: recording locks on; the next tap (or Esc) ends it.
            NSLog("Velora: tap (%.0f ms) — recording locked on", heldFor * 1000)
            phase = .recording(locked: true)
        }
    }

    func escapePressed() {
        switch phase {
        case .recording, .transcribing:
            cancel()
        case .idle:
            // Dismiss a lingering error HUD.
            if case .error = hud.model.state {
                hud.transition(to: .hidden(.cancel))
            }
        }
    }
}
