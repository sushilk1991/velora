import AppKit
import ApplicationServices
import Foundation

/// Runtime-only identities needed for capability-level policy.
enum ActionRuntimePolicy {
    /// Browser identities are used for page-URL observations only. They do
    /// not grant a separate set of controls that Action Mode may press.
    static let browserBundleIDs: Set<String> = Set(
        ModeCategory.byBundleID
            .filter { $0.value == .browser }
            .map { $0.key.lowercased() })

    static func isBrowserBundle(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return browserBundleIDs.contains(bundleID.lowercased())
    }

}

enum ActionVerificationPurpose: Equatable {
    case target
    case goal
}

enum ActionInteractionState: Equatable {
    case ready
    case deferred
    case refused
}

struct ActionWindowIdentity: Equatable {
    let name: String
    let bundleID: String
    let pid: Int
    let windowID: Int
    let processIdentity: CuaProcessIdentity?

    init(
        name: String, bundleID: String, pid: Int, windowID: Int,
        processIdentity: CuaProcessIdentity? = nil
    ) {
        self.name = name
        self.bundleID = bundleID
        self.pid = pid
        self.windowID = windowID
        self.processIdentity = processIdentity?.pid == pid_t(pid)
            ? processIdentity : nil
    }
}

struct ActionProcessIdentity: Equatable {
    let name: String
    let bundleID: String
    let pid: Int
    let processIdentity: CuaProcessIdentity?

    init(
        name: String, bundleID: String, pid: Int,
        processIdentity: CuaProcessIdentity? = nil
    ) {
        self.name = name
        self.bundleID = bundleID
        self.pid = pid
        self.processIdentity = processIdentity?.pid == pid_t(pid)
            ? processIdentity : nil
    }
}

enum ActionMediaControlResult: Equatable {
    case verified
    case unavailable
    case misdirected
}

struct ActionStateReceipt: Equatable {
    let id: String
    let appName: String
    let bundleID: String
    let pid: Int
    let windowID: Int
    let snapshotID: String
    let assertion: ActionStateAssertion
    let mutationOrdinal: Int
    let processIdentity: CuaProcessIdentity?

    init(
        id: String, appName: String, bundleID: String,
        pid: Int, windowID: Int, snapshotID: String,
        assertion: ActionStateAssertion, mutationOrdinal: Int,
        processIdentity: CuaProcessIdentity? = nil
    ) {
        self.id = id
        self.appName = appName
        self.bundleID = bundleID
        self.pid = pid
        self.windowID = windowID
        self.snapshotID = snapshotID
        self.assertion = assertion
        self.mutationOrdinal = mutationOrdinal
        self.processIdentity = processIdentity?.pid == pid_t(pid)
            ? processIdentity : nil
    }
}

