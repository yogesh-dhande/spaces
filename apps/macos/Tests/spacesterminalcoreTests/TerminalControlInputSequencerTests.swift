import Foundation
import XCTest

@testable import spacesterminalcore

/// Contract coverage for the control-input sequencer: writes run strictly in enqueue order with no
/// artificial pacing, a submit's carriage return stays glued to the text it submits even when other
/// sends arrive in between, and `drain()` waits for the whole outstanding chain.
final class TerminalControlInputSequencerTests: XCTestCase {
    private final class WriteRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(label: String, at: ContinuousClock.Instant)] = []

        func record(_ label: String) {
            lock.lock()
            entries.append((label: label, at: ContinuousClock.now))
            lock.unlock()
        }

        var recorded: [(label: String, at: ContinuousClock.Instant)] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    /// A submit is two writes (the pasted text, then the CR that submits it). Nothing may be written
    /// between them, or two submissions merge into one line with a stray Enter — which is what the
    /// sequencer exists to prevent now that the pair is separated structurally (bracketed paste) rather
    /// than by a timed gap. This enqueues two submits back-to-back the way the daemon's notification
    /// flush delivers queued lines, plus a following write, and pins the exact interleaving.
    func testSubmitPairsStayAdjacentAcrossBackToBackSends() async {
        let sequencer = TerminalControlInputSequencer()
        let recorder = WriteRecorder()
        let drained = expectation(description: "all writes ran")

        sequencer.enqueueWrite { recorder.record("text-1") }
        sequencer.enqueueWrite { recorder.record("cr-1") }
        sequencer.enqueueWrite { recorder.record("text-2") }
        sequencer.enqueueWrite { recorder.record("cr-2") }
        sequencer.enqueueWrite {
            recorder.record("text-3")
            drained.fulfill()
        }

        await fulfillment(of: [drained], timeout: 10)

        XCTAssertEqual(recorder.recorded.map(\.label), ["text-1", "cr-1", "text-2", "cr-2", "text-3"])
    }

    /// The point of removing the timed separation: a submit pays no pacing cost. A text+CR pair, and a
    /// second submit right behind it, must all land promptly rather than each waiting out a fixed
    /// interval (issue #389 — a lone submit cost ~500ms and back-to-back submits ~1s before the shell
    /// even saw the newline).
    func testSubmitWritesRunWithoutArtificialPacing() async {
        let sequencer = TerminalControlInputSequencer()
        let recorder = WriteRecorder()
        let drained = expectation(description: "both submits ran")

        let start = ContinuousClock.now
        sequencer.enqueueWrite { recorder.record("text-1") }
        sequencer.enqueueWrite { recorder.record("cr-1") }
        sequencer.enqueueWrite { recorder.record("text-2") }
        sequencer.enqueueWrite {
            recorder.record("cr-2")
            drained.fulfill()
        }

        await fulfillment(of: [drained], timeout: 10)

        let recorded = recorder.recorded
        XCTAssertEqual(recorded.map(\.label), ["text-1", "cr-1", "text-2", "cr-2"])
        XCTAssertLessThan(
            start.duration(to: recorded[3].at), .milliseconds(150),
            "two submit pairs must not pay a fixed per-submit pacing interval")
    }

    /// `drain()` must suspend until every write enqueued so far has actually run. This is the
    /// handoff-quiesce guarantee (finding D1): before the daemon `execv`s, a pending
    /// `terminal send --submit` must not be lost with its CR (or whole line) unwritten. The writes here
    /// are deliberately slow so a `drain()` that did not await the chain would return early; asserting the
    /// recorded writes SYNCHRONOUSLY right after `await drain()` proves it waited.
    func testDrainWaitsForEverythingEnqueuedBeforeReturning() async {
        let sequencer = TerminalControlInputSequencer()
        let recorder = WriteRecorder()

        sequencer.enqueueWrite {
            try? await Task.sleep(for: .milliseconds(100), clock: .continuous)
            recorder.record("text")
        }
        sequencer.enqueueWrite {
            try? await Task.sleep(for: .milliseconds(100), clock: .continuous)
            recorder.record("cr")
        }

        await sequencer.drain()

        // No polling: both writes must already have run because drain awaited the whole chain.
        XCTAssertEqual(recorder.recorded.map(\.label), ["text", "cr"], "drain() returned before the queued submit writes ran")
    }
}
