import Foundation

/// Serializes a terminal session's control-request input writes so a submit-style send's text and the
/// carriage return that submits it reach the PTY as one ordered, uninterrupted pair.
///
/// Agent TUIs (Claude Code, Codex, OpenCode) group bytes that arrive in one PTY read burst into a paste,
/// so a submit's text has to be distinguishable from its Enter. The send chokepoints
/// (`GhosttyEmbeddedSessionHost`, `GhosttyLinuxHeadlessSessionCore`) make that distinction structural:
/// the text goes in through ghostty's paste encoder — bracketed-paste framed when the application
/// enabled DECSET 2004, plain text otherwise — and the CR follows as its own write. The framing is what
/// makes the CR read as a distinct Enter keystroke, so neither write needs to be delayed.
///
/// What this type guarantees is ordering. Every control-request input write (send text/bytes/paste, key)
/// for a session funnels through one sequencer in enqueue order, so a later request's bytes can never
/// land between a submit's text and its CR and merge two submissions into one line. Callers all run on
/// the main actor, so a text+CR pair claims two adjacent FIFO slots atomically.
public final class TerminalControlInputSequencer: @unchecked Sendable {
    private let queue = TerminalInputSerialQueue()

    public init() {}

    /// Enqueues an input write, ordered after everything already enqueued.
    public func enqueueWrite(_ write: @escaping @Sendable () async -> Void) { queue.enqueue { await write() } }

    /// Suspends until every write enqueued so far has run — including a submit's trailing CR — so a
    /// handoff `execv` cannot destroy the sequencer with an unwritten CR (or the whole submitted line)
    /// still queued. Callers first stop accepting new input (the control server is stopped before
    /// quiesce drains), so the chain this awaits is bounded by the outstanding writes themselves.
    public func drain() async { await queue.drain() }
}
