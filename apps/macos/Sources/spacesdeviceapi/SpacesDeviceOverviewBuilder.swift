import Foundation
import spacesdevicecore
import spacesterminalcore
import workspacecore

struct SpacesDeviceOverviewBuilder {
    struct WorkspaceDescriptor: Sendable {
        let project: ProjectRecord
        let workspace: WorkspaceRecord
        let settings: WorkspaceSettings?
        let assignedPorts: [SpacesDeviceAssignedPort]
        let environment: [String: String]
        let resolvedBrowserSessions: [BrowserSession]
        let setupState: WorkspaceSetupState?
        let runningProcesses: [RunningProcessRecord]
        let agentWindows: [AgentWindowRecord]
        let windows: [WindowRecord]

        init(
            project: ProjectRecord, workspace: WorkspaceRecord, settings: WorkspaceSettings? = nil, runningProcesses: [RunningProcessRecord] = [],
            agentWindows: [AgentWindowRecord] = [], windows: [WindowRecord] = [], assignedPorts: [SpacesDeviceAssignedPort] = [],
            environment: [String: String] = [:], resolvedBrowserSessions: [BrowserSession] = [], setupState: WorkspaceSetupState? = nil
        ) {
            self.project = project
            self.workspace = workspace
            self.settings = settings
            self.assignedPorts = assignedPorts
            self.environment = environment
            self.resolvedBrowserSessions = resolvedBrowserSessions
            self.setupState = setupState
            self.runningProcesses = runningProcesses
            self.agentWindows = agentWindows
            self.windows = windows
        }
    }

    struct WorkspaceTerminalRow: Sendable {
        let entry: TerminalSessionCatalogEntry
        let workspace: WorkspaceDescriptor
        let title: String
        let rowKind: SpacesDeviceTerminalSessionRowKind
        let rowSourceID: String
        let hasFinalRender: Bool
    }

    static func build(
        projects: [ProjectRecord] = [], workspaces: [WorkspaceDescriptor], workspaceRows: [WorkspaceTerminalRow],
        liveSessions: [TerminalSessionCatalogEntry], workspaceIDsWithTeardownInFlight: [String] = [], daemonStatus: TerminalServiceDaemonStatus
    ) -> SpacesDeviceOverviewPayload {
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
            // Pin each project's default workspace to the top so every client (macOS sidebar, iOS) renders the
            // same order. macOS re-applies this same tiebreaker in its sidebar; making it canonical here keeps the
            // clients from diverging and lets iOS inherit the order verbatim.
            if lhs.workspace.isDefault != rhs.workspace.isDefault { return lhs.workspace.isDefault }
            return lhs.workspace.displayName.localizedStandardCompare(rhs.workspace.displayName) == .orderedAscending
        }.map { descriptor in
            let runtimeRows = runtimeRows(for: descriptor, availableSessionIDs: availableSessionIDs, sessionsByID: sessionEntriesByID)
            return SpacesDeviceWorkspaceSummary(
                id: descriptor.workspace.id, projectID: descriptor.project.id, projectName: descriptor.project.name,
                branch: descriptor.workspace.branch, baseBranch: descriptor.workspace.baseBranch, dir: descriptor.workspace.dir,
                isRunning: descriptor.workspace.isRunning, isHidden: descriptor.workspace.isHidden, isDefault: descriptor.workspace.isDefault,
                notes: descriptor.workspace.notes, sessionCount: sessionsByWorkspaceID[descriptor.workspace.id]?.count ?? 0,
                assignedPorts: descriptor.assignedPorts, environment: descriptor.environment,
                setupState: descriptor.setupState.map(deviceWorkspaceSetupState),
                config: workspaceConfig(from: descriptor.settings, resolvedBrowserSessions: descriptor.resolvedBrowserSessions),
                processRows: runtimeRows.processes, codingAgentRows: runtimeRows.agents, terminalRows: runtimeRows.terminals)
        }

