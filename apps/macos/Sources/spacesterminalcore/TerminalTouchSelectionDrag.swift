import Foundation

/// One end of a selection, as a touch client draws a handle on it.
public enum TerminalSelectionHandle: Equatable, Sendable {
    case start
    case end
}

/// A touch drag's selection in absolute rows: a long press that selected a word and keeps extending it,
/// or a handle moved to a new cell.
///
/// A touch names cells directly, so unlike `TerminalSelectionDrag` (which folds in what Ghostty's mouse
/// gesture resolved on the frame the surface shows) it needs no anchor reconciliation when the anchor
/// scrolls off the grid: the pointer cell is an absolute cell too, and it can lie above or below the
/// viewport, which is how a drag held past an edge says which way it is going.
///
/// The selection is always a stream selection. The fixed part is what the drag does not move: the
/// pressed word for a long press, or the end opposite the handle. The result spans the fixed part and
/// the pointer cell, so dragging back across the fixed part flips the selection to the other side
/// instead of collapsing it.
public struct TerminalTouchSelectionDrag: Equatable, Sendable {
    private let fixedStart: TerminalAbsoluteCell
    private let fixedEnd: TerminalAbsoluteCell
    /// The epoch of the selection the drag grows from; a frame from another epoch renumbered its rows,
    /// which ends the selection.
    public let historyEpoch: UInt64

    /// A long press that selected `word`: the drag extends the word by cell in either direction.
    public init(word: TerminalAbsoluteSelection) {
        fixedStart = word.start
        fixedEnd = word.end
        historyEpoch = word.historyEpoch
    }

    /// A handle drag: the opposite end stays put, and the pointer cell replaces the dragged end.
    public init(moving handle: TerminalSelectionHandle, of selection: TerminalAbsoluteSelection) {
        let fixed = handle == .start ? selection.end : selection.start
        fixedStart = fixed
        fixedEnd = fixed
        historyEpoch = selection.historyEpoch
    }

    /// The selection with the pointer at `cell`.
    public func selection(pointerAt cell: TerminalAbsoluteCell) -> TerminalAbsoluteSelection {
        TerminalAbsoluteSelection(from: min(fixedStart, cell), to: max(fixedEnd, cell), isRectangle: false, historyEpoch: historyEpoch)
    }
}
