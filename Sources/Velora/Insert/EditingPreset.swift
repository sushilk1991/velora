import Foundation

enum EditingPreset: String, CaseIterable, Identifiable {
    case shorter, clearer, formal, bullets, english, hindi, spanish
    var id: Self { self }
    var title: String {
        switch self {
        case .shorter: return "Make shorter"
        case .clearer: return "Make clearer"
        case .formal: return "Make formal"
        case .bullets: return "Turn into bullets"
        case .english: return "Translate to English"
        case .hindi: return "Translate to Hindi"
        case .spanish: return "Translate to Spanish"
        }
    }
    var instruction: String {
        let operation: String
        switch self {
        case .shorter: operation = "Shorten this text without dropping its facts."
        case .clearer: operation = "Make this text easier to understand."
        case .formal: operation = "Use a professional, formal tone."
        case .bullets: operation = "Organize the existing points into a concise bullet list."
        case .english: operation = "Translate this text into English."
        case .hindi: operation = "Translate this text into Hindi using Devanagari script."
        case .spanish: operation = "Translate this text into Spanish."
        }
        return operation + " Preserve meaning, negation, names, numbers, dates, URLs, and code. Do not add facts, owners, deadlines, or answers. Output only the transformed text."
    }
}
