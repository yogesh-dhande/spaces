import Foundation
import ghosttyvtshim

/// Shared bridge between the libghostty-vt C shim and the Swift render types. Both the headless Linux
/// daemon session (`GhosttyEmbeddedSessionCore`) and the client-local ended-session scrollback replay
/// (`TerminalEndedSessionScrollbackModel`) render through this one converter and theme packer, so a
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

    /// Converts a libghostty-vt snapshot into the Swift render snapshot the render pipeline consumes.
    /// The raw snapshot's `cells` buffer stays owned by the caller (freed with
    /// `spaces_ghostty_vt_snapshot_free`); this only reads it. Mouse tracking is not part of the raw
    /// snapshot — it is a terminal mode, queried separately — so the caller supplies it.
    public static func snapshot(from rawSnapshot: SpacesGhosttyVtSnapshot, mouseReportingActive: Bool) -> GhosttyTerminalSnapshot {
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
            clusters: clusters, mouseReportingActive: mouseReportingActive)
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
