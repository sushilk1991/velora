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

enum DictationOutputFailure {
    static func message(for text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Couldn't transcribe that — try again"
            : nil
    }
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
    /// When the transcribe watchdog fired and showed "timed out". A late
    /// `final` is auto-inserted for a grace period; beyond it the result is
    /// preserved in History + clipboard without a surprise paste.
    private var timeoutErrorAt: Date?
    private static let lateFinalGrace: TimeInterval = 15
    /// The session the user explicitly cancelled (Esc / stuck-transcribe / error).
    /// A late `final` for this id must be ignored; a `final` for the current
    /// `sessionID` that is NOT this one is always honored, even if `phase`
    /// drifted (e.g. a missed hotkeyUp left us in `.recording`), so a valid
    /// transcription is never silently lost.
    private var cancelledSessionID: String?
    /// The session whose `final` we already inserted. Guards against a stray or
    /// duplicate `final` re-inserting text now that the phase guard is loose.
    private var consumedSessionID: String?
    private var sessionContext: AppContext?
    private var recordingStart: Date?
    private var transcribeStartedAt: Date?
    private var hotkeyDownAt: Date?
    private var rawTranscript: String?
    private var transcribeTimer: Timer?
    /// When set, the error HUD's action button runs this instead of retrying
    /// dictation (e.g. "Open Settings" for a missing Accessibility grant).
    private var errorRetryAction: (() -> Void)?
    /// A menubar "Reformat Last as…" round-trip in flight: the history row and
    /// the app to paste the re-formatted result back into.
    private var pendingReformat: (id: Int64, bundleID: String?)?
    /// The last successful insertion, for the "scratch that" voice command —
    /// undo is only offered into the SAME app, shortly after.
    private var lastInsertion: (bundleID: String?, at: Date)?
    private static let undoWindow: TimeInterval = 180
    /// Rich screen-context entities (title + nearby AX text) gathered in the
    /// background while the user speaks, attached to the `stop` command so the
    /// LLM cleanup can spell on-screen names right — with zero hot-path cost.
    private var richEntities: [ContextEntity] = []
    /// Increments per session so a slow background gather from a prior session
    /// can't clobber the current one.
    private var contextGatherGeneration = 0
    private let contextQueue = DispatchQueue(label: "com.velora.context", qos: .userInitiated)
    /// Learning loop: what we last inserted, so a later edit can be diffed into
    /// a learned correction.
    private let learning = LearningStore()
    private var pendingLearning: (element: AXUIElement, inserted: String, insertedWords: Set<String>)?
    /// Deferred re-check: `checkPendingLearning` normally runs when the NEXT
    /// dictation starts, so an edit made after the *last* dictation of a sitting
    /// would never be learned. This one-shot timer closes that gap.
    private var learningRecheckTimer: Timer?
    /// Long enough for the user to notice and fix a misheard word; short enough
    /// that the field usually still exists when we re-read it.
    private static let learningRecheckDelay: TimeInterval = 45
    /// Real-time path: an AX value-change watch on the pasted-into field, so an
    /// edit is learned seconds after the user makes it (the timer above stays
    /// as the fallback for apps whose fields don't emit value changes).
    private let editWatcher = EditWatcher()
    private var editDebounceTimer: Timer?
    /// Quiet period after the last observed keystroke before diffing — the
    /// user has likely finished fixing the word.
    private static let editDebounce: TimeInterval = 2.0
    /// Learning is scoped to compose-box-sized fields: we never diff a large
    /// document (can't isolate our span; would freeze on the hot path).
    private static let learningMaxWords = 60

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
        // Successful device-change recovery is silent (capture rebuilds and the
        // recording continues); this only fires when NO input could be
        // re-established (the last mic unplugged).
        capture.onDeviceLost = { [weak self] _ in
            guard let self, self.isRecording else { return }
            self.supervisor.send(["cmd": "cancel", "session": self.sessionID])
            self.cancelledSessionID = self.sessionID
            self.showError("Microphone disconnected")
        }
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

    // MARK: - Reformat last (menubar quick-override, off the hot path)

    /// Built-in modes offered in the "Reformat Last as…" menu.
    static let reformatModes = ["Default", "Message", "Email", "Note", "Code", "Raw"]

    /// True when there's a recent dictation with archived audio to re-run.
    var canReformatLast: Bool {
        history.recent(limit: 1).first?.audioPath != nil
    }

