import Foundation

/// Serializes a terminal session's control-request input writes so a submit-style send's text and the
/// carriage return that submits it reach the PTY as one ordered pair — and, when the text went out
/// unframed, restores the temporal spacing that keeps that CR a distinct Enter keystroke.
///
/// Agent TUIs (Claude Code, Codex, OpenCode) group bytes that arrive in one PTY read burst into a paste,
/// so a submit's text has to be distinguishable from its Enter. The send chokepoints
/// (`GhosttyEmbeddedSessionHost`, `GhosttyLinuxHeadlessSessionCore`) make that distinction structural
/// whenever the running application enabled bracketed paste (DECSET 2004): the text goes in through
/// ghostty's paste encoder framed by paste markers, the frame closes before the CR arrives, and neither
/// write needs to be delayed. When the application has NOT enabled bracketed paste — an agent TUI still
/// initializing right after a detection-based spawn, or a plain byte reader — the paste encoder emits
/// the text unframed, and only time can keep the CR out of the text's read burst. For that case the
/// chokepoints enqueue the CR through `enqueueSubmitCarriageReturn`, which spaces it `separation` after
/// the text AND holds the next write back by the same interval, keeping the CR a lone burst on both
/// sides.
///
/// `separation` is sized for the slowest composer among the supported agent TUIs, not the fastest:
/// Claude Code and Codex read a lone CR burst as a distinct Enter keystroke at a much shorter gap, but
/// OpenCode's composer needs materially more room before it reliably reads the CR as its own keystroke
/// rather than folding it into the preceding paste-like burst (issue #187).
///
/// What this type always guarantees is ordering. Every control-request input write (send
/// text/bytes/paste, key) for a session funnels through one sequencer in enqueue order, so a later
/// request's bytes can never land between a submit's text and its CR and merge two submissions into one
/// line. Callers all run on the main actor, so a text+CR pair claims two adjacent FIFO slots atomically.
/// (A plain `asyncAfter` of the CR could not give this guarantee — it does not hold a FIFO slot, so
/// writes submitted during the delay would jump ahead of the pending CR.)
public final class TerminalControlInputSequencer: @unchecked Sendable {
    private let queue = TerminalInputSerialQueue()
    private let lock = NSLock()
    private let separation: Duration
    /// Earliest instant the next write may run; set by a separated submit CR write. Guarded by `lock`.
    private var earliestNextWrite: ContinuousClock.Instant?

    public init(separation: Duration = .milliseconds(500)) { self.separation = separation }

    /// Enqueues an input write, ordered after everything already enqueued and held back until a
    /// preceding separated submit CR's trailing separation has elapsed.
    public func enqueueWrite(_ write: @escaping @Sendable () async -> Void) {
        queue.enqueue {
            if let earliest = self.takeEarliestNextWrite() { try? await Task.sleep(until: earliest, clock: .continuous) }
            await write()
        }
    }

    /// Enqueues an unframed submit's carriage return, separated from the write before it (the text it
    /// submits) and from the write after it by `separation`. Framed submits never need this — their CR
    /// goes through `enqueueWrite`.
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
    /// plus at most one `separation` interval per unframed submit.
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
