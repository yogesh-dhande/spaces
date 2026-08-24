import CryptoKit
import Foundation

/// Caches the on-screen cell size Ghostty's bundled font measures at a given (font size, scale)
/// pair, keyed off a real `ghostty_surface_size()` read.
///
/// `GhosttyRemoteTerminalHostView.viewportSize()` and `GhosttyRemoteTerminalViewport.cellMetrics(fontSize:)`
/// consult it as a fallback prediction for the window before a surface exists, instead of guessing
/// the grid from `UIFont.monospacedSystemFont` — a font Ghostty never actually renders with, so its
/// measured "W" width does not match the surface's own cell width. A live surface always wins over
/// a prediction; the cache only ever fills the gap before one exists, and every prediction is
/// checked against the next live read and corrected if it drifted (see the self-heal call site in
/// `surfaceViewportSize(renderBounds:)`), so a stale entry costs at most one degraded open rather
/// than a stuck grid.
public struct GhosttyTerminalCellMetricsCache {
    public struct CellPixelSize: Equatable {
        public let width: Int
        public let height: Int
        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    /// One persisted `UserDefaults` entry: everything is invalidated together by dropping the
    /// whole array when `stamp` no longer matches, rather than tracking per-entry provenance.
    private struct Storage: Codable {
        var stamp: String
        var entries: [StoredEntry]
    }

    /// Flat, `Codable`-friendly encoding of the (font size, scale) -> cell size map. A `Dictionary`
    /// keyed on a custom `Hashable` type does not round-trip through `JSONEncoder` as a plain
    /// object, so the key fields ride alongside the value in an array instead.
    private struct StoredEntry: Codable {
        let fontSizePoints: Int
        let scaleTenths: Int
        let width: Int
        let height: Int
    }

    private struct Key: Equatable {
        let fontSizePoints: Int
        let scaleTenths: Int

        /// Scale is rounded to one decimal place before keying: iOS only ever hands out 1x/2x/3x
        /// screen scales, so a decimal's worth of precision is already more than the input space
        /// needs, and rounding keeps two float reads of the same scale from missing each other.
        init(fontSizePoints: Int, scale: Double) {
            self.fontSizePoints = fontSizePoints
            self.scaleTenths = Int((scale * 10).rounded())
        }

        init(entry: StoredEntry) {
            fontSizePoints = entry.fontSizePoints
            scaleTenths = entry.scaleTenths
        }
    }

    public static let defaultStorageKey = "spaces.ghostty.terminalCellMetricsCache.v1"

    private let defaults: UserDefaults
    private let storageKey: String
    private let stamp: String

    /// `stamp` identifies the build and config this cache's entries were measured under; see
    /// `GhosttyTerminalCellMetricsCache.stamp(appVersion:configFileContents:)`. `defaults` and
    /// `storageKey` default to production values and are overridden in tests for isolation.
    public init(defaults: UserDefaults = .standard, storageKey: String = GhosttyTerminalCellMetricsCache.defaultStorageKey, stamp: String) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.stamp = stamp
    }

    public func cellPixelSize(fontSizePoints: Int, scale: Double) -> CellPixelSize? {
        let storage = loadStorage()
        guard storage.stamp == stamp else { return nil }
        let key = Key(fontSizePoints: fontSizePoints, scale: scale)
        guard let match = storage.entries.first(where: { Key(entry: $0) == key }) else { return nil }
        return CellPixelSize(width: match.width, height: match.height)
    }

    /// Records the cell size a live surface just measured, overwriting any stale entry for the
    /// same (font size, scale). A stamp mismatch (an app update, or the generated Ghostty config's
    /// content changing) drops every existing entry first, so a previous build's or a previous
    /// theme's measurements never mix with the current one's.
    public func recordCellPixelSize(fontSizePoints: Int, scale: Double, width: Int, height: Int) {
        var storage = loadStorage()
        if storage.stamp != stamp { storage = Storage(stamp: stamp, entries: []) }
        let key = Key(fontSizePoints: fontSizePoints, scale: scale)
        storage.entries.removeAll { Key(entry: $0) == key }
        storage.entries.append(StoredEntry(fontSizePoints: key.fontSizePoints, scaleTenths: key.scaleTenths, width: width, height: height))
        saveStorage(storage)
    }

