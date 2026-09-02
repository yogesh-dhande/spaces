import XCTest

@testable import spacesd

#if os(macOS)
    final class AutomationTickCoalescerTests: XCTestCase {
        func testCoalescesTicksWhileOneIsInFlight() {
            let counter = TickCounter()
            let started = expectation(description: "first tick started")
            started.assertForOverFulfill = false
            let finished = expectation(description: "two ticks finished")
            // The first tick blocks on this semaphore, holding itself in flight until the
            // test has issued both coalescing submits. A fixed sleep here loses to scheduler
            // load: if the window expires between the submits, the third submit starts a
            // third tick instead of coalescing.
            let release = DispatchSemaphore(value: 0)
            let coalescer = AutomationTickCoalescer {
                let value = counter.increment()
                if value == 1 {
                    started.fulfill()
                    release.wait()
                }
                if value == 2 { finished.fulfill() }
            }
            coalescer.submit()
            wait(for: [started], timeout: 2)
            coalescer.submit()
            coalescer.submit()
            release.signal()
            wait(for: [finished], timeout: 2)
            XCTAssertEqual(counter.value(), 2)
        }
    }

    private final class TickCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }
        func value() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }
#endif
