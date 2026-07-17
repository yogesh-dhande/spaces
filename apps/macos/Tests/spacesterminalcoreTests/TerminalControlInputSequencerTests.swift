import Foundation
import XCTest

@testable import spacesterminalcore

/// Contract coverage for the control-input sequencer: writes run strictly in enqueue order, and a
/// submit carriage return is temporally separated from the write before it (the text it submits) and
/// the write after it (the next request's bytes), so the CR reaches the TUI as a lone Enter burst.
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

    func testSubmitPairsStayOrderedAndSeparatedAgainstRapidFollowUpWrites() async {
        let separation: Duration = .milliseconds(50)
        let sequencer = TerminalControlInputSequencer(separation: separation)
        let recorder = WriteRecorder()
        let drained = expectation(description: "all writes ran")

        // Two rapid submit-style sends (text + CR each), enqueued back-to-back the way the daemon's
        // notification flush delivers queued lines.
        sequencer.enqueueWrite { recorder.record("text-1") }
        sequencer.enqueueSubmitCarriageReturn { recorder.record("cr-1") }
        sequencer.enqueueWrite { recorder.record("text-2") }
        sequencer.enqueueSubmitCarriageReturn { recorder.record("cr-2") }
        sequencer.enqueueWrite {
            recorder.record("text-3")
            drained.fulfill()
        }

        await fulfillment(of: [drained], timeout: 10)

        let recorded = recorder.recorded
        XCTAssertEqual(recorded.map(\.label), ["text-1", "cr-1", "text-2", "cr-2", "text-3"])
        // Task.sleep guarantees at least the requested interval, so lower bounds are stable; a small
        // epsilon absorbs clock-capture jitter around the write itself.
        let minimumGap: Duration = .milliseconds(45)
        XCTAssertGreaterThanOrEqual(recorded[0].at.duration(to: recorded[1].at), minimumGap, "the CR must trail the text it submits")
        XCTAssertGreaterThanOrEqual(recorded[1].at.duration(to: recorded[2].at), minimumGap, "the write after a CR must be held back")
        XCTAssertGreaterThanOrEqual(recorded[2].at.duration(to: recorded[3].at), minimumGap, "the second CR must trail its text")
        XCTAssertGreaterThanOrEqual(recorded[3].at.duration(to: recorded[4].at), minimumGap, "the write after the second CR must be held back")
    }

    func testPlainWritesRunBackToBackWithoutArtificialSpacing() async {
        let sequencer = TerminalControlInputSequencer(separation: .milliseconds(200))
        let recorder = WriteRecorder()
        let drained = expectation(description: "all writes ran")

        let start = ContinuousClock.now
        sequencer.enqueueWrite { recorder.record("a") }
        sequencer.enqueueWrite { recorder.record("b") }
        sequencer.enqueueWrite {
            recorder.record("c")
            drained.fulfill()
        }

        await fulfillment(of: [drained], timeout: 10)

        XCTAssertEqual(recorder.recorded.map(\.label), ["a", "b", "c"])
        XCTAssertLessThan(start.duration(to: recorder.recorded[2].at), .milliseconds(150), "plain writes must not inherit submit spacing")
    }
}
