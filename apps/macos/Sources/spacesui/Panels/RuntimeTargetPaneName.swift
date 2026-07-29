import spacesterminalcore

/// What a workspace's runtime target contributes to naming the pane that hosts its session, and the
/// rule that combines it with the pane's own live title.
///
/// The two sources age differently: the target's name comes from the device overview, which refreshes
/// on its poll cadence (and, for a global panel window, only when that panel re-renders), while the
/// pane's title changes the instant the shell retitles itself.
struct RuntimeTargetPaneName: Sendable, Equatable {
    /// The name the sidebar row shows for this target.
    let title: String
    /// The user's rename, when one pins the name.
    let pinnedTitle: String?
    /// Whether `title` identifies the target rather than describing what is running in it. A
    /// configured process, coding agent, or browser row is named by its config entry, so nothing the
    /// program inside prints may replace it; an ad hoc shell names itself after what it is running.
    let namesByIdentity: Bool

    /// The title a pane displays. A configured target keeps its identity name. An ad hoc shell
    /// resolves through the shared session-title rule with its pane as the live title, so a rename
    /// still pins the name while an unpinned shell follows the program it is running without waiting
    /// for the overview to catch up.
    static func paneTitle(_ name: RuntimeTargetPaneName?, liveTitle: String) -> String {
        guard let name else { return liveTitle }
        guard !name.namesByIdentity else { return name.title }
        return TerminalSessionTitle.effective(userTitle: name.pinnedTitle, runtimeTitle: liveTitle, launchTitle: name.title)
    }
}
