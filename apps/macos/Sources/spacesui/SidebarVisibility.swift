import Foundation
import workspacecore

/// The rules deciding which projects and workspaces the sidebar shows.
///
/// Every surface that renders the sidebar's model — the outline itself, arrow navigation, the
/// window cycle order, the automation editor's workspace picker — reads through
/// `SidebarController.deviceProjects` / `visibleWorkspaces`. The command palette's workspace walk
/// (`AppKitController.deviceCommandPaletteWorkspaceItems`) and the terminal pane's session picker
/// (`orderedSessionPickerWorkspaceContexts`) list the same rows in the same order and call these
/// rules directly. Keeping the rules here (pure, host-free) is what stops "is this row shown?" from
/// being re-answered slightly differently at each of those sites.
///
/// The Workspaces visibility dialog deliberately does not use these: it lists everything, because it
/// is the only surface that can bring a hidden row back.
enum SidebarVisibility {
    /// A workspace is shown only when neither it nor its owning project is hidden.
    ///
    /// Project hiding is a second, independent flag rather than a bulk edit of the child flags, so
    /// hiding a project suppresses its workspaces without overwriting what the user chose for each
    /// one — unhiding the project restores exactly the set that was shown before.
    ///
    /// A nil project means the workspace's project is not in the loaded model at all, which leaves no
    /// row to render it under; the workspace is not shown.
    static func isVisibleWorkspace(_ workspace: WorkspaceSummary, inProject project: ProjectSummary?) -> Bool {
        guard let project, !project.isHidden else { return false }
        return !workspace.isHidden
    }

    /// The projects the sidebar lists under one device header.
    ///
    /// A hidden project leaves the sidebar entirely — header and children — the same way a hidden
    /// workspace does, and stays reachable only from the Workspaces dialog.
    ///
    /// A non-git project's row stands in for its single workspace. If that workspace is hidden the
    /// project has no visible workspace, so the row is dropped rather than left as a dead stand-in
    /// that selects nothing.
    static func deviceProjects(_ projects: [ProjectSummary], deviceID: String, workspacesByProject: [String: [WorkspaceSummary]]) -> [ProjectSummary]
    {
        projects.filter { project in
            guard project.deviceID == deviceID, !project.isHidden else { return false }
            guard !project.isGitRepo else { return true }
            return (workspacesByProject[project.id] ?? []).contains { isVisibleWorkspace($0, inProject: project) }
        }
    }
}
