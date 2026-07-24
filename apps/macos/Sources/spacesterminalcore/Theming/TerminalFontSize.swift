/// The user's choice of iOS terminal text size, in points.
///
/// 11 is the default so existing installs render unchanged until a user opts into a different
/// size. Changing it changes the cell metrics used to compute the terminal grid, so the daemon
/// sees an ordinary resize to the new column/row count.
public enum TerminalFontSize: Int, CaseIterable, Sendable {
    case nine = 9
    case ten = 10
    case eleven = 11
    case twelve = 12

    /// The font size both the settings picker and the terminal view start with.
    public static let `default`: TerminalFontSize = .eleven

    /// Resolves a persisted raw value, falling back to the default for missing or
    /// out-of-range values so an unreadable setting never leaves the font size unset.
    public init(persistedRawValue: Int?) { self = persistedRawValue.flatMap(TerminalFontSize.init(rawValue:)) ?? .default }

    /// The size in points, as GhosttyKit's font APIs expect.
    public var points: Double { Double(rawValue) }

    /// Human-facing label for the settings picker.
    public var displayName: String { "\(rawValue)" }
}
