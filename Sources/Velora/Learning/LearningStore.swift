import AppKit
import Foundation

/// Persists corrections Velora learns from the user's post-dictation edits into
/// `~/.velora/learned.json` — a small file the engine merges into its
/// global vocab/replacements (see engine `_load_learned`).
///
/// Two tiers of correction (the owner's "don't learn the literal replacement"
/// steer): a wrong side that is NOT a real word ("wrold", "valora") is a safe
/// deterministic `replacement`; a wrong side that IS a real dictionary word
/// ("lung" misheard for "Airlearn") goes into `soft_replacements`, which the
/// engine surfaces to the cleanup LLM as a context-gated hint — a genuine
/// "lung" stays a lung. Either way the RIGHT side joins `vocabulary`, which
/// biases whisper's recognition itself (the primary learning channel).
///
/// Kept separate from the app-owned `config.json` so neither clobbers the other.
/// All access is main-actor (called from `DictationController`).
final class LearningStore {
    struct Learned: Codable {
        var replacements: [String: String] = [:]
        /// Context-gated corrections: applied by the cleanup LLM only when the
        /// context clearly means the corrected term, never deterministically.
        var softReplacements: [String: String] = [:]
        var vocabulary: [String] = []
        /// How many times each correction was seen — we only trust a correction
        /// once it recurs, to avoid learning one-off typos.
        var counts: [String: Int] = [:]

        enum CodingKeys: String, CodingKey {
            case replacements
            case softReplacements = "soft_replacements"
            case vocabulary
            case counts
        }

        init() {}

