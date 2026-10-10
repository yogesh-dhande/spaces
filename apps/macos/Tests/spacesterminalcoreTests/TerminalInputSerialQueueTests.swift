import Foundation
import XCTest

@testable import spacesterminalcore

final class TerminalInputSerialQueueTests: XCTestCase {
    func testQueueRunsRequestsInSubmissionOrder() async {
        let queue = TerminalInputSerialQueue()
        let collector = InputQueueEventCollector()
        let allRequestsFinished = expectation(description: "all input requests finished")

        for index in 0..<3 {
            queue.enqueue {
                if index == 0 { try await Task.sleep(for: .milliseconds(100)) }
                if await collector.append(index) { allRequestsFinished.fulfill() }
            }
        }

        await fulfillment(of: [allRequestsFinished], timeout: 2)
        let capturedEvents = await collector.snapshot()
        XCTAssertEqual(capturedEvents, [0, 1, 2])
    }

    func testCancelAllCancelsQueuedChainBeforeRunningNewRequests() async throws {
        let queue = TerminalInputSerialQueue()
        let collector = InputQueueStringEventCollector()
        let gate = InputQueueGate()
        let firstRequestStarted = expectation(description: "first request started")
        let newRequestFinished = expectation(description: "new request finished")

        queue.enqueue {
            await collector.append("first_started")
            firstRequestStarted.fulfill()
            await gate.wait()
            await collector.append("first_finished")
        }
        queue.enqueue { await collector.append("stale_1") }
        queue.enqueue { await collector.append("stale_2") }

        await fulfillment(of: [firstRequestStarted], timeout: 2)
        queue.cancelAll()
        queue.enqueue {
            await collector.append("new")
            newRequestFinished.fulfill()
        }

        try await Task.sleep(for: .milliseconds(100))
        var capturedEvents = await collector.snapshot()
        XCTAssertEqual(capturedEvents, ["first_started"])

        await gate.open()
        await fulfillment(of: [newRequestFinished], timeout: 2)
        capturedEvents = await collector.snapshot()
        XCTAssertEqual(capturedEvents, ["first_started", "first_finished", "new"])
    }

    /// A task cancelled or generation-superseded before it ever runs `operation` cannot run its own
    /// completion bookkeeping from inside that closure, so `onDiscarded` is the queue's own signal that
    /// a slot a caller is holding open until completion (e.g. `TerminalScrollCoalescer`'s
    /// one-batch-in-flight gate) must be released some other way. This proves it fires exactly once for
    /// a task `cancelAll()` discards while still queued behind a blocked head, and never for the head
    /// task itself, which actually ran to completion.
    func testCancelAllInvokesOnDiscardedForTasksThatNeverRanAndNeverForOnesThatDid() async throws {
        let queue = TerminalInputSerialQueue()
        let collector = InputQueueStringEventCollector()
        let gate = InputQueueGate()
        let discardCount = InputQueueDiscardCounter()
        let firstRequestStarted = expectation(description: "first request started")
        let firstRequestFinished = expectation(description: "first request finished")

        queue.enqueue(
            operation: {
                await collector.append("first_started")
                firstRequestStarted.fulfill()
                await gate.wait()
                await collector.append("first_finished")
                firstRequestFinished.fulfill()
            }, onDiscarded: { await discardCount.increment(label: "first") })
        queue.enqueue(operation: { await collector.append("stale") }, onDiscarded: { await discardCount.increment(label: "second") })

        await fulfillment(of: [firstRequestStarted], timeout: 2)
        queue.cancelAll()
        await gate.open()
        await fulfillment(of: [firstRequestFinished], timeout: 2)

        // The discarded second task races the head's own completion only in when its `defer` runs, not
        // in whether `onDiscarded` fires at all (it is called synchronously on the discard path, before
        // the task returns), so a short poll rather than a fixed sleep keeps this from flaking under load.
        var counts = await discardCount.snapshot()
        let deadline = ContinuousClock().now + .seconds(2)
        while counts["second"] != 1, ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            counts = await discardCount.snapshot()
        }

