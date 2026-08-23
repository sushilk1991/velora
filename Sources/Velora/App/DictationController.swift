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

/// Decides when an error makes every later engine final unsafe to consume.
/// Normal user dictation keeps its short late-final grace period, but external
/// requests and Voice Edit must fail closed: their final is either API output
/// or a spoken instruction, never ordinary text to auto-paste.
enum LateFinalPolicy {
    static func commandMayExecute(allowAutomaticInsertion: Bool) -> Bool {
        allowAutomaticInsertion
    }

    static func errorCancelsSession(
        _ failedSession: String,
        editInstructionSession: String?,
        externalRequestSession: String?,
        actionInstructionSession: String?
    ) -> Bool {
        editInstructionSession == failedSession
            || externalRequestSession == failedSession
            || actionInstructionSession == failedSession
    }
}

enum ErrorRetryIntent: Equatable {
    case dictation
    case voiceEdit

    static func resolve(
        explicit: ErrorRetryIntent?,
        failedSession: String,
        editInstructionSession: String?
    ) -> ErrorRetryIntent {
        if let explicit { return explicit }
        return editInstructionSession == failedSession ? .voiceEdit : .dictation
    }

    func perform(
        dictation: () -> Void,
        voiceEdit: () -> Void
    ) {
        switch self {
        case .dictation: dictation()
        case .voiceEdit: voiceEdit()
        }
    }
}

struct ExternalDictationResult {
    let text: String
    let mode: String?
    let durationMs: Int
}

enum ExternalDictationError: LocalizedError {
    case denied
    case busy
    case unavailable(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .denied: return "The user denied this listening request"
        case .busy: return "Velora is already recording or transcribing"
        case .unavailable(let message): return message
        case .cancelled: return "The listening request was cancelled"
        }
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
        case starting(locked: Bool)
        case recording(locked: Bool)
        case transcribing

