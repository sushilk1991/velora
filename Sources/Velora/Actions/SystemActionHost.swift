import AppKit
import ApplicationServices
import Foundation

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

    init(inserter: TextInserter) {
        self.inserter = inserter
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

    /// Titles of the currently selected rows near the focused element — the
    /// highlighted entry in a quick switcher, for instance. These strings are
    /// written by the target app, not by us, so unlike a field's value they are
    /// real evidence about what the user is about to act on.
    func focusedSelectionLabel() -> String? {
        guard Permissions.accessibilityGranted,
              let app = onMain({ NSWorkspace.shared.frontmostApplication }),
              let focused = ScreenContext.focusedElement(of: app) else { return nil }
        AXUIElementSetMessagingTimeout(focused, 0.5)
        // Chromium/Electron hangs the selected row off the input element via
        // this relation, which is how a quick switcher's highlighted result is
        // exposed to VoiceOver.
        var labels: [String] = []
        for attribute in ["AXSelectedRows", "AXSelectedChildren",
                          "AXLinkedUIElements", "AXSelectedCells"] {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                    focused, attribute as CFString, &ref) == .success,
                  let elements = ref as? [AXUIElement] else { continue }
            for element in elements.prefix(3) {
                AXUIElementSetMessagingTimeout(element, 0.3)
                labels.append(contentsOf: Self.textOf(element, depth: 2))
            }
            if !labels.isEmpty { break }
        }
        return labels.isEmpty ? nil : String(labels.joined(separator: " ").prefix(400))
    }

    /// App-authored text of an element and, briefly, its children. Row labels in
    /// Electron lists usually sit on a child static-text node rather than the
    /// row itself.
    private static func textOf(_ element: AXUIElement, depth: Int) -> [String] {
        var found: [String] = []
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
               let text = ref as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                found.append(String(text.prefix(120)))
            }
        }
        guard depth > 0, found.isEmpty else { return found }
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            // Bounded: a Slack row's subtree is small, but an unbounded walk of
            // an Electron tree is seconds of IPC.
            for child in children.prefix(6) {
                found.append(contentsOf: textOf(child, depth: depth - 1))
                if found.count >= 4 { break }
            }
        }
        return found
    }

    // MARK: - Input

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
        guard canPostInput else { return false }
        if let bundleID, !bundleID.isEmpty,
           onMain({ NSWorkspace.shared.frontmostApplication?.bundleIdentifier }) != bundleID {
            return false
        }
        // Synchronous by design: the executor's next step (often Return) must
        // not race the characters into the field.
        let finished = DispatchSemaphore(value: 0)
        var succeeded = false
        inserter.insertViaTyping(text, targetBundleID: bundleID) { ok in
            succeeded = ok
            finished.signal()
        }
        let deadline = DispatchTime.now() + .milliseconds(max(3_000, text.count * 12))
        guard finished.wait(timeout: deadline) == .success else { return false }
        return succeeded
    }

    func pasteText(_ text: String, expecting bundleID: String?) -> Bool {
        // Typing is the safer primitive for action plans: it never touches the
        // user's clipboard, and plan text is short by construction.
        typeText(text, expecting: bundleID)
    }

    func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags,
                  expecting bundleID: String?) -> Bool {
        guard canPostInput else { return false }
        if let bundleID, !bundleID.isEmpty,
           onMain({ NSWorkspace.shared.frontmostApplication?.bundleIdentifier }) != bundleID {
            return false
        }
        return inserter.pressKey(keyCode, flags: flags)
    }

    func sleep(ms: Int) {
        guard ms > 0 else { return }
        Thread.sleep(forTimeInterval: Double(ms) / 1000)
    }

    func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
