import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalUnreachableBackoffTests: XCTestCase {
    func testDelaysFollowTheLadderInOrder() {
        var backoff = TerminalUnreachableBackoff()
        XCTAssertEqual(backoff.nextDelay(), 1)
        XCTAssertEqual(backoff.nextDelay(), 2)
        XCTAssertEqual(backoff.nextDelay(), 4)
        XCTAssertEqual(backoff.nextDelay(), 8)
        XCTAssertEqual(backoff.nextDelay(), 15)
    }

    func testDelayHoldsAtTheLastRungOnceReached() {
        var backoff = TerminalUnreachableBackoff()
        for _ in TerminalUnreachableBackoff.ladderSeconds {
            _ = backoff.nextDelay()
        }
        XCTAssertEqual(backoff.nextDelay(), 15)
        XCTAssertEqual(backoff.nextDelay(), 15)
    }

    func testResetReturnsToTheShortestDelay() {
        var backoff = TerminalUnreachableBackoff()
        _ = backoff.nextDelay()
        _ = backoff.nextDelay()
        backoff.reset()
        XCTAssertEqual(backoff.nextDelay(), 1)
    }
}
