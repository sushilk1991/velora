import AppKit
import ApplicationServices
import Foundation

/// Frontmost-tab page info (URL + title) cached per browser, with freshness.
/// Pure logic, separated so the cache policy is selftestable without Apple
/// Events.
struct BrowserPageCache {
    struct Entry: Equatable {
        let url: URL?
        let title: String?
        let at: Date
    }

    private var entries: [String: Entry] = [:]

    mutating func store(bundleID: String, url: URL?, title: String?, at: Date) {
        entries[bundleID.lowercased()] = Entry(url: url, title: title, at: at)
    }

    /// An entry no older than `maxAge`. A stale entry is worse than none:
    /// the user switches tabs constantly, and yesterday's URL would pick
    /// yesterday's writing style.
    func fresh(bundleID: String?, at now: Date, maxAge: TimeInterval) -> Entry? {
        guard let key = bundleID?.lowercased(),
              let entry = entries[key],
              now.timeIntervalSince(entry.at) <= maxAge
        else { return nil }
        return entry
    }
}

/// Reads the frontmost tab's URL and title from browsers whose accessibility
/// trees are closed to assistive clients. Chrome refuses the AX connection
/// outright (verified live, 2026-08-22: every call returns -25211 per
/// target), so the only supported road is one Apple Event per read — gated
/// by the user's Automation permission, used solely for the page address and
/// tab title, with nothing leaving the machine.
///
/// Safari and Gecko browsers are deliberately absent: their AX path works
/// and needs no permission prompt.
enum BrowserPage {
    /// Chromium-family bundles sharing Chrome's AppleScript dictionary
    /// ("active tab of front window"). Lowercased.
    static let appleScriptBundleIDs: Set<String> = [
        "com.google.chrome",
        "com.brave.browser",
        "com.microsoft.edgemac",
        "com.vivaldi.vivaldi",
        "com.operasoftware.opera",
        "company.thebrowser.browser",  // Arc
        "company.thebrowser.dia",
    ]

    static func usesAppleScript(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return appleScriptBundleIDs.contains(bundleID.lowercased())
    }

    /// The one-line script per browser. `application id` keeps it robust to
    /// renamed or localized apps.
    static func scriptSource(bundleID: String) -> String {
        "tell application id \"\(bundleID)\" to get "
            + "{URL of active tab of front window, title of active tab of front window}"
    }

    /// All Apple Events run here: NSAppleScript is not thread-safe, and a
    /// beachballing browser must never block dictation — callers either take
    /// the cache or wait on a bounded semaphore.
    private static let queue = DispatchQueue(
        label: "com.sushil.velora.browser-page", qos: .userInitiated)
    private static var cache = BrowserPageCache()
    private static let cacheLock = NSLock()
    /// One in-flight read per browser; a stuck Chrome must not pile up work.
    private static var inFlight = Set<String>()
    /// Last permission denial per browser, to avoid hammering TCC. The user
    /// can re-enable in System Settings → Privacy & Security → Automation;
    /// we re-check after this interval.
    private static var deniedUntil: [String: Date] = [:]
    private static let denialRecheck: TimeInterval = 60
    private static var staleNoticePIDs = Set<pid_t>()

    /// True when a running process predates its on-disk binary — Chrome
    /// auto-updates in place and keeps running the old code until relaunch,
    /// and macOS fails closed on BOTH Apple Events (-1743, promptless) and
    /// accessibility (-25211) against such a process (root-caused live,
    /// 2026-08-23). Failures from a stale browser mean "restart the
    /// browser", never "the user said no".
    static func processIsStale(launchDate: Date?, binaryModified: Date?) -> Bool {
        guard let launchDate, let binaryModified else { return false }
        return launchDate < binaryModified
    }

    static func isStale(_ app: NSRunningApplication) -> Bool {
        guard let executable = app.executableURL,
              let modified = (try? FileManager.default.attributesOfItem(
                atPath: executable.path))?[.modificationDate] as? Date
        else { return false }
        return processIsStale(launchDate: app.launchDate, binaryModified: modified)
    }

