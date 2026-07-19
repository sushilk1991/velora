import XCTest
@testable import Velora

final class RecognitionFinalizationPolicyTests: XCTestCase {
    func testWaitsDuringGracePeriodEvenWhenPartialIsStable() {
        XCTAssertEqual(
            RecognitionFinalizationPolicy.decision(
                transcript: "A stable partial",
                elapsed: 1,
                secondsSinceLastUpdate: 1
            ),
            .wait
        )
    }

    func testDeliversStablePartialAfterGracePeriod() {
        XCTAssertEqual(
            RecognitionFinalizationPolicy.decision(
                transcript: "A stable partial",
                elapsed: 3,
                secondsSinceLastUpdate: 1
            ),
            .deliverFallback
        )
    }

    func testWaitsForRecentlyChangingPartial() {
        XCTAssertEqual(
            RecognitionFinalizationPolicy.decision(
                transcript: "Still changing",
                elapsed: 3,
                secondsSinceLastUpdate: 0.2
            ),
            .wait
        )
    }

    func testTimeoutDeliversWordsOrFailsWhenEmpty() {
        XCTAssertEqual(
            RecognitionFinalizationPolicy.decision(
                transcript: "Last usable words",
                elapsed: 8,
                secondsSinceLastUpdate: 0
            ),
            .deliverFallback
        )
        XCTAssertEqual(
            RecognitionFinalizationPolicy.decision(
                transcript: "  ",
                elapsed: 8,
                secondsSinceLastUpdate: 8
            ),
            .fail
        )
    }
}
