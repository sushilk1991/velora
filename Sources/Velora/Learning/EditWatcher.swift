import AppKit
import ApplicationServices

/// Watches ONE AX element — the field Velora just pasted into — for value
/// changes, so an edit the user makes right away is learned right away
/// instead of at the 45s re-check or the next dictation.
///
/// Main-thread only: the AXObserver's run-loop source lives on the main run
/// loop and callbacks arrive there. Fails soft (some apps/fields don't emit
/// kAXValueChanged) — callers keep the timer-based re-check as the fallback.
final class EditWatcher {
    private var observer: AXObserver?
    private var element: AXUIElement?

    /// Fired on the main thread on every value change of the watched element.
    /// Callers debounce — a fast typist fires this per keystroke.
    var onChange: (() -> Void)?

    /// Starts watching `element`; replaces any previous watch. Returns false
    /// when the app doesn't support AX observation (caller falls back to
    /// timers).
    @discardableResult
    func watch(_ element: AXUIElement) -> Bool {
        stop()
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return false }
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<EditWatcher>.fromOpaque(refcon).takeUnretainedValue().onChange?()
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let obs = created else {
            return false
        }
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard AXObserverAddNotification(obs, element, kAXValueChangedNotification as CFString, refcon) == .success
        else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        self.element = element
        return true
    }

    func stop() {
        if let obs = observer {
            if let el = element {
                AXObserverRemoveNotification(obs, el, kAXValueChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
        element = nil
    }

    deinit {
        // Owned by the main-actor DictationController, so deinit runs on main.
        stop()
    }
}
