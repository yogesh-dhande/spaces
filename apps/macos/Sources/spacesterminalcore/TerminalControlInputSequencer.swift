import Foundation

/// Serializes a terminal session's control-request input writes and enforces the temporal spacing
/// that makes a submit-style send's trailing carriage return read as a distinct Enter keystroke.
///
/// Agent TUIs (Claude Code, Codex, OpenCode) group bytes that arrive in one PTY read burst into a
/// paste: text immediately followed by its CR stays unsubmitted in the composer, and a CR immediately
/// followed by the next send's text merges two submissions into one. So a submit CR is written
/// `separation` after the text it submits AND holds back whatever write follows it by the same
/// interval, keeping the CR a lone burst on both sides. Every control-request input write funnels
/// through one sequencer per session in enqueue order; callers all run on the main actor, so a text+CR
/// pair enqueues atomically and a later request's bytes can never land between them. (A plain
/// `asyncAfter` of the CR on the session's control queue cannot give this guarantee — it does not hold
/// a FIFO slot, so writes submitted during the delay would jump ahead of the pending CR and merge
/// submissions.)
///
/// `separation` is sized for the slowest composer among the supported agent TUIs, not the fastest:
/// Claude Code and Codex read a lone CR burst as a distinct Enter keystroke at a much shorter gap, but
/// OpenCode's composer needs materially more room before it reliably reads the CR as its own keystroke
/// rather than folding it into the preceding paste-like burst (issue #187 — `terminal send text
/// --submit` left OpenCode's composer holding the unsubmitted prompt at the previous, shorter gap).
/// Widening it is safe for every consumer of this sequencer — the interactive "Enter" button and the
/// orchestration/notification send paths all go through this same chokepoint — and it stays well under
/// the threshold where a human click would perceive lag.
public final class TerminalControlInputSequencer: @unchecked Sendable {
    private let queue = TerminalInputSerialQueue()
    private let lock = NSLock()
    private let separation: Duration
    /// Earliest instant the next write may run; set by a submit CR write. Guarded by `lock`.
    private var earliestNextWrite: ContinuousClock.Instant?

    public init(separation: Duration = .milliseconds(500)) { self.separation = separation }

    /// Enqueues an input write, ordered after everything already enqueued and held back until a
    /// preceding submit CR's trailing separation has elapsed.
    public func enqueueWrite(_ write: @escaping @Sendable () async -> Void) {
        queue.enqueue {
            if let earliest = self.takeEarliestNextWrite() { try? await Task.sleep(until: earliest, clock: .continuous) }
            await write()
        }
    }

    /// Enqueues a submit carriage return, separated from the write before it (the text it submits)
    /// and from the write after it by `separation`.
    public func enqueueSubmitCarriageReturn(_ write: @escaping @Sendable () async -> Void) {
        queue.enqueue {
            try? await Task.sleep(for: self.separation, clock: .continuous)
            await write()
            self.setEarliestNextWrite(.now.advanced(by: self.separation))
        }
    }

    /// Suspends until every write enqueued so far has run — including a pending submit CR held back by
    /// its `separation` delay — so a handoff `execv` cannot destroy the sequencer with an unwritten CR (or
    /// the whole submitted line) still queued. Callers first stop accepting new input (the control server
    /// is stopped before quiesce drains), so the chain this awaits is bounded by the outstanding writes
    /// plus at most one `separation` interval.
    public func drain() async { await queue.drain() }

    private func takeEarliestNextWrite() -> ContinuousClock.Instant? {
        lock.lock()
        defer { lock.unlock() }
        let value = earliestNextWrite
        earliestNextWrite = nil
        return value
    }

    private func setEarliestNextWrite(_ instant: ContinuousClock.Instant) {
        lock.lock()
        earliestNextWrite = instant
        lock.unlock()
    }
}
