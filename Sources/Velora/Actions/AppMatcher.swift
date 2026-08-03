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
