import Carbon.HIToolbox
import Foundation

struct KeyboardSpeechRoute: Codable, Equatable {
    var language: String
    var model: String
}

enum CleanupMemoryPolicy: String, Codable, CaseIterable, Identifiable {
    case automatic
    case keepReady = "keep_ready"
    case saveMemory = "save_memory"
    var id: Self { self }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .keepReady: return "Keep ready"
        case .saveMemory: return "Save memory"
        }
    }
}

/// Read once when an ordinary take starts; changing keyboards affects the next take.
enum KeyboardLanguageRouting {
    struct InputSource: Equatable {
        let id: String
        let name: String
        let language: String
    }

    static let languages: [(String, String)] = [
        ("auto", "Auto-detect"), ("en", "English"), ("hi", "Hindi"),
        ("es", "Spanish"), ("zh", "Mandarin Chinese"), ("ar", "Arabic"),
        ("fr", "French"), ("pt", "Portuguese"), ("de", "German"),
        ("it", "Italian"), ("ja", "Japanese"), ("uk", "Ukrainian"),
        ("ru", "Russian"), ("ko", "Korean"),
    ]

    static func currentInputSource() -> InputSource? {
        if !Thread.isMainThread { return DispatchQueue.main.sync { currentInputSource() } }
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let rawID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        let id = Unmanaged<CFString>.fromOpaque(rawID).takeUnretainedValue() as String
        let name = TISGetInputSourceProperty(source, kTISPropertyLocalizedName).map {
            Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
        } ?? id
        let language: String
        if let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
           let values = Unmanaged<CFArray>.fromOpaque(raw).takeUnretainedValue() as? [String],
           let first = values.first {
            language = first.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? "auto"
        } else { language = "auto" }
        return InputSource(id: id, name: name, language: language)
    }

    static func context(config: AppConfig = .shared) -> [String: String]? {
        context(enabled: config.followKeyboardLanguage, routes: config.keyboardSpeechRoutes,
                source: currentInputSource())
    }

    static func context(enabled: Bool, routes: [String: KeyboardSpeechRoute], source: InputSource?) -> [String: String]? {
        guard enabled, let source, let route = routes[source.id] else { return nil }
        return ["input_source": source.id, "language": route.language, "model": route.model]
    }

    static func valid(_ routes: [String: KeyboardSpeechRoute]) -> Bool {
        routes.count <= 128 && routes.allSatisfy { source, route in
            !source.isEmpty && source.unicodeScalars.count <= 512
                && !source.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                && !route.model.isEmpty && route.model.unicodeScalars.count <= 512
                && !route.model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                && !route.language.isEmpty && route.language.utf8.count <= 32
                && route.language.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
        }
    }
}
