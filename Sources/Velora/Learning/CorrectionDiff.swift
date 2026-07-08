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

    static func corrections(baseline: String, edited: String) -> [Correction] {
        let a = tokenize(baseline)
        let b = tokenize(edited)
        guard !a.isEmpty, !b.isEmpty, a.count <= maxTokens, b.count <= maxTokens else { return [] }
        // Ignore edits that changed the length a lot — that's rewriting, not a
        // spelling fix, and word alignment gets unreliable.
        if abs(a.count - b.count) > max(2, a.count / 5) { return [] }

        let ops = diff(a, b)
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
        // A misheard NAME is usually a *different-sounding* name — "Shubhi" →
        // "Shivangi" is edit distance 5 — so the typo-shaped distance gate
        // must not apply when both sides read as names (capitalized). The
        // deliberate act of replacing one capitalized word with another inside
        // text the user JUST dictated is itself the correction signal;
        // LearningStore's stopwords still veto common capitalized words.
        let bothNames = w.first?.isUppercase == true && r.first?.isUppercase == true
        if !bothNames {
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
