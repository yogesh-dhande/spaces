import Foundation

/// The one place a snapshot cell turns into the text a client shows. Both the grid resolver
/// (`GhosttyTerminalSnapshotGrid`) and the display-run layout (`GhosttyTerminalSnapshotLayout`) render
/// through it, so accessibility text, copy buffers, previews, and scrollback replay all agree on what
/// a cell says.
public enum GhosttyTerminalSnapshotCellText {
    /// The cell's text: its full grapheme cluster when it has one, its base codepoint otherwise. The
    /// cluster is passed in because it lives beside the cell rather than in it — the caller reads it out
    /// of the snapshot's table at the cell's own index. Spacer cells (the trailing half of a
    /// double-width glyph) and invisible cells render as a space so column positions still line up.
    public static func displayText(for cell: GhosttyTerminalSnapshot.Cell, cluster: String?) -> String {
        let hiddenFlags = GhosttyTerminalSnapshotGrid.spacerFlag | GhosttyTerminalSnapshotGrid.invisibleFlag
        if cell.flags & hiddenFlags != 0 { return " " }
        if let cluster { return cluster }
        guard cell.codepoint != 0 else { return " " }
        guard let scalar = UnicodeScalar(cell.codepoint) else { return "\u{FFFD}" }
        return String(scalar)
    }
}
