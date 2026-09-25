import AppKit

/// Where a pane's brief stands for the surfaces that toggle it (the workspace footer glyph, the ⋯ menu
/// item, a global panel window's strip glyph, and ⌥⌘B).
enum AgentBriefToggleState: Equatable, Sendable {
    /// The pane's session belongs to no coding agent with a brief, so there is nothing to toggle.
    case unavailable
    case shown
    case hidden

    /// The action a toggle surface offers: the opposite of the current state.
    var toggleTitle: String { self == .shown ? "Hide Brief" : "Show Brief" }
}

extension NSButton {
    /// Renders a brief toggle glyph for `state`: absent when there is no brief, accent while the column
    /// is shown, muted while it is hidden, and titled with the action a click performs.
    func applyAgentBriefToggleState(_ state: AgentBriefToggleState) {
        isHidden = state == .unavailable
        contentTintColor = state == .shown ? Theme.accent : Theme.muted
        toolTip = state.toggleTitle
        setAccessibilityLabel(state.toggleTitle)
    }
}
