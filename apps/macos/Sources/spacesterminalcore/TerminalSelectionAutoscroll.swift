import Foundation

/// The cadence and directions of a selection drag held past the top or bottom edge, shared by the Mac
/// pane and the iPhone so both scroll a selection at the same speed.
public enum TerminalSelectionAutoscroll {
    /// One row per tick, as Ghostty's own selection scroll is.
    public static let interval: Duration = .milliseconds(15)

    public enum Direction: Equatable, Sendable {
        case towardOlderRows
        case towardNewerRows
    }
}
