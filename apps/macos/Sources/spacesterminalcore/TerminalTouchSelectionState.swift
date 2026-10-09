import Foundation

/// The selection a touch client (the iPhone and iPad) holds for one terminal, with the drag that is
/// growing it and the epoch rules that end it.
///
/// Nothing here is committed to the session: the selection is this client's alone, in absolute rows, so
/// it follows its text as output scrolls it and spans the client's replayed scrollback and its live
/// rows. It ends when the rows it names are renumbered (`historyEpoch` changes: a reset, a clear, a
/// screen switch or a column resize) or when the client clears it (a tap, typing).
public struct TerminalTouchSelectionState: Equatable, Sendable {
    public private(set) var selection: TerminalAbsoluteSelection?
    private var drag: TerminalTouchSelectionDrag?
    /// The epoch of the newest live frame, painted or not. See `noteLiveFrameEpoch(_:)`.
    private var lastLiveHistoryEpoch: UInt64?

    public init() {}

    /// Whether a long press or a handle is currently growing the selection.
    public var isDragging: Bool { drag != nil }

    /// A long press selected `word`; the finger still down extends it.
    public mutating func beginWordSelection(_ word: TerminalAbsoluteSelection) {
        selection = word
        drag = TerminalTouchSelectionDrag(word: word)
    }

    /// A finger took hold of one of the selection's handles. Does nothing without a selection.
    public mutating func beginHandleDrag(_ handle: TerminalSelectionHandle) {
        guard let selection else { return }
        drag = TerminalTouchSelectionDrag(moving: handle, of: selection)
    }

    /// The drag's finger is over `cell`. Does nothing outside a drag.
    public mutating func extendDrag(to cell: TerminalAbsoluteCell) {
        guard let drag else { return }
        selection = drag.selection(pointerAt: cell)
    }

    /// The finger lifted. The selection stays.
    public mutating func endDrag() { drag = nil }

    /// Replaces the selection from outside a touch (select-all, or clearing), with no drag behind it.
    public mutating func replace(with newSelection: TerminalAbsoluteSelection?) {
        selection = newSelection
        drag = nil
    }

    public mutating func clear() { replace(with: nil) }

    /// The frame on screen is in `epoch`. A selection of another epoch names rows that frame does not
    /// number the same way, so it ends. This also ends a selection when the session's run changes: a
    /// relaunch or any other rebuild of the host's terminal mints a new incarnation, which the host
    /// folds into the `historyEpoch` of every frame it exports.
    public mutating func noteShownFrameEpoch(_ epoch: UInt64) {
        guard let current = selection, current.historyEpoch != epoch else { return }
        clear()
    }

    /// A live frame arrived in `epoch`, whether or not it is painted. While the client shows its own
    /// replay the live frames are not painted, so a clear, reset or screen switch would otherwise leave
    /// a highlight in the old numbering. Only a selection made in the previous live epoch ends: one
    /// made on a replay that was not yet aligned with the host is numbered in the replay's own epoch,
    /// and must survive live frames that merely differ from it.
    public mutating func noteLiveFrameEpoch(_ epoch: UInt64) {
        defer { lastLiveHistoryEpoch = epoch }
        guard let previous = lastLiveHistoryEpoch, previous != epoch, let current = selection, current.historyEpoch == previous else { return }
        clear()
    }
}
