import XCTest

@testable import spacesterminalcore

final class TerminalCorePersistenceQueueTests: XCTestCase {
    /// Records the order in which queued writes actually run, guarded so the serial queue and the draining
    /// test thread never race on the array.
    private final class OrderRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []

        func record(_ value: Int) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var recorded: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    /// A burst of coalesced writes for one key collapses to a single run of the newest value: earlier
    /// generations are superseded before they run because the queue is parked until every write is enqueued.
    func testCoalescedWriteRunsOnlyLatestForKey() {
        let queue = TerminalCorePersistenceQueue(label: "test.persistence.coalesce")
        let recorder = OrderRecorder()
        // Park the serial queue so all five enqueues land before any runs; the gate then supersedes the
        // first four when the barrier releases.
        let barrier = DispatchSemaphore(value: 0)
        queue.enqueueWrite { barrier.wait() }
        for value in 1...5 { queue.enqueueCoalescedWrite(key: "k") { recorder.record(value) } }
        barrier.signal()
        queue.drain()
        XCTAssertEqual(recorder.recorded, [5])
    }

    /// Coalescing is per key: two different keys each keep their own newest write.
    func testCoalescedWritesAreKeyedIndependently() {
        let queue = TerminalCorePersistenceQueue(label: "test.persistence.coalesce-keyed")
        let recorder = OrderRecorder()
        let barrier = DispatchSemaphore(value: 0)
        queue.enqueueWrite { barrier.wait() }
        queue.enqueueCoalescedWrite(key: "a") { recorder.record(1) }
        queue.enqueueCoalescedWrite(key: "b") { recorder.record(10) }
        queue.enqueueCoalescedWrite(key: "a") { recorder.record(2) }
        queue.enqueueCoalescedWrite(key: "b") { recorder.record(20) }
        barrier.signal()
        queue.drain()
        // Only the newest of each key runs, and FIFO preserves the enqueue order of those survivors.
        XCTAssertEqual(recorder.recorded, [2, 20])
    }

    /// Uncoalesced writes run in strict FIFO enqueue order, and `drain()` blocks until they have all run.
    func testUncoalescedWritesRunFIFOAndDrainBlocks() {
        let queue = TerminalCorePersistenceQueue(label: "test.persistence.fifo")
        let recorder = OrderRecorder()
        for value in 1...50 { queue.enqueueWrite { recorder.record(value) } }
        queue.drain()
        XCTAssertEqual(recorder.recorded, Array(1...50))
    }

    /// `drainAsync()` suspends until every enqueued write has run.
    func testDrainAsyncAwaitsQueuedWrites() async {
        let queue = TerminalCorePersistenceQueue(label: "test.persistence.drain-async")
        let recorder = OrderRecorder()
        for value in 1...20 { queue.enqueueWrite { recorder.record(value) } }
        await queue.drainAsync()
        XCTAssertEqual(recorder.recorded, Array(1...20))
    }
}
