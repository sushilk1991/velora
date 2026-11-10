import Foundation

/// Interface language is independent of speech recognition and model choice.
enum InterfaceLanguage: String, Codable, CaseIterable, Identifiable {
    case english = "en", spanish = "es"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Español"
        }
    }

    func resolvedIdentifier() -> String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "en", "system", "hi": self = .english
        case "es": self = .spanish
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Choose English or Spanish for the interface.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum SoundSet: String, Codable, CaseIterable, Identifiable {
    case classic, soft, chime
    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: return L10n.text("Classic")
        case .soft: return L10n.text("Soft")
        case .chime: return L10n.text("Chime")
        }
    }

    func assetName(for cue: String) -> String {
        self == .classic ? cue : "\(rawValue)-\(cue)"
    }
}