    /// The padding-correct predicted grid for a viewport of `renderBoundsWidth` x
    /// `renderBoundsHeight` points at `scale`, from a cached cell size, or nil when nothing is
    /// cached yet for this (font size, scale). The pixel sizing mirrors
    /// `GhosttyRemoteTerminalHostView.updateSurfaceGeometry()`'s own `floor(bounds * scale)`,
    /// minimum 1, exactly, so a hit predicts precisely what the surface would report for the same
    /// geometry.
    public func predictedGrid(fontSizePoints: Int, scale: Double, renderBoundsWidth: Double, renderBoundsHeight: Double) -> (columns: Int, rows: Int)?
    {
        guard let cell = cellPixelSize(fontSizePoints: fontSizePoints, scale: scale), cell.width > 0, cell.height > 0 else { return nil }
        let widthPx = max(Int((renderBoundsWidth * scale).rounded(.down)), 1)
        let heightPx = max(Int((renderBoundsHeight * scale).rounded(.down)), 1)
        let paddingPerSide = Self.paddingPerSidePx(scale: scale)
        let contentWidthPx = max(widthPx - paddingPerSide * 2, 1)
        let contentHeightPx = max(heightPx - paddingPerSide * 2, 1)
        let columns = max(Int((Double(contentWidthPx) / Double(cell.width)).rounded(.down)), 1)
        let rows = max(Int((Double(contentHeightPx) / Double(cell.height)).rounded(.down)), 1)
        return (columns: columns, rows: rows)
    }

    /// Ghostty's non-macOS DPI baseline: `font/face.zig` defines `default_dpi` as `72` when the
    /// build target is macOS and `96` otherwise, and the iOS `GhosttyKit` slice takes the `else`
    /// branch. `Surface.zig` (~line 465, `scaledPadding`) turns a `window-padding-x`/`-y` config
    /// value (2pt by default, and the Spaces-generated config never overrides it) into device
    /// pixels as `floor(configPoints * scale * defaultDPI / 72)` per side. Confirmed against a live
    /// iOS surface at `.nine`/`.default`/`.twelve` font sizes (padding does not depend on font
    /// size): scale 2.0 measured 5px/side, scale 3.0 measured 8px/side, both exactly what this
    /// formula predicts and neither what the naive 72-baseline formula would (4px/6px) — the
    /// generic Ghostty default_dpi silently changes on the non-macOS build target this module
    /// links against.
    private static let iOSDefaultDPI: Double = 96

    public static func paddingPerSidePx(scale: Double) -> Int { Int((2.0 * iOSDefaultDPI * scale / 72.0).rounded(.down)) }

    /// Identifies the build and config a cache's entries were measured under. `appVersion` catches
    /// an app or `GhosttyKit` update changing font metrics; `configFileContents` catches the
    /// Spaces-generated Ghostty config changing (a future font-family or padding override) even
    /// with the app version unchanged. Either changing drops every cached entry on next load.
    public static func stamp(appVersion: String, configFileContents: Data?) -> String {
        // `Hasher` is process-salted (a different result every launch, by design), so it cannot
        // back a stamp meant to stay stable across launches of the same build; SHA256 is
        // deterministic in the content alone.
        let digest = SHA256.hash(data: configFileContents ?? Data())
        let digestHex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(appVersion)|\(digestHex)"
    }

    private func loadStorage() -> Storage {
        guard let data = defaults.data(forKey: storageKey), let storage = try? JSONDecoder().decode(Storage.self, from: data) else {
            return Storage(stamp: stamp, entries: [])
        }
        return storage
    }

    private func saveStorage(_ storage: Storage) {
        guard let data = try? JSONEncoder().encode(storage) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
