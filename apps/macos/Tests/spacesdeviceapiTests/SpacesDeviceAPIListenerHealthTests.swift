import Foundation
import XCTest

@testable import spacesdeviceapi

final class SpacesDeviceAPIListenerHealthTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    func testAListenerThatNeverStartedIsNotRunning() {
        XCTAssertFalse(SpacesDeviceAPIListenerHealth.isRunning(listenerStarted: false, waitingSince: nil, now: start))
    }

    func testAReadyListenerIsRunning() {
        XCTAssertTrue(SpacesDeviceAPIListenerHealth.isRunning(listenerStarted: true, waitingSince: nil, now: start))
    }

    func testATransientWaitInsideTheGracePeriodStaysRunning() {
        let waitingSince = start
        let now = start.addingTimeInterval(SpacesDeviceAPIListenerHealth.waitingGracePeriod - 1)

        XCTAssertTrue(SpacesDeviceAPIListenerHealth.isRunning(listenerStarted: true, waitingSince: waitingSince, now: now))
    }

    func testAWaitPastTheGracePeriodReportsNotRunningSoTheSupervisorRebuildsTheListener() {
        let waitingSince = start
        let now = start.addingTimeInterval(SpacesDeviceAPIListenerHealth.waitingGracePeriod)

        XCTAssertFalse(SpacesDeviceAPIListenerHealth.isRunning(listenerStarted: true, waitingSince: waitingSince, now: now))
    }

    func testAWaitThatResolvesBackToReadyIsRunningAgain() {
        let stuck = SpacesDeviceAPIListenerHealth.isRunning(
            listenerStarted: true, waitingSince: start, now: start.addingTimeInterval(SpacesDeviceAPIListenerHealth.waitingGracePeriod + 60))
        XCTAssertFalse(stuck)

        // Reaching ready clears the waiting timestamp, so the same elapsed time no longer counts.
        XCTAssertTrue(
            SpacesDeviceAPIListenerHealth.isRunning(
                listenerStarted: true, waitingSince: nil, now: start.addingTimeInterval(SpacesDeviceAPIListenerHealth.waitingGracePeriod + 60)))
    }

    func testAStoppedListenerStaysNotRunningWhileWaiting() {
        XCTAssertFalse(SpacesDeviceAPIListenerHealth.isRunning(listenerStarted: false, waitingSince: start, now: start))
    }
}
