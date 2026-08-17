import Foundation

public enum GhosttyTerminalSnapshotViewport {
    public enum HorizontalAlignment: Sendable, Equatable {
        case leading
        case followCursor
    }

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

    public static func crop(_ snapshot: GhosttyTerminalSnapshot, columns: Int, rows: Int, horizontalAlignment: HorizontalAlignment = .followCursor)
        -> GhosttyTerminalSnapshot
    {
        let window = window(for: snapshot, columns: columns, rows: rows, horizontalAlignment: horizontalAlignment)
        return crop(snapshot, window: window)
    }

    /// Whether `window` shows `snapshot` whole, which is exactly the condition under which ``crop(_:window:)``
    /// hands the snapshot back untouched.
    ///
    /// Callers use this to tell a displayed frame that still is the host's grid from one that is a slice of
    /// it. That distinction matters beyond rendering: soft-wrap metadata is carried per cell, so a cropped
    /// frame keeps each row's "wraps into the next row" bit while the columns the crop dropped are gone, and
    /// anything that reassembles a logical line from such a frame reads a line that was never on screen.
    public static func covers(_ snapshot: GhosttyTerminalSnapshot, window: Window) -> Bool {
        window.columnOffset == 0 && window.rowOffset == 0 && window.columns == snapshot.columns && window.rows == snapshot.rows
    }

    public static func crop(_ snapshot: GhosttyTerminalSnapshot, window: Window) -> GhosttyTerminalSnapshot {
        guard !covers(snapshot, window: window) else { return snapshot }

        let columnOffset = min(max(window.columnOffset, 0), max(snapshot.columns - 1, 0))
        let rowOffset = min(max(window.rowOffset, 0), max(snapshot.rows - 1, 0))
        let columns = min(max(window.columns, 1), max(snapshot.columns - columnOffset, 1))
        let rows = min(max(window.rows, 1), max(snapshot.rows - rowOffset, 1))
        var cells: [GhosttyTerminalSnapshot.Cell] = []
        cells.reserveCapacity(columns * rows)
        for row in 0..<rows {
            let sourceRow = rowOffset + row
            let rowOffset = sourceRow * snapshot.columns
            let sourceStart = rowOffset + columnOffset
            let sourceEnd = sourceStart + columns
            cells.append(contentsOf: snapshot.cells[sourceStart..<sourceEnd])
        }

        return GhosttyTerminalSnapshot(
            columns: columns, rows: rows, cursorColumn: min(max(snapshot.cursorColumn - columnOffset, 0), max(columns - 1, 0)),
            cursorRow: min(max(snapshot.cursorRow - rowOffset, 0), max(rows - 1, 0)),
            cursorVisible: snapshot.cursorVisible && snapshot.cursorColumn >= columnOffset && snapshot.cursorColumn < columnOffset + columns
                && snapshot.cursorRow >= rowOffset && snapshot.cursorRow < rowOffset + rows, defaultForegroundRGB: snapshot.defaultForegroundRGB,
            defaultBackgroundRGB: snapshot.defaultBackgroundRGB, cells: cells,
            clusters: croppedCellText(
                snapshot.clusters, sourceColumns: snapshot.columns, columnOffset: columnOffset, rowOffset: rowOffset, columns: columns, rows: rows),
            linkURLs: croppedCellText(
                snapshot.linkURLs, sourceColumns: snapshot.columns, columnOffset: columnOffset, rowOffset: rowOffset, columns: columns, rows: rows),
            mouseReportingActive: snapshot.mouseReportingActive, mouseShiftCapture: snapshot.mouseShiftCapture)
    }

    /// Rebases a cell-text table into the cropped grid's coordinates, dropping entries for cells the crop
    /// leaves out. Walking the entries rather than the cells keeps a crop of a plain-text frame free.
    private static func croppedCellText(_ table: [Int: String], sourceColumns: Int, columnOffset: Int, rowOffset: Int, columns: Int, rows: Int)
        -> [Int: String]
    {
        guard !table.isEmpty, sourceColumns > 0 else { return [:] }
        var cropped: [Int: String] = [:]
        for (sourceIndex, text) in table {
            let row = sourceIndex / sourceColumns - rowOffset
            let column = sourceIndex % sourceColumns - columnOffset
            guard row >= 0, row < rows, column >= 0, column < columns else { continue }
            cropped[row * columns + column] = text
        }
        return cropped
    }

    public static func window(
        for snapshot: GhosttyTerminalSnapshot, columns: Int, rows: Int, horizontalAlignment: HorizontalAlignment = .followCursor
    ) -> Window {
        let resolvedColumns = min(max(columns, 1), max(snapshot.columns, 1))
        let resolvedRows = min(max(rows, 1), max(snapshot.rows, 1))

        let columnOffset: Int
        switch horizontalAlignment {
        case .leading: columnOffset = 0
        case .followCursor:
            columnOffset = viewportOffset(
                cursor: snapshot.cursorColumn, viewport: resolvedColumns, content: snapshot.columns, trailingContext: max(2, resolvedColumns / 5))
        }

        return Window(
            columnOffset: columnOffset,
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
