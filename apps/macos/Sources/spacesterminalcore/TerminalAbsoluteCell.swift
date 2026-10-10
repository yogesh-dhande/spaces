import Foundation

/// A grid cell named by absolute row: the row number a host's terminal gave the text when it was
/// written (`GhosttyTerminalSnapshot.historyRowBase` plus the viewport row), which keeps naming that text
/// as output scrolls and prunes. Only comparable between cells of one history epoch.
///
/// Rows are signed so a row relative to a frame's base (negative above the viewport) is plain
/// subtraction.
public struct TerminalAbsoluteCell: Hashable, Comparable, Sendable {
    public var column: Int
    public var row: Int64

    public init(column: Int, row: Int64) {
        self.column = column
        self.row = row
    }

    /// Reading order: by row, then by column.
    public static func < (lhs: TerminalAbsoluteCell, rhs: TerminalAbsoluteCell) -> Bool {
        lhs.row != rhs.row ? lhs.row < rhs.row : lhs.column < rhs.column
    }
}
