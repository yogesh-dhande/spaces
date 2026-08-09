import XCTest

@testable import spacesterminalcore

/// The rule both clients retire an armed resync retry by. A frame closes the retry only when it proves
/// the failure that armed it was answered; anything looser cancels a request for a gap the frame does
/// not cover, and anything stricter costs reads the session did not need.
final class TerminalResyncOwedOrderingTests: XCTestCase {
    func testOnlyAFrameAtOrPastTheFailedTargetClosesTheRequest() {
        let owed = TerminalResyncOwedOrdering.throughFrame(ownerEpoch: 3, sessionRevision: 42)

        XCTAssertFalse(owed.isSatisfied(byFrameOwnerEpoch: 3, sessionRevision: 41), "the frame the failure raced does not cover it")
        XCTAssertTrue(owed.isSatisfied(byFrameOwnerEpoch: 3, sessionRevision: 42), "the target itself is what the resync asked for")
        XCTAssertTrue(owed.isSatisfied(byFrameOwnerEpoch: 3, sessionRevision: 99))
        // Epochs only advance, so any frame from a later session generation is past the failure whatever
        // revision it carries; a frame from an earlier one is behind it whatever revision it carries.
        XCTAssertTrue(owed.isSatisfied(byFrameOwnerEpoch: 4, sessionRevision: 1))
        XCTAssertFalse(owed.isSatisfied(byFrameOwnerEpoch: 2, sessionRevision: 500))
        // An unrevisioned frame cannot be ordered against a known target, so it proves nothing.
        XCTAssertFalse(owed.isSatisfied(byFrameOwnerEpoch: 3, sessionRevision: nil))
    }

    func testAFailureWithNoReadableTargetIsClosedOnlyByTheRetryItself() {
        let decodeFailure = TerminalResyncOwedOrdering.forFailedUpdate(nil)

        XCTAssertEqual(decodeFailure, .unknown)
        XCTAssertFalse(decodeFailure.isSatisfied(byFrameOwnerEpoch: 9, sessionRevision: 999))
        // An attach that found no frame names no failure, so any frame at all repairs what it asked for.
        XCTAssertTrue(TerminalResyncOwedOrdering.anyFrame.isSatisfied(byFrameOwnerEpoch: 0, sessionRevision: nil))
    }

    func testAFailedDeltaOwesItsOwnTarget() {
        let delta = GhosttyRenderDeltaFrame(
            baseRevision: 41, targetRevision: 42, ownerEpoch: 3, columns: 4, rows: 1, cursorColumn: 0, cursorRow: 0, cursorVisible: false,
            defaultForegroundRGB: 0xFFFFFF, defaultBackgroundRGB: 0, changedCellCount: 0)

        XCTAssertEqual(TerminalResyncOwedOrdering.forFailedUpdate(.delta(delta)), .throughFrame(ownerEpoch: 3, sessionRevision: 42))
    }

    func testASecondFailureRaisesTheDebtToWhicheverIsLater() {
        let first = TerminalResyncOwedOrdering.throughFrame(ownerEpoch: 3, sessionRevision: 42)
        let later = TerminalResyncOwedOrdering.throughFrame(ownerEpoch: 3, sessionRevision: 43)
        let nextEpoch = TerminalResyncOwedOrdering.throughFrame(ownerEpoch: 4, sessionRevision: 1)

        XCTAssertEqual(first.merged(with: later), later)
        XCTAssertEqual(later.merged(with: first), later)
        XCTAssertEqual(first.merged(with: nextEpoch), nextEpoch)
        XCTAssertEqual(nextEpoch.merged(with: first), nextEpoch)
        // One read has to answer both failures, so a failure nothing can prove covered dominates, and a
        // gap with no ordering of its own defers to the one that has it.
        XCTAssertEqual(first.merged(with: .unknown), .unknown)
        XCTAssertEqual(TerminalResyncOwedOrdering.unknown.merged(with: .anyFrame), .unknown)
        XCTAssertEqual(TerminalResyncOwedOrdering.anyFrame.merged(with: first), first)
        XCTAssertEqual(first.merged(with: .anyFrame), first)
    }
}
