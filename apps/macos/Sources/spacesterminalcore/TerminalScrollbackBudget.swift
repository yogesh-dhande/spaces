public enum TerminalScrollbackBudget {
    /// Matches Ghostty's default `scrollback-limit`, which is measured in bytes.
    public static let defaultMaxBytes = 10_000_000

    /// Head-truncation trigger for the durable `output.log` transcript. A long-running, chatty session
    /// (build watcher, `tail -f`, verbose agent) appends output for its whole life, so the transcript is
    /// bounded to a small multiple of the scrollback budget instead of growing without bound. The bound is
    /// a multiple, not exactly the budget, so trimming is rare (once per budget-worth of new output) and so
    /// every transcript consumer keeps a full budget of history with headroom: `terminalTail`,
    /// `terminalTranscript` (ended-pane scrollback replay), and daemon handoff resume all read an
    /// end-relative suffix no larger than `defaultMaxBytes`.
    public static let liveTranscriptTrimTriggerBytes = defaultMaxBytes * 3

    /// Bytes of the newest transcript kept after a head-truncation. Strictly greater than
    /// `defaultMaxBytes`, so a trim only ever drops bytes older than every consumer's budget.
    public static let liveTranscriptRetainedBytes = defaultMaxBytes * 2
}
