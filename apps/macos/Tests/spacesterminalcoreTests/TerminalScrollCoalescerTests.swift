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

    func testScrollEventsMergeIntoOneFrameBatch() async throws {
        let recorder = Recorder()
        let coalescer = TerminalScrollCoalescer(frameInterval: .milliseconds(20)) { batch, finish in
            recorder.enqueue(batch, finish: finish)
            finish()
        }

        coalescer.append(horizontal: 1, vertical: 2, scrollMods: 7)
        coalescer.append(horizontal: 3, vertical: 4, scrollMods: 15)
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(recorder.batches, [.init(horizontal: 4, vertical: 6, scrollMods: 15)])
    }

    func testInFlightScrollDoesNotQueueStaleFrameBatches() async throws {
        let recorder = Recorder()
        let coalescer = TerminalScrollCoalescer(frameInterval: .milliseconds(20)) { batch, finish in recorder.enqueue(batch, finish: finish) }

        coalescer.append(horizontal: 0, vertical: 5, scrollMods: 7)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(recorder.batches, [.init(horizontal: 0, vertical: 5, scrollMods: 7)])

        coalescer.append(horizontal: 0, vertical: 2, scrollMods: 7)
        coalescer.append(horizontal: 0, vertical: 3, scrollMods: 15)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(recorder.batches.count, 1)

        recorder.finishFirst()
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(recorder.batches, [.init(horizontal: 0, vertical: 5, scrollMods: 7), .init(horizontal: 0, vertical: 5, scrollMods: 15)])
    }

    func testFlushSendsPendingScrollImmediatelyForInputOrdering() {
        let recorder = Recorder()
        let coalescer = TerminalScrollCoalescer(frameInterval: .milliseconds(200)) { batch, finish in recorder.enqueue(batch, finish: finish) }

        coalescer.append(horizontal: 2, vertical: 3, scrollMods: 7)
        coalescer.flush()

        XCTAssertEqual(recorder.batches, [.init(horizontal: 2, vertical: 3, scrollMods: 7)])
    }
}
