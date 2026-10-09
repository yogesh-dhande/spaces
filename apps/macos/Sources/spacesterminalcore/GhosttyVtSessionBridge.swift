import Foundation
import ghosttyvtshim

/// Shared bridge between the libghostty-vt C shim and the Swift render types. Both the headless Linux
/// daemon session (`GhosttyEmbeddedSessionCore`) and the client-local scrollback replay
/// (`TerminalLocalScrollbackModel`) render through this one converter and theme packer, so a
/// replayed frame carries the exact same cell/theme shape the daemon would have produced.
public enum GhosttyVtSessionBridge {
    /// Packs a theme's terminal export and appearance into the C shim's theme struct (default
    /// fg/bg/cursor plus the 16 ANSI palette entries; the shim fills indices 16-255 with the standard
    /// xterm ramp). The appearance is also what a live headless session reports to CSI ? 996 n.
    public static func packTheme(_ export: GhosttyThemeExport, appearance: ThemeAppearance) -> SpacesGhosttyVtTheme {
        var theme = SpacesGhosttyVtTheme()
        theme.foreground_rgb = export.foreground.packedRGB
        theme.background_rgb = export.background.packedRGB
        theme.cursor_rgb = export.cursorColor.packedRGB
        theme.is_dark = appearance == .dark
        withUnsafeMutablePointer(to: &theme.palette_rgb) { tuplePointer in
            tuplePointer.withMemoryRebound(to: UInt32.self, capacity: 16) { buffer in
                for index in 0..<16 { buffer[index] = index < export.palette.count ? export.palette[index].packedRGB : 0 }
            }
        }
        return theme
    }

    /// Reports whether the session's terminal has the alternate screen active, the state clients route
    /// scroll gestures on. A caller that has a live vt session reads it here and hands the result to
    /// `snapshot(from:...)`, which sees only the raw cell export.
    public static func alternateScreenActive(session: OpaquePointer) -> Bool {
        var active = false
        guard spaces_ghostty_vt_session_alternate_screen_active(session, &active) else { return false }
        return active
    }

    /// Converts a libghostty-vt snapshot into the Swift render snapshot the render pipeline consumes.
    /// The raw snapshot's `cells` buffer stays owned by the caller (freed with
    /// `spaces_ghostty_vt_snapshot_free`); this only reads it. Mouse tracking is not part of the raw
    /// snapshot (it is a terminal mode, queried separately), so the caller supplies it. The active
    /// screen is queried separately for the same reason: a caller with a live session passes
    /// `alternateScreenActive(session:)`. Scrollbar and history position are likewise queried separately
    /// (the shim has no per-snapshot equivalent of the embedded surface's combined export) and default
    /// to zero. The snapshot carries no selection: the client owns its selection in absolute rows and
    /// paints it onto the frames it displays. The scrollback replay passes no scrollbar but does pass
    /// `historyRowBase` and `historyEpoch`, in the host's numbering once the replay is aligned with it
    /// (`TerminalLocalScrollbackModel`).
    public static func snapshot(
        from rawSnapshot: SpacesGhosttyVtSnapshot, mouseTrackingLevel: TerminalMouseTrackingLevel, alternateScreenActive: Bool,
        scrollbarTotal: UInt32 = 0, scrollbarOffset: UInt32 = 0, historyRowBase: UInt64 = 0, historyEpoch: UInt64 = 0
    ) -> GhosttyTerminalSnapshot {
        var cells: [GhosttyTerminalSnapshot.Cell] = []
        var clusters: [Int: String] = [:]
        if let rawCells = rawSnapshot.cells, rawSnapshot.cell_count > 0 {
            cells.reserveCapacity(rawSnapshot.cell_count)
            for (index, rawCell) in UnsafeBufferPointer(start: rawCells, count: rawSnapshot.cell_count).enumerated() {
                cells.append(
                    GhosttyTerminalSnapshot.Cell(
                        codepoint: rawCell.codepoint, foregroundRGB: rawCell.foreground_rgb, backgroundRGB: rawCell.background_rgb,
                        flags: rawCell.flags))
                if let cluster = cluster(for: rawCell) { GhosttyTerminalSnapshot.setCluster(cluster, forCell: index, in: &clusters) }
            }
        }
        return GhosttyTerminalSnapshot(
            columns: Int(rawSnapshot.columns), rows: Int(rawSnapshot.rows), cursorColumn: Int(rawSnapshot.cursor_column),
            cursorRow: Int(rawSnapshot.cursor_row), cursorVisible: rawSnapshot.cursor_visible,
            defaultForegroundRGB: rawSnapshot.default_foreground_rgb, defaultBackgroundRGB: rawSnapshot.default_background_rgb, cells: cells,
            clusters: clusters, mouseTrackingLevel: mouseTrackingLevel, alternateScreenActive: alternateScreenActive,
            scrollbarTotal: scrollbarTotal, scrollbarOffset: scrollbarOffset, historyRowBase: historyRowBase, historyEpoch: historyEpoch)
    }

    /// Rebuilds a cell's grapheme cluster from the shim's base codepoint plus the extra codepoints it
    /// exported. Cells with no extras — nearly all of them — carry no cluster and render from the base
    /// codepoint alone.
    private static func cluster(for cell: SpacesGhosttyVtSnapshotCell) -> String? {
        guard let extras = cell.grapheme_extras, cell.grapheme_extra_len > 0, let base = UnicodeScalar(cell.codepoint) else { return nil }
        var scalars = String.UnicodeScalarView()
        scalars.append(base)
        for extra in UnsafeBufferPointer(start: extras, count: Int(cell.grapheme_extra_len)) {
            // A surrogate or out-of-range value is not something the terminal can hold; the base
            // codepoint alone still renders the cell.
            guard let scalar = UnicodeScalar(extra) else { return nil }
            scalars.append(scalar)
        }
        return String(scalars)
    }
}
