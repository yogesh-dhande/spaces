import Foundation

/// Builds the visibility outline straight from a Device API overview payload, which is the form a
/// single-device client (iOS) holds its projects and workspaces in.
extension WorkspaceVisibilityTree {
    /// The project -> workspace outline for everything one device reports, in the overview's own project
    /// order. Hidden projects and hidden workspaces are listed like any other, since this outline is where
    /// they are brought back.
    public static func projectNodes(overview: SpacesDeviceOverviewPayload, query: String) -> [WorkspaceVisibilityProjectNode] {
        var workspacesByProject: [String: [Workspace]] = [:]
        for workspace in overview.workspaces {
            workspacesByProject[workspace.projectID, default: []].append(
                Workspace(id: workspace.id, name: workspace.displayName, isDefault: workspace.isDefault, isHidden: workspace.isHidden))
        }
        let projects = overview.projects.map { Project(id: $0.id, name: $0.name, isGitRepo: $0.isGitRepo, isHidden: $0.isHidden) }
        return projectNodes(projects: projects, workspacesByProject: workspacesByProject, query: query)
    }
}
