import Foundation
import XCTest

@testable import spacesterminalghostty

final class GhosttyInputOutputResyncSchedulerTests: XCTestCase {
    @MainActor private func waitForCondition(_ description: String, timeout: TimeInterval = 5, condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for \(description)")
    }

    @MainActor func testInteractiveOutputWithPendingCommandSchedulesResync() async {
        var resyncCount = 0
        let scheduler = GhosttyInputOutputResyncScheduler { resyncCount += 1 }

        scheduler.noteLocalOwnerCommand()
        scheduler.handleOutputDidChange(interactive: true)

        XCTAssertTrue(scheduler.hasScheduledResync)
        await waitForCondition("pending command resync") { resyncCount == 1 }
        XCTAssertEqual(resyncCount, 1)
        XCTAssertFalse(scheduler.hasScheduledResync)
    }

    @MainActor func testInteractiveOutputWithInFlightWorkItemReschedules() async {
        var resyncCount = 0
        let scheduler = GhosttyInputOutputResyncScheduler { resyncCount += 1 }

        scheduler.noteLocalOwnerCommand()
        scheduler.handleOutputDidChange(interactive: true)
        XCTAssertTrue(scheduler.hasScheduledResync)

        // A second interactive output while a work item is in flight reschedules the
        // resync rather than cancelling it; the cancelled prior item never fires.
        scheduler.handleOutputDidChange(interactive: true)
        XCTAssertTrue(scheduler.hasScheduledResync)

        await waitForCondition("in-flight work item resync") { resyncCount == 1 }
        XCTAssertEqual(resyncCount, 1)
    }

    @MainActor func testPlainInteractiveOutputCancelsWithoutScheduling() async {
        var resyncCount = 0
        let scheduler = GhosttyInputOutputResyncScheduler { resyncCount += 1 }

        scheduler.handleOutputDidChange(interactive: true)

        XCTAssertFalse(scheduler.hasScheduledResync)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(resyncCount, 0)
    }

    @MainActor func testBulkOutputWithPendingInputSchedulesResync() async {
        var resyncCount = 0
        let scheduler = GhosttyInputOutputResyncScheduler { resyncCount += 1 }

        scheduler.noteLocalOwnerInput()
        scheduler.handleOutputDidChange(interactive: false)

        XCTAssertTrue(scheduler.hasScheduledResync)
        await waitForCondition("pending input resync") { resyncCount == 1 }
        XCTAssertEqual(resyncCount, 1)
        XCTAssertFalse(scheduler.hasScheduledResync)
    }

    @MainActor func testBulkOutputWithNothingPendingIsNoOp() async {
        var resyncCount = 0
        let scheduler = GhosttyInputOutputResyncScheduler { resyncCount += 1 }

        scheduler.handleOutputDidChange(interactive: false)

        XCTAssertFalse(scheduler.hasScheduledResync)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(resyncCount, 0)
    }

    @MainActor func testCancelForTerminationCancelsWorkItemButKeepsInputPending() async {
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
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(resyncCount, 0)

        // Termination cleared the command flag and work item but left input-pending
        // intact, so a subsequent bulk output schedules another resync.
        scheduler.handleOutputDidChange(interactive: false)
        XCTAssertTrue(scheduler.hasScheduledResync)
        await waitForCondition("post-termination pending input resync") { resyncCount == 1 }
        XCTAssertEqual(resyncCount, 1)
    }
}