        let workspaceSessionSummaries = workspaceRows.sorted { lhs, rhs in
            if lhs.workspace.project.name != rhs.workspace.project.name {
                return lhs.workspace.project.name.localizedStandardCompare(rhs.workspace.project.name) == .orderedAscending
            }
            if lhs.workspace.workspace.displayName != rhs.workspace.workspace.displayName {
                return lhs.workspace.workspace.displayName.localizedStandardCompare(rhs.workspace.workspace.displayName) == .orderedAscending
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }.map { row in
            // A summary describes its session exactly as the row claiming it does, since the surfaces that
            // list sessions rather than rows (a bell's Alerts row, the iOS session list) read the pairing
            // off the summary: an ad hoc shell and a coding agent both carry the title their program
            // reports, and a configured process carries none, because the command its configured entry
            // names already says what it is doing.
            summary(
                for: row.entry, matchedWorkspace: row.workspace, title: row.title, liveTitle: row.rowKind == .agent ? row.entry.liveTitle : nil,
                rowKind: row.rowKind, rowSourceID: row.rowSourceID, hasFinalRender: row.hasFinalRender)
        }

        let adHocSessionSummaries = adHocLiveSessions.sorted { lhs, rhs in
            if lhs.effectiveWorkingDirectory != rhs.effectiveWorkingDirectory {
                return lhs.effectiveWorkingDirectory.localizedStandardCompare(rhs.effectiveWorkingDirectory) == .orderedAscending
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }.map { session in
            let matchedWorkspace = matchedWorkspaceBySessionID[session.sessionID] ?? nil
            return summary(
                for: session, matchedWorkspace: matchedWorkspace, title: session.name, liveTitle: session.liveTitle, rowKind: .liveSession,
                rowSourceID: nil, hasFinalRender: false)
        }

        return SpacesDeviceOverviewPayload(
            projects: projectSummaries, workspaces: workspaceSummaries, sessions: workspaceSessionSummaries + adHocSessionSummaries,
            retainedTerminalSessionIDs: retainedTerminalSessionIDs(liveSessions: liveSessions, workspaces: workspaces),
            workspaceIDsWithTeardownInFlight: workspaceIDsWithTeardownInFlight, daemonStatus: daemonStatus)
    }

    /// The keep-set the daemon publishes on `SpacesDeviceOverviewPayload.retainedTerminalSessionIDs`:
    /// every terminal session id whose pane and transcript the daemon still retains.
    ///
    /// This is the daemon's authoritative retention rule, mirroring the session garbage collector's
    /// `SQLiteStore.terminalSessionIsReferencedByProduct` plus a live core: a session is retained while
    /// it has a live interactive service (`liveSessions`, the same catalog that feeds `sessions`) or while
    /// a `running_processes`, `agent_sessions`, or `runtime_targets` row references it. It reads the raw
    /// product records' tracking ids directly, BEFORE `sessions`' live-map stripping drops an ended
    /// session's id — so a bare ad hoc shell that has exited but is still held by its `runtime_targets`
    /// (terminal window) row remains in the keep-set, and its client-side ended pane stays open for
    /// scrollback until that row is removed. Ids are whitespace-trimmed, empties dropped, and sorted so
    /// the payload is stable tick-to-tick (the client dedupes overviews by equality).
    private static func retainedTerminalSessionIDs(liveSessions: [TerminalSessionCatalogEntry], workspaces: [WorkspaceDescriptor]) -> [String] {
        var retained = Set<String>()
        func insert(_ trackingID: String?) {
            guard let normalized = trackingID?.trimmingCharacters(in: .whitespacesAndNewlines), !normalized.isEmpty else { return }
            retained.insert(normalized)
        }
        for session in liveSessions { insert(session.sessionID) }
        for descriptor in workspaces {
            for process in descriptor.runningProcesses { insert(process.terminalTrackingID) }
            for agent in descriptor.agentWindows { insert(agent.terminalTrackingID) }
            for window in descriptor.windows { insert(window.terminalTrackingID) }
        }
        return retained.sorted()
    }

    static func matchedWorkspace(for session: TerminalSessionCatalogEntry, workspaces: [WorkspaceDescriptor]) -> WorkspaceDescriptor? {
        workspaces.first { $0.workspace.id == session.workspaceID }
    }

    private static func summary(
        for session: TerminalSessionCatalogEntry, matchedWorkspace: WorkspaceDescriptor?, title: String, liveTitle: String? = nil,
        rowKind: SpacesDeviceTerminalSessionRowKind, rowSourceID: String?, hasFinalRender: Bool
    ) -> SpacesDeviceTerminalSessionSummary {
        let isInteractive = session.runtimeState.state.isInteractive
        return SpacesDeviceTerminalSessionSummary(
            id: session.sessionID, title: title, liveTitle: liveTitle, workingDirectory: session.effectiveWorkingDirectory,
            shell: session.launchConfiguration.shell, command: session.launchConfiguration.command, state: session.runtimeState.state,
            backend: session.launchConfiguration.backend, lifetimePolicy: session.launchConfiguration.lifetimePolicy,
            servicePID: session.runtimeState.servicePID, childPID: session.runtimeState.childPID, workspaceID: session.workspaceID,
            workspaceTitle: matchedWorkspace?.workspace.displayName, projectID: matchedWorkspace?.project.id,
            projectName: matchedWorkspace?.project.name, createdAt: session.launchConfiguration.createdAt, updatedAt: session.runtimeState.updatedAt,
            isControlAvailable: isInteractive && session.isControlAvailable,
            isSubscriptionAvailable: isInteractive && session.isSubscriptionAvailable, attachmentSnapshot: session.attachmentSnapshot,
            rowKind: rowKind, rowSourceID: rowSourceID, hasFinalRender: hasFinalRender,
            foregroundDetectedAgentKind: session.runtimeState.foregroundDetectedAgentKind?.rawValue, bellAt: session.runtimeState.bellAt)
    }

    private static func projectSummaries(from projects: [ProjectRecord]) -> [SpacesDeviceProjectSummary] {
        var seen = Set<String>()
        return projects.sorted { lhs, rhs in lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }.compactMap { project in
            guard !seen.contains(project.id) else { return nil }
            seen.insert(project.id)
            return SpacesDeviceProjectSummary(
                id: project.id, name: project.name, dir: project.dir, isGitRepo: project.isGitRepo, defaultBranch: project.defaultBranch,
                config: projectConfig(from: project))
        }
    }

    static func projectConfig(from project: ProjectRecord) -> SpacesDeviceProjectConfig {
        SpacesDeviceProjectConfig(
            setupScript: project.setupScript, stopScript: project.stopScript, ports: project.ports.map(devicePort),
            processes: project.processes.map(deviceProcess), browserSessions: project.browserSessions.map(deviceBrowserSession))
    }

    private static func workspaceConfig(from settings: WorkspaceSettings?, resolvedBrowserSessions: [BrowserSession]) -> SpacesDeviceWorkspaceConfig {
        SpacesDeviceWorkspaceConfig(
            stopScript: settings?.stopScript, ports: settings?.ports.map(devicePort) ?? [], processes: settings?.processes.map(deviceProcess) ?? [],
            browserSessions: settings?.browserSessions.map(deviceBrowserSession) ?? [],
            resolvedBrowserSessions: resolvedBrowserSessions.map(deviceBrowserSession))
    }

    private static func devicePort(_ port: ServiceDefinition) -> SpacesDeviceServiceDefinition {
        SpacesDeviceServiceDefinition(id: port.id, name: port.name)
    }

    private static func deviceProcess(_ process: ProcessTemplate) -> SpacesDeviceProcessTemplate {
        SpacesDeviceProcessTemplate(id: process.id, name: process.name, command: process.command, kind: process.kind, onExit: process.onExit.rawValue)
    }

    private static func deviceBrowserSession(_ session: BrowserSession) -> SpacesDeviceBrowserSession {
        SpacesDeviceBrowserSession(name: session.name, url: session.url)
    }

    private static func deviceWorkspaceSetupState(_ state: WorkspaceSetupState) -> SpacesDeviceWorkspaceSetupState {
        SpacesDeviceWorkspaceSetupState(
            status: deviceWorkspaceSetupStatus(state.status), errorMessage: state.errorMessage, startedAt: state.startedAt,
            finishedAt: state.finishedAt, exitCode: state.exitCode, logPath: state.logPath, logTail: setupLogTail(state))
    }

    /// Reads the tail of the setup log for the states that show the setup screen with a log
    /// (`running` and `failed`). `succeeded` shows the normal workspace detail and `pending` has no
    /// output yet, so their tails are omitted to keep the overview snapshot small.
    private static func setupLogTail(_ state: WorkspaceSetupState) -> String? {
        guard state.status == .running || state.status == .failed else { return nil }
        guard let path = state.logPath?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        let maxBytes: UInt64 = 16_384
        let endOffset = (try? handle.seekToEnd()) ?? 0
        let startOffset = endOffset > maxBytes ? endOffset - maxBytes : 0
        try? handle.seek(toOffset: startOffset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if startOffset > 0, let firstNewline = text.firstIndex(of: "\n") { text = "...\n" + String(text[text.index(after: firstNewline)...]) }
        return text
    }

    private static func deviceWorkspaceSetupStatus(_ status: WorkspaceSetupStatus) -> SpacesDeviceWorkspaceSetupStatus {
        switch status {
        case .pending: return .pending
        case .running: return .running
        case .succeeded: return .succeeded
        case .failed: return .failed
        }
    }

    private struct WorkspaceRows {
        let processes: [SpacesDeviceWorkspaceProcessRow]
        let agents: [SpacesDeviceWorkspaceCodingAgentRow]
        let terminals: [SpacesDeviceWorkspaceTerminalRow]
    }

    private struct ProcessRows {
        let rows: [SpacesDeviceWorkspaceProcessRow]
        let claimedTerminalKeys: Set<String>
    }

    private struct CodingAgentRows {
        let rows: [SpacesDeviceWorkspaceCodingAgentRow]
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
        var rows: [SpacesDeviceWorkspaceProcessRow] = []
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
                SpacesDeviceWorkspaceProcessRow(
                    id: template.id, workspaceID: descriptor.workspace.id, name: template.name ?? "", command: template.command,
                    templateID: template.id, processID: runningProcess?.id, sessionID: availableSessionID, runState: state,
                    exitedAt: runningProcess?.exitedAt, canRun: !isRunning, canStop: isRunning, canRestart: isRunning))
        }

        for runningProcess in descriptor.runningProcesses where !usedProcessIDs.contains(runningProcess.id) {
            if let claimedKey = terminalTrackingKey(runningProcess) { claimedTerminalKeys.insert(claimedKey) }
            let state = processRunState(runningProcess)
            let rawSessionID = terminalSessionID(for: runningProcess)
            let availableSessionID = rawSessionID.flatMap { availableSessionIDs.contains($0) ? $0 : nil }
            let isRunning = state == .running
            let name = runningProcess.templateName.trimmingCharacters(in: .whitespacesAndNewlines)
            rows.append(
                SpacesDeviceWorkspaceProcessRow(
                    id: "process-runtime:\(runningProcess.id)", workspaceID: descriptor.workspace.id, name: name.isEmpty ? "Process" : name,
                    command: runningProcess.command, templateID: runningProcess.templateID, processID: runningProcess.id,
                    sessionID: availableSessionID, runState: state, exitedAt: runningProcess.exitedAt, canRun: false, canStop: isRunning,
                    canRestart: false))
        }
        return ProcessRows(rows: rows, claimedTerminalKeys: claimedTerminalKeys)
    }

