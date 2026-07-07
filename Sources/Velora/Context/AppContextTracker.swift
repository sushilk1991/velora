import AppKit
import Foundation

/// A snapshot of the app the user is dictating into; sent with the `start`
/// command so the engine can auto-resolve the formatting mode.
struct AppContext {
    let bundleID: String?
    let appName: String?

    /// JSON shape for the wire protocol `context` field.
    var payload: [String: Any] {
        [
            "bundle_id": bundleID as Any? ?? NSNull(),
            "app_name": appName as Any? ?? NSNull(),
            "mode": NSNull(),  // null = engine auto-resolves from mode files
        ]
    }
}

/// Tracks the frontmost application via NSWorkspace (no TCC required).
final class AppContextTracker {
    private var observer: NSObjectProtocol?
    private(set) var frontmost: NSRunningApplication?

    /// Current context snapshot (call at dictation start).
    var current: AppContext {
        let app = frontmost ?? NSWorkspace.shared.frontmostApplication
        return AppContext(bundleID: app?.bundleIdentifier, appName: app?.localizedName)
    }

    func start() {
        frontmost = NSWorkspace.shared.frontmostApplication
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            // Ignore activations of Velora itself (settings/onboarding windows)
            // so context reflects the app the user will paste into.
            if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                self?.frontmost = app
            }
        }
    }

    func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = nil
    }
}
