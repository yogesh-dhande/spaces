import Foundation
import spacesmobilecore
import spacesterminalcore
import workspacecore

struct SpacesMobileOverviewBuilder {
    struct WorkspaceDescriptor: Sendable {
        let project: ProjectRecord
        let workspace: WorkspaceRecord
    }

    struct WorkspaceTerminalRow: Sendable {
        let entry: TerminalSessionCatalogEntry
        let workspace: WorkspaceDescriptor
        let title: String
        let rowKind: SpacesMobileTerminalSessionRowKind
        let rowSourceID: String
        let hasFinalRender: Bool
    }

    static func build(workspaces: [WorkspaceDescriptor], workspaceRows: [WorkspaceTerminalRow], liveSessions: [TerminalSessionCatalogEntry])
        -> SpacesMobileOverviewPayload
    {
        let representedSessionIDs = Set(workspaceRows.map { $0.entry.sessionID })
        let representedWorkspaceTitleSlots = Set(workspaceRows.map { "\($0.workspace.workspace.id)|\(normalizedSlotName($0.title))" })
        let matchedWorkspaceByLiveSessionID = Dictionary(
            uniqueKeysWithValues: liveSessions.map { session in
                (session.sessionID, matchedWorkspace(for: session.effectiveWorkingDirectory, workspaces: workspaces))
            })
        let adHocLiveSessions = liveSessions.filter { session in
            guard !representedSessionIDs.contains(session.sessionID) else { return false }
            guard let matchedWorkspace = matchedWorkspaceByLiveSessionID[session.sessionID] ?? nil else { return true }
            let workspaceID = matchedWorkspace.workspace.id
            return !representedWorkspaceTitleSlots.contains("\(workspaceID)|\(normalizedSlotName(session.effectiveTitle))")
        }
        let matchedWorkspaceBySessionID = Dictionary(
            uniqueKeysWithValues: adHocLiveSessions.map { session in (session.sessionID, matchedWorkspaceByLiveSessionID[session.sessionID] ?? nil) })

        let sessionsByWorkspaceID = Dictionary(
            grouping: workspaceRows.map { ($0.workspace.workspace.id, $0.entry.sessionID) }
                + matchedWorkspaceBySessionID.compactMap { sessionID, descriptor in descriptor.map { ($0.workspace.id, sessionID) } }, by: \.0)

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

        let workspaceSessionSummaries = workspaceRows.sorted { lhs, rhs in
            if lhs.workspace.project.name != rhs.workspace.project.name {
                return lhs.workspace.project.name.localizedStandardCompare(rhs.workspace.project.name) == .orderedAscending
            }
            if lhs.workspace.workspace.title != rhs.workspace.workspace.title {
                return lhs.workspace.workspace.title.localizedStandardCompare(rhs.workspace.workspace.title) == .orderedAscending
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }.map { row in
            summary(
                for: row.entry, matchedWorkspace: row.workspace, title: row.title, rowKind: row.rowKind, rowSourceID: row.rowSourceID,
                hasFinalRender: row.hasFinalRender)
        }

        let adHocSessionSummaries = adHocLiveSessions.sorted { lhs, rhs in
            if lhs.effectiveWorkingDirectory != rhs.effectiveWorkingDirectory {
                return lhs.effectiveWorkingDirectory.localizedStandardCompare(rhs.effectiveWorkingDirectory) == .orderedAscending
            }
            return lhs.effectiveTitle.localizedStandardCompare(rhs.effectiveTitle) == .orderedAscending
        }.map { session in
            let matchedWorkspace = matchedWorkspaceBySessionID[session.sessionID] ?? nil
            return summary(
                for: session, matchedWorkspace: matchedWorkspace, title: session.effectiveTitle, rowKind: .liveSession, rowSourceID: nil,
                hasFinalRender: false)
        }

        return SpacesMobileOverviewPayload(workspaces: workspaceSummaries, sessions: workspaceSessionSummaries + adHocSessionSummaries)
    }

    static func matchedWorkspace(for workingDirectory: String, workspaces: [WorkspaceDescriptor]) -> WorkspaceDescriptor? {
        let normalizedWorkingDirectory = normalizedPath(workingDirectory)
        return workspaces.filter { descriptor in
            let workspaceDirectory = normalizedPath(descriptor.workspace.dir)
            return normalizedWorkingDirectory == workspaceDirectory || normalizedWorkingDirectory.hasPrefix(workspaceDirectory + "/")
        }.max { lhs, rhs in normalizedPath(lhs.workspace.dir).count < normalizedPath(rhs.workspace.dir).count }
    }

    private static func summary(
        for session: TerminalSessionCatalogEntry, matchedWorkspace: WorkspaceDescriptor?, title: String, rowKind: SpacesMobileTerminalSessionRowKind,
        rowSourceID: String?, hasFinalRender: Bool
    ) -> SpacesMobileTerminalSessionSummary {
        let isInteractive = session.runtimeState.state.isInteractive
        return SpacesMobileTerminalSessionSummary(
            id: session.sessionID, title: title, workingDirectory: session.effectiveWorkingDirectory, state: session.runtimeState.state,
            backend: session.launchConfiguration.backend, lifetimePolicy: session.launchConfiguration.lifetimePolicy,
            servicePID: session.runtimeState.servicePID, childPID: session.runtimeState.childPID, workspaceID: matchedWorkspace?.workspace.id,
            workspaceTitle: matchedWorkspace?.workspace.title, projectID: matchedWorkspace?.project.id, projectName: matchedWorkspace?.project.name,
            createdAt: session.launchConfiguration.createdAt, updatedAt: session.runtimeState.updatedAt,
            isControlAvailable: isInteractive && session.isControlAvailable,
            isSubscriptionAvailable: isInteractive && session.isSubscriptionAvailable, attachmentSnapshot: session.attachmentSnapshot,
            rowKind: rowKind, rowSourceID: rowSourceID, hasFinalRender: hasFinalRender)
    }

    private static func normalizedPath(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }

    private static func normalizedSlotName(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
}
