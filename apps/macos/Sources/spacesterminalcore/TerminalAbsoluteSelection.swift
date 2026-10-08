import Foundation

/// A selection a client holds itself, in absolute rows, so it follows its text as output scrolls it up
/// and into the client's own scrollback replay. `historyEpoch` names the row numbering the rows belong
/// to; a frame or replay in another epoch renumbered its rows, and the selection does not apply to it.
public struct TerminalAbsoluteSelection: Hashable, Sendable {
    /// First cell in document order. A rectangle's `start` is its top-left corner.
    public let start: TerminalAbsoluteCell
    /// Last cell in document order. A rectangle's `end` is its bottom-right corner.
    public let end: TerminalAbsoluteCell
    public let isRectangle: Bool
    public let historyEpoch: UInt64

    /// Orders the two ends. A stream selection orders them in reading order. A rectangle orders its rows
    /// and normalizes its columns to the min/max band, since reading order cannot order the columns of a
    /// block dragged toward the left.
    public init(from first: TerminalAbsoluteCell, to second: TerminalAbsoluteCell, isRectangle: Bool, historyEpoch: UInt64) {
        if isRectangle {
            start = TerminalAbsoluteCell(column: min(first.column, second.column), row: min(first.row, second.row))
            end = TerminalAbsoluteCell(column: max(first.column, second.column), row: max(first.row, second.row))
        } else {
            start = min(first, second)
            end = max(first, second)
        }
        self.isRectangle = isRectangle
        self.historyEpoch = historyEpoch
    }

    /// The part of this selection a frame shows, in the frame's viewport coordinates. Nil when the frame
    /// is in another epoch or the selection lies wholly outside its rows.
    public func projection(onto snapshot: GhosttyTerminalSnapshot) -> GhosttyTerminalSelectionRange? {
        guard snapshot.historyEpoch == historyEpoch else { return nil }
        return GhosttyTerminalSelectionProjection.project(
            startColumn: UInt16(clamping: max(start.column, 0)), startRow: start.row, endColumn: UInt16(clamping: max(end.column, 0)),
            endRow: end.row, isRectangle: isRectangle, viewportRowOffset: Int64(clamping: snapshot.historyRowBase), columns: snapshot.columns,
            rows: snapshot.rows)
    }
}
