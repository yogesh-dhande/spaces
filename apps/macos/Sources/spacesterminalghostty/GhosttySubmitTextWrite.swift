#if canImport(AppKit) && canImport(GhosttyKit)
    import Foundation
    import spacesterminalcore

    /// What one engine-isolated submit-text step produced on the embedded (macOS) path: the framing
    /// ghostty's paste encoder used, and the host-PTY writes that call emitted.
    ///
    /// The two travel together because they are decided together and consumed apart: the framing paces the
    /// carriage return, while the writes are awaited off the terminal engine actor (they run on it) to turn
    /// the send into an answer about bytes at the PTY. `TerminalSubmitTextWriteOutcome` is what the
    /// sequencer finally sees, after that wait.
    enum GhosttySubmitTextWrite {
        case written(framed: Bool, writes: TerminalInputWriteBatch)
        case notDelivered
    }
#endif
