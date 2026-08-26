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

    /// The number of newest terminal automation runs the overview carries, in addition to every currently
    /// active (queued/running) run. Keeps the snapshot bounded while still covering enough recent history
    /// for a client to render run lists and derive alert entries from recent failed/timed-out runs.
    static let recentAutomationRunLimit = 50

    /// Selects the automation runs the overview carries, from three inputs, de-duplicated and returned
    /// newest first:
    /// - `recentTerminal`: the newest terminal runs globally (already limited to `recentAutomationRunLimit`
    ///   by the caller's query) — the recent-history window.
    /// - `latestPerAutomation`: each automation's single newest terminal run, so a chatty automation
    ///   filling the global recent window can never evict quieter automations' last-run status (a client
    ///   would otherwise read them as "never run" with empty history).
    /// - `active`: every currently-active (queued/running) run, so a live run is never dropped by the cap.
    /// Pure and static so the selection contract is unit-testable without a store or a running server.
    static func selectOverviewRuns(recentTerminal: [AutomationRun], latestPerAutomation: [AutomationRun], active: [AutomationRun]) -> [AutomationRun]
    {
        var seen = Set<String>()
        var merged: [AutomationRun] = []
        for run in recentTerminal + latestPerAutomation + active where seen.insert(run.id).inserted { merged.append(run) }
        return merged.sorted { $0.createdAt > $1.createdAt }
    }

    static func build(
        projects: [ProjectRecord] = [], workspaces: [WorkspaceDescriptor], workspaceRows: [WorkspaceTerminalRow],
        liveSessions: [TerminalSessionCatalogEntry], workspaceIDsWithTeardownInFlight: [String] = [], daemonStatus: TerminalServiceDaemonStatus,
        automations: [TerminalServiceAutomationSummary] = [], automationRuns: [TerminalServiceAutomationRunSummary] = [],
        automationAttributedSessionIDs: [String] = []
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
        }.compactMap { row -> SpacesDeviceTerminalSessionSummary? in
            // Workspace rows always carry a workspace; a nil id would be a workspace-less session that has
            // no place in a workspace-scoped listing, so it is dropped rather than surfaced.
            guard let workspaceID = row.entry.workspaceID else { return nil }
            return summary(
                for: row.entry, workspaceID: workspaceID, matchedWorkspace: row.workspace, title: row.title,
                liveTitle: row.rowKind == .agent ? row.entry.liveTitle : nil, rowKind: row.rowKind, rowSourceID: row.rowSourceID,
                hasFinalRender: row.hasFinalRender)
        }

        let adHocSessionSummaries = adHocLiveSessions.sorted { lhs, rhs in
            if lhs.effectiveWorkingDirectory != rhs.effectiveWorkingDirectory {
                return lhs.effectiveWorkingDirectory.localizedStandardCompare(rhs.effectiveWorkingDirectory) == .orderedAscending
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }.compactMap { session -> SpacesDeviceTerminalSessionSummary? in
            // Workspace-less sessions are not workspace-owned and stay invisible
            // in the workspace-scoped overview; only sessions with a workspace id produce a summary.
            guard let workspaceID = session.workspaceID else { return nil }
            let matchedWorkspace = matchedWorkspaceBySessionID[session.sessionID] ?? nil
            return summary(
                for: session, workspaceID: workspaceID, matchedWorkspace: matchedWorkspace, title: session.name, liveTitle: session.liveTitle,
                rowKind: .liveSession, rowSourceID: nil, hasFinalRender: false)
        }

        return SpacesDeviceOverviewPayload(
            projects: projectSummaries, workspaces: workspaceSummaries, sessions: workspaceSessionSummaries + adHocSessionSummaries,
            retainedTerminalSessionIDs: retainedTerminalSessionIDs(
                liveSessions: liveSessions, workspaces: workspaces, automationAttributedSessionIDs: automationAttributedSessionIDs),
            workspaceIDsWithTeardownInFlight: workspaceIDsWithTeardownInFlight, daemonStatus: daemonStatus, automations: automations,
            automationRuns: automationRuns)
    }

    /// The keep-set the daemon publishes on `SpacesDeviceOverviewPayload.retainedTerminalSessionIDs`:
    /// every terminal session id whose pane and transcript the daemon still retains.
    ///
    /// This is the daemon's authoritative retention rule, mirroring the session garbage collector's
    /// `SQLiteStore.terminalSessionIsReferencedByProduct` plus a live core: a session is retained while
    /// it has a live interactive service (`liveSessions`, the same catalog that feeds `sessions`) or while
    /// a `running_processes`, `agent_sessions`, `runtime_targets`, or automation-run row references it. It
    /// reads the raw product records' tracking ids directly, BEFORE `sessions`' live-map stripping drops an
    /// ended session's id — so a bare ad hoc shell that has exited but is still held by its `runtime_targets`
    /// (terminal window) row remains in the keep-set, and its client-side ended pane stays open for
    /// scrollback until that row is removed. Ids are whitespace-trimmed, empties dropped, and sorted so
    /// the payload is stable tick-to-tick (the client dedupes overviews by equality).
    ///
    /// `automationAttributedSessionIDs` covers the automation-run arm of that rule, which no workspace
    /// descriptor can supply: an automation run's terminals are replayable from the Runs tab until the run is
    /// pruned. An exited automation terminal has already shed its live runtime target, so it would not
    /// otherwise appear here and the client would close the replay pane on the next overview. This is read
    /// from the store rather than derived from `automationRuns` so the keep-set
    /// covers every retained run, not just the ones inside the overview's bounded run window.
    private static func retainedTerminalSessionIDs(
        liveSessions: [TerminalSessionCatalogEntry], workspaces: [WorkspaceDescriptor], automationAttributedSessionIDs: [String]
    ) -> [String] {
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
        for sessionID in automationAttributedSessionIDs { insert(sessionID) }
        return retained.sorted()
    }

    static func matchedWorkspace(for session: TerminalSessionCatalogEntry, workspaces: [WorkspaceDescriptor]) -> WorkspaceDescriptor? {
        workspaces.first { $0.workspace.id == session.workspaceID }
    }

    private static func summary(
        for session: TerminalSessionCatalogEntry, workspaceID: String, matchedWorkspace: WorkspaceDescriptor?, title: String,
        liveTitle: String? = nil, rowKind: SpacesDeviceTerminalSessionRowKind, rowSourceID: String?, hasFinalRender: Bool
    ) -> SpacesDeviceTerminalSessionSummary {
        let isInteractive = session.runtimeState.state.isInteractive
        return SpacesDeviceTerminalSessionSummary(
            id: session.sessionID, title: title, liveTitle: liveTitle, workingDirectory: session.effectiveWorkingDirectory,
            shell: session.launchConfiguration.shell, command: session.launchConfiguration.command, state: session.runtimeState.state,
            backend: session.launchConfiguration.backend, lifetimePolicy: session.launchConfiguration.lifetimePolicy,
            servicePID: session.runtimeState.servicePID, childPID: session.runtimeState.childPID, workspaceID: workspaceID,
            workspaceTitle: matchedWorkspace?.workspace.displayName, projectID: matchedWorkspace?.project.id,
            projectName: matchedWorkspace?.project.name, createdAt: session.launchConfiguration.createdAt, updatedAt: session.runtimeState.updatedAt,
            isControlAvailable: isInteractive && session.isControlAvailable,
            isSubscriptionAvailable: isInteractive && session.isSubscriptionAvailable, attachmentSnapshot: session.attachmentSnapshot,
            rowKind: rowKind, rowSourceID: rowSourceID, hasFinalRender: hasFinalRender,
            foregroundDetectedAgentKind: session.runtimeState.foregroundDetectedAgentKind?.rawValue,
            foregroundCommand: TerminalForegroundProcessInspector.displayCommand(
                executableName: session.runtimeState.foregroundExecutableName, argv: session.runtimeState.foregroundArgv),
            bellAt: session.runtimeState.bellAt, bracketedPasteActive: session.runtimeState.bracketedPasteActive)
    }

    private static func projectSummaries(from projects: [ProjectRecord]) -> [SpacesDeviceProjectSummary] {
        var seen = Set<String>()
        return projects.sorted { lhs, rhs in lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending }.compactMap { project in
            guard !seen.contains(project.id) else { return nil }
            seen.insert(project.id)
            return SpacesDeviceProjectSummary(
                id: project.id, name: project.name, dir: project.dir, isGitRepo: project.isGitRepo, defaultBranch: project.defaultBranch,
                isHidden: project.isHidden, config: projectConfig(from: project))
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
        // Only a row with no templateID at all (a legacy row from before per-process identity existed)
        // may be claimed by name below. A row whose templateID is set but stale (the process it was
        // configured for was removed while it ran, removal keeps the tracked row, and a later edit reused
        // that name for a *different* process under a fresh id) must not be claimed by that new template:
        // it already failed the id check above and is not a live instance of it. Without this, the new
        // template's row here would report `canRun: false` (already running) from the stale row, hiding
        // Start even though the backend (`WorkspaceOrchestrator.matchingConfiguredTemplateForMissingCheck`,
        // the same rule, applied to the same stale-id state) treats the new template as missing and would
        // launch it. A row excluded here still gets its own row from the fallback loop below, keyed by its
        // own (stale) templateID, so it stays visible and reported as running rather than disappearing.
        let runningByKey = Dictionary(
            descriptor.runningProcesses.filter { ($0.templateID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty }.map {
                (normalizedRunRowName($0.templateName), $0)
            }, uniquingKeysWith: { existing, _ in existing })
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
        // terminal. It is named by that session: the user's rename when one is stored, else the stored
        // label, which registration materializes even when nothing reported one. The literal is reached
        // only by a row stored before labels were materialized, and is pure display, never a focus name.
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
        id: String, workspaceID: String, name: String, command: String, agent: AgentWindowRecord, sessionsByID: [String: TerminalSessionCatalogEntry]
    ) -> SpacesDeviceWorkspaceCodingAgentRow {
        let rawSessionID = terminalSessionID(for: agent)
        let session = rawSessionID.flatMap { sessionsByID[$0] }
        return SpacesDeviceWorkspaceCodingAgentRow(
            id: id, workspaceID: workspaceID, name: name, command: command, agentID: agent.id, sessionID: session?.sessionID,
            runState: agentRunState(session: session), activityState: activityState(for: agent), updatedAt: agent.updatedAt, canStop: true,
            liveTitle: session?.liveTitle)
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

    private static func agentRunState(session: TerminalSessionCatalogEntry?) -> SpacesDeviceRunState {
        guard let session else { return .exited }
        return runState(for: session)
    }

    private static func runState(for session: TerminalSessionCatalogEntry) -> SpacesDeviceRunState {
        session.runtimeState.state.isInteractive ? .running : .exited
    }

    private static func activityState(for agent: AgentWindowRecord) -> SpacesDeviceCodingAgentActivityState {
        switch agent.status {
        case .spinning: return .spinning
        case .waiting: return .waiting
        case .done: return .done
        case .exited: return .exited
        case .idle: return .idle
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
