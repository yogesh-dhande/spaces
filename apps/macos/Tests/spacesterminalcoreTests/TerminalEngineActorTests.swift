import Dispatch
import XCTest

@testable import spacesterminalcore

@MainActor final class TerminalEngineActorTests: XCTestCase {
    @TerminalEngineActor private final class Counter {
        var value = 0
        func bump() { value += 1 }
    }

    /// `runSynchronously` from a non-engine background thread enters the engine's isolation domain and
    /// returns the isolated result.
    func testRunSynchronouslyFromBackgroundThreadEntersActor() {
        let expectation = expectation(description: "background bridge")
        // Every `runSynchronously` call must originate off the main thread (the one-way rule's precondition),
        // so the isolated `Counter` is created and mutated entirely from the background bridge.
        DispatchQueue.global().async {
            let counter = TerminalEngineActor.runSynchronously { Counter() }
            let value = TerminalEngineActor.runSynchronously {
                counter.bump()
                counter.bump()
                return counter.value
            }
            XCTAssertEqual(value, 2)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    /// A reentrant `runSynchronously` (already on the engine queue) runs inline rather than deadlocking
    /// on `queue.sync`.
    func testRunSynchronouslyReentrantRunsInline() {
        let expectation = expectation(description: "reentrant")
        DispatchQueue.global().async {
            let value = TerminalEngineActor.runSynchronously {
                TerminalEngineActor.runSynchronously { 41 } + 1
            }
            XCTAssertEqual(value, 42)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    /// The legal engine→main synchronous hop (the one-way rule's permitted direction) does not deadlock
    /// when driven through the bridge from a background thread.
    func testEngineToMainSyncHopDoesNotDeadlock() {
        let expectation = expectation(description: "engine to main")
        DispatchQueue.global().async {
            let onMain = TerminalEngineActor.runSynchronously {
                DispatchQueue.main.sync { Thread.isMainThread }
            }
            XCTAssertTrue(onMain)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    /// The async `run` hop reaches the engine actor from a non-isolated async context.
    func testAsyncRunHop() async {
        let counter = await TerminalEngineActor.run { Counter() }
        await TerminalEngineActor.run { counter.bump() }
        let value = await TerminalEngineActor.run { counter.value }
        XCTAssertEqual(value, 1)
    }
}
