/// A client-local replay's scrollbar: how many rows it holds, where its viewport sits within them, and
/// how many rows that viewport shows. Row 0 is the oldest row the replay holds, which is only as old as
/// the transcript bytes the replay was built from, never the whole session's history.
public struct TerminalScrollbackReplayScrollbar: Equatable, Sendable {
    public let total: Int
    public let offset: Int
    public let rows: Int

    public init(total: Int, offset: Int, rows: Int) {
        self.total = total
        self.offset = offset
        self.rows = rows
    }
}
