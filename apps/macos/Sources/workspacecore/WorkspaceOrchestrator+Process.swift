import Foundation
import spacesterminalcore
import systembridge

extension WorkspaceOrchestrator {
    /// Launching a workspace's configured processes never moves focus.
    ///
    /// Every one of these launches is programmatic: the only orchestrator whose window opener actually
    /// reaches the macOS client is the daemon's profile-command orchestrator, which serves
    /// `spaces workspace start`/`restart` and the MCP tools that wrap them. In-app and mobile lifecycle
    /// actions run through the Device API, whose orchestrator opens no panes at all. So a configured
    /// process launch that lands in the client is, by construction, one a script or an agent asked for
    /// while the user was working somewhere else, and taking their window and caret for it is a
    /// disruption they did not ask for. The pane is still installed so the output is one click away; it
    /// simply arrives on an unselected tab.
    static let configuredProcessOpenFocusIntent = TerminalOpenFocusIntent.withoutFocus

    /// The open intent for a configured process launch: never focusing, and naming the session it takes
    /// over from when the launch is a restart's replacement, so the pane keeps its place in the layout.
    static func configuredProcessOpenIntent(replacing replacedSessionID: String? = nil) -> TerminalPaneOpenIntent {
        TerminalPaneOpenIntent(focus: configuredProcessOpenFocusIntent, replacesSessionID: replacedSessionID)
    }

