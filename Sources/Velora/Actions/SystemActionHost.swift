import AppKit
import ApplicationServices
import Foundation

enum ActionTypingProgress {
    /// Exact Action-owned text that must precede the next typing chunk. Invalid
    /// progress—including a UTF-16 offset inside a surrogate pair—fails closed.
    static func expectedDraft(
        priorDraft: String,
        insertion: String,
        postedUTF16Units: Int
    ) -> String? {
        let insertionUnits = Array(insertion.utf16)
        guard postedUTF16Units >= 0,
              postedUTF16Units <= insertionUnits.count else { return nil }
        let prefixUnits = Array(insertionUnits.prefix(postedUTF16Units))
        let prefix = String(decoding: prefixUnits, as: UTF16.self)
        guard Array(prefix.utf16) == prefixUnits else { return nil }
        return priorDraft + prefix
    }
}

/// The real machine behind `ActionExecutor`.
///
/// Two macOS behaviours shape this file:
///
/// * **Activation is advisory.** Since macOS 14 `activate()` is a request the
///   current app can decline, so every launch is followed by a polled
///   `wait_frontmost` rather than an assumption. `yieldActivation` is what makes
///   the request likely to be granted from a menubar app.
/// * **Electron builds their accessibility tree lazily.** Slack, WhatsApp and
///   friends expose nothing until an assistive client asks, so
///   `enableAccessibility` sets `AXManualAccessibility`. That call returns
///   `kAXErrorAttributeUnsupported` on builds where it nonetheless works
///   (electron#37465), so the result is ignored and the tree is re-read to
///   check — never branch on its error code.
final class SystemActionHost: ActionHost {
    private let inserter: TextInserter
    private var accessibilityEnabledPIDs = Set<pid_t>()
    /// Exact AX field and exact text written by this Action invocation. The
    /// field survives planner turns, but is reset before the next user action.
    private var actionTextTarget: ScreenKeystrokeStreamTarget?
    private var actionDraft = ""

    init(inserter: TextInserter) {
        self.inserter = inserter
    }

    func beginActionInputSession() {
        clearActionTextState()
    }

    private func clearActionTextState() {
        actionTextTarget = nil
        actionDraft = ""
    }

    private func expectedBundle(_ expected: String?, matches actual: String) -> Bool {
        guard let expected, !expected.isEmpty else { return true }
        return expected == actual
    }