    private static func codingAgentRows(for descriptor: WorkspaceDescriptor, sessionsByID: [String: TerminalSessionCatalogEntry]) -> CodingAgentRows {
        var claimedTerminalKeys = Set<String>()
        var rows: [SpacesDeviceWorkspaceCodingAgentRow] = []
        // Every coding-agent row is a live session: an agent exists only once its command is running in a
        // terminal. It is named by that session — the user's rename when one is stored, else the label the
        // agent reports for itself.
        for agent in descriptor.agentWindows {
            if let claimedKey = terminalTrackingKey(agent) { claimedTerminalKeys.insert(claimedKey) }
            rows.append(
                codingAgentRow(
                    id: "agent:\(agent.id)", workspaceID: descriptor.workspace.id, name: agent.effectiveLabel ?? "Coding Agent",
                    command: terminalDetail(for: agent, windows: descriptor.windows) ?? "", agent: agent, sessionsByID: sessionsByID))
        }
        return CodingAgentRows(rows: rows, claimedTerminalKeys: claimedTerminalKeys)
    }

    private static func codingAgentRow(
        id: String, workspaceID: String, name: String, command: String, agent: AgentWindowRecord,
        sessionsByID: [String: TerminalSessionCatalogEntry]
    ) -> SpacesDeviceWorkspaceCodingAgentRow {
        let rawSessionID = terminalSessionID(for: agent)
        let session = rawSessionID.flatMap { sessionsByID[$0] }
        return SpacesDeviceWorkspaceCodingAgentRow(
            id: id, workspaceID: workspaceID, name: name, command: command, agentID: agent.id, sessionID: session?.sessionID,
            runState: agentRunState(agent: agent, session: session), activityState: activityState(for: agent), updatedAt: agent.updatedAt,
            canStop: true, liveTitle: session?.liveTitle)
    }