    public func updateRunningWorkspaceProcesses(workspaceID: String, processes: [ProcessTemplate], restartChangedCommands: Bool) throws {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        guard var existing = try loadWorkspaceSettings(project: project, workspace: workspace) else {
            throw WorkspaceError.missingProject(dir: project.dir)
        }
        let normalizedProcesses = normalizeProcessTemplateIDs(previous: existing.processes, updated: processes)
        try validateProcessTemplates(normalizedProcesses)
        try validateWorkspaceFocusNames(
            workspaceID: workspace.id, processes: normalizedProcesses, browserSessions: existing.browserSessions,
            agentWindows: try store.agentWindows(workspaceID: workspace.id))
        if workspace.isRunning {
            try applyRunningWorkspaceProcessEdits(
                project: project, workspace: workspace, previous: existing.processes, updated: normalizedProcesses,
                restartChangedCommands: restartChangedCommands)
        }
        existing.processes = normalizedProcesses
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: existing.processes)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: nowISO8601())
    }

    // Configured-process matching uses the raw configured name directly.
    func configuredProcessMatchKey(name: String?) -> String { name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }

    func runningProcessMatchKey(name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    public func runningProcesses(workspaceID: String) throws -> [RunningProcessRecord] { try store.runningProcesses(workspaceID: workspaceID) }

    /// Recorded pids of currently-running processes across all active workspaces.
    /// Used to install per-process exit observers in place of status polling.
    public func runningOwnedProcessPIDs() throws -> Set<Int> {
        var pids: Set<Int> = []
        for project in try store.projects() {
            for workspace in try store.workspaces(projectID: project.id) {
                for process in try store.runningProcesses(workspaceID: workspace.id) where process.status == .running {
                    // A Spaces terminal-backed process can be recorded running before its child PID is
                    // persisted: the child PID is written to terminal runtime state, not the database, and
                    // no later databaseDidChange is guaranteed to revisit it. Resolve through runtime state
                    // when the DB pid is missing so the exit monitor still installs an observer for it.
                    if let pid = process.pid, pid > 0 {
                        pids.insert(pid)
                    } else if let runtimePID = resolvedRuntimePID(for: process), runtimePID > 0 {
                        pids.insert(runtimePID)
                    }
                }
            }
        }
        return pids
    }

    public func checkAndUpdateProcessStatuses(ignoreStartupGracePeriod: Bool = false) throws -> Bool {
        var didUpdate = false
        let allProjects = try store.projects()
        for project in allProjects {
            let workspaces = try store.workspaces(projectID: project.id)
            for workspace in workspaces {
                if try refreshProcessStatuses(workspaceID: workspace.id, project: project, ignoreStartupGracePeriod: ignoreStartupGracePeriod) {
                    didUpdate = true
                }
            }
        }
        if try reconcileTerminalForegroundAgentClassifications() { didUpdate = true }
        return didUpdate
    }

    @discardableResult func refreshProcessStatuses(workspaceID: String, ignoreStartupGracePeriod: Bool = false) throws -> Bool {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        return try refreshProcessStatuses(
            workspaceID: workspaceID, project: project, workspace: workspace, ignoreStartupGracePeriod: ignoreStartupGracePeriod)
    }

    @discardableResult func refreshProcessStatuses(
        workspaceID: String, project: ProjectRecord, workspace: WorkspaceRecord? = nil, ignoreStartupGracePeriod: Bool = false
    ) throws -> Bool {
        let workspace = try workspace ?? resolveWorkspace(id: workspaceID).1
        let processes = try store.runningProcesses(workspaceID: workspace.id)
        let now = currentDate()
        var didUpdate = false
        for process in processes where process.status == .running {
            if let runtimeState = resolvedBuiltInSessionRuntimeState(for: process), !runtimeState.state.isInteractive {
                let exitedPID = runtimeState.childPID.map(Int.init) ?? process.pid
                let exitedAt = runtimeState.exitedAt ?? nowISO8601()
                guard try store.markRunningProcessExited(process, pid: exitedPID, exitedAt: exitedAt) else { continue }
                let updatedProcess = RunningProcessRecord(
                    id: process.id, workspaceID: process.workspaceID, templateName: process.templateName, command: process.command,
                    terminalApp: process.terminalApp, terminalTrackingID: process.terminalTrackingID, pid: exitedPID, status: .exited,
                    logPath: process.logPath, lastOutputAt: process.lastOutputAt, startedAt: process.startedAt, exitedAt: exitedAt)
                didUpdate = true
                try handleProcessExit(workspaceID: workspace.id, process: updatedProcess, project: project, workspace: workspace)
                continue
            }
            if !ignoreStartupGracePeriod, let startedAtStr = process.startedAt, let startedAt = TerminalSessionTimestamp.date(from: startedAtStr),
                now.timeIntervalSince(startedAt) < 10.0
            {
                continue
            }
            guard let pid = resolvedRuntimePID(for: process) else { continue }
            if process.pid != pid {
                let updatedProcess = RunningProcessRecord(
                    id: process.id, workspaceID: process.workspaceID, templateName: process.templateName, command: process.command,
                    terminalApp: process.terminalApp, terminalTrackingID: process.terminalTrackingID, pid: pid, status: process.status,
                    logPath: process.logPath, lastOutputAt: process.lastOutputAt, startedAt: process.startedAt, exitedAt: process.exitedAt)
                try store.upsert(runningProcess: updatedProcess)
                didUpdate = true
            }
            if !isProcessAlive(pid: pid) {
                let exitedAt = nowISO8601()
                guard try store.markRunningProcessExited(process, pid: process.pid, exitedAt: exitedAt) else { continue }
                let updatedProcess = RunningProcessRecord(
                    id: process.id, workspaceID: process.workspaceID, templateName: process.templateName, command: process.command,
                    runtimeTargetID: process.runtimeTargetID, terminalApp: process.terminalApp, terminalTrackingID: process.terminalTrackingID,
                    pid: process.pid, status: .exited, logPath: process.logPath, lastOutputAt: process.lastOutputAt, startedAt: process.startedAt,
                    exitedAt: exitedAt)
                didUpdate = true
                try handleProcessExit(workspaceID: workspace.id, process: updatedProcess, project: project, workspace: workspace)
            }
        }
        return didUpdate
    }

    func handleProcessExit(workspaceID: String, process: RunningProcessRecord, project: ProjectRecord, workspace: WorkspaceRecord) throws {
        // Find the process template to get the on-exit behavior
        guard let config = try loadWorkspaceSettings(project: project, workspace: workspace) else { return }
        guard
            let processTemplate = config.processes.first(where: { template in
                if let templateID = process.templateID?.trimmingCharacters(in: .whitespacesAndNewlines), !templateID.isEmpty {
                    return template.id == templateID
                }
                return processKey(for: template) == process.templateName
            })
        else { return }
        switch processTemplate.onExit {
        case .none:
            // Do nothing - just log the exit
            break
        case .notify: notificationDeliverer("Process Exited", "Process '\(process.templateName)' has exited", nil)
        case .restart:
            // The one exit action that LAUNCHES, and it runs on the detached process-exit monitor rather
            // than inside any lifecycle action — so it needs the workspace's gate. A teardown terminates
            // the workspace's processes and only afterwards deletes their rows; a monitor tick landing in
            // between sees the process dead, marks the still-present row exited, and would relaunch it into
            // a worktree the delete is about to remove, leaving a live process whose record is then dropped.
            // (`markRunningProcessExited` is what closes the same window once the rows are gone: its
            // conditional update matches nothing, so this never runs.)
            //
            // The gate is taken here rather than inside `restartProcessInTerminal` because the deliberate
            // restart paths — `restartWorkspaceProcess`, `recoverMissingConfiguredProcess` — already hold
            // it and would re-enter.
            //
            // A busy gate means some lifecycle action owns the workspace right now, and this skips
            // silently: if that action was a teardown the process must stay dead, and if the workspace
            // survives it the row is still `.exited` for the next monitor tick to restart. `upWorkspace`
            // also reaches here while holding the gate, and skipping is right there too — it calls
            // `restartExitedProcesses` on the very next line, under the gate it already owns.
            do {
                try withWorkspaceLifecycleLock(workspaceID: workspaceID) {
                    Self.writeStandardError("spaces: Restarting process '\(process.templateName)' due to exit\n")
                    notificationDeliverer("Process Restarting", "Process '\(process.templateName)' is being restarted", nil)
                    try restartProcessInTerminal(workspaceID: workspaceID, process: process)
                }
            } catch  where WorkspaceOrchestrator.isWorkspaceLifecycleBusyError(error) { return }
        }
    }

    func restartExitedProcesses(workspaceID: String, background: Bool) throws {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let settings = try loadWorkspaceSettings(project: project, workspace: workspace)
        let processes = try store.runningProcesses(workspaceID: workspaceID)
        // Templates a `.running` row already satisfies, by the same strict rule the missing-check uses
        // (templateID match, or a name match only for a row with no templateID at all). Tracked as a
        // mutable set, not a one-time snapshot: restarting one exited row below can itself add to it, which
        // matters when two stale rows independently resolve by name to the same template (see below).
        var liveTemplateIDs = Set(
            processes.filter { $0.status == .running }.compactMap { matchingConfiguredTemplateForMissingCheck(for: $0, settings: settings)?.id })
        for process in processes where process.status == .exited {
            // Bulk convergence (Start) restarts only a row that still resolves to a currently configured
            // template. Removing a process from workspace settings while it is running deliberately keeps
            // its runtime row (removal never deletes tracked rows), so a since-removed process can sit here
            // `.exited` with no matching template. `configuredProcessTemplate`'s fallback to an ad hoc
            // template built from the row itself exists for the *explicit* per-process restart action (a
            // user's deliberate click on that specific row), not for bulk convergence: applying it here
            // would make Start silently relaunch a command the user removed from configuration, breaking
            // the "Start launches only configured processes" contract. A skipped stale row is left exactly
            // as is; stop and the existing settings/window cleanup paths own removing it, not this filter.
            guard let resolvedTemplate = matchingConfiguredTemplate(for: process, settings: settings) else { continue }
            // A stale-templateID exited row (its own template was removed while it ran, and a later edit
            // reused its name for a *different* process under a fresh id) resolves here via
            // `matchingConfiguredTemplate`'s unconditional name fallback to that new template, the same
            // resolution `configuredProcessTemplate`/the explicit restart action uses, deliberately, because
            // there the row IS the thing being restarted. Bulk convergence has to ask a second question this
            // stale row's identity does not answer: is the new template already live somewhere else (round-6
            // launched it as its own row, separately)? If so, restarting this row under the new template's
            // command would produce a second, duplicate row for a template meant to have exactly one; the
            // stale row stays exited, as documented, rather than being revived into a duplicate. If the new
            // template has no live row anywhere yet, this exited row is the one live-launchable path back to
            // it (the self-healing case), so it still restarts.
            guard !liveTemplateIDs.contains(resolvedTemplate.id) else { continue }
            try restartProcessInTerminal(workspaceID: workspaceID, process: process, background: background)
            liveTemplateIDs.insert(resolvedTemplate.id)
        }
    }

    /// Launches every configured process template that has no runtime record at all, leaving templates that
    /// already have a `.running` or `.exited` row untouched (an exited one is `restartExitedProcesses`'s job,
    /// and a running one stays running). A workspace whose only tracked runtime is an ad hoc terminal or a
    /// coding-agent session (issue #438) has zero rows for its configured processes, so this is what makes
    /// Start launch them instead of doing nothing: `restartExitedProcesses` only revives rows that already
    /// exist. Called under the workspace lifecycle lock by `upWorkspace`.
    func launchMissingConfiguredProcesses(workspaceID: String, background: Bool) throws {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        guard let settings = try loadWorkspaceSettings(project: project, workspace: workspace), !settings.processes.isEmpty else { return }
        let running = try store.runningProcesses(workspaceID: workspaceID)
        // Matches through `matchingConfiguredTemplateForMissingCheck`, the templateID-then-processKey
        // resolution `restartExitedProcesses` and `configuredProcessTemplate` also build on, but without
        // their name-match fallback for a row whose templateID is set but stale (see that function's doc
        // comment): an unnamed configured process's `processKey` falls back to its command, and a live row
        // whose `templateID` is unset entirely (a legacy row from before per-process identity existed,
        // never touched since) is keyed by that same command in `template_name` and still resolves by name
        // here. A row with a nonempty but stale templateID does not: it is left stale rather than let it
        // satisfy whatever template later reused its old name, so that new template still launches.
        let missingTemplates = settings.processes.filter { template in
            !running.contains { matchingConfiguredTemplateForMissingCheck(for: $0, settings: settings)?.id == template.id }
        }
        guard !missingTemplates.isEmpty else { return }

        let portDefinitions = try store.workspaceServiceDefinitions(workspaceID: workspace.id)
        let existingPorts = try store.workspacePorts(workspaceID: workspace.id)
        if existingPorts.count != portDefinitions.count {
            let portRange = try store.appConfig().portRange
            _ = try PortAllocator(store: store).allocatePorts(workspaceID: workspace.id, definitions: portDefinitions, range: portRange)
        }
        let assignedPorts = try store.workspacePortsAssigned(workspaceID: workspace.id)
        let runtimeManifest = workspaceRuntimeManifest(project: project, workspace: workspace, assignedPorts: assignedPorts)
        let env = buildWorkspaceEnv(
            project: project, workspace: workspace, namedPorts: assignedPorts.map { (port: $0.port, name: $0.name) }, runtimeManifest: runtimeManifest
        )
        // `workspace.isRunning` is the snapshot from the top of this call and never updated mid-batch (the
        // workspace record is only marked running after every template here has been tried), so each call
        // would otherwise compute the same "restore on failure" answer regardless of an earlier sibling's
        // outcome. Once one template has launched, a later failure must not restore placeholder
        // reservations over its now-live ports.
        //
        // Seeded from `running`, not just this loop: a retry after a partial batch (one template launched
        // last attempt and is live, another failed) filters that already-live row out of `missingTemplates`
        // above, so it never gets a turn to set this within the loop below, and a `.running` row this call
        // did not launch itself (one `restartExitedProcesses` just revived, moments earlier in the same
        // `upWorkspace` pass) is exactly as live and exactly as much at risk from a reservation restore.
        var batchHasLiveLaunch = running.contains { $0.status == .running }
        for template in missingTemplates {
            _ = try launchConfiguredProcess(
                template: template, workspace: workspace, env: env, background: background,
                restoreReservedPortsOnFailure: batchHasLiveLaunch ? false : nil)
            batchHasLiveLaunch = true
        }
    }

    @discardableResult func restartProcessInTerminal(
        workspaceID: String, process: RunningProcessRecord, templateOverride: ProcessTemplate? = nil, background: Bool = false
    ) throws -> RunningProcessRecord {
        try requireWorkspaceSetupSucceeded(workspaceID: workspaceID)
        _ = background
        let previousSessionID = process.terminalTrackingID
        if ProcessInfo.processInfo.environment["DEBUG"] == "1" {
            Self.writeStandardError(
                "spaces: restart_process begin workspace=\(workspaceID) name=\(process.templateName) previous_session=\(previousSessionID ?? "-")\n")
        }
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let template = try templateOverride ?? configuredProcessTemplate(for: process, workspace: workspace, project: project)
        let assignedPorts = try store.workspacePortsAssigned(workspaceID: workspaceID)
        let runtimeManifest = workspaceRuntimeManifest(project: project, workspace: workspace, assignedPorts: assignedPorts)
        let env = buildWorkspaceEnv(
            project: project, workspace: workspace, namedPorts: assignedPorts.map { (port: $0.port, name: $0.name) }, runtimeManifest: runtimeManifest
        )
        let session: SpacesTerminalSessionHandle
        // The replacement takes over this process's pane, so its session is closed as held rather than
        // torn down. `replacedSessionID` stays set until the launch claims it; a launch that throws
        // releases the hold on the way out so no pane is left waiting for a session that never arrives.
        var replacedSessionID: String?
        if isManagedTerminalApp(process.terminalApp) {
            replacedSessionID = replacedTerminalSessionID(for: process)
            terminateBuiltInTerminalSession(for: process, closeDisposition: replacedSessionID == nil ? .teardown : .awaitReplacement)
        } else {
            _ = terminateProcessForRestart(process)
        }
        defer { if let held = replacedSessionID { builtInTerminalWindowCloser(held, .teardown) } }
        let command = try spacesTerminalCommand(template: template, env: env)
        let workspaceWasRunning = workspace.isRunning
        let runtimeStartPorts = assignedPorts.map(\.port)
        releaseReservedPortsForRuntimeStart(ports: runtimeStartPorts)
        // A restart of a running workspace's process that throws must not leave the hold behind: the
        // ports stay unreserved while the workspace runs, but the hold would outlive the workspace
        // stopping and block the pass that holds its pinned ports again. When the workspace was not
        // running the restart came from `restartExitedProcesses` inside `upWorkspace`, where sibling
        // launches may still be starting on these ports, so the hold deliberately stays until the
        // workspace is marked running.
        var launchSucceeded = false
        defer { if !launchSucceeded && workspaceWasRunning { PortReserver.shared.clearRuntimeStartHold(ports: runtimeStartPorts) } }
        session = try launchSpacesTerminalSession(
            title: process.templateName, workingDirectory: workspace.dir, command: command, showMode: .owner,
            openIntent: Self.configuredProcessOpenIntent(replacing: replacedSessionID), backend: .ghosttyEmbedded, readinessPolicy: .sessionReady,
            workspaceID: workspace.id, kind: .process)
        replacedSessionID = nil
        launchSucceeded = true
        if ProcessInfo.processInfo.environment["DEBUG"] == "1" {
            Self.writeStandardError(
                "spaces: restart_process launched workspace=\(workspaceID) name=\(process.templateName) previous_session=\(previousSessionID ?? "-") new_session=\(session.sessionID)\n"
            )
        }
        let now = nowISO8601()
        let restartedProcess = RunningProcessRecord(
            id: process.id, workspaceID: process.workspaceID, templateID: template.id, templateName: process.templateName, command: template.command,
            terminalApp: TerminalHost.spaces.appName, terminalTrackingID: session.sessionID, pid: session.childPID, status: .running,
            logPath: session.outputPath, lastOutputAt: nil, startedAt: now, exitedAt: nil)
        try store.upsert(runningProcess: restartedProcess)
        let existingWindows = try store.windows(workspaceID: workspace.id)
        let existingWindow = existingWindows.first(where: { matchesTrackedTerminalWindow($0, process: process) })
        let restoredWindow = WindowRecord(
            id: existingWindow?.id ?? process.id, workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: process.templateName,
            detail: process.command, targetURL: nil, terminalTrackingID: session.sessionID, role: "terminal",
            orderIndex: existingWindow?.orderIndex ?? Self.nextWindowOrderIndex(existing: existingWindows, role: "terminal", orderOffset: 200),
            lastSeenAt: now)
        try store.upsert(window: restoredWindow)
        return restartedProcess
    }

    func terminateProcessForRestart(_ process: RunningProcessRecord) -> Bool {
        guard let pid = resolvedRuntimePID(for: process) else { return true }
        terminateProcessGroup(pid: pid)
        waitForProcessExit(pid: pid, timeout: 10.0)
        guard isProcessAlive(pid: pid) else { return true }
        Self.writeStandardError(
            "spaces: Process '\(process.templateName)' with pid \(pid) did not exit in time; restart will open a fresh Spaces terminal session\n")
        return false
    }

    func processLaunchCommand(template: ProcessTemplate) throws -> String {
        let trimmed = template.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkspaceError.invalidArgument(message: "Process command is required.") }
        return trimmed
    }

    public func validateProcessTemplate(_ template: ProcessTemplate) throws { _ = try processLaunchCommand(template: template) }

    public func validateProcessTemplates(_ templates: [ProcessTemplate]) throws {
        for template in templates { try validateProcessTemplate(template) }
    }

    func configuredProcessTemplate(for process: RunningProcessRecord, workspace: WorkspaceRecord, project: ProjectRecord) throws -> ProcessTemplate {
        let settings = try loadWorkspaceSettings(project: project, workspace: workspace)
        if let template = matchingConfiguredTemplate(for: process, settings: settings) { return template }
        return ProcessTemplate(name: process.templateName, command: process.command)
    }

    /// Resolves the template `settings.processes` still configures for `process`, matching by templateID
    /// first and then by process key (name), the same resolution order `configuredProcessTemplate` uses.
    /// Returns nil when neither matches: the process was removed from workspace settings while it was
    /// running (removal keeps the tracked row) or was never configured runtime to begin with. Kept as one
    /// helper so `configuredProcessTemplate`'s deliberate ad hoc fallback and `restartExitedProcesses`'s
    /// configured-only filter cannot drift onto different matching rules.
    ///
    /// The name fallback is deliberately unconditional here, including for a row whose `templateID` is set
    /// but matches nothing current (removed while it ran, its slot's name later reused by a differently
    /// configured process under a fresh id): both of this helper's callers only ever act on that row itself
    /// (`configuredProcessTemplate` resolves what an explicit restart of that specific row relaunches as;
    /// `restartExitedProcesses` only reaches an `.exited` row), so picking up the new template's command is
    /// a convergent, one-row substitution, not a duplicate. `launchMissingConfiguredProcesses`'s
    /// missing-check needs the opposite answer for exactly that stale-id case, because it asks a different
    /// question ("is some other row already this template") where the same fallback would wrongly let the
    /// stale row satisfy the new template and suppress launching it; see
    /// `matchingConfiguredTemplateForMissingCheck`.
    func matchingConfiguredTemplate(for process: RunningProcessRecord, settings: WorkspaceSettings?) -> ProcessTemplate? {
        if let templateID = process.templateID?.trimmingCharacters(in: .whitespacesAndNewlines), !templateID.isEmpty,
            let template = settings?.processes.first(where: { $0.id == templateID })
        {
            return template
        }
        let processKey = process.templateName.trimmingCharacters(in: .whitespacesAndNewlines)
        return settings?.processes.first(where: { self.processKey(for: $0) == processKey })
    }

    /// The missing-check's own resolution, stricter than `matchingConfiguredTemplate` in exactly one case:
    /// a row whose `templateID` is set but matches no current template never falls back to a name match.
    /// That row was configured once, under a different id, and removed while it ran (removal keeps the
    /// tracked row); if a later edit reuses its old name for a *different* process under a fresh id, the
    /// row is stale with respect to that new template, not a live instance of it. `matchingConfiguredTemplate`
    /// treating the name match as good enough is right for its own callers (see its doc comment) but wrong
    /// here: `launchMissingConfiguredProcesses` would read the new template as already running and never
    /// launch its command, leaving the stale row running under the reused name indefinitely. A row with no
    /// `templateID` at all (never had per-process identity, or genuinely never configured) still resolves by
    /// name, same as `matchingConfiguredTemplate`; that path is unaffected by this restriction.
    func matchingConfiguredTemplateForMissingCheck(for process: RunningProcessRecord, settings: WorkspaceSettings?) -> ProcessTemplate? {
        let trimmedTemplateID = process.templateID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmedTemplateID.isEmpty else { return settings?.processes.first(where: { $0.id == trimmedTemplateID }) }
        let processKey = process.templateName.trimmingCharacters(in: .whitespacesAndNewlines)
        return settings?.processes.first(where: { self.processKey(for: $0) == processKey })
    }

    func normalizeProcessTemplateIDs(previous: [ProcessTemplate], updated: [ProcessTemplate]) -> [ProcessTemplate] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let previousNames = previous.compactMap { template -> String? in
            let trimmed = template.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        let previousCommands = previous.map { $0.command.trimmingCharacters(in: .whitespacesAndNewlines) }
        let nameCounts = Dictionary(previousNames.map { ($0, 1) }, uniquingKeysWith: +)
        let commandCounts = Dictionary(previousCommands.map { ($0, 1) }, uniquingKeysWith: +)
        var usedIDs = Set<String>()

        return updated.map { template in
            if previousByID[template.id] != nil {
                usedIDs.insert(template.id)
                return template
            }

            let trimmedName = template.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedName.isEmpty, nameCounts[trimmedName] == 1,
                let match = previous.first(where: {
                    ($0.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") == trimmedName && !usedIDs.contains($0.id)
                })
            {
                usedIDs.insert(match.id)
                return ProcessTemplate(id: match.id, name: template.name, command: template.command, kind: template.kind, onExit: template.onExit)
            }

            let trimmedCommand = template.command.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedName.isEmpty, commandCounts[trimmedCommand] == 1,
                let match = previous.first(where: {
                    $0.command.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedCommand && !usedIDs.contains($0.id)
                })
            {
                usedIDs.insert(match.id)
                return ProcessTemplate(id: match.id, name: template.name, command: template.command, kind: template.kind, onExit: template.onExit)
            }

            return template
        }
    }

    func seededWorkspaceProcesses(from templates: [ProcessTemplate]) -> [ProcessTemplate] {
        templates.map { template in
            ProcessTemplate(id: UUID().uuidString, name: template.name, command: template.command, kind: template.kind, onExit: template.onExit)
        }
    }

    func processKey(for template: ProcessTemplate) -> String {
        let name = template.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let command = template.command.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? command : name
    }

    func runningWorkspaceProcessEdits(previous: [ProcessTemplate], updated: [ProcessTemplate]) -> [RunningWorkspaceProcessEdit] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        return updated.compactMap { updatedTemplate in
            guard let previousTemplate = previousByID[updatedTemplate.id] else { return nil }
            let previousKey = processKey(for: previousTemplate)
            let updatedKey = processKey(for: updatedTemplate)
            let edit = RunningWorkspaceProcessEdit(
                previous: previousTemplate, updated: updatedTemplate, previousKey: previousKey, updatedKey: updatedKey)
            guard edit.commandChanged || edit.keyChanged else { return nil }
            return edit
        }
    }

    func applyRunningWorkspaceProcessEdits(
        project: ProjectRecord, workspace: WorkspaceRecord, previous: [ProcessTemplate], updated: [ProcessTemplate], restartChangedCommands: Bool
    ) throws {
        let edits = runningWorkspaceProcessEdits(previous: previous, updated: updated)
        let restartRequiringEdits = edits.filter(\.commandChanged)
        if !restartRequiringEdits.isEmpty, !restartChangedCommands {
            throw WorkspaceError.invalidArgument(message: "Changing a running process command requires restart confirmation.")
        }

        let runningProcesses = try store.runningProcesses(workspaceID: workspace.id)
        let runningByKey = Dictionary(uniqueKeysWithValues: runningProcesses.map { ($0.templateName, $0) })

        if !restartRequiringEdits.isEmpty {
            for edit in restartRequiringEdits {
                guard let runningProcess = runningByKey[edit.previousKey] else { continue }
                try validateRunningProcessRestart(project: project, workspace: workspace, process: runningProcess, updatedTemplate: edit.updated)
            }
        }

        for edit in edits {
            guard let runningProcess = runningByKey[edit.previousKey] else { continue }
            if edit.commandChanged {
                let restartedProcess = RunningProcessRecord(
                    id: runningProcess.id, workspaceID: runningProcess.workspaceID, templateID: edit.updated.id, templateName: edit.updatedKey,
                    command: edit.updated.command, runtimeTargetID: runningProcess.runtimeTargetID, terminalApp: runningProcess.terminalApp,
                    terminalTrackingID: runningProcess.terminalTrackingID, pid: runningProcess.pid, status: runningProcess.status,
                    logPath: runningProcess.logPath, lastOutputAt: runningProcess.lastOutputAt, startedAt: runningProcess.startedAt,
                    exitedAt: runningProcess.exitedAt)
                try restartProcessInTerminal(workspaceID: workspace.id, process: restartedProcess, templateOverride: edit.updated)
            } else if edit.keyChanged {
                try relabelRunningProcess(
                    workspaceID: workspace.id, process: runningProcess, templateID: edit.updated.id, templateName: edit.updatedKey,
                    command: runningProcess.command)
            }
        }
    }

    func validateRunningProcessRestart(
        project: ProjectRecord, workspace: WorkspaceRecord, process: RunningProcessRecord, updatedTemplate: ProcessTemplate
    ) throws {
        _ = project
        _ = workspace
        _ = process
        try validateProcessTemplate(updatedTemplate)
    }

    func relabelRunningProcess(workspaceID: String, process: RunningProcessRecord, templateID: String? = nil, templateName: String, command: String)
        throws
    {
        let updatedProcess = RunningProcessRecord(
            id: process.id, workspaceID: process.workspaceID, templateID: templateID ?? process.templateID, templateName: templateName,
            command: command, runtimeTargetID: process.runtimeTargetID, terminalApp: process.terminalApp,
            terminalTrackingID: process.terminalTrackingID, pid: process.pid, status: process.status, logPath: process.logPath,
            lastOutputAt: process.lastOutputAt, startedAt: process.startedAt, exitedAt: process.exitedAt)
        try store.upsert(runningProcess: updatedProcess)
        if let terminalWindow = try store.windows(workspaceID: workspaceID).first(where: {
            $0.roleValue == .terminal && matchesTrackedTerminalWindow($0, process: process)
        }) {
            try store.upsert(
                window: WindowRecord(
                    id: terminalWindow.id, workspaceID: terminalWindow.workspaceID, app: terminalWindow.app, name: templateName, detail: command,
                    targetURL: terminalWindow.targetURL, terminalTrackingID: terminalWindow.terminalTrackingID, role: terminalWindow.role,
                    orderIndex: terminalWindow.orderIndex, lastSeenAt: nowISO8601()))
        }
    }

    func processRuntimePaths(workspaceID: String, name: String) throws -> (logFile: String, pidFile: String) {
        let runtimeRoot = try runtimeDirectory()
        let workspaceRuntime = URL(fileURLWithPath: runtimeRoot).appendingPathComponent(workspaceID, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRuntime, withIntermediateDirectories: true)
        let safe = safeFilename(name)
        let logFile = workspaceRuntime.appendingPathComponent("\(safe).log").path
        let pidFile = workspaceRuntime.appendingPathComponent("\(safe).pid").path
        return (logFile, pidFile)
    }

    /// - Parameter reservations: On a restart, the pane each configured process's previous session left
    ///   held, claimed here so the replacement takes it over in place.
    func launchProcesses(
        workspace: WorkspaceRecord, templates: [ProcessTemplate], env: [String: String], background: Bool = false,
        reservations: ReplacedTerminalSessionReservations? = nil
    ) throws -> [WindowRecord] {
        try requireWorkspaceSetupSucceeded(workspaceID: workspace.id)
        guard !templates.isEmpty else {
            try terminateBuiltInTerminalSessionsForConfiguredProcesses(workspaceID: workspace.id)
            try store.deleteRunningProcesses(workspaceID: workspace.id)
            return []
        }
        try terminateBuiltInTerminalSessionsForConfiguredProcesses(workspaceID: workspace.id)
        try store.deleteRunningProcesses(workspaceID: workspace.id)
        var terminalWindows: [WindowRecord] = []
        for (index, template) in templates.enumerated() {
            let name = template.name ?? template.command
            let sessionCommand = try spacesTerminalCommand(template: template, env: env)
            let session = try launchSpacesTerminalSession(
                title: name, workingDirectory: workspace.dir, command: sessionCommand, showMode: .owner,
                openIntent: Self.configuredProcessOpenIntent(replacing: reservations?.claimSessionID(processKey: runningProcessMatchKey(name: name))),
                backend: .ghosttyEmbedded, readinessPolicy: .sessionReady, workspaceID: workspace.id, kind: .process)
            let now = nowISO8601()
            let running = RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateID: template.id, templateName: name, command: template.command,
                terminalApp: TerminalHost.spaces.appName, terminalTrackingID: session.sessionID, pid: session.childPID, status: .running,
                logPath: session.outputPath, lastOutputAt: nil, startedAt: now, exitedAt: nil)
            try store.upsert(runningProcess: running)
            terminalWindows.append(
                WindowRecord(
                    id: UUID().uuidString, workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: name, detail: template.command,
                    targetURL: nil, terminalTrackingID: session.sessionID, role: "terminal", orderIndex: 200 + index, lastSeenAt: now))
        }
        return terminalWindows
    }

    func currentProcessEnvironment() -> [String: String] {
        var environment: [String: String] = [:]
        var cursor = environ
        while let entry = cursor.pointee {
            let line = String(cString: entry)
            if let separator = line.firstIndex(of: "=") {
                let key = String(line[..<separator])
                let value = String(line[line.index(after: separator)...])
                environment[key] = value
            }
            cursor = cursor.advanced(by: 1)
        }
        return environment
    }

    func terminateProcessGroup(pid: Int) {
        guard pid > 0 else { return }
        guard pid != Int(getpid()) else { return }
        let groupTarget = processGroupID(for: pid) ?? pid
        if debugLoggingEnabled() {
            Self.writeStandardError(
                "spaces: terminate_process_group pid=\(pid) group=\(groupTarget) current_group=\(Int(getpgrp())) daemon_pid=\(Int(getpid()))\n")
        }
        if groupTarget == Int(getpgrp()) {
            _ = try? Shell.run(["kill", "-INT", "\(pid)"])
            waitForProcessExit(pid: pid, timeout: 2.0)
            guard isProcessAlive(pid: pid) else { return }
            _ = try? Shell.run(["kill", "-TERM", "\(pid)"])
            return
        }
        let processGroupID = "-\(groupTarget)"
        // Send interrupt first so interactive commands like `docker compose up` shut down cleanly.
        _ = try? Shell.run(["kill", "-INT", "--", processGroupID])
        waitForProcessExit(pid: pid, timeout: 2.0)
        guard isProcessAlive(pid: pid) else { return }
        // Follow with TERM only if interrupt did not stop the process.
        _ = try? Shell.run(["kill", "-TERM", "--", processGroupID])
        waitForProcessExit(pid: pid, timeout: 2.0)
        guard isProcessAlive(pid: pid) else { return }
        // Fallback: target the tracked shell process directly.
        _ = try? Shell.run(["kill", "-TERM", "\(pid)"])
    }

    func processGroupID(for pid: Int) -> Int? {
        guard pid > 0 else { return nil }
        guard let output = try? Shell.runAndCapture(["ps", "-o", "pgid=", "-p", "\(pid)"]) else { return nil }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let groupID = Int(trimmed), groupID > 0 else { return nil }
        return groupID
    }

    func isProcessAlive(pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if let state = processState(pid: pid) {
            let trimmed = state.trimmingCharacters(in: .whitespacesAndNewlines)
            if let first = trimmed.first, first == "Z" { return false }
            return !trimmed.isEmpty
        }
        // If the PID is dead, check if any child processes are still alive.
        // This handles cases where the shell exits but the actual command continues.
        guard let output = try? Shell.runAndCapture(["pgrep", "-P", "\(pid)"]) else { return false }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }

    func processState(pid: Int) -> String? {
        guard pid > 0 else { return nil }
        if kill(pid_t(pid), 0) != 0, errno != EPERM { return nil }
        return try? Shell.runAndCapture(["ps", "-p", "\(pid)", "-o", "state="])
    }

    func waitForProcessExit(pid: Int, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while isProcessAlive(pid: pid), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    }

    public func restartWorkspaceProcess(workspaceID: String, processID: String) throws {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) {
            guard let process = try store.runningProcesses(workspaceID: workspaceID).first(where: { $0.id == processID }) else { return }
            try restartProcessInTerminal(workspaceID: workspaceID, process: process)
        }
    }

    public func stopWorkspaceProcess(workspaceID: String, processID: String) throws {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) {
            guard let process = try store.runningProcesses(workspaceID: workspaceID).first(where: { $0.id == processID }) else { return }
            try stopRunningProcess(process, workspaceID: workspaceID)
        }
    }

    /// Starts (or restarts) a configured process, under the lifecycle gate: launching a process into a
    /// workspace whose teardown had already snapshotted its rows would leave a live terminal behind with
    /// no record and no worktree. Both `runConfiguredProcess` overloads route through here, so the gate
    /// covers every configured-process start.
    @discardableResult public func recoverMissingConfiguredProcess(workspaceID: String, processKey: String, processTemplateID: String? = nil) throws
        -> RunningProcessRecord
    {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) {
            try recoverMissingConfiguredProcessUnlocked(workspaceID: workspaceID, processKey: processKey, processTemplateID: processTemplateID)
        }
    }

    private func recoverMissingConfiguredProcessUnlocked(workspaceID: String, processKey: String, processTemplateID: String?) throws
        -> RunningProcessRecord
    {
        try requireWorkspaceSetupSucceeded(workspaceID: workspaceID)
        let recoverStartedAt = currentDate()
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let settings = try loadWorkspaceSettings(project: project, workspace: workspace)
        let trimmedTemplateID = processTemplateID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let template: ProcessTemplate? =
            if !trimmedTemplateID.isEmpty { (settings?.processes ?? []).first(where: { $0.id == trimmedTemplateID }) } else {
                (settings?.processes ?? []).first(where: { configuredProcessMatchesKey($0, key: processKey) })
            }
        guard let template else { throw WorkspaceError.invalidArgument(message: "Configured process not found.") }

        let running = try store.runningProcesses(workspaceID: workspaceID)
        let expectedKey = configuredProcessMatchKey(name: template.name)
        if let existing = running.first(where: { runningProcessMatchesTemplate($0, template: template, fallbackKey: expectedKey) }) {
            let process =
                if existing.status == .exited {
                    try restartProcessInTerminal(workspaceID: workspaceID, process: existing, templateOverride: template)
                } else { existing }
            try markWorkspaceRunningIfNeeded(workspace)
            return process
        }

        let assignedPorts = try store.workspacePortsAssigned(workspaceID: workspace.id)
        let runtimeManifest = workspaceRuntimeManifest(project: project, workspace: workspace, assignedPorts: assignedPorts)
        let env = buildWorkspaceEnv(
            project: project, workspace: workspace, namedPorts: assignedPorts.map { (port: $0.port, name: $0.name) }, runtimeManifest: runtimeManifest
        )
        let process = try launchConfiguredProcess(template: template, workspace: workspace, env: env)
        try markWorkspaceRunningIfNeeded(workspace)
        logPerfMetric(
            "process_recover", workspaceID: workspaceID, target: configuredProcessMatchKey(name: template.name),
            detail: "host=\(TerminalHost.spaces.rawValue)", elapsedMS: elapsedMS(since: recoverStartedAt), success: true)
        return process
    }

    @discardableResult public func runConfiguredProcess(workspaceID: String, processKey: String) throws -> RunningProcessRecord {
        try recoverMissingConfiguredProcess(workspaceID: workspaceID, processKey: processKey)
    }

    @discardableResult public func runConfiguredProcess(workspaceID: String, processTemplateID: String, processKey: String) throws
        -> RunningProcessRecord
    { try recoverMissingConfiguredProcess(workspaceID: workspaceID, processKey: processKey, processTemplateID: processTemplateID) }

    func configuredProcessMatchesKey(_ template: ProcessTemplate, key: String) -> Bool {
        let trimmedName = template.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmedName.isEmpty && trimmedName == key
    }

    func runningProcessMatchesTemplate(_ process: RunningProcessRecord, template: ProcessTemplate, fallbackKey: String) -> Bool {
        if let templateID = process.templateID?.trimmingCharacters(in: .whitespacesAndNewlines), !templateID.isEmpty {
            return templateID == template.id
        }
        return !fallbackKey.isEmpty && runningProcessMatchKey(name: process.templateName) == fallbackKey
    }

    func stopRunningProcess(_ process: RunningProcessRecord, workspaceID: String) throws {
        if isManagedTerminalApp(process.terminalApp) {
            terminateBuiltInTerminalSession(for: process)
        } else if let pid = resolvedRuntimePID(for: process) {
            terminateProcessGroup(pid: pid)
        }
        if let terminalWindow = try store.windows(workspaceID: workspaceID).first(where: { matchesTrackedTerminalWindow($0, process: process) }) {
            if terminalWindow.roleValue == .terminal, isManagedTerminalApp(terminalWindow.app),
                let sessionID = normalizedTerminalSessionID(terminalWindow.terminalTrackingID)
            {
                builtInTerminalWindowCloser(sessionID, .teardown)
            }
            try store.deleteWindow(id: terminalWindow.id)
        }

        try store.deleteRunningProcess(id: process.id)

        try clearWorkspaceRunningIfNoTrackedRuntimeIndicators(workspaceID: workspaceID)
    }

    /// Frees placeholder port reservations before a workspace runtime starts, and holds those ports
    /// against the daemon's reconciler rebinding them mid-launch. Placeholder sockets exist only while
    /// the workspace is stopped; once runtime is active, assigned ports are best-effort environment
    /// contracts and users resolve conflicts manually.
    ///
    /// Frees by port rather than by workspace so the port is freed whatever reservation is holding it:
    /// reservations are derived from the store by the daemon's reconciler, so one can still be held on
    /// behalf of a workspace record that was deleted or re-assigned since it was bound, and the server
    /// about to start would otherwise get EADDRINUSE on its own assigned port.
    func releaseReservedPortsForRuntimeStart(ports: [Int]) { PortReserver.shared.beginRuntimeStartHold(ports: ports) }

    /// - Parameter restoreReservedPortsOnFailure: Overrides the default "restore only when the workspace
    ///   was stopped" rule. `launchMissingConfiguredProcesses` passes `false` for every template after the
    ///   batch's first successful launch: restoring placeholder reservations rebinds every one of the
    ///   workspace's assigned ports, including ones a sibling launch earlier in the same batch already
    ///   started a real server on, which can make that live server lose its bind (or fail one still coming
    ///   up) to the placeholder socket. Once the batch has a live process, the workspace is no longer
    ///   meaningfully "stopped" for reservation purposes even though `workspace.isRunning` (captured once,
    ///   before the batch) has not been updated to say so yet. With `false` the runtime-start hold is
    ///   deliberately left in place, so it keeps covering the live sibling's port for the rest of the
    ///   batch; the reconciler clears it once the workspace is marked running. Passing `false` is
    ///   therefore the one case where a failed launch neither rebinds nor clears the hold: clearing it
    ///   would let a reconcile pass rebind a placeholder over the sibling's still-starting server.
    @discardableResult func launchConfiguredProcess(
        template: ProcessTemplate, workspace: WorkspaceRecord, env: [String: String], background: Bool = false,
        restoreReservedPortsOnFailure: Bool? = nil
    ) throws -> RunningProcessRecord {
        try requireWorkspaceSetupSucceeded(workspaceID: workspace.id)
        _ = background
        let name = processKey(for: template)
        let sessionCommand = try spacesTerminalCommand(template: template, env: env)
        let workspaceWasRunning = workspace.isRunning
        let shouldRestoreReservedPortsOnFailure = restoreReservedPortsOnFailure ?? !workspaceWasRunning
        let assignedPorts = try store.workspacePorts(workspaceID: workspace.id)
        releaseReservedPortsForRuntimeStart(ports: assignedPorts)
        // A launch that throws after releasing placeholders resolves the runtime-start hold three ways:
        //
        // - The workspace was already running (for example from an ad-hoc terminal): clear the hold
        //   without rebinding. A running workspace's ports are outside the reconciler's desired set, so
        //   they intentionally stay unreserved, but the hold itself must go or it survives the workspace
        //   stopping again and blocks the pass that would hold those ports once more.
        // - The workspace was stopped: end the hold and rebind, so it keeps its pinned ports held.
        //   Rebinding here rather than leaving it to the daemon's reservation reconciler keeps the
        //   failure outcome deterministic: the store is unchanged by a failed launch, so the reconciler
        //   would reach the same set, and this way the ports are never briefly unheld.
        // - The batch launcher explicitly passed `restoreReservedPortsOnFailure: false`: leave the hold
        //   in place. See that parameter's documentation.
        var launchSucceeded = false
        defer {
            if !launchSucceeded {
                if workspaceWasRunning {
                    PortReserver.shared.clearRuntimeStartHold(ports: assignedPorts)
                } else if shouldRestoreReservedPortsOnFailure {
                    PortReserver.shared.endRuntimeStartHold(ports: assignedPorts)
                }
            }
        }
        let session = try launchSpacesTerminalSession(
            title: name, workingDirectory: workspace.dir, command: sessionCommand, showMode: .owner, openIntent: Self.configuredProcessOpenIntent(),
            backend: .ghosttyEmbedded, readinessPolicy: .sessionReady, workspaceID: workspace.id, kind: .process)
        let now = nowISO8601()
        let record = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateID: template.id, templateName: name, command: template.command,
            terminalApp: TerminalHost.spaces.appName, terminalTrackingID: session.sessionID, pid: session.childPID, status: .running,
            logPath: session.outputPath, lastOutputAt: nil, startedAt: now, exitedAt: nil)
        try store.upsert(runningProcess: record)
        let nextOrder = Self.nextWindowOrderIndex(existing: try store.windows(workspaceID: workspace.id), role: "terminal", orderOffset: 200)
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: name, detail: template.command,
                targetURL: nil, terminalTrackingID: session.sessionID, role: "terminal", orderIndex: nextOrder, lastSeenAt: now))
        launchSucceeded = true
        return record
    }

}
