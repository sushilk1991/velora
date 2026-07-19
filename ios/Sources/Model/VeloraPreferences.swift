import Foundation

enum VeloraPreferences {
    static let speechLocaleIdentifierKey = "velora.mobile.speechLocaleIdentifier"
    static let systemLocaleIdentifier = "system"

    static func resolvedSpeechLocaleIdentifier(
        storedIdentifier: String?,
        currentIdentifier: String = Locale.current.identifier
    ) -> String {
        guard let storedIdentifier,
              !storedIdentifier.isEmpty,
              storedIdentifier != systemLocaleIdentifier
        else {
            return currentIdentifier
        }
        return storedIdentifier
    }
}
