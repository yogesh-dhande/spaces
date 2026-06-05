import Foundation
import spacesmobilecore
import spacesterminalcore
import workspacecore

struct SpacesMobileOverviewBuilder {
    struct WorkspaceDescriptor: Sendable {
        let project: ProjectRecord
        let workspace: WorkspaceRecord
        let settings: WorkspaceSettings?
        let runningProcesses: [RunningProcessRecord]
        let agentWindows: [AgentWindowRecord]
        let windows: [WindowRecord]

        init(
            project: ProjectRecord, workspace: WorkspaceRecord, settings: WorkspaceSettings? = nil, runningProcesses: [RunningProcessRecord] = [],
            agentWindows: [AgentWindowRecord] = [], windows: [WindowRecord] = []
        ) {
            self.project = project
            self.workspace = workspace
            self.settings = settings
            self.runningProcesses = runningProcesses
            self.agentWindows = agentWindows
            self.windows = windows
        }
    }

    struct WorkspaceTerminalRow: Sendable {
        let entry: TerminalSessionCatalogEntry
        let workspace: WorkspaceDescriptor
        let title: String
        let rowKind: SpacesMobileTerminalSessionRowKind
        let rowSourceID: String
        let hasFinalRender: Bool
    }

    static func build(projects: [ProjectRecord] = [], workspaces: [WorkspaceDescriptor], sessions: [TerminalSessionCatalogEntry])
        -> SpacesMobileOverviewPayload
    { build(projects: projects, workspaces: workspaces, workspaceRows: [], liveSessions: sessions) }

