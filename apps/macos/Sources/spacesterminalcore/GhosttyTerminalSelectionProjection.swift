import Foundation

/// Projects a screen-space selection (row 0 = oldest retained scrollback row, matching what
/// `spaces_ghostty_vt_session_set_selection`/`_selection_state` accept and report) into one
/// viewport's coordinates. The Linux headless core owns the selection in screen space (it can span
/// scrollback the current viewport does not show) and rebases it into the viewport it exports every
/// frame, the same way `GhosttyTerminalSnapshotViewport` rebases a snapshot when cropping it for
/// follow-cursor display.
///
/// Lives next to `GhosttyTerminalSelectionRange` so both the headless core and its tests share one
/// implementation. Unlike `GhosttyTerminalSnapshotViewport.crop`, this only crops vertically: the
/// headless core's viewport always shows every column the session has, so there is no horizontal
/// window to intersect.
public enum GhosttyTerminalSelectionProjection {
    /// `startRow`/`endRow` are screen-space and must already be ordered (`startRow <= endRow`, and
    /// `startColumn <= endColumn` when they are equal), matching what
    /// `spaces_ghostty_vt_session_selection_state` guarantees. A rectangle's columns are the one
    /// exception: lexicographic ordering cannot order them, so they are normalized here. `viewportRowOffset` is the screen-space
    /// row of the viewport's first visible row (the scrollbar offset); `columns`/`rows` are the
    /// viewport's dimensions. Returns nil when the selection does not overlap the viewport at all.
    public static func project(
        startColumn: UInt16, startRow: UInt32, endColumn: UInt16, endRow: UInt32, isRectangle: Bool, viewportRowOffset: UInt32, columns: Int,
        rows: Int
    ) -> GhosttyTerminalSelectionRange? {
        guard columns > 0, rows > 0 else { return nil }

        let windowRowStart = viewportRowOffset
        let windowRowEnd = viewportRowOffset + UInt32(rows) - 1

        let overlapRowStart = max(startRow, windowRowStart)
        let overlapRowEnd = min(endRow, windowRowEnd)
        guard overlapRowStart <= overlapRowEnd else { return nil }

        let extendsAbove = startRow < windowRowStart
        let extendsBelow = endRow > windowRowEnd

        if isRectangle {
            // The (y, x)-lexicographic endpoint ordering guarantees rows are ordered but says nothing
            // about a rectangle's columns: a block dragged toward the left arrives with startColumn >
            // endColumn. The rectangle spans the min..max column band either way, so normalize here.
            let clampedStart = min(max(Int(min(startColumn, endColumn)), 0), columns - 1)
            let clampedEnd = min(max(Int(max(startColumn, endColumn)), 0), columns - 1)
            return GhosttyTerminalSelectionRange(
                startColumn: UInt16(clampedStart), startRow: UInt16(overlapRowStart - windowRowStart), endColumn: UInt16(clampedEnd),
                endRow: UInt16(overlapRowEnd - windowRowStart), isRectangle: true, extendsAbove: extendsAbove, extendsBelow: extendsBelow)
        }

        guard overlapRowStart < overlapRowEnd else {
            // Exactly one row of the selection survives the crop. Its occupied columns depend on
            // whether it is still the true start row, the true end row, both (a single-row
            // selection), or neither (an interior row, hence full width).
            let row = overlapRowStart
            let occupiedStart = row == startRow ? Int(startColumn) : 0
            let occupiedEnd = row == endRow ? Int(endColumn) : columns - 1
            let clampedStart = min(max(occupiedStart, 0), columns - 1)
            let clampedEnd = min(max(occupiedEnd, 0), columns - 1)
            guard clampedStart <= clampedEnd else { return nil }
            return GhosttyTerminalSelectionRange(
                startColumn: UInt16(clampedStart), startRow: UInt16(row - windowRowStart), endColumn: UInt16(clampedEnd),
                endRow: UInt16(row - windowRowStart), isRectangle: false, extendsAbove: extendsAbove, extendsBelow: extendsBelow)
        }

        // More than one row survives the crop, which guarantees an interior (full-width) row among
        // them, so the viewport's columns always intersect the selection here regardless of the
        // boundary rows' own ranges.
        let projectedStartColumn = extendsAbove ? 0 : min(max(Int(startColumn), 0), columns - 1)
        let projectedEndColumn = extendsBelow ? columns - 1 : min(max(Int(endColumn), 0), columns - 1)
        return GhosttyTerminalSelectionRange(
            startColumn: UInt16(projectedStartColumn), startRow: UInt16(overlapRowStart - windowRowStart), endColumn: UInt16(projectedEndColumn),
            endRow: UInt16(overlapRowEnd - windowRowStart), isRectangle: false, extendsAbove: extendsAbove, extendsBelow: extendsBelow)
    }
}