        /// Short label for log lines.
        var label: String {
            switch self {
            case .idle: return "idle"
            case .starting(let locked): return locked ? "starting(locked)" : "starting(hold)"
            case .recording(let locked): return locked ? "recording(locked)" : "recording(hold)"
            case .transcribing: return "transcribing"
            }
        }
    }

    /// Hold shorter than this is a "tap" (which locks recording on).
    private static let tapThreshold: TimeInterval = 0.35

    enum DelayedEditCaptureRelease: Equatable {
        case lockRecording
        case cancel
    }

    static func delayedEditCaptureRelease(
        heldFor: TimeInterval
    ) -> DelayedEditCaptureRelease {
        heldFor < tapThreshold ? .lockRecording : .cancel
    }
    /// Short dictations keep the existing 20-second watchdog. A recovery
    /// whole-clip decode after a long recording needs a duration-scaled budget;
    /// otherwise the app reports a false timeout while the engine is still
    /// preserving the transcript.
    private static let minimumTranscribeTimeout: TimeInterval = 20
    private static let maximumTranscribeTimeout: TimeInterval = 600
    static func transcribeTimeout(recordingDurationMs: Int?) -> TimeInterval {
        let recordingSeconds = Double(max(0, recordingDurationMs ?? 0)) / 1_000
        return min(
            maximumTranscribeTimeout,
            max(minimumTranscribeTimeout, recordingSeconds * 0.1))
    }

    static func recordingLimitMessage(seconds: Double) -> String {
        let total = max(1, Int(seconds.rounded()))
        if total.isMultiple(of: 3_600) {
            return "\(total / 3_600)-hour dictation limit reached"
        }
        if total >= 3_600 {
            return "\(total / 3_600)h \((total % 3_600) / 60)m dictation limit reached"
        }
        if total.isMultiple(of: 60) {
            return "\(total / 60)-minute dictation limit reached"
        }
        return "\(total)-second dictation limit reached"
    }
    /// Edit round-trip ceiling — above the engine's own 20 s edit budget so
    /// the engine's `edit_failed` normally arrives first; this only fires if
    /// the reply is lost entirely.
    private static let editTimeout: TimeInterval = 25

    weak var delegate: DictationControllerDelegate?
    /// App-owned foreground capture exclusion (currently meeting recording).
    /// Post-meeting background processing does not block dictation.
    var recordingBlockReason: (() -> String?)?

    private let config = AppConfig.shared
    private let capture = AudioCapture()
    private let mediaPlayback = MediaPlaybackCoordinator()
    private let contextTracker: AppContextTracker
    private let hud: HUDPanel
    private let inserter = TextInserter()
    private let history: HistoryStore
    private let sounds: SoundPlayer
    private let supervisor: EngineSupervisor
    private let dictionary: DictionaryRepository
    private var externalInsertionObserver: NSObjectProtocol?

    /// Action Mode stays uninitialized until an action actually starts. Plain
    /// dictation may consult actionsStorage to enforce input exclusion without
    /// paying ledger setup on the hotkey-to-microphone path.
    private var actionsStorage: AgentSessionManager?
    private var actions: AgentSessionManager {
        if let actionsStorage { return actionsStorage }
        // The routing host adds background delivery (via the user-installed
        // Cua Driver) around the classic foreground host; with the driver
        // absent or the setting off it IS the classic host.
        let manager = AgentSessionManager(
            client: supervisor.client,
            host: BackgroundRoutingActionHost(
                system: SystemActionHost(inserter: inserter),
                transport: CuaSocketTransport(),
                backgroundEnabled: { [config] in
                    config.backgroundActions && CuaDriver.isInstalled
                }))
        actionsStorage = manager
        return manager
    }
    /// The dictation session whose transcript is a command, not text to insert.
    private var actionSession: String?
    /// Opt-in session whose provisional transcript owns a bounded live draft
    /// at the original text cursor.
    private var streamSession: (
        session: String, draft: LiveStreamDraftSession, mode: String?)?
    /// Keeps a cancelled session alive until any in-flight Unicode delivery
    /// has finished and its still-owned original selection is restored.
    private var streamCancellation: (
        session: String, draft: LiveStreamDraftSession, mode: String?)?
    private struct DeferredStreamFinal {
        let session: String
        let text: String
        let raw: String
        let mode: String?
        let cleanupMs: Int?
        let cleanupApplied: Bool?
        let cleanupWallMs: Int?
        let finalizationMs: Int?
        let audio: String?
        let allowAutomaticInsertion: Bool
    }
    private var deferredStreamFinal: DeferredStreamFinal?
    /// Identity of the CLI request that owns the running action, if any.
    private var actionRequestID: UUID?
    /// Names harvested off the screen while the command was being spoken.
    private var actionScreenNames: [String] = []
    /// The app that was frontmost when the command was spoken. Captured at
    /// session start because Velora's own HUD may take focus afterwards, and
    /// "this window" in a command means the user's window, not ours.
    private var actionOriginApp: NSRunningApplication?

    private(set) var phase: Phase = .idle {
        didSet {
            guard phase != oldValue else { return }
            NSLog("Velora: phase %@ → %@", oldValue.label, phase.label)
            delegate?.dictationController(self, didChangePhase: phase)
            if phase == .idle {
                schedulePendingRecordingLimitNotice()
                flushDeferredLearnedToastIfPossible()
            }
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
    /// Speaking time is frozen when capture stops. History and time-saved
    /// metrics must not count STT/cleanup latency as time spent speaking.
    private var recordingDurationMs: Int?
    private var transcribeStartedAt: Date?
    private var activeTranscribeTimeout = minimumTranscribeTimeout
    private var autoStopLimitSeconds: Double?
    private var pendingRecordingLimitNoticeSeconds: Double?
    private var recordingLimitNoticeScheduled = false
    private var hotkeyDownAt: Date?
    /// A hold-to-talk release can arrive while macOS is still negotiating a
    /// Bluetooth input route. Finish immediately once capture becomes ready.
    private var stopAfterCaptureStarts = false
    private var rawTranscript: String?
    /// STT decode latency from this session's `transcript` event, persisted
    /// with the history row (the live `final` event doesn't carry it).
    private var sttMs: Int?
    private var transcribeTimer: Timer?
    private var captureStartTimer: Timer?
    /// When set, the error HUD's action button runs this instead of retrying
    /// dictation (e.g. "Open Settings" for a missing Accessibility grant).
    private var errorRetryAction: (() -> Void)?
    /// Default Retry routing when no one-off action overrides the button.
    private var errorRetryIntent: ErrorRetryIntent = .dictation
    /// A menubar "Reformat Last as…" round-trip in flight: the history row and
    /// the app to paste the re-formatted result back into.
    private var pendingReformat: (id: Int64, bundleID: String?)?
    /// Safe Voice Edit: the recording session whose transcript is an edit
    /// INSTRUCTION for `selection`, not text to paste.
    private var editSession: (
        session: String, selection: ScreenTextSelection, bundleID: String?)?
    /// The engine `edit_text` round-trip in flight after an edit session's
    /// final: verify-and-replace happens when `edited` comes back.
    private var pendingEdit: (
        id: String, selection: ScreenTextSelection, bundleID: String?)?
    /// Sublime selection capture and replacement use its plugin host, never
    /// the app's main thread. IDs make late callbacks one-shot and ignorable.
    private var sublimeCaptureID: UUID?
    private var sublimeCaptureLocksRecording = false
    private var sublimeCaptureReleasedBeforeStart = false
    private var sublimeApplyID: UUID?
    private var sublimeApplyingToken: SublimeTextSelectionToken?
    private let sublimeQueue = DispatchQueue(
        label: "com.velora.sublime-voice-edit",
        qos: .userInitiated)
    /// Self-contained watchdog for the edit round-trip — kept separate from
    /// the dictation transcribe timer so an unrelated failure's showError
    /// never discards a valid in-flight edit.
    private var editTimer: Timer?
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
    /// a learned correction. `session` keys the history row's quality
    /// observation (the async insert never reports a rowid).
    private var pendingLearning: (
        element: AXUIElement, inserted: String, insertedTokens: Set<String>, session: String)?
    /// Deferred re-check for apps whose fields do not emit AX value changes.
    private var learningRecheckTimer: Timer?
    /// Long enough for the user to notice and fix a misheard word; short enough
    /// that the field usually still exists when we re-read it.
    private static let learningRecheckDelay: TimeInterval = 60
    /// Real-time path: an AX value-change watch on the pasted-into field, so an
    /// edit is learned seconds after the user makes it (the timer above stays
    /// as the fallback for apps whose fields don't emit value changes).
    private let editWatcher = EditWatcher()
    private var editDebounceTimer: Timer?
    /// Quiet period after the last observed keystroke before diffing — the
    /// user has likely finished fixing the word.
    private static let editDebounce: TimeInterval = 2.0
    /// Learning is scoped to bounded fields: both the controller and diff stop
    /// after the same number of normalized tokens.
    private static let learningMaxTokens = CorrectionDiff.maxTokens
    /// A committed correction may arrive while recording or while a higher
    /// priority HUD result is visible. Keep only the newest deferred toast.
    private var deferredLearnedToast: (wrong: String, right: String)?
    /// One externally requested dictation may be active at a time. It remains
    /// tied to the exact engine session approved by the user, so a late or
    /// foreign event can never satisfy the requester.
    private var externalRequest: (
        requestID: UUID,
        session: String,
        completion: (Result<ExternalDictationResult, ExternalDictationError>) -> Void
    )?
    private var externalApproval: (
        requestID: UUID,
        alertToken: UUID,
        completion: (Result<ExternalDictationResult, ExternalDictationError>) -> Void
    )?
    /// Terminal lifecycle gate. Once AppKit begins quitting, neither a queued
    /// consent response nor a late menu/hotkey event may reopen the microphone.
    private var terminating = false

    init(
        supervisor: EngineSupervisor,
        contextTracker: AppContextTracker,
        hud: HUDPanel,
        history: HistoryStore,
        sounds: SoundPlayer,
        dictionary: DictionaryRepository
    ) {
        self.supervisor = supervisor
        self.contextTracker = contextTracker
        self.hud = hud
        self.history = history
        self.sounds = sounds
        self.dictionary = dictionary
        super.init()
        ModeApplicationIndex.shared.reload()
        externalInsertionObserver = NotificationCenter.default.addObserver(
            forName: .veloraExternalTextInsertion, object: nil, queue: .main
        ) { [weak self] _ in
            self?.inserter.resetContinuationContext()
        }
        hud.model.onRetry = { [weak self] in self?.retryFromError() }
        // The direct device adapter reports runtime interruption or removal;
        // a failed microphone cannot leave a silent "recording" HUD alive.
        capture.onDeviceLost = { [weak self] _ in
            guard let self else { return }
            guard case .starting = self.phase else {
                guard self.isRecording else { return }
                self.supervisor.send(["cmd": "cancel", "session": self.sessionID])
                self.cancelledSessionID = self.sessionID
                self.showError("Microphone disconnected")
                return
            }
            self.supervisor.send(["cmd": "cancel", "session": self.sessionID])
            self.cancelledSessionID = self.sessionID
            self.showError("Microphone could not start")
        }
    }

    deinit {
        if let externalInsertionObserver {
            NotificationCenter.default.removeObserver(externalInsertionObserver)
        }
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    /// User-owned foreground work that an updater relaunch must not cancel.
    /// Edit-learning timers are intentionally excluded: their durable input
    /// is already saved and they are safe to resume on a later edit.
    var hasUserOperationInFlight: Bool {
        phase != .idle
            || pendingReformat != nil
            || pendingEdit != nil
            || sublimeCaptureID != nil
            || sublimeApplyID != nil
            || externalApproval != nil
            || streamCancellation != nil
            // An action drives other apps' windows; relaunching Velora
            // underneath a half-run plan would strand it mid-message.
            || actionsStorage?.isRunning == true
    }

    // MARK: - Menubar entry point

    /// Menubar "Start/Stop Dictation" — always toggle semantics.
    func toggleFromMenu() {
        switch phase {
        case .idle:
            startRecording(locked: true)
        case .starting:
            cancel()
        case .recording:
            stopAndTranscribe()
        case .transcribing:
            break
        }
    }

    // MARK: - Action Mode

    /// Plan (and optionally carry out) one spoken command.
    ///
    /// The frontmost app is snapshotted BEFORE anything of Velora's can take
    /// focus: the planner's whole job is deciding what "this window" and "the
    /// app I'm in" mean, and by the time a plan comes back the answer may have
    /// changed.
    func performAction(
        command: String,
        execute: Bool,
        allowSend: Bool = false,
        requestID: UUID? = nil,
        completion: @escaping (Result<[String: Any], ControlFailure>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !terminating else {
            completion(.failure(ControlFailure(
                code: "app_unavailable", message: "Velora is shutting down")))
            return
        }
        guard !StreamInteractionGate.actionRequestIsBusy(
            phaseIsIdle: phase == .idle,
            cancellationInFlight: streamCancellation != nil,
            actionIsRunning: actionsStorage?.isRunning == true
        ) else {
            completion(.failure(ControlFailure(
                code: "busy", message: "Velora is busy right now")))
            return
        }
        if execute {
            guard Permissions.accessibilityGranted, TextInserter.canPostEvents else {
                completion(.failure(ControlFailure(
                    code: "permission_required",
                    message: "Action Mode needs Accessibility permission to control apps")))
                return
            }
            guard !SecureInput.isActive else {
                completion(.failure(ControlFailure(
                    code: "secure_input",
                    message: "A password field is active; keystrokes are blocked")))
                return
            }
        }
        let frontmost = contextTracker.frontmost ?? NSWorkspace.shared.frontmostApplication
        let context = ActionContextSnapshot.capture(
            frontmost: frontmost,
            windowTitle: ScreenContext.windowTitle(of: frontmost),
            selection: ScreenContext.selectedText(of: frontmost)?.text ?? "",
            screenNames: ScreenContext.visibleNames(of: frontmost),
            pageURL: actionPageURL(of: frontmost))

        actionRequestID = requestID
        actions.perform(
            transcript: command, context: context, execute: execute, allowSend: allowSend
        ) { [weak self] result in
            self?.actionRequestID = nil
            switch result {
            case .planned(let plan):
                // The harvested names are reported so a wrong-name plan can be
                // diagnosed: an empty list means the target app's window was
                // never read, which is a different bug from the model ignoring
                // the names it was given.
                var payload = plan.payload
                payload["screen_names"] = context.screenNames
                completion(.success(["ok": true, "executed": false, "plan": payload]))
            case .needsSendApproval(let plan):
                completion(.failure(ControlFailure(
                    code: "send_not_allowed",
                    message: "This plan sends a message. Re-run with --allow-send if "
                        + "that is what you want: " + plan.describedSteps.joined(separator: " → "))))
            case .completed, .performedUnverified:
                guard let payload = result.controlSuccessPayload(execute: execute) else {
                    completion(.failure(ControlFailure(
                        code: "action_failed", message: "Action result was unavailable")))
                    return
                }
                completion(.success(payload))
            case .cancelled:
                completion(.failure(ControlFailure(
                    code: "cancelled", message: "The action was cancelled")))
            case .failed(let reason, let trace):
                completion(.failure(ControlFailure(
                    code: "action_failed",
                    message: trace.isEmpty ? reason
                        : "\(reason) [\(trace.joined(separator: " → "))]")))
            }
        }
    }

    /// Page URL for the action planner's first-turn context — browsers only,
    /// same policy as the per-turn observation.
    private func actionPageURL(of app: NSRunningApplication?) -> String {
        guard ActionRuntimePolicy.isBrowserBundle(app?.bundleIdentifier) else { return "" }
        return ScreenContext.pageURL(of: app, deep: true)?.absoluteString ?? ""
    }

    /// Cancels the running action. With a `requestID`, only the action that
    /// request started — a client that was refused as busy must not be able to
    /// cancel the plan it lost the race to.
    func cancelAction(requestID: UUID? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let requestID, actionRequestID != requestID { return }
        actionsStorage?.cancel()
    }

    /// Runs a command spoken through the Action hotkey. Unlike the CLI path
    /// this always executes — the user held a dedicated key and spoke an
    /// instruction, which is the consent.
    private func runVoiceAction(_ command: String) {
        let origin = actionOriginApp
        actionOriginApp = nil
        guard !command.isEmpty else {
            showError("Didn't catch a command")
            return
        }
        guard !SecureInput.isActive else {
            showError("A password field is active — actions are blocked")
            return
        }
        let names = actionScreenNames
        actionScreenNames = []
        let context = ActionContextSnapshot.capture(
            frontmost: origin,
            windowTitle: ScreenContext.windowTitle(of: origin),
            selection: ScreenContext.selectedText(of: origin)?.text ?? "",
            screenNames: names,
            pageURL: actionPageURL(of: origin))
        showNotice(symbol: "wand.and.stars", message: "Working on it…")
        NSLog("Velora: voice action — %@", command)
        // allowSend: holding the Action hotkey and speaking the command is the
        // consent. Esc aborts while it runs.
        actions.perform(transcript: command, context: context,
                        execute: true, allowSend: true) { [weak self] result in
            guard let self else { return }
            if let notice = result.voiceCompletionNotice {
                self.showNotice(symbol: notice.symbol, message: notice.message)
                return
            }
            switch result {
            case .planned, .needsSendApproval:
                self.showNotice(symbol: "checkmark.circle", message: "Planned")
            case .cancelled:
                self.showNotice(symbol: "xmark.circle", message: "Action cancelled")
            case .failed(let reason, _):
                self.showError(String(reason.prefix(80)))
            case .completed, .performedUnverified:
                break
            }
        }
    }

    /// Agent/CLI entry point. Every request requires a fresh native approval;
    /// the global Settings toggle only exposes the capability and is not
    /// treated as microphone consent. Approved sessions use the normal visible
    /// HUD/sounds and are stopped by the user's usual hotkey, menu item, or Esc.
    func requestExternalDictation(
        mode: String?,
        requestID: UUID,
        completion: @escaping (Result<ExternalDictationResult, ExternalDictationError>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !terminating else {
            completion(.failure(.unavailable("Velora is shutting down")))
            return
        }
        guard externalRequest == nil, externalApproval == nil, phase == .idle else {
            completion(.failure(.busy))
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Allow a local agent to listen?"
        alert.informativeText = "Velora will visibly record one dictation and return its transcript to the requesting process. It will not paste text or read your screen."
        if let mode, !mode.isEmpty {
            alert.informativeText += "\n\nFormatting mode: \(mode)"
        }
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Deny")
        let alertToken = VisibleAlert.present(alert) { [weak self] response in
            guard let self else {
                completion(.failure(.unavailable("Velora is shutting down")))
                return
            }
            guard self.externalApproval?.requestID == requestID else { return }
            self.externalApproval = nil
            guard !self.terminating else {
                completion(.failure(.cancelled))
                return
            }
            guard response == .alertFirstButtonReturn else {
                completion(.failure(.denied))
                return
            }
            guard self.startRecording(
                locked: true, explicitMode: mode, external: true
            ) else {
                completion(.failure(.unavailable(
                    "Velora could not start the approved recording")))
                return
            }
            self.externalRequest = (
                requestID: requestID, session: self.sessionID, completion: completion)
        }
        externalApproval = (
            requestID: requestID, alertToken: alertToken, completion: completion)
    }

    /// Cancels either an unapproved prompt or the exact approved session. Used
    /// by the local socket timeout so a disconnected caller can never leave a
    /// consent dialog wedged or a microphone recording running.
    func cancelExternalRequest(_ requestID: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let approval = externalApproval, approval.requestID == requestID {
            externalApproval = nil
            approval.completion(.failure(.cancelled))
            VisibleAlert.dismiss(approval.alertToken)
            return
        }
        if externalRequest?.requestID == requestID { cancel() }
    }

    /// Revokes the capability itself, not just a socket request. Normal
    /// user-started dictation is left alone; pending consent and an approved
    /// agent-owned microphone session are cancelled immediately.
    func revokeExternalAccess() {
        dispatchPrecondition(condition: .onQueue(.main))
        if let approval = externalApproval {
            externalApproval = nil
            approval.completion(.failure(.cancelled))
            VisibleAlert.dismiss(approval.alertToken)
        }
        if externalRequest != nil {
            if phase != .idle {
                cancel()
            } else if let request = externalRequest {
                externalRequest = nil
                request.completion(.failure(.cancelled))
            }
        }
    }

    /// Completes every app-owned or broker-owned dictation before teardown.
    /// Pending consent is completed immediately; dismissing its alert cannot
    /// start capture because the approval state and lifecycle gate are cleared
    /// first. Idempotent for applicationShouldTerminate/applicationWillTerminate.
    func cancelForTermination() {
        dispatchPrecondition(condition: .onQueue(.main))
        terminating = true
        clearSublimeCapture()
        cancelSublimeApply()
        if let approval = externalApproval {
            externalApproval = nil
            approval.completion(.failure(.cancelled))
            VisibleAlert.dismiss(approval.alertToken)
        }
        if phase != .idle {
            cancel()
        } else if let request = externalRequest {
            externalRequest = nil
            request.completion(.failure(.cancelled))
        }
        mediaPlayback.restoreImmediatelyForTermination()
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
              let audioURL = AppConfig.archivedAudioURL(name: audio),
              FileManager.default.fileExists(atPath: audioURL.path)
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

    // MARK: - Safe Voice Edit (selection + spoken instruction)

    /// Begins an edit session: captures the current selection, then records a
    /// spoken instruction using the normal dictation state machine. The
    /// transcript is diverted in the `.final` handler — it is an instruction,
    /// never pasted text. Scope safety is structural: only the captured
    /// selection can ever be replaced, and only in its origin app.
    func beginEditSession(locked: Bool) {
        guard phase == .idle else { return }
        guard config.voiceEdit else { return }
        guard sublimeApplyID == nil else {
            showNotice(symbol: "hourglass", message: "Finishing edit")
            return
        }
        guard pendingEdit == nil else {
            showNotice(symbol: "hourglass", message: "Current edit is still finishing")
            return
        }
        guard sublimeCaptureID == nil else { return }
        let inputGeneration = UserInputActivity.snapshot()
        // Read the live owner first. The activation observer is intentionally
        // cached and can trail a just-focused editor by one run-loop turn.
        let app = NSWorkspace.shared.frontmostApplication
            ?? contextTracker.frontmost
        if let app, SublimeTextSelectionBridge.supports(app) {
            beginSublimeEditCapture(
                app: app,
                locked: locked,
                inputGeneration: inputGeneration)
            return
        }
        guard let selected = ScreenContext.selectedText(of: app) else {
            veloraLog(
                "Velora: voice edit selection unavailable in "
                    + (app?.bundleIdentifier ?? "unknown"))
            showEditStartError("Select some text first, then speak an edit")
            return
        }
        startCapturedEdit(
            selected,
            app: app,
            locked: locked)
    }

    private func beginSublimeEditCapture(
        app: NSRunningApplication,
        locked: Bool,
        inputGeneration: UInt64
    ) {
        let captureID = UUID()
        sublimeCaptureID = captureID
        sublimeCaptureLocksRecording = locked
        sublimeCaptureReleasedBeforeStart = false
        sublimeQueue.async { [weak self] in
            let result = SublimeTextSelectionBridge.capture(of: app)
            DispatchQueue.main.async {
                guard let self, self.sublimeCaptureID == captureID else {
                    if case .success(let capture) = result {
                        capture.token.discard()
                    }
                    return
                }
                let captureLocksRecording = self.sublimeCaptureLocksRecording
                let releasedBeforeStart =
                    self.sublimeCaptureReleasedBeforeStart
                self.clearSublimeCapture()
                guard self.phase == .idle,
                      inputGeneration == UserInputActivity.snapshot(),
                      NSWorkspace.shared.frontmostApplication?
                          .processIdentifier == app.processIdentifier
                else {
                    if case .success(let capture) = result {
                        capture.token.discard()
                    }
                    return
                }
                switch result {
                case .success(let capture):
                    guard !releasedBeforeStart else {
                        capture.token.discard()
                        self.showEditStartError(
                            "Sublime Text took too long — retry the edit")
                        return
                    }
                    let element = AXUIElementCreateApplication(
                        app.processIdentifier)
                    let selected = ScreenTextSelection(
                        text: capture.text,
                        element: element,
                        identity: .sublimeToken(capture.token),
                        isEditable: true)
                    self.startCapturedEdit(
                        selected,
                        app: app,
                        locked: captureLocksRecording)
                case .failure(.emptySelection):
                    self.showEditStartError(
                        "Select some text first, then speak an edit")
                case .failure(.multipleSelections):
                    self.showEditStartError(
                        "Select one text range, then speak an edit")
                case .failure(.selectionTooLong):
                    self.showEditStartError(
                        "Select a shorter text range, then speak an edit")
                case .failure(.unsupportedView):
                    self.showEditStartError(
                        "Select text in a Sublime document, not Find or Console")
                case .failure(.integrationNeedsRestart):
                    self.showEditStartError(
                        "Restart Sublime Text once, then retry")
                case .failure(.integrationUnavailable):
                    if !releasedBeforeStart,
                       let selected = ScreenContext.selectedText(of: app) {
                        self.startCapturedEdit(
                            selected,
                            app: app,
                            locked: captureLocksRecording)
                    } else {
                        self.showEditStartError(
                            "Couldn't connect to Sublime Text — try again")
                    }
                }
            }
        }
    }

    private func clearSublimeCapture() {
        sublimeCaptureID = nil
        sublimeCaptureLocksRecording = false
        sublimeCaptureReleasedBeforeStart = false
    }

    private func startCapturedEdit(
        _ selected: ScreenTextSelection,
        app: NSRunningApplication?,
        locked: Bool
    ) {
        guard selected.text.count <= 8_000 else {
            selected.discardMutableIdentity()
            showEditStartError("Selection too long to voice-edit")
            return
        }
        // "Raw" mode: the instruction transcript skips the writing model —
        // the words go to the edit prompt verbatim, no cleanup needed.
        guard startRecording(locked: locked, explicitMode: "Raw", hudLabel: "Edit") else {
            selected.discardMutableIdentity()
            installEditStartRetry()
            return
        }
        editSession = (
            session: sessionID, selection: selected,
            bundleID: app?.bundleIdentifier)
        NSLog("Velora: edit session started — %ld chars selected in %@",
              selected.text.count, app?.bundleIdentifier ?? "unknown")
    }

    /// The error capsule's Retry button must retry Safe Voice Edit, not start
    /// an unrelated normal dictation. A click is a toggle-style action, so it
    /// always starts locked even when the configured hotkey uses hold mode.
    private func showEditStartError(_ message: String) {
        showError(message, retryIntent: .voiceEdit)
    }

    private func installEditStartRetry() {
        errorRetryIntent = .voiceEdit
    }

    private func sendEditCommand(
        edit: (
            session: String, selection: ScreenTextSelection, bundleID: String?
        ),
        instruction: String
    ) {
        guard !instruction.isEmpty else {
            edit.selection.discardMutableIdentity()
            phase = .idle
            showError(
                "Didn't catch an instruction — try again",
                retryIntent: .voiceEdit)
            return
        }
        let id = UUID().uuidString
        pendingEdit = (
            id: id, selection: edit.selection,
            bundleID: edit.bundleID)
        phase = .transcribing
        editTimer?.invalidate()
        editTimer = Timer.scheduledTimer(
            withTimeInterval: Self.editTimeout, repeats: false
        ) { [weak self] _ in
            guard let self, let pending = self.pendingEdit, pending.id == id else { return }
            pending.selection.discardMutableIdentity()
            self.pendingEdit = nil
            self.supervisor.send(["cmd": "edit_cancel", "id": id])
            if self.phase == .transcribing { self.phase = .idle }
            self.showError("Edit timed out", retryIntent: .voiceEdit)
        }
        supervisor.send([
            "cmd": "edit_text", "id": id,
            "text": edit.selection.text, "instruction": instruction,
        ])
        NSLog("Velora: edit_text sent — %ld chars, instruction %ld words",
              edit.selection.text.count,
              instruction.split(separator: " ").count)
    }

    private func applyEdit(
        pending: (
            id: String, selection: ScreenTextSelection, bundleID: String?
        ),
        text: String, applied: Bool, ms: Int, reason: String?
    ) {
        guard applied else {
            pending.selection.discardMutableIdentity()
            // A guarded edit returns the original text — nothing worth
            // staging (the document still has it); leave the clipboard alone.
            NSLog("Velora: edit not applied (reason=%@)", reason ?? "model declined")
            showNotice(symbol: "pencil.slash", message: "Couldn't apply that edit")
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            pending.selection.discardMutableIdentity()
            showNotice(symbol: "pencil.slash", message: "Couldn't apply that edit")
            return
        }
        if let token = pending.selection.sublimeToken {
            applySublimeEdit(
                pending: pending,
                token: token,
                text: text,
                ms: ms)
            return
        }
        // AX-based editors keep a clipboard recovery path. Sublime performs
        // the exact replacement inside its plugin and must never touch the
        // user's clipboard.
        inserter.copyToClipboard(text)
        guard pending.selection.isEditable else {
            showNotice(symbol: "doc.on.clipboard", message: "Edited text on clipboard")
            return
        }
        guard Permissions.accessibilityGranted, TextInserter.canPostEvents,
              !SecureInput.isActive,
              let bundleID = pending.bundleID,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
        else {
            showNotice(symbol: "doc.on.clipboard", message: "Edited text on clipboard")
            return
        }
        // The selection must still be what we edited, in the SAME field — the
        // same string selected elsewhere in the same field/page (two
        // "Approved" occurrences, say) must not be overwritten. If the user
        // clicked away or typed, replacing whatever is now selected would
        // corrupt their document. Recovery stays one step: the text is on the
        // clipboard.
        let app = NSWorkspace.shared.frontmostApplication
        guard let current = ScreenContext.selectedText(of: app),
              pending.selection.canReplace(with: current)
        else {
            NSLog("Velora: edit paste skipped — selection changed")
            showNotice(symbol: "doc.on.clipboard", message: "Selection changed — edit on clipboard")
            return
        }
        guard inserter.insertViaPasteboard(
            text,
            targetBundleID: bundleID,
            targetElement: current.element,
            additionalDeliveryCheck: {
                let latestApp = NSWorkspace.shared.frontmostApplication
                guard latestApp?.bundleIdentifier == bundleID,
                      let latest = ScreenContext.selectedText(of: latestApp)
                else { return false }
                return pending.selection.canReplace(with: latest)
            })
        else {
            showNotice(symbol: "doc.on.clipboard", message: "Edited text on clipboard")
            return
        }
        finishAppliedEdit(bundleID: bundleID, ms: ms)
    }

    private func applySublimeEdit(
        pending: (
            id: String, selection: ScreenTextSelection, bundleID: String?
        ),
        token: SublimeTextSelectionToken,
        text: String,
        ms: Int
    ) {
        guard !SecureInput.isActive,
              let bundleID = pending.bundleID,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
        else {
            token.discard()
            NSLog("Velora: Sublime edit skipped — target/selection/input changed")
            showNotice(
                symbol: "pencil.slash",
                message: "Selection changed — retry the edit")
            return
        }
        let applyID = UUID()
        sublimeApplyID = applyID
        sublimeApplyingToken = token
        sublimeQueue.async { [weak self] in
            // The client rechecks the exact frontmost Sublime PID, and Sublime
            // validates the view, selection, generation, and buffer revision
            // immediately before replacement.
            let result = token.replace(with: text)
            DispatchQueue.main.async {
                guard let self, self.sublimeApplyID == applyID else { return }
                self.sublimeApplyID = nil
                self.sublimeApplyingToken = nil
                switch result {
                case .applied:
                    self.finishAppliedEdit(bundleID: bundleID, ms: ms)
                case .rejected:
                    NSLog("Velora: Sublime edit skipped — plugin validation failed")
                    self.showNotice(
                        symbol: "pencil.slash",
                        message: "Selection changed — retry the edit")
                case .unknown:
                    NSLog("Velora: Sublime edit result could not be confirmed")
                    self.showNotice(
                        symbol: "exclamationmark.triangle",
                        message: "Couldn't confirm whether Sublime applied the edit")
                }
            }
        }
    }

    private func cancelSublimeApply() {
        sublimeApplyID = nil
        sublimeApplyingToken?.discard()
        sublimeApplyingToken = nil
    }

    private func finishAppliedEdit(bundleID: String, ms: Int) {
        // The edit rewrote text in place; the remembered delivery tail no
        // longer describes what sits before the caret.
        inserter.resetContinuationContext()
        lastInsertion = (bundleID: bundleID, at: Date())
        sounds.play(.stop)
        NSLog("Velora: edit applied (%d ms)", ms)
        showNotice(symbol: "pencil.line", message: "Edited")
    }

    /// Pastes the last dictation's ORIGINAL raw transcript — exactly what the
    /// speech model heard, before any cleanup. The escape hatch for a cleanup
    /// that changed meaning: no engine round-trip, no STT re-run, works even
    /// after the audio clip has been pruned.
    func pasteLastRawOriginal() {
        guard let record = history.recent(limit: 1).first else {
            showError("No recent dictation")
            return
        }
        let raw = record.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            showError("The last dictation has no transcript")
            return
        }
        inserter.copyToClipboard(raw)
        NSLog("Velora: paste last as-heard id=%lld (%d chars)", record.id, raw.count)
        guard let bundleID = record.bundleID,
              let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID).first
        else { return }
        app.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            // Same rails as a live insertion: never synthesize input without
            // the grant, into a secure field, or into a different app. The
            // text is already on the clipboard for a manual paste either way.
            guard Permissions.accessibilityGranted, TextInserter.canPostEvents,
                  !SecureInput.isActive,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
            else {
                NSLog("Velora: as-heard paste skipped — target not ready (text on clipboard)")
                return
            }
            self.inserter.insert(raw, targetBundleID: bundleID, mode: "Raw")
        }
    }

    /// Pastes a completed "Reformat Last as…" result back into its origin app.
    private func applyReformat(
        id: Int64, raw: String, text: String, mode: String?,
        sttMs: Int, cleanupMs: Int, cleanupApplied: Bool, cleanupWallMs: Int?
    ) {
        guard let pending = pendingReformat, pending.id == id else { return }
        pendingReformat = nil
        history.updateAfterReprocess(
            id: id, raw: raw, final: text, mode: mode,
            sttMs: sttMs, cleanupMs: cleanupMs, cleanupApplied: cleanupApplied,
            cleanupWallMs: cleanupWallMs)
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
    private func captureLearningBaseline(text: String, bundleID: String?, session: String) {
        guard config.learnFromEdits else { return }
        let inserted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedTokens = CorrectionDiff.normalizedTokens(inserted),
              !normalizedTokens.isEmpty else {
            veloraLog(
                "Velora: learning — baseline skipped (empty or >\(Self.learningMaxTokens) tokens)")
            return
        }
        let insertedTokens = Set(normalizedTokens)
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
            // A completed next insertion supersedes the single retained
            // baseline. Give the prior field one final timer-style read first
            // so timer-only AX surfaces do not silently drop an edit.
            if self.pendingLearning != nil {
                self.evaluatePendingLearning(consume: true)
            }
            self.pendingLearning = (element, inserted, insertedTokens, session)
            self.scheduleLearningRecheck()
            // Real-time: watch the field itself; edits evaluate a debounce
            // after the last keystroke instead of waiting for the 60s timer.
            self.editWatcher.onChange = { [weak self] in self?.scheduleEditEvaluation() }
            let watching = self.editWatcher.watch(element)
            veloraLog("Velora: learning — baseline set (\(normalizedTokens.count) tokens, watch=\(watching ? "live" : "timer-only"))")
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

    /// Arms the one-shot deferred re-check (~60 s after insert). Main thread,
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

    /// Consume-now entry point for the 60-second fallback timer.
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
                // Unobservable (field gone/unreadable) — never a quality verdict.
                veloraLog("Velora: learning — field unreadable at evaluate (consume=\(consume))")
                return
            }
            guard edited != pending.inserted else {
                // Untouched. Only the final (consuming) check is an honest
                // "unchanged" observation — a live watcher tick just means the
                // user hasn't edited YET.
                if consume {
                    self.history.markQualityObservation(
                        session: pending.session, state: .unchanged)
                }
                return
            }
            // Size cap only (a real document never diffs; would freeze/mislead).
            // Fields BIGGER than the insertion are fine below the cap:
            // CorrectionDiff isolates the best-matching window itself, so a
            // TextEdit/Notes doc accumulating several dictations still learns.
            guard CorrectionDiff.normalizedTokens(edited) != nil else {
                // Unsupported (oversized field) — no observation either way.
                veloraLog(
                    "Velora: learning — field too large to diff (>\(Self.learningMaxTokens) tokens)")
                return
            }

            let corrections = CorrectionDiff.corrections(baseline: pending.inserted, edited: edited)
                .filter {
                    CorrectionDiff.normalizedToken($0.wrong)
                        .map(pending.insertedTokens.contains) ?? false
                }
            guard !corrections.isEmpty else {
                // The field changed but nothing learnable was isolated. If our
                // inserted span survives verbatim inside the larger text, the
                // user only added around it — an honest "unchanged" at the
                // final check. Anything else (cleared on send, wholesale
                // rewrite) is ambiguous and stays unobserved.
                if consume, edited.contains(pending.inserted) {
                    self.history.markQualityObservation(
                        session: pending.session, state: .unchanged)
                }
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
                    guard self.pendingLearning?.inserted == pending.inserted,
                          self.pendingLearning?.session == pending.session else { return }
                    self.consumePendingLearning()
                }
                // A demonstrable user edit of our inserted words — the one
                // honest "edited" signal (regardless of whether the dictionary
                // commits the correction pair).
                self.history.markQualityObservation(
                    session: pending.session, state: .edited)
                let committed = self.dictionary.observeCorrections(
                    corrections.map { ($0.wrong, $0.right) })
                veloraLog("Velora: learning — \(corrections.count) correction(s) observed, \(committed.count) committed")
                if let first = committed.first {
                    self.showLearnedToast(first)
                }
            }
        }
    }

    /// Wispr-style feedback: the pill returns briefly with the mishearing
    /// struck through and the fix next to it. Only when nothing else is using
    /// the HUD — a toast must never stomp an active dictation.
    private func showLearnedToast(_ pair: (wrong: String, right: String)) {
        guard phase == .idle, hud.model.state.isAvailable else {
            deferredLearnedToast = pair
            return
        }
        presentLearnedToast(pair)
    }

    private func flushDeferredLearnedToastIfPossible() {
        guard let pair = deferredLearnedToast,
              phase == .idle, hud.model.state.isAvailable else { return }
        deferredLearnedToast = nil
        presentLearnedToast(pair)
    }

    /// The HUD is shared with file transcription and meeting capture. Their
    /// notices can finish while dictation is already idle, so phase changes
    /// alone cannot release deferred learned feedback.
    func hudDidBecomeAvailable() {
        flushDeferredLearnedToastIfPossible()
    }

    private func presentLearnedToast(_ pair: (wrong: String, right: String)) {
        hud.transition(to: .learned(wrong: pair.wrong, right: pair.right))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            guard let self, case .learned = self.hud.model.state else { return }
            self.hud.transition(to: .hidden(.success))
            self.flushDeferredLearnedToastIfPossible()
        }
    }

    // MARK: - Error retry

    private func retryFromError() {
        hud.transition(to: .hidden(.cancel))
        phase = .idle
        // Retry may immediately start another session. Wait until that decision
        // has settled; the flush keeps the toast deferred if the HUD is busy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.flushDeferredLearnedToastIfPossible()
        }
        if let action = errorRetryAction {
            errorRetryAction = nil
            errorRetryIntent = .dictation
            hud.model.retryTitle = "Retry"
            action()
            return
        }
        let intent = errorRetryIntent
        errorRetryIntent = .dictation
        intent.perform(
            dictation: {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.startRecording(locked: true)
                }
            },
            voiceEdit: { [weak self] in
                self?.beginEditSession(locked: true)
            })
    }

    // MARK: - Recording lifecycle

    @discardableResult
    private func startRecording(
        locked: Bool, explicitMode: String? = nil, external: Bool = false,
        hudLabel: String? = nil, streamTyping: Bool = false,
        livePreview: Bool = false,
        targetAppOverride: NSRunningApplication? = nil
    ) -> Bool {
        guard !terminating, phase == .idle else { return false }
        guard streamCancellation == nil else {
            NSLog("Velora: recording deferred — restoring a cancelled stream draft")
            return false
        }
        // Action execution drives focus and may synthesize text while the
        // controller phase is idle. Starting any dictation in that interval
        // would allow two independent keyboard-event streams to interleave.
        guard actionsStorage?.isRunning != true else {
            NSLog("Velora: recording refused — an action is still running")
            return false
        }
        if let reason = recordingBlockReason?() {
            showError(reason)
            return false
        }

        // A fresh press supersedes any lingering error/fallback HUD: clear its
        // one-shot retry action so we start clean (the transition to
        // `.listening` below replaces the error visual).
        errorRetryAction = nil
        errorRetryIntent = .dictation
        hud.model.retryTitle = "Retry"

        // Secure input (password fields): refuse with an error HUD.
        guard !SecureInput.isActive else {
            NSLog("Velora: recording refused — secure input active")
            showError("Secure input active — dictation unavailable")
            return false
        }
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            NSLog("Velora: recording refused — mic auth status=%ld", micStatus.rawValue)
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            showError("Microphone access needed")
            return false
        }
        guard supervisor.isReady else {
            NSLog("Velora: recording refused — engine not ready")
            // First run: say WHAT is happening ("Downloading the speech model
            // (1.6 GB) — 42%") instead of a vague "starting…".
            showError(supervisor.loadingStatus ?? "Speech engine is starting…")
            return false
        }

        // Request the media pause before opening the microphone. On Bluetooth
        // headphones this prevents music from playing through the lower-quality
        // two-way headset route while Velora captures speech.
        mediaPlayback.pauseForDictation()

        sessionID = UUID().uuidString
        rawTranscript = nil
        sttMs = nil
        recordingStart = nil
        recordingDurationMs = nil
        activeTranscribeTimeout = Self.minimumTranscribeTimeout
        autoStopLimitSeconds = nil
        pendingRecordingLimitNoticeSeconds = nil
        recordingLimitNoticeScheduled = false
        stopAfterCaptureStarts = false
        captureStartTimer?.invalidate()
        captureStartTimer = nil
        timeoutErrorAt = nil  // a stale timeout must never drop THIS session's final

        // Context chip: the target app's actual icon + the client-side
        // detected mode label (ModeCategory mirrors the engine's map).
        let liveApp = NSWorkspace.shared.frontmostApplication
        let liveAppIsExternal = liveApp?.processIdentifier
            != ProcessInfo.processInfo.processIdentifier
        let liveExternalApp = liveAppIsExternal ? liveApp : nil
        let targetApp = external
            ? nil
            : (targetAppOverride ?? liveExternalApp ?? contextTracker.frontmost)

        // Enrich the app context with on-screen entities (current file, the
        // person/channel you're messaging, …) via the Accessibility API, so the
        // engine can spell them right and, later, tag them. Cheap AX title read;
        // never blocks capture.
        var enriched = external
            ? AppContext(bundleID: nil, appName: "Local agent")
            : AppContext(
                bundleID: targetApp?.bundleIdentifier,
                appName: targetApp?.localizedName)
        if !external {
            enriched.entities = ScreenContext.entities(
                for: targetApp, category: ModeCategory.category(forBundleID: enriched.bundleID))
        }
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
            modeName: hudLabel ?? explicitMode
                ?? ModeApplicationIndex.shared.modeName(forBundleID: sessionContext?.bundleID)
                ?? ModeCategory.displayName(
                    forBundleID: sessionContext?.bundleID,
                    // Detected web app (Gmail, Notion…): the chip mirrors the
                    // engine's site→mode refinement instead of saying "Browser".
                    siteSlug: enriched.entities.first { $0.type == "site" }?.value),
            livePreview: livePreview))

        NSLog(
            "Velora: engine start session=%@ target=%@",
            sessionID, sessionContext?.bundleID ?? "unknown")
        var startCommand: [String: Any] = [
            "cmd": "start",
            "session": sessionID,
            "context": sessionContext?.payload ?? [:],
        ]
        if let explicitMode {
            var payload = startCommand["context"] as? [String: Any] ?? [:]
            payload["mode"] = explicitMode
            startCommand["context"] = payload
        }
        if streamTyping {
            var payload = startCommand["context"] as? [String: Any] ?? [:]
            payload["stream_typing"] = true
            startCommand["context"] = payload
        }
        phase = .starting(locked: locked)
        supervisor.send(startCommand)

        // Background pass: read richer nearby AX text (the person you're
        // replying to, field labels) while the user speaks. It's heavier than
        // the title read, so it runs off the main thread and is attached to the
        // `stop` command — ready by the time the user finishes talking, adding
        // nothing to the release→insert latency.
        richEntities = []
        if !external {
            contextGatherGeneration += 1
            let generation = contextGatherGeneration
            let gatherApp = targetApp
            let gatherCategory = ModeCategory.category(forBundleID: enriched.bundleID)
            contextQueue.async { [weak self] in
                let rich = ScreenContext.richEntities(for: gatherApp, category: gatherCategory)
                DispatchQueue.main.async {
                    guard let self, self.contextGatherGeneration == generation else { return }
                    self.richEntities = rich
                }
            }
        }

        // No HUD transition while capture spins up: a hidden HUD stays hidden
        // and the standby pill morphs straight to `.listening` on success —
        // flashing the wide "Starting microphone…" capsule on every start read
        // as jank. The 8 s watchdog below still surfaces a mic that never
        // starts, and a capture failure shows the error HUD immediately.
        let client = supervisor.client
        let requestedSession = sessionID
        capture.start(
            onChunk: { data in client.send(audio: data) },
            onLevel: { [weak self] bands in self?.hud.model.levels.push(bands) }
        ) { [weak self] result in
            guard let self, self.sessionID == requestedSession,
                  case .starting(let currentLocked) = self.phase else { return }
            self.captureStartTimer?.invalidate()
            self.captureStartTimer = nil
            switch result {
            case .failure(let error):
                self.supervisor.send(["cmd": "cancel", "session": requestedSession])
                self.showError(error.localizedDescription)
            case .success:
                self.recordingStart = Date()
                self.hud.model.levels.reset()
                self.hud.model.recordingStart = self.recordingStart
                self.hud.transition(to: .listening)
                self.sounds.play(.start)
                self.phase = .recording(locked: currentLocked)
                if self.stopAfterCaptureStarts {
                    self.stopAfterCaptureStarts = false
                    self.stopAndTranscribe()
                }
            }
        }
        captureStartTimer = Timer.scheduledTimer(
            withTimeInterval: 8, repeats: false
        ) { [weak self] _ in
            guard let self, self.sessionID == requestedSession,
                  case .starting = self.phase else { return }
            self.supervisor.send(["cmd": "cancel", "session": requestedSession])
            self.cancelledSessionID = requestedSession
            self.showError("Microphone did not start — check the selected input")
        }
        return true
    }

    private func stopAndTranscribe() {
        guard isRecording else { return }

        recordingDurationMs = elapsedRecordingMs
        sounds.play(.stop)
        // Attach the background-gathered rich context (if it finished) so the
        // engine's cleanup sees the on-screen names. Falls back to the basic
        // title entities already sent with `start`.
        var stopCmd: [String: Any] = ["cmd": "stop", "session": sessionID]
        if !richEntities.isEmpty {
            stopCmd["entities"] = richEntities.map { $0.payload }
        }
        let stoppedSession = sessionID
        hud.transition(to: .transcribing)
        phase = .transcribing
        capture.stop { [weak self] in
            guard let self else { return }
            self.mediaPlayback.restoreAfterDictation()
            guard self.sessionID == stoppedSession,
                  self.phase == .transcribing,
                  self.cancelledSessionID != stoppedSession else { return }
            NSLog("Velora: engine stop session=%@", stoppedSession)
            self.supervisor.send(stopCmd)
            self.armTranscribeTimeout()
        }
    }

    /// (Re)arms the stop→final watchdog. Reset on `transcript` progress so a
    /// slow LLM cleanup after a long batch (whisper) decode doesn't trip it.
    /// A late `final` that arrives after this fires is still honored (see the
    /// `.final` handler) unless the user explicitly cancelled.
    private func armTranscribeTimeout(after explicitTimeout: TimeInterval? = nil) {
        activeTranscribeTimeout = explicitTimeout
            ?? Self.transcribeTimeout(recordingDurationMs: recordingDurationMs)
        transcribeStartedAt = Date()
        transcribeTimer?.invalidate()
        transcribeTimer = Timer.scheduledTimer(
            withTimeInterval: activeTranscribeTimeout, repeats: false
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
        guard elapsed >= activeTranscribeTimeout else { return false }
        NSLog("Velora: hotkey while stuck transcribing %.1fs — self-resetting", elapsed)
        transcribeTimer?.invalidate()
        transcribeTimer = nil
        supervisor.send(["cmd": "cancel", "session": sessionID])
        cancelledSessionID = sessionID
        cancelStreamDraft()
        hud.model.recordingStart = nil
        phase = .idle
        // HUDPanel publishes availability synchronously. Release dictation's
        // phase first so a retained meeting failure can claim that callback.
        hud.transition(to: .hidden(.cancel))
        editSession?.selection.discardMutableIdentity()
        editSession = nil
        failExternalRequest(for: sessionID, error: .cancelled)
        return true
    }

    /// Esc or explicit cancel: stop everything, insert nothing.
    func cancel() {
        if phase == .idle, sublimeCaptureID != nil {
            clearSublimeCapture()
            hud.transition(to: .hidden(.cancel))
            return
        }
        if phase == .idle, sublimeApplyID != nil {
            cancelSublimeApply()
            hud.transition(to: .hidden(.cancel))
            return
        }
        guard phase != .idle else { return }
        captureStartTimer?.invalidate()
        captureStartTimer = nil
        transcribeTimer?.invalidate()
        transcribeTimer = nil

        // Mark this session cancelled so a late `final` for it is refused
        // (the user explicitly gave up on it).
        cancelledSessionID = sessionID
        cancelStreamDraft()
        stopAfterCaptureStarts = false
        editSession?.selection.discardMutableIdentity()
        editSession = nil
        if let pending = pendingEdit {
            pending.selection.discardMutableIdentity()
            supervisor.send(["cmd": "edit_cancel", "id": pending.id])
            pendingEdit = nil
        }
        editTimer?.invalidate()
        editTimer = nil
        stopCaptureAndRestoreMedia()
        NSLog("Velora: engine cancel session=%@", sessionID)
        supervisor.send(["cmd": "cancel", "session": sessionID])
        hud.model.recordingStart = nil
        phase = .idle
        hud.transition(to: .hidden(.cancel))
        failExternalRequest(for: sessionID, error: .cancelled)
    }

    private func showError(
        _ message: String, retryIntent explicitRetryIntent: ErrorRetryIntent? = nil
    ) {
        clearSublimeCapture()
        cancelStreamDraft()
        let failedSession = sessionID
        let retryIntent = ErrorRetryIntent.resolve(
            explicit: explicitRetryIntent,
            failedSession: failedSession,
            editInstructionSession: editSession?.session)
        if LateFinalPolicy.errorCancelsSession(
            failedSession,
            editInstructionSession: editSession?.session,
            externalRequestSession: externalRequest?.session,
            actionInstructionSession: actionSession
        ) {
            // Once the requester has received a failure, a late final must not
            // fall through into the normal paste path. The same rule is
            // critical for Voice Edit: its transcript is an instruction, so
            // after an edit timeout/error it must never become normal dictated
            // text merely because showError clears the captured selection.
            cancelledSessionID = failedSession
        }
        if actionSession == failedSession {
            actionSession = nil
        }
        if editSession?.session == failedSession {
            editSession?.selection.discardMutableIdentity()
            editSession = nil
        }
        // Deliberately does NOT clear pendingEdit: showError is a catch-all
        // reached by unrelated failures (e.g. a rejected "Reformat Last as…"
        // while an edit is in flight), and discarding a valid edit round-trip
        // here would lose its result. The edit owns its own lifecycle —
        // editTimer, the `edited`/`edit_failed` handlers, and cancel().
        stopCaptureAndRestoreMedia()
        captureStartTimer?.invalidate()
        captureStartTimer = nil
        transcribeTimer?.invalidate()
        transcribeTimer = nil
        errorRetryAction = nil
        errorRetryIntent = retryIntent
        hud.model.retryTitle = "Retry"
        NSLog("Velora: error HUD — %@", message)
        sounds.play(.error)
        hud.transition(to: .error(message))
        phase = .idle
        failExternalRequest(
            for: failedSession, error: .unavailable(message))
    }

    // MARK: - Engine events

    /// Routed here by the AppDelegate from the supervisor.
    func handleEngineEvent(_ event: EngineEvent) {
        // Action Mode replies are addressed by their own request id and never
        // belong to a dictation session.
        switch event {
        case .actionTurn, .actionFailed:
            actionsStorage?.handle(event)
            return
        default:
            break
        }
        switch event {
        case .partial(let session, let text):
            guard session == sessionID, phase != .idle else { return }
            // Ordinary dictation keeps provisional Whisper output out of the
            // HUD and target. Stream Typing alone owns an exact live range and
            // may replace it; the authoritative final still wins below.
            if let stream = streamSession, stream.session == session {
                stream.draft.update(text, mode: stream.mode)
            }

        case .transcript(let session, let raw, let ms):
            guard session == sessionID else { return }
            rawTranscript = raw
            sttMs = ms > 0 ? ms : nil
            // Progress signal: the engine has decoded and is now formatting.
            // Refresh the timeout so a slow LLM cleanup after a long batch
            // transcription doesn't trip the stop→final deadline.
            if phase == .transcribing {
                armTranscribeTimeout(after: Self.minimumTranscribeTimeout)
            }

        case .recordingAutoStopped(let session, let durationS, let limitS):
            guard session == sessionID, phase != .idle else { return }
            recordingDurationMs = max(
                recordingDurationMs ?? 0,
                Int(max(0, durationS) * 1_000))
            autoStopLimitSeconds = limitS > 0
                ? limitS
                : config.portableEngineSettings.maximumRecordingSeconds
            if isRecording {
                sounds.play(.stop)
                stopCaptureAndRestoreMedia()
            }
            hud.transition(to: .transcribing)
            phase = .transcribing
            armTranscribeTimeout()

        case .final(
            let session, let text, let raw, let mode, let cleanupMs,
            let cleanupWallMs, let cleanupApplied, let totalMs, let audio,
            let autoStopped
        ):
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
            if isRecording {
                recordingDurationMs = elapsedRecordingMs
                stopCaptureAndRestoreMedia()
            }
            let recordingLimitSeconds = autoStopLimitSeconds
                ?? config.portableEngineSettings.maximumRecordingSeconds
            autoStopLimitSeconds = nil
            if autoStopped {
                pendingRecordingLimitNoticeSeconds = recordingLimitSeconds
                recordingLimitNoticeScheduled = false
            }
            // Safe Voice Edit: this session's transcript is an INSTRUCTION for
            // the captured selection, never text to paste.
            let effectiveRaw = raw.isEmpty ? (rawTranscript ?? text) : raw
            if StreamTypingFinalPolicy.shouldDeferFinal(
                session: session,
                cancellationSession: streamCancellation?.session
            ) {
                deferredStreamFinal = DeferredStreamFinal(
                    session: session, text: text, raw: effectiveRaw, mode: mode,
                    cleanupMs: cleanupMs, cleanupApplied: cleanupApplied,
                    cleanupWallMs: cleanupWallMs, finalizationMs: totalMs,
                    audio: audio,
                    allowAutomaticInsertion: !arrivedTooLate)
                return
            }
            if let edit = editSession, edit.session == session {
                editSession = nil
                let instruction = (raw.isEmpty ? text : raw)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                sendEditCommand(edit: edit, instruction: instruction)
                return
            }
            if let stream = streamSession, stream.session == session {
                finishStreamInsertion(
                    stream: stream,
                    text: text,
                    raw: effectiveRaw,
                    mode: mode,
                    cleanupMs: cleanupMs,
                    cleanupApplied: cleanupApplied,
                    cleanupWallMs: cleanupWallMs,
                    finalizationMs: totalMs,
                    audio: audio)
                return
            }
            finishInsertion(
                text: text, raw: effectiveRaw,
                mode: mode, cleanupMs: cleanupMs, cleanupApplied: cleanupApplied,
                cleanupWallMs: cleanupWallMs, finalizationMs: totalMs, audio: audio,
                allowAutomaticInsertion: !arrivedTooLate)
            schedulePendingRecordingLimitNotice()

        case .reprocessed(
            let id, _, let raw, let text, let mode, _,
            let sttMs, let cleanupMs, let cleanupApplied, let cleanupWallMs
        ):
            // Only the menubar "Reformat Last as…" path is handled here; the
            // History tab consumes its own reprocess replies via notification.
            if let id, pendingReformat?.id == id {
                applyReformat(
                    id: id, raw: raw, text: text, mode: mode,
                    sttMs: sttMs, cleanupMs: cleanupMs,
                    cleanupApplied: cleanupApplied, cleanupWallMs: cleanupWallMs)
            }

        case .reprocessFailed(let id, let error, _):
            guard let id, pendingReformat?.id == id else { break }
            pendingReformat = nil
            showError("Reformat failed: \(error)")

        case .edited(let id, let text, let applied, let ms, let reason):
            guard let pending = pendingEdit, pending.id == id else { break }
            pendingEdit = nil
            editTimer?.invalidate()
            editTimer = nil
            if phase == .transcribing { phase = .idle }
            applyEdit(pending: pending, text: text, applied: applied, ms: ms, reason: reason)

        case .editFailed(let id, let error, let code):
            guard let pending = pendingEdit, pending.id == id else { break }
            pending.selection.discardMutableIdentity()
            pendingEdit = nil
            editTimer?.invalidate()
            editTimer = nil
            if phase == .transcribing { phase = .idle }
            switch code {
            case "busy":
                showError(
                    "Velora is busy — try the edit again",
                    retryIntent: .voiceEdit)
            case "cleanup_unavailable":
                showError(
                    "The writing model is still loading — try again shortly",
                    retryIntent: .voiceEdit)
            default:
                showError(error, retryIntent: .voiceEdit)
            }

        case .error(let session, let message):
            // Only errors scoped to the active session may end the dictation;
            // global or foreign-session errors are logged and ignored.
            if session == sessionID, phase != .idle {
                if pendingEdit != nil {
                    cancelPendingEditForError(message)
                } else {
                    showError(message)
                }
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
            if pendingEdit != nil {
                cancelPendingEditForError("Engine crashed — restarting")
            } else {
                showError("Engine crashed — restarting")
            }
        }
    }

    private func cancelPendingEditForError(_ message: String) {
        // pendingEdit is created only after the raw instruction final has set
        // consumedSessionID, so clearing it here blocks both a stale `.edited`
        // response and any duplicate raw final from reaching normal insertion.
        if let pending = pendingEdit {
            pending.selection.discardMutableIdentity()
            supervisor.send(["cmd": "edit_cancel", "id": pending.id])
            pendingEdit = nil
        }
        editTimer?.invalidate()
        editTimer = nil
        showError(message, retryIntent: .voiceEdit)
    }

    private func finishInsertion(
        text: String,
        raw: String,
        mode: String?,
        cleanupMs: Int?,
        cleanupApplied: Bool?,
        cleanupWallMs: Int?,
        finalizationMs: Int?,
        audio: String?,
        allowAutomaticInsertion: Bool = true,
        finalOutputAlreadyStaged: Bool = false,
        historyAlreadyRecorded: Bool = false,
        expectedTargetElement: AXUIElement? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = sessionContext

        if let request = externalRequest, request.session == sessionID {
            let durationMs = recordingDurationMs ?? elapsedRecordingMs
            if let message = DictationOutputFailure.message(for: trimmed) {
                if audio != nil {
                    recordHistory(
                        text: "", raw: raw, context: context, mode: mode,
                        cleanupMs: cleanupMs, cleanupApplied: cleanupApplied,
                        cleanupWallMs: cleanupWallMs,
                        finalizationMs: finalizationMs, audio: audio)
                }
                externalRequest = nil
                phase = .idle
                showError(message)
                request.completion(.failure(.unavailable(message)))
            } else {
                recordHistory(
                    text: text, raw: raw, context: context, mode: mode,
                    cleanupMs: cleanupMs, cleanupApplied: cleanupApplied,
                    cleanupWallMs: cleanupWallMs,
                    finalizationMs: finalizationMs, audio: audio)
                externalRequest = nil
                phase = .idle
                showNotice(symbol: "waveform.badge.checkmark", message: "Sent to local agent")
                request.completion(.success(ExternalDictationResult(
                    text: text, mode: mode, durationMs: durationMs)))
            }
            return
        }

        if let session = actionSession, session == sessionID {
            actionSession = nil
            // Raw mode: `raw` is what the user said, before any formatting. The
            // planner is matching names and app names, so verbatim wins.
            let command = (raw.isEmpty ? trimmed : raw)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard LateFinalPolicy.commandMayExecute(
                allowAutomaticInsertion: allowAutomaticInsertion
            ) else {
                phase = .idle
                showNotice(
                    symbol: "exclamationmark.arrow.triangle.2.circlepath",
                    message: "Finished late — action not run")
                return
            }
            if audio != nil {
                recordHistory(
                    text: command, raw: raw, context: context, mode: "Action",
                    cleanupMs: cleanupMs, cleanupApplied: cleanupApplied,
                    cleanupWallMs: cleanupWallMs,
                    finalizationMs: finalizationMs, audio: audio)
            }
            phase = .idle
            runVoiceAction(command)
            return
        }

        // Commands are recognized before the late-final empty-text gate: a
        // cleanup model may intentionally remove the words "scratch that".
        // Once automatic delivery is disallowed, report the command without
        // executing Return/Undo or copying its literal words.
        if config.voiceCommands,
           let command = VoiceCommand.parse(text: trimmed, raw: raw) {
            if LateFinalPolicy.commandMayExecute(
                allowAutomaticInsertion: allowAutomaticInsertion
            ) {
                executeVoiceCommand(command)
            } else {
                phase = .idle
                showNotice(
                    symbol: "exclamationmark.arrow.triangle.2.circlepath",
                    message: "Finished late — command not run")
            }
            return
        }

        if !allowAutomaticInsertion {
            if let message = DictationOutputFailure.message(for: trimmed) {
                if audio != nil {
                    recordHistory(
                        text: "", raw: raw, context: context, mode: mode,
                        cleanupMs: cleanupMs, cleanupApplied: cleanupApplied,
                        cleanupWallMs: cleanupWallMs,
                        finalizationMs: finalizationMs, audio: audio)
                }
                showError(message)
            } else {
                inserter.stageFinalOutput(text)
                recordHistory(
                    text: text, raw: raw, context: context, mode: mode,
                    cleanupMs: cleanupMs, cleanupApplied: cleanupApplied,
                    cleanupWallMs: cleanupWallMs,
                    finalizationMs: finalizationMs, audio: audio)
                phase = .idle
                showNotice(symbol: "doc.on.clipboard.fill", message: "Finished late — copied")
            }
            return
        }

        if let message = DictationOutputFailure.message(for: trimmed) {
            // A real recording that survives to `final` must never disappear
            // without feedback. The engine already retried recoverable prompt
            // hallucinations; retain archived audio so History can reprocess it.
            if audio != nil {
                recordHistory(
                    text: "", raw: raw, context: context, mode: mode,
                    cleanupMs: cleanupMs, cleanupApplied: cleanupApplied,
                    cleanupWallMs: cleanupWallMs,
                    finalizationMs: finalizationMs, audio: audio)
            }
            showError(message)
            return
        }

        // Clipboard delivery is the invariant; synthetic paste/typing is only
        // the convenience layer. Staging here covers own-window, paste,
        // typing, permission, secure-input, focus-change, and silent Command-V
        // failures while whole-utterance voice commands above remain commands
        // rather than copied prose.
        StreamFinalOutputStagingPolicy.stage(
            text, alreadyStaged: finalOutputAlreadyStaged,
            write: inserter.stageFinalOutput)

        // Own-window insertion (onboarding try-it): the TextEditor lives inside
        // Velora's own window. AppContextTracker deliberately ignores Velora's
        // own activations, so `context.bundleID` is some *other* app while the
        // real frontmost is us — the "focus changed" guard below would always
        // divert to the clipboard and nothing would land in the box. When we
        // ourselves are frontmost, insert straight into our key window's
        // focused text view via the responder chain (zero TCC), skip the
        // fallback, and still fire the inserted notification.
        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.sushil.velora"
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ownBundleID,
           inserter.insertIntoOwnWindow(text, mode: mode) {
            NSLog("Velora: insert method=own-window session=%@ chars=%ld", sessionID, text.count)
            errorRetryAction = nil
            errorRetryIntent = .dictation
            hud.model.retryTitle = "Retry"
            hud.transition(to: .inserted)
            phase = .idle
            if StreamTypingFinalPolicy.shouldRecordHistory(
                alreadyRecorded: historyAlreadyRecorded
            ) {
                recordHistory(
                    text: text, raw: raw, context: context, mode: mode,
                    cleanupMs: cleanupMs, cleanupApplied: cleanupApplied,
                    cleanupWallMs: cleanupWallMs,
                    finalizationMs: finalizationMs, audio: audio)
            }
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
            errorRetryIntent = .dictation
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
            if StreamTypingFinalPolicy.shouldRecordHistory(
                alreadyRecorded: historyAlreadyRecorded
            ) {
                recordHistory(
                    text: text, raw: raw, context: context, mode: mode,
                    cleanupMs: cleanupMs, cleanupApplied: cleanupApplied,
                    cleanupWallMs: cleanupWallMs,
                    finalizationMs: finalizationMs, audio: audio)
            }
            return
        }

        if StreamTypingFinalPolicy.shouldRecordHistory(
            alreadyRecorded: historyAlreadyRecorded
        ) {
            recordHistory(
                text: text, raw: raw, context: context, mode: mode,
                cleanupMs: cleanupMs, cleanupApplied: cleanupApplied,
                cleanupWallMs: cleanupWallMs,
                finalizationMs: finalizationMs, audio: audio)
        }

        let session = sessionID
        inserter.insert(
            text,
            targetBundleID: context?.bundleID,
            mode: mode,
            expectedTargetElement: expectedTargetElement
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
            self.captureLearningBaseline(
                text: text, bundleID: context?.bundleID, session: session)
            NotificationCenter.default.post(name: .veloraDictationInserted, object: text)
            self.scheduleInsertedHide()
        }
    }

    private func finishStreamInsertion(
        stream: (session: String, draft: LiveStreamDraftSession, mode: String?),
        text: String,
        raw: String,
        mode: String?,
        cleanupMs: Int?,
        cleanupApplied: Bool?,
        cleanupWallMs: Int?,
        finalizationMs: Int?,
        audio: String?
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let command = StreamTypingFinalPolicy.voiceCommand(
            enabled: config.voiceCommands, text: trimmed, raw: raw
        ) {
            let session = stream.session
            // A command is never draft text. Remove a still-owned provisional
            // revision first, then act only after exact restoration completes.
            // This keeps both the document and clipboard untouched by the
            // words "scratch that" / "new line" themselves.
            cancelStreamDraft { [weak self] result in
                guard let self,
                      session == self.sessionID,
                      session != self.cancelledSessionID
                else { return }
                guard StreamTypingFinalPolicy.commandMayExecute(after: result) else {
                    self.phase = .idle
                    self.showNotice(
                        symbol: "exclamationmark.arrow.triangle.2.circlepath",
                        message: "Draft changed — command not run")
                    self.schedulePendingRecordingLimitNotice()
                    return
                }
                self.executeVoiceCommand(command)
                self.schedulePendingRecordingLimitNotice()
            }
            return
        }
        guard DictationOutputFailure.message(for: trimmed) == nil else {
            cancelStreamDraft()
            finishInsertion(
                text: text, raw: raw, mode: mode,
                cleanupMs: cleanupMs, cleanupApplied: cleanupApplied,
                cleanupWallMs: cleanupWallMs,
                finalizationMs: finalizationMs, audio: audio)
            return
        }

        // The polished final is recoverable before any last live-range
        // replacement. History is committed at the same boundary: cancelling
        // an in-flight AX replacement may restore the original document, but
        // it must never erase the user's completed utterance. Provisional text
        // never enters either durable surface.
        inserter.stageFinalOutput(text)
        recordHistory(
            text: text, raw: raw, context: sessionContext, mode: mode,
            cleanupMs: cleanupMs, cleanupApplied: cleanupApplied,
            cleanupWallMs: cleanupWallMs,
            finalizationMs: finalizationMs, audio: audio)
        let session = stream.session
        stream.draft.finish(text, mode: mode ?? stream.mode) { [weak self, weak draft = stream.draft] result in
            guard let self, let draft,
                  session == self.sessionID,
                  session != self.cancelledSessionID,
                  self.streamSession?.draft === draft
            else { return }
            self.streamSession = nil
            switch result {
            case .unavailable:
                // The target never exposed a safely replaceable live range.
                // Fall back to Velora's normal final-only delivery.
                self.finishInsertion(
                    text: text, raw: raw, mode: mode,
                    cleanupMs: cleanupMs, cleanupApplied: cleanupApplied,
                    cleanupWallMs: cleanupWallMs,
                    finalizationMs: finalizationMs, audio: audio,
                    finalOutputAlreadyStaged: true,
                    historyAlreadyRecorded: true,
                    expectedTargetElement:
                        stream.draft.finalInsertionTarget?.element)
            case .ownershipLost:
                self.phase = .idle
                self.showNotice(
                    symbol: "doc.on.clipboard.fill",
                    message: "Cursor changed — final copied")
            case .applied:
                self.inserter.resetContinuationContext()
                self.hud.transition(to: .inserted)
                self.phase = .idle
                self.lastInsertion = (
                    bundleID: self.sessionContext?.bundleID, at: Date())
                self.captureLearningBaseline(
                    text: text,
                    bundleID: self.sessionContext?.bundleID,
                    session: session)
                NotificationCenter.default.post(
                    name: .veloraDictationInserted, object: text)
                self.scheduleInsertedHide()
            }
            self.schedulePendingRecordingLimitNotice()
        }
    }

    private func finishDeferredStreamFinal(
        _ final: DeferredStreamFinal,
        after cancellation: StreamTypingSession.CancellationResult
    ) {
        guard final.session == sessionID,
              final.session != cancelledSessionID else { return }
        if !StreamTypingFinalPolicy.commandMayExecute(after: cancellation),
           StreamTypingFinalPolicy.voiceCommand(
            enabled: config.voiceCommands,
            text: final.text.trimmingCharacters(in: .whitespacesAndNewlines),
            raw: final.raw
           ) != nil {
            phase = .idle
            showNotice(
                symbol: "exclamationmark.arrow.triangle.2.circlepath",
                message: "Draft changed — command not run")
            schedulePendingRecordingLimitNotice()
            return
        }
        finishInsertion(
            text: final.text, raw: final.raw, mode: final.mode,
            cleanupMs: final.cleanupMs,
            cleanupApplied: final.cleanupApplied,
            cleanupWallMs: final.cleanupWallMs,
            finalizationMs: final.finalizationMs,
            audio: final.audio,
            allowAutomaticInsertion:
                StreamTypingFinalPolicy.commandMayExecute(after: cancellation)
                    && final.allowAutomaticInsertion)
        schedulePendingRecordingLimitNotice()
    }

    private func recordHistory(
        text: String, raw: String, context: AppContext?, mode: String?,
        cleanupMs: Int?, cleanupApplied: Bool?, cleanupWallMs: Int?,
        finalizationMs: Int?, audio: String?
    ) {
        let durationMs = recordingDurationMs ?? elapsedRecordingMs
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
                cleanupWallMs: cleanupWallMs,
                finalizationMs: finalizationMs,
                audioPath: audio,
                sessionID: sessionID.isEmpty ? nil : sessionID,
                sttMs: sttMs,
                cleanupApplied: cleanupApplied))
    }

    private var elapsedRecordingMs: Int {
        recordingStart.map { max(0, Int(-$0.timeIntervalSinceNow * 1_000)) } ?? 0
    }

    private func stopCaptureAndRestoreMedia() {
        capture.stop()
        mediaPlayback.restoreAfterDictation()
    }

    private func failExternalRequest(
        for session: String, error: ExternalDictationError
    ) {
        guard let request = externalRequest, request.session == session else { return }
        externalRequest = nil
        request.completion(.failure(error))
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
            // The undone text is gone; its tail must not shape the next insert.
            inserter.resetContinuationContext()
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
            // The caret moved to a fresh line (or the message was sent) — the
            // prior delivery is no longer adjacent to it.
            inserter.resetContinuationContext()
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
            self.flushDeferredLearnedToastIfPossible()
        }
    }

    private func schedulePendingRecordingLimitNotice(attempt: Int = 0) {
        guard phase == .idle,
              pendingRecordingLimitNoticeSeconds != nil,
              !recordingLimitNoticeScheduled
        else { return }
        recordingLimitNoticeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 1 : 0.5)) {
            [weak self] in
            guard let self else { return }
            self.recordingLimitNoticeScheduled = false
            guard self.phase == .idle,
                  let limitSeconds = self.pendingRecordingLimitNoticeSeconds
            else { return }
            guard self.hud.model.state.isAvailable else {
                // Normal insertion briefly owns the HUD's `.inserted` state,
                // while clipboard/error notices own it for up to 2.2 seconds.
                // Wait for those higher-priority outcomes instead of silently
                // losing the explanation for an automatic duration stop.
                if attempt < 6 {
                    self.schedulePendingRecordingLimitNotice(attempt: attempt + 1)
                }
                return
            }
            self.pendingRecordingLimitNoticeSeconds = nil
            self.showNotice(
                symbol: "clock.badge.exclamationmark",
                message: Self.recordingLimitMessage(seconds: limitSeconds))
        }
    }

    /// Keep the compact Copied confirmation readable before it fades.
    private func scheduleInsertedHide() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self] in
            guard let self, self.hud.model.state == .inserted else { return }
            self.hud.model.recordingStart = nil
            self.hud.transition(to: .hidden(.success))
            self.flushDeferredLearnedToastIfPossible()
        }
    }
}

