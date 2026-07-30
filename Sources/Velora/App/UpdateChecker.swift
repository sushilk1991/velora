import AppKit
import Foundation

extension Notification.Name {
    /// Posted on the main queue after a successful release-feed check, including
    /// when the running build is already current. Settings uses this to expose
    /// the latest release notes without maintaining a second network request.
    static let veloraUpdateCheckCompleted = Notification.Name("VeloraUpdateCheckCompleted")
}

/// Checks the public GitHub releases feed for a newer build — the update
/// channel for an app distributed as a DMG outside the App Store.
///
/// Privacy contract (README "Privacy" section states the same): at most one
/// anonymous HTTPS GET to api.github.com per day, carrying nothing beyond
/// what any HTTP request carries; it can be turned off in Settings → General.
/// Installing goes through UpdateInstaller, which downloads the release DMG
/// only when the user asks (or opted into automatic installs).
final class UpdateChecker {
    enum CheckOrigin: Equatable {
        case automatic
        case manual
    }

    /// The downloadable DMG attached to a release.
    struct Asset: Equatable {
        let name: String
        let url: URL
        let size: Int
    }

    struct Release: Equatable {
        let version: String
        let page: URL
        /// GitHub's release body. It is displayed as inert Markdown-like text;
        /// it is never executed or loaded into a web view.
        let notes: String
        let publishedAt: Date?
        /// nil when the release has no DMG — surfaces fall back to `page`.
        let asset: Asset?
    }

    /// Existing call sites describe a newer `Release` as an update.
    typealias Update = Release

    enum Outcome: Equatable {
        case upToDate(Release)
        case updateAvailable(Update)
        case failed(String)
    }

    static let shared = UpdateChecker()

    static let repoSlug = "sushilk1991/velora"

    /// Fires once on the main queue whenever a coalesced check discovers a
    /// newer release. The origin keeps an explicit manual check from being
    /// treated as an automatic prompt.
    var onUpdate: ((Update, CheckOrigin) -> Void)?

    /// The most recent discovery, for surfaces that appear after the check ran
    /// (the menubar menu rebuilds on every open; Settings opens late).
    private(set) var available: Update?

    /// Latest published release even when this build is already current. This
    /// is the changelog source for Settings after any successful check.
    private(set) var latestRelease: Release?

    private struct PendingCheck {
        let origin: CheckOrigin
        let completion: (Outcome) -> Void
    }
    private var pendingChecks: [PendingCheck] = []

    /// Test hook: VELORA_UPDATE_FEED_URL points the check at a local feed
    /// (file:// works) so the full pipeline can be exercised end-to-end.
    /// Harmless in production — UpdateInstaller verifies signatures, so a
    /// custom feed still can't install anything not released by this team.
    static var feedOverridden: Bool {
        ProcessInfo.processInfo.environment["VELORA_UPDATE_FEED_URL"] != nil
    }

    static func allowsPersistentState(feedOverridden: Bool) -> Bool {
        !feedOverridden
    }

    static var persistentStateAllowed: Bool {
        allowsPersistentState(feedOverridden: feedOverridden)
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

    static let maximumReleaseNotesBytes = 524_288

    private let config = AppConfig.shared
    private var periodicTimer: Timer?

    private init() {
        guard let restored = Self.restoredState(
            currentVersion: Self.currentVersion,
            version: config.cachedReleaseVersion,
            rawPage: config.cachedReleasePage,
            notes: config.cachedReleaseNotes,
            publishedAt: config.cachedReleasePublishedAt,
            name: config.cachedReleaseAssetName,
            rawURL: config.cachedReleaseAssetURL,
            size: config.cachedReleaseAssetSize)
        else { return }
        latestRelease = restored.latest
        available = restored.available
    }

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
        check(origin: .automatic) { _ in }
    }

