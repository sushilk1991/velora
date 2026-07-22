import Foundation

enum DictationStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case message
    case email
    case note
    case code
    case raw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Auto"
        case .message: "Message"
        case .email: "Email"
        case .note: "Note"
        case .code: "Code"
        case .raw: "Raw"
        }
    }

    var systemImage: String {
        switch self {
        case .automatic: "wand.and.stars"
        case .message: "message.fill"
        case .email: "envelope.fill"
        case .note: "note.text"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .raw: "text.quote"
        }
    }

    var detail: String {
        switch self {
        case .automatic: "Clean prose and infer structure from what you say"
        case .message: "Brief and conversational"
        case .email: "Natural, professional paragraphs"
        case .note: "Headings and lists only when clearly useful"
        case .code: "Preserve commands, symbols, casing, and line breaks"
        case .raw: "Use Apple's transcript without smart cleanup"
        }
    }

    var refinementGuidance: String {
        switch self {
        case .automatic:
            "Use clean general-purpose prose. Infer paragraphs or lists only when the speaker clearly changes topic or enumerates items."
        case .message:
            "Format as a concise, conversational message. Do not add a greeting or sign-off. Do not make the tone formal."
        case .email:
            "Format as a professional but natural email. Use short paragraphs at real topic changes. Keep only greetings and sign-offs the speaker actually said."
        case .note:
            "Format as a useful note. Markdown is allowed. Use a list only when the speaker clearly enumerates multiple items; otherwise keep prose."
        case .code:
            "Preserve commands, identifiers, flags, paths, symbols, casing, and line breaks exactly."
        case .raw:
            "Do not rewrite the transcript."
        }
    }

    static func resolve(_ rawValue: String?) -> DictationStyle {
        guard let rawValue, let style = DictationStyle(rawValue: rawValue) else {
            return .automatic
        }
        return style
    }
}
