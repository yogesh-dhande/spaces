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
    public static func covers(_ snapshot: GhosttyTerminalSnapshot, window: Window) -> Bool {
        coversColumns(snapshot, window: window) && window.rowOffset == 0 && window.rows == snapshot.rows
    }

    /// Whether `window` keeps every row it shows at its full width.
    ///
    /// This is the axis that decides whether a logical line can be read back out of a displayed frame.
    /// Soft-wrap metadata is carried per cell, so a column crop keeps each row's "wraps into the next row"
    /// bit while the columns past the window are gone, and anything that reassembles a wrapped line from
    /// such a frame reads a line that was never on screen: each row's visible slice, concatenated. A row
    /// window drops whole rows instead, which leaves the rows it does show intact.
    public static func coversColumns(_ snapshot: GhosttyTerminalSnapshot, window: Window) -> Bool {
        window.columnOffset == 0 && window.columns == snapshot.columns
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
            mouseReportingActive: snapshot.mouseReportingActive, mouseShiftCapture: snapshot.mouseShiftCapture,
            selection: croppedSelection(
                snapshot.selection, sourceColumns: snapshot.columns, columnOffset: columnOffset, rowOffset: rowOffset, columns: columns, rows: rows),
            scrollbarTotal: snapshot.scrollbarTotal, scrollbarOffset: snapshot.scrollbarOffset + UInt32(rowOffset))
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

    /// Rebases the shared selection into the cropped grid, the same way `croppedCellText` rebases the
    /// per-cell text tables: an entry entirely outside the window disappears, and one that straddles a
    /// window edge is clamped to it with the extends flags recording what got cut off.
    ///
    /// A stream (non-rectangle) selection carries only one column range per end, because every row
    /// strictly between `startRow` and `endRow` is implicitly selected full width by convention: the
    /// struct has no per-row ranges to crop. That means a boundary row's occupied columns depend on
    /// whether it is still the selection's true start/end row after cropping or an interior row this
    /// crop exposes for the first time, which is the same test the extends flags already need.
    private static func croppedSelection(
        _ selection: GhosttyTerminalSelectionRange?, sourceColumns: Int, columnOffset: Int, rowOffset: Int, columns: Int, rows: Int
    ) -> GhosttyTerminalSelectionRange? {
        guard let selection else { return nil }
        let originalStartRow = Int(selection.startRow)
        let originalEndRow = Int(selection.endRow)
        let originalStartColumn = Int(selection.startColumn)
        let originalEndColumn = Int(selection.endColumn)

        let windowRowStart = rowOffset
        let windowRowEnd = rowOffset + rows - 1
        let windowColumnStart = columnOffset
        let windowColumnEnd = columnOffset + columns - 1

        var overlapRowStart = max(originalStartRow, windowRowStart)
        var overlapRowEnd = min(originalEndRow, windowRowEnd)
        guard overlapRowStart <= overlapRowEnd else { return nil }

        let clippedAbove = originalStartRow < windowRowStart
        let clippedBelow = originalEndRow > windowRowEnd

        if selection.isRectangle {
            let overlapColumnStart = max(originalStartColumn, windowColumnStart)
            let overlapColumnEnd = min(originalEndColumn, windowColumnEnd)
            guard overlapColumnStart <= overlapColumnEnd else { return nil }
            return GhosttyTerminalSelectionRange(
                startColumn: UInt16(overlapColumnStart - windowColumnStart), startRow: UInt16(overlapRowStart - windowRowStart),
                endColumn: UInt16(overlapColumnEnd - windowColumnStart), endRow: UInt16(overlapRowEnd - windowRowStart), isRectangle: true,
                extendsAbove: selection.extendsAbove || clippedAbove, extendsBelow: selection.extendsBelow || clippedBelow)
        }

        // A surviving row's own occupied columns only cover the window when it is a true boundary row
        // that the row crop didn't already clip: an interior row is full width by convention, but a
        // boundary row that survived the row crop can still miss the column window entirely (e.g. the
        // start row's text sits to the right of a narrow leading window). Trim such a row away before
        // assuming any surviving row intersects the window.
        var startRowTrimmed = false
        var endRowTrimmed = false
        if !clippedAbove, originalStartColumn > windowColumnEnd {
            overlapRowStart += 1
            startRowTrimmed = true
        }
        if !clippedBelow, originalEndColumn < windowColumnStart {
            overlapRowEnd -= 1
            endRowTrimmed = true
        }
        guard overlapRowStart <= overlapRowEnd else { return nil }

        // A trimmed boundary row means the selection continues beyond what this window shows, the same
        // as if the row crop itself had clipped it.
        let extendsAbove = selection.extendsAbove || clippedAbove || startRowTrimmed
        let extendsBelow = selection.extendsBelow || clippedBelow || endRowTrimmed

        guard overlapRowStart < overlapRowEnd else {
            // Exactly one row of the selection survives the crop. Its occupied columns depend on whether
            // it is still the true start row, the true end row, both (a single-row selection), or
            // neither (an interior row, hence full width).
            let row = overlapRowStart
            let occupiedStart = row == originalStartRow ? originalStartColumn : 0
            let occupiedEnd = row == originalEndRow ? originalEndColumn : sourceColumns - 1
            let clampedStart = max(occupiedStart, windowColumnStart)
            let clampedEnd = min(occupiedEnd, windowColumnEnd)
            guard clampedStart <= clampedEnd else { return nil }
            return GhosttyTerminalSelectionRange(
                startColumn: UInt16(clampedStart - windowColumnStart), startRow: UInt16(row - windowRowStart),
                endColumn: UInt16(clampedEnd - windowColumnStart), endRow: UInt16(row - windowRowStart), isRectangle: false,
                extendsAbove: extendsAbove, extendsBelow: extendsBelow)
        }

        // More than one row survives the crop. A surviving true boundary row is known by now to
        // intersect the window (an out-of-window one was trimmed above), so it clamps into the window
        // like any partially-visible row. Any other surviving top or bottom row is interior to the
        // original selection, hence full width, whether the row crop clipped it or the column trim
        // above did.
        let startColumn = (clippedAbove || startRowTrimmed) ? 0 : min(max(originalStartColumn - windowColumnStart, 0), columns - 1)
        let endColumn = (clippedBelow || endRowTrimmed) ? columns - 1 : min(max(originalEndColumn - windowColumnStart, 0), columns - 1)
        return GhosttyTerminalSelectionRange(
            startColumn: UInt16(startColumn), startRow: UInt16(overlapRowStart - windowRowStart), endColumn: UInt16(endColumn),
            endRow: UInt16(overlapRowEnd - windowRowStart), isRectangle: false, extendsAbove: extendsAbove, extendsBelow: extendsBelow)
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
