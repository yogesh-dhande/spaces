import Foundation
import spacesterminalcore
import systembridge

extension WorkspaceOrchestrator {
    public func updateRunningWorkspaceProcesses(workspaceID: String, processes: [ProcessTemplate], restartChangedCommands: Bool) throws {
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        guard var existing = try loadWorkspaceSettings(project: project, workspace: workspace) else {
            throw WorkspaceError.missingProject(dir: project.dir)
        }
        let normalizedProcesses = normalizeProcessTemplateIDs(previous: existing.processes, updated: processes)
        try validateProcessTemplates(normalizedProcesses)
        try validateWorkspaceFocusNames(
            workspaceID: workspace.id, processes: normalizedProcesses, browserSessions: existing.browserSessions,
            agentLaunchers: existing.agentLaunchers, agentWindows: try store.agentWindows(workspaceID: workspace.id))
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
            for workspace in try store.workspaces(projectID: project.id, includeArchived: false) {
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
            let workspaces = try store.workspaces(projectID: project.id, includeArchived: false)
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
        let formatter = ISO8601DateFormatter()
        var didUpdate = false
        for process in processes where process.status == .running {
            if let runtimeState = resolvedBuiltInSessionRuntimeState(for: process), !runtimeState.state.isInteractive {
                let updatedProcess = RunningProcessRecord(
                    id: process.id, workspaceID: process.workspaceID, templateName: process.templateName, command: process.command,
                    terminalApp: process.terminalApp, terminalTrackingID: process.terminalTrackingID, terminalNativeID: process.terminalNativeID,
                    pid: runtimeState.childPID.map(Int.init) ?? process.pid, status: .exited, logPath: process.logPath,
                    lastOutputAt: process.lastOutputAt, startedAt: process.startedAt, exitedAt: runtimeState.exitedAt ?? nowISO8601())
                try store.upsert(runningProcess: updatedProcess)
                didUpdate = true
                try handleProcessExit(workspaceID: workspace.id, process: updatedProcess, project: project, workspace: workspace)
                continue
            }
            if !ignoreStartupGracePeriod, let startedAtStr = process.startedAt, let startedAt = formatter.date(from: startedAtStr),
                now.timeIntervalSince(startedAt) < 10.0
            {
                continue
            }
            guard let pid = resolvedRuntimePID(for: process) else { continue }
            if process.pid != pid {
                let updatedProcess = RunningProcessRecord(
                    id: process.id, workspaceID: process.workspaceID, templateName: process.templateName, command: process.command,
                    terminalApp: process.terminalApp, terminalTrackingID: process.terminalTrackingID, terminalNativeID: process.terminalNativeID,
                    pid: pid, status: process.status, logPath: process.logPath, lastOutputAt: process.lastOutputAt, startedAt: process.startedAt,
                    exitedAt: process.exitedAt)
                try store.upsert(runningProcess: updatedProcess)
                didUpdate = true
            }
            if !isProcessAlive(pid: pid) {
                let updatedProcess = RunningProcessRecord(
                    id: process.id, workspaceID: process.workspaceID, templateName: process.templateName, command: process.command,
                    runtimeTargetID: process.runtimeTargetID, terminalApp: process.terminalApp, terminalTrackingID: process.terminalTrackingID,
                    terminalNativeID: process.terminalNativeID, pid: process.pid, status: .exited, logPath: process.logPath,
                    lastOutputAt: process.lastOutputAt, startedAt: process.startedAt, exitedAt: nowISO8601())
                try store.upsert(runningProcess: updatedProcess)
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
            // Restart the process
            Self.writeStandardError("spaces: Restarting process '\(process.templateName)' due to exit\n")
            notificationDeliverer("Process Restarting", "Process '\(process.templateName)' is being restarted", nil)
            try restartProcessInTerminal(workspaceID: workspaceID, process: process)
        }
    }

    func restartExitedProcesses(workspaceID: String, background: Bool) throws {
        let processes = try store.runningProcesses(workspaceID: workspaceID)
        for process in processes where process.status == .exited {
            try restartProcessInTerminal(workspaceID: workspaceID, process: process, background: background)
        }
    }

    func restartProcessInTerminal(
        workspaceID: String, process: RunningProcessRecord, templateOverride: ProcessTemplate? = nil, background: Bool = false
    ) throws {
        try requireWorkspaceSetupSucceeded(workspaceID: workspaceID)
        _ = background
        let previousSessionID = process.terminalNativeID ?? process.terminalTrackingID
        if ProcessInfo.processInfo.environment["DEBUG"] == "1" {
            Self.writeStandardError(
                "spaces: restart_process begin workspace=\(workspaceID) name=\(process.templateName) previous_session=\(previousSessionID ?? "-")\n")
        }
        let (project, workspace) = try resolveWorkspace(id: workspaceID)
        let template = try templateOverride ?? configuredProcessTemplate(for: process, workspace: workspace, project: project)
        let assignedPorts = try store.workspacePortsAssigned(workspaceID: workspaceID)
        let runtimePlan = try workspaceRuntimePlan(project: project, workspace: workspace, assignedPorts: assignedPorts)
        let env = buildWorkspaceEnv(
            project: project, workspace: workspace, namedPorts: assignedPorts.map { (port: $0.port, name: $0.name) },
            runtimeManifest: runtimePlan.manifest)
        let session: SpacesTerminalSessionHandle
        if isManagedTerminalApp(process.terminalApp) {
            terminateBuiltInTerminalSession(for: process)
        } else {
            _ = terminateProcessForRestart(process)
        }
        let command = try spacesTerminalCommand(template: template, env: env)
        releaseReservedPortsForRuntimeStart(workspaceID: workspace.id)
        session = try launchSpacesTerminalSession(
            title: process.templateName, workingDirectory: workspace.dir, command: command, showMode: .owner, backend: .ghosttyEmbedded,
            readinessPolicy: .sessionReady, workspaceID: workspace.id, kind: .process)
        if ProcessInfo.processInfo.environment["DEBUG"] == "1" {
            Self.writeStandardError(
                "spaces: restart_process launched workspace=\(workspaceID) name=\(process.templateName) previous_session=\(previousSessionID ?? "-") new_session=\(session.sessionID)\n"
            )
        }
        let now = nowISO8601()
        let restartedProcess = RunningProcessRecord(
            id: process.id, workspaceID: process.workspaceID, templateID: template.id, templateName: process.templateName, command: template.command,
            terminalApp: TerminalHost.spaces.appName, terminalTrackingID: session.sessionID, terminalNativeID: session.sessionID,
            pid: session.childPID, status: .running, logPath: session.outputPath, lastOutputAt: nil, startedAt: now, exitedAt: nil)
        try store.upsert(runningProcess: restartedProcess)
        let existingWindows = try store.windows(workspaceID: workspace.id)
        let existingWindow = existingWindows.first(where: { matchesTrackedTerminalWindow($0, process: process) })
        let restoredWindow = WindowRecord(
            id: existingWindow?.id ?? process.id, workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: process.templateName,
            detail: process.command, targetURL: nil, terminalTrackingID: session.sessionID, terminalNativeID: session.sessionID,
            role: "terminal",
            orderIndex: existingWindow?.orderIndex ?? Self.nextWindowOrderIndex(existing: existingWindows, role: "terminal", orderOffset: 200),
            lastSeenAt: now)
        try store.upsert(window: restoredWindow)
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
        if let templateID = process.templateID?.trimmingCharacters(in: .whitespacesAndNewlines), !templateID.isEmpty,
            let template = settings?.processes.first(where: { $0.id == templateID })
        {
            return template
        }
        let processKey = process.templateName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let template = settings?.processes.first(where: { self.processKey(for: $0) == processKey }) { return template }
        return ProcessTemplate(name: process.templateName, command: process.command)
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
                    terminalTrackingID: runningProcess.terminalTrackingID, terminalNativeID: runningProcess.terminalNativeID, pid: runningProcess.pid,
                    status: runningProcess.status, logPath: runningProcess.logPath, lastOutputAt: runningProcess.lastOutputAt,
                    startedAt: runningProcess.startedAt, exitedAt: runningProcess.exitedAt)
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
            terminalTrackingID: process.terminalTrackingID, terminalNativeID: process.terminalNativeID, pid: process.pid, status: process.status,
            logPath: process.logPath, lastOutputAt: process.lastOutputAt, startedAt: process.startedAt, exitedAt: process.exitedAt)
        try store.upsert(runningProcess: updatedProcess)
        if let terminalWindow = try store.windows(workspaceID: workspaceID).first(where: {
            $0.role == "terminal" && matchesTrackedTerminalWindow($0, process: process)
        }) {
            try store.upsert(
                window: WindowRecord(
                    id: terminalWindow.id, workspaceID: terminalWindow.workspaceID, app: terminalWindow.app, name: templateName, detail: command,
                    targetURL: terminalWindow.targetURL, terminalTrackingID: terminalWindow.terminalTrackingID,
                    terminalNativeID: terminalWindow.terminalNativeID, role: terminalWindow.role, orderIndex: terminalWindow.orderIndex,
                    lastSeenAt: nowISO8601()))
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

    func launchProcesses(workspace: WorkspaceRecord, templates: [ProcessTemplate], env: [String: String], background: Bool = false) throws
        -> [WindowRecord]
    {
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
                title: name, workingDirectory: workspace.dir, command: sessionCommand, showMode: .owner, backend: .ghosttyEmbedded,
                readinessPolicy: .sessionReady, workspaceID: workspace.id, kind: .process)
            let now = nowISO8601()
            let running = RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateID: template.id, templateName: name, command: template.command,
                terminalApp: TerminalHost.spaces.appName, terminalTrackingID: session.sessionID, terminalNativeID: session.sessionID,
                pid: session.childPID, status: .running, logPath: session.outputPath, lastOutputAt: nil, startedAt: now, exitedAt: nil)
            try store.upsert(runningProcess: running)
            terminalWindows.append(
                WindowRecord(
                    id: UUID().uuidString, workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: name, detail: template.command,
                    targetURL: nil, terminalTrackingID: session.sessionID, terminalNativeID: session.sessionID, role: "terminal",
                    orderIndex: 200 + index, lastSeenAt: now))
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
        guard let process = try store.runningProcesses(workspaceID: workspaceID).first(where: { $0.id == processID }) else { return }
        try restartProcessInTerminal(workspaceID: workspaceID, process: process)
    }

