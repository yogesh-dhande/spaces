import Foundation
import XCTest

@testable import spacesterminalghostty

final class GhosttyInputOutputResyncSchedulerTests: XCTestCase {
    /// Spins the main run loop long enough for the 20ms local-echo resync delay to
    /// fire, matching the timing idiom used by GhosttyEmbeddedSessionHostTests.
    @MainActor private func spinMainLoop(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor func testInteractiveOutputWithPendingCommandSchedulesResync() {
        var resyncCount = 0
        let scheduler = GhosttyInputOutputResyncScheduler { resyncCount += 1 }

        scheduler.noteLocalOwnerCommand()
        scheduler.handleOutputDidChange(interactive: true)

        XCTAssertTrue(scheduler.hasScheduledResync)
        spinMainLoop()
        XCTAssertEqual(resyncCount, 1)
        XCTAssertFalse(scheduler.hasScheduledResync)
    }

    @MainActor func testInteractiveOutputWithInFlightWorkItemReschedules() {
        var resyncCount = 0
        let scheduler = GhosttyInputOutputResyncScheduler { resyncCount += 1 }

        scheduler.noteLocalOwnerCommand()
        scheduler.handleOutputDidChange(interactive: true)
        XCTAssertTrue(scheduler.hasScheduledResync)

        // A second interactive output while a work item is in flight reschedules the
        // resync rather than cancelling it; the cancelled prior item never fires.
        scheduler.handleOutputDidChange(interactive: true)
        XCTAssertTrue(scheduler.hasScheduledResync)

        spinMainLoop()
        XCTAssertEqual(resyncCount, 1)
    }

    @MainActor func testPlainInteractiveOutputCancelsWithoutScheduling() {
        var resyncCount = 0
        let scheduler = GhosttyInputOutputResyncScheduler { resyncCount += 1 }

        scheduler.handleOutputDidChange(interactive: true)

        XCTAssertFalse(scheduler.hasScheduledResync)
        spinMainLoop()
        XCTAssertEqual(resyncCount, 0)
    }

    @MainActor func testBulkOutputWithPendingInputSchedulesResync() {
        var resyncCount = 0
        let scheduler = GhosttyInputOutputResyncScheduler { resyncCount += 1 }

        scheduler.noteLocalOwnerInput()
        scheduler.handleOutputDidChange(interactive: false)

        XCTAssertTrue(scheduler.hasScheduledResync)
        spinMainLoop()
        XCTAssertEqual(resyncCount, 1)
        XCTAssertFalse(scheduler.hasScheduledResync)
    }

    @MainActor func testBulkOutputWithNothingPendingIsNoOp() {
        var resyncCount = 0
        let scheduler = GhosttyInputOutputResyncScheduler { resyncCount += 1 }

        scheduler.handleOutputDidChange(interactive: false)

        XCTAssertFalse(scheduler.hasScheduledResync)
        spinMainLoop()
        XCTAssertEqual(resyncCount, 0)
    }

    @MainActor func testCancelForTerminationCancelsWorkItemButKeepsInputPending() {
        var resyncCount = 0
        let scheduler = GhosttyInputOutputResyncScheduler { resyncCount += 1 }

        // Schedule a work item via the command path so termination has one to cancel.
        scheduler.noteLocalOwnerCommand()
        scheduler.handleOutputDidChange(interactive: true)
        // The owner types again before shutdown, marking input pending.
        scheduler.noteLocalOwnerInput()
        XCTAssertTrue(scheduler.hasScheduledResync)

        scheduler.cancelForTermination()
        XCTAssertFalse(scheduler.hasScheduledResync)
        spinMainLoop()
        XCTAssertEqual(resyncCount, 0)

        // Termination cleared the command flag and work item but left input-pending
        // intact, so a subsequent bulk output schedules another resync.
        scheduler.handleOutputDidChange(interactive: false)
        XCTAssertTrue(scheduler.hasScheduledResync)
        spinMainLoop()
        XCTAssertEqual(resyncCount, 1)
    }
}
