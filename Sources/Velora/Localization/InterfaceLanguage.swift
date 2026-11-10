import Foundation

/// Interface language is independent of speech recognition and model choice.
enum InterfaceLanguage: String, Codable, CaseIterable, Identifiable {
    case system, english = "en", hindi = "hi", spanish = "es"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L10n.text("System")
        case .english: return "English"
        case .hindi: return "हिन्दी"
        case .spanish: return "Español"
        }
    }

    func resolvedIdentifier(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        guard self == .system else { return rawValue }
        for language in preferredLanguages {
            let base = language.replacingOccurrences(of: "_", with: "-")
                .split(separator: "-").first.map(String.init)?.lowercased() ?? ""
            if ["en", "hi", "es"].contains(base) { return base }
        }
        return "en"
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
