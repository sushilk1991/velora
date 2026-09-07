import AppKit
import Foundation

/// Updater end-to-end (`Velora --update-e2e [--install]`): checks
/// the feed (point VELORA_UPDATE_FEED_URL at a local JSON to control it),
/// downloads + verifies + stages the release DMG, and with --install exercises
/// the production AppDelegate, update window, and graceful quit path.
/// Run it on a COPY of the app, never the installed one. The original process
/// cannot observe work that intentionally starts after it exits, so the parent
/// test must verify the copy's new version/signature and the relaunched process.
enum UpdateE2E {
    private static let installTimeout: TimeInterval = 300

    static func run(install: Bool) -> Int32 {
        if install { return runInstall() }
        print("update-e2e: running \(UpdateChecker.currentVersion ?? "<no version — bare binary>") from \(Bundle.main.bundleURL.path)")
        var outcome: UpdateChecker.Outcome?
        UpdateChecker.shared.check(origin: .manual) { outcome = $0 }
        while outcome == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        switch outcome! {
        case .failed(let reason):
            print("update-e2e: check failed — \(reason)")
            return 1
        case .upToDate:
            print("update-e2e: up to date")
            return 0
        case .updateAvailable(let update):
            print("update-e2e: found \(update.version), asset \(update.asset?.name ?? "<none>") (\(update.asset?.size ?? 0) bytes)")
            if let blocker = UpdateInstaller.installBlocker() {
                print("update-e2e: cannot install in place — \(blocker)")
                return 1
            }
            UpdateInstaller.shared.begin(update)
            var lastLogged = -1
            while true {
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                switch UpdateInstaller.shared.state {
                case .downloading(_, let progress):
                    let percent = Int(progress * 100)
                    if percent / 20 > lastLogged / 20 {
                        print("update-e2e: downloading — \(percent)%")
                        lastLogged = percent
                    }
                case .verifying:
                    break
                case .ready(let version):
                    print("update-e2e: \(version) verified and staged")
                    return 0
                case .failed(let reason):
                    print("update-e2e: failed — \(reason)")
                    return 1
                case .idle, .installing:
                    break
                }
            }
        }
    }

    /// Use a disposable bundle and a nonexistent VELORA_ENGINE_DIR to exercise
    /// real app lifecycle callbacks without loading speech models.
    private static func runInstall() -> Int32 {
        guard let enginePath = ProcessInfo.processInfo.environment["VELORA_ENGINE_DIR"],
              !enginePath.isEmpty, !FileManager.default.fileExists(atPath: enginePath),
              UpdateChecker.feedOverridden,
              !Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            print("update-e2e: use a disposable app, a test feed, and a nonexistent VELORA_ENGINE_DIR")
            return 1
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard !NSRunningApplication.runningApplications(
            withBundleIdentifier: UpdateInstaller.requiredBundleID
        ).contains(where: { $0.processIdentifier != ownPID }) else {
            print("update-e2e: quit other Velora instances before testing installation")
            return 1
        }
        let staged = (try? FileManager.default.contentsOfDirectory(
            at: UpdateInstaller.updatesDirectory, includingPropertiesForKeys: nil)) ?? []
        guard !staged.contains(where: { ["app", "dmg"].contains($0.pathExtension) }) else {
            print("update-e2e: preserve the existing staged update before testing")
            return 1
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        let deadline = Date().addingTimeInterval(installTimeout)
        var checkStarted = false
        var previousState: UpdateInstaller.State?
        let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
            guard Date() < deadline else {
                print("update-e2e: install did not finish before the deadline")
                exit(1)
            }
            // This callback is wired by the real composition root. Waiting
            // for it prevents the test from bypassing restart safety again.
            if !checkStarted, UpdateInstaller.shared.relaunchBlockReason != nil {
                checkStarted = true
                UpdateChecker.shared.check(origin: .manual) { outcome in
                    guard case .updateAvailable(let update) = outcome else {
                        print("update-e2e: expected a newer release, got \(outcome)")
                        exit(1)
                    }
                    UpdateWindowController.shared.show(update)
                    let model = UpdateWindowModel()
                    model.present(update)
                    model.install()
                }
            }
            let state = UpdateInstaller.shared.state
            guard state != previousState else { return }
            previousState = state
            switch state {
            case .ready(let version):
                let blocker = UpdateInstaller.shared.relaunchBlockReason?() ?? "none"
                print("update-e2e: \(version) ready; restart blocker: \(blocker)")
            case .installing:
                print("update-e2e: installing through normal AppKit termination")
            case .failed(let reason):
                print("update-e2e: failed — \(reason)")
                exit(1)
            default: break
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        withExtendedLifetime(delegate) { app.run() }
        return 1
    }
}
