import Foundation

/// One vocabulary for the updater, shared by the update window, Settings ›
/// General, About, and the menubar so a single installer state never reads
/// three different ways across surfaces.
///
///     idle ──▶ "Update to Velora 1.2.3…"        (opens the window)
///     downloading ──▶ "Downloading Velora 1.2.3 — 42%"
///     verifying ──▶ "Verifying Velora 1.2.3…"
///     ready ──▶ "Restart to Update"  or  "Waiting to Install…" once committed
///     installing ──▶ "Installing…"
///     failed ──▶ the reason, plus "Try Again" or "Open Releases Page"
enum UpdateCopy {
    static let installTitle = "Install Update"
    static let restartTitle = "Restart to Update"
    static let waitingTitle = "Waiting to Install…"
    static let installingTitle = "Installing…"
    static let tryAgainTitle = "Try Again"
    static let releasesPageTitle = "Open Releases Page"
    static let skipTitle = "Skip This Version"
    static let notNowTitle = "Not Now"
    static let cancelInstallTitle = "Cancel Install"

    /// Menubar and Settings offer for a discovered, not yet staged release.
    static func updateTitle(_ version: String) -> String {
        "Update to Velora \(version)…"
    }

    /// Menubar row once a verified build is staged.
    static func restartTitle(_ version: String) -> String {
        "Restart to Update to \(version)"
    }

    /// Caption for a non-idle installer state; nil while idle.
    static func caption(
        for state: UpdateInstaller.State, installsWhenReady: Bool
    ) -> String? {
        switch state {
        case .idle:
            return nil
        case .downloading(let version, let progress):
            return "Downloading Velora \(version) — \(Int(progress * 100))%"
        case .verifying(let version):
            return "Verifying Velora \(version)…"
        case .ready(let version):
            if installsWhenReady {
                return "Velora \(version) installs when current work finishes."
            }
            return "Velora \(version) is downloaded and verified."
        case .installing:
            return "Installing and restarting Velora…"
        case .failed(let reason):
            return reason
        }
    }
}