// MARK: - HotkeyMonitorDelegate

extension DictationController: HotkeyMonitorDelegate {
    func nonHotkeyInput() {
        inserter.resetContinuationContext()
        clearSublimeCapture()
        // Sublime validates the exact view, selection, text, and buffer revision
        // when applying. Do not discard that stronger identity here: a click on
        // Velora's non-activating HUD is also observed as global mouse input.
    }

    func hotkeyDown() {
        guard sublimeApplyID == nil else {
            showNotice(symbol: "hourglass", message: "Finishing edit")
            return
        }
        if sublimeCaptureID != nil {
            clearSublimeCapture()
        }
        // Self-heal a wedged transcribe: normally `transcribeTimer` recovers,
        // but a missed event or a hung engine shouldn't strand the hotkey. If
        // we're still transcribing well past the timeout, reset to idle first
        // so this press starts a fresh dictation instead of being swallowed.
        if phase == .transcribing { resetIfStuckTranscribing() }

        switch (config.hotkeyMode, phase) {
        case (.toggle, .idle):
            startRecording(locked: true)
        case (.toggle, .starting):
            cancel()
        case (.toggle, .recording):
            stopAndTranscribe()
        case (.toggle, .transcribing):
            break

        case (.hold, .idle):
            hotkeyDownAt = Date()
            startRecording(locked: false)
        case (.hold, .starting(locked: true)):
            cancel()
        case (.hold, .starting(locked: false)):
            break
        case (.hold, .recording(locked: true)):
            // Tap while locked → finish.
            stopAndTranscribe()
        case (.hold, .recording(locked: false)), (.hold, .transcribing):
            break
        }
    }

