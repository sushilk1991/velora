import AppKit
import ApplicationServices
import Foundation

/// Everything the executor needs from the machine. Split out from the executor
/// so the step logic — which is where a bug sends a message to the wrong person
/// — can be exercised headlessly against a scripted host.
protocol ActionHost: AnyObject {
    /// Launch or switch to an app; returns the name it actually resolved to.
    func openApp(named name: String) -> String?
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
    /// Press the on-screen control whose label matches. Label-addressed AX
    /// action — never a coordinate, never a synthesized click.
    func pressElement(label: String, expecting bundleID: String?) -> Bool
    func typeText(_ text: String, expecting bundleID: String?) -> Bool
    func pasteText(_ text: String, expecting bundleID: String?) -> Bool
    /// `expecting` is the bundle id the plan established focus on. The Return
    /// that commits a send is the one keystroke that must not be posted a
    /// moment after focus moved.
    func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags, expecting bundleID: String?) -> Bool
    /// False when a keystroke must not be synthesized right now (permission
    /// missing, or a password field has secure input up).
    var canPostInput: Bool { get }
    /// True when something on screen can actually receive typed characters.
    /// A frontmost app with no focused element (TextEdit with no open document,
    /// an app showing only a toolbar) swallows synthesized text silently.
    var hasFocusedTextTarget: Bool { get }
    /// True when the login window owns the screen. Nothing can be driven then,
    /// and the generic "app didn't come to the front" failure would send the
    /// user hunting for a bug that is really just a locked Mac.
    var screenIsLocked: Bool { get }
    func sleep(ms: Int)
    /// Monotonic seconds, for wait timeouts.
    func now() -> TimeInterval
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

struct ActionRunResult: Equatable {
    let outcome: ActionOutcome
    /// One line per attempted step, for the log and for tests.
    let trace: [String]
    /// How many steps fully completed. The loop recomputes its carried safety
    /// state from THIS, not from the batch as written — a verify_context that
    /// failed at runtime must not count as having verified anything.
    let executedSteps: Int
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

    private let host: ActionHost
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

    init(host: ActionHost) {
        self.host = host
    }

    func cancel() {
        cancelLock.lock()
        cancelledStorage = true
        cancelLock.unlock()
    }

