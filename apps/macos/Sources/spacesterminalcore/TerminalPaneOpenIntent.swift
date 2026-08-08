import Foundation

/// What a launch asks the client to do with the pane it is about to open, carried beside the
/// attachment mode on the open-pane request. Attachment decides how the client attaches to the
/// session; this decides what the open does to the window and the layout.
public struct TerminalPaneOpenIntent: Sendable, Equatable {
    /// Whether the open may move the caret, select a tab, or bring a panel forward.
    public var focus: TerminalOpenFocusIntent
    /// The session this one takes over from, when the launch is a replacement (a restart relaunching a
    /// configured process). The client points that session's existing pane at this session instead of
    /// installing a second one, so the pane keeps its tab, its split, and its window. Nil for a launch
    /// that replaces nothing.
    public var replacesSessionID: String?

    public init(focus: TerminalOpenFocusIntent, replacesSessionID: String? = nil) {
        self.focus = focus
        self.replacesSessionID = replacesSessionID
    }

    /// What a user asking for a terminal wants: bring it forward, focused, as its own pane.
    public static let focused = TerminalPaneOpenIntent(focus: .focus)
}

/// What a client should do with a pane whose session the daemon is closing.
public enum TerminalPaneCloseDisposition: String, Codable, Sendable, CaseIterable {
    /// The session is gone for good: tear the pane down.
    case teardown
    /// The session is being replaced by one the daemon is about to launch. The pane is held where it is
    /// so the replacement can claim it, instead of being torn down and re-added at the end of the tab
    /// strip. The daemon guarantees the hold ends: every reservation is either claimed by the
    /// replacement's open or released by a plain `teardown` close before the operation returns.
    case awaitReplacement
}
