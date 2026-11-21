import Foundation

/// Separates local debug/dev app bundles (`Velora Dev.app`,
/// `com.sushil.velora.dev`) from release `Velora.app` (`com.sushil.velora`)
/// so a developer build never collides with an installed release on bundle ID,
/// sockets, preferences, Application Support, or the self-updater.
enum AppIdentity {
    static let releaseBundleID = "com.sushil.velora"
    static let devBundleID = "com.sushil.velora.dev"

    static func isDevBundle(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == devBundleID
    }

    static var isDevBuild: Bool {
        isDevBundle(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    static func displayName(bundleIdentifier: String?) -> String {
        isDevBundle(bundleIdentifier: bundleIdentifier) ? "Velora Dev" : "Velora"
    }

    static var displayName: String {
        displayName(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    static func dataDirectoryName(bundleIdentifier: String?) -> String {
        isDevBundle(bundleIdentifier: bundleIdentifier) ? ".velora-dev" : ".velora"
    }

    static func applicationSupportName(bundleIdentifier: String?) -> String {
        isDevBundle(bundleIdentifier: bundleIdentifier) ? "Velora Dev" : "Velora"
    }

    static func updatesDisabledMessage(bundleIdentifier: String?) -> String {
        if isDevBundle(bundleIdentifier: bundleIdentifier) {
            return "Velora Dev does not self-update. Open Velora.app for release updates."
        }
        return "Open Velora.app to check for and install updates."
    }
}