    private func actionDraftIsOwned(
        _ draft: String,
        target: ScreenKeystrokeStreamTarget,
        waitingUpTo timeout: TimeInterval
    ) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        repeat {
            if ScreenContext.keystrokeStreamOwnsDraft(draft, target: target) {
                return true
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.01)
        } while true
    }

    /// Runs `work` on the main thread and returns its result.
    ///
    /// The executor runs on a background queue so its waits (activation
    /// polling, per-chunk typing) never block the UI — but AppKit activation is
    /// main-thread-only, so every AppKit touch hops back. Safe from a
    /// background queue because the main queue is never waiting on the
    /// executor: `ActionCoordinator` dispatches the run and returns.
    private func onMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }

    // MARK: - Apps

    func openApp(named name: String) -> String? {
        onMain {
            // Prefer an already-running app: it is the one with the user's windows.
            let running = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && $0.localizedName != nil
            }
            if let index = AppMatcher.bestMatch(
                for: name, in: running.map { $0.localizedName ?? "" }) {
                let app = running[index]
                self.activate(app)
                self.enableAccessibility(for: app)
                return app.localizedName
            }
            guard let url = InstalledApps.shared.url(forName: name) else { return nil }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return url.deletingPathExtension().lastPathComponent
        }
    }

    private func activate(_ app: NSRunningApplication) {
        // Cooperative activation: ask the system to hand our activation right
        // to the target, then request the switch. Without the yield a menubar
        // app's activate() is frequently ignored on macOS 14+.
        NSApp.yieldActivation(to: app)
        app.activate(options: [.activateAllWindows])
    }

    func openURL(_ url: URL) -> Bool {
        onMain { NSWorkspace.shared.open(url) }
    }

    func frontmostApp() -> (name: String, bundleID: String)? {
        onMain {
            guard let app = NSWorkspace.shared.frontmostApplication,
                  let name = app.localizedName else { return nil }
            // Every time we notice an app, make sure its tree is being built.
            // Chromium/Electron expose nothing until asked, and enabling this
            // only when we launched the app meant a plan run against an
            // already-frontmost Slack never enabled it at all.
            self.enableAccessibility(for: app)
            return (name, app.bundleIdentifier ?? "")  // "" == unknown; never matched
        }
    }

    // MARK: - Accessibility reads

    /// Ask an Electron/Chromium app to build its accessibility tree. Idempotent
    /// per launch; the PID set is the cache.
    func enableAccessibility(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid > 0, !accessibilityEnabledPIDs.contains(pid),
              Permissions.accessibilityGranted else { return }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.5)
        // Deliberately unchecked: the attribute reports "unsupported" on builds
        // where setting it works, so the only meaningful verification is
        // reading the tree afterwards (which the plan's own steps do).
        _ = AXUIElementSetAttributeValue(
            element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        accessibilityEnabledPIDs.insert(pid)
    }

    func frontmostWindowTitle() -> String? {
        guard Permissions.accessibilityGranted,
              let app = onMain({ NSWorkspace.shared.frontmostApplication }),
              app.processIdentifier > 0 else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef, CFGetTypeID(windowRef) == AXUIElementGetTypeID()
        else { return nil }
        let window = windowRef as! AXUIElement  // type-checked above
        // Messaging timeouts do not propagate to returned elements.
        AXUIElementSetMessagingTimeout(window, 0.5)
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                window, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What the focused field says about itself. In a chat app this is where
    /// the recipient's name lives ("Message Himesh"), which is exactly what a
    /// `verify_context` step needs to confirm before typing.
    func focusedElementLabel() -> String? {
        guard Permissions.accessibilityGranted,
              let app = onMain({ NSWorkspace.shared.frontmostApplication }),
              let focused = ScreenContext.focusedElement(of: app) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.5)
        var parts: [String] = []
        // App-authored attributes ONLY. `kAXValue` is deliberately excluded: it
        // is the field's *contents*, which in this flow is the text the plan
        // itself just typed. Verifying against it would be circular — the plan
        // types "Priya" into a search box and then confirms it can see "Priya",
        // proving nothing about which conversation is open.
        for attribute in [kAXDescriptionAttribute, kAXPlaceholderValueAttribute,
                          kAXTitleAttribute] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(focused, attribute as CFString, &ref) == .success,
               let text = ref as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(String(text.prefix(200)))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The label of the ONE element the app says is active — a quick
    /// switcher's highlighted row.
    ///
    /// This deliberately reads a single element and never flattens a subtree.
    /// The previous version walked the results list and joined everything it
    /// found, which against real Slack produced "Suggestions … Here are some
    /// recent conversations: …" — a blob containing every recent contact. Any
    /// name in the list then satisfied a check meant to confirm one specific
    /// recipient, and a plan typed into the wrong window while reporting that
    /// it had verified the right one. A verification that matches too much is
    /// worse than no verification, because it manufactures confidence.
    ///
    /// Chromium maps `role=listbox`/`option` to AXList/AXStaticText, so
    /// `AXSelectedRows` never resolves on web content; what it does do is fold
    /// `aria-activedescendant` into the app's `AXFocusedUIElement`.
    func focusedSelectionLabel() -> String? {
        guard Permissions.accessibilityGranted,
              let app = onMain({ NSWorkspace.shared.frontmostApplication }),
              app.processIdentifier > 0 else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.5)
        guard let active = ScreenContext.axElement(
            appElement, kAXFocusedUIElementAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(active, 0.3)
        // The element's own words only. Its value is excluded for the same
        // reason as in `focusedElementLabel`: it is the text we just typed.
        var parts: [String] = []
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let text = ScreenContext.axString(active, attribute),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(String(text.prefix(160)))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// AX role of the focused element, for observations ("AXTextField" tells
    /// the model a search box is focused; "AXButton" tells it typing is lost).
    func focusedElementRole() -> String? {
        guard Permissions.accessibilityGranted,
              let app = onMain({ NSWorkspace.shared.frontmostApplication })
        else { return nil }
        return ScreenContext.focusedElementRole(of: app)
    }

    /// The labels visible in the frontmost window right now — what the model
    /// looks at between turns. Bounded walk; runs on the executor's queue.
    func visibleNames() -> [String] {
        guard let app = onMain({ NSWorkspace.shared.frontmostApplication })
        else { return [] }
        return ScreenContext.visibleNames(of: app)
    }

    /// Press the navigation element whose visible label matches. The
    /// frontmost app must still be the one the plan verified; ScreenContext
    /// also refuses every non-navigation AX role before AXPress. Communication
    /// apps expose rows/cells; browsers additionally expose links (a search
    /// result) — every other app refuses the verb outright.
    func pressElement(label: String, expecting bundleID: String?) -> Bool {
        guard Permissions.accessibilityGranted else { return false }
        guard let app = onMain({ NSWorkspace.shared.frontmostApplication })
        else { return false }
        guard let roles = ActionRuntimePolicy.pressRoles(forBundleID: app.bundleIdentifier)
        else { return false }
        if let bundleID, !bundleID.isEmpty, app.bundleIdentifier != bundleID {
            return false
        }
        let pressed = ScreenContext.pressElement(labelled: label, in: app, roles: roles)
        if pressed { clearActionTextState() }
        return pressed
    }

    /// URL of the frontmost page when a browser is frontmost, else nil. Read
    /// via AX only — no AppleScript, no new permission surface.
    func frontmostPageURL() -> String? {
        guard Permissions.accessibilityGranted,
              let app = onMain({ NSWorkspace.shared.frontmostApplication }),
              ActionRuntimePolicy.isBrowserBundle(app.bundleIdentifier)
        else { return nil }
        return ScreenContext.pageURL(of: app, deep: true)?.absoluteString
    }

    // MARK: - Input

    /// Captures one proven editable AX field with a readable empty caret. A
    /// generic focused element is insufficient: a synthesized "e" on Gmail's
    /// document surface is an ambient keyboard shortcut, not text insertion.
    var hasFocusedTextTarget: Bool {
        guard Permissions.accessibilityGranted else {
            clearActionTextState()
            return false
        }
        if let target = actionTextTarget {
            guard ScreenContext.keystrokeStreamOwnsDraft(actionDraft, target: target) else {
                clearActionTextState()
                return false
            }
            return true
        }
        guard let app = onMain({ NSWorkspace.shared.frontmostApplication }),
              app.processIdentifier > 0,
              let target = ScreenContext.keystrokeStreamTarget(of: app),
              ScreenContext.keystrokeStreamOwnsDraft("", target: target)
        else {
            clearActionTextState()
            return false
        }
        actionTextTarget = target
        actionDraft = ""
        return true
    }

    var canPostInput: Bool {
        Permissions.accessibilityGranted
            && CGPreflightPostEventAccess()
            && !SecureInput.isActive
            && !screenIsLocked
    }

    /// Verified in the field: with the Mac locked, `loginwindow` is frontmost,
    /// no app can be activated, and a plan that ignored this would try to type
    /// its message at the login window.
    var screenIsLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    func typeText(_ text: String, expecting bundleID: String?) -> Bool {
        guard canPostInput, hasFocusedTextTarget,
              let target = actionTextTarget,
              expectedBundle(bundleID, matches: target.bundleID),
              ScreenContext.keystrokeStreamOwnsDraft(actionDraft, target: target)
        else {
            clearActionTextState()
            return false
        }
        let priorDraft = actionDraft
        let resultingDraft = priorDraft + text
        // Synchronous by design: the executor's next step (often Return) must
        // not race the characters into the field.
        let finished = DispatchSemaphore(value: 0)
        var succeeded = false
        inserter.insertViaTyping(
            text,
            targetBundleID: target.bundleID,
            targetElement: target.element,
            initialDeliveryCheck: {
                ScreenContext.keystrokeStreamOwnsDraft(priorDraft, target: target)
            },
            continuationDeliveryCheck: { [weak self] postedUTF16Units in
                guard let self,
                      let expectedDraft = ActionTypingProgress.expectedDraft(
                        priorDraft: priorDraft,
                        insertion: text,
                        postedUTF16Units: postedUTF16Units)
                else { return false }
                // The first check observes the unchanged starting caret. For
                // later chunks, briefly allow the target app's AX tree to
                // catch up with the event that was just posted.
                return self.actionDraftIsOwned(
                    expectedDraft,
                    target: target,
                    waitingUpTo: postedUTF16Units == 0 ? 0 : 0.2)
            },
            completion: { ok in
                succeeded = ok
                finished.signal()
            })
        let deadline = DispatchTime.now() + .milliseconds(max(3_000, text.count * 12))
        guard finished.wait(timeout: deadline) == .success, succeeded else {
            clearActionTextState()
            return false
        }

        // AX delivery is asynchronous relative to the posted CGEvent. Give the
        // app a short bounded window to expose the resulting caret and text,
        // then retain only a draft whose exact element and contents are proven.
        if actionDraftIsOwned(resultingDraft, target: target, waitingUpTo: 0.5) {
            actionDraft = resultingDraft
            return true
        }
        clearActionTextState()
        return false
    }

    func pasteText(_ text: String, expecting bundleID: String?) -> Bool {
        // Typing is the safer primitive for action plans: it never touches the
        // user's clipboard, and plan text is short by construction.
        typeText(text, expecting: bundleID)
    }

    func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags,
                  expecting bundleID: String?) -> Bool {
        let committing = keyCode == ActionKey.keyCode(for: "return")
            || keyCode == ActionKey.keyCode(for: "enter")
        if committing {
            guard let target = actionTextTarget,
                  !actionDraft.isEmpty,
                  expectedBundle(bundleID, matches: target.bundleID),
                  ScreenContext.keystrokeStreamOwnsDraft(actionDraft, target: target)
            else {
                clearActionTextState()
                return false
            }
        }
        guard canPostInput else {
            if committing { clearActionTextState() }
            return false
        }
        if let bundleID, !bundleID.isEmpty,
           onMain({ NSWorkspace.shared.frontmostApplication?.bundleIdentifier }) != bundleID {
            if committing { clearActionTextState() }
            return false
        }
        let pressed = inserter.pressKey(keyCode, flags: flags)
        if committing { clearActionTextState() }
        return pressed
    }

    func sleep(ms: Int) {
        guard ms > 0 else { return }
        Thread.sleep(forTimeInterval: Double(ms) / 1000)
    }

    func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
