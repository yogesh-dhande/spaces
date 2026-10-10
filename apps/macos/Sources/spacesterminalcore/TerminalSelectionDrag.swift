import Foundation

/// The viewport a drag step is resolved against: where the frame the mirror surface showed sits in
/// absolute rows, and its grid.
public struct TerminalSelectionDragFrame: Equatable, Sendable {
    public let historyRowBase: UInt64
    public let historyEpoch: UInt64
    public let columns: Int
    public let rows: Int

    public init(historyRowBase: UInt64, historyEpoch: UInt64, columns: Int, rows: Int) {
        self.historyRowBase = historyRowBase
        self.historyEpoch = historyEpoch
        self.columns = columns
        self.rows = rows
    }

    public init(snapshot: GhosttyTerminalSnapshot) {
        self.init(historyRowBase: snapshot.historyRowBase, historyEpoch: snapshot.historyEpoch, columns: snapshot.columns, rows: snapshot.rows)
    }

    fileprivate var rowBase: Int64 { Int64(clamping: historyRowBase) }
}

/// What Ghostty's drag gesture resolved on the frame the mirror surface shows, as
/// `ghostty_mirror_selection_info` reports it: ordered start and end cells in viewport coordinates.
public struct TerminalSelectionDragResolution: Equatable, Sendable {
    public let startColumn: Int
    public let startRow: Int
    public let endColumn: Int
    public let endRow: Int
    public let isRectangle: Bool

    public init(startColumn: Int, startRow: Int, endColumn: Int, endRow: Int, isRectangle: Bool) {
        self.startColumn = startColumn
        self.startRow = startRow
        self.endColumn = endColumn
        self.endRow = endRow
        self.isRectangle = isRectangle
    }
}

/// One mouse drag's selection, merged from Ghostty's per-frame resolutions into absolute rows.
///
/// The mirror surface runs the gesture (cell, word or line by click count; Option for a rectangle) on the
/// frame it shows, so Ghostty only knows the anchor while the anchor is on that frame's grid. When the
/// anchor's text scrolls off the grid the fork seats the gesture's click pin on a stand-in corner cell
/// (top-left when the anchor is above the viewport, bottom-right when below; a rectangle keeps the anchor's
/// column), which gets the pointer side of the resolution right and the anchor side wrong: half-cell
/// rounding, trailing-whitespace trimming and word boundaries are all read from the stand-in. The drag
/// therefore remembers the anchor side Ghostty resolved while the anchor was on the grid and keeps it,
/// taking only the pointer side from Ghostty while the anchor is off the grid.
///
/// The consumer writes `anchorViewportRow(in:)` and `anchor.column` into the surface's
/// `drag_anchor_x/y` for each frame it applies, and feeds every resolution through `merge`.
public struct TerminalSelectionDrag: Equatable, Sendable {
    /// The cell the press landed on.
    public let anchor: TerminalAbsoluteCell
    /// The epoch of the frame the press was made on; a frame from another epoch renumbered its rows, which
    /// ends the selection.
    public let historyEpoch: UInt64

    /// The end of the last on-grid resolution that sits on the anchor side. For a rectangle only its row
    /// is meaningful, since Ghostty's column band is right at every step. Nil until a selection resolved
    /// while the anchor was on the grid.
    private var anchorSideEnd: TerminalAbsoluteCell?
    private var lastSelection: TerminalAbsoluteSelection?

    public init(anchor: TerminalAbsoluteCell, historyEpoch: UInt64) {
        self.anchor = anchor
        self.historyEpoch = historyEpoch
    }

    /// The anchor's row in `frame`'s viewport: negative above the first row, `rows` or more below the last.
    public func anchorViewportRow(in frame: TerminalSelectionDragFrame) -> Int { Int(clamping: anchor.row - frame.rowBase) }

    /// Whether the anchor's cell is on `frame`'s grid, which decides who owns the anchor side of the
    /// selection.
    public func anchorIsOnGrid(in frame: TerminalSelectionDragFrame) -> Bool {
        let row = anchorViewportRow(in: frame)
        return row >= 0 && row < frame.rows && anchor.column >= 0 && anchor.column < frame.columns
    }

    /// Folds one Ghostty resolution into the drag and returns the selection to hold and paint: nil for no
    /// selection (a click with no movement, or a frame from another epoch).
    ///
    /// `pointerColumn`/`pointerRow` are the pointer's cell in `frame`'s viewport; they say which side of the
    /// anchor the pointer is on, which says which end of Ghostty's ordered result is the anchor's.
    ///
    /// While the anchor is off the grid Ghostty can resolve no selection when the pointer sits inside the
    /// stand-in cell itself; the last merged selection stays then, and the next move out of the cell
    /// resolves normally.
    public mutating func merge(
        _ resolution: TerminalSelectionDragResolution?, pointerColumn: Int, pointerRow: Int, in frame: TerminalSelectionDragFrame
    ) -> TerminalAbsoluteSelection? {
        guard frame.historyEpoch == historyEpoch else {
            anchorSideEnd = nil
            lastSelection = nil
            return nil
        }
        let anchorOnGrid = anchorIsOnGrid(in: frame)
        guard let resolution else {
            guard anchorOnGrid else { return lastSelection }
            anchorSideEnd = nil
            lastSelection = nil
            return nil
        }

        let base = frame.rowBase
        let ghosttyStart = TerminalAbsoluteCell(column: resolution.startColumn, row: base + Int64(resolution.startRow))
        let ghosttyEnd = TerminalAbsoluteCell(column: resolution.endColumn, row: base + Int64(resolution.endRow))
        let isRectangle = resolution.isRectangle

        let merged: TerminalAbsoluteSelection
        if anchorOnGrid {
            let pointer = TerminalAbsoluteCell(column: pointerColumn, row: base + Int64(pointerRow))
            // A rectangle's sides are its rows, so the pointer is "after" the anchor by row alone.
            let pointerIsAtOrAfterAnchor = isRectangle ? pointer.row >= anchor.row : pointer >= anchor
            anchorSideEnd = pointerIsAtOrAfterAnchor ? ghosttyStart : ghosttyEnd
            merged = TerminalAbsoluteSelection(from: ghosttyStart, to: ghosttyEnd, isRectangle: isRectangle, historyEpoch: historyEpoch)
        } else {
            let anchorIsAbove = anchorViewportRow(in: frame) < 0
            let pointerSide = anchorIsAbove ? ghosttyEnd : ghosttyStart
            let anchorSide = anchorSideEnd ?? anchor
            if isRectangle {
                // Ghostty's column band is right (the stand-in keeps the anchor's column); only the anchor's
                // row is Ghostty's to get wrong. The selection normalizes the band, so which corner
                // carries which column does not matter.
                let anchorEnd = TerminalAbsoluteCell(column: ghosttyStart.column, row: anchorSide.row)
                let pointerEnd = TerminalAbsoluteCell(column: ghosttyEnd.column, row: pointerSide.row)
                merged = TerminalAbsoluteSelection(from: anchorEnd, to: pointerEnd, isRectangle: true, historyEpoch: historyEpoch)
            } else {
                merged = TerminalAbsoluteSelection(from: anchorSide, to: pointerSide, isRectangle: false, historyEpoch: historyEpoch)
            }
        }
        lastSelection = merged
        return merged
    }
}