    public func stopWorkspaceProcess(workspaceID: String, processID: String) throws {
        try withWorkspaceLifecycleLock(workspaceID: workspaceID) {
            guard let process = try store.runningProcesses(workspaceID: workspaceID).first(where: { $0.id == processID }) else { return }
            try stopRunningProcess(process, workspaceID: workspaceID)
        }
    }

    public func recoverMissingConfiguredProcess(workspaceID: String, processKey: String, processTemplateID: String? = nil) throws {
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
            if existing.status == .exited { try restartProcessInTerminal(workspaceID: workspaceID, process: existing, templateOverride: template) }
            try markWorkspaceRunningIfNeeded(workspace)
            return
        }

        let assignedPorts = try store.workspacePortsAssigned(workspaceID: workspace.id)
        let runtimePlan = try workspaceRuntimePlan(project: project, workspace: workspace, assignedPorts: assignedPorts)
        let env = buildWorkspaceEnv(
            project: project, workspace: workspace, namedPorts: assignedPorts.map { (port: $0.port, name: $0.name) },
            runtimeManifest: runtimePlan.manifest)
        _ = try launchConfiguredProcess(template: template, workspace: workspace, env: env)
        try markWorkspaceRunningIfNeeded(workspace)
        logPerfMetric(
            "process_recover", workspaceID: workspaceID, target: configuredProcessMatchKey(name: template.name),
            detail: "host=\(TerminalHost.spaces.rawValue)", elapsedMS: elapsedMS(since: recoverStartedAt), success: true)
    }

    public func runConfiguredProcess(workspaceID: String, processKey: String) throws {
        try recoverMissingConfiguredProcess(workspaceID: workspaceID, processKey: processKey)
    }

    public func runConfiguredProcess(workspaceID: String, processTemplateID: String, processKey: String) throws {
        try recoverMissingConfiguredProcess(workspaceID: workspaceID, processKey: processKey, processTemplateID: processTemplateID)
    }

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
            if terminalWindow.role == "terminal", isManagedTerminalApp(terminalWindow.app),
                let sessionID = normalizedTerminalSessionID(terminalWindow.terminalNativeID ?? terminalWindow.terminalTrackingID)
            {
                builtInTerminalWindowCloser(sessionID)
            }
            try store.deleteWindow(id: terminalWindow.id)
        }

        try store.deleteRunningProcess(id: process.id)

        try clearWorkspaceRunningIfNoTrackedRuntimeIndicators(workspaceID: workspaceID)
    }

    /// Releases placeholder port reservations before a workspace runtime starts. Placeholder sockets
    /// exist only while the workspace is stopped; once runtime is active, assigned ports are best-effort
    /// environment contracts and users resolve conflicts manually.
    func releaseReservedPortsForRuntimeStart(workspaceID: String) { PortReserver.shared.releasePorts(workspaceID: workspaceID) }

    @discardableResult func launchConfiguredProcess(
        template: ProcessTemplate, workspace: WorkspaceRecord, env: [String: String], background: Bool = false
    ) throws -> RunningProcessRecord {
        try requireWorkspaceSetupSucceeded(workspaceID: workspace.id)
        _ = background
        let name = processKey(for: template)
        let sessionCommand = try spacesTerminalCommand(template: template, env: env)
        let shouldRestoreReservedPortsOnFailure = !workspace.isRunning
        releaseReservedPortsForRuntimeStart(workspaceID: workspace.id)
        // If the launch started from a stopped workspace and throws after releasing placeholders,
        // restore them so the stopped workspace keeps its pinned ports held. A workspace that was
        // already running (for example from an ad-hoc terminal) intentionally remains unreserved.
        var launchSucceeded = false
        defer {
            if !launchSucceeded && shouldRestoreReservedPortsOnFailure {
                try? PortAllocator(store: store).reserveExistingPorts(workspaceID: workspace.id)
            }
        }
        let session = try launchSpacesTerminalSession(
            title: name, workingDirectory: workspace.dir, command: sessionCommand, showMode: .owner, backend: .ghosttyEmbedded,
            readinessPolicy: .sessionReady, workspaceID: workspace.id, kind: .process)
        let now = nowISO8601()
        let record = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateID: template.id, templateName: name, command: template.command,
            terminalApp: TerminalHost.spaces.appName, terminalTrackingID: session.sessionID, terminalNativeID: session.sessionID,
            pid: session.childPID, status: .running, logPath: session.outputPath, lastOutputAt: nil, startedAt: now, exitedAt: nil)
        try store.upsert(runningProcess: record)
        let nextOrder = Self.nextWindowOrderIndex(existing: try store.windows(workspaceID: workspace.id), role: "terminal", orderOffset: 200)
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: name, detail: template.command,
                targetURL: nil, terminalTrackingID: session.sessionID, terminalNativeID: session.sessionID, role: "terminal",
                orderIndex: nextOrder, lastSeenAt: now))
        launchSucceeded = true
        return record
    }

}
