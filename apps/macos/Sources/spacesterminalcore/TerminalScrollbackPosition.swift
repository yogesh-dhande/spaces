import Foundation

/// Where a rendered terminal frame sits relative to its session's live bottom row.
///
/// Every frame a client renders carries Ghostty's own scrollbar state: `scrollbarTotal` is the whole
/// scrollable region (scrollback plus the active area), `scrollbarOffset` is the index of the
/// viewport's top row inside that region, and the viewport is `rows` tall. So the rows hidden below
/// the viewport are `total - offset - rows`, which is zero exactly when the viewport's last row is the
/// session's last row. Ghostty reports the same zero for a session with no scrollback at all (it
/// special-cases `total = rows`, `offset = 0`), so a terminal that has never scrolled reads as being
/// at the live bottom rather than as scrolled back by its own height.
///
/// The value is derived per frame on the client and never travels on the wire: the daemon owns the
/// viewport, and the frames it already publishes say where that viewport sits.
///
/// It reads the session's exported viewport, never the crop a client happens to render out of it. On
/// iOS the software keyboard leaves the session's grid alone and the client renders a shorter window
/// of it that follows the cursor (see `GhosttyTerminalSnapshotViewport`), so measuring that window's
/// distance to the grid's bottom would report a fresh session's blank rows as scrollback.
public struct TerminalScrollbackPosition: Equatable, Sendable {
    /// How many rows of output sit below the rendered viewport. Zero when the viewport shows the live
    /// bottom row.
    public let rowsFromLiveBottom: Int

    /// A frame showing the session's last row, which is also what a frame carrying no scrollbar state
    /// resolves to (an ended pane's transcript replay exports none).
    public static let atLiveBottom = TerminalScrollbackPosition(rowsFromLiveBottom: 0)

    private init(rowsFromLiveBottom: Int) { self.rowsFromLiveBottom = rowsFromLiveBottom }

    /// Clamped at zero: a viewport taller than the scrollable region it reports (a frame exported
    /// mid-resize, or one carrying no scrollbar state) is at the bottom, never past it.
    public init(scrollbarTotal: UInt32, scrollbarOffset: UInt32, viewportRows: Int) {
        rowsFromLiveBottom = max(Int(scrollbarTotal) - Int(scrollbarOffset) - max(viewportRows, 0), 0)
    }

    public init(snapshot: GhosttyTerminalSnapshot) {
        self.init(scrollbarTotal: snapshot.scrollbarTotal, scrollbarOffset: snapshot.scrollbarOffset, viewportRows: snapshot.rows)
    }

    /// Whether the frame is showing scrollback rather than the live bottom, which is the whole
    /// condition the jump-to-bottom control is offered under.
    public var isScrolledIntoScrollback: Bool { rowsFromLiveBottom > 0 }

    /// The position a frame describes, or `atLiveBottom` when there is no frame to read: a pane with
    /// nothing rendered has no scrollback to be inside of.
    public static func position(of snapshot: GhosttyTerminalSnapshot?) -> TerminalScrollbackPosition {
        guard let snapshot else { return .atLiveBottom }
        return TerminalScrollbackPosition(snapshot: snapshot)
    }
}
