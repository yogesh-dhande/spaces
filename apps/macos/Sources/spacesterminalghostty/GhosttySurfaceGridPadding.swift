import Foundation

/// The padding Ghostty leaves between a surface's edge and the first cell of its grid, in that
/// surface's own device pixels.
///
/// Ghostty positions cell `(0, 0)` at this offset and resolves a pointer back to a cell by subtracting it
/// again (`renderer/size.zig`, `Coordinate.convert`), so anything converting between a cell and a pixel on
/// a macOS-hosted surface needs it: the session daemon's headless surface and a Mac pane's mirror surface
/// alike.
///
/// `Surface.zig`'s `scaledPadding` turns the `window-padding-x`/`-y` config value into pixels as
/// `floor(points * scale * dpi / 72)`, and `font/face.zig` defines `default_dpi` as 72 on macOS, so on this
/// platform the surface's content scale alone decides it. (The iOS GhosttyKit slice builds against the
/// non-macOS 96 baseline, which is why `GhosttyTerminalCellMetricsCache.paddingPerSidePx(scale:)` carries a
/// different constant for the same formula.)
enum GhosttySurfaceGridPadding {
    static func perSidePixels(scale: Double) -> Double { (windowPaddingPoints * scale).rounded(.down) }

    /// Ghostty's `window-padding-x`/`-y` default. The Ghostty config Spaces generates never overrides it.
    private static let windowPaddingPoints = 2.0
}
