import Foundation

/// A terminal selection projected into one viewport's grid: the daemon owns the shared selection in
/// screen+scrollback coordinates and rebases it into each frame's viewport before export, so every field
/// here is already relative to the frame that carries it and clipped to that frame's `columns`/`rows`
/// (a coordinate past the grid is not a valid range). `startRow`/`startColumn` order before
/// `endRow`/`endColumn` regardless of which end the selection's drag started from, so a consumer never
/// has to compare the two ends before walking the range.
///
/// Conforms to `Codable` in addition to the `Equatable, Sendable` the type needs on its own: it nests
/// inside `GhosttyTerminalSnapshot`, which derives its own `Codable` conformance, so every field it holds
/// has to be `Codable` too.
public struct GhosttyTerminalSelectionRange: Codable, Equatable, Sendable {
    public var startColumn: UInt16
    public var startRow: UInt16
    public var endColumn: UInt16
    public var endRow: UInt16
    /// True for a column-block (rectangle) selection; false for the normal stream selection that runs
    /// start-to-end through every row in between.
    public var isRectangle: Bool
    /// The selection continues into scrollback above this viewport's top row: the row the daemon
    /// rebased from was clipped off, not that the selection actually starts at `startRow`.
    public var extendsAbove: Bool
    /// The selection continues past this viewport's bottom row, the same way `extendsAbove` reads for
    /// the top.
    public var extendsBelow: Bool

    public init(
        startColumn: UInt16, startRow: UInt16, endColumn: UInt16, endRow: UInt16, isRectangle: Bool, extendsAbove: Bool, extendsBelow: Bool
    ) {
        self.startColumn = startColumn
        self.startRow = startRow
        self.endColumn = endColumn
        self.endRow = endRow
        self.isRectangle = isRectangle
        self.extendsAbove = extendsAbove
        self.extendsBelow = extendsBelow
    }
}
