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

    func testAttemptEndedUnreachableBeforeGraceElapsesEntersUnreachableWithBannerVisible() {
        var tracker = TerminalConnectionStageTracker()
        tracker.streamLost()
        let delay = tracker.attemptEndedUnreachable()
        XCTAssertEqual(tracker.stage, .unreachable)
        XCTAssertTrue(tracker.isBannerVisible)
        XCTAssertEqual(delay, 1)
    }

    func testRepeatedAttemptEndedUnreachableFollowsTheBackoffLadder() {
        var tracker = TerminalConnectionStageTracker()
        tracker.streamLost()
        XCTAssertEqual(tracker.attemptEndedUnreachable(), 1)
        XCTAssertEqual(tracker.attemptEndedUnreachable(), 2)
        XCTAssertEqual(tracker.attemptEndedUnreachable(), 4)
        XCTAssertEqual(tracker.attemptEndedUnreachable(), 8)
        XCTAssertEqual(tracker.attemptEndedUnreachable(), 15)
        XCTAssertEqual(tracker.attemptEndedUnreachable(), 15)
    }

    func testAttemptEndedUnreachableFromConnectedIsTreatedSafely() {
        var tracker = TerminalConnectionStageTracker()
        let delay = tracker.attemptEndedUnreachable()
        XCTAssertEqual(tracker.stage, .unreachable)
        XCTAssertTrue(tracker.isBannerVisible)
        XCTAssertEqual(delay, 1)
    }

    func testRetryRequestedWhileUnreachableResetsTheBackoffButKeepsStageAndBanner() {
        var tracker = TerminalConnectionStageTracker()
        tracker.streamLost()
        _ = tracker.attemptEndedUnreachable()
        _ = tracker.attemptEndedUnreachable()
        tracker.retryRequested()
        XCTAssertEqual(tracker.stage, .unreachable)
        XCTAssertTrue(tracker.isBannerVisible)
        XCTAssertEqual(tracker.attemptEndedUnreachable(), 1)
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
        _ = tracker.attemptEndedUnreachable()
        _ = tracker.attemptEndedUnreachable()
        tracker.frameReceived()
        XCTAssertEqual(tracker.stage, .connected)
        XCTAssertFalse(tracker.isBannerVisible)

        tracker.streamLost()
        XCTAssertEqual(tracker.attemptEndedUnreachable(), 1)
    }

    func testStreamLostWhileUnreachableIsANoOp() {
        var tracker = TerminalConnectionStageTracker()
        tracker.streamLost()
        _ = tracker.attemptEndedUnreachable()
        _ = tracker.attemptEndedUnreachable()
        tracker.streamLost()
        XCTAssertEqual(tracker.stage, .unreachable)
        XCTAssertTrue(tracker.isBannerVisible)
        XCTAssertEqual(tracker.attemptEndedUnreachable(), 4)
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
