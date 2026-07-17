import AppKit
import Foundation

/// Checks the public GitHub releases feed for a newer build — the update
/// channel for an app distributed as a DMG outside the App Store.
///
/// Privacy contract (README "Privacy" section states the same): at most one
/// anonymous HTTPS GET to api.github.com per day, carrying nothing beyond
/// what any HTTP request carries; it can be turned off in Settings → General.
/// Installing goes through UpdateInstaller, which downloads the release DMG
/// only when the user asks (or opted into automatic installs).
final class UpdateChecker {
    /// The downloadable DMG attached to a release.
    struct Asset: Equatable {
        let name: String
        let url: URL
        let size: Int
    }

    struct Update: Equatable {
        let version: String
        let page: URL
        /// nil when the release has no DMG — surfaces fall back to `page`.
        let asset: Asset?
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

    /// Test hook: VELORA_UPDATE_FEED_URL points the check at a local feed
    /// (file:// works) so the full pipeline can be exercised end-to-end.
    /// Harmless in production — UpdateInstaller verifies signatures, so a
    /// custom feed still can't install anything not released by this team.
    static var feedOverridden: Bool {
        ProcessInfo.processInfo.environment["VELORA_UPDATE_FEED_URL"] != nil
    }

    private static var apiURL: URL? {
        if let raw = ProcessInfo.processInfo.environment["VELORA_UPDATE_FEED_URL"] {
            return URL(string: raw)
        }
        return URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest")
    }
    /// 20h, not 24: a "same time every morning" launch pattern still checks
    /// daily instead of skipping every other day.
    private static let interval: TimeInterval = 20 * 60 * 60

    private let config = AppConfig.shared
    private var periodicTimer: Timer?

    /// Marketing version of the running build. Bare `swift build` binaries
    /// (no Info.plist) return nil and never see update prompts.
    static var currentVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// The automatic launch-time check plus a slow timer for instances that
    /// stay running for weeks — both gated on the Settings toggle and the
    /// daily interval, so combined they still make at most one request a day.
    func startPeriodicChecks() {
        checkAfterLaunch()
        guard periodicTimer == nil else { return }
        let timer = Timer(timeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            self?.checkIfDue()
        }
        timer.tolerance = 15 * 60
        RunLoop.main.add(timer, forMode: .common)
        periodicTimer = timer
    }

    /// The launch-time check: deferred — launch is busy with engine spawn and
    /// model loads, and the check is idle work.
    func checkAfterLaunch() {
        guard config.updateChecks,
              Date().timeIntervalSince(config.lastUpdateCheck) >= Self.interval
        else { return }
        // Re-gate on the timestamp after the deferral: a manual "Check Now"
        // in the meantime already satisfied today's check — firing again
        // would break the advertised once-a-day behavior.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.checkIfDue()
        }
    }

    private func checkIfDue() {
        guard config.updateChecks,
              Date().timeIntervalSince(config.lastUpdateCheck) >= Self.interval
        else { return }
        check { _ in }
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
                // launch instead of going quiet for a day. Never stamp under
                // a feed override — the e2e harness shares this defaults
                // domain with the real app and must not eat its daily check.
                if case .failed = outcome {} else if !Self.feedOverridden {
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
        // Non-HTTP responses stay allowed: the VELORA_UPDATE_FEED_URL test
        // hook serves the feed from a file:// URL.
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            return .failed("Could not read the releases feed")
        }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return .failed("Could not read the releases feed") }

        let remote = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard isNewer(remote, than: current) else { return .upToDate }

        let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/\(repoSlug)/releases/latest")
        guard let page else { return .upToDate }
        let asset = pickAsset(version: remote, assets: json["assets"] as? [[String: Any]] ?? [])
        return .updateAvailable(Update(version: remote, page: page, asset: asset))
    }

    /// The DMG to download for a release: the canonical `Velora-<version>.dmg`
    /// if present, otherwise any attached DMG, otherwise nil.
    static func pickAsset(version: String, assets: [[String: Any]]) -> Asset? {
        let dmgs = assets.compactMap { entry -> Asset? in
            guard let name = entry["name"] as? String, name.hasSuffix(".dmg"),
                  let raw = entry["browser_download_url"] as? String,
                  let url = URL(string: raw),
                  assetURLAllowed(url)
            else { return nil }
            return Asset(name: name, url: url, size: entry["size"] as? Int ?? 0)
        }
        return dmgs.first { $0.name == "Velora-\(version).dmg" } ?? dmgs.first
    }

    /// Downloads only come from GitHub over HTTPS. The signature gate in
    /// UpdateInstaller is the real security boundary, but there is no reason
    /// to hand a feed-controlled URL — and its DMG — to hdiutil's parsers
    /// from anywhere else. The VELORA_UPDATE_FEED_URL test hook lifts this
    /// (file:// assets) for the e2e harness.
    static func assetURLAllowed(_ url: URL) -> Bool {
        if ProcessInfo.processInfo.environment["VELORA_UPDATE_FEED_URL"] != nil { return true }
        guard url.scheme == "https", let host = url.host else { return false }
        return host == "github.com"
            || host.hasSuffix(".github.com")
            || host.hasSuffix(".githubusercontent.com")
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
