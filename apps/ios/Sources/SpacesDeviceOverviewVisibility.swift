import Foundation
import spacesdevicecore

/// Effective-visibility rule shared by every surface that lists workspaces or derives events from them —
/// the Spaces tab's browse list, the Agents tab, and the Alerts tab. `isHidden` on a project is
/// daemon-owned state mirroring the workspace-level flag (mutated only from the Mac's Workspace
/// Visibility dialog; iOS has no UI to hide a project, only to recover one via `unhideProject`), so a
/// workspace is visible only while neither it nor its project is hidden.
extension SpacesDeviceOverviewPayload {
    /// Whether the project identified by `projectID` is hidden, or `false` if this overview does not
    /// (yet) carry a project with that id.
    func isProjectHidden(forProjectID projectID: String) -> Bool { projects.first { $0.id == projectID }?.isHidden ?? false }

    /// `!workspace.isHidden && !project.isHidden`, the rule every visible-surface filter applies. The
    /// project is looked up by the workspace's `projectID` against this overview's own `projects`.
    func isWorkspaceVisible(_ workspace: SpacesDeviceWorkspaceSummary) -> Bool {
        !workspace.isHidden && !isProjectHidden(forProjectID: workspace.projectID)
    }
}
