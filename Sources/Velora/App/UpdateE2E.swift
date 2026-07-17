import AppKit
import Foundation

/// Headless updater end-to-end (`Velora --update-e2e [--install]`): checks
/// the feed (point VELORA_UPDATE_FEED_URL at a local JSON to control it),
/// downloads + verifies + stages the release DMG, and with --install spawns
/// the swap helper and exits so the helper replaces the bundle this binary
/// ran from — run it on a COPY of the app, never the installed one. The app
/// itself never starts (no engine, menubar, or hotkeys). The harness cannot
/// observe the swap (the helper waits for this very process to exit), so
/// after --install returns, check the bundle's version + codesign yourself.
enum UpdateE2E {
    static func run(install: Bool) -> Int32 {
        print("update-e2e: running \(UpdateChecker.currentVersion ?? "<no version — bare binary>") from \(Bundle.main.bundleURL.path)")
        var outcome: UpdateChecker.Outcome?
        UpdateChecker.shared.check { outcome = $0 }
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
                    if install {
                        print("update-e2e: spawning swap helper and exiting")
                        UpdateInstaller.shared.installOnExit()
                    }
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
}
