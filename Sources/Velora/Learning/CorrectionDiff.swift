import Foundation

/// Extracts likely dictation corrections by diffing what Velora inserted
/// (`baseline`) against what the field holds after the user edited it
/// (`edited`). Conservative on purpose — it only reports 1-for-1 word
/// substitutions that look like a spelling/homophone fix of a word Velora
/// produced, never unrelated edits or insertions/deletions.
enum CorrectionDiff {
    struct Correction: Equatable {
        let wrong: String
        let right: String
    }

    /// Returns the substitutions to learn. Empty when the edit isn't a clean
    /// word-for-word correction (added sentences, deletions, big rewrites).
    /// Hard cap: never diff more than this many tokens (backstop against a
    /// pathological field slipping past the caller's size guard).
    private static let maxTokens = 200

    /// A field bigger than this is never scanned (a real document; the window
    /// search would be meaningless and the diff misleading).
    private static let maxScanTokens = 400

    static func corrections(baseline: String, edited: String) -> [Correction] {
        let a = tokenize(baseline)
        var b = tokenize(edited)
        guard !a.isEmpty, !b.isEmpty, a.count <= maxTokens else { return [] }
        // The field may hold MORE than we inserted — a document accumulating
        // several dictations (TextEdit, Notes). Isolate the window that best
        // matches the inserted text and diff against that, instead of bailing.
        if b.count > a.count + max(2, a.count / 5) {
            guard let window = bestWindow(for: a, in: b) else { return [] }
            b = window
        }
        guard b.count <= maxTokens else { return [] }
        // Ignore edits that changed the length a lot — that's rewriting, not a
        // spelling fix, and word alignment gets unreliable.
        if abs(a.count - b.count) > max(2, a.count / 5) { return [] }

        let ops = diff(a, b)
        // Anchor: a genuine spelling fix leaves the sentence mostly intact.
        // Without this, diffing two UNRELATED texts (window match gone wrong,
        // or the user replaced the content wholesale) can cough up a spurious
        // 1:1 pair — and the name-fix rule would happily learn it.
        let keeps = ops.reduce(0) { count, op in
            if case .keep = op { return count + 1 }
            return count
        }
        guard keeps * 10 >= max(a.count, b.count) * 7 else { return [] }
        var result: [Correction] = []
        var i = 0
        while i < ops.count {
            // A substitution shows up as a delete immediately followed by an
            // insert of a single word each.
            if case .delete(let wrong) = ops[i], i + 1 < ops.count,
               case .insert(let right) = ops[i + 1] {
                if let pair = correctionPair(wrong: wrong, right: right) {
                    result.append(Correction(wrong: pair.wrong, right: pair.right))
                }
                i += 2
            } else {
                i += 1
            }
        }
        return result
    }

    // MARK: - Heuristics

    /// Returns the PUNCTUATION-TRIMMED (wrong, right) pair when the edit reads as
    /// a spelling/homophone correction (both alphabetic, meaningful length,
    /// close edit distance, actually different), else nil. Trimming here means
    /// the learned entry is "wrold"→"world", not "wrold,"→"world," — so it fixes
    /// the word regardless of trailing punctuation next time.
    private static func correctionPair(wrong: String, right: String) -> (wrong: String, right: String)? {
        let w = wrong.trimmingCharacters(in: .punctuationCharacters)
        let r = right.trimmingCharacters(in: .punctuationCharacters)
        guard w.count >= 3, r.count >= 2, w.lowercased() != r.lowercased() else { return nil }
        guard w.allSatisfy({ $0.isLetter }), r.allSatisfy({ $0.isLetter }) else { return nil }
        // A misheard NAME is usually a *different-sounding* word — "Shubhi" →
        // "Shivangi" is edit distance 5, and STT typically hears a name as a
        // lowercase common word ("airline" for "Airlearn") — so the
        // typo-shaped distance gate must not apply when the REPLACEMENT the
        // user deliberately typed reads as a name (capitalized). That typing
        // act is itself the correction signal; LearningStore's stopwords
        // still veto common capitalized words ("Hello", "Okay", …).
        let nameFix = r.first?.isUppercase == true
        if !nameFix {
            let distance = editDistance(w.lowercased(), r.lowercased())
            // Similar enough to be a correction of the same intended word (not
            // a wholly different word swapped in).
            guard distance <= max(1, min(w.count, r.count) / 2) else { return nil }
        }
        return (w, r)
    }

    private static func tokenize(_ text: String) -> [String] {
        text.split { $0 == " " || $0 == "\n" || $0 == "\t" }.map(String.init)
    }

    /// Finds the contiguous token window in `b` that best matches the inserted
    /// tokens `a` (±2 length slack), requiring ≥70% of `a`'s tokens present.
    /// Cheap (offsets a running score instead of rescoring each window) and
    /// bounded by `maxScanTokens`, and it runs off the main thread.
    private static func bestWindow(for a: [String], in b: [String]) -> [String]? {
        guard b.count <= maxScanTokens else { return nil }
        let aSet = Set(a.map { $0.lowercased() })
        let hits = b.map { aSet.contains($0.lowercased()) ? 1 : 0 }
        var best: (score: Int, range: Range<Int>)?
        for delta in -2...2 {
            let len = a.count + delta
            guard len >= 1, len <= b.count else { continue }
            var score = hits[0..<len].reduce(0, +)
            var start = 0
            while true {
                if best == nil || score > best!.score {
                    best = (score, start..<(start + len))
                }
                if start + len >= b.count { break }
                score += hits[start + len] - hits[start]
                start += 1
            }
        }
        guard let found = best, found.score * 10 >= a.count * 7 else { return nil }
        return Array(b[found.range])
    }

    // MARK: - Word-level diff (LCS backtrack)

    private enum Op {
        case keep(String)
        case delete(String)
        case insert(String)
    }

    private static func diff(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        // LCS length table on lowercased tokens.
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if a[i].lowercased() == b[j].lowercased() {
                    lcs[i][j] = lcs[i + 1][j + 1] + 1
                } else {
                    lcs[i][j] = max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i].lowercased() == b[j].lowercased() {
                ops.append(.keep(a[i])); i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                ops.append(.delete(a[i])); i += 1
            } else {
                ops.append(.insert(b[j])); j += 1
            }
        }
        while i < n { ops.append(.delete(a[i])); i += 1 }
        while j < m { ops.append(.insert(b[j])); j += 1 }
        return ops
    }

    /// Levenshtein distance (small strings, so the simple DP is fine).
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...max(1, x.count) where !x.isEmpty {
            cur[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return y.isEmpty ? x.count : prev[y.count]
    }
}
