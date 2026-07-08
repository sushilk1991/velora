import Foundation

/// Voice-native editing, v1: an utterance that IS one of a small set of exact
/// command phrases executes instead of pasting ("scratch that" → ⌘Z on the
/// last insertion, "new line" → Return). Deliberately conservative — only a
/// whole-utterance match can trigger, so command words inside real dictation
/// ("please press enter your password") are never intercepted.
enum VoiceCommand: Equatable {
    /// Undo the just-pasted dictation in the target app (one ⌘Z — a paste is
    /// a single undo group in every standard text view).
    case undoLastInsertion
    /// Press Return in the focused field.
    case pressReturn
    /// Blank line: two Returns.
    case newParagraph

    private static let undoPhrases: Set<String> = [
        "undo that", "undo this", "undo last",
        "scratch that", "delete that", "delete this",
    ]
    private static let returnPhrases: Set<String> = [
        "new line", "newline", "press enter", "press return",
    ]
    private static let paragraphPhrases: Set<String> = [
        "new paragraph", "next paragraph",
    ]

    /// Parses a final utterance into a command, or nil for ordinary dictation.
    /// Checks the cleaned text AND the raw transcript: cleanup may reword or
    /// even empty a bare retraction phrase ("scratch that" with nothing before
    /// it), and the command must still fire.
    static func parse(text: String, raw: String) -> VoiceCommand? {
        for candidate in [text, raw] {
            if let command = parseOne(candidate) { return command }
        }
        return nil
    }

    private static func parseOne(_ utterance: String) -> VoiceCommand? {
        let normalized = utterance
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
        guard !normalized.isEmpty, normalized.count <= 24 else { return nil }
        if undoPhrases.contains(normalized) { return .undoLastInsertion }
        if returnPhrases.contains(normalized) { return .pressReturn }
        if paragraphPhrases.contains(normalized) { return .newParagraph }
        return nil
    }
}
