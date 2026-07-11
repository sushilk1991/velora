import Foundation

/// A small, bounded fragment immediately around the current selection/caret.
struct TextSelectionBoundary: Equatable {
    /// Enough context to classify straight quotes without retaining/scanning a
    /// document. Accessibility callers fetch at most this many UTF-16 units on
    /// either side of the selection.
    static let contextLimit = 32

    let before: String
    let after: String

    var previous: Character? { before.last }
    var next: Character? { after.first }

    init(before: String, after: String) {
        self.before = String(before.suffix(Self.contextLimit))
        self.after = String(after.prefix(Self.contextLimit))
    }

    /// Accessibility selection ranges use UTF-16 offsets. Convert them without
    /// splitting composed characters such as emoji; malformed ranges are simply
    /// unavailable rather than risking a bad insertion.
    init?(text: String, utf16Range: NSRange) {
        let count = text.utf16.count
        guard utf16Range.location >= 0,
              utf16Range.length >= 0,
              utf16Range.location <= count,
              utf16Range.length <= count - utf16Range.location
        else { return nil }

        let utf16 = text.utf16
        guard let start16 = utf16.index(
                  utf16.startIndex, offsetBy: utf16Range.location, limitedBy: utf16.endIndex),
              let end16 = utf16.index(
                  start16, offsetBy: utf16Range.length, limitedBy: utf16.endIndex),
              let start = String.Index(start16, within: text),
              let end = String.Index(end16, within: text)
        else { return nil }

        self.init(before: String(text[..<start]), after: String(text[end...]))
    }
}

/// Adds only the separators required by the text surrounding the caret.
/// Generated/history text stays clean; this shapes the delivery payload only.
enum TextInsertionBoundary {
    private static let noSpaceAfter = Set<Character>(
        "([{“‘「『（【《〈〔〖〘〚/@#\\_$-–—")
    private static let noSpaceBefore = Set<Character>(
        ".,!?;:%)]}”’、。，！？；：％）】」』》〉〕〗〙〛/@#\\_$-–—")
    private static let openingContext = Set<Character>(
        "([{“‘「『（【《〈〔〖〘〚")
    private static let closingContext = Set<Character>(
        ".,!?;:%)]}”’、。，！？；：％）】」』》〉〕〗〙〛")
    private static let apostropheSuffixes: Set<String> = [
        "s", "t", "re", "ve", "ll", "d", "m",
    ]

    /// Compatibility helper for direct single-character callers and tests.
    static func adjusted(
        _ text: String, previous: Character?, next: Character?, mode: String? = nil
    ) -> String {
        adjusted(
            text,
            boundary: TextSelectionBoundary(
                before: previous.map(String.init) ?? "",
                after: next.map(String.init) ?? ""),
            mode: mode)
    }

    static func adjusted(
        _ text: String, boundary: TextSelectionBoundary?, mode: String?
    ) -> String {
        guard !text.isEmpty, let boundary else { return text }
        var result = text
        if needsLeadingSeparator(text: text, boundary: boundary, mode: mode) {
            result.insert(" ", at: result.startIndex)
        }
        if needsTrailingSeparator(text: text, boundary: boundary) {
            result.append(" ")
        }
        return result
    }

    private static func needsLeadingSeparator(
        text: String, boundary: TextSelectionBoundary, mode: String?
    ) -> Bool {
        guard let left = boundary.previous, let right = text.first else { return false }

        // `object.` + `member` in Code mode is a token continuation. Restrict
        // this to single tokens so ordinary multiword cleaned prose still
        // starts a new sentence correctly while `Type.Nested` remains valid.
        if left == ".", isCodeMode(mode), looksLikeCodeContinuation(text) {
            return false
        }

        if left == "\"" || left == "'" {
            if isOpeningQuoteAtEnd(boundary.before, quote: left) { return false }
            if left == "'", startsWithApostropheSuffix(text) { return false }
        }
        return needsGenericSeparator(between: left, and: right)
    }

    private static func needsTrailingSeparator(
        text: String, boundary: TextSelectionBoundary
    ) -> Bool {
        guard let left = text.last, let right = boundary.next else { return false }
        if right == "\"" || right == "'" {
            if isClosingQuoteAtStart(boundary.after, quote: right) { return false }
            if right == "'", (left.isLetter || left.isNumber),
               startsWithApostropheSuffix(String(boundary.after.dropFirst())) {
                return false
            }
        }
        return needsGenericSeparator(between: left, and: right)
    }

    private static func needsGenericSeparator(
        between left: Character, and right: Character
    ) -> Bool {
        guard !left.isWhitespace, !right.isWhitespace,
              !noSpaceAfter.contains(left),
              !noSpaceBefore.contains(right),
              !isEastAsianText(left), !isEastAsianText(right)
        else { return false }
        return true
    }

    private static func isCodeMode(_ mode: String?) -> Bool {
        guard let mode = mode?.lowercased() else { return false }
        return mode == "code" || mode == "terminal"
    }

    private static func looksLikeCodeContinuation(_ text: String) -> Bool {
        guard !text.contains(where: \Character.isWhitespace),
              let first = text.first
        else { return false }
        return first.isLetter || first.isNumber || "_$([{".contains(first)
    }

    private static func isOpeningQuoteAtEnd(_ before: String, quote: Character) -> Bool {
        guard before.last == quote else { return false }
        let prior = before.dropLast().last
        return prior == nil || prior!.isWhitespace || openingContext.contains(prior!)
    }

    private static func isClosingQuoteAtStart(_ after: String, quote: Character) -> Bool {
        guard after.first == quote else { return false }
        let following = after.dropFirst().first
        return following == nil || following!.isWhitespace || closingContext.contains(following!)
    }

    private static func startsWithApostropheSuffix(_ text: String) -> Bool {
        let suffix = String(text.prefix { $0.isLetter }).lowercased()
        return apostropheSuffixes.contains(suffix)
    }

    private static func isEastAsianText(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x2E80...0x2FFF,  // CJK radicals and punctuation-adjacent blocks
                 0x3040...0x30FF,  // Hiragana and Katakana
                 0x3100...0x31FF,  // Bopomofo and Katakana extensions
                 0x3400...0x4DBF,  // CJK Extension A
                 0x4E00...0x9FFF,  // CJK Unified Ideographs
                 0xF900...0xFAFF:  // CJK Compatibility Ideographs
                return true
            default:
                return false
            }
        }
    }
}
