import Foundation

enum VeloraPreferences {
    static let speechLocaleIdentifierKey = "velora.mobile.speechLocaleIdentifier"
    static let dictationStyleKey = "velora.mobile.dictationStyle"
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

    /// `SFSpeechRecognizer(locale:)` may fall back to a keyboard dictation
    /// language. Reject that silent substitution so the UI never claims it is
    /// recognizing one language while actually running another.
    static func recognitionLocale(_ actual: Locale, matches requestedIdentifier: String) -> Bool {
        let requested = Locale(identifier: requestedIdentifier)
        guard actual.language.languageCode == requested.language.languageCode else {
            return false
        }
        if let requestedRegion = requested.region {
            return actual.region == requestedRegion
        }
        return true
    }
}