    /// Freshest cached info without any IPC — safe on the hotkey path.
    static func cachedInfo(bundleID: String?, maxAge: TimeInterval = 3.0)
        -> BrowserPageCache.Entry? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache.fresh(bundleID: bundleID, at: Date(), maxAge: maxAge)
    }

    /// Starts an async read; the result lands in the cache (and the optional
    /// callback). Called at dictation start so the value is ready by `stop`.
    static func refresh(_ app: NSRunningApplication?,
                        completion: ((BrowserPageCache.Entry?) -> Void)? = nil) {
        guard let app, let bundleID = app.bundleIdentifier?.lowercased(),
              usesAppleScript(bundleID) else {
            completion?(nil)
            return
        }
        if isStale(app) {
            // A stale browser fails every road promptlessly; asking would
            // record a phantom "denial" against the user.
            cacheLock.lock()
            let firstNotice = staleNoticePIDs.insert(app.processIdentifier).inserted
            cacheLock.unlock()
            if firstNotice {
                NSLog("Velora: %@ is running a replaced binary (auto-update) — "
                      + "browser context resumes after it restarts", bundleID)
            }
            completion?(nil)
            return
        }
        cacheLock.lock()
        let alreadyRunning = !inFlight.insert(bundleID).inserted
        cacheLock.unlock()
        if alreadyRunning {
            completion?(cachedInfo(bundleID: bundleID))
            return
        }
        queue.async {
            let entry = readNow(bundleID: bundleID)
            cacheLock.lock()
            inFlight.remove(bundleID)
            if let entry {
                cache.store(bundleID: bundleID, url: entry.url,
                            title: entry.title, at: entry.at)
            }
            cacheLock.unlock()
            completion?(entry)
        }
    }

    /// Bounded synchronous read for callers that can afford a short wait
    /// (rich entities on the background pass, Action Mode's executor). Falls
    /// back to the freshest cache on timeout; the in-flight read still
    /// completes and repopulates the cache for the next caller.
    static func info(_ app: NSRunningApplication?,
                     timeout: TimeInterval = 1.2) -> BrowserPageCache.Entry? {
        guard let app, let bundleID = app.bundleIdentifier?.lowercased(),
              usesAppleScript(bundleID) else { return nil }
        let done = DispatchSemaphore(value: 0)
        var result: BrowserPageCache.Entry?
        refresh(app) { entry in
            result = entry
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            return cachedInfo(bundleID: bundleID, maxAge: 10)
        }
        return result ?? cachedInfo(bundleID: bundleID, maxAge: 10)
    }

    // MARK: - The actual Apple Event (queue-confined)

    private static var compiledScripts: [String: NSAppleScript] = [:]

    private static func readNow(bundleID: String) -> BrowserPageCache.Entry? {
        guard permissionAllows(bundleID: bundleID) else { return nil }
        let script: NSAppleScript
        if let cached = compiledScripts[bundleID] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: scriptSource(bundleID: bundleID))
            else { return nil }
            compiledScripts[bundleID] = fresh
            script = fresh
        }
        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            // -1743: the user declined Automation for this browser.
            if code == -1743 {
                cacheLock.lock()
                deniedUntil[bundleID] = Date().addingTimeInterval(denialRecheck)
                cacheLock.unlock()
            }
            return nil
        }
        // {URL, title} arrives as a two-item list; a bare string means the
        // browser returned only one of them.
        let rawURL: String?
        let rawTitle: String?
        if descriptor.numberOfItems >= 2 {
            rawURL = descriptor.atIndex(1)?.stringValue
            rawTitle = descriptor.atIndex(2)?.stringValue
        } else {
            rawURL = descriptor.stringValue
            rawTitle = nil
        }
        let title = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return BrowserPageCache.Entry(
            url: ScreenContext.normalizedPageURL(rawURL),
            title: (title?.isEmpty ?? true) ? nil : title,
            at: Date())
    }

    // MARK: - Diagnostics (velora ax-probe)

    /// TCC state without prompting: 0 granted, -1743 denied, -1744 consent
    /// not yet asked/answered, -600 target not running.
    static func permissionStatus(bundleID: String) -> Int {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return Int(AEDeterminePermissionToAutomateTarget(
            target.aeDesc, typeWildCard, typeWildCard, false))
    }

    /// Runs the read synchronously and reports the AppleScript error code
    /// (0 = success), for ax-probe. Bypasses the denial cache on purpose.
    static func debugRead(bundleID: String) -> (code: Int, url: String) {
        var code = 0
        var url = ""
        queue.sync {
            guard let script = NSAppleScript(
                source: scriptSource(bundleID: bundleID)) else {
                code = -1
                return
            }
            var errorInfo: NSDictionary?
            let descriptor = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? -2
                return
            }
            url = (descriptor.numberOfItems >= 1
                   ? descriptor.atIndex(1)?.stringValue : descriptor.stringValue) ?? ""
        }
        return (code, url)
    }

    /// Diagnostic only: one harmless `get name` to Finder, reporting the
    /// error code or the returned name.
    static func debugProbeFinder() -> String {
        var out = ""
        queue.sync {
            guard let script = NSAppleScript(
                source: "tell application id \"com.apple.finder\" to get name")
            else {
                out = "compile-failed"
                return
            }
            var errorInfo: NSDictionary?
            let descriptor = script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                out = "error \((errorInfo[NSAppleScript.errorNumber] as? Int) ?? -2)"
            } else {
                out = "ok: \(descriptor.stringValue ?? "?")"
            }
        }
        return out
    }

    /// Asks TCC for Automation consent, prompting the user the first time.
    /// noErr = allowed; -1743 = the user said no; procNotFound = the browser
    /// isn't running (nothing to read anyway).
    private static func permissionAllows(bundleID: String) -> Bool {
        cacheLock.lock()
        let denied = deniedUntil[bundleID].map { $0 > Date() } ?? false
        cacheLock.unlock()
        if denied { return false }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        let status = AEDeterminePermissionToAutomateTarget(
            target.aeDesc, typeWildCard, typeWildCard, true)
        if status == noErr { return true }
        if status == -1743 {
            cacheLock.lock()
            deniedUntil[bundleID] = Date().addingTimeInterval(denialRecheck)
            cacheLock.unlock()
        }
        return false
    }
}
