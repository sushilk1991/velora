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
}
