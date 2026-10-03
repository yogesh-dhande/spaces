#if canImport(UIKit)
    import XCTest
    @testable import SpacesMobile

    @MainActor private final class FakeVisitHost: SpacesMobileTerminalVisitHost {
        var clearableKeys: Set<String> = []
        private(set) var sent: [(sessionID: String, focusedForSeconds: Double, keys: Set<String>)] = []
        /// While set, a send does not return until `releaseHeldSend()`.
        var holdsSends = false
        private var heldSends: [CheckedContinuation<Void, Never>] = []

        func visitClearableKeys(forSessionID sessionID: String) -> Set<String> { clearableKeys }

        func sendVisit(sessionID: String, focusedForSeconds: Double, keys: Set<String>) async {
            sent.append((sessionID, focusedForSeconds, keys))
            guard holdsSends else { return }
            await withCheckedContinuation { heldSends.append($0) }
        }

        func releaseHeldSend() {
            holdsSends = false
            heldSends.removeFirst().resume()
        }
    }

    @MainActor final class TerminalVisitTrackerTests: XCTestCase {
        private let doneAlert = "agent:agent-a:done:2026-01-01T00:10:00Z"
        private let secondAlert = "process:process-a:2026-01-01T00:11:00Z"
        private let flagKey = "comebacklater:agent:agent-a"

        private func makeTracker() -> (SpacesMobileTerminalVisitTracker, ManualVisitClock, FakeVisitHost) {
            let clock = ManualVisitClock()
            let tracker = SpacesMobileTerminalVisitTracker(now: { clock.now }, schedule: clock.schedule)
            return (tracker, clock, FakeVisitHost())
        }

        /// Lets the tracker's request task run.
        private func settle() async { for _ in 0..<20 { await Task.yield() } }

        func testSendsTheVisitTwoSecondsAfterContentShowsWhenSomethingWouldClear() async {
            let (tracker, clock, host) = makeTracker()
            host.clearableKeys = [doneAlert]
            tracker.openSession("session-a", host: host)
            tracker.contentDidShow(sessionID: "session-a")

            clock.advance(1.9)
            await settle()
            XCTAssertTrue(host.sent.isEmpty, "a visit is not reported before the dwell")

            clock.advance(0.2)
            await settle()
            XCTAssertEqual(host.sent.count, 1)
            XCTAssertEqual(host.sent.first?.sessionID, "session-a")
            XCTAssertEqual(try XCTUnwrap(host.sent.first?.focusedForSeconds), 2.0, accuracy: 0.01)
        }

        func testAReportNamesOnlyTheKeysWhoseDwellCompleted() async {
            let (tracker, clock, host) = makeTracker()
            host.clearableKeys = [doneAlert]
            tracker.openSession("session-a", host: host)
            tracker.contentDidShow(sessionID: "session-a")
            clock.advance(1.9)

            host.clearableKeys = [doneAlert, secondAlert]
            tracker.overviewChanged()
            clock.advance(0.2)
            await settle()
            XCTAssertEqual(host.sent.map(\.keys), [[doneAlert]], "the later key has not had its own dwell")

            clock.advance(1.8)
            await settle()
            XCTAssertEqual(host.sent.map(\.keys), [[doneAlert], [secondAlert]])
            XCTAssertEqual(try XCTUnwrap(host.sent.last?.focusedForSeconds), 3.9, accuracy: 0.01)
        }

        func testNothingToClearSendsNothing() async {
            let (tracker, clock, host) = makeTracker()
            tracker.openSession("session-a", host: host)
            tracker.contentDidShow(sessionID: "session-a")

            clock.advance(30)
            await settle()

            XCTAssertTrue(host.sent.isEmpty)
        }

        func testTheVisitStartsOnlyOnceContentHasShown() async {
            let (tracker, clock, host) = makeTracker()
            host.clearableKeys = [doneAlert]
            tracker.openSession("session-a", host: host)

            clock.advance(10)
            await settle()
            XCTAssertTrue(host.sent.isEmpty, "an open viewer with nothing painted is not being looked at")
            XCTAssertFalse(tracker.hasActiveVisit)

            tracker.contentDidShow(sessionID: "session-a")
            clock.advance(2)
            await settle()

            XCTAssertEqual(host.sent.count, 1)
            XCTAssertEqual(try XCTUnwrap(host.sent.first?.focusedForSeconds), 2.0, accuracy: 0.01, "the visit is counted from first paint")
        }

        func testContentShownForAnotherSessionDoesNotStartTheVisit() async {
            let (tracker, clock, host) = makeTracker()
            host.clearableKeys = [doneAlert]
            tracker.openSession("session-a", host: host)

            tracker.contentDidShow(sessionID: "session-other")
            clock.advance(10)
            await settle()

            XCTAssertTrue(host.sent.isEmpty)
        }

        func testClosingTheViewerCancelsAPendingVisit() async {
            let (tracker, clock, host) = makeTracker()
            host.clearableKeys = [doneAlert]
            tracker.openSession("session-a", host: host)
            tracker.contentDidShow(sessionID: "session-a")

            clock.advance(1)
            tracker.closeSession()
            clock.advance(10)
            await settle()

            XCTAssertTrue(host.sent.isEmpty)
        }

        func testSwitchingToAnotherSessionCancelsTheVisitOfTheOneLeft() async {
            let (tracker, clock, host) = makeTracker()
            host.clearableKeys = [doneAlert]
            tracker.openSession("session-a", host: host)
            tracker.contentDidShow(sessionID: "session-a")

            clock.advance(1)
            tracker.openSession("session-b", host: host)
            clock.advance(10)
            await settle()

            XCTAssertTrue(host.sent.isEmpty, "session-b has not painted, and session-a was left before its dwell")
        }

        func testBackgroundingCancelsAndReturningStartsANewVisit() async {
            let (tracker, clock, host) = makeTracker()
            host.clearableKeys = [doneAlert]
            tracker.openSession("session-a", host: host)
            tracker.contentDidShow(sessionID: "session-a")

            clock.advance(1)
            tracker.setForeground(false)
            clock.advance(60)
            await settle()
            XCTAssertTrue(host.sent.isEmpty, "time away from the app is not time on the terminal")

            tracker.setForeground(true)
            clock.advance(2)
            await settle()

            XCTAssertEqual(host.sent.count, 1)
            XCTAssertEqual(
                try XCTUnwrap(host.sent.first?.focusedForSeconds), 2.0, accuracy: 0.01, "the new visit starts on return, not at the first open")
        }

        func testAnAlertArrivingWhileWatchedIsSentTwoSecondsLaterWithTheFullVisitDuration() async {
            let (tracker, clock, host) = makeTracker()
            tracker.openSession("session-a", host: host)
            tracker.contentDidShow(sessionID: "session-a")
            clock.advance(10)

            host.clearableKeys = [doneAlert]
            tracker.overviewChanged()
            clock.advance(1.9)
            await settle()
            XCTAssertTrue(host.sent.isEmpty)

            clock.advance(0.2)
            await settle()
            XCTAssertEqual(host.sent.count, 1)
            XCTAssertEqual(
                try XCTUnwrap(host.sent.first?.focusedForSeconds), 12.0, accuracy: 0.01,
                "the report carries how long the whole visit has lasted, so the device can tell it began before anything it set during it")
        }

        func testAFlagPresentWhenTheVisitStartsIsReported() async {
            let (tracker, clock, host) = makeTracker()
            host.clearableKeys = [flagKey]
            tracker.openSession("session-a", host: host)
            tracker.contentDidShow(sessionID: "session-a")

            clock.advance(2)
            await settle()

            XCTAssertEqual(host.sent.count, 1)
        }

        func testAFlagSetDuringTheVisitIsNeverReportedForIt() async {
            let (tracker, clock, host) = makeTracker()
            tracker.openSession("session-a", host: host)
            tracker.contentDidShow(sessionID: "session-a")
            clock.advance(5)

            host.clearableKeys = [flagKey]
            tracker.overviewChanged()
            clock.advance(30)
            await settle()

            XCTAssertTrue(host.sent.isEmpty, "the device keeps a flag set after the visit began, so reporting it is pointless")
        }

        func testNeverTwoRequestsInFlightAndTheWaitingAlertGoesOutOnceTheFirstReturns() async {
            let (tracker, clock, host) = makeTracker()
            host.clearableKeys = [doneAlert]
            host.holdsSends = true
            tracker.openSession("session-a", host: host)
            tracker.contentDidShow(sessionID: "session-a")
            clock.advance(2)
            await settle()
            XCTAssertEqual(host.sent.count, 1)

            host.clearableKeys = [doneAlert, secondAlert]
            tracker.overviewChanged()
            clock.advance(5)
            await settle()
            XCTAssertEqual(host.sent.count, 1, "the second alert waits while a request is out")

            host.releaseHeldSend()
            await settle()
            XCTAssertEqual(host.sent.count, 2)
        }

        func testAnAlertTheDeviceKeepsIsNotReportedAgainWithinTheSameVisit() async {
            let (tracker, clock, host) = makeTracker()
            host.clearableKeys = [doneAlert]
            tracker.openSession("session-a", host: host)
            tracker.contentDidShow(sessionID: "session-a")
            clock.advance(2)
            await settle()
            tracker.overviewChanged()

            clock.advance(30)
            await settle()
            XCTAssertEqual(host.sent.count, 1)

            // A later visit tries again.
            tracker.setForeground(false)
            tracker.setForeground(true)
            clock.advance(2)
            await settle()
            XCTAssertEqual(host.sent.count, 2)
        }
    }
#endif
