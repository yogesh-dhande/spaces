import Foundation

/// Converts between a cell in a terminal grid and the normalized position that names it on the wire.
///
/// This is the shared arithmetic behind the coordinate contract documented on
/// ``TerminalControlMouseButtonPayload``: a client encodes the cell it clicked with ``center(column:row:columns:rows:)``
/// and a session host decodes it with ``cell(x:y:columns:rows:)``. A center is the one position inside a
/// cell that survives the round trip whatever the host's own pixel geometry is; an edge coordinate floors
/// into the neighbouring column or row.
public enum TerminalPointerGrid {
    /// The normalized position naming `column`/`row` in a grid of `columns` x `rows`: the center of that cell.
    public static func center(column: Int, row: Int, columns: Int, rows: Int) -> (x: Double, y: Double) {
        let columns = max(columns, 1)
        let rows = max(rows, 1)
        let cell = self.cell(column: column, row: row, columns: columns, rows: rows)
        return (x: (Double(cell.column) + 0.5) / Double(columns), y: (Double(cell.row) + 0.5) / Double(rows))
    }

    /// The cell a normalized position names in a grid of `columns` x `rows`. A position on a boundary
    /// belongs to the cell that starts there, and one outside the grid clamps to its nearest edge cell.
    public static func cell(x: Double, y: Double, columns: Int, rows: Int) -> (column: Int, row: Int) {
        let columns = max(columns, 1)
        let rows = max(rows, 1)
        let column = Int((min(max(x, 0), 1) * Double(columns)).rounded(.down))
        let row = Int((min(max(y, 0), 1) * Double(rows)).rounded(.down))
        return cell(column: column, row: row, columns: columns, rows: rows)
    }

    private static func cell(column: Int, row: Int, columns: Int, rows: Int) -> (column: Int, row: Int) {
        (column: min(max(column, 0), columns - 1), row: min(max(row, 0), rows - 1))
    }
}
