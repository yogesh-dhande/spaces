import Foundation
import spacesmobilecore
import spacesterminalcore
import workspacecore

struct SpacesMobileOverviewBuilder {
    struct WorkspaceDescriptor: Sendable {
        let project: ProjectRecord
        let workspace: WorkspaceRecord
    }

    static func build(workspaces: [WorkspaceDescriptor], sessions: [TerminalSessionCatalogEntry]) -> SpacesMobileOverviewPayload {
        let matchedWorkspaceBySessionID = Dictionary(
            uniqueKeysWithValues: sessions.map { session in
                (session.sessionID, matchedWorkspace(for: session.effectiveWorkingDirectory, workspaces: workspaces))
            })

        let sessionsByWorkspaceID = Dictionary(
            grouping: matchedWorkspaceBySessionID.compactMap { sessionID, descriptor in descriptor.map { ($0.workspace.id, sessionID) } }, by: \.0)

        let workspaceSummaries = workspaces.sorted { lhs, rhs in
            if lhs.project.name != rhs.project.name { return lhs.project.name.localizedStandardCompare(rhs.project.name) == .orderedAscending }
            return lhs.workspace.title.localizedStandardCompare(rhs.workspace.title) == .orderedAscending
        }.map { descriptor in
            SpacesMobileWorkspaceSummary(
                id: descriptor.workspace.id, projectID: descriptor.project.id, projectName: descriptor.project.name,
                title: descriptor.workspace.title, branch: descriptor.workspace.branch, targetBranch: descriptor.workspace.targetBranch,
                dir: descriptor.workspace.dir, isRunning: descriptor.workspace.isRunning, isArchived: descriptor.workspace.isArchived,
                isHidden: descriptor.workspace.isHidden, isDefault: descriptor.workspace.isDefault,
                sessionCount: sessionsByWorkspaceID[descriptor.workspace.id]?.count ?? 0)
        }

        let sessionSummaries = sessions.sorted { lhs, rhs in
            if lhs.effectiveWorkingDirectory != rhs.effectiveWorkingDirectory {
                return lhs.effectiveWorkingDirectory.localizedStandardCompare(rhs.effectiveWorkingDirectory) == .orderedAscending
            }
            return lhs.effectiveTitle.localizedStandardCompare(rhs.effectiveTitle) == .orderedAscending
        }.map { session in
            let matchedWorkspace = matchedWorkspaceBySessionID[session.sessionID] ?? nil
            return SpacesMobileTerminalSessionSummary(
                id: session.sessionID, title: session.effectiveTitle, workingDirectory: session.effectiveWorkingDirectory,
                state: session.runtimeState.state, backend: session.launchConfiguration.backend,
                lifetimePolicy: session.launchConfiguration.lifetimePolicy, servicePID: session.runtimeState.servicePID,
                childPID: session.runtimeState.childPID, workspaceID: matchedWorkspace?.workspace.id,
                workspaceTitle: matchedWorkspace?.workspace.title, projectID: matchedWorkspace?.project.id,
                projectName: matchedWorkspace?.project.name, createdAt: session.launchConfiguration.createdAt,
                updatedAt: session.runtimeState.updatedAt, isControlAvailable: session.isControlAvailable,
                isSubscriptionAvailable: session.isSubscriptionAvailable, attachmentSnapshot: session.attachmentSnapshot)
        }

        return SpacesMobileOverviewPayload(workspaces: workspaceSummaries, sessions: sessionSummaries)
    }

    static func matchedWorkspace(for workingDirectory: String, workspaces: [WorkspaceDescriptor]) -> WorkspaceDescriptor? {
        let normalizedWorkingDirectory = normalizedPath(workingDirectory)
        return workspaces.filter { descriptor in
            let workspaceDirectory = normalizedPath(descriptor.workspace.dir)
            return normalizedWorkingDirectory == workspaceDirectory || normalizedWorkingDirectory.hasPrefix(workspaceDirectory + "/")
        }.max { lhs, rhs in normalizedPath(lhs.workspace.dir).count < normalizedPath(rhs.workspace.dir).count }
    }

    private static func normalizedPath(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
}
