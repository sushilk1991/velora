import AppKit
import Foundation

/// A snapshot of the app the user is dictating into; sent with the `start`
/// command so the engine can auto-resolve the formatting mode.
struct AppContext {
    let bundleID: String?
    let appName: String?
    /// Screen-context entities (current file, person, channel, …) extracted at
    /// session start; empty when none are available. See `ScreenContext`.
    var entities: [ContextEntity] = []

    /// JSON shape for the wire protocol `context` field.
    var payload: [String: Any] {
        [
            "bundle_id": bundleID as Any? ?? NSNull(),
            "app_name": appName as Any? ?? NSNull(),
            "mode": NSNull(),  // null = engine auto-resolves from mode files
            "entities": entities.map { $0.payload },
        ]
    }
}

/// When each process last became the active app, since Velora launched.
/// Action Mode picks the copy of an app the user touched last from this:
/// window order alone misses a copy whose windows sit on another Space or
/// are minimized (review, 0.28). Main queue only.
enum ActivationHistory {
    private static var lastActive: [pid_t: Date] = [:]

    static func record(_ pid: pid_t, at date: Date = Date()) {
        lastActive[pid] = date
    }

    static func lastActivated(_ pid: pid_t) -> Date? {
        lastActive[pid]
    }
}

/// Tracks the frontmost application via NSWorkspace (no TCC required).
final class AppContextTracker {
    private var observer: NSObjectProtocol?
    private(set) var frontmost: NSRunningApplication?

    func start() {
        frontmost = NSWorkspace.shared.frontmostApplication
        if let frontmost {
            ActivationHistory.record(frontmost.processIdentifier)
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let app {
                ActivationHistory.record(app.processIdentifier)
            }
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
