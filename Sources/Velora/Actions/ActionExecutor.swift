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
    func typeText(_ text: String, expecting bundleID: String?) -> Bool
    func pasteText(_ text: String, expecting bundleID: String?) -> Bool
    /// `expecting` is the bundle id the plan established focus on. The Return
    /// that commits a send is the one keystroke that must not be posted a
    /// moment after focus moved.
    func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags, expecting bundleID: String?) -> Bool
    /// False when a keystroke must not be synthesized right now (permission
    /// missing, or a password field has secure input up).
    var canPostInput: Bool { get }
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
    case failed(step: Int, reason: String)
    case cancelled(step: Int)

    var isSuccess: Bool { self == .completed }
}

struct ActionRunResult: Equatable {
    let outcome: ActionOutcome
    /// One line per attempted step, for the log and for tests.
    let trace: [String]
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
        guard plan.isExecutable else {
            return ActionRunResult(outcome: .failed(step: 0, reason: "nothing to do"),
                                   trace: trace)
        }
        // Checked up front rather than per step: on a locked Mac every plan
        // fails, and it should say why instead of blaming the target app.
        guard !host.screenIsLocked else {
            trace.append("blocked: screen locked")
            return ActionRunResult(
                outcome: .failed(step: 0, reason: "the screen is locked"), trace: trace)
        }

        for (index, step) in plan.steps.enumerated() {
            if cancelled {
                return ActionRunResult(outcome: .cancelled(step: index), trace: trace)
            }
            // Permission and secure-input state can change mid-plan (the user
            // clicks a password field between steps).
            if step.isInput, !host.canPostInput {
                trace.append("blocked: input not permitted")
                return ActionRunResult(
                    outcome: .failed(step: index,
                                     reason: "keyboard input is not permitted right now"),
                    trace: trace)
            }

            switch step {
            case .openApp(let name):
                guard let resolved = host.openApp(named: name) else {
                    trace.append("open_app \(name): not found")
                    return ActionRunResult(
                        outcome: .failed(step: index, reason: "couldn't find an app called \(name)"),
                        trace: trace)
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
                    return ActionRunResult(
                        outcome: .failed(step: index, reason: "couldn't open that link"),
                        trace: trace)
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
                    return ActionRunResult(
                        outcome: .failed(step: index, reason: "\(app) didn't come to the front"),
                        trace: trace)
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
                    return ActionRunResult(
                        outcome: .failed(step: index, reason: "couldn't read the active window"),
                        trace: trace)
                }
                if expectedAppName != nil || expectedBundleID != nil, !focusStillHeld() {
                    trace.append("verify_context: focus lost before the check")
                    return ActionRunResult(
                        outcome: .failed(step: index,
                                         reason: "\(expectedAppName ?? "the app") lost focus"),
                        trace: trace)
                }
                let title = host.frontmostWindowTitle()
                let label = host.focusedElementLabel()
                let selection = host.focusedSelectionLabel()
                guard let after = host.frontmostApp(),
                      after.bundleID == before.bundleID, after.name == before.name else {
                    trace.append("verify_context: focus moved while reading the screen")
                    return ActionRunResult(
                        outcome: .failed(step: index,
                                         reason: "the active window changed mid-check"),
                        trace: trace)
                }
                guard AppMatcher.contextMatches(terms, in: [title, label, selection]) else {
                    trace.append("verify_context \(terms.joined(separator: "+")): "
                                 + "no match in '\(title ?? "")' / '\(label ?? "")'"
                                 + " / '\(selection ?? "")'")
                    return ActionRunResult(
                        outcome: .failed(
                            step: index,
                            reason: "couldn't confirm \(terms.first ?? "the target") on screen"),
                        trace: trace)
                }
                // The window that satisfied the check — and only that one — is
                // what the following steps may type into.
                expectedAppName = after.name
                expectedBundleID = after.bundleID
                trace.append("verify_context ok")

            case .typeText(let text), .pasteText(let text):
                guard focusStillHeld() else {
                    trace.append("type_text: focus lost")
                    return ActionRunResult(
                        outcome: .failed(step: index,
                                         reason: "\(expectedAppName ?? "the app") lost focus"),
                        trace: trace)
                }
                let ok: Bool
                if case .pasteText = step {
                    ok = host.pasteText(text, expecting: expectedBundleID)
                } else {
                    ok = host.typeText(text, expecting: expectedBundleID)
                }
                guard ok else {
                    trace.append("type_text: refused")
                    return ActionRunResult(
                        outcome: .failed(step: index, reason: "couldn't type that text"),
                        trace: trace)
                }
                trace.append("type_text \(text.count) chars")

            case .key(let name, let mods, let repeatCount):
                guard focusStillHeld() else {
                    trace.append("key \(name): focus lost")
                    return ActionRunResult(
                        outcome: .failed(step: index,
                                         reason: "\(expectedAppName ?? "the app") lost focus"),
                        trace: trace)
                }
                guard let code = ActionKey.keyCode(for: name) else {
                    trace.append("key \(name): unmappable")
                    return ActionRunResult(
                        outcome: .failed(step: index, reason: "can't press \(name)"),
                        trace: trace)
                }
                let flags = ActionModifier.flags(for: mods)
                for iteration in 0..<repeatCount {
                    if cancelled {
                        return ActionRunResult(outcome: .cancelled(step: index), trace: trace)
                    }
                    guard host.pressKey(code, flags: flags,
                                        expecting: expectedBundleID) else {
                        trace.append("key \(name): failed at \(iteration)")
                        return ActionRunResult(
                            outcome: .failed(step: index, reason: "couldn't press \(name)"),
                            trace: trace)
                    }
                    if repeatCount > 1 { host.sleep(ms: 30) }
                }
                trace.append("key \(mods.joined(separator: "+"))\(mods.isEmpty ? "" : "+")\(name)"
                             + (repeatCount > 1 ? " x\(repeatCount)" : ""))

            case .pause(let ms):
                host.sleep(ms: ms)
                trace.append("pause \(ms)ms")
            }
        }
        return ActionRunResult(outcome: .completed, trace: trace)
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