    func hotkeyUp() {
        guard config.hotkeyMode == .hold else { return }
        let heldFor = hotkeyDownAt.map { -$0.timeIntervalSinceNow } ?? 0
        if case .starting(locked: false) = phase {
            if heldFor >= Self.tapThreshold {
                stopAfterCaptureStarts = true
            } else {
                phase = .starting(locked: true)
            }
            return
        }
        guard case .recording(locked: false) = phase else { return }

        if heldFor >= Self.tapThreshold {
            stopAndTranscribe()
        } else {
            // Short tap: recording locks on; the next tap (or Esc) ends it.
            NSLog("Velora: tap (%.0f ms) — recording locked on", heldFor * 1000)
            phase = .recording(locked: true)
        }
    }

    func secondaryHotkeyDown(_ role: SecondaryHotkeyRole) {
        switch role {
        case .edit: editHotkeyDown()
        case .stream: streamHotkeyDown()
        case .action: actionHotkeyDown()
        }
    }

    func secondaryHotkeyUp(_ role: SecondaryHotkeyRole) {
        switch role {
        case .edit: editHotkeyUp()
        case .stream: streamHotkeyUp()
        case .action: actionHotkeyUp()
        }
    }

    private func beginStreamSession(locked: Bool) {
        guard phase == .idle, sublimeCaptureID == nil else { return }
        // Read the live owner first; the activation observer can trail a newly
        // focused editor by one run-loop turn.
        let inputGeneration = UserInputActivity.snapshot()
        let app = NSWorkspace.shared.frontmostApplication
            ?? contextTracker.frontmost
        let nativeTarget = ScreenContext.streamTarget(of: app)
        let shouldCaptureKeystrokeTarget = nativeTarget == nil
            && app?.bundleIdentifier != SublimeTextSelectionBridge.bundleID
        let keystrokeTarget = shouldCaptureKeystrokeTarget
            ? ScreenContext.keystrokeStreamTarget(of: app)
            : nil
        let previewTarget = shouldCaptureKeystrokeTarget
            && keystrokeTarget == nil
            ? ScreenContext.streamPreviewTarget(of: app)
            : nil
        switch StreamTargetRouting.route(
            bundleID: app?.bundleIdentifier,
            nativeTargetAvailable: nativeTarget != nil,
            keystrokeTargetAvailable: keystrokeTarget != nil,
            previewTargetAvailable: previewTarget != nil
        ) {
        case .accessibility:
            guard let nativeTarget else { return }
            startStreamRecording(
                draft: StreamTypingSession(
                    target: nativeTarget,
                    inputGeneration: inputGeneration),
                app: app,
                locked: locked)
        case .sublime:
            guard let app else { return }
            beginSublimeStreamCapture(
                app: app,
                locked: locked,
                inputGeneration: inputGeneration)
        case .keystroke:
            guard let keystrokeTarget else { return }
            veloraLog(
                "Velora: stream target route=keystroke app="
                    + keystrokeTarget.bundleID)
            startStreamRecording(
                draft: KeystrokeStreamTypingSession(
                    target: keystrokeTarget,
                    inputGeneration: inputGeneration),
                app: app,
                locked: locked)
        case .preview:
            guard let previewTarget else { return }
            veloraLog(
                "Velora: stream target route=preview app="
                    + previewTarget.bundleID)
            let draft = StreamPreviewTypingSession(
                target: previewTarget,
                inputGeneration: inputGeneration
            ) { [weak self] text in
                self?.hud.model.liveTranscript = text
            }
            startStreamRecording(
                draft: draft,
                app: app,
                locked: locked,
                hudLabel: "Stream Preview",
                livePreview: true)
        case .unavailable:
            veloraLog(
                "Velora: stream target unavailable in "
                    + (app?.bundleIdentifier ?? "unknown"))
            showNotice(
                symbol: "text.cursor",
                message: "Stream Typing isn't available in this field")
        }
    }

