import XCTest
@testable import Velora

@MainActor
final class TranscriptDeliveryTests: XCTestCase {
    func testDeliverCopiesTheSameNormalizedTextSavedToHistory() {
        let suiteName = "TranscriptDeliveryTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated user defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let clipboard = ClipboardSpy()
        let store = TranscriptStore(defaults: defaults)

        let delivered = TranscriptDelivery.deliver(
            "  Send   Maya the notes. ",
            to: clipboard,
            store: store
        )

        XCTAssertEqual(delivered, "Send Maya the notes.")
        XCTAssertEqual(clipboard.value, "Send Maya the notes.")
        XCTAssertEqual(store.entries.map(\.text), ["Send Maya the notes."])
    }

    func testDeliverDoesNotTouchClipboardOrHistoryForEmptyText() {
        let suiteName = "TranscriptDeliveryTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated user defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let clipboard = ClipboardSpy()
        let store = TranscriptStore(defaults: defaults)

        XCTAssertNil(TranscriptDelivery.deliver(" \n ", to: clipboard, store: store))
        XCTAssertNil(clipboard.value)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testAppShortcutHandoffIsConsumedExactlyOnce() {
        let suiteName = "TranscriptDeliveryTests.Router.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated user defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let router = CaptureLaunchRouter(defaults: defaults)

        router.requestCapture()

        XCTAssertTrue(router.consumePendingCapture())
        XCTAssertFalse(router.consumePendingCapture())
    }

    func testAppShortcutHandoffSurvivesColdLaunch() {
        let suiteName = "TranscriptDeliveryTests.ColdLaunch.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated user defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        CaptureLaunchRouter(defaults: defaults).requestCapture()
        let relaunched = CaptureLaunchRouter(defaults: defaults)

        XCTAssertTrue(relaunched.consumePendingCapture())
        XCTAssertFalse(relaunched.consumePendingCapture())
    }
}

@MainActor
private final class ClipboardSpy: ClipboardWriting {
    private(set) var value: String?

    func write(_ text: String) {
        value = text
    }
}