    static func build(
        projects: [ProjectRecord] = [], workspaces: [WorkspaceDescriptor], workspaceRows: [WorkspaceTerminalRow],
        liveSessions: [TerminalSessionCatalogEntry]
    ) -> SpacesMobileOverviewPayload {
        let representedSessionIDs = Set(workspaceRows.map { $0.entry.sessionID })
        let matchedWorkspaceByLiveSessionID = Dictionary(
            uniqueKeysWithValues: liveSessions.map { session in (session.sessionID, matchedWorkspace(for: session, workspaces: workspaces)) })
        let adHocLiveSessions = liveSessions.filter { session in !representedSessionIDs.contains(session.sessionID) }
        let matchedWorkspaceBySessionID = Dictionary(
            uniqueKeysWithValues: adHocLiveSessions.map { session in (session.sessionID, matchedWorkspaceByLiveSessionID[session.sessionID] ?? nil) })

        let sessionsByWorkspaceID = Dictionary(
            grouping: workspaceRows.map { ($0.workspace.workspace.id, $0.entry.sessionID) }
                + matchedWorkspaceBySessionID.compactMap { sessionID, descriptor in descriptor.map { ($0.workspace.id, sessionID) } }, by: \.0)

        let sessionEntriesByID = Dictionary(
            (liveSessions + workspaceRows.map(\.entry)).map { ($0.sessionID, $0) }, uniquingKeysWith: { liveSession, _ in liveSession })
        let availableSessionIDs = Set(sessionEntriesByID.keys)
        let projectSummaries = projectSummaries(from: projects.isEmpty ? workspaces.map(\.project) : projects)

        let workspaceSummaries = workspaces.sorted { lhs, rhs in
            if lhs.project.name != rhs.project.name { return lhs.project.name.localizedStandardCompare(rhs.project.name) == .orderedAscending }
            return lhs.workspace.title.localizedStandardCompare(rhs.workspace.title) == .orderedAscending
        }.map { descriptor in
            let runtimeRows = runtimeRows(for: descriptor, availableSessionIDs: availableSessionIDs, sessionsByID: sessionEntriesByID)
            return SpacesMobileWorkspaceSummary(
                id: descriptor.workspace.id, projectID: descriptor.project.id, projectName: descriptor.project.name,
                title: descriptor.workspace.title, branch: descriptor.workspace.branch, targetBranch: descriptor.workspace.targetBranch,
                dir: descriptor.workspace.dir, isRunning: descriptor.workspace.isRunning, isArchived: descriptor.workspace.isArchived,
                isHidden: descriptor.workspace.isHidden, isDefault: descriptor.workspace.isDefault,
                sessionCount: sessionsByWorkspaceID[descriptor.workspace.id]?.count ?? 0, processRows: runtimeRows.processes,
                codingAgentRows: runtimeRows.agents, terminalRows: runtimeRows.terminals)
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

        return SpacesMobileOverviewPayload(
            projects: projectSummaries, workspaces: workspaceSummaries, sessions: workspaceSessionSummaries + adHocSessionSummaries)
    }

    static func matchedWorkspace(for workingDirectory: String, workspaces: [WorkspaceDescriptor]) -> WorkspaceDescriptor? {
        let normalizedWorkingDirectory = normalizedPath(workingDirectory)
        return workspaces.filter { descriptor in
            let workspaceDirectory = normalizedPath(descriptor.workspace.dir)
            return normalizedWorkingDirectory == workspaceDirectory || normalizedWorkingDirectory.hasPrefix(workspaceDirectory + "/")
        }.max { lhs, rhs in normalizedPath(lhs.workspace.dir).count < normalizedPath(rhs.workspace.dir).count }
    }

    static func matchedWorkspace(for session: TerminalSessionCatalogEntry, workspaces: [WorkspaceDescriptor]) -> WorkspaceDescriptor? {
        if let workspaceID = session.workspaceID { return workspaces.first { $0.workspace.id == workspaceID } }
        return matchedWorkspace(for: session.effectiveWorkingDirectory, workspaces: workspaces)
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

    private static func projectSummaries(from projects: [ProjectRecord]) -> [SpacesMobileProjectSummary] {
        var seen = Set<String>()
        return projects.sorted { lhs, rhs in lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }.compactMap { project in
            guard !seen.contains(project.id) else { return nil }
            seen.insert(project.id)
            return SpacesMobileProjectSummary(
                id: project.id, name: project.name, dir: project.dir, isGitRepo: project.isGitRepo, defaultBranch: project.defaultBranch,
                isCollapsed: project.isCollapsed)
        }
    }

    private struct WorkspaceRows {
        let processes: [SpacesMobileWorkspaceProcessRow]
        let agents: [SpacesMobileWorkspaceCodingAgentRow]
        let terminals: [SpacesMobileWorkspaceTerminalRow]
    }

    private struct ProcessRows {
        let rows: [SpacesMobileWorkspaceProcessRow]
        let claimedTerminalKeys: Set<String>
    }

    private struct CodingAgentRows {
        let rows: [SpacesMobileWorkspaceCodingAgentRow]
        let claimedTerminalKeys: Set<String>
    }

    private static func runtimeRows(
        for descriptor: WorkspaceDescriptor, availableSessionIDs: Set<String>, sessionsByID: [String: TerminalSessionCatalogEntry]
    ) -> WorkspaceRows {
        let processRows = processRows(for: descriptor, availableSessionIDs: availableSessionIDs)
        let agentRows = codingAgentRows(for: descriptor, sessionsByID: sessionsByID)
        let claimedTerminalKeys = processRows.claimedTerminalKeys.union(agentRows.claimedTerminalKeys)
        let terminalRows = workspaceTerminalRows(for: descriptor, sessionsByID: sessionsByID, claimedTerminalKeys: claimedTerminalKeys)
        return WorkspaceRows(processes: processRows.rows, agents: agentRows.rows, terminals: terminalRows)
    }

    private static func processRows(for descriptor: WorkspaceDescriptor, availableSessionIDs: Set<String>) -> ProcessRows {
        var usedProcessIDs = Set<String>()
        var claimedTerminalKeys = Set<String>()
        var rows: [SpacesMobileWorkspaceProcessRow] = []
        let runningByTemplateID = Dictionary(
            descriptor.runningProcesses.compactMap { process -> (String, RunningProcessRecord)? in
                guard let templateID = process.templateID?.trimmingCharacters(in: .whitespacesAndNewlines), !templateID.isEmpty else { return nil }
                return (templateID, process)
            }, uniquingKeysWith: { existing, _ in existing })
        let runningByKey = Dictionary(
            descriptor.runningProcesses.map { (normalizedRunRowName($0.templateName), $0) }, uniquingKeysWith: { existing, _ in existing })
        for template in descriptor.settings?.processes ?? [] {
            let key = normalizedRunRowName(template.name ?? "")
            guard !key.isEmpty else { continue }
            let runningProcess = runningByTemplateID[template.id] ?? runningByKey[key]
            if let runningProcess {
                usedProcessIDs.insert(runningProcess.id)
                if let claimedKey = terminalTrackingKey(runningProcess) { claimedTerminalKeys.insert(claimedKey) }
            }
            let state = processRunState(runningProcess)
            let rawSessionID = terminalSessionID(for: runningProcess)
            let availableSessionID = rawSessionID.flatMap { availableSessionIDs.contains($0) ? $0 : nil }
            let isRunning = state == .running
            rows.append(
                SpacesMobileWorkspaceProcessRow(
                    id: template.id, workspaceID: descriptor.workspace.id, name: template.name ?? "", command: template.command,
                    templateID: template.id, processID: runningProcess?.id, sessionID: availableSessionID, runState: state, canRun: !isRunning,
                    canStop: isRunning, canRestart: isRunning))
        }

        for runningProcess in descriptor.runningProcesses where !usedProcessIDs.contains(runningProcess.id) {
            if let claimedKey = terminalTrackingKey(runningProcess) { claimedTerminalKeys.insert(claimedKey) }
            let state = processRunState(runningProcess)
            let rawSessionID = terminalSessionID(for: runningProcess)
            let availableSessionID = rawSessionID.flatMap { availableSessionIDs.contains($0) ? $0 : nil }
            let isRunning = state == .running
            let name = runningProcess.templateName.trimmingCharacters(in: .whitespacesAndNewlines)
            rows.append(
                SpacesMobileWorkspaceProcessRow(
                    id: "process-runtime:\(runningProcess.id)", workspaceID: descriptor.workspace.id, name: name.isEmpty ? "Process" : name,
                    command: runningProcess.command, templateID: runningProcess.templateID, processID: runningProcess.id,
                    sessionID: availableSessionID, runState: state, canRun: false, canStop: isRunning, canRestart: false))
        }
        return ProcessRows(rows: rows, claimedTerminalKeys: claimedTerminalKeys)
    }

    private static func codingAgentRows(for descriptor: WorkspaceDescriptor, sessionsByID: [String: TerminalSessionCatalogEntry]) -> CodingAgentRows {
        var usedAgentIDs = Set<String>()
        var claimedTerminalKeys = Set<String>()
        var rows: [SpacesMobileWorkspaceCodingAgentRow] = []
        let configuredLaunchers = descriptor.settings?.agentLaunchers ?? []
        let agentByConfiguredID = Dictionary(
            descriptor.agentWindows.compactMap { agent -> (String, AgentWindowRecord)? in
                guard let id = agent.claimedLauncherID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
                return (id, agent)
            }, uniquingKeysWith: { existing, _ in existing })
        let agentByConfiguredName = Dictionary(
            descriptor.agentWindows.compactMap { agent -> (String, AgentWindowRecord)? in
                guard agent.claimedLauncherID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return nil }
                let names = [agent.claimedLauncherName, agent.label].compactMap { $0 }.map(normalizedRunRowName).filter { !$0.isEmpty }
                guard let name = names.first else { return nil }
                return (name, agent)
            }, uniquingKeysWith: { existing, _ in existing })

        for launcher in configuredLaunchers {
            let key = normalizedRunRowName(launcher.name)
            guard !key.isEmpty else { continue }
            let agent = agentByConfiguredID[launcher.id] ?? agentByConfiguredName[key]
            if let agent {
                usedAgentIDs.insert(agent.id)
                if let claimedKey = terminalTrackingKey(agent) { claimedTerminalKeys.insert(claimedKey) }
            }
            rows.append(
                codingAgentRow(
                    id: "configured-agent:\(descriptor.workspace.id):\(launcher.id)", workspaceID: descriptor.workspace.id, name: launcher.name,
                    command: launcher.command, launcherID: launcher.id, agent: agent, isConfigured: true, sessionsByID: sessionsByID))
        }

        for agent in descriptor.agentWindows where !usedAgentIDs.contains(agent.id) {
            if let claimedKey = terminalTrackingKey(agent) { claimedTerminalKeys.insert(claimedKey) }
            rows.append(
                codingAgentRow(
                    id: "agent:\(agent.id)", workspaceID: descriptor.workspace.id, name: agent.label ?? agent.claimedLauncherName ?? "Coding Agent",
                    command: terminalDetail(for: agent, windows: descriptor.windows) ?? "", launcherID: agent.claimedLauncherID, agent: agent,
                    isConfigured: false, sessionsByID: sessionsByID))
        }
        return CodingAgentRows(rows: rows, claimedTerminalKeys: claimedTerminalKeys)
    }

    private static func codingAgentRow(
        id: String, workspaceID: String, name: String, command: String, launcherID: String?, agent: AgentWindowRecord?, isConfigured: Bool,
        sessionsByID: [String: TerminalSessionCatalogEntry]
    ) -> SpacesMobileWorkspaceCodingAgentRow {
        let rawSessionID = terminalSessionID(for: agent)
        let session = rawSessionID.flatMap { sessionsByID[$0] }
        let runState = agentRunState(agent: agent, session: session)
        let canRun = isConfigured && runState != .running
        let canStop = agent != nil
        let hasClaimedLauncherID = agent?.claimedLauncherID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasClaimedLauncherName = agent?.claimedLauncherName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let canRestart = agent != nil && (isConfigured || hasClaimedLauncherID || hasClaimedLauncherName)
        return SpacesMobileWorkspaceCodingAgentRow(
            id: id, workspaceID: workspaceID, name: name, command: command, launcherID: launcherID, agentID: agent?.id, sessionID: session?.sessionID,
            isConfigured: isConfigured, runState: runState, activityState: activityState(for: agent), canRun: canRun, canStop: canStop,
            canRestart: canRestart)
    }

    private static func workspaceTerminalRows(
        for descriptor: WorkspaceDescriptor, sessionsByID: [String: TerminalSessionCatalogEntry], claimedTerminalKeys: Set<String>
    ) -> [SpacesMobileWorkspaceTerminalRow] {
        var rows: [SpacesMobileWorkspaceTerminalRow] = []
        var includedSessionIDs = Set<String>()
        for window in descriptor.windows where window.role == "terminal" {
            if let key = terminalTrackingKey(window), claimedTerminalKeys.contains(key) { continue }
            let rawSessionID = terminalSessionID(for: window)
            let session = rawSessionID.flatMap { sessionsByID[$0] }
            if let rawSessionID { includedSessionIDs.insert(rawSessionID) }
            let runState = session.map(runState(for:)) ?? (rawSessionID == nil ? .running : .exited)
            rows.append(
                SpacesMobileWorkspaceTerminalRow(
                    id: "terminal-window:\(window.id)", workspaceID: descriptor.workspace.id,
                    title: window.name ?? session?.effectiveTitle ?? "Workspace Terminal", workingDirectory: descriptor.workspace.dir,
                    sessionID: session?.sessionID, runState: runState, canOpenTerminal: session != nil,
                    canStop: runState == .running && session?.sessionID != nil))
        }

        for (sessionID, session) in sessionsByID where !includedSessionIDs.contains(sessionID) {
            if let workspaceID = session.workspaceID {
                guard workspaceID == descriptor.workspace.id else { continue }
            } else {
                guard let matched = matchedWorkspace(for: session.effectiveWorkingDirectory, workspaces: [descriptor]),
                    matched.workspace.id == descriptor.workspace.id
                else { continue }
            }
            let sessionKey = "terminal:\(sessionID)"
            guard !claimedTerminalKeys.contains(sessionKey) else { continue }
            let runState = runState(for: session)
            rows.append(
                SpacesMobileWorkspaceTerminalRow(
                    id: "terminal-session:\(sessionID)", workspaceID: descriptor.workspace.id, title: session.effectiveTitle,
                    workingDirectory: session.effectiveWorkingDirectory, sessionID: sessionID, runState: runState, canOpenTerminal: true,
                    canStop: runState == .running))
        }

        return rows.sorted { lhs, rhs in lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending }
    }

    private static func processRunState(_ process: RunningProcessRecord?) -> SpacesMobileRunState {
        guard let process else { return .notStarted }
        return process.status == .exited ? .exited : .running
    }

    private static func agentRunState(agent: AgentWindowRecord?, session: TerminalSessionCatalogEntry?) -> SpacesMobileRunState {
        guard agent != nil else { return .notStarted }
        guard let session else { return .exited }
        return runState(for: session)
    }

    private static func runState(for session: TerminalSessionCatalogEntry) -> SpacesMobileRunState {
        session.runtimeState.state.isInteractive ? .running : .exited
    }

    private static func activityState(for agent: AgentWindowRecord?) -> SpacesMobileCodingAgentActivityState {
        switch agent?.status {
        case .spinning: return .spinning
        case .waiting: return .waiting
        case .done: return .done
        case .idle, nil: return .idle
        }
    }

    private static func terminalSessionID(for process: RunningProcessRecord?) -> String? {
        guard let sessionID = process?.terminalNativeID ?? process?.terminalTrackingID, !sessionID.isEmpty else { return nil }
        return sessionID
    }

    private static func terminalSessionID(for agent: AgentWindowRecord?) -> String? {
        guard let sessionID = agent?.terminalNativeID ?? agent?.terminalTrackingID, !sessionID.isEmpty else { return nil }
        return sessionID
    }

    private static func terminalSessionID(for window: WindowRecord) -> String? {
        guard let sessionID = window.terminalNativeID ?? window.terminalTrackingID, !sessionID.isEmpty else { return nil }
        return sessionID
    }

    private static func terminalTrackingKey(_ process: RunningProcessRecord) -> String? {
        terminalSessionID(for: process).map { "terminal:\($0)" } ?? process.windowID.map { "window:\($0)" }
    }

    private static func terminalTrackingKey(_ agent: AgentWindowRecord) -> String? {
        terminalSessionID(for: agent).map { "terminal:\($0)" } ?? (agent.yabaiWindowID ?? agent.windowID).map { "window:\($0)" }
    }

    private static func terminalTrackingKey(_ window: WindowRecord) -> String? {
        terminalSessionID(for: window).map { "terminal:\($0)" } ?? window.windowID.map { "window:\($0)" }
    }

    private static func terminalDetail(for agent: AgentWindowRecord, windows: [WindowRecord]) -> String? {
        guard let key = terminalTrackingKey(agent) else { return nil }
        return windows.first(where: { terminalTrackingKey($0) == key }).flatMap { $0.detail ?? $0.name }
    }

    private static func normalizedRunRowName(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
}