    func run(_ plan: ActionPlan) -> ActionRunResult {
        var trace: [String] = []

        /// Failure at `index`: exactly the steps before it completed.
        func failed(_ index: Int, _ reason: String,
                    recoverable: Bool) -> ActionRunResult {
            ActionRunResult(
                outcome: .failed(step: index, reason: reason, recoverable: recoverable),
                trace: trace, executedSteps: index)
        }

        guard plan.isExecutable else {
            return failed(0, "nothing to do", recoverable: false)
        }
        // Checked up front rather than per step: on a locked Mac every plan
        // fails, and it should say why instead of blaming the target app.
        guard !host.screenIsLocked else {
            trace.append("blocked: screen locked")
            return failed(0, "the screen is locked", recoverable: false)
        }

        for (index, step) in plan.steps.enumerated() {
            if cancelled {
                return ActionRunResult(outcome: .cancelled(step: index), trace: trace,
                                       executedSteps: index)
            }
            // Permission and secure-input state can change mid-plan (the user
            // clicks a password field between steps).
            if step.isInput, !host.canPostInput {
                trace.append("blocked: input not permitted")
                return failed(index, "keyboard input is not permitted right now",
                              recoverable: false)
            }

            switch step {
            case .openApp(let name):
                guard let resolved = host.openApp(named: name) else {
                    trace.append("open_app \(name): not found")
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
                trace.append("open_app \(resolved)")

            case .openURL(let url):
                guard host.openURL(url) else {
                    trace.append("open_url \(url.scheme ?? "?"): failed")
                    return failed(index, "couldn't open that link", recoverable: true)
                }
                // A URL hands off to whichever app owns the scheme; the plan
                // must re-establish focus before it may type.
                expectedAppName = nil
                expectedBundleID = nil
                trace.append("open_url \(url.scheme ?? "?")")

            case .waitFrontmost(let app, let timeoutMs):
                guard let front = waitForFrontmost(app, timeoutMs: timeoutMs) else {
                    let actual = host.frontmostApp()?.name ?? "nothing"
                    trace.append("wait_frontmost \(app): timed out (front: \(actual))")
                    return failed(index, "\(app) didn't come to the front",
                                  recoverable: true)
                }
                expectedAppName = front.name
                expectedBundleID = front.bundleID
                trace.append("wait_frontmost \(front.name)")

            case .verifyContext(let terms):
                // Read frontmost, then the labels, then frontmost again. The
                // window title and the focused-element label are read from
                // whatever is in front *at that moment*, so without bracketing
                // the reads a focus change mid-step would let the plan verify
                // one app's title and then type into another's window.
                guard let before = host.frontmostApp() else {
                    trace.append("verify_context: no frontmost app")
                    return failed(index, "couldn't read the active window",
                                  recoverable: false)
                }
                if expectedAppName != nil || expectedBundleID != nil, !focusStillHeld() {
                    trace.append("verify_context: focus lost before the check")
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
                    trace.append("verify_context: focus moved while reading the screen")
                    return failed(index, "the active window changed mid-check",
                                  recoverable: false)
                }
                guard AppMatcher.contextMatches(terms, in: [title, label, selection]) else {
                    trace.append("verify_context \(terms.joined(separator: "+")): "
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
                trace.append("verify_context ok [\(terms.joined(separator: "+"))] "
                             + "title='\(title ?? "")' label='\(label ?? "")' "
                             + "selection='\(selection ?? "")'")

            case .typeText(let text), .pasteText(let text):
                // Synthesized characters go to whatever holds focus; with
                // nothing focused they are simply dropped. Observed in the
                // field: "open TextEdit and type hello" reported success while
                // TextEdit had no document, so the text went nowhere and the
                // run still claimed it had typed 17 characters.
                guard host.hasFocusedTextTarget else {
                    trace.append("type_text: nothing focused to type into")
                    // Recoverable: the next turn can open a compose field or
                    // press the element that would focus one.
                    return failed(
                        index,
                        "\(expectedAppName ?? "that app") has no text field "
                            + "focused to type into",
                        recoverable: true)
                }
                guard focusStillHeld() else {
                    trace.append("type_text: focus lost")
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
                    trace.append("type_text: refused")
                    return failed(index, "couldn't type that text", recoverable: false)
                }
                trace.append("type_text \(text.count) chars")

            case .key(let name, let mods, let repeatCount):
                guard focusStillHeld() else {
                    trace.append("key \(name): focus lost")
                    return failed(index, "\(expectedAppName ?? "the app") lost focus",
                                  recoverable: false)
                }
                guard let code = ActionKey.keyCode(for: name) else {
                    trace.append("key \(name): unmappable")
                    return failed(index, "can't press \(name)", recoverable: false)
                }
                let flags = ActionModifier.flags(for: mods)
                for iteration in 0..<repeatCount {
                    if cancelled {
                        return ActionRunResult(outcome: .cancelled(step: index),
                                               trace: trace, executedSteps: index)
                    }
                    guard host.pressKey(code, flags: flags,
                                        expecting: expectedBundleID) else {
                        trace.append("key \(name): failed at \(iteration)")
                        return failed(index, "couldn't press \(name)", recoverable: false)
                    }
                    if repeatCount > 1 { host.sleep(ms: 30) }
                }
                trace.append("key \(mods.joined(separator: "+"))\(mods.isEmpty ? "" : "+")\(name)"
                             + (repeatCount > 1 ? " x\(repeatCount)" : ""))

            case .pressElement(let label):
                // AXPress is not a synthesized keystroke, so `canPostInput`
                // (secure input) deliberately does not apply — but a screen
                // that locked mid-batch must still stop it.
                guard !host.screenIsLocked else {
                    trace.append("press_element \(label): screen locked")
                    return failed(index, "the screen is locked", recoverable: false)
                }
                guard focusStillHeld() else {
                    trace.append("press_element \(label): focus lost")
                    return failed(index, "\(expectedAppName ?? "the app") lost focus",
                                  recoverable: false)
                }
                guard host.pressElement(label: label,
                                        expecting: expectedBundleID) else {
                    trace.append("press_element \(label): not found")
                    // Recoverable BY DESIGN: "that label isn't on screen" is
                    // exactly the observation the next turn should react to.
                    return failed(index, "couldn't find '\(label)' on screen",
                                  recoverable: true)
                }
                trace.append("press_element \(label)")

            case .pause(let ms):
                host.sleep(ms: ms)
                trace.append("pause \(ms)ms")
            }
        }
        return ActionRunResult(outcome: .completed, trace: trace,
                               executedSteps: plan.steps.count)
    }

    /// True when the app the plan focused is still frontmost. When focus was
    /// established without a bundle id (a `verify_context` on an unreadable
    /// app), fall back to comparing names.
    private func focusStillHeld() -> Bool {
        guard expectedAppName != nil || expectedBundleID != nil else { return false }
        guard let front = host.frontmostApp() else { return false }
        if let expectedBundleID, !expectedBundleID.isEmpty {
            return front.bundleID == expectedBundleID
        }
        if let expectedAppName {
            return AppMatcher.normalize(front.name) == AppMatcher.normalize(expectedAppName)
        }
        return false
    }

    private func waitForFrontmost(
        _ app: String, timeoutMs: Int
    ) -> (name: String, bundleID: String)? {
        let deadline = host.now() + Double(timeoutMs) / 1000
        repeat {
            if cancelled { return nil }
            if let front = host.frontmostApp(),
               AppMatcher.bestMatch(for: app, in: [front.name]) != nil {
                return front
            }
            host.sleep(ms: 60)
        } while host.now() < deadline
        // One final read: the app may have come forward during the last sleep.
        if let front = host.frontmostApp(),
           AppMatcher.bestMatch(for: app, in: [front.name]) != nil {
            return front
        }
        return nil
    }
}