        XCTAssertEqual(counts["second"], 1, "the discarded task behind the cancelled chain must invoke onDiscarded exactly once")
        XCTAssertNil(counts["first"], "the head task ran operation to completion, so it must never invoke onDiscarded")
        let capturedEvents = await collector.snapshot()
        XCTAssertEqual(capturedEvents, ["first_started", "first_finished"], "the discarded task's operation must never run")
    }

    /// A pointer crossing cells quickly queues a motion per cell behind whatever is in flight. Of
    /// consecutive unsent motions only the newest matters, so the older ones are discarded.
    func testConsecutiveSupersedableOperationsKeepOnlyTheNewest() async throws {
        let queue = TerminalInputSerialQueue()
        let collector = InputQueueStringEventCollector()
        let gate = InputQueueGate()
        let discardCount = InputQueueDiscardCounter()
        let headStarted = expectation(description: "head started")
        let lastFinished = expectation(description: "last motion finished")

        queue.enqueue {
            headStarted.fulfill()
            await gate.wait()
            await collector.append("press")
        }
        await fulfillment(of: [headStarted], timeout: 2)
        queue.enqueue(
            supersedable: true, operation: { await collector.append("motion_1") }, onDiscarded: { await discardCount.increment(label: "motion_1") })
        queue.enqueue(
            supersedable: true,
            operation: {
                await collector.append("motion_2")
                lastFinished.fulfill()
            }, onDiscarded: { await discardCount.increment(label: "motion_2") })

        await gate.open()
        await fulfillment(of: [lastFinished], timeout: 2)

        let events = await collector.snapshot()
        XCTAssertEqual(events, ["press", "motion_2"])
        let counts = await discardCount.snapshot()
        XCTAssertEqual(counts["motion_1"], 1)
        XCTAssertNil(counts["motion_2"])
    }

    /// A press, release or key between two motions fences them: the earlier motion belongs before that
    /// input and a later motion must not discard it (a drag's last cell must still reach the program
    /// before its release).
    func testNonSupersedableOperationBetweenMotionsKeepsBothMotionsInOrder() async throws {
        let queue = TerminalInputSerialQueue()
        let collector = InputQueueStringEventCollector()
        let gate = InputQueueGate()
        let discardCount = InputQueueDiscardCounter()
        let headStarted = expectation(description: "head started")
        let lastFinished = expectation(description: "last motion finished")

        queue.enqueue {
            headStarted.fulfill()
            await gate.wait()
            await collector.append("press")
        }
        await fulfillment(of: [headStarted], timeout: 2)
        queue.enqueue(
            supersedable: true, operation: { await collector.append("drag_motion") },
            onDiscarded: { await discardCount.increment(label: "drag_motion") })
        queue.enqueue { await collector.append("release") }
        queue.enqueue(
            supersedable: true,
            operation: {
                await collector.append("hover_motion")
                lastFinished.fulfill()
            }, onDiscarded: { await discardCount.increment(label: "hover_motion") })

        await gate.open()
        await fulfillment(of: [lastFinished], timeout: 2)

        let events = await collector.snapshot()
        XCTAssertEqual(events, ["press", "drag_motion", "release", "hover_motion"])
        let counts = await discardCount.snapshot()
        XCTAssertTrue(counts.isEmpty, "no motion may be discarded across a release: \(counts)")
    }

    /// A motion already running is past replacing, and the next one queues after it as usual.
    func testSupersedableOperationThatAlreadyStartedIsNotDiscarded() async throws {
        let queue = TerminalInputSerialQueue()
        let collector = InputQueueStringEventCollector()
        let gate = InputQueueGate()
        let firstStarted = expectation(description: "first motion started")
        let secondFinished = expectation(description: "second motion finished")

        queue.enqueue(supersedable: true) {
            firstStarted.fulfill()
            await gate.wait()
            await collector.append("motion_1")
        }
        await fulfillment(of: [firstStarted], timeout: 2)
        queue.enqueue(supersedable: true) {
            await collector.append("motion_2")
            secondFinished.fulfill()
        }

        await gate.open()
        await fulfillment(of: [secondFinished], timeout: 2)
        let events = await collector.snapshot()
        XCTAssertEqual(events, ["motion_1", "motion_2"])
    }
}

private actor InputQueueEventCollector {
    private var events: [Int] = []

    func append(_ event: Int) -> Bool {
        events.append(event)
        return events.count == 3
    }

    func snapshot() -> [Int] { events }
}

private actor InputQueueStringEventCollector {
    private var events: [String] = []

    func append(_ event: String) { events.append(event) }

    func snapshot() -> [String] { events }
}

private actor InputQueueDiscardCounter {
    private var counts: [String: Int] = [:]

    func increment(label: String) { counts[label, default: 0] += 1 }

    func snapshot() -> [String: Int] { counts }
}

private actor InputQueueGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in continuations.append(continuation) }
    }

    func open() {
        isOpen = true
        let pendingContinuations = continuations
        continuations.removeAll()
        for continuation in pendingContinuations { continuation.resume() }
    }
}
