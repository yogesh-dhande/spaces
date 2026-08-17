import Foundation

/// Effective-visibility rule for any surface that lists workspaces or derives events from an overview
/// payload. `isHidden` on a project is daemon-owned state independent of the workspace-level flag rather
/// than a bulk edit of it, so hiding a project suppresses its workspaces without overwriting what the user
/// chose for each one, and a workspace is visible only while neither it nor its project is hidden.
extension SpacesDeviceOverviewPayload {
    /// Whether the project identified by `projectID` is hidden, or `false` if this overview does not
    /// (yet) carry a project with that id.
    public func isProjectHidden(forProjectID projectID: String) -> Bool { projects.first { $0.id == projectID }?.isHidden ?? false }

    /// `!workspace.isHidden && !project.isHidden`, the rule every visible-surface filter applies. The
    /// project is looked up by the workspace's `projectID` against this overview's own `projects`.
    public func isWorkspaceVisible(_ workspace: SpacesDeviceWorkspaceSummary) -> Bool {
        !workspace.isHidden && !isProjectHidden(forProjectID: workspace.projectID)
    }
}