/// Everything the executor needs from the machine. Split out from the executor
/// so the step logic — which is where a bug sends a message to the wrong person
/// — can be exercised headlessly against a scripted host.
protocol ActionHost: AnyObject {
    /// Clears exact text-target/draft ownership at the boundary between user
    /// actions. The host itself survives across planner turns within one run.
    func beginActionInputSession(command: String)
    /// Drops every retained input capability and any owned automation child.
    func endActionInputSession()
    /// Records whether this plan may commit user-authored content.
    func prepareForActionPlan(sends: Bool)
    /// Rechecks that the user has not entered the exact background target.
    func prepareInteraction() -> ActionInteractionState
    /// Launch or switch to an app; returns the name it actually resolved to.
    func openApp(named name: String) -> String?
    /// Switch to the already-resolved running app without fuzzy re-resolution.
    func openApp(named name: String, bundleID: String, pid: Int) -> String?
    func openURL(_ url: URL) -> Bool
    /// (localizedName, bundleIdentifier) of the frontmost app.
    func frontmostApp() -> (name: String, bundleID: String)?
    /// Title of the frontmost window, if readable.
    func frontmostWindowTitle() -> String?
    /// App-authored label of the focused element (description/placeholder/title).
    /// Never the field's value — that is the plan's own typed text.
    func focusedElementLabel() -> String?
    /// App-authored label of the highlighted row near the focused element (a
    /// quick switcher's selected result), if any.
    func focusedSelectionLabel() -> String?
    /// AX role of the focused element ("AXTextField"), for observations.
    func focusedElementRole() -> String?
    /// Name-like labels visible in the frontmost window — what the model gets
    /// to look at between turns.
    func visibleNames() -> [String]
    /// Structured, hierarchy-preserving view of the current target window.
    /// The model receives the serializable observation; the host retains the
    /// local AX capabilities that make its element indices meaningful.
    func uiSnapshot() -> ActionUISnapshot?
    /// True when `visibleNames()` really is what the USER can see. The
    /// open_url data fence admits screen names as "the spelling on screen",
    /// which only holds for a window in front of the user; labels read out
    /// of a background window the user cannot see are not that, and letting
    /// them authorize URL content would reopen the exfiltration class the
    /// fence exists to close.
    var screenNamesAreUserVisible: Bool { get }
    /// True while the host is driving a window the user cannot see.
    ///
    /// A `wait_frontmost` that has not been satisfied must not try to fix
    /// focus in that mode: there, the wait is polling the background target's
    /// readiness, and asking the host to open the app again would either
    /// unpin the window it is already typing into or fall back to the
    /// foreground and take the user's screen — the one thing background
    /// execution promises not to do.
    var isDrivingInBackground: Bool { get }
    /// URL of the frontmost page when a browser is frontmost, else nil.
    func frontmostPageURL() -> String?
    /// Press the on-screen control whose label matches. Label-addressed AX
    /// action — never a coordinate, never a synthesized click.
    func pressElement(label: String, expecting bundleID: String?) -> Bool
    /// Press an exact element selected from `uiSnapshot`. Implementations
    /// must refuse a stale snapshot or changed app/label/role.
    func pressElement(index: Int, snapshotID: String, label: String,
                      role: String, expecting bundleID: String?) -> Bool
    /// Re-read exact model-selected evidence without performing an action.
    func verifyElement(index: Int, snapshotID: String, label: String,
                       role: String, target: String,
                       expecting bundleID: String?,
                       purpose: ActionVerificationPurpose) -> Bool
    /// Exact ordinary window currently in front, including WindowServer id.
    func foregroundWindow() -> ActionWindowIdentity?
    /// Exact window owned by this action. A background host returns its routed
    /// target; a foreground host returns the user's current window.
    func actionWindow() -> ActionWindowIdentity?
    /// Exact process acquired by this action. Windowless regular apps retain
    /// process identity without gaining any UI capability.
    func actionProcess() -> ActionProcessIdentity?
    /// Opaque app-native capabilities bound to the current exact process.
    func mediaCapabilities() -> [ActionNativeCapability]
    /// Presses an exact Cua capability, then proves the acquired PID's state.
    func mediaControl(_ control: ActionMediaControl) -> ActionMediaControlResult
    /// Present the engine-attested routed app or window and leave it in front.
    func presentUI(snapshotID: String, bundleID: String, windowID: Int,
                   scope: ActionPresentationScope) -> Bool
    /// Exact partial-tree write selected by the engine's current Cua snapshot.
    func typeText(_ text: String, target: ActionTextTarget,
                  expecting bundleID: String?) -> ActionStateReceipt?
    /// Full-value write for an explicit replacement or navigation search.
    func replaceText(_ text: String, target: ActionTextTarget,
                     expecting bundleID: String?) -> ActionStateReceipt?
    /// Navigation-only query write. It never establishes document draft
    /// ownership for a later content write or commit.
    func searchText(_ text: String, target: ActionTextTarget,
                    expecting bundleID: String?) -> ActionStateReceipt?
    /// Bounded positive state proof. Implementations build every driver
    /// predicate; the plan cannot supply process/window or polling mechanics.
    func verifyState(_ check: ActionStateCheck,
                     expecting bundleID: String?) -> ActionStateReceipt?
    func typeText(_ text: String, expecting bundleID: String?) -> Bool
    func pasteText(_ text: String, expecting bundleID: String?) -> Bool
    /// `expecting` is the bundle id the plan established focus on. The Return
    /// that commits a send is the one keystroke that must not be posted a
    /// moment after focus moved. The plan's own key name and modifier words
    /// ride along because a background host delivers by NAME (the driver's
    /// vocabulary), while the foreground host posts the key CODE.
    func pressKey(name: String, mods: [String], keyCode: CGKeyCode,
                  flags: CGEventFlags, expecting bundleID: String?) -> Bool
    /// False when a keystroke must not be synthesized right now (permission
    /// missing, or a password field has secure input up).
    var canPostInput: Bool { get }
    /// True only after the host captures a proven editable AX text field with
    /// a readable empty selection. Generic focused surfaces can interpret
    /// synthesized characters as application shortcuts.
    var hasFocusedTextTarget: Bool { get }
    /// True when the login window owns the screen. Nothing can be driven then,
    /// and the generic "app didn't come to the front" failure would send the
    /// user hunting for a bug that is really just a locked Mac.
    var screenIsLocked: Bool { get }
    /// Terminal host failure that a retry or foreground recovery cannot fix.
    var actionFailureReason: String? { get }
    func sleep(ms: Int)
    /// Monotonic seconds, for wait timeouts.
    func now() -> TimeInterval
}