    private func beginSublimeStreamCapture(
        app: NSRunningApplication,
        locked: Bool,
        inputGeneration: UInt64
    ) {
        let captureID = UUID()
        sublimeCaptureID = captureID
        sublimeCaptureLocksRecording = locked
        sublimeCaptureReleasedBeforeStart = false
        sublimeQueue.async { [weak self] in
            let result = SublimeTextSelectionBridge.captureStream(of: app)
            DispatchQueue.main.async {
                guard let self, self.sublimeCaptureID == captureID else {
                    if case .success(let capture) = result {
                        DispatchQueue.global(qos: .utility).async {
                            _ = capture.token.cancel()
                        }
                    }
                    return
                }
                let captureLocksRecording = self.sublimeCaptureLocksRecording
                let releasedBeforeStart =
                    self.sublimeCaptureReleasedBeforeStart
                self.clearSublimeCapture()
                guard self.phase == .idle,
                      inputGeneration == UserInputActivity.snapshot(),
                      NSWorkspace.shared.frontmostApplication?
                          .processIdentifier == app.processIdentifier
                else {
                    if case .success(let capture) = result {
                        DispatchQueue.global(qos: .utility).async {
                            _ = capture.token.cancel()
                        }
                    }
                    return
                }
                switch result {
                case .success(let capture):
                    guard !releasedBeforeStart else {
                        DispatchQueue.global(qos: .utility).async {
                            _ = capture.token.cancel()
                        }
                        self.showNotice(
                            symbol: "text.cursor",
                            message: "Sublime Text took too long — retry Stream")
                        return
                    }
                    self.startStreamRecording(
                        draft: SublimeStreamTypingSession(
                            capture: capture,
                            inputGeneration: inputGeneration),
                        app: app,
                        locked: captureLocksRecording)
                case .failure(.multipleSelections):
                    self.showNotice(
                        symbol: "text.cursor",
                        message: "Use one cursor or selection for Stream")
                case .failure(.selectionTooLong):
                    self.showNotice(
                        symbol: "text.cursor",
                        message: "Select fewer than 8,000 characters for Stream")
                case .failure(.unsupportedView):
                    self.showNotice(
                        symbol: "text.cursor",
                        message: "Stream works in a Sublime document, not Find or Console")
                case .failure(.integrationNeedsRestart):
                    self.showNotice(
                        symbol: "arrow.clockwise",
                        message: "Restart Sublime Text once, then retry Stream")
                case .failure(.emptySelection),
                     .failure(.integrationUnavailable):
                    self.showNotice(
                        symbol: "text.cursor",
                        message: "Couldn't connect Stream to Sublime Text")
                }
            }
        }
    }

