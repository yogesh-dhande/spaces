import XCTest

@testable import spacesterminalcore

@MainActor final class TerminalScrollCoalescerTests: XCTestCase {
    private struct WaitTimedOut: Error {}

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

    private func waitUntil(
        timeout: Duration = .seconds(2), pollInterval: Duration = .milliseconds(10), file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: pollInterval)
        }

        XCTFail("Timed out waiting for condition.", file: file, line: line)
        throw WaitTimedOut()
    }

    func testScrollEventsMergeIntoOneFrameBatch() async throws {
        let recorder = Recorder()
        let coalescer = TerminalScrollCoalescer(frameInterval: .milliseconds(20)) { batch, finish in
            recorder.enqueue(batch, finish: finish)
            finish()
        }

        coalescer.append(horizontal: 1, vertical: 2, scrollMods: 7)
        coalescer.append(horizontal: 3, vertical: 4, scrollMods: 15)
        try await waitUntil { recorder.batches == [.init(horizontal: 4, vertical: 6, scrollMods: 15)] }
    }

    func testScrollEventsRetainLatestPointerPosition() async throws {
        let recorder = Recorder()
        let coalescer = TerminalScrollCoalescer(frameInterval: .milliseconds(20)) { batch, finish in
            recorder.enqueue(batch, finish: finish)
            finish()
        }

        coalescer.append(horizontal: 0, vertical: 2, scrollMods: 7, pointerPosition: .init(x: 0.25, y: 0.5, mods: 1))
        coalescer.append(horizontal: 0, vertical: 4, scrollMods: 15, pointerPosition: .init(x: 0.75, y: 0.8, mods: 8))

        try await waitUntil {
            recorder.batches == [.init(horizontal: 0, vertical: 6, scrollMods: 15, pointerPosition: .init(x: 0.75, y: 0.8, mods: 8))]
        }
    }

    func testInFlightScrollDoesNotQueueStaleFrameBatches() async throws {
        let recorder = Recorder()
        let coalescer = TerminalScrollCoalescer(frameInterval: .milliseconds(20)) { batch, finish in recorder.enqueue(batch, finish: finish) }

        coalescer.append(horizontal: 0, vertical: 5, scrollMods: 7)
        try await waitUntil { recorder.batches == [.init(horizontal: 0, vertical: 5, scrollMods: 7)] }

        coalescer.append(horizontal: 0, vertical: 2, scrollMods: 7)
        coalescer.append(horizontal: 0, vertical: 3, scrollMods: 15)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(recorder.batches.count, 1)

        recorder.finishFirst()
        try await waitUntil {
            recorder.batches == [.init(horizontal: 0, vertical: 5, scrollMods: 7), .init(horizontal: 0, vertical: 5, scrollMods: 15)]
        }
    }

    func testFlushSendsPendingScrollImmediatelyForInputOrdering() {
        let recorder = Recorder()
        let coalescer = TerminalScrollCoalescer(frameInterval: .milliseconds(200)) { batch, finish in recorder.enqueue(batch, finish: finish) }

        coalescer.append(horizontal: 2, vertical: 3, scrollMods: 7)
        coalescer.flush()

        XCTAssertEqual(recorder.batches, [.init(horizontal: 2, vertical: 3, scrollMods: 7)])
    }
}
