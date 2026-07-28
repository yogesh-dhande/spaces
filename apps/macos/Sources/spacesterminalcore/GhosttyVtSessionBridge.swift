import Foundation
import ghosttyvtshim

/// Shared bridge between the libghostty-vt C shim and the Swift render types. Both the headless Linux
/// daemon session (`GhosttyEmbeddedSessionCore`) and the client-local ended-session scrollback replay
/// (`TerminalEndedSessionScrollbackModel`) render through this one converter and theme packer, so a
/// replayed frame carries the exact same cell/theme shape the daemon would have produced.
public enum GhosttyVtSessionBridge {
    /// Packs a theme's terminal export into the C shim's theme struct (default fg/bg/cursor plus the 16
    /// ANSI palette entries; the shim fills indices 16-255 with the standard xterm ramp).
    public static func packTheme(_ export: GhosttyThemeExport) -> SpacesGhosttyVtTheme {
        var theme = SpacesGhosttyVtTheme()
        theme.foreground_rgb = export.foreground.packedRGB
        theme.background_rgb = export.background.packedRGB
        theme.cursor_rgb = export.cursorColor.packedRGB
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
        let cells: [GhosttyTerminalSnapshot.Cell]
        if let rawCells = rawSnapshot.cells, rawSnapshot.cell_count > 0 {
            cells = UnsafeBufferPointer(start: rawCells, count: rawSnapshot.cell_count).map {
                GhosttyTerminalSnapshot.Cell(
                    codepoint: $0.codepoint, foregroundRGB: $0.foreground_rgb, backgroundRGB: $0.background_rgb, flags: $0.flags)
            }
        } else {
            cells = []
        }
        return GhosttyTerminalSnapshot(
            columns: Int(rawSnapshot.columns), rows: Int(rawSnapshot.rows), cursorColumn: Int(rawSnapshot.cursor_column),
            cursorRow: Int(rawSnapshot.cursor_row), cursorVisible: rawSnapshot.cursor_visible,
            defaultForegroundRGB: rawSnapshot.default_foreground_rgb, defaultBackgroundRGB: rawSnapshot.default_background_rgb, cells: cells,
            mouseReportingActive: mouseReportingActive)
    }
}