    /// Re-runs the most recent dictation's cleanup under a different mode and
    /// pastes the result back into the app it came from. Reuses the History
    /// reprocess round-trip — never touches the live dictation hot path, so it
    /// costs nothing per dictation (addresses the "override must stay fast"
    /// requirement: the mode choice happens after the fact, not before cleanup).
    func reformatLast(mode: String) {
        guard let record = history.recent(limit: 1).first, let audio = record.audioPath,
              FileManager.default.fileExists(
                  atPath: AppConfig.audioDirectory.appendingPathComponent(audio).path)
        else {
            showError("No recent dictation to reformat")
            return
        }
        pendingReformat = (record.id, record.bundleID)
        var cmd: [String: Any] = ["cmd": "reprocess", "audio": audio, "id": record.id, "mode": mode]
        if let bundleID = record.bundleID { cmd["bundle_id"] = bundleID }
        if let appName = record.appName { cmd["app_name"] = appName }
        supervisor.send(cmd)
        NSLog("Velora: reformat last id=%lld as %@", record.id, mode)
    }

    /// Pastes a completed "Reformat Last as…" result back into its origin app.
    private func applyReformat(id: Int64, raw: String, text: String, mode: String?) {
        guard let pending = pendingReformat, pending.id == id else { return }
        pendingReformat = nil
        history.updateAfterReprocess(id: id, raw: raw, final: text, mode: mode)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        inserter.copyToClipboard(text)
        if let bundleID = pending.bundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate(options: [.activateAllWindows])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                // Same rails as a live insertion (review finding): never
                // synthesize input without the grant, into a secure field, or
                // into an app other than the reformat's origin. The text is
                // already on the clipboard for a manual paste either way.
                guard Permissions.accessibilityGranted, TextInserter.canPostEvents,
                      !SecureInput.isActive,
                      NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
                else {
                    NSLog("Velora: reformat paste skipped — target not ready (text on clipboard)")
                    return
                }
                self.inserter.insert(text, targetBundleID: bundleID, mode: mode)
            }
        }
    }

    // MARK: - Learning loop (learn corrections from post-dictation edits)

    /// Remembers the focused field + exactly what we inserted, so a later edit
    /// can be diffed. Only for compose-box-sized insertions — we never learn
    /// from a big document (can't isolate our span and would freeze).
    private func captureLearningBaseline(text: String, bundleID: String?) {
        guard config.learnFromEdits else { return }
        let inserted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let insertedWords = Set(
            inserted.lowercased().split { $0 == " " || $0 == "\n" || $0 == "\t" }.map(String.init))
        guard insertedWords.count >= 1, insertedWords.count <= Self.learningMaxWords else {
            veloraLog("Velora: learning — baseline skipped (\(insertedWords.count) words)")
            return
        }
        // Let the ⌘V paste settle, then grab the focused element (main thread —
        // just a couple of timeout-capped AX calls).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            let app = bundleID.flatMap {
                NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
            } ?? NSWorkspace.shared.frontmostApplication
            guard let element = ScreenContext.focusedElement(of: app) else {
                veloraLog("Velora: learning — no focused AX element (app=\(app?.bundleIdentifier ?? "nil")), cannot watch edits")
                return
            }
            self.pendingLearning = (element, inserted, insertedWords)
            self.scheduleLearningRecheck()
            // Real-time: watch the field itself; edits evaluate a debounce
            // after the last keystroke instead of waiting for the 45s timer.
            self.editWatcher.onChange = { [weak self] in self?.scheduleEditEvaluation() }
            let watching = self.editWatcher.watch(element)
            veloraLog("Velora: learning — baseline set (\(insertedWords.count) words, watch=\(watching ? "live" : "timer-only"))")
        }
    }

    /// Debounces watcher events: evaluate ~2s after the LAST value change.
    private func scheduleEditEvaluation() {
        guard pendingLearning != nil else { return }
        editDebounceTimer?.invalidate()
        editDebounceTimer = Timer.scheduledTimer(
            withTimeInterval: Self.editDebounce, repeats: false
        ) { [weak self] _ in
            self?.evaluatePendingLearning(consume: false)
        }
    }

    /// Clears the baseline and every trigger watching it (one consume, ever).
    private func consumePendingLearning() {
        pendingLearning = nil
        learningRecheckTimer?.invalidate()
        learningRecheckTimer = nil
        editDebounceTimer?.invalidate()
        editDebounceTimer = nil
        editWatcher.stop()
    }

    /// Arms the one-shot deferred re-check (~45 s after insert). Main thread,
    /// like the rest of this class; superseding a previous timer keeps at most
    /// one re-check pending — always for the newest baseline.
    private func scheduleLearningRecheck() {
        learningRecheckTimer?.invalidate()
        learningRecheckTimer = Timer.scheduledTimer(
            withTimeInterval: Self.learningRecheckDelay, repeats: false
        ) { [weak self] _ in
            self?.checkPendingLearning()
        }
    }

    /// Consume-now entry point (next dictation start / 45s fallback timer).
    private func checkPendingLearning() {
        evaluatePendingLearning(consume: true)
    }

    /// Diffs what we inserted against the (possibly-edited) field and learns any
    /// word-for-word corrections. The AX read + diff run OFF the main thread so a
    /// wedged app can't stall the hotkey; only the store update touches main.
    ///
    /// `consume: false` (real-time watcher path) keeps the baseline alive while
    /// the edit yields no corrections — the user may just be typing MORE text —
    /// and consumes it on the first actual observation (re-observing the same
    /// pair per keystroke would double-count toward the 2-sighting threshold).
    private func evaluatePendingLearning(consume: Bool) {
        guard config.learnFromEdits, let pending = pendingLearning else {
            if consume { consumePendingLearning() }
            return
        }
        if consume { consumePendingLearning() }
        contextQueue.async { [weak self] in
            guard let self else { return }
            guard let edited = ScreenContext.stringValue(of: pending.element) else {
                veloraLog("Velora: learning — field unreadable at evaluate (consume=\(consume))")
                return
            }
            guard edited != pending.inserted else { return }  // untouched — nothing to learn yet
            // Size cap only (a real document never diffs; would freeze/mislead).
            // Fields BIGGER than the insertion are fine below the cap:
            // CorrectionDiff isolates the best-matching window itself, so a
            // TextEdit/Notes doc accumulating several dictations still learns.
            let editedWords = edited.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
            guard editedWords <= 400 else {
                veloraLog("Velora: learning — field too large to diff (\(editedWords) words)")
                return
            }

            let corrections = CorrectionDiff.corrections(baseline: pending.inserted, edited: edited)
                .filter { pending.insertedWords.contains($0.wrong.lowercased()) }
            guard !corrections.isEmpty else {
                veloraLog("Velora: learning — edit seen, no learnable 1:1 correction (consume=\(consume))")
                return
            }
            DispatchQueue.main.async {
                if !consume {
                    // A later trigger may have consumed the baseline while we
                    // were reading — never observe the same edit twice. Match
                    // by IDENTITY (the inserted text), not mere presence: a new
                    // dictation may have installed a fresh baseline meanwhile,
                    // and consuming THAT would kill its watcher (review
                    // finding).
                    guard self.pendingLearning?.inserted == pending.inserted else { return }
                    self.consumePendingLearning()
                }
                let committed = self.learning.observe(corrections.map { ($0.wrong, $0.right) })
                veloraLog("Velora: learning — \(corrections.count) correction(s) observed, \(committed.count) committed")
                if let first = committed.first {
                    self.supervisor.send(["cmd": "reload_config"])
                    self.showLearnedToast(first)
                }
            }
        }
    }

    /// Wispr-style feedback: the pill returns briefly with the mishearing
    /// struck through and the fix next to it. Only when nothing else is using
    /// the HUD — a toast must never stomp an active dictation.
    private func showLearnedToast(_ pair: (wrong: String, right: String)) {
        guard phase == .idle, hud.model.state.isHidden else { return }
        hud.transition(to: .learned(wrong: pair.wrong, right: pair.right))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            guard let self, case .learned = self.hud.model.state else { return }
            self.hud.transition(to: .hidden(.success))
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
            // First run: say WHAT is happening ("Downloading the speech model
            // (1.6 GB) — 42%") instead of a vague "starting…".
            showError(supervisor.loadingStatus ?? "Speech engine is starting…")
            return
        }

        // Learn from any edits the user made to the previous dictation before
        // starting a new one (they've clearly finished with it).
        checkPendingLearning()

        sessionID = UUID().uuidString
        rawTranscript = nil
        recordingStart = Date()
        timeoutErrorAt = nil  // a stale timeout must never drop THIS session's final

        // Context chip: the target app's actual icon + the client-side
        // detected mode label (ModeCategory mirrors the engine's map).
        let targetApp = contextTracker.frontmost ?? NSWorkspace.shared.frontmostApplication

        // Enrich the app context with on-screen entities (current file, the
        // person/channel you're messaging, …) via the Accessibility API, so the
        // engine can spell them right and, later, tag them. Cheap AX title read;
        // never blocks capture.
        var enriched = contextTracker.current
        enriched.entities = ScreenContext.entities(
            for: targetApp, category: ModeCategory.category(forBundleID: enriched.bundleID))
        sessionContext = enriched
        if !enriched.entities.isEmpty {
            // Log only types/count — never the values (subject lines, names,
            // page titles are private and would persist in the unified log).
            NSLog("Velora: screen context — %ld entities [%@]",
                  enriched.entities.count,
                  enriched.entities.map { $0.type }.joined(separator: ", "))
        }
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

        // Background pass: read richer nearby AX text (the person you're
        // replying to, field labels) while the user speaks. It's heavier than
        // the title read, so it runs off the main thread and is attached to the
        // `stop` command — ready by the time the user finishes talking, adding
        // nothing to the release→insert latency.
        contextGatherGeneration += 1
        let generation = contextGatherGeneration
        let gatherApp = targetApp
        let gatherCategory = ModeCategory.category(forBundleID: enriched.bundleID)
        richEntities = []
        contextQueue.async { [weak self] in
            let rich = ScreenContext.richEntities(for: gatherApp, category: gatherCategory)
            DispatchQueue.main.async {
                guard let self, self.contextGatherGeneration == generation else { return }
                self.richEntities = rich
            }
        }

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
        // Attach the background-gathered rich context (if it finished) so the
        // engine's cleanup sees the on-screen names. Falls back to the basic
        // title entities already sent with `start`.
        var stopCmd: [String: Any] = ["cmd": "stop", "session": sessionID]
        if !richEntities.isEmpty {
            stopCmd["entities"] = richEntities.map { $0.payload }
        }
        supervisor.send(stopCmd)
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
            self.timeoutErrorAt = Date()
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
        case .partial(let session, _):
            // Protocol-compatible progress only. Whisper partials are
            // provisional and must never compete with the authoritative final
            // inside the waveform-first HUD.
            guard session == sessionID, phase != .idle else { return }

        case .transcript(let session, let raw, _):
            guard session == sessionID else { return }
            rawTranscript = raw
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
            guard session == sessionID,
                  session != cancelledSessionID,
                  session != consumedSessionID
            else {
                NSLog("Velora: ignoring final for session=%@ (current=%@ cancelled=%@ consumed=%@)",
                      session, sessionID, cancelledSessionID ?? "none", consumedSessionID ?? "none")
                return
            }
            // Grace-bounded auto-insertion: a much later result must not land
            // in whatever the user is doing now, but it must not disappear.
            // Preserve it in History + clipboard and show a compact notice.
            let arrivedTooLate = timeoutErrorAt.map {
                -$0.timeIntervalSinceNow > Self.lateFinalGrace
            } ?? false
            if arrivedTooLate {
                NSLog("Velora: preserving late final without auto-paste — session=%@", session)
            }
            timeoutErrorAt = nil
            consumedSessionID = session  // one insertion per session; block duplicates
            NSLog("Velora: engine final session=%@ chars=%ld phase=%@", session, text.count, phase.label)
            transcribeTimer?.invalidate()
            transcribeTimer = nil
            // If we never observed the stop edge, capture is still running — stop
            // it now so the mic releases and we don't keep streaming audio.
            if isRecording { capture.stop() }
            finishInsertion(
                text: text, raw: raw.isEmpty ? (rawTranscript ?? text) : raw,
                mode: mode, cleanupMs: cleanupMs, audio: audio,
                allowAutomaticInsertion: !arrivedTooLate)

        case .reprocessed(let id, _, let raw, let text, let mode, _, _, _, _):
            // Only the menubar "Reformat Last as…" path is handled here; the
            // History tab consumes its own reprocess replies via notification.
            if let id, pendingReformat?.id == id {
                applyReformat(id: id, raw: raw, text: text, mode: mode)
            }

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

    private func finishInsertion(
        text: String,
        raw: String,
        mode: String?,
        cleanupMs: Int?,
        audio: String?,
        allowAutomaticInsertion: Bool = true
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = sessionContext

        if !allowAutomaticInsertion {
            if let message = DictationOutputFailure.message(for: trimmed) {
                if audio != nil {
                    recordHistory(
                        text: "", raw: raw, context: context, mode: mode,
                        cleanupMs: cleanupMs, audio: audio)
                }
                showError(message)
            } else {
                inserter.stageFinalOutput(text)
                recordHistory(
                    text: text, raw: raw, context: context, mode: mode,
                    cleanupMs: cleanupMs, audio: audio)
                phase = .idle
                showNotice(symbol: "doc.on.clipboard.fill", message: "Finished late — copied")
            }
            return
        }

        // Voice commands v1: an utterance that IS a command ("scratch that",
        // "new line") executes instead of pasting. Checked before the
        // empty-guard — cleanup can legitimately empty a bare retraction
        // phrase, and the command must still fire off the raw transcript.
        if config.voiceCommands, let command = VoiceCommand.parse(text: trimmed, raw: raw) {
            executeVoiceCommand(command)
            return
        }

        if let message = DictationOutputFailure.message(for: trimmed) {
            // A real recording that survives to `final` must never disappear
            // without feedback. The engine already retried recoverable prompt
            // hallucinations; retain archived audio so History can reprocess it.
            if audio != nil {
                recordHistory(
                    text: "", raw: raw, context: context, mode: mode,
                    cleanupMs: cleanupMs, audio: audio)
            }
            showError(message)
            return
        }

        // Clipboard delivery is the invariant; synthetic paste/typing is only
        // the convenience layer. Staging here covers own-window, paste,
        // typing, permission, secure-input, and focus-change paths while whole
        // utterance voice commands above remain commands rather than copied
        // prose.
        inserter.stageFinalOutput(text)

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
           inserter.insertIntoOwnWindow(text, mode: mode) {
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
            recordHistory(
                text: text, raw: raw, context: context, mode: mode,
                cleanupMs: cleanupMs, audio: audio)
            return
        }

        recordHistory(
            text: text, raw: raw, context: context, mode: mode,
            cleanupMs: cleanupMs, audio: audio)

        inserter.insert(
            text, targetBundleID: context?.bundleID, mode: mode
        ) { [weak self] inserted in
            guard let self else { return }
            guard inserted else {
                self.phase = .idle
                self.sounds.play(.error)
                self.showNotice(
                    symbol: "doc.on.clipboard.fill",
                    message: "Insertion interrupted — copied")
                return
            }
            self.hud.transition(to: .inserted)
            self.phase = .idle
            self.lastInsertion = (bundleID: context?.bundleID, at: Date())
            self.captureLearningBaseline(text: text, bundleID: context?.bundleID)
            NotificationCenter.default.post(name: .veloraDictationInserted, object: text)
            self.scheduleInsertedHide()
        }
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

    // MARK: - Voice commands

    /// Executes a whole-utterance voice command instead of pasting it.
    private func executeVoiceCommand(_ command: VoiceCommand) {
        phase = .idle
        guard Permissions.accessibilityGranted, TextInserter.canPostEvents,
              !SecureInput.isActive
        else {
            NSLog("Velora: voice command refused — cannot post events")
            hud.transition(to: .hidden(.cancel))
            return
        }
        switch command {
        case .undoLastInsertion:
            guard let last = lastInsertion,
                  -last.at.timeIntervalSinceNow <= Self.undoWindow,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == last.bundleID
            else {
                NSLog("Velora: voice command undo — nothing to undo here")
                showNotice(symbol: "xmark.circle.fill", message: "Nothing to undo")
                return
            }
            lastInsertion = nil  // one undo per insertion
            consumePendingLearning()  // never diff-learn from text we removed
            // Resolve semantic Z in the active layout — raw positional
            // keycode 6 would be ⌘W on AZERTY and close the window.
            inserter.pressKey(
                Hotkey.keyCode(for: "z") ?? 6,
                flags: .maskCommand)
            NSLog("Velora: voice command — undid last insertion")
            showNotice(symbol: "arrow.uturn.backward.circle.fill", message: "Undone")
        case .pressReturn, .newParagraph:
            // Same focus rail as the paste path: Return into an app the user
            // switched to mid-transcription could send a message or confirm a
            // dialog (review finding).
            if let target = sessionContext?.bundleID,
               NSWorkspace.shared.frontmostApplication?.bundleIdentifier != target {
                NSLog("Velora: voice command return — focus changed, skipped")
                hud.transition(to: .hidden(.cancel))
                return
            }
            inserter.pressKey(36)  // kVK_Return
            if command == .newParagraph { inserter.pressKey(36) }
            NSLog("Velora: voice command — return")
            hud.transition(to: .inserted)
            scheduleInsertedHide()
        }
    }

    /// Transient toast in the dictation flow (replaces whatever the HUD shows).
    private func showNotice(symbol: String, message: String) {
        hud.transition(to: .notice(symbol: symbol, message: message))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            // Only hide OUR toast — a different notice shown meanwhile keeps
            // its own timer.
            guard let self,
                  case .notice(let s, let m) = self.hud.model.state,
                  s == symbol, m == message
            else { return }
            self.hud.transition(to: .hidden(.success))
        }
    }

    /// Keep the compact Copied confirmation readable before it fades.
    private func scheduleInsertedHide() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
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
