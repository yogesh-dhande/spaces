import CoreGraphics
import spacesterminalcore

/// Pure placement math for the Copy pill offered while the daemon's shared selection is present (see
/// `TerminalSelectionCopyPill`). Kept free of SwiftUI/UIKit so the placement rule is unit testable
/// without a live terminal surface, a window, or a rendered view hierarchy.
enum TerminalSelectionCopyPillLayout {
    struct Anchor: Equatable {
        /// The point, in the terminal view's own coordinate space, the pill's trailing edge sits against:
        /// x is the right edge of the selection's last selected column, y is the row edge the pill rests
        /// on (its bottom edge when the pill sits above, its top edge when it flips below).
        let point: CGPoint
        /// True when the pill sits below `point` instead of above it. The highlight touching the top of
        /// the viewport (its start row is the viewport's first row, or the daemon reports the selection
        /// continues further up into scrollback) means a pill above it would sit off-screen or over
        /// content the user never selected, so it flips below instead.
        let flipsBelow: Bool
    }

    /// Crops `snapshot`'s selection into the viewport this client is currently showing, the same
    /// `.leading`-aligned window `GhosttyRemoteTerminalHostView` renders through, and turns the result
    /// into a pill anchor point. Nil when the snapshot carries no selection or the crop leaves none
    /// visible. Skips the crop (an O(grid) copy) entirely when the snapshot carries no selection, since
    /// that is the common case on every frame while nothing is selected.
    static func anchor(
        snapshot: GhosttyTerminalSnapshot, viewportColumns: Int, viewportRows: Int, contentOrigin: CGPoint, cellWidth: CGFloat, cellHeight: CGFloat
    ) -> Anchor? {
        guard snapshot.selection != nil, viewportColumns > 0, viewportRows > 0 else { return nil }
        let window = GhosttyTerminalSnapshotViewport.window(
            for: snapshot, columns: viewportColumns, rows: viewportRows, horizontalAlignment: .leading)
        guard let selection = GhosttyTerminalSnapshotViewport.crop(snapshot, window: window).selection else { return nil }
        return anchor(
            for: selection, columns: window.columns, rows: window.rows, contentOrigin: contentOrigin, cellWidth: cellWidth, cellHeight: cellHeight)
    }

    /// The pure placement rule against a selection already projected into this viewport: right-aligned to
    /// one column past the selection's last selected column (clamped to the grid, so a selection ending
    /// at the last column does not push the anchor past the right edge), above the end row unless the
    /// flip rule applies.
    static func anchor(
        for selection: GhosttyTerminalSelectionRange, columns: Int, rows: Int, contentOrigin: CGPoint, cellWidth: CGFloat, cellHeight: CGFloat
    )
        -> Anchor?
    {
        guard columns > 0, rows > 0, cellWidth > 0, cellHeight > 0 else { return nil }
        // A highlight that also reaches the viewport's last row leaves no room below either, so the flip
        // is skipped and the pill sits above the end row, overlaying the selection's tail the way a text
        // callout sits over full-screen content, rather than rendering past the bottom edge.
        let flipsBelow = (selection.startRow == 0 || selection.extendsAbove) && Int(selection.endRow) + 1 < rows
        let endColumn = min(Int(selection.endColumn) + 1, columns)
        let x = contentOrigin.x + CGFloat(endColumn) * cellWidth
        let rowEdge = flipsBelow ? Int(selection.endRow) + 1 : Int(selection.endRow)
        let y = contentOrigin.y + CGFloat(rowEdge) * cellHeight
        return Anchor(point: CGPoint(x: x, y: y), flipsBelow: flipsBelow)
    }

    /// Turns an anchor into the pill's final top-left origin. The anchor's flip rule already handles the
    /// common cases (selection near the top flips the pill below, selection near the bottom keeps it
    /// above), but a selection near the left or right edge can still place the pill's far side outside the
    /// grid, so this clamps both axes to the grid bounds as a last-resort guarantee that the pill stays
    /// tappable, even when that means overlaying the selection itself the way a callout sits over
    /// full-screen content.
    static func origin(anchor: Anchor, pillSize: CGSize, gap: CGFloat, contentOrigin: CGPoint, gridSize: CGSize) -> CGPoint {
        let x = anchor.point.x - pillSize.width
        let y = anchor.flipsBelow ? anchor.point.y + gap : anchor.point.y - gap - pillSize.height
        // The max is applied after the min so a pill larger than the grid pins to the top-leading grid
        // corner rather than the bottom-trailing one.
        let clampedX = max(min(x, contentOrigin.x + gridSize.width - pillSize.width), contentOrigin.x)
        let clampedY = max(min(y, contentOrigin.y + gridSize.height - pillSize.height), contentOrigin.y)
        return CGPoint(x: clampedX, y: clampedY)
    }
}
