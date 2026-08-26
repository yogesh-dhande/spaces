import Foundation
import XCTest

@testable import spacesterminalcore

/// Contract coverage for the control-input sequencer: writes run strictly in enqueue order, a framed
/// submit carries no artificial pacing, an unframed submit's carriage return is spaced from the text
/// before it and the write after it, every enqueue's acknowledgement reports what the writes reached,
/// and `drain()` waits for the whole outstanding chain.
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
    /// between them, or two submissions merge into one line with a stray Enter — the ordering the
    /// sequencer exists to guarantee on both submit paths (framed-immediate and separated). This
    /// enqueues two submits back-to-back the way the daemon's notification flush delivers queued
    /// lines, plus a following write, and pins the exact interleaving.
    func testSubmitPairsStayAdjacentAcrossBackToBackSends() async {
        let sequencer = TerminalControlInputSequencer()
        let recorder = WriteRecorder()
        let drained = expectation(description: "all writes ran")

        sequencer.enqueueSubmit(
            writeText: {
                recorder.record("text-1")
                return .written(framed: true)
            },
            writeCarriageReturn: {
                recorder.record("cr-1")
                return .delivered
            })
        sequencer.enqueueSubmit(
            writeText: {
                recorder.record("text-2")
                return .written(framed: true)
            },
            writeCarriageReturn: {
                recorder.record("cr-2")
                return .delivered
            })
        sequencer.enqueueWrite {
            recorder.record("text-3")
            drained.fulfill()
            return .delivered
        }

        await fulfillment(of: [drained], timeout: 10)

        XCTAssertEqual(recorder.recorded.map(\.label), ["text-1", "cr-1", "text-2", "cr-2", "text-3"])
    }

    /// The framed-submit path (bracketed paste on, CR enqueued as a plain write) pays no pacing cost:
    /// a text+CR pair, and a second submit right behind it, must all land promptly rather than each
    /// waiting out a fixed interval (issue #389 — a lone submit cost ~500ms and back-to-back submits
    /// ~1s before the shell even saw the newline).
    func testSubmitWritesRunWithoutArtificialPacing() async {
        let sequencer = TerminalControlInputSequencer()
        let recorder = WriteRecorder()
        let drained = expectation(description: "both submits ran")

        let start = ContinuousClock.now
        sequencer.enqueueSubmit(
            writeText: {
                recorder.record("text-1")
                return .written(framed: true)
            },
            writeCarriageReturn: {
                recorder.record("cr-1")
                return .delivered
            })
        sequencer.enqueueSubmit(
            writeText: {
                recorder.record("text-2")
                return .written(framed: true)
            },
            writeCarriageReturn: {
                recorder.record("cr-2")
                drained.fulfill()
                return .delivered
            })

        await fulfillment(of: [drained], timeout: 10)

        let recorded = recorder.recorded
        XCTAssertEqual(recorded.map(\.label), ["text-1", "cr-1", "text-2", "cr-2"])
        XCTAssertLessThan(start.duration(to: recorded[3].at), .milliseconds(150), "two submit pairs must not pay a fixed per-submit pacing interval")
    }

    /// An unframed submit's CR (bracketed paste off, so no paste frame protects it) must be spaced from
    /// the text write before it AND hold back the write after it by the separation interval, keeping the
    /// CR a lone PTY read burst on both sides (issue #187). Ordering across the delay is part of the
    /// contract: a write enqueued while the CR is still sleeping must run after it, never jump ahead.
    /// The framing comes from the text write itself, which is what keeps the pacing bound to the bytes
    /// that actually went out.
    func testSeparatedSubmitCarriageReturnSpacesBothSides() async {
        let separation: Duration = .milliseconds(120)
        let sequencer = TerminalControlInputSequencer(separation: separation)
        let recorder = WriteRecorder()
        let drained = expectation(description: "all writes ran")

        sequencer.enqueueSubmit(
            writeText: {
                recorder.record("text")
                return .written(framed: false)
            },
            writeCarriageReturn: {
                recorder.record("cr")
                return .delivered
            })
        sequencer.enqueueWrite {
            recorder.record("next")
            drained.fulfill()
            return .delivered
        }

        await fulfillment(of: [drained], timeout: 10)

        let recorded = recorder.recorded
        XCTAssertEqual(recorded.map(\.label), ["text", "cr", "next"])
        XCTAssertGreaterThanOrEqual(
            recorded[0].at.duration(to: recorded[1].at), separation, "an unframed submit's CR must wait out the separation after its text")
        XCTAssertGreaterThanOrEqual(
            recorded[1].at.duration(to: recorded[2].at), separation, "the write after an unframed submit's CR must be held back by the separation")
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
            return .delivered
        }
        sequencer.enqueueWrite {
            try? await Task.sleep(for: .milliseconds(100), clock: .continuous)
            recorder.record("cr")
            return .delivered
        }

        await sequencer.drain()

        // No polling: both writes must already have run because drain awaited the whole chain.
        XCTAssertEqual(recorder.recorded.map(\.label), ["text", "cr"], "drain() returned before the queued submit writes ran")
    }

    /// The acknowledgement is the whole point of the send contract: it must not resolve until the writes
    /// have actually run, so a caller that waits on it (the daemon's send path, a session's control
    /// socket) reports a write rather than an enqueue.
    func testSubmitAcknowledgementResolvesOnlyAfterBothWritesRan() async {
        let sequencer = TerminalControlInputSequencer()
        let recorder = WriteRecorder()

        let acknowledgement = sequencer.enqueueSubmit(
            writeText: {
                try? await Task.sleep(for: .milliseconds(80), clock: .continuous)
                recorder.record("text")
                return .written(framed: true)
            },
            writeCarriageReturn: {
                try? await Task.sleep(for: .milliseconds(80), clock: .continuous)
                recorder.record("cr")
                return .delivered
            })

        let outcome = await Task.detached { acknowledgement.wait(timeout: .seconds(10)) }.value

        XCTAssertEqual(outcome, .delivered)
        XCTAssertEqual(recorder.recorded.map(\.label), ["text", "cr"], "the acknowledgement resolved before the submit's writes ran")
    }

    /// A submit whose text never reached the PTY — the session was torn down between enqueue and write —
    /// fails the whole send and writes no carriage return: there is nothing in the composer to submit.
    func testSubmitWhoseTextIsNotDeliveredFailsAndSkipsItsCarriageReturn() async {
        let sequencer = TerminalControlInputSequencer()
        let recorder = WriteRecorder()

        let acknowledgement = sequencer.enqueueSubmit(
            writeText: {
                recorder.record("text")
                return .notDelivered
            },
            writeCarriageReturn: {
                recorder.record("cr")
                return .delivered
            })

        let outcome = await Task.detached { acknowledgement.wait(timeout: .seconds(10)) }.value

        XCTAssertEqual(outcome, .notDelivered)
        XCTAssertEqual(recorder.recorded.map(\.label), ["text"], "a submit whose text went nowhere must not send its carriage return")
    }

    /// A plain write reports its own outcome the same way, so a send to a session that has lost its
    /// surface is a failure rather than a silent no-op.
    func testPlainWriteAcknowledgementCarriesTheWriteOutcome() async {
        let sequencer = TerminalControlInputSequencer()

        let acknowledgement = sequencer.enqueueWrite { .notDelivered }
        let outcome = await Task.detached { acknowledgement.wait(timeout: .seconds(10)) }.value

        XCTAssertEqual(outcome, .notDelivered)
    }
}
