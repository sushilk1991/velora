import XCTest
@testable import Velora

final class TranscriptFormatterTests: XCTestCase {
    func testNormalizeTrimsAndCollapsesWhitespace() {
        XCTAssertEqual(
            TranscriptFormatter.normalize("  hello   from\n Velora  "),
            "hello from Velora"
        )
    }

    func testNormalizeLeavesWordsAndPunctuationUntouched() {
        XCTAssertEqual(
            TranscriptFormatter.normalize("Ship it—today, please."),
            "Ship it—today, please."
        )
    }

    func testNormalizeRejectsWhitespaceOnlyInput() {
        XCTAssertTrue(TranscriptFormatter.normalize(" \n\t ").isEmpty)
    }

    func testSystemLanguageSentinelResolvesWithoutDuplicatingAConcreteLocale() {
        XCTAssertEqual(
            VeloraPreferences.resolvedSpeechLocaleIdentifier(
                storedIdentifier: VeloraPreferences.systemLocaleIdentifier,
                currentIdentifier: "en-IN"
            ),
            "en-IN"
        )
        XCTAssertEqual(
            VeloraPreferences.resolvedSpeechLocaleIdentifier(
                storedIdentifier: "hi-IN",
                currentIdentifier: "en-IN"
            ),
            "hi-IN"
        )
    }
}