    private static func workspaceTerminalRows(
        for descriptor: WorkspaceDescriptor, sessionsByID: [String: TerminalSessionCatalogEntry], claimedTerminalKeys: Set<String>
    ) -> [SpacesDeviceWorkspaceTerminalRow] {
        var rows: [SpacesDeviceWorkspaceTerminalRow] = []
        var includedSessionIDs = Set<String>()
        for window in descriptor.windows where window.roleValue == .terminal {
            if let key = terminalTrackingKey(window), claimedTerminalKeys.contains(key) { continue }
            let rawSessionID = terminalSessionID(for: window)
            let session = rawSessionID.flatMap { sessionsByID[$0] }
            if let rawSessionID { includedSessionIDs.insert(rawSessionID) }
            let runState = session.map(runState(for:)) ?? (rawSessionID == nil ? .running : .exited)
            rows.append(
                SpacesDeviceWorkspaceTerminalRow(
                    id: "terminal-window:\(window.id)", workspaceID: descriptor.workspace.id,
                    // The session record is where a rename is stored, so it names the row while it exists;
                    // the tracked window record (which a rename also rewrites, so the two agree) names only
                    // rows whose session is already gone.
                    title: session?.name ?? window.name ?? "Workspace Terminal", workingDirectory: descriptor.workspace.dir,
                    sessionID: session?.sessionID, runState: runState, canOpenTerminal: session != nil,
                    canStop: runState == .running && session?.sessionID != nil, liveTitle: session?.liveTitle))
        }

        for (sessionID, session) in sessionsByID.sorted(by: { $0.key < $1.key }) where !includedSessionIDs.contains(sessionID) {
            guard session.workspaceID == descriptor.workspace.id else { continue }
            let sessionKey = "terminal:\(sessionID)"
            guard !claimedTerminalKeys.contains(sessionKey) else { continue }
            let runState = runState(for: session)
            rows.append(
                SpacesDeviceWorkspaceTerminalRow(
                    id: "terminal-session:\(sessionID)", workspaceID: descriptor.workspace.id, title: session.name,
                    workingDirectory: session.effectiveWorkingDirectory, sessionID: sessionID, runState: runState, canOpenTerminal: true,
                    canStop: runState == .running, liveTitle: session.liveTitle))
        }

        // Rows are ordered by name, which moves only when the user renames one: what a program prints
        // into its title never reorders the list, and palette and cycling requests may reference these
        // rows by list index against a later overview.
        return rows.sorted { lhs, rhs in lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending }
    }

