public enum TerminalScrollbackBudget {
    /// Matches Ghostty's default `scrollback-limit`, which is measured in bytes.
    public static let defaultMaxBytes = 10_000_000

    /// The transcript a client prefetches for its client-local scrollback replay right after a session's
    /// first paint, on the phone and on the Mac alike. It is a first cut, not a tuned number: it holds
    /// roughly sixteen thousand lines of typical shell output, which covers nearly every scroll a user
    /// actually makes, and it costs a fraction of the budget-sized read in bytes on the wire and in
    /// daemon-side replay. Reaching the top of that replay fetches the whole `defaultMaxBytes` budget once.
    public static let initialLocalScrollbackPageBytes = 1_000_000

    /// Head-truncation trigger for the durable `output.log` transcript. A long-running, chatty session
    /// (build watcher, `tail -f`, verbose agent) appends output for its whole life, so the transcript is
    /// bounded to a small multiple of the scrollback budget instead of growing without bound. The bound is
    /// a multiple, not exactly the budget, so trimming is rare (once per budget-worth of new output) and so
    /// every transcript consumer keeps a full budget of history with headroom: `terminalTail`,
    /// `terminalTranscript` (client-local scrollback replay), and daemon handoff resume all read an
    /// end-relative suffix no larger than `defaultMaxBytes`.
    public static let liveTranscriptTrimTriggerBytes = defaultMaxBytes * 3

    /// Bytes of the newest transcript kept after a head-truncation. Strictly greater than
    /// `defaultMaxBytes`, so a trim only ever drops bytes older than every consumer's budget.
    public static let liveTranscriptRetainedBytes = defaultMaxBytes * 2
}
