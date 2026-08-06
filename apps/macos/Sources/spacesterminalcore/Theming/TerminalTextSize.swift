/// The app-wide macOS terminal text size, in points.
///
/// Distinct from ``TerminalFontSize``, which is the iOS settings picker's fixed 9-12 pt enum: this
/// is the macOS zoom value, moved one point at a time across 9-18 pt by the terminal zoom keys and
/// exposed through no picker at all. The two platforms size their terminals from separate values so
/// neither one's range or controls constrain the other.
///
/// Changing it changes the cell metrics used to compute the terminal grid, so the daemon sees an
/// ordinary resize to the new column/row count.
public struct TerminalTextSize: Equatable, Sendable {
    /// The inclusive range zooming moves within. A zoom step past either end resolves to the end
    /// itself, which is what makes the press do nothing.
    public static let range = 9...18

    /// The size a profile starts at before it has ever zoomed.
    public static let `default` = TerminalTextSize(points: 12)

    public let points: Int

    private init(points: Int) { self.points = points }

    /// Resolves a persisted value, falling back to the default for a missing, non-numeric, or
    /// out-of-range string so an unreadable setting never leaves the terminal text size unset.
    public init(persistedRawValue: String?) {
        guard let points = persistedRawValue.flatMap(Int.init), Self.range.contains(points) else {
            self = .default
            return
        }
        self.init(points: points)
    }

    /// The string form stored in the client database.
    public var persistedRawValue: String { String(points) }

    /// The size as AppKit's and GhosttyKit's font APIs express it.
    public var pointSize: Double { Double(points) }

    /// The size `command` moves to, clamped to ``range``.
    public func applying(_ command: TerminalTextZoomCommand) -> TerminalTextSize {
        switch command {
        case .zoomIn: return TerminalTextSize(points: min(points + 1, Self.range.upperBound))
        case .zoomOut: return TerminalTextSize(points: max(points - 1, Self.range.lowerBound))
        }
    }
}