extension ActionHost {
    /// Foreground hosts drive the window the user is looking at.
    var isDrivingInBackground: Bool { false }
    var actionFailureReason: String? { nil }
    func beginActionInputSession() {
        beginActionInputSession(command: "")
    }
    func endActionInputSession() {}
    func prepareForActionPlan(sends: Bool) {}
    func prepareInteraction() -> ActionInteractionState { .ready }
    func openApp(named name: String, bundleID: String, pid: Int) -> String? {
        nil
    }
    func uiSnapshot() -> ActionUISnapshot? { nil }
    func pressElement(index: Int, snapshotID: String, label: String,
                      role: String, expecting bundleID: String?) -> Bool {
        pressElement(label: label, expecting: bundleID)
    }
    func verifyElement(index: Int, snapshotID: String, label: String,
                       role: String, target: String,
                       expecting bundleID: String?,
                       purpose: ActionVerificationPurpose) -> Bool {
        false
    }
    func foregroundWindow() -> ActionWindowIdentity? { nil }
    func actionWindow() -> ActionWindowIdentity? { foregroundWindow() }
    func actionProcess() -> ActionProcessIdentity? {
        guard let window = actionWindow() else { return nil }
        return ActionProcessIdentity(
            name: window.name, bundleID: window.bundleID, pid: window.pid,
            processIdentity: window.processIdentity)
    }
    func mediaCapabilities() -> [ActionNativeCapability] {
        guard let target = actionProcess() else { return [] }
        return NativeMediaAutomation.shared.capabilities(for: target)
    }
    func mediaControl(_ control: ActionMediaControl) -> ActionMediaControlResult {
        guard let target = actionProcess() else { return .unavailable }
        return NativeMediaAutomation.shared.perform(
            control, target: target, maySend: { true })
    }
    func presentUI(snapshotID: String, bundleID: String, windowID: Int,
                   scope: ActionPresentationScope) -> Bool {
        false
    }
    func typeText(_ text: String, target: ActionTextTarget,
                  expecting bundleID: String?) -> ActionStateReceipt? { nil }
    func replaceText(_ text: String, target: ActionTextTarget,
                     expecting bundleID: String?) -> ActionStateReceipt? { nil }
    func searchText(_ text: String, target: ActionTextTarget,
                    expecting bundleID: String?) -> ActionStateReceipt? { nil }
    func verifyState(_ check: ActionStateCheck,
                     expecting bundleID: String?) -> ActionStateReceipt? { nil }
}

enum ActionOutcome: Equatable {
    case completed
    /// `recoverable` marks failures another turn of the loop can react to —
    /// a checkpoint that did not match, a label that was not on screen. A
    /// non-recoverable failure (secure input, a locked screen, stolen focus)
    /// ends the whole action: it is not something a smarter plan fixes.
    case failed(step: Int, reason: String, recoverable: Bool)
    case cancelled(step: Int)

    var isSuccess: Bool { self == .completed }
}

/// Machine observations emitted by the executor for deterministic completion
/// decisions. These are deliberately typed events, not strings recovered from
/// the human-readable trace.
enum ActionEvidenceEvent: Equatable {
    case appOpenRequested(requested: String, resolved: String)
    case frontmostConfirmed(requested: String, actual: String, bundleID: String)
    case uiTargetVerified(target: String)
    case goalVerified(target: String)
    case localGoalVerified(ActionLocalProof)
    case stateVerified(ActionStateReceipt, expectedValue: String?)
    case targetResolved(ActionCompletionTarget)
    case unverifiedEffect(ActionEffectKind)
}

enum ActionEffectKind: Equatable {
    case openURL
    case typeText
    case pasteText
    case key
    case pressElement
    case presentUI
}

struct ActionRunResult: Equatable {
    let outcome: ActionOutcome
    /// One line per attempted step — the DURABLE rendering, safe for the
    /// log file and the task ledger. Typed text appears as a count only.
    let trace: [String]
    /// The same lines with the plan's typed text quoted, for the planner's
    /// next observation and nothing else. A bare "5 chars" left the model
    /// unable to tell its words were already in, and it retyped chunks
    /// until the turn budget died (observed live).
    let observationTrace: [String]
    /// How many steps fully completed. The loop recomputes its carried safety
    /// state from THIS, not from the batch as written — a verify_context that
    /// failed at runtime must not count as having verified anything.
    let executedSteps: Int
    let evidence: [ActionEvidenceEvent]
}

/// Runs a validated plan, re-checking safety at every step.
///
/// The invariants it enforces at runtime — none of which the plan can waive:
///
/// * a plan is re-validated before it runs, so a plan that arrived from
///   anywhere but the engine still has to pass the same gate;
/// * input steps abort unless the frontmost app is still the one the plan
///   established focus on, so a user switching windows mid-plan (or a slow
///   app losing focus) stops the plan instead of typing into whatever is there;
/// * `verify_context` failing is fatal, not a warning — it is the check that
///   stands between "message Himesh" and messaging whoever Slack's quick
///   switcher happened to highlight;
/// * `cancel()` is honoured between every step.
final class ActionExecutor {
    /// How long a `verify_context` step waits for the screen to catch up
    /// before deciding the state it wanted never arrived.
    static let verifySettleSeconds: TimeInterval = 2.5
    /// How long a named app gets to come forward on its own before Velora
    /// asks it to, and how long it then gets to arrive.
    static let focusRecoveryAfterMs = 700
    static let focusRecoveryTimeoutMs = 3000
    /// AXPress returns when the action is accepted, not when an asynchronous
    /// app has published the resulting hierarchy. Without this small generic
    /// settle, the next observation can re-read the pre-press tree and spend
    /// a multi-second model turn repeating the same navigation control.
    static let indexedPressSettleMs = 250
    /// Electron exposes focus asynchronously after an exact AX focus action.
    /// A short bounded poll distinguishes "not yet" from "not focused" without
    /// weakening the editable-target requirement.
    static let textFocusSettleSeconds: TimeInterval = 0.75

