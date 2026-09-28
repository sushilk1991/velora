import AppKit
import Foundation

/// Resolves the app name a plan asks for ("Chrome", "WhatsApp") to an app that
/// actually exists on this Mac.
///
/// Speech and app names disagree in mundane ways that would otherwise fail a
/// plan outright: people say "Chrome" for *Google Chrome*, "Messages" matches
/// both *Messages* and *Messenger*, and some shipped names carry invisible
/// characters — WhatsApp's `localizedName` on this machine starts with a U+200E
/// left-to-right mark, so a plain `==` against "WhatsApp" is false.
enum AppMatcher {
    /// Case-folded, punctuation- and format-character-free form used for all
    /// comparisons.
    static func normalize(_ name: String) -> String {
        let scalars = name.lowercased().unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Index of the best candidate for `query`, or nil when nothing is close
    /// enough. Ranked exact → prefix → word-prefix → substring, so "Messages"
    /// cannot be captured by "Messenger" while "Chrome" still finds
    /// "Google Chrome".
    static func bestMatch(for query: String, in candidates: [String]) -> Int? {
        let needle = normalize(query)
        guard !needle.isEmpty else { return nil }

        var prefixHit: Int?
        var wordPrefixHit: Int?
        var substringHit: Int?

        for (index, candidate) in candidates.enumerated() {
            let hay = normalize(candidate)
            if hay.isEmpty { continue }
            if hay == needle { return index }
            // Prefixes need three characters: "go" must not select
            // "Google Chrome", and no real app is asked for in two letters.
            if prefixHit == nil, needle.count >= 3, hay.hasPrefix(needle) { prefixHit = index }
            if wordPrefixHit == nil, needle.count >= 3,
               candidate.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                   .contains(where: { normalize(String($0)).hasPrefix(needle) }) {
                wordPrefixHit = index
            }
            // Substrings only for names long enough that a chance hit is
            // unlikely — "go" must not select "Google Chrome".
            if substringHit == nil, needle.count >= 4, hay.contains(needle) {
                substringHit = index
            }
        }
        return prefixHit ?? wordPrefixHit ?? substringHit
    }

    /// Whether two spoken/observed app names refer to the same app, in either
    /// direction ("Chrome" ↔ "Google Chrome"). Mirrors the engine validator's
    /// `app_name_matches` pair test, which decides whether a step moved the
    /// plan to a different app.
    static func namesSameApp(_ one: String, _ other: String) -> Bool {
        guard !normalize(one).isEmpty, !normalize(other).isEmpty else {
            return false
        }
        return bestMatch(for: one, in: [other]) != nil
            || bestMatch(for: other, in: [one]) != nil
    }

    /// Splits text into normalized words. Comparison happens word by word so a
    /// verify term cannot match across a boundary.
    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// True when EVERY term of a `verify_context` step appears on screen.
    ///
    /// Matching is whole-word, not substring, and every term must be present.
    /// Both rules exist because this check is what stands between "message
    /// Priya" and messaging someone else: a substring test lets the term
    /// "priya" be satisfied by a window titled "Priyanka Menon", and any-of
    /// semantics let one generic term carry a whole plan. Multi-word terms
    /// ("Himesh Singh") match a consecutive run of words.
    static func contextMatches(_ terms: [String], in haystacks: [String?]) -> Bool {
        let hayWords = haystacks.compactMap { $0 }.flatMap(words)
        guard !hayWords.isEmpty else { return false }
        let usable = terms.map(words).filter { !$0.isEmpty }
        guard !usable.isEmpty else { return false }
        for termWords in usable where !containsRun(termWords, in: hayWords) {
            return false
        }
        return true
    }

    private static func containsRun(_ needle: [String], in hay: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= hay.count else { return false }
        for start in 0...(hay.count - needle.count) {
            if Array(hay[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }
}

/// Several processes can run one app: a second Chrome profile, a browser an
/// automation tool launched. An action uses the copy the user touched last
/// (owner rule, 2026-09-28), never whichever copy the system lists first.
enum AppCopies {
    /// The pid of the user's copy used last. An automation tool's copy never
    /// counts: a script may bring it forward or close it at any time (see
    /// `onlyAutomation`). Among the user's copies: the only one; else the one
    /// activated last, wherever its windows are; else the first that owns an
    /// on-screen window in front-to-back order; else nil, and the system
    /// chooses. Never the newest launch: that is usually an automation copy
    /// (review, 0.28).
    ///
    ///     7066 user, activated 10:00   16137 automation, activated 10:05
    ///     windows, front → back: [Orca 700, Chrome 16137, Chrome 7066]
    ///     copies: [7066, 16137]                         →  7066
    static func latestUsed(
        _ copies: [(pid: Int, activated: Date?, automated: Bool)],
        windowOwners: [Int]
    ) -> Int? {
        let candidates = copies.filter { !$0.automated }
        if candidates.count == 1 {
            return candidates[0].pid
        }

        let activated = candidates.compactMap { copy in
            copy.activated.map { (pid: copy.pid, at: $0) }
        }
        if let last = activated.max(by: { $0.at < $1.at }) {
            return last.pid
        }

        let pids = Set(candidates.map(\.pid))
        return windowOwners.first(where: pids.contains)
    }

    /// Whether every running copy is an automation tool's: the user quit
    /// theirs. An action then starts the user's own copy rather than use an
    /// agent's, which may be signed out, headless, or closed mid-action
    /// (review, 0.28).
    ///
    ///     [automation, automation]  →  true    (start a new copy)
    ///     [automation, user]        →  false   (use the user's)
    ///     []                        →  false   (nothing runs: launch as usual)
    static func onlyAutomation(_ automated: [Bool]) -> Bool {
        !automated.isEmpty && !automated.contains(false)
    }

    /// `onlyAutomation` for the running regular copies of `bundleID`. Main
    /// thread only (AppKit).
    static func onlyAutomation(bundleID: String) -> Bool {
        onlyAutomation(regularCopies(of: bundleID).map {
            isAutomationLaunch(launchArguments(of: $0.processIdentifier))
        })
    }

    /// Chromium switches that automation tools launch a browser with:
    /// Puppeteer and Playwright (`--enable-automation`, `--headless`,
    /// `--remote-debugging-pipe`), agent browsers (`--remote-debugging-port`).
    private static let automationSwitches = [
        "--enable-automation", "--headless",
        "--remote-debugging-pipe", "--remote-debugging-port",
    ]

    /// Whether a process's launch arguments mark an automation tool's copy.
    ///
    ///     [chrome, "--remote-debugging-port=54357"]  →  true
    ///     [chrome, "--profile-directory=Default"]    →  false
    static func isAutomationLaunch(_ arguments: [String]) -> Bool {
        arguments.contains { argument in
            automationSwitches.contains {
                argument == $0 || argument.hasPrefix($0 + "=")
            }
        }
    }

    /// The running copy of `app`'s bundle the user touched last; `app`
    /// itself when it is the only copy or nothing shows which copy was used
    /// last. Main thread only (AppKit).
    static func latest(of app: NSRunningApplication) -> NSRunningApplication {
        guard let bundleID = app.bundleIdentifier else { return app }
        return latest(bundleID: bundleID) ?? app
    }

    /// The running regular copy of `bundleID` the user touched last; nil
    /// when several run and nothing singles out a user copy.
    static func latest(bundleID: String) -> NSRunningApplication? {
        let copies = regularCopies(of: bundleID)
        guard copies.count > 1 else { return copies.first }

        let pick = latestUsed(
            copies.map {
                (Int($0.processIdentifier),
                 ActivationHistory.lastActivated($0.processIdentifier),
                 isAutomationLaunch(launchArguments(of: $0.processIdentifier)))
            },
            windowOwners: windowOwnersFrontToBack())
        return copies.first { Int($0.processIdentifier) == pick }
    }

    private static func regularCopies(
        of bundleID: String
    ) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier == bundleID
        }
    }

    /// A same-user process's argv, from the kernel's KERN_PROCARGS2 block;
    /// empty when it cannot be read.
    ///
    ///     [argc: Int32][exec path\0][\0 padding…][argv[0]\0][argv[1]\0]…[env…]
    private static func launchArguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        let countSize = MemoryLayout<Int32>.size
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size > countSize else { return [] }
        var block = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &block, &size, nil, 0) == 0,
              size > countSize else { return [] }

        let argc = block.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = countSize
        while index < size, block[index] != 0 { index += 1 }  // exec path
        while index < size, block[index] == 0 { index += 1 }  // padding

        var arguments: [String] = []
        while index < size, arguments.count < Int(argc) {
            let start = index
            while index < size, block[index] != 0 { index += 1 }
            arguments.append(String(decoding: block[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    /// Owner pids of on-screen normal windows, front to back. Only the
    /// on-screen list is z-ordered: `.optionAll` interleaves hidden windows
    /// in no useful order (measured 2026-09-28).
    private static func windowOwnersFrontToBack() -> [Int] {
        guard let rows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard (row[kCGWindowLayer as String] as? Int) == 0 else {
                return nil
            }
            return row[kCGWindowOwnerPID as String] as? Int
        }
    }
}

/// Apps installed on this Mac, by display name. Scanned lazily and cached: the
/// planner names apps, and a plan for an app that is installed-but-not-running
/// still has to launch.
final class InstalledApps {
    static let shared = InstalledApps()

    private var cache: [(name: String, url: URL)] = []
    private var scannedAt: Date?
    private let ttl: TimeInterval = 300

    private static let searchPaths = [
        "/Applications", "/Applications/Utilities", "/System/Applications",
        "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    /// (display name, bundle URL) for every .app in the standard locations.
    func entries() -> [(name: String, url: URL)] {
        if let scannedAt, Date().timeIntervalSince(scannedAt) < ttl, !cache.isEmpty {
            return cache
        }
        var found: [(name: String, url: URL)] = []
        var seen = Set<String>()
        for path in Self.searchPaths {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            for entry in contents where entry.hasSuffix(".app") {
                let name = String(entry.dropLast(4))
                guard seen.insert(name.lowercased()).inserted else { continue }
                found.append((name, URL(fileURLWithPath: path + "/" + entry)))
            }
        }
        cache = found
        scannedAt = Date()
        return found
    }

    func url(forName name: String) -> URL? {
        let list = entries()
        guard let index = AppMatcher.bestMatch(for: name, in: list.map(\.name)) else {
            return nil
        }
        return list[index].url
    }
}
