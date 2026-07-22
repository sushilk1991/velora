import Foundation

struct TranscriptEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let text: String
    let createdAt: Date

    init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

enum TranscriptFormatter {
    /// Speech results occasionally contain leading or repeated whitespace.
    /// Clipboard output should be immediately usable in any text field.
    static func normalize(_ rawValue: String) -> String {
        rawValue
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Smart cleanup may intentionally return paragraphs or list items. Keep
    /// those line breaks while still removing speech-model spacing noise.
    static func normalizeStructured(_ rawValue: String) -> String {
        let canonical = rawValue
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = canonical.components(separatedBy: "\n").map { line in
            line
                .split(whereSeparator: \Character.isWhitespace)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
        }

        var normalized: [String] = []
        for line in lines {
            if line.isEmpty, normalized.last?.isEmpty == true {
                continue
            }
            normalized.append(line)
        }

        while normalized.first?.isEmpty == true { normalized.removeFirst() }
        while normalized.last?.isEmpty == true { normalized.removeLast() }
        return normalized.joined(separator: "\n")
    }

    /// Fast, model-free cleanup shared by every supported iPhone. It handles
    /// the unambiguous speech artifacts that do not require semantic judgment;
    /// the on-device language model may refine the result further afterward.
    static func deterministicCleanup(
        _ rawValue: String,
        for style: DictationStyle,
        localeIdentifier: String = "en-US"
    ) -> String {
        var text = normalizeStructured(rawValue)
        guard !text.isEmpty else { return "" }
        guard style != .raw else { return text }

        text = applySpokenBreaks(text)
        if style == .code {
            return stripSingleTrailingPeriod(normalizeStructured(text))
        }

        text = scrubStandaloneFillers(text, localeIdentifier: localeIdentifier)
        if !isMostlyNonLatin(text) {
            text = normalizeSpokenPunctuation(text)
            text = capitalizeFirstLetter(text)
        }
        text = normalizeStructured(text)

        if style == .message {
            text = stripShortMessagePeriod(text)
        }
        return text
    }

    static func isMostlyNonLatin(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter(CharacterSet.letters.contains)
        guard !letters.isEmpty else { return false }
        let nonLatin = letters.filter { $0.value > 0x024F }.count
        return Double(nonLatin) / Double(letters.count) > 0.5
    }

    private static func applySpokenBreaks(_ text: String) -> String {
        replacingMatches(
            pattern: #"(?i)\s*[,.;:!?]?\s*\bnew\s*(line|paragraph)\b[,.;:!?]?\s*"#,
            in: text
        ) { match, source in
            guard let kindRange = Range(match.range(at: 1), in: source) else { return " " }
            return source[kindRange].lowercased() == "paragraph" ? "\n\n" : "\n"
        }
    }

    private static func scrubStandaloneFillers(
        _ text: String,
        localeIdentifier: String
    ) -> String {
        // These tokens are English speech artifacts, but some are real words
        // elsewhere (for example German and Portuguese "um"). Never delete
        // them from a language Velora explicitly supports.
        guard Locale(identifier: localeIdentifier).language.languageCode?.identifier == "en" else {
            return text
        }
        let scrubbed = replacingMatches(
            pattern: #"(?i)(?<!\w)(?:u+m+|u+h+|uhm+|erm+)(?!\w),?\s*"#,
            in: text
        ) { _, _ in "" }
        return scrubbed
            .replacingOccurrences(of: #"\s+([.!?,;:])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"^[.!?,;:]+\s*"#, with: "", options: .regularExpression)
    }

    private static func normalizeSpokenPunctuation(_ text: String) -> String {
        let determiners = Set(
            "a an the this that these those my your his her its our their no some any each every another either neither both several many few one two three four five six seven eight nine ten"
                .split(separator: " ").map(String.init)
        )
        let symbols = [
            "full stop": ".",
            "question mark": "?",
            "exclamation mark": "!",
            "exclamation point": "!",
            "open paren": " (",
            "open parenthesis": " (",
            "close paren": ")",
            "close parenthesis": ")",
        ]
        var output = replacingMatches(
            pattern: #"(?i)\b(full stop|question mark|exclamation (?:mark|point)|(?:open|close) paren(?:thesis)?)\b"#,
            in: text
        ) { match, source in
            guard let phraseRange = Range(match.range(at: 1), in: source),
                  let fullRange = Range(match.range, in: source)
            else { return "" }
            let precedingWords = source[..<fullRange.lowerBound]
                .split { !$0.isLetter }
                .suffix(3)
                .map { $0.lowercased() }
            if precedingWords.contains(where: determiners.contains) {
                return String(source[fullRange])
            }
            return symbols[source[phraseRange].lowercased()] ?? String(source[fullRange])
        }
        output = output
            .replacingOccurrences(of: #"\s+([.!?,;:)])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\(\s+"#, with: "(", options: .regularExpression)
            .replacingOccurrences(of: #"([.!?])[.!?,]+"#, with: "$1", options: .regularExpression)
        return output
    }

    private static func capitalizeFirstLetter(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            guard let index = line.firstIndex(where: { $0.isLetter }), line[index].isLowercase else {
                return line
            }
            var output = line
            output.replaceSubrange(index...index, with: String(line[index]).uppercased())
            return output
        }.joined(separator: "\n")
    }

    private static func stripShortMessagePeriod(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("."), !trimmed.hasSuffix(".."),
              !trimmed.contains("\n"), trimmed.split(whereSeparator: \Character.isWhitespace).count <= 15
        else { return text }
        let withoutLast = trimmed.dropLast()
        guard withoutLast.range(of: #"[.!?…]\s+\S"#, options: .regularExpression) == nil else {
            return text
        }
        return String(withoutLast)
    }

    private static func stripSingleTrailingPeriod(_ text: String) -> String {
        guard text.hasSuffix("."), !text.hasSuffix("..") else { return text }
        return String(text.dropLast())
    }

    private static func replacingMatches(
        pattern: String,
        in source: String,
        replacement: (NSTextCheckingResult, String) -> String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return source }
        let matches = expression.matches(
            in: source,
            range: NSRange(source.startIndex..<source.endIndex, in: source)
        )
        var output = source
        for match in matches.reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            output.replaceSubrange(range, with: replacement(match, source))
        }
        return output
    }
}
