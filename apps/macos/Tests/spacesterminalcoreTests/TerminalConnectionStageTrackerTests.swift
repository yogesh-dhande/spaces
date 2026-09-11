import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalConnectionStageTrackerTests: XCTestCase {
    func testStartsConnectedWithNoBanner() {
        let tracker = TerminalConnectionStageTracker()
        XCTAssertEqual(tracker.stage, .connected)
        XCTAssertFalse(tracker.isBannerVisible)
    }

    func testStreamLostFromConnectedEntersReconnectingWithBannerHidden() {
        var tracker = TerminalConnectionStageTracker()
        tracker.streamLost()
        XCTAssertEqual(tracker.stage, .reconnecting)
        XCTAssertFalse(tracker.isBannerVisible)
    }

    func testGraceElapsedWhileReconnectingShowsTheBanner() {
        var tracker = TerminalConnectionStageTracker()
        tracker.streamLost()
        tracker.graceElapsed()
        XCTAssertEqual(tracker.stage, .reconnecting)
        XCTAssertTrue(tracker.isBannerVisible)
    }

    func testLateGraceTimerAfterFrameReceivedDoesNotShowTheBanner() {
        var tracker = TerminalConnectionStageTracker()
        tracker.streamLost()
        tracker.frameReceived()
        tracker.graceElapsed()
        XCTAssertEqual(tracker.stage, .connected)
        XCTAssertFalse(tracker.isBannerVisible)
    }

    func testEnteringUnreachableBeforeGraceElapsesShowsTheBannerImmediately() {
        var tracker = TerminalConnectionStageTracker()
        tracker.streamLost()
        tracker.enterUnreachable()
        XCTAssertEqual(tracker.stage, .unreachable)
        XCTAssertTrue(tracker.isBannerVisible)
        XCTAssertEqual(tracker.nextRedialDelay(), 1)
    }

    /// A caller that races several redials at once reports each attempt's failure as evidence only and
    /// paces the redials itself, so entering stage 2 repeatedly must not walk the ladder. Only
    /// `nextRedialDelay()` advances it, and it picks up where the reported failures left it alone.
    func testEnteringUnreachableRepeatedlyDoesNotSpendTheBackoffLadder() {
        var tracker = TerminalConnectionStageTracker()
        tracker.streamLost()
        tracker.enterUnreachable()
        tracker.enterUnreachable()
        tracker.enterUnreachable()
        XCTAssertEqual(tracker.stage, .unreachable)
        XCTAssertTrue(tracker.isBannerVisible)
        XCTAssertEqual(tracker.nextRedialDelay(), 1)
        XCTAssertEqual(tracker.nextRedialDelay(), 2)
    }

    func testRepeatedRedialsFollowTheBackoffLadder() {
        var tracker = TerminalConnectionStageTracker()
        tracker.streamLost()
        tracker.enterUnreachable()
        XCTAssertEqual(tracker.nextRedialDelay(), 1)
        XCTAssertEqual(tracker.nextRedialDelay(), 2)
        XCTAssertEqual(tracker.nextRedialDelay(), 4)
        XCTAssertEqual(tracker.nextRedialDelay(), 8)
        XCTAssertEqual(tracker.nextRedialDelay(), 15)
        XCTAssertEqual(tracker.nextRedialDelay(), 15)
    }

    func testEnteringUnreachableFromConnectedIsTreatedSafely() {
        var tracker = TerminalConnectionStageTracker()
        tracker.enterUnreachable()
        XCTAssertEqual(tracker.stage, .unreachable)
        XCTAssertTrue(tracker.isBannerVisible)
        XCTAssertEqual(tracker.nextRedialDelay(), 1)
    }

    func testRetryRequestedWhileUnreachableResetsTheBackoffButKeepsStageAndBanner() {
        var tracker = TerminalConnectionStageTracker()
        tracker.streamLost()
        tracker.enterUnreachable()
        _ = tracker.nextRedialDelay()
        _ = tracker.nextRedialDelay()
        tracker.retryRequested()
        XCTAssertEqual(tracker.stage, .unreachable)
        XCTAssertTrue(tracker.isBannerVisible)
        XCTAssertEqual(tracker.nextRedialDelay(), 1)
    }

    func testRetryRequestedWhileConnectedIsANoOp() {
        var tracker = TerminalConnectionStageTracker()
        tracker.retryRequested()
        XCTAssertEqual(tracker.stage, .connected)
        XCTAssertFalse(tracker.isBannerVisible)
    }

    func testFrameReceivedFromUnreachableReturnsToConnectedAndResetsBackoff() {
        var tracker = TerminalConnectionStageTracker()
        tracker.streamLost()
        tracker.enterUnreachable()
        _ = tracker.nextRedialDelay()
        _ = tracker.nextRedialDelay()
        tracker.frameReceived()
        XCTAssertEqual(tracker.stage, .connected)
        XCTAssertFalse(tracker.isBannerVisible)

        tracker.streamLost()
        tracker.enterUnreachable()
        XCTAssertEqual(tracker.nextRedialDelay(), 1)
    }

    func testStreamLostWhileUnreachableIsANoOp() {
        var tracker = TerminalConnectionStageTracker()
        tracker.streamLost()
        tracker.enterUnreachable()
        _ = tracker.nextRedialDelay()
        _ = tracker.nextRedialDelay()
        tracker.streamLost()
        XCTAssertEqual(tracker.stage, .unreachable)
        XCTAssertTrue(tracker.isBannerVisible)
        XCTAssertEqual(tracker.nextRedialDelay(), 4)
    }

    func testStreamLostWhileAlreadyReconnectingIsANoOp() {
        var tracker = TerminalConnectionStageTracker()
        tracker.streamLost()
        tracker.graceElapsed()
        tracker.streamLost()
        XCTAssertEqual(tracker.stage, .reconnecting)
        XCTAssertTrue(tracker.isBannerVisible)
    }
}