    private func startStreamRecording(
        draft: LiveStreamDraftSession,
        app: NSRunningApplication?,
        locked: Bool,
        hudLabel: String = "Stream",
        livePreview: Bool = false
    ) {
        let mode = ModeApplicationIndex.shared.modeName(
            forBundleID: app?.bundleIdentifier)
            ?? ModeCategory.displayName(forBundleID: app?.bundleIdentifier)
        guard startRecording(
            locked: locked,
            hudLabel: hudLabel,
            streamTyping: true,
            livePreview: livePreview,
            targetAppOverride: app)
        else {
            draft.cancel(completion: nil)
            return
        }
        streamSession = (session: sessionID, draft: draft, mode: mode)
        NSLog(
            "Velora: stream session started — liveTarget=owned app=%@",
            app?.bundleIdentifier ?? "unknown")
    }

    private func cancelStreamDraft(
        completion: ((StreamTypingSession.CancellationResult) -> Void)? = nil
    ) {
        guard let stream = streamSession else {
            completion?(.noDraft)
            return
        }
        streamSession = nil
        streamCancellation = stream
        stream.draft.cancel { [weak self, weak draft = stream.draft] result in
            guard let self, let draft,
                  self.streamCancellation?.draft === draft else { return }
            self.streamCancellation = nil
            completion?(result)
            if let final = self.deferredStreamFinal,
               final.session == stream.session {
                self.deferredStreamFinal = nil
                self.finishDeferredStreamFinal(final, after: result)
            }
        }
    }