        /// Tolerant decode: files written before `soft_replacements` existed
        /// (or by older builds) must keep loading.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            replacements = (try? c.decode([String: String].self, forKey: .replacements)) ?? [:]
            softReplacements = (try? c.decode([String: String].self, forKey: .softReplacements)) ?? [:]
            vocabulary = (try? c.decode([String].self, forKey: .vocabulary)) ?? []
            counts = (try? c.decode([String: Int].self, forKey: .counts)) ?? [:]
        }
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
        // Sentence-starters that are always capitalized: with the name-pair
        // distance gate relaxed, "Hello" → "Howdy" must not become a rule.
        "hello", "hi", "hey", "okay", "ok", "yeah", "yes", "dear", "thanks", "thank", "the",
        "this", "that", "please", "sorry",
    ]

    init() {
        url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".velora/learned.json")
        load()
    }

    /// Test hook: point the store at an arbitrary file.
    init(url: URL) {
        self.url = url
        load()
    }

    /// True when macOS's spellchecker considers `word` a correctly-spelled
    /// real word — such a wrong side must never become a deterministic global
    /// rewrite (a real "lung" would be corrupted forever).
    static func isRealWord(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        let range = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0)
        return range.location == NSNotFound
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Learned.self, from: data) else { return }
        learned = decoded
        // One-time migration: earlier builds stored real-word wrongs as hard
        // replacements ("lung"→"Airlearn"); demote them to context-gated soft
        // corrections so genuine uses of the word survive.
        let riskyKeys = learned.replacements.keys.filter { Self.isRealWord($0) }
        if !riskyKeys.isEmpty {
            for key in riskyKeys {
                learned.softReplacements[key] = learned.replacements.removeValue(forKey: key)
            }
            save()
        }
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

    /// True for a word that reads as a name/identifier ("Shubham", "Velora",
    /// "authCheck") rather than an ordinary word. CorrectionDiff only passes
    /// all-letter tokens, so in practice this means "has an uppercase letter".
    static func isNameLike(_ word: String) -> Bool {
        word.contains(where: { $0.isUppercase || $0.isNumber }) || word.contains("_")
    }

    /// True when `wrong` plausibly IS `right` misheard: the strings share most
    /// of their shape ("shubhi"→"Shivangi", "aircirclearn"→"Airlearn"). A pair
    /// like "vercel"→"Netlify" (distance ≈ length) is the user changing their
    /// MIND, not fixing recognition.
    static func likelyMishearing(_ wrong: String, _ right: String) -> Bool {
        let a = wrong.lowercased(), b = right.lowercased()
        let longest = max(a.count, b.count)
        // Tiny words: any 1-char difference is half the word — that's a
        // content swap ("js"→"TS"), not a mishearing. Only case/spelling
        // -identical pairs qualify (review finding).
        if longest <= 3 { return a == b }
        let bound = max(3, (longest * 2) / 3)
        return editDistance(a, b) <= bound
    }

    /// Plain Levenshtein — inputs are single short words.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(
                    prev[j] + 1,
                    cur[j - 1] + 1,
                    prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }

    /// Records observed corrections (wrong → right) and returns the pairs that
    /// were COMMITTED by this call (caller reloads the engine + shows the HUD
    /// toast). Name-like corrections commit on FIRST sighting — the edit came
    /// from text Velora just inserted, and a misheard name is exactly what the
    /// user wants fixed everywhere (Wispr parity) — but only when the pair is
    /// SAFE to commit instantly: context-gated (soft tier) or edit-distance
    /// close (a mishearing's shape). A far-distance pair headed for a
    /// deterministic rewrite ("vercel"→"Netlify") is a content edit, not a
    /// mishearing — it keeps the 2-sighting bar (review finding). Ordinary
    /// words always keep the 2-sighting bar; common homophones are refused
    /// outright; a committed rule is never flipped by a single conflicting
    /// one-off.
    @discardableResult
    func observe(_ corrections: [(wrong: String, right: String)]) -> [(wrong: String, right: String)] {
        load()  // pick up any external change (e.g. a Settings "Clear") first
        var committed: [(wrong: String, right: String)] = []
        for correction in corrections {
            let wrong = correction.wrong.lowercased()
            guard !Self.stopwords.contains(wrong) else { continue }
            if learned.replacements[wrong] == correction.right
                || learned.softReplacements[wrong] == correction.right { continue }  // already learned
            // Key the count by the exact PAIR so a conflicting right value can't
            // ride an earlier count over the threshold.
            let pairKey = "\(wrong)\u{2192}\(correction.right)"
            learned.counts[pairKey, default: 0] += 1
            let instantSafe = Self.isRealWord(wrong)  // soft tier: LLM-gated
                || Self.likelyMishearing(wrong, correction.right)
            let threshold = (Self.isNameLike(correction.right) && instantSafe)
                ? 1 : Self.confirmThreshold
            if (learned.counts[pairKey] ?? 0) >= threshold {
                // Real-word wrongs are context-gated (LLM hint), never a
                // deterministic global rewrite — "lung" must stay a lung in a
                // sentence about lungs. Either way the corrected term joins
                // the vocabulary, which biases whisper's RECOGNITION — the
                // primary learning channel.
                if Self.isRealWord(wrong) {
                    learned.softReplacements[wrong] = correction.right
                } else {
                    learned.replacements[wrong] = correction.right
                }
                if !learned.vocabulary.contains(correction.right) {
                    learned.vocabulary.append(correction.right)
                }
                committed.append((correction.wrong, correction.right))
            }
        }
        // A committed pair no longer needs its count; drop it so `counts` can't
        // grow one entry per unique typo forever.
        for correction in corrections {
            let wrong = correction.wrong.lowercased()
            if learned.replacements[wrong] == correction.right
                || learned.softReplacements[wrong] == correction.right {
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
    /// Cap on vocabulary terms NOT backed by a correction (imported lists).
    private static let maxStandaloneVocabulary = 300

    /// Bound the store deterministically: keep the alphabetically-first
    /// `maxReplacements` (stable, not the random dictionary order), trim vocab to
    /// match, and cap the pending-counts map.
    private func prune() {
        for keyPath in [\Learned.replacements, \Learned.softReplacements] {
            if learned[keyPath: keyPath].count > Self.maxReplacements {
                let overflow = learned[keyPath: keyPath].count - Self.maxReplacements
                for key in learned[keyPath: keyPath].keys.sorted().suffix(overflow) {
                    learned[keyPath: keyPath].removeValue(forKey: key)
                }
            }
        }
        // Vocabulary: terms backed by a live correction are always kept.
        // STANDALONE terms (hand-curated imports) are legitimate too — the
        // old unconditional filter silently deleted them right after import
        // (review finding) — but capped, evicting oldest-first.
        let kept = Set(learned.replacements.values).union(learned.softReplacements.values)
        var standalone = 0
        var survivors: [String] = []
        for term in learned.vocabulary.reversed() {  // newest first
            if kept.contains(term) {
                survivors.append(term)
            } else if standalone < Self.maxStandaloneVocabulary {
                standalone += 1
                survivors.append(term)
            }
        }
        learned.vocabulary = survivors.reversed()
        if learned.counts.count > Self.maxCounts {
            let overflow = learned.counts.count - Self.maxCounts
            for key in learned.counts.keys.sorted().suffix(overflow) {
                learned.counts.removeValue(forKey: key)
            }
        }
    }

    /// How many corrections are currently learned (for the Settings UI).
    var count: Int { learned.replacements.count + learned.softReplacements.count }

    /// One learned correction, for display/management in Settings.
    struct Entry: Identifiable, Equatable {
        var id: String { wrong }
        let wrong: String
        let right: String
    }

    /// Learned corrections (both tiers merged), alphabetized (reads fresh from
    /// disk each call so the Settings list reflects edits made by the running
    /// DictationController).
    func entries() -> [Entry] {
        load()
        return learned.replacements.merging(learned.softReplacements) { hard, _ in hard }
            .map { Entry(wrong: $0.key, right: $0.value) }
            .sorted { $0.wrong.localizedCaseInsensitiveCompare($1.wrong) == .orderedAscending }
    }

    /// Forgets a single learned correction (and any pending counts toward it).
    func remove(wrong: String) {
        load()
        let key = wrong.lowercased()
        let hard = learned.replacements.removeValue(forKey: key)
        let soft = learned.softReplacements.removeValue(forKey: key)
        guard let removedRight = hard ?? soft else { return }
        // Preserve vocabulary order; only drop the removed value if nothing else
        // maps to it.
        if !learned.replacements.values.contains(removedRight),
           !learned.softReplacements.values.contains(removedRight) {
            learned.vocabulary.removeAll { $0 == removedRight }
        }
        learned.counts = learned.counts.filter { !$0.key.hasPrefix("\(key)\u{2192}") }
        save()
    }

    func clear() {
        learned = Learned()
        save()
    }

    // MARK: - Import / export (portable personal dictionary)

    /// The raw dictionary file: both correction tiers + vocabulary.
    func exportData() -> Data? {
        load()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(learned)
    }

    /// Merges a previously exported dictionary (existing entries win; imported
    /// real-word wrongs are demoted to the context-gated soft tier no matter
    /// which tier they were exported from). Returns (corrections, vocabulary)
    /// counts actually added, or nil for an unreadable file.
    func importData(_ data: Data) -> (corrections: Int, vocabulary: Int)? {
        guard let incoming = try? JSONDecoder().decode(Learned.self, from: data) else { return nil }
        // The tolerant decoder accepts ANY JSON object; an empty result means
        // this wasn't a dictionary file — report that, not "imported 0".
        guard !incoming.replacements.isEmpty || !incoming.softReplacements.isEmpty
            || !incoming.vocabulary.isEmpty
        else { return nil }
        load()
        var corrections = 0
        let pairs = incoming.replacements.merging(incoming.softReplacements) { hard, _ in hard }
        for (wrong, right) in pairs {
            let key = wrong.lowercased()
            guard !key.isEmpty, !right.isEmpty,
                  learned.replacements[key] == nil, learned.softReplacements[key] == nil,
                  !Self.stopwords.contains(key)
            else { continue }
            if Self.isRealWord(key) {
                learned.softReplacements[key] = right
            } else {
                learned.replacements[key] = right
            }
            if !learned.vocabulary.contains(right) { learned.vocabulary.append(right) }
            corrections += 1
        }
        var vocabulary = 0
        for term in incoming.vocabulary
        where !term.isEmpty && !learned.vocabulary.contains(term) {
            learned.vocabulary.append(term)
            vocabulary += 1
        }
        prune()
        save()
        return (corrections, vocabulary)
    }
}
