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

/// One action's typing capability. Once exact target proof is requested,
/// losing that element cannot reopen generic focused-field capture.
struct ActionTextTargetState {
    private(set) var target: ScreenKeystrokeStreamTarget?
    private(set) var draft = ""
    private var verificationRequired = false

    var mayCaptureGeneric: Bool { !verificationRequired }

    mutating func reset() {
        target = nil
        draft = ""
        verificationRequired = false
    }

    mutating func requireVerification() {
        verificationRequired = true
        clearTarget()
    }

    mutating func pin(_ target: ScreenKeystrokeStreamTarget) {
        verificationRequired = true
        self.target = target
        draft = ""
    }

    mutating func captureGeneric(_ target: ScreenKeystrokeStreamTarget) {
        guard mayCaptureGeneric else { return }
        self.target = target
        draft = ""
    }

    mutating func updateDraft(_ draft: String) {
        self.draft = draft
    }

    mutating func clearTarget() {
        target = nil
        draft = ""
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
    private var targetState = ActionTextTargetState()
    private var actionUISnapshot: ScreenActionUISnapshot?

    init(inserter: TextInserter) {
        self.inserter = inserter
    }

    func beginActionInputSession() {
        targetState.reset()
        actionUISnapshot = nil
    }

    func endActionInputSession() {
        targetState.reset()
        actionUISnapshot = nil
    }

    private func clearActionTextState() {
        targetState.clearTarget()
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
        clearActionTextState()
        return onMain {
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

    func openApp(named name: String, bundleID: String, pid: Int) -> String? {
        clearActionTextState()
        return onMain {
            guard pid > 0,
                  let app = NSRunningApplication(
                    processIdentifier: pid_t(pid)),
                  app.activationPolicy == .regular,
                  app.bundleIdentifier?.caseInsensitiveCompare(bundleID)
                    == .orderedSame else { return nil }
            self.activate(app)
            self.enableAccessibility(for: app)
            return app.localizedName ?? name
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
        clearActionTextState()
        return onMain { NSWorkspace.shared.open(url) }
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

    func foregroundWindow() -> ActionWindowIdentity? {
        onMain {
            guard let app = NSWorkspace.shared.frontmostApplication,
                  let name = app.localizedName,
                  let bundleID = app.bundleIdentifier,
                  let rows = CGWindowListCopyWindowInfo(
                    [.optionOnScreenOnly, .excludeDesktopElements],
                    CGWindowID(kCGNullWindowID)) as? [[String: Any]],
                  let row = rows.first(where: {
                      ($0[kCGWindowOwnerPID as String] as? Int)
                          == Int(app.processIdentifier)
                          && ($0[kCGWindowLayer as String] as? Int) == 0
                  }),
                  let windowID = row[kCGWindowNumber as String] as? Int
            else { return nil }
            return ActionWindowIdentity(
                name: name, bundleID: bundleID,
                pid: Int(app.processIdentifier), windowID: windowID)
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
        if BrowserPage.usesAppleScript(app.bundleIdentifier) {
            // Chromium exposes no AX window; the tab title rides the same
            // Apple Event as the page URL (executor queue — waiting is fine).
            return BrowserPage.info(app)?.title
        }
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

    /// What the focused field says about itself. A target-bound composer may
    /// expose the recipient in an authored label such as "Message Himesh".
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

    func uiSnapshot() -> ActionUISnapshot? {
        guard let app = onMain({ NSWorkspace.shared.frontmostApplication })
        else {
            actionUISnapshot = nil
            return nil
        }
        let snapshot = ScreenContext.actionUISnapshot(of: app)
        actionUISnapshot = snapshot
        return snapshot?.observation
    }

    /// These come off the frontmost window, which is by definition what the
    /// user is looking at.
    var screenNamesAreUserVisible: Bool { true }

    /// Legacy label-addressed fallback. The frontmost app must still be the
    /// one the plan verified; the structured indexed path is preferred.
    func pressElement(label: String, expecting bundleID: String?) -> Bool {
        guard Permissions.accessibilityGranted else { return false }
        guard let app = onMain({ NSWorkspace.shared.frontmostApplication })
        else { return false }
        if let bundleID, !bundleID.isEmpty, app.bundleIdentifier != bundleID {
            return false
        }
        let pressed = ScreenContext.pressElement(labelled: label, in: app)
        if pressed { clearActionTextState() }
        return pressed
    }

    func pressElement(index: Int, snapshotID: String, label: String,
                      role: String, expecting bundleID: String?) -> Bool {
        guard Permissions.accessibilityGranted,
              let snapshot = actionUISnapshot,
              snapshot.observation.source == .native,
              snapshot.observation.id == snapshotID,
              let record = snapshot.observation.elements.first(where: {
                  $0.index == index
              }),
              record.role == role,
              !record.actions.contains(ActionUICapability.cuaClick),
              AppMatcher.normalize(record.label ?? "")
                == AppMatcher.normalize(label),
              let app = onMain({ NSWorkspace.shared.frontmostApplication }),
              app.bundleIdentifier == snapshot.observation.bundleID,
              expectedBundle(bundleID, matches: snapshot.observation.bundleID)
        else { return false }
        let pressed = ScreenContext.pressActionElement(
            index: index, in: snapshot)
        // Any press can replace the tree or move focus. Never let a later
        // indexed step reuse capabilities from the old surface.
        actionUISnapshot = nil
        if pressed { clearActionTextState() }
        return pressed
    }

    func verifyElement(index: Int, snapshotID: String, label: String,
                       role: String, target: String,
                       expecting bundleID: String?,
                       purpose: ActionVerificationPurpose) -> Bool {
        if purpose == .target { targetState.requireVerification() }
        guard Permissions.accessibilityGranted,
              let snapshot = actionUISnapshot,
              snapshot.observation.source == .native,
              snapshot.observation.id == snapshotID,
              let app = onMain({ NSWorkspace.shared.frontmostApplication }),
              app.bundleIdentifier == snapshot.observation.bundleID,
              expectedBundle(bundleID, matches: snapshot.observation.bundleID)
        else { return false }
        guard ScreenContext.verifyActionElement(
            index: index, label: label, role: role, target: target,
            in: snapshot, purpose: purpose) else { return false }
        guard purpose == .target else { return true }
        guard let pinned = Self.verifiedTextTarget(
            purpose: purpose, index: index, snapshot: snapshot,
            capture: { bundleID, element in
                ScreenContext.keystrokeStreamTarget(
                    bundleID: bundleID, element: element)
            }) else { return false }
        targetState.pin(pinned)
        return true
    }

    /// Converts target proof into one exact local typing capability. Goal
    /// proof deliberately has no path to this capture closure.
    static func verifiedTextTarget(
        purpose: ActionVerificationPurpose,
        index: Int,
        snapshot: ScreenActionUISnapshot,
        capture: (String, AXUIElement) -> ScreenKeystrokeStreamTarget?
    ) -> ScreenKeystrokeStreamTarget? {
        guard purpose == .target,
              let element = snapshot.elementsByIndex[index] else { return nil }
        return capture(snapshot.observation.bundleID, element)
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
        if let target = targetState.target {
            guard ScreenContext.keystrokeStreamOwnsDraft(
                targetState.draft, target: target) else {
                clearActionTextState()
                return false
            }
            return true
        }
        guard targetState.mayCaptureGeneric,
              let app = onMain({ NSWorkspace.shared.frontmostApplication }),
              app.processIdentifier > 0,
              let target = ScreenContext.keystrokeStreamTarget(of: app),
              ScreenContext.keystrokeStreamOwnsDraft("", target: target)
        else {
            clearActionTextState()
            return false
        }
        targetState.captureGeneric(target)
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
              let target = targetState.target,
              expectedBundle(bundleID, matches: target.bundleID),
              ScreenContext.keystrokeStreamOwnsDraft(
                targetState.draft, target: target)
        else {
            clearActionTextState()
            return false
        }
        let priorDraft = targetState.draft
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
            targetState.updateDraft(resultingDraft)
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

    func pressKey(name: String, mods: [String], keyCode: CGKeyCode,
                  flags: CGEventFlags, expecting bundleID: String?) -> Bool {
        // One definition of "commits text", shared with the background host:
        // the policy table, judged on the plan's own key name. The old
        // keycode inference agreed only by coincidence (review finding).
        let committing = ActionPlan.Limits.committingKeys.contains(name.lowercased())
        if committing {
            guard let target = targetState.target,
                  !targetState.draft.isEmpty,
                  expectedBundle(bundleID, matches: target.bundleID),
                  ScreenContext.keystrokeStreamOwnsDraft(
                    targetState.draft, target: target)
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
        if pressed { clearActionTextState() }
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