    private func streamHotkeyDown() {
        if sublimeCaptureID != nil {
            cancel()
            return
        }
        if phase == .transcribing { resetIfStuckTranscribing() }
        let isStreamRecording = streamSession?.session == sessionID && isRecording

        switch (config.hotkeyMode, phase) {
        case (.toggle, .idle):
            beginStreamSession(locked: true)
        case (.toggle, .starting) where isStreamRecording:
            cancel()
        case (.toggle, .recording) where isStreamRecording:
            stopAndTranscribe()
        case (.hold, .idle):
            hotkeyDownAt = Date()
            beginStreamSession(locked: false)
        case (.hold, .starting(locked: true)) where isStreamRecording:
            cancel()
        case (.hold, .recording(locked: true)) where isStreamRecording:
            stopAndTranscribe()
        default:
            break
        }
    }

    private func streamHotkeyUp() {
        guard config.hotkeyMode == .hold else { return }
        if phase == .idle, sublimeCaptureID != nil {
            let heldFor = hotkeyDownAt.map { -$0.timeIntervalSinceNow } ?? 0
            switch Self.delayedEditCaptureRelease(heldFor: heldFor) {
            case .lockRecording:
                sublimeCaptureLocksRecording = true
            case .cancel:
                sublimeCaptureReleasedBeforeStart = true
            }
            return
        }
        guard streamSession?.session == sessionID else { return }
        let heldFor = hotkeyDownAt.map { -$0.timeIntervalSinceNow } ?? 0
        if case .starting(locked: false) = phase {
            if heldFor >= Self.tapThreshold {
                stopAfterCaptureStarts = true
            } else {
                phase = .starting(locked: true)
            }
            return
        }
        guard case .recording(locked: false) = phase else { return }
        if heldFor >= Self.tapThreshold {
            stopAndTranscribe()
        } else {
            NSLog("Velora: stream tap (%.0f ms) — recording locked on", heldFor * 1000)
            phase = .recording(locked: true)
        }
    }

