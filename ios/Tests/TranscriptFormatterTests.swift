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

    func testStructuredNormalizationPreservesListsAndParagraphs() {
        XCTAssertEqual(
            TranscriptFormatter.normalizeStructured(
                "  First paragraph.  \n\n\n  1. First item  \n  2. Second item  "
            ),
            "First paragraph.\n\n1. First item\n2. Second item"
        )
    }

    func testDeterministicCleanupHandlesSafeSpeechArtifacts() {
        XCTAssertEqual(
            TranscriptFormatter.deterministicCleanup(
                "um hello there question mark new paragraph uh ship Friday full stop",
                for: .note
            ),
            "Hello there?\n\nShip Friday."
        )
        XCTAssertEqual(
            TranscriptFormatter.deterministicCleanup("Thanks for checking.", for: .message),
            "Thanks for checking"
        )
    }

    func testDeterministicCleanupProtectsNounsCodeRawAndNonLatinText() {
        XCTAssertEqual(
            TranscriptFormatter.deterministicCleanup("We came to a full stop.", for: .automatic),
            "We came to a full stop."
        )
        XCTAssertEqual(
            TranscriptFormatter.deterministicCleanup("git status.", for: .code),
            "git status"
        )
        XCTAssertEqual(
            TranscriptFormatter.deterministicCleanup("um keep this raw", for: .raw),
            "um keep this raw"
        )
        XCTAssertEqual(
            TranscriptFormatter.deterministicCleanup("नमस्ते दुनिया", for: .automatic),
            "नमस्ते दुनिया"
        )
    }

    func testDeterministicCleanupDoesNotDeleteGermanPrepositionUm() {
        XCTAssertEqual(
            TranscriptFormatter.deterministicCleanup(
                "ich komme um drei Uhr",
                for: .automatic,
                localeIdentifier: "de-DE"
            ),
            "Ich komme um drei Uhr"
        )
        XCTAssertEqual(
            TranscriptFormatter.deterministicCleanup(
                "um send the notes",
                for: .automatic,
                localeIdentifier: "en-US"
            ),
            "Send the notes"
        )
    }

    func testDictationStyleFallsBackToAutomatic() {
        XCTAssertEqual(DictationStyle.resolve(nil), .automatic)
        XCTAssertEqual(DictationStyle.resolve("unknown"), .automatic)
        XCTAssertEqual(DictationStyle.resolve("email"), .email)
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

    func testRecognitionLocaleRejectsSilentLanguageOrRegionFallback() {
        XCTAssertTrue(
            VeloraPreferences.recognitionLocale(
                Locale(identifier: "en-IN"),
                matches: "en-IN"
            )
        )
        XCTAssertFalse(
            VeloraPreferences.recognitionLocale(
                Locale(identifier: "en-US"),
                matches: "en-IN"
            )
        )
        XCTAssertFalse(
            VeloraPreferences.recognitionLocale(
                Locale(identifier: "en-IN"),
                matches: "hi-IN"
            )
        )
    }
}

@MainActor
final class TranscriptStoreTests: XCTestCase {
    func testHistoryPersistsNewestFiftyEntries() {
        let suiteName = "TranscriptStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated user defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = TranscriptStore(defaults: defaults)
        for index in 0..<55 {
            XCTAssertNotNil(store.add("Entry \(index)"))
        }

        XCTAssertEqual(store.entries.count, 50)
        XCTAssertEqual(store.entries.first?.text, "Entry 54")
        XCTAssertEqual(store.entries.last?.text, "Entry 5")

        let reloaded = TranscriptStore(defaults: defaults)
        XCTAssertEqual(reloaded.entries, store.entries)
    }

    func testCorruptHistoryStartsEmptyAndCanRecover() {
        let suiteName = "TranscriptStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated user defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not json".utf8), forKey: "velora.mobile.transcriptHistory")

        let store = TranscriptStore(defaults: defaults)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNotNil(store.add("Recovered"))
        XCTAssertEqual(TranscriptStore(defaults: defaults).entries.map(\.text), ["Recovered"])
    }

    func testDeleteAndClearAreDurable() {
        let suiteName = "TranscriptStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated user defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = TranscriptStore(defaults: defaults)
        let first = try! XCTUnwrap(store.add("First"))
        _ = store.add("Second")
        store.delete(first)
        XCTAssertEqual(TranscriptStore(defaults: defaults).entries.map(\.text), ["Second"])

        store.clear()
        XCTAssertTrue(TranscriptStore(defaults: defaults).entries.isEmpty)
    }
}
