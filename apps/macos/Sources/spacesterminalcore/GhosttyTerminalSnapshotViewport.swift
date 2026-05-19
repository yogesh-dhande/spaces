import Foundation

public enum GhosttyTerminalSnapshotViewport {
    public struct Window: Sendable, Equatable {
        public let columnOffset: Int
        public let rowOffset: Int
        public let columns: Int
        public let rows: Int

        public init(columnOffset: Int, rowOffset: Int, columns: Int, rows: Int) {
            self.columnOffset = columnOffset
            self.rowOffset = rowOffset
            self.columns = columns
            self.rows = rows
        }
    }

    public static func crop(_ snapshot: GhosttyTerminalSnapshot, columns: Int, rows: Int) -> GhosttyTerminalSnapshot {
        let window = window(for: snapshot, columns: columns, rows: rows)
        guard window.columns != snapshot.columns || window.rows != snapshot.rows || window.columnOffset != 0 || window.rowOffset != 0 else {
            return snapshot
        }

        var cells: [GhosttyTerminalSnapshot.Cell] = []
        cells.reserveCapacity(window.columns * window.rows)
        for row in 0..<window.rows {
            let sourceRow = window.rowOffset + row
            let rowOffset = sourceRow * snapshot.columns
            let sourceStart = rowOffset + window.columnOffset
            let sourceEnd = sourceStart + window.columns
            cells.append(contentsOf: snapshot.cells[sourceStart..<sourceEnd])
        }

        return GhosttyTerminalSnapshot(
            columns: window.columns, rows: window.rows,
            cursorColumn: min(max(snapshot.cursorColumn - window.columnOffset, 0), max(window.columns - 1, 0)),
            cursorRow: min(max(snapshot.cursorRow - window.rowOffset, 0), max(window.rows - 1, 0)),
            cursorVisible: snapshot.cursorVisible && snapshot.cursorColumn >= window.columnOffset
                && snapshot.cursorColumn < window.columnOffset + window.columns && snapshot.cursorRow >= window.rowOffset
                && snapshot.cursorRow < window.rowOffset + window.rows, defaultForegroundRGB: snapshot.defaultForegroundRGB,
            defaultBackgroundRGB: snapshot.defaultBackgroundRGB, cells: cells)
    }

    public static func window(for snapshot: GhosttyTerminalSnapshot, columns: Int, rows: Int) -> Window {
        let resolvedColumns = min(max(columns, 1), max(snapshot.columns, 1))
        let resolvedRows = min(max(rows, 1), max(snapshot.rows, 1))

        return Window(
            columnOffset: viewportOffset(
                cursor: snapshot.cursorColumn, viewport: resolvedColumns, content: snapshot.columns, trailingContext: max(2, resolvedColumns / 5)),
            rowOffset: viewportOffset(
                cursor: snapshot.cursorRow, viewport: resolvedRows, content: snapshot.rows, trailingContext: min(max(1, resolvedRows / 8), 2)),
            columns: resolvedColumns, rows: resolvedRows)
    }

    private static func viewportOffset(cursor: Int, viewport: Int, content: Int, trailingContext: Int) -> Int {
        guard content > viewport else { return 0 }
        let clampedCursor = min(max(cursor, 0), max(content - 1, 0))
        if clampedCursor < viewport { return 0 }
        let preferredCursorPosition = max(viewport - trailingContext - 1, 0)
        let proposedOffset = clampedCursor - preferredCursorPosition
        return min(max(proposedOffset, 0), max(content - viewport, 0))
    }
}
