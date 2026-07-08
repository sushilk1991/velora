import Foundation

/// Persists corrections Velora learns from the user's post-dictation edits into
/// `~/.velora/learned.json` — a small `{replacements, vocabulary}` file the
/// engine merges into its global vocab/replacements (see engine `_load_learned`).
///
/// Kept separate from the app-owned `config.json` so neither clobbers the other.
/// All access is main-actor (called from `DictationController`).
final class LearningStore {
    struct Learned: Codable {
        var replacements: [String: String] = [:]
        var vocabulary: [String] = []
        /// How many times each correction was seen — we only trust a correction
        /// once it recurs, to avoid learning one-off typos.
        var counts: [String: Int] = [:]
    }

    private(set) var learned = Learned()
    private let url: URL
    /// The SAME (wrong → right) pair must be seen this many times before it's
    /// committed — so one-off edits and conflicting one-offs never stick.
    private static let confirmThreshold = 2
    /// Cap on learned replacements so the file (and the cleanup prompt) can't
    /// grow without bound. At the cap, entries are evicted in a stable
    /// (alphabetical) order — deterministic, not the random dictionary order.
    private static let maxReplacements = 250

    /// Common high-frequency / homophone words we refuse to learn as global
    /// rewrites — two context-specific fixes must never make Velora rewrite
    /// every future "their" as "there".
    private static let stopwords: Set<String> = [
        "their", "there", "theyre", "they're", "then", "than", "form", "from", "your", "youre",
        "you're", "its", "it's", "were", "where", "we're", "our", "hour", "here", "hear", "for",
        "four", "fore", "to", "too", "two", "of", "off", "no", "know", "now", "one", "won",
        "right", "write", "by", "buy", "bye", "see", "sea", "son", "sun", "new", "knew", "would",
        "wood", "week", "weak", "made", "maid", "meet", "meat", "wait", "weight", "way", "weigh",
        "accept", "except", "affect", "effect", "loose", "lose", "quiet", "quite", "cant", "can't",
    ]

    init() {
        url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".velora/learned.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Learned.self, from: data) else { return }
        learned = decoded
    }

    private func save() {
        // The app can race the engine on first run; ensure ~/.velora exists.
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let data = try JSONEncoder().encode(learned)
            try data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSLog("Velora: failed to persist learned.json: \(error)")
        }
    }

    /// Records observed corrections (wrong → right). A pair is committed only on
    /// its 2nd matching sighting; common words are refused; a committed rule is
    /// never flipped by a single conflicting one-off. Returns true if anything
    /// was committed (caller reloads the engine).
    @discardableResult
    func observe(_ corrections: [(wrong: String, right: String)]) -> Bool {
        load()  // pick up any external change (e.g. a Settings "Clear") first
        var committed = false
        for correction in corrections {
            let wrong = correction.wrong.lowercased()
            guard !Self.stopwords.contains(wrong) else { continue }
            if learned.replacements[wrong] == correction.right { continue }  // already learned
            // Key the count by the exact PAIR so a conflicting right value can't
            // ride an earlier count over the threshold.
            let pairKey = "\(wrong)\u{2192}\(correction.right)"
            learned.counts[pairKey, default: 0] += 1
            if (learned.counts[pairKey] ?? 0) >= Self.confirmThreshold {
                learned.replacements[wrong] = correction.right
                if !learned.vocabulary.contains(correction.right) {
                    learned.vocabulary.append(correction.right)
                }
                committed = true
            }
        }
        // A committed pair no longer needs its count; drop it so `counts` can't
        // grow one entry per unique typo forever.
        for correction in corrections {
            let wrong = correction.wrong.lowercased()
            if learned.replacements[wrong] == correction.right {
                learned.counts.removeValue(forKey: "\(wrong)\u{2192}\(correction.right)")
            }
        }
        prune()
        save()
        return committed
    }

    /// Cap on how many pending (unconfirmed) pair counts we retain, so a stream
    /// of one-off typos can't grow learned.json without bound.
    private static let maxCounts = 500

    /// Bound the store deterministically: keep the alphabetically-first
    /// `maxReplacements` (stable, not the random dictionary order), trim vocab to
    /// match, and cap the pending-counts map.
    private func prune() {
        if learned.replacements.count > Self.maxReplacements {
            let overflow = learned.replacements.count - Self.maxReplacements
            for key in learned.replacements.keys.sorted().suffix(overflow) {
                learned.replacements.removeValue(forKey: key)
            }
        }
        let kept = Set(learned.replacements.values)
        learned.vocabulary = learned.vocabulary.filter { kept.contains($0) }
        if learned.counts.count > Self.maxCounts {
            let overflow = learned.counts.count - Self.maxCounts
            for key in learned.counts.keys.sorted().suffix(overflow) {
                learned.counts.removeValue(forKey: key)
            }
        }
    }

    /// How many corrections are currently learned (for the Settings UI).
    var count: Int { learned.replacements.count }

    /// One learned correction, for display/management in Settings.
    struct Entry: Identifiable, Equatable {
        var id: String { wrong }
        let wrong: String
        let right: String
    }

    /// Learned corrections, alphabetized (reads fresh from disk each call so the
    /// Settings list reflects edits made by the running DictationController).
    func entries() -> [Entry] {
        load()
        return learned.replacements
            .map { Entry(wrong: $0.key, right: $0.value) }
            .sorted { $0.wrong.localizedCaseInsensitiveCompare($1.wrong) == .orderedAscending }
    }

    /// Forgets a single learned correction (and any pending counts toward it).
    func remove(wrong: String) {
        load()
        let key = wrong.lowercased()
        guard let removedRight = learned.replacements.removeValue(forKey: key) else { return }
        // Preserve vocabulary order; only drop the removed value if nothing else
        // maps to it.
        if !learned.replacements.values.contains(removedRight) {
            learned.vocabulary.removeAll { $0 == removedRight }
        }
        learned.counts = learned.counts.filter { !$0.key.hasPrefix("\(key)\u{2192}") }
        save()
    }

    func clear() {
        learned = Learned()
        save()
    }
}
