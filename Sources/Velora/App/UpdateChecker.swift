import AppKit
import Foundation

/// Checks the public GitHub releases feed for a newer build — the update
/// channel for an app distributed as a DMG outside the App Store.
///
/// Privacy contract (README "Privacy" section states the same): at most one
/// anonymous HTTPS GET to api.github.com per day, carrying nothing beyond
/// what any HTTP request carries; it can be turned off in Settings → General.
/// No auto-download — "update" is a link to the release page.
final class UpdateChecker {
    struct Update: Equatable {
        let version: String
        let page: URL
    }

    enum Outcome: Equatable {
        case upToDate
        case updateAvailable(Update)
        case failed(String)
    }

    static let shared = UpdateChecker()

    static let repoSlug = "sushilk1991/velora"

    /// Fires on the main queue whenever any check discovers a newer release.
    var onUpdate: ((Update) -> Void)?

    /// The most recent discovery, for surfaces that appear after the check ran
    /// (the menubar menu rebuilds on every open; Settings opens late).
    private(set) var available: Update?

    private static let apiURL =
        URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest")
    /// 20h, not 24: a "same time every morning" launch pattern still checks
    /// daily instead of skipping every other day.
    private static let interval: TimeInterval = 20 * 60 * 60

    private let config = AppConfig.shared

    /// Marketing version of the running build. Bare `swift build` binaries
    /// (no Info.plist) return nil and never see update prompts.
    static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// The automatic launch-time check: gated on the Settings toggle and the
    /// daily interval, and deferred — launch is busy with engine spawn and
    /// model loads, and the check is idle work.
    func checkAfterLaunch() {
        guard config.updateChecks,
              Date().timeIntervalSince(config.lastUpdateCheck) >= Self.interval
        else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.config.updateChecks,
                  // Re-gate on the timestamp: a manual "Check Now" during the
                  // 30 s deferral already satisfied today's check — firing
                  // again would break the advertised once-a-day behavior.
                  Date().timeIntervalSince(self.config.lastUpdateCheck) >= Self.interval
            else { return }
            self.check { _ in }
        }
    }

    /// One check against the releases feed; completion on the main queue.
    func check(completion: @escaping (Outcome) -> Void) {
        guard let current = Self.currentVersion else {
            completion(.failed("Development build — updates are checked in packaged builds only"))
            return
        }
        guard let apiURL = Self.apiURL else {
            completion(.failed("Bad update URL"))
            return
        }
        var request = URLRequest(url: apiURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let outcome = Self.parse(
                current: current, data: data, response: response, error: error)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Stamp only reachable checks; an offline launch retries next
                // launch instead of going quiet for a day.
                if case .failed = outcome {} else {
                    self.config.lastUpdateCheck = Date()
                }
                if case .updateAvailable(let update) = outcome {
                    if update != self.available {
                        veloraLog("Velora: update available — \(update.version) (running \(current))")
                    }
                    self.available = update
                    self.onUpdate?(update)
                }
                completion(outcome)
            }
        }.resume()
    }

    static func parse(
        current: String, data: Data?, response: URLResponse?, error: Error?
    ) -> Outcome {
        if let error { return .failed(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return .failed("Could not read the releases feed") }

        let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard isNewer(remote, than: current) else { return .upToDate }

        let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/\(repoSlug)/releases/latest")
        guard let page else { return .upToDate }
        return .updateAvailable(Update(version: remote, page: page))
    }

    /// Numeric semver compare — "0.10.0" beats "0.9.9"; missing components
    /// count as zero; non-numeric junk in a component compares as zero.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