    private let host: ActionHost
    private let progress: (ActionProgress) -> Void
    /// Written on the main queue by `cancel()`, read on the executor's
    /// background queue. Locked rather than left to arm64's incidental
    /// coherence, matching `UserInputActivity` in HotkeyMonitor.
    private let cancelLock = NSLock()
    private var cancelledStorage = false
    private var cancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelledStorage
    }
    /// The app the plan has established focus on, and its bundle id once seen.
    private var expectedAppName: String?
    private var expectedBundleID: String?
    /// One focus recovery per batch. An app that refuses to come forward twice
    /// is not going to come forward a third time, and each attempt costs the
    /// user real seconds.
    private var triedFocusRecovery = false
    private var verifiedUITarget = false

    init(host: ActionHost,
         progress: @escaping (ActionProgress) -> Void = { _ in }) {
        self.host = host
        self.progress = progress
    }

    func cancel() {
        cancelLock.lock()
        cancelledStorage = true
        cancelLock.unlock()
    }

    func run(_ plan: ActionPlan) -> ActionRunResult {
        var trace: [String] = []
        /// Parallel to `trace`, differing only where a line carries content
        /// that must not reach a durable sink.
        var observationTrace: [String] = []
        var evidence: [ActionEvidenceEvent] = []

        /// Appends one line to both renderings.
        func note(_ line: String, observed: String? = nil) {
            trace.append(line)
            observationTrace.append(observed ?? line)
        }

        /// Failure at `index`: exactly the steps before it completed.
        func failed(_ index: Int, _ reason: String,
                    recoverable: Bool) -> ActionRunResult {
            ActionRunResult(
                outcome: .failed(step: index, reason: reason, recoverable: recoverable),
                trace: trace, observationTrace: observationTrace,
                executedSteps: index, evidence: evidence)
        }

        guard plan.isExecutable else {
            return failed(0, "nothing to do", recoverable: false)
        }
        // Checked up front rather than per step: on a locked Mac every plan
        // fails, and it should say why instead of blaming the target app.
        guard !host.screenIsLocked else {
            note("blocked: screen locked")
            return failed(0, "the screen is locked", recoverable: false)
        }

        for (index, step) in plan.steps.enumerated() {
            if case .verifyUI = step {
                progress(.verifyingTarget)
            } else if case .verifyGoal = step {
                progress(.verifyingTarget)
            } else if case .verifyState = step {
                progress(.verifyingTarget)
            } else {
                progress(.executing(
                    step: index + 1, total: plan.steps.count,
                    description: Self.progressDescription(step)))
            }
            if cancelled {
                return ActionRunResult(outcome: .cancelled(step: index), trace: trace,
                                       observationTrace: observationTrace,
                                       executedSteps: index, evidence: evidence)
            }
            // Permission and secure-input state can change mid-plan (the user
            // clicks a password field between steps).
            if step.isInput, !host.canPostInput {
                note("blocked: input not permitted")
                return failed(index, "keyboard input is not permitted right now",
                              recoverable: false)
            }
            if Self.mutatesUI(step) {
                switch host.prepareInteraction() {
                case .ready:
                    break
                case .deferred:
                    note("interaction boundary: target app is in use")
                    return failed(
                        index, "waiting for the target app to be free",
                        recoverable: true)
                case .refused:
                    note("interaction boundary: exact handoff refused")
                    return failed(
                        index, host.actionFailureReason
                            ?? "the target window could not be presented safely",
                        recoverable: false)
                }
            }

            switch step {
            case .openApp(let name):
                guard let resolved = host.openApp(named: name) else {
                    note("open_app \(name): not found")
                    return failed(index, "couldn't find an app called \(name)",
                                  recoverable: true)
                }
                // Both cleared: activation is advisory, so until a
                // wait_frontmost confirms it, "we asked for Slack" is not
                // "Slack is in front". Keeping the name alone would let the
                // following type_text run with `expecting: nil`, which switches
                // off the per-chunk target check inside TextInserter.
                expectedAppName = nil
                expectedBundleID = nil
                verifiedUITarget = false
                evidence.append(.appOpenRequested(
                    requested: Self.evidenceText(name, limit: 120),
                    resolved: Self.evidenceText(resolved, limit: 120)))
                note("open_app \(resolved)")

            case .openURL(let url):
                guard host.openURL(url) else {
                    note("open_url \(url.scheme ?? "?"): failed")
                    return failed(index, "couldn't open that link", recoverable: true)
                }
                // A URL hands off to whichever app owns the scheme; the plan
                // must re-establish focus before it may type.
                expectedAppName = nil
                expectedBundleID = nil
                verifiedUITarget = false
                evidence.append(.unverifiedEffect(.openURL))
                note("open_url \(url.scheme ?? "?")")

            case .waitFrontmost(let app, let timeoutMs):
                // Waiting alone never made anything happen. A plan that
                // checkpoints before opening its app — which a small planner
                // writes constantly — burned every turn on an eight-second
                // wait for a window nobody had asked for (observed live:
                // seven identical timeouts, then `open_app` on the last turn).
                // Ask once, then keep waiting. This grants no new power: it is
                // the same activation `open_app` performs with the same app
                // name, and in background-routing mode the host keeps driving
                // the off-screen window instead of taking the screen.
                // Never in background mode: there the wait polls this host's
                // own readiness, and re-opening would unpin the window being
                // driven or fall back to the foreground and take the screen.
                let mayRecoverFocus = !host.isDrivingInBackground
                    && !triedFocusRecovery
                // Ask early. Recovering only after the full timeout expired
                // meant the user watched the whole eight seconds elapse before
                // anything was attempted.
                let firstLook = mayRecoverFocus
                    ? min(timeoutMs, Self.focusRecoveryAfterMs) : timeoutMs
                var front = waitForFrontmost(app, timeoutMs: firstLook)
                if front == nil, !cancelled, mayRecoverFocus {
                    triedFocusRecovery = true
                    if let resolved = host.openApp(named: app) {
                        note("wait_frontmost \(app): asked \(resolved) to come forward")
                        // Recorded like any other activation. It may have
                        // LAUNCHED the app; a turn that did that and then
                        // failed must not report "nothing effective to do".
                        evidence.append(.appOpenRequested(
                            requested: Self.evidenceText(app, limit: 120),
                            resolved: Self.evidenceText(resolved, limit: 120)))
                        front = waitForFrontmost(
                            app,
                            timeoutMs: max(timeoutMs - firstLook,
                                           Self.focusRecoveryTimeoutMs))
                    }
                }
                guard let front else {
                    if let reason = host.actionFailureReason {
                        note("wait_frontmost \(app): terminal host refusal")
                        return failed(index, reason, recoverable: false)
                    }
                    let actual = host.frontmostApp()?.name ?? "nothing"
                    note("wait_frontmost \(app): timed out (front: \(actual)) — "
                         + "\(app) will not come forward; do not wait for it again")
                    return failed(index, "\(app) didn't come to the front",
                                  recoverable: true)
                }
                expectedAppName = front.name
                expectedBundleID = front.bundleID
                verifiedUITarget = false
                evidence.append(.frontmostConfirmed(
                    requested: Self.evidenceText(app, limit: 120),
                    actual: Self.evidenceText(front.name, limit: 120),
                    bundleID: Self.evidenceText(front.bundleID, limit: 256)))
                if let window = host.actionWindow() {
                    evidence.append(.targetResolved(ActionCompletionTarget(
                        appName: window.name, bundleID: window.bundleID,
                        pid: window.pid, windowID: window.windowID,
                        processIdentity: window.processIdentity)))
                }
                note("wait_frontmost \(front.name)")

            case .verifyContext(let terms):
                // Read frontmost, then the labels, then frontmost again. The
                // window title and the focused-element label are read from
                // whatever is in front *at that moment*, so without bracketing
                // the reads a focus change mid-step would let the plan verify
                // one app's title and then type into another's window.
                guard let before = host.frontmostApp() else {
                    note("verify_context: no frontmost app")
                    return failed(index, "couldn't read the active window",
                                  recoverable: false)
                }
                if expectedAppName != nil || expectedBundleID != nil, !focusStillHeld() {
                    note("verify_context: focus lost before the check")
                    return failed(index, "\(expectedAppName ?? "the app") lost focus",
                                  recoverable: false)
                }
                // Poll rather than read once. A UI does not settle on a
                // schedule: Slack's search is network-backed, and a window
                // title updates some tens of milliseconds after the click that
                // caused it. A single read turns "not yet" into "not true",
                // which fails a correct plan. Polling only ever lets the check
                // see the real state — it never loosens what counts as a match.
                var title = host.frontmostWindowTitle()
                var label = host.focusedElementLabel()
                var selection = host.focusedSelectionLabel()
                let settleDeadline = host.now() + Self.verifySettleSeconds
                while !AppMatcher.contextMatches(terms, in: [title, label, selection]),
                      host.now() < settleDeadline, !cancelled {
                    host.sleep(ms: 150)
                    title = host.frontmostWindowTitle()
                    label = host.focusedElementLabel()
                    selection = host.focusedSelectionLabel()
                }
                guard let after = host.frontmostApp(),
                      after.bundleID == before.bundleID, after.name == before.name else {
                    note("verify_context: focus moved while reading the screen")
                    return failed(index, "the active window changed mid-check",
                                  recoverable: false)
                }
                guard AppMatcher.contextMatches(terms, in: [title, label, selection]) else {
                    note("verify_context \(terms.joined(separator: "+")): "
                                 + "no match in '\(title ?? "")' / '\(label ?? "")'"
                                 + " / '\(selection ?? "")'")
                    // Recoverable BY DESIGN: this is the observation the loop
                    // exists for. The model gets told what the screen showed
                    // instead, and chooses differently.
                    return failed(
                        index,
                        "couldn't confirm \(terms.first ?? "the target") on screen",
                        recoverable: true)
                }
                // The window that satisfied the check — and only that one — is
                // what the following steps may type into.
                expectedAppName = after.name
                expectedBundleID = after.bundleID
                // Record WHAT satisfied the check, not just that it did. A
                // check that passes for the wrong reason is invisible
                // otherwise, and this one guards a message to a human.
                note("verify_context ok [\(terms.joined(separator: "+"))] "
                             + "title='\(title ?? "")' label='\(label ?? "")' "
                             + "selection='\(selection ?? "")'")

            case .verifyUI(let snapshotID, let elementIndex, let role,
                           let label, let target):
                guard let before = host.frontmostApp(), focusStillHeld() else {
                    note("verify_ui [\(elementIndex)] \(target): focus lost")
                    return failed(index, "\(expectedAppName ?? "the app") lost focus",
                                  recoverable: false)
                }
                guard host.verifyElement(
                    index: elementIndex, snapshotID: snapshotID,
                    label: label, role: role, target: target,
                    expecting: expectedBundleID, purpose: .target),
                      let after = host.frontmostApp(),
                      after.bundleID == before.bundleID, after.name == before.name
                else {
                    note("verify_ui [\(elementIndex)] \(target): stale or no match")
                    return failed(
                        index, "the active target changed before typing",
                        recoverable: true)
                }
                expectedAppName = after.name
                expectedBundleID = after.bundleID
                verifiedUITarget = true
                evidence.append(.uiTargetVerified(target: target))
                note("verify_ui ok [\(elementIndex)] \(role) '\(label)' target='\(target)'")

            case .verifyGoal(let snapshotID, let elementIndex, let role,
                             let label, let target):
                guard let before = host.frontmostApp(), focusStillHeld() else {
                    note("verify_goal [\(elementIndex)] \(target): focus lost")
                    return failed(index, "\(expectedAppName ?? "the app") lost focus",
                                  recoverable: false)
                }
                guard host.verifyElement(
                    index: elementIndex, snapshotID: snapshotID,
                    label: label, role: role, target: target,
                    expecting: expectedBundleID, purpose: .goal),
                      let after = host.frontmostApp(),
                      after.bundleID == before.bundleID, after.name == before.name
                else {
                    note("verify_goal [\(elementIndex)] \(target): stale or no match")
                    return failed(
                        index, "the visible completion evidence changed",
                        recoverable: true)
                }
                expectedAppName = after.name
                expectedBundleID = after.bundleID
                evidence.append(.goalVerified(target: target))
                note("verify_goal ok [\(elementIndex)] \(role) '\(label)' target='\(target)'")

            case .verifyState(let check):
                guard let receipt = host.verifyState(
                    check, expecting: expectedBundleID) else {
                    note("verify_state: positive state not proven")
                    return failed(
                        index, "the completion state could not be verified",
                        recoverable: true)
                }
                evidence.append(.stateVerified(
                    receipt, expectedValue: check.expectedValue))
                note("verify_state satisfied \(check.assertion.rawValue)")

            case .typeTextAt(let text, let operation, let target):
                if operation != .search, plan.requiresUITargetVerification,
                   !verifiedUITarget {
                    note("type_text: target verifier has not confirmed the recipient")
                    return failed(
                        index,
                        "the active recipient was not confirmed before typing",
                        recoverable: true)
                }
                guard focusStillHeld() else {
                    note("type_text: routed target lost")
                    return failed(
                        index, "the routed app target changed",
                        recoverable: false)
                }
                let receipt: ActionStateReceipt?
                if operation == .replace {
                    receipt = host.replaceText(
                        text, target: target, expecting: expectedBundleID)
                } else if operation == .search {
                    receipt = host.searchText(
                        text, target: target, expecting: expectedBundleID)
                } else {
                    receipt = host.typeText(
                        text, target: target, expecting: expectedBundleID)
                }
                guard let receipt else {
                    note("type_text: exact background write refused")
                    return failed(
                        index, "couldn't type into that exact field",
                        recoverable: false)
                }
                let kind: ActionEffectKind = operation == .paste
                    ? .pasteText : .typeText
                evidence.append(.unverifiedEffect(kind))
                if operation != .search {
                    evidence.append(.stateVerified(
                        receipt, expectedValue: nil))
                }
                let verb: String
                switch operation {
                case .replace: verb = "replace_text"
                case .search: verb = "search_text"
                case .type, .paste: verb = "type_text"
                }
                note("\(verb) \(text.count) chars",
                     observed: "\(verb) \(text.count) chars: "
                        + "\"\(Self.evidenceText(text, scalarLimit: 90))\"")

            case .typeText(let text), .pasteText(let text), .searchText(let text):
                let isSearch: Bool
                if case .searchText = step { isSearch = true } else { isSearch = false }
                if !isSearch, plan.requiresUITargetVerification,
                   !verifiedUITarget {
                    note("type_text: target verifier has not confirmed the recipient")
                    return failed(
                        index,
                        "the active recipient was not confirmed before typing",
                        recoverable: true)
                }
                // Synthesized characters go to whatever holds focus; with
                // nothing focused they are simply dropped. Observed in the
                // field: "open TextEdit and type hello" reported success while
                // TextEdit had no document, so the text went nowhere and the
                // run still claimed it had typed 17 characters.
                let focusDeadline = host.now() + Self.textFocusSettleSeconds
                while !host.hasFocusedTextTarget,
                      host.now() < focusDeadline, !cancelled {
                    host.sleep(ms: 100)
                }
                guard host.hasFocusedTextTarget else {
                    // Name the remedy, not just the symptom. "nothing focused"
                    // sent the planner hunting for a menu item called "New
                    // Document" over and over; what it needed to know is that
                    // an empty app wants a new document opened first.
                    note("type_text: nothing focused to type into — "
                         + "\(expectedAppName ?? "that app") has no text field "
                         + "on screen; open a document (key n with cmd) or "
                         + "press a field first, then type")
                    // Recoverable: the next turn can open a compose field or
                    // press the element that would focus one.
                    return failed(
                        index,
                        "\(expectedAppName ?? "that app") has no text field "
                            + "focused to type into",
                        recoverable: true)
                }
                guard focusStillHeld() else {
                    note("type_text: focus lost")
                    return failed(index, "\(expectedAppName ?? "the app") lost focus",
                                  recoverable: false)
                }
                let ok: Bool
                if case .pasteText = step {
                    ok = host.pasteText(text, expecting: expectedBundleID)
                } else {
                    ok = host.typeText(text, expecting: expectedBundleID)
                }
                guard ok else {
                    note("type_text: refused")
                    return failed(index, "couldn't type that text", recoverable: false)
                }
                evidence.append(.unverifiedEffect(
                    step == .pasteText(text) ? .pasteText : .typeText))
                // The planner gets the text, the log gets the count. A bare
                // count gave the model no way to tell its words were already
                // in, and it retyped chunks until the turn budget ran out
                // (observed live) — but message and note bodies must not
                // land in a durable log file. This is the plan's OWN text,
                // never anything read off the screen, so putting it in the
                // observation adds no untrusted content. Bounded in UNICODE
                // SCALARS so the engine's 140-code-point clip of an executed
                // line cannot cut it mid-quote.
                let verb = isSearch ? "search_text" : "type_text"
                note("\(verb) \(text.count) chars",
                     observed: "\(verb) \(text.count) chars: "
                         + "\"\(Self.evidenceText(text, scalarLimit: 90))\"")

            case .presentUI:
                note("present_ui: result-card click required")
                return failed(
                    index, "opening the target requires a result-card click",
                    recoverable: false)

            case .key(let name, let mods, let repeatCount):
                guard focusStillHeld() else {
                    note("key \(name): focus lost")
                    return failed(index, "\(expectedAppName ?? "the app") lost focus",
                                  recoverable: false)
                }
                guard let code = ActionKey.keyCode(for: name) else {
                    note("key \(name): unmappable")
                    return failed(index, "can't press \(name)", recoverable: false)
                }
                let flags = ActionModifier.flags(for: mods)
                for iteration in 0..<repeatCount {
                    if cancelled {
                        return ActionRunResult(outcome: .cancelled(step: index),
                                               trace: trace,
                                               observationTrace: observationTrace,
                                               executedSteps: index,
                                               evidence: evidence)
                    }
                    guard host.pressKey(name: name, mods: mods, keyCode: code,
                                        flags: flags,
                                        expecting: expectedBundleID) else {
                        note("key \(name): failed at \(iteration)")
                        return failed(index, "couldn't press \(name)", recoverable: false)
                    }
                    if repeatCount > 1 { host.sleep(ms: 30) }
                }
                evidence.append(.unverifiedEffect(.key))
                note("key \(mods.joined(separator: "+"))\(mods.isEmpty ? "" : "+")\(name)"
                             + (repeatCount > 1 ? " x\(repeatCount)" : ""))
                if !mods.isEmpty || ActionPlan.Limits.focusMovingKeys.contains(name) {
                    verifiedUITarget = false
                }

            case .pressElement(let label):
                // The host exposes AXPress only for structurally safe
                // navigation roles. It is not a synthesized keystroke, so
                // `canPostInput` deliberately does not apply — but a screen
                // that locked mid-batch must still stop it.
                guard !host.screenIsLocked else {
                    note("press_element \(label): screen locked")
                    return failed(index, "the screen is locked", recoverable: false)
                }
                guard focusStillHeld() else {
                    note("press_element \(label): focus lost")
                    return failed(index, "\(expectedAppName ?? "the app") lost focus",
                                  recoverable: false)
                }
                guard host.pressElement(label: label,
                                        expecting: expectedBundleID) else {
                    // Name the remedy. Observed live: an app that launched
                    // without a document has no text area, and the planner
                    // spent every remaining turn pressing a MENU item called
                    // "New Document" — which press_element cannot reach by
                    // design. Repeating the bare "not found" taught it
                    // nothing, so it repeated the step.
                    note("press_element \(label): not found — nothing on "
                         + "screen has that label, and menu items cannot be "
                         + "pressed. Use a key shortcut instead (a new "
                         + "document is key n with cmd), or press a label "
                         + "listed in screen_names")
                    // Recoverable BY DESIGN: "that label isn't on screen" is
                    // exactly the observation the next turn should react to.
                    return failed(index, "couldn't find '\(label)' on screen",
                                  recoverable: true)
                }
                evidence.append(.unverifiedEffect(.pressElement))
                note("press_element \(label)")
                verifiedUITarget = false

            case .pressUI(let snapshotID, let elementIndex, let role, let label):
                guard !host.screenIsLocked else {
                    note("press_ui [\(elementIndex)] \(label): screen locked")
                    return failed(index, "the screen is locked", recoverable: false)
                }
                guard focusStillHeld() else {
                    note("press_ui [\(elementIndex)] \(label): focus lost")
                    return failed(index, "\(expectedAppName ?? "the app") lost focus",
                                  recoverable: false)
                }
                guard host.pressElement(
                    index: elementIndex, snapshotID: snapshotID,
                    label: label, role: role, expecting: expectedBundleID)
                else {
                    if let reason = host.actionFailureReason {
                        note("press_ui [\(elementIndex)] \(label): \(reason)")
                        return failed(index, reason, recoverable: false)
                    }
                    note("press_ui [\(elementIndex)] \(label): stale or refused")
                    return failed(
                        index,
                        "the selected UI element changed; inspect the fresh screen",
                        recoverable: true)
                }
                evidence.append(.unverifiedEffect(.pressElement))
                note("press_ui [\(elementIndex)] \(role) \(label)")
                verifiedUITarget = false
                host.sleep(ms: Self.indexedPressSettleMs)

            case .pause(let ms):
                host.sleep(ms: ms)
                note("pause \(ms)ms")

            case .mediaControl(let control):
                guard !host.screenIsLocked else {
                    note("media_control \(control.state.rawValue): screen locked")
                    return failed(index, "the screen is locked", recoverable: false)
                }
                guard let target = host.actionProcess(), target.pid > 0,
                      !target.name.isEmpty, !target.bundleID.isEmpty else {
                    note("media_control \(control.state.rawValue): no exact target")
                    return failed(
                        index, "media playback has no exact app target",
                        recoverable: false)
                }
                switch host.mediaControl(control) {
                case .verified:
                    evidence.append(.targetResolved(ActionCompletionTarget(
                        appName: target.name, bundleID: target.bundleID,
                        pid: target.pid,
                        processIdentity: target.processIdentity)))
                    evidence.append(.localGoalVerified(.media(
                        state: control.state, appName: target.name)))
                    note("media_control \(control.state.rawValue): verified")
                case .unavailable:
                    note("media_control \(control.state.rawValue): unavailable")
                    return failed(
                        index, "the target app's media state is unavailable",
                        recoverable: false)
                case .misdirected:
                    note("media_control \(control.state.rawValue): misdirected")
                    return failed(
                        index, "the media command did not reach the target app",
                        recoverable: false)
                }
            }
        }
        return ActionRunResult(outcome: .completed, trace: trace,
                               observationTrace: observationTrace,
                               executedSteps: plan.steps.count, evidence: evidence)
    }

    private static func progressDescription(_ step: ActionStep) -> String {
        switch step {
        case .openApp(let app): return "Opening \(app)"
        case .openURL: return "Opening link"
        case .waitFrontmost(let app, _): return "Waiting for \(app)"
        case .verifyContext: return "Checking screen"
        case .verifyUI: return "Confirming recipient"
        case .verifyGoal: return "Confirming completion"
        case .presentUI: return "Presenting target"
        case .typeText, .pasteText: return "Typing message"
        case .searchText: return "Searching"
        case .key(let name, _, _):
            return ActionPlan.Limits.committingKeys.contains(name)
                ? "Sending" : "Pressing \(name)"
        case .pause: return "Waiting for screen"
        case .pressElement(let label): return "Opening \(label)"
        case .pressUI(_, _, _, let label): return "Opening \(label)"
        case .mediaControl(let control):
            return control.state == .play ? "Starting playback" : "Pausing playback"
        case .verifyState: return "Verifying completion"
        case .typeTextAt(_, let operation, _):
            switch operation {
            case .replace: return "Replacing text"
            case .search: return "Searching"
            case .type, .paste: return "Typing"
            }
        }
    }

    private static func mutatesUI(_ step: ActionStep) -> Bool {
        switch step {
        case .typeText, .typeTextAt, .searchText, .pasteText, .key,
             .pressElement, .pressUI, .presentUI, .mediaControl:
            return true
        default:
            return false
        }
    }

    /// True when the app the plan focused is still frontmost. When focus was
    /// established without a bundle id (a `verify_context` on an unreadable
    /// app), fall back to comparing names.
    private func focusStillHeld() -> Bool {
        guard expectedAppName != nil || expectedBundleID != nil else { return false }
        guard let front = host.frontmostApp() else { return false }
        if let expectedBundleID, !expectedBundleID.isEmpty {
            return front.bundleID.caseInsensitiveCompare(expectedBundleID)
                == .orderedSame
        }
        if let expectedAppName {
            return AppMatcher.normalize(front.name) == AppMatcher.normalize(expectedAppName)
        }
        return false
    }

    /// Evidence may become user-visible once goal-bound postconditions exist.
    /// Bound and defang it at capture time so that future code cannot
    /// accidentally render an app-authored control/bidi payload verbatim.
    private static func evidenceText(_ text: String, limit: Int) -> String {
        String(ActionPlan.sanitize(text).prefix(limit))
    }

    /// Bounds by unicode scalars rather than graphemes. The engine clips an
    /// executed line at 140 PYTHON code points; 90 graphemes of decomposed
    /// text can be far more than that, so the guarantee has to be measured
    /// in the same unit the clipper uses (review finding).
    private static func evidenceText(_ text: String, scalarLimit: Int) -> String {
        let sanitized = ActionPlan.sanitize(text)
        let scalars = sanitized.unicodeScalars
        guard scalars.count > scalarLimit else { return sanitized }
        return String(String.UnicodeScalarView(scalars.prefix(scalarLimit)))
    }

    private func waitForFrontmost(
        _ app: String, timeoutMs: Int
    ) -> (name: String, bundleID: String)? {
        let deadline = host.now() + Double(timeoutMs) / 1000
        repeat {
            if cancelled { return nil }
            if host.actionFailureReason != nil { return nil }
            if let front = host.frontmostApp(),
               AppMatcher.bestMatch(for: app, in: [front.name]) != nil {
                return front
            }
            host.sleep(ms: 60)
        } while host.now() < deadline
        // One final read: the app may have come forward during the last sleep.
        if host.actionFailureReason == nil,
           let front = host.frontmostApp(),
           AppMatcher.bestMatch(for: app, in: [front.name]) != nil {
            return front
        }
        return nil
    }
}
