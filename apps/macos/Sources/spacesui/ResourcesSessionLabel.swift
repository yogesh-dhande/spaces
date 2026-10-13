import Foundation
import spacesdevicecore

/// How a terminal session is named in the Resources table: the same project, workspace, and terminal
/// names the sidebar shows, read from the owning device's overview.
struct ResourcesSessionLabel: Equatable, Sendable {
    let sessionID: String
    let workspaceID: String
    let projectName: String
    let workspaceName: String
    let terminalName: String
    /// Whether the terminal runs a coding agent, which the table marks with the sidebar's agent glyph.
    let runsAgent: Bool
    /// Whether the workspace, or its project, is hidden from the sidebar. A hidden workspace still uses
    /// resources, so it is listed, but it has no sidebar row to select.
    let isHidden: Bool

    /// Labels for every live session in `overview`, keyed by session id.
    ///
    /// A session whose workspace is not in the overview is left out. The two are read from one
    /// snapshot, so that only happens while the overview is catching up with a session that was just
    /// created or closed, and the next overview names it.
    static func labels(from overview: SpacesDeviceOverviewPayload) -> [String: ResourcesSessionLabel] {
        let hiddenProjectIDs = Set(overview.projects.filter(\.isHidden).map(\.id))
        let workspacesByID = Dictionary(overview.workspaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var labels: [String: ResourcesSessionLabel] = [:]
        for session in overview.sessions {
            guard let workspace = workspacesByID[session.workspaceID] else { continue }
            let agentRow = workspace.codingAgentRows.first { $0.sessionID == session.id }
            let terminalName =
                agentRow?.name ?? workspace.processRows.first { $0.sessionID == session.id }?.name
                ?? workspace.terminalRows.first { $0.sessionID == session.id }?.title ?? session.title
            labels[session.id] = ResourcesSessionLabel(
                sessionID: session.id, workspaceID: workspace.id, projectName: workspace.projectName, workspaceName: workspace.displayName,
                terminalName: terminalName, runsAgent: agentRow != nil || session.foregroundDetectedAgentKind != nil,
                isHidden: workspace.isHidden || hiddenProjectIDs.contains(workspace.projectID))
        }
        return labels
    }
}
