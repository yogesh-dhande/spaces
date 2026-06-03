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
