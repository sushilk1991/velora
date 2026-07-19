import Foundation
import Observation

/// One explicit handoff from App Intents into the app scene. The persisted
/// bit covers cold launch; `requestID` covers invocations while the app is open.
@MainActor
@Observable
final class CaptureLaunchRouter {
    static let shared = CaptureLaunchRouter()

    private static let pendingKey = "velora.pendingDictateToClipboard"
    private let defaults: UserDefaults

    private(set) var requestID = UUID()

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func requestCapture() {
        defaults.set(true, forKey: Self.pendingKey)
        requestID = UUID()
    }

    func consumePendingCapture() -> Bool {
        guard defaults.bool(forKey: Self.pendingKey) else { return false }
        defaults.removeObject(forKey: Self.pendingKey)
        return true
    }
}