    /// Action Mode hotkey: hold, speak a command, release. Shares the dictation
    /// hold/toggle semantics, and like Safe Voice Edit only ever starts from
    /// idle — it never interrupts a dictation that is already running.
    private func actionHotkeyDown() {
        if phase == .transcribing { resetIfStuckTranscribing() }
        let isActionRecording = actionSession == sessionID && isRecording

        switch (config.hotkeyMode, phase) {
        case (.toggle, .idle):
            beginActionSession(locked: true)
        case (.toggle, .starting) where isActionRecording:
            cancel()
        case (.toggle, .recording) where isActionRecording:
            stopAndTranscribe()
        case (.hold, .idle):
            hotkeyDownAt = Date()
            beginActionSession(locked: false)
        case (.hold, .starting(locked: true)) where isActionRecording:
            cancel()
        case (.hold, .recording(locked: true)) where isActionRecording:
            stopAndTranscribe()
        default:
            break
        }
    }

    private func actionHotkeyUp() {
        guard config.hotkeyMode == .hold, actionSession == sessionID else { return }
        let heldFor = hotkeyDownAt.map { -$0.timeIntervalSinceNow } ?? 0
        if case .starting(locked: false) = phase {
            if heldFor >= Self.tapThreshold {
                stopAfterCaptureStarts = true
            } else {
                phase = .starting(locked: true)
            }
            return
        }
        guard case .recording(locked: false) = phase else { return }
        if heldFor >= Self.tapThreshold {
            stopAndTranscribe()
        } else {
            NSLog("Velora: action tap (%.0f ms) — recording locked on", heldFor * 1000)
            phase = .recording(locked: true)
        }
    }

    /// Starts recording a command. "Raw" mode: the planner needs the words as
    /// spoken — cleanup would rewrite the very names that identify a person or
    /// an app ("Himesh" → "Hi, mesh").
    private func beginActionSession(locked: Bool) {
        guard Permissions.accessibilityGranted, TextInserter.canPostEvents else {
            showError("Action Mode needs Accessibility permission")
            return
        }
        let origin = contextTracker.frontmost ?? NSWorkspace.shared.frontmostApplication
        guard startRecording(locked: locked, explicitMode: "Raw", hudLabel: "Action") else {
            return
        }
        actionSession = sessionID
        actionOriginApp = origin
        actionScreenNames = []
        // Harvested while the user is still speaking: the walk is bounded but
        // not instant, and the hotkey path must not wait on Electron's AX tree.
        let harvestSession = sessionID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let names = ScreenContext.visibleNames(of: origin)
            DispatchQueue.main.async {
                guard let self, self.actionSession == harvestSession else { return }
                self.actionScreenNames = names
                NSLog("Velora: action screen names — %ld found", names.count)
            }
        }
        NSLog("Velora: action session started (from %@)",
              origin?.localizedName ?? "unknown")
    }

    /// Safe Voice Edit hotkey: same hold/toggle semantics as dictation, but
    /// only ever starts when idle with a selection — it never interrupts a
    /// dictation in progress.
    private func editHotkeyDown() {
        guard sublimeApplyID == nil else {
            showNotice(symbol: "hourglass", message: "Finishing edit")
            return
        }
        if sublimeCaptureID != nil {
            cancel()
            return
        }
        if phase == .transcribing { resetIfStuckTranscribing() }
        let isEditRecording = editSession?.session == sessionID && isRecording

        switch (config.hotkeyMode, phase) {
        case (.toggle, .idle):
            beginEditSession(locked: true)
        case (.toggle, .starting) where isEditRecording:
            cancel()
        case (.toggle, .recording) where isEditRecording:
            stopAndTranscribe()
        case (.hold, .idle):
            hotkeyDownAt = Date()
            beginEditSession(locked: false)
        case (.hold, .starting(locked: true)) where isEditRecording:
            cancel()
        case (.hold, .recording(locked: true)) where isEditRecording:
            stopAndTranscribe()
        default:
            break
        }
    }

    private func editHotkeyUp() {
        guard config.hotkeyMode == .hold else { return }
        if phase == .idle, sublimeCaptureID != nil {
            let heldFor = hotkeyDownAt.map { -$0.timeIntervalSinceNow } ?? 0
            switch Self.delayedEditCaptureRelease(heldFor: heldFor) {
            case .lockRecording:
                sublimeCaptureLocksRecording = true
            case .cancel:
                sublimeCaptureReleasedBeforeStart = true
            }
            return
        }
        guard editSession?.session == sessionID else { return }
        let heldFor = hotkeyDownAt.map { -$0.timeIntervalSinceNow } ?? 0
        if case .starting(locked: false) = phase {
            if heldFor >= Self.tapThreshold {
                stopAfterCaptureStarts = true
            } else {
                phase = .starting(locked: true)
            }
            return
        }
        guard case .recording(locked: false) = phase else { return }

        if heldFor >= Self.tapThreshold {
            stopAndTranscribe()
        } else {
            NSLog("Velora: edit tap (%.0f ms) — recording locked on", heldFor * 1000)
            phase = .recording(locked: true)
        }
    }

    func escapePressed() {
        // Esc is the universal abort. A running plan is driving other apps'
        // windows, so it is the thing the user most urgently wants stopped —
        // and it runs while `phase` is idle, so it must be checked first.
        if actionsStorage?.isRunning == true {
            actionsStorage?.cancel()
            NSLog("Velora: action cancelled by Esc")
            // Only swallow Esc while steps are actually running. While a plan is
            // merely being planned nothing is touching the machine, and Esc
            // still belongs to whatever else is on screen.
            if actionsStorage?.isExecuting == true { return }
        }
        switch phase {
        case .starting, .recording, .transcribing:
            cancel()
        case .idle:
            if sublimeCaptureID != nil || sublimeApplyID != nil {
                cancel()
                return
            }
            // Dismiss a lingering error HUD.
            if case .error = hud.model.state {
                hud.transition(to: .hidden(.cancel))
                flushDeferredLearnedToastIfPossible()
            }
        }
    }
}
