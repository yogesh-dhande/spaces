import Foundation
import Testing

@testable import spacesui

/// Covers the serialization a burst of Next/Previous presses depends on: a step that arrives while an
/// earlier one is still awaiting real work runs after it, and reads the state the earlier one left.
@MainActor @Suite struct WindowCycleStepQueueTests {
    @Test func aStepEnqueuedMidBurstWaitsForThePreviousStepToLand() async {
        let queue = WindowCycleStepQueue()
        let cycle = CycleRecorder()
        let awaitedWork = Gate()

        // Stands in for the awaits a real step makes (Chrome tab discovery, opening a remote pane).
        queue.enqueue {
            cycle.steps.append("first started")
            await awaitedWork.wait()
            cycle.landedOn = "a"
            cycle.steps.append("first landed on a")
        }
        queue.enqueue {
            cycle.steps.append("second saw \(cycle.landedOn ?? "nothing")")
            cycle.landedOn = "b"
        }

        await settle()
        // The second press is chained behind a step that has not returned, so it has not read
        // anything yet.
        #expect(cycle.steps == ["first started"])

        awaitedWork.open()
        await settle()
        #expect(cycle.steps == ["first started", "first landed on a", "second saw a"])
        #expect(cycle.landedOn == "b")
    }

    @Test func stepsRunInTheOrderTheyWereEnqueued() async {
        let queue = WindowCycleStepQueue()
        let cycle = CycleRecorder()

        for press in ["1", "2", "3"] {
            queue.enqueue {
                await Task.yield()
                cycle.steps.append(press)
            }
        }

        await settle()
        #expect(cycle.steps == ["1", "2", "3"])
    }

    /// Runs whatever main-actor work the queue has pending. The queue holds at most a handful of
    /// steps here, so this is far more turns than they need.
    private func settle() async { for _ in 0..<100 { await Task.yield() } }
}

/// What the cycle steps write, standing in for the cursor and frozen rotation a real step lands on.
@MainActor private final class CycleRecorder {
    var steps: [String] = []
    var landedOn: String?
}

/// Holds a step open until the test releases it, the way an in-flight Chrome or pane-open await does.
@MainActor private final class Gate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}