    private static func processRunState(_ process: RunningProcessRecord?) -> SpacesDeviceRunState {
        guard let process else { return .notStarted }
        return process.status == .exited ? .exited : .running
    }

    private static func agentRunState(agent: AgentWindowRecord?, session: TerminalSessionCatalogEntry?) -> SpacesDeviceRunState {
        guard agent != nil else { return .notStarted }
        guard let session else { return .exited }
        return runState(for: session)
    }

    private static func runState(for session: TerminalSessionCatalogEntry) -> SpacesDeviceRunState {
        session.runtimeState.state.isInteractive ? .running : .exited
    }

    private static func activityState(for agent: AgentWindowRecord?) -> SpacesDeviceCodingAgentActivityState {
        switch agent?.status {
        case .spinning: return .spinning
        case .waiting: return .waiting
        case .done: return .done
        case .exited: return .exited
        case .idle, nil: return .idle
        }
    }

    private static func terminalSessionID(for process: RunningProcessRecord?) -> String? {
        guard let sessionID = process?.terminalTrackingID, !sessionID.isEmpty else { return nil }
        return sessionID
    }

    private static func terminalSessionID(for agent: AgentWindowRecord?) -> String? {
        guard let sessionID = agent?.terminalTrackingID, !sessionID.isEmpty else { return nil }
        return sessionID
    }

    private static func terminalSessionID(for window: WindowRecord) -> String? {
        guard let sessionID = window.terminalTrackingID, !sessionID.isEmpty else { return nil }
        return sessionID
    }

    private static func terminalTrackingKey(_ process: RunningProcessRecord) -> String? { terminalSessionID(for: process).map { "terminal:\($0)" } }

    private static func terminalTrackingKey(_ agent: AgentWindowRecord) -> String? { terminalSessionID(for: agent).map { "terminal:\($0)" } }

    private static func terminalTrackingKey(_ window: WindowRecord) -> String? { terminalSessionID(for: window).map { "terminal:\($0)" } }

    private static func terminalDetail(for agent: AgentWindowRecord, windows: [WindowRecord]) -> String? {
        guard let key = terminalTrackingKey(agent) else { return nil }
        return windows.first(where: { terminalTrackingKey($0) == key }).flatMap { $0.detail ?? $0.name }
    }

    private static func normalizedRunRowName(_ name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
}
