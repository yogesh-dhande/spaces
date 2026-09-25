import Observation

/// Whether each coding agent's brief sheet is up over its terminal, as the user last left it.
///
/// Owned by `SpacesMobileAppModel` rather than the terminal screen, which is rebuilt on every entry
/// and would forget the choice the moment the user navigated away. Keyed by the agent's runtime row id
/// (`agent:<row id>`), never by the session id: the brief belongs to the agent, not to the terminal it
/// happens to run in. In memory only, so a relaunch opens every brief again.
///
/// An agent the user has not touched opens its sheet whenever it has a brief. Dismissing the sheet
/// hides that agent's brief until the pill asks for it back, so the one fact worth storing is which
/// agents the user hid: asking for a brief back and never having hidden it behave the same.
@MainActor @Observable final class AgentBriefVisibility {
    private var hiddenAgentRowIDs: Set<String> = []

    /// Whether `row`'s brief sheet should be on screen: it has a brief, and the user has not hidden it.
    func isPresented(for row: SpacesMobileWorkspaceRuntimeRow) -> Bool { row.brief != nil && !hiddenAgentRowIDs.contains(row.id) }

    /// Records the user showing or hiding `row`'s brief. A row with no brief records nothing: the sheet
    /// closes on its own when the brief goes away, and that close is not the user hiding it, so the
    /// agent's next brief still opens by itself.
    func setPresented(_ isPresented: Bool, for row: SpacesMobileWorkspaceRuntimeRow) {
        guard row.brief != nil else { return }
        if isPresented { hiddenAgentRowIDs.remove(row.id) } else { hiddenAgentRowIDs.insert(row.id) }
    }
}
