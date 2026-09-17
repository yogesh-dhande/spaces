import XCTest

@testable import spacesterminalcore

@MainActor final class TerminalScrollCoalescerTests: XCTestCase {
    @MainActor private final class Recorder: @unchecked Sendable {
        var batches: [TerminalScrollCoalescer.Batch] = []
        var completions: [TerminalScrollCoalescer.FinishHandler] = []

        func enqueue(_ batch: TerminalScrollCoalescer.Batch, finish: @escaping TerminalScrollCoalescer.FinishHandler) {
            batches.append(batch)
            completions.append(finish)
        }

        func finishFirst() {
            let finish = completions.removeFirst()
            finish()
        }
    }

    /// The first delta of a gesture is the one the user is waiting on, so it leaves synchronously: no
    /// await, no timer turn.
    func testFirstScrollSendsWithoutWaiting() {
        let recorder = Recorder()
        let coalescer = TerminalScrollCoalescer { batch, finish in recorder.enqueue(batch, finish: finish) }

        coalescer.append(horizontal: 1, vertical: 2, scrollMods: 7)

        XCTAssertEqual(recorder.batches, [.init(horizontal: 1, vertical: 2, scrollMods: 7)])
    }

    func testScrollEventsMergeWhileABatchIsInFlight() {
        let recorder = Recorder()
        let coalescer = TerminalScrollCoalescer { batch, finish in recorder.enqueue(batch, finish: finish) }

        coalescer.append(horizontal: 1, vertical: 2, scrollMods: 7)
        coalescer.append(horizontal: 3, vertical: 4, scrollMods: 15)
        coalescer.append(horizontal: 5, vertical: 6, scrollMods: 15)
        XCTAssertEqual(recorder.batches.count, 1)

        recorder.finishFirst()

        XCTAssertEqual(recorder.batches, [.init(horizontal: 1, vertical: 2, scrollMods: 7), .init(horizontal: 8, vertical: 10, scrollMods: 15)])
    }

    func testMergedScrollRetainsLatestPointerPosition() {
        let recorder = Recorder()
        let coalescer = TerminalScrollCoalescer { batch, finish in recorder.enqueue(batch, finish: finish) }

        coalescer.append(horizontal: 0, vertical: 1, scrollMods: 7, pointerPosition: .init(x: 0.1, y: 0.1, mods: 0))
        coalescer.append(horizontal: 0, vertical: 2, scrollMods: 7, pointerPosition: .init(x: 0.25, y: 0.5, mods: 1))
        coalescer.append(horizontal: 0, vertical: 4, scrollMods: 15, pointerPosition: .init(x: 0.75, y: 0.8, mods: 8))
        recorder.finishFirst()

        XCTAssertEqual(recorder.batches.last, .init(horizontal: 0, vertical: 6, scrollMods: 15, pointerPosition: .init(x: 0.75, y: 0.8, mods: 8)))
    }

    func testCompletedBatchWithNothingPendingSendsNothing() {
        let recorder = Recorder()
        let coalescer = TerminalScrollCoalescer { batch, finish in recorder.enqueue(batch, finish: finish) }

        coalescer.append(horizontal: 0, vertical: 5, scrollMods: 7)
        recorder.finishFirst()

        XCTAssertEqual(recorder.batches, [.init(horizontal: 0, vertical: 5, scrollMods: 7)])
    }

    func testFlushSendsPendingScrollImmediatelyForInputOrdering() {
        let recorder = Recorder()
        let coalescer = TerminalScrollCoalescer { batch, finish in recorder.enqueue(batch, finish: finish) }

        coalescer.append(horizontal: 2, vertical: 3, scrollMods: 7)
        coalescer.append(horizontal: 1, vertical: 1, scrollMods: 7)
        coalescer.flush()

        XCTAssertEqual(recorder.batches, [.init(horizontal: 2, vertical: 3, scrollMods: 7), .init(horizontal: 1, vertical: 1, scrollMods: 7)])
    }

    func testCancelDropsPendingScroll() {
        let recorder = Recorder()
        let coalescer = TerminalScrollCoalescer { batch, finish in recorder.enqueue(batch, finish: finish) }

        coalescer.append(horizontal: 0, vertical: 5, scrollMods: 7)
        coalescer.append(horizontal: 0, vertical: 9, scrollMods: 7)
        coalescer.cancel()
        recorder.finishFirst()

        XCTAssertEqual(recorder.batches, [.init(horizontal: 0, vertical: 5, scrollMods: 7)])
    }
}
