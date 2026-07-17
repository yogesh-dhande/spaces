import Foundation

/// Serializes a terminal session's control-request input writes and enforces the temporal spacing
/// that makes a submit-style send's trailing carriage return read as a distinct Enter keystroke.
///
/// Agent TUIs (Claude Code, Codex) group bytes that arrive in one PTY read burst into a paste: text
/// immediately followed by its CR stays unsubmitted in the composer, and a CR immediately followed by
/// the next send's text merges two submissions into one. So a submit CR is written `separation` after
/// the text it submits AND holds back whatever write follows it by the same interval, keeping the CR a
/// lone burst on both sides. Every control-request input write funnels through one sequencer per
/// session in enqueue order; callers all run on the main actor, so a text+CR pair enqueues atomically
/// and a later request's bytes can never land between them. (A plain `asyncAfter` of the CR on the
/// session's control queue cannot give this guarantee — it does not hold a FIFO slot, so writes
/// submitted during the delay would jump ahead of the pending CR and merge submissions.)
public final class TerminalControlInputSequencer: @unchecked Sendable {
    private let queue = TerminalInputSerialQueue()
    private let lock = NSLock()
    private let separation: Duration
    /// Earliest instant the next write may run; set by a submit CR write. Guarded by `lock`.
    private var earliestNextWrite: ContinuousClock.Instant?

    public init(separation: Duration = .milliseconds(100)) { self.separation = separation }

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
