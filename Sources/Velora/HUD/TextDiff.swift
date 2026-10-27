import Foundation

/// Word-level difference between a selection and its Proofread result,
/// shaped for the HUD: what was struck out, what was put in.
///
///   "Their going too the store."  →  "They're going to the store."
///   [-Their][+They're][ going ][-too][+to][ the store.]
struct TextDiff: Equatable {
    enum Kind: Equatable {
        case same
        case removed
        case added
    }

    struct Segment: Equatable {
        let kind: Kind
        let text: String
    }

    /// Every character of both texts, in order: `same` + `removed` spell the
    /// original, `same` + `added` the result.
    let segments: [Segment]

    static func words(from old: String, to new: String) -> TextDiff {
        let oldTokens = tokens(old)
        let newTokens = tokens(new)

        // Myers diff from the standard library; offsets index the token
        // arrays above.
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in newTokens.difference(from: oldTokens) {
            switch change {
            case .remove(let offset, _, _):
                removed.insert(offset)
            case .insert(let offset, _, _):
                inserted.insert(offset)
            }
        }

        // Walk both sides in step. At a change point removals come first, so
        // a wrong word always sits right before its fix.
        var segments: [Segment] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldTokens.count || newIndex < newTokens.count {
            if oldIndex < oldTokens.count, removed.contains(oldIndex) {
                append(.removed, oldTokens[oldIndex], to: &segments)
                oldIndex += 1
                continue
            }
            if newIndex < newTokens.count, inserted.contains(newIndex) {
                append(.added, newTokens[newIndex], to: &segments)
                newIndex += 1
                continue
            }
            append(.same, oldTokens[oldIndex], to: &segments)
            oldIndex += 1
            newIndex += 1
        }
        return TextDiff(segments: segments)
    }

    /// Changed spots: a struck word with its fix counts once, as does a lone
    /// insertion or removal.
    var changeCount: Int {
        var count = 0
        var previous: Kind = .same
        for segment in segments {
            if segment.kind == .removed || (segment.kind == .added && previous != .removed) {
                count += 1
            }
            previous = segment.kind
        }
        return count
    }

    /// The HUD's display form. Whitespace runs, line breaks included, become
    /// one space, and an unchanged stretch keeps at most `context` words next
    /// to each change, the rest shown as "…". Empty when nothing changed.
    ///
    ///   "… five six seven [-teh][+the] end"
    func excerpt(context: Int = 4) -> [Segment] {
        guard changeCount > 0 else { return [] }

        let lastIndex = segments.count - 1
        return segments.enumerated().map { index, segment in
            let text = Self.collapsingWhitespace(segment.text)
            guard segment.kind == .same else {
                return Segment(kind: segment.kind, text: text)
            }
            return Segment(
                kind: .same,
                text: Self.shortened(
                    text,
                    keepsHead: index > 0,
                    keepsTail: index < lastIndex,
                    context: context))
        }
    }

    /// The excerpt as drawn: a space between a struck word and its fix,
    /// which sit flush in the text itself.
    static func displayRuns(_ segments: [Segment]) -> [Segment] {
        var runs: [Segment] = []
        for segment in segments {
            if segment.kind == .added, runs.last?.kind == .removed {
                runs.append(Segment(kind: .same, text: " "))
            }
            runs.append(segment)
        }
        return runs
    }

    // MARK: - Tokens

    /// Words (letters, digits, apostrophes), whitespace runs, and single
    /// punctuation marks. Apostrophes stay inside words so "its" → "it's"
    /// reads as one replaced word.
    private static func tokens(_ text: String) -> [String] {
        enum Class {
            case word
            case space
            case mark
        }

        func classify(_ character: Character) -> Class {
            if character.isWhitespace {
                return .space
            }
            if character.isLetter || character.isNumber || character == "'" || character == "’" {
                return .word
            }
            return .mark
        }

        var tokens: [String] = []
        var current = ""
        var currentClass: Class?
        for character in text {
            let characterClass = classify(character)
            if characterClass == currentClass, characterClass != .mark {
                current.append(character)
                continue
            }
            if !current.isEmpty {
                tokens.append(current)
            }
            current = String(character)
            currentClass = characterClass
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func append(_ kind: Kind, _ token: String, to segments: inout [Segment]) {
        if let last = segments.last, last.kind == kind {
            segments[segments.count - 1] = Segment(kind: kind, text: last.text + token)
            return
        }
        segments.append(Segment(kind: kind, text: token))
    }

    // MARK: - Excerpt

    private static func collapsingWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// Shortens one unchanged stretch. `keepsHead` keeps the words right
    /// after the previous change, `keepsTail` those right before the next.
    ///
    ///   head and tail:  " a b c d e f "  →  " a b … e f "
    ///   tail only:      "one two three " →  "… two three "
    ///   head only:      " plan is set"   →  " plan is …"
    private static func shortened(
        _ text: String, keepsHead: Bool, keepsTail: Bool, context: Int
    ) -> String {
        let words = text.split(separator: " ").map(String.init)
        let keep = (keepsHead ? context : 0) + (keepsTail ? context : 0)
        guard words.count > keep else { return text }

        let lead = text.hasPrefix(" ") ? " " : ""
        let trail = text.hasSuffix(" ") ? " " : ""
        let head = keepsHead ? words.prefix(context).joined(separator: " ") : ""
        let tail = keepsTail ? words.suffix(context).joined(separator: " ") : ""
        switch (keepsHead, keepsTail) {
        case (true, true):
            return lead + head + " … " + tail + trail
        case (false, true):
            return "… " + tail + trail
        case (true, false):
            return lead + head + " …"
        case (false, false):
            return "…"
        }
    }
}
