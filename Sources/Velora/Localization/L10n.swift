import Foundation

/// Uses public bundle APIs. The source checkout fallback keeps bare SwiftPM
/// runs equivalent to a packaged app without changing Bundle.main's language.
enum L10n {
    private static let languageLock = NSLock()
    private static var selectedLanguage: InterfaceLanguage = .system

    /// Keep text lookup independent of AppConfig's locks and initialization:
    /// even a settings-load error can safely ask for its localized message.
    static func setLanguage(_ language: InterfaceLanguage) {
        languageLock.lock()
        selectedLanguage = language
        languageLock.unlock()
    }

    private static var currentLanguage: InterfaceLanguage {
        languageLock.lock()
        defer { languageLock.unlock() }
        return selectedLanguage
    }

    private static let bundles: [String: Bundle] = {
        let roots = [Bundle.main.resourceURL,
                     ResourceLocator.repoRoot?.appendingPathComponent("Resources")].compactMap { $0 }
        var result: [String: Bundle] = [:]
        for language in ["en", "hi", "es"] {
            for root in roots {
                if let bundle = Bundle(path: root.appendingPathComponent("\(language).lproj").path) {
                    result[language] = bundle
                    break
                }
            }
        }
        return result
    }()

    static func text(_ key: String, language: InterfaceLanguage? = nil) -> String {
        let identifier = (language ?? currentLanguage).resolvedIdentifier()
        let fallback = bundles["en"]?.localizedString(forKey: key, value: key, table: nil) ?? key
        return bundles[identifier]?.localizedString(forKey: key, value: fallback, table: nil) ?? fallback
    }

    /// Catalog formats use %@ placeholders only. Arguments remain text, so
    /// numbers, paths and errors cannot become format directives.
    static func format(_ key: String, _ arguments: String...) -> String {
        formatted(key, arguments: arguments)
    }

    static func formatted(_ key: String, arguments: [String], language: InterfaceLanguage? = nil) -> String {
        let translated = text(key, language: language)
        guard translated.components(separatedBy: "%@").count == arguments.count + 1,
              !translated.replacingOccurrences(of: "%@", with: "").contains("%") else {
            return interpolate(key, arguments)
        }
        return interpolate(translated, arguments)
    }

    private static func interpolate(_ format: String, _ arguments: [String]) -> String {
        let parts = format.components(separatedBy: "%@")
        guard parts.count == arguments.count + 1 else { return format }
        return zip(arguments, parts.dropFirst()).reduce(parts[0]) { $0 + $1.0 + $1.1 }
    }
}