    /// One check against the releases feed; completion on the main queue.
    func check(
        origin: CheckOrigin = .manual,
        completion: @escaping (Outcome) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let current = Self.currentVersion else {
            completion(.failed("Development build — updates are checked in packaged builds only"))
            return
        }
        guard let apiURL = Self.apiURL else {
            completion(.failed("Bad update URL"))
            return
        }
        pendingChecks.append(PendingCheck(origin: origin, completion: completion))
        guard pendingChecks.count == 1 else { return }
        var request = URLRequest(url: apiURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let outcome = Self.parse(
                current: current, data: data, response: response, error: error)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let checks = self.pendingChecks
                self.pendingChecks.removeAll()
                // Stamp only reachable checks; an offline launch retries next
                // launch instead of going quiet for a day. Never stamp under
                // a feed override — the e2e harness shares this defaults
                // domain with the real app and must not eat its daily check.
                switch outcome {
                case .failed:
                    break
                case .upToDate(let release):
                    if Self.persistentStateAllowed {
                        self.config.lastUpdateCheck = Date()
                        self.persist(release)
                    }
                    self.latestRelease = release
                    self.available = nil
                    NotificationCenter.default.post(
                        name: .veloraUpdateCheckCompleted, object: nil)
                case .updateAvailable(let update):
                    if Self.persistentStateAllowed {
                        self.config.lastUpdateCheck = Date()
                        self.persist(update)
                    }
                    self.latestRelease = update
                    if update != self.available {
                        veloraLog("Velora: update available — \(update.version) (running \(current))")
                    }
                    self.available = update
                    NotificationCenter.default.post(
                        name: .veloraUpdateCheckCompleted, object: nil)
                    let origin: CheckOrigin = checks.contains {
                        $0.origin == .automatic
                    } ? .automatic : .manual
                    self.onUpdate?(update, origin)
                }
                checks.forEach { $0.completion(outcome) }
            }
        }.resume()
    }

    private func persist(_ release: Release) {
        config.cacheRelease(
            version: release.version,
            page: release.page.absoluteString,
            notes: release.notes,
            publishedAt: release.publishedAt,
            assetName: release.asset?.name,
            assetURL: release.asset?.url.absoluteString,
            assetSize: release.asset?.size ?? 0)
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
        guard !remote.isEmpty, remote.count <= 64,
              remote.range(
                of: "^[0-9A-Za-z.-]+$", options: .regularExpression) != nil
        else { return .failed("The release version is invalid") }
        let feedPage = (json["html_url"] as? String).flatMap(URL.init(string:))
        let page = feedPage.flatMap { releasePageAllowed($0) ? $0 : nil }
            ?? URL(string: "https://github.com/\(repoSlug)/releases/latest")
        guard let page else { return .failed("Release page URL is invalid") }
        let notes = boundedReleaseNotes(json["body"] as? String)
        let publishedAt = (json["published_at"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
        let asset = pickAsset(version: remote, assets: json["assets"] as? [[String: Any]] ?? [])
        let release = Release(
            version: remote,
            page: page,
            notes: notes,
            publishedAt: publishedAt,
            asset: asset)
        return isNewer(remote, than: current)
            ? .updateAvailable(release)
            : .upToDate(release)
    }

    static func boundedReleaseNotes(_ raw: String?) -> String {
        let notes = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !notes.isEmpty else {
            return "No release notes were provided for this version."
        }
        guard notes.utf8.count > maximumReleaseNotesBytes else { return notes }
        let suffix = "\n\nRelease notes were shortened here. View the complete notes on GitHub."
        let budget = maximumReleaseNotesBytes - suffix.utf8.count
        var prefix = String(decoding: notes.utf8.prefix(budget), as: UTF8.self)
        while prefix.utf8.count > budget { prefix.removeLast() }
        return prefix + suffix
    }

    static func releasePageAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host == "github.com" else { return false }
        let prefix = "/\(repoSlug)/releases"
        return url.path == prefix || url.path.hasPrefix(prefix + "/")
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

    /// Reconstructs only bounded, official asset metadata persisted by a
    /// successful release check. The installer still revalidates size,
    /// signature, identity, exact version, and Gatekeeper before replacement.
    static func restoredAsset(name: String?, rawURL: String?, size: Int) -> Asset? {
        guard let name,
              !name.isEmpty, name.count <= 255, name.hasSuffix(".dmg"),
              !name.contains("/"), !name.contains("\\"),
              let rawURL, rawURL.count <= 2_048,
              let url = URL(string: rawURL),
              assetURLAllowed(url)
        else { return nil }
        return Asset(name: name, url: url, size: max(0, size))
    }

    /// Connects the machine-local cache to both changelog and actionable
    /// update state. Keeping this pure makes the relaunch path testable without
    /// replacing the process-wide AppConfig/UpdateChecker singletons.
    static func restoredState(
        currentVersion: String?,
        version: String?,
        rawPage: String?,
        notes: String?,
        publishedAt: Date?,
        name: String?,
        rawURL: String?,
        size: Int
    ) -> (latest: Release, available: Release?)? {
        guard let version,
              let rawPage,
              let page = URL(string: rawPage),
              releasePageAllowed(page),
              let notes,
              notes.utf8.count <= maximumReleaseNotesBytes,
              currentVersion.map({
                  !isNewer($0, than: version)
              }) ?? true
        else { return nil }
        let release = Release(
            version: version,
            page: page,
            notes: notes,
            publishedAt: publishedAt,
            asset: restoredAsset(name: name, rawURL: rawURL, size: size))
        let actionable = currentVersion.map {
            isNewer(version, than: $0)
        } ?? false
        return (release, actionable ? release : nil)
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
