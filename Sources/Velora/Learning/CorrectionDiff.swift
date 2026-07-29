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
    static let maxTokens = 500
    private static let maxTokenCharacters = DictionaryValue.maximumLength
    private static let maxInputCharacters = maxTokens * (maxTokenCharacters + 1)

    private struct Token {
        let raw: String
        let normalized: String
    }

    static func corrections(baseline: String, edited: String) -> [Correction] {
        guard let a = tokenize(baseline), var b = tokenize(edited),
              !a.isEmpty, !b.isEmpty else { return [] }
        // The field may hold MORE than we inserted — a document accumulating
        // several dictations (TextEdit, Notes). Isolate the window that best
        // matches the inserted text and diff against that, instead of bailing.
        if b.count > a.count + max(2, a.count / 5) {
            guard let window = bestWindow(for: a, in: b) else { return [] }
            b = window
        }
        // Ignore edits that changed the length a lot — that's rewriting, not a
        // spelling fix, and word alignment gets unreliable.
        if abs(a.count - b.count) > max(2, a.count / 5) { return [] }

        if a.count <= 3 {
            return shortCorrection(baseline: a, edited: b)
        }
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
    private static func correctionPair(
        wrong: String,
        right: String,
        allowDistantNameFix: Bool = true
    ) -> (wrong: String, right: String)? {
        let w = trimmedToken(wrong)
        let r = trimmedToken(right)
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
        if nameFix && !allowDistantNameFix {
            guard LearningStore.likelyMishearing(w, r) else { return nil }
        } else if !nameFix {
            let distance = editDistance(w.lowercased(), r.lowercased())
            // Similar enough to be a correction of the same intended word (not
            // a wholly different word swapped in).
            guard distance <= max(1, min(w.count, r.count) / 2) else { return nil }
        }
        return (w, r)
    }

    static func normalizedToken(_ token: String) -> String? {
        let normalized = trimmedToken(token)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        return normalized.isEmpty ? nil : normalized
    }

    static func normalizedTokens(_ text: String) -> [String]? {
        tokenize(text)?.map(\.normalized)
    }

    private static func trimmedToken(_ token: String) -> String {
        token.trimmingCharacters(in: .punctuationCharacters)
    }

    /// Tokenizes at most `maxTokens` normalized words, with the same 60-character
    /// per-token bound as the Personal Dictionary and a derived whole-input cap.
    /// These rails bound punctuation-only and single-token AX values too.
    private static func tokenize(_ text: String) -> [Token]? {
        var result: [Token] = []
        result.reserveCapacity(min(64, maxTokens))
        var start: String.Index?
        var scannedCharacters = 0
        var tokenCharacters = 0

        func appendToken(endingAt end: String.Index) -> Bool {
            guard let tokenStart = start else { return true }
            let raw = String(text[tokenStart..<end])
            guard let normalized = normalizedToken(raw) else { return true }
            result.append(Token(raw: raw, normalized: normalized))
            return result.count <= maxTokens
        }

        var index = text.startIndex
        while index < text.endIndex {
            scannedCharacters += 1
            guard scannedCharacters <= maxInputCharacters else { return nil }
            if text[index].isWhitespace {
                guard appendToken(endingAt: index) else { return nil }
                start = nil
                tokenCharacters = 0
            } else if start == nil {
                start = index
                tokenCharacters = 1
            } else {
                tokenCharacters += 1
            }
            guard tokenCharacters <= maxTokenCharacters else { return nil }
            index = text.index(after: index)
        }
        guard appendToken(endingAt: text.endIndex) else { return nil }
        return result
    }

    /// Finds the contiguous token window in `b` that best matches the inserted
    /// tokens `a` (±2 length slack), requiring ≥70% of `a`'s tokens present.
    /// Cheap (offsets a running score instead of rescoring each window) and
    /// bounded by `maxTokens`, and it runs off the main thread.
    private static func bestWindow(for a: [Token], in b: [Token]) -> [Token]? {
        let aSet = Set(a.map(\.normalized))
        let hits = b.map { aSet.contains($0.normalized) ? 1 : 0 }
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

    private static func shortCorrection(
        baseline: [Token], edited: [Token]
    ) -> [Correction] {
        guard baseline.count == edited.count else { return [] }
        var result: Correction?
        for (before, after) in zip(baseline, edited)
            where before.normalized != after.normalized {
            guard result == nil,
                  let pair = correctionPair(
                    wrong: before.raw,
                    right: after.raw,
                    // A one-word field is itself a strong correction signal.
                    // With surrounding words, require the name replacement to
                    // retain a plausible speech/misspelling shape.
                    allowDistantNameFix: baseline.count == 1)
            else { return [] }
            result = Correction(wrong: pair.wrong, right: pair.right)
        }
        return result.map { [$0] } ?? []
    }

    private static func diff(_ a: [Token], _ b: [Token]) -> [Op] {
        let n = a.count, m = b.count
        // LCS length table on punctuation-trimmed lowercase tokens.
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if a[i].normalized == b[j].normalized {
                    lcs[i][j] = lcs[i + 1][j + 1] + 1
                } else {
                    lcs[i][j] = max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i].normalized == b[j].normalized {
                ops.append(.keep(a[i].raw)); i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                ops.append(.delete(a[i].raw)); i += 1
            } else {
                ops.append(.insert(b[j].raw)); j += 1
            }
        }
        while i < n { ops.append(.delete(a[i].raw)); i += 1 }
        while j < m { ops.append(.insert(b[j].raw)); j += 1 }
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
