import Foundation
import appctl
import streamctl

struct CLI {
    let args: [String]
    private var wantsJSON: Bool { args.contains("--json") }
    private var output: CLITextOrJSONOutput { .init(wantsJSON: wantsJSON) }

    func run() throws {
        guard args.count >= 2 else {
            printHelp()
            return
        }

        let command = args[1]

        if command == "--version" {
            try output.emit(
                text: "mx \(AppVersion.current)",
                json: MutationResultPayload(message: "Reported current version.", resource: ["version": AppVersion.current]))
            return
        }

        let db = try DatabaseLocator.defaultPath()
        let store = try SQLiteStore(path: db)
        let orchestrator = MuxyOrchestrator(store: store)

        _ = try orchestrator.syncConfig()

        switch command {
        case "project": try runProjectSubcommand(orchestrator: orchestrator)
        case "workspace": try runWorkspaceSubcommand(orchestrator: orchestrator)
        case "discover": try runDiscover(orchestrator: orchestrator)
        case "dashboard":
            let payload = try DashboardPayloadBuilder.build(orchestrator: orchestrator)
            try output.emit(
                text: "Dashboard command is only available with --json.",
                json: payload)
        case "agent": try runAgentSubcommand(orchestrator: orchestrator)
        default: printHelp()
        }
    }

    private func runProjectSubcommand(orchestrator: MuxyOrchestrator) throws {
        guard args.count >= 3 else {
            throw NSError(
                domain: "mx.cli", code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Missing project action. Use: project list|add|update|remove|port|process|status-check|browser-session"
                ])
        }

        switch args[2] {
        case "port": try runProjectPortSubcommand(orchestrator: orchestrator)
        case "process": try runProjectProcessSubcommand(orchestrator: orchestrator)
        case "status-check": try runProjectStatusCheckSubcommand(orchestrator: orchestrator)
        case "browser-session": try runProjectBrowserSessionSubcommand(orchestrator: orchestrator)
        case "get":
            let dir = try value(for: "--dir")
            let projectID = normalizePath(dir)
            guard let project = try orchestrator.project(id: projectID) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Project not found for dir \(dir)"])
            }
            try output.emit(
                text: "\(project.name)\t\(project.dir)",
                json: project)
        case "list":
            let projects = try orchestrator.listProjects()
            try output.emitLines(
                text: projects.map { "\($0.name)\t\($0.dir)\tgit=\($0.isGitRepo ? "yes" : "no")\tdefault_branch=\($0.defaultBranch ?? "-")" },
                json: projects.map(ProjectSummaryPayload.init))
        case "add":
            let dir = optionalValue(for: "--dir")
            let gitURL = optionalValue(for: "--git-url")
            if dir != nil, gitURL != nil {
                throw NSError(
                    domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Use either --dir <path> or --git-url <url>, but not both."])
            }
            let record: ProjectRecord
            if let gitURL {
                record = try orchestrator.addProject(gitURL: gitURL)
            } else if let dir {
                record = try orchestrator.addProject(dir: dir)
            } else {
                throw NSError(
                    domain: "mx.cli", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Missing required flags. Use: project add --dir <path> or project add --git-url <url>"])
            }
            try output.emit(
                text: "Added project \(record.name)\t\(record.dir)",
                json: MutationResultPayload(message: "Added project \(record.name).", resource: record))
        case "update":
            let dir = try value(for: "--dir")
            let setupScript = optionalValue(for: "--setup-script")
            let stopScript = optionalValue(for: "--stop-script")
            try orchestrator.updateProjectConfig(projectID: normalizePath(dir)) { project in
                if let setupScript { project.setupScript = setupScript }
                if let stopScript { project.stopScript = stopScript }
            }
            let projectID = normalizePath(dir)
            guard let project = try orchestrator.project(id: projectID) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Project not found for dir \(dir)"])
            }
            try output.emit(
                text: "Updated project \(dir)",
                json: MutationResultPayload(message: "Updated project \(project.name).", resource: project))
        case "remove":
            let dir = try value(for: "--dir")
            try orchestrator.removeProject(dir: dir)
            try output.emit(
                text: "Removed project \(dir)",
                json: MutationResultPayload<ProjectRecord>(message: "Removed project \(normalizePath(dir)).", resource: nil))
        default: throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown project action: \(args[2])"])
        }
    }

    private func runProjectPortSubcommand(orchestrator: MuxyOrchestrator) throws {
        guard args.count >= 4 else {
            throw NSError(
                domain: "mx.cli", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Missing action. Use: project port add|remove|list --dir <path> [--name <name>]"])
        }
        let dir = try value(for: "--dir")
        let projectID = normalizePath(dir)
        switch args[3] {
        case "add":
            let name = try value(for: "--name")
            try orchestrator.updateProjectConfig(projectID: projectID) { config in
                if !config.ports.contains(where: { $0.name == name }) { config.ports.append(PortDefinition(name: name)) }
            }
            guard let project = try orchestrator.project(id: projectID) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Project not found for dir \(dir)"])
            }
            try output.emit(
                text: "Added port \(name) to \(dir)",
                json: MutationResultPayload(message: "Added port \(name).", resource: project))
        case "remove":
            let name = try value(for: "--name")
            try orchestrator.updateProjectConfig(projectID: projectID) { config in config.ports.removeAll { $0.name == name } }
            guard let project = try orchestrator.project(id: projectID) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Project not found for dir \(dir)"])
            }
            try output.emit(
                text: "Removed port \(name) from \(dir)",
                json: MutationResultPayload(message: "Removed port \(name).", resource: project))
        case "list":
            guard let project = try orchestrator.project(id: projectID) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Project not found for dir \(dir)"])
            }
            try output.emitLines(
                text: project.ports.map(\.name),
                json: project.ports)
        default:
            throw NSError(
                domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown action: \(args[3]). Use: project port add|remove|list"])
        }
    }

    private func runProjectProcessSubcommand(orchestrator: MuxyOrchestrator) throws {
        guard args.count >= 4 else {
            throw NSError(
                domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing action. Use: project process add|remove|list --dir <path>"])
        }
        let dir = try value(for: "--dir")
        let projectID = normalizePath(dir)
        switch args[3] {
        case "add":
            let name = optionalValue(for: "--name")
            let command = try value(for: "--command")
            let onExitStr = optionalValue(for: "--on-exit") ?? ProcessExitAction.none.rawValue
            guard let onExit = ProcessExitAction(rawValue: onExitStr) else {
                throw NSError(
                    domain: "mx.cli", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid --on-exit value '\(onExitStr)'. Use: none|restart|notify"])
            }
            try orchestrator.updateProjectConfig(projectID: projectID) { config in
                config.processes.append(ProcessTemplate(name: name, command: command, onExit: onExit))
            }
            guard let project = try orchestrator.project(id: projectID) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Project not found for dir \(dir)"])
            }
            try output.emit(
                text: "Added process \(name ?? command) to \(dir)",
                json: MutationResultPayload(message: "Added process \(name ?? command).", resource: project))
        case "remove":
            let name = try value(for: "--name")
            try orchestrator.updateProjectConfig(projectID: projectID) { config in config.processes.removeAll { $0.name == name } }
            guard let project = try orchestrator.project(id: projectID) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Project not found for dir \(dir)"])
            }
            try output.emit(
                text: "Removed process \(name) from \(dir)",
                json: MutationResultPayload(message: "Removed process \(name).", resource: project))
        case "list":
            guard let project = try orchestrator.project(id: projectID) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Project not found for dir \(dir)"])
            }
            try output.emitLines(
                text: project.processes.map { "\($0.name ?? "-")\t\($0.command)\ton-exit=\($0.onExit.rawValue)" },
                json: project.processes)
        default:
            throw NSError(
                domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown action: \(args[3]). Use: project process add|remove|list"])
        }
    }

    private func runProjectStatusCheckSubcommand(orchestrator: MuxyOrchestrator) throws {
        guard args.count >= 4 else {
            throw NSError(
                domain: "mx.cli", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Missing action. Use: project status-check add|remove|list --dir <path>"])
        }
        let dir = try value(for: "--dir")
        let projectID = normalizePath(dir)
        switch args[3] {
        case "add":
            let name = optionalValue(for: "--name")
            let process = try value(for: "--process")
            let command = try value(for: "--command")
            let intervalStr = optionalValue(for: "--interval")
            let timeoutStr = optionalValue(for: "--timeout")
            let onFailStr = optionalValue(for: "--on-fail") ?? OnFailAction.none.rawValue
            guard let onFail = OnFailAction(rawValue: onFailStr) else {
                throw NSError(
                    domain: "mx.cli", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid --on-fail value '\(onFailStr)'. Use: none|restart|notify"])
            }
            let interval: Int
            if let s = intervalStr {
                guard let n = Int(s), n > 0 else {
                    throw NSError(
                        domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid --interval '\(s)'. Must be a positive integer."])
                }
                interval = n
            } else {
                interval = PollingConstants.statusCheckDefaultInterval
            }
            let timeout: Int
            if let s = timeoutStr {
                guard let n = Int(s), n > 0 else {
                    throw NSError(
                        domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid --timeout '\(s)'. Must be a positive integer."])
                }
                timeout = n
            } else {
                timeout = PollingConstants.statusCheckDefaultTimeout
            }
            try orchestrator.updateProjectConfig(projectID: projectID) { config in
                config.statusChecks.append(
                    StatusCheckDefinition(name: name, process: process, command: command, interval: interval, timeout: timeout, onFail: onFail))
            }
            guard let project = try orchestrator.project(id: projectID) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Project not found for dir \(dir)"])
            }
            try output.emit(
                text: "Added status check \(name ?? process) to \(dir)",
                json: MutationResultPayload(message: "Added status check \(name ?? process).", resource: project))
        case "remove":
            let name = try value(for: "--name")
            try orchestrator.updateProjectConfig(projectID: projectID) { config in config.statusChecks.removeAll { $0.name == name } }
            guard let project = try orchestrator.project(id: projectID) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Project not found for dir \(dir)"])
            }
            try output.emit(
                text: "Removed status check \(name) from \(dir)",
                json: MutationResultPayload(message: "Removed status check \(name).", resource: project))
        case "list":
            guard let project = try orchestrator.project(id: projectID) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Project not found for dir \(dir)"])
            }
            try output.emitLines(
                text: project.statusChecks.map {
                    "\($0.name ?? "-")\tprocess=\($0.process)\tcommand=\($0.command)\tinterval=\($0.interval)\ttimeout=\($0.timeout)\ton-fail=\($0.onFail.rawValue)"
                },
                json: project.statusChecks)
        default:
            throw NSError(
                domain: "mx.cli", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unknown action: \(args[3]). Use: project status-check add|remove|list"])
        }
    }

    private func runProjectBrowserSessionSubcommand(orchestrator: MuxyOrchestrator) throws {
        guard args.count >= 4 else {
            throw NSError(
                domain: "mx.cli", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Missing action. Use: project browser-session add|remove|list --dir <path>"])
        }
        let dir = try value(for: "--dir")
        let projectID = normalizePath(dir)
        switch args[3] {
        case "add":
            let name = optionalValue(for: "--name")
            let url = try value(for: "--url")
            try orchestrator.updateProjectConfig(projectID: projectID) { config in config.browserSessions.append(BrowserSession(name: name, url: url))
            }
            guard let project = try orchestrator.project(id: projectID) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Project not found for dir \(dir)"])
            }
            try output.emit(
                text: "Added browser session \(name ?? url) to \(dir)",
                json: MutationResultPayload(message: "Added browser session \(name ?? url).", resource: project))
        case "remove":
            let url = try value(for: "--url")
            try orchestrator.updateProjectConfig(projectID: projectID) { config in config.browserSessions.removeAll { $0.url == url } }
            guard let project = try orchestrator.project(id: projectID) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Project not found for dir \(dir)"])
            }
            try output.emit(
                text: "Removed browser session \(url) from \(dir)",
                json: MutationResultPayload(message: "Removed browser session \(url).", resource: project))
        case "list":
            guard let project = try orchestrator.project(id: projectID) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Project not found for dir \(dir)"])
            }
            try output.emitLines(
                text: project.browserSessions.map { "\($0.name ?? "-")\t\($0.url ?? "-")" },
                json: project.browserSessions)
        default:
            throw NSError(
                domain: "mx.cli", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unknown action: \(args[3]). Use: project browser-session add|remove|list"])
        }
    }

    private func runWorkspaceSubcommand(orchestrator: MuxyOrchestrator) throws {
        guard args.count >= 3 else {
            throw NSError(
                domain: "mx.cli", code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Missing workspace action. Use: workspace list|get|create|import|update|launch|restart|up|stop|archive|focus|runtime|settings|port|process|status-check|browser-session"
                ])
        }
        switch args[2] {
        case "port": try runWorkspacePortSubcommand(orchestrator: orchestrator)
        case "process": try runWorkspaceProcessSubcommand(orchestrator: orchestrator)
        case "status-check": try runWorkspaceStatusCheckSubcommand(orchestrator: orchestrator)
        case "browser-session": try runWorkspaceBrowserSessionSubcommand(orchestrator: orchestrator)
        case "settings": try runWorkspaceSettingsSubcommand(orchestrator: orchestrator)
        case "get":
            let id = try workspaceID(orchestrator: orchestrator)
            guard let workspace = try orchestrator.store.workspace(id: id) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Workspace not found for id \(id)"])
            }
            try output.emit(
                text: "\(workspace.name)\t\(workspace.dir)",
                json: workspace)
        case "list":
            let projectDir = try value(for: "--project-dir")
            let projectID = normalizePath(projectDir)
            let workspaces = try orchestrator.listWorkspaces(projectID: projectID, includeArchived: args.contains("--all"))
            try output.emitLines(
                text: workspaces.map { ws in
                    let flags = [
                        ws.isDefault ? "default" : nil, ws.isRunning ? "running" : nil, ws.isArchived ? "archived" : nil, !ws.isActive ? "inactive" : nil,
                    ].compactMap { $0 }.joined(separator: ",")
                    return "\(ws.name)\t\(ws.dir)\t\(flags)"
                },
                json: workspaces.map(WorkspaceSummaryPayload.init))
        case "create":
            let projectDir = try value(for: "--project-dir")
            let name = try value(for: "--name")
            let branch = optionalValue(for: "--branch")
            let targetBranch = optionalValue(for: "--target-branch")
            let directoryNameFlag = optionalValue(for: "--directory-name")
            let dirnameFlag = optionalValue(for: "--dirname")
            if directoryNameFlag != nil, dirnameFlag != nil {
                throw NSError(
                    domain: "mx.cli", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Use either --directory-name <name> or --dirname <name>, but not both."])
            }
            let directoryName = directoryNameFlag ?? dirnameFlag
            let tooltip = optionalValue(for: "--tooltip")
            let projectID = normalizePath(projectDir)
            var workspace = try orchestrator.createWorkspace(
                projectID: projectID, name: name, branch: branch, targetBranch: targetBranch, directoryName: directoryName)
            if let tooltip {
                try orchestrator.updateWorkspaceTooltip(workspaceID: workspace.id, tooltip: tooltip)
                workspace = try orchestrator.store.workspace(id: workspace.id)!
            }
            try output.emit(
                text: "Created workspace \(workspace.name)\t\(workspace.dir)",
                json: MutationResultPayload(message: "Created workspace \(workspace.name).", resource: workspace))
        case "import":
            let dir = optionalValue(for: "--dir") ?? FileManager.default.currentDirectoryPath
            let title = optionalValue(for: "--title")
            let tooltip = optionalValue(for: "--tooltip")
            let normalizedImportDir = normalizePath(dir)
            let workspace: WorkspaceRecord
            if let existing = try orchestrator.store.workspace(dir: normalizedImportDir), !existing.isArchived {
                if title != nil || tooltip != nil {
                    try orchestrator.updateWorkspaceMetadata(workspaceID: existing.id, title: title, tooltip: tooltip != nil ? .some(tooltip) : nil)
                }
                workspace = try orchestrator.store.workspace(id: existing.id) ?? existing
                try output.emit(
                    text: "Workspace already exists: \(workspace.name)\t\(workspace.dir)",
                    json: MutationResultPayload(message: "Workspace already exists.", resource: workspace))
            } else {
                var created = try orchestrator.createWorkspaceFromWorktree(worktreePath: dir, name: title)
                if let tooltip {
                    try orchestrator.updateWorkspaceMetadata(workspaceID: created.id, tooltip: .some(tooltip))
                    created = try orchestrator.store.workspace(id: created.id)!
                }
                workspace = created
                try output.emit(
                    text: "Created workspace \(workspace.name)\t\(workspace.dir)",
                    json: MutationResultPayload(message: "Created workspace \(workspace.name).", resource: workspace))
            }
        case "update":
            let id = try workspaceID(orchestrator: orchestrator)
            let title = optionalValue(for: "--title")
            let branch = optionalValue(for: "--branch")
            let directoryNameFlag = optionalValue(for: "--directory-name")
            let dirnameFlag = optionalValue(for: "--dirname")
            let dirNameFlag = optionalValue(for: "--dir-name")
            let providedDirectoryNameFlags = [directoryNameFlag, dirnameFlag, dirNameFlag].compactMap { $0 }
            if providedDirectoryNameFlags.count > 1 {
                throw NSError(
                    domain: "mx.cli", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Use only one of --directory-name <name>, --dirname <name>, or --dir-name <name>."])
            }
            let directoryName = directoryNameFlag ?? dirnameFlag ?? dirNameFlag
            let shouldClearTooltip = args.contains("--clear-tooltip") || args.contains("--clear")
            let activateFlag = args.contains("--active")
            let deactivateFlag = args.contains("--inactive")
            if activateFlag && deactivateFlag {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Use either --active or --inactive, but not both."])
            }
            let tooltipValue = optionalValueAllowingMissingValue(for: "--tooltip")
            if args.contains("--tooltip"), tooltipValue == nil {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing required value for --tooltip"])
            }
            if shouldClearTooltip, args.contains("--tooltip") {
                throw NSError(
                    domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Use either --tooltip <text> or --clear-tooltip, but not both."])
            }
            let tooltipUpdate: String??
            if shouldClearTooltip {
                tooltipUpdate = .some(nil)
            } else if let tooltipValue {
                tooltipUpdate = .some(tooltipValue)
            } else {
                tooltipUpdate = nil
            }
            let activeUpdate = activateFlag ? true : (deactivateFlag ? false : nil)
            guard title != nil || branch != nil || directoryName != nil || tooltipUpdate != nil || activeUpdate != nil else {
                throw NSError(
                    domain: "mx.cli", code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "No updates provided. Use one or more of --title, --branch, --directory-name/--dirname/--dir-name, --tooltip, --clear-tooltip, --active, or --inactive."
                    ])
            }
            try orchestrator.updateWorkspaceMetadata(
                workspaceID: id, title: title, branch: branch, directoryName: directoryName, tooltip: tooltipUpdate)
            if let activeUpdate { try orchestrator.updateWorkspaceActive(workspaceID: id, isActive: activeUpdate) }
            guard let updated = try orchestrator.store.workspace(id: id) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Workspace not found for id \(id)"])
            }
            try output.emit(
                text: "Updated workspace \(id)\t\(updated.name)",
                json: MutationResultPayload(message: "Updated workspace \(updated.name).", resource: updated))
        case "launch":
            let id = try workspaceID(orchestrator: orchestrator)
            try orchestrator.launchWorkspace(workspaceID: id)
            guard let workspace = try orchestrator.store.workspace(id: id) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Workspace not found for id \(id)"])
            }
            try output.emit(
                text: "Launched workspace \(id)",
                json: MutationResultPayload(message: "Launched workspace \(workspace.name).", resource: workspace))
        case "restart":
            let id = try workspaceID(orchestrator: orchestrator)
            try orchestrator.restartWorkspace(workspaceID: id)
            guard let workspace = try orchestrator.store.workspace(id: id) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Workspace not found for id \(id)"])
            }
            try output.emit(
                text: "Restarted workspace \(id)",
                json: MutationResultPayload(message: "Restarted workspace \(workspace.name).", resource: workspace))
        case "up":
            let id = try workspaceID(orchestrator: orchestrator)
            let shouldRestartIfRunning = args.contains("--force-restart")
            let shouldFocus = args.contains("--focus")
            let focusName = optionalValueAllowingMissingValue(for: "--focus")
            if shouldFocus, focusName == nil {
                let availableNames = try orchestrator.workspaceFocusableWindowNames(workspaceID: id)
                let suffix = availableNames.isEmpty ? "" : " Available names: \(availableNames.joined(separator: ", "))"
                throw NSError(
                    domain: "mx.cli", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "`mx workspace up --focus` requires a window name. Use `--focus <name>`.\(suffix)"])
            }
            try orchestrator.upWorkspace(workspaceID: id, restartIfRunning: shouldRestartIfRunning, background: !shouldFocus)
            if let focusName { try orchestrator.focusWorkspaceWindow(workspaceID: id, name: focusName) }
            guard let workspace = try orchestrator.store.workspace(id: id) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Workspace not found for id \(id)"])
            }
            try output.emit(
                text: "Workspace is running \(id)",
                json: MutationResultPayload(message: "Workspace is running.", resource: workspace))
        case "stop":
            let id = try workspaceID(orchestrator: orchestrator)
            let outcome = try orchestrator.stopWorkspace(workspaceID: id)
            guard let workspace = try orchestrator.store.workspace(id: id) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Workspace not found for id \(id)"])
            }
            if outcome.skippedStopScriptBecauseWorkspaceDirectoryMissing {
                try output.emitLines(
                    text: [
                        "Stopped workspace \(id)",
                        "Note: workspace directory is missing, so the workspace stop script was skipped."
                    ],
                    json: MutationResultPayload(
                        message: "Stopped workspace \(workspace.name). Workspace directory was missing, so the stop script was skipped.",
                        resource: workspace))
            } else {
                try output.emit(
                    text: "Stopped workspace \(id)",
                    json: MutationResultPayload(message: "Stopped workspace \(workspace.name).", resource: workspace))
            }
        case "archive":
            let id = try workspaceID(orchestrator: orchestrator)
            try orchestrator.archiveWorkspace(workspaceID: id)
            let resource = try orchestrator.store.workspace(id: id)
            try output.emit(
                text: "Archived workspace \(id)",
                json: MutationResultPayload<WorkspaceRecord>(message: "Archived workspace \(id).", resource: resource))
        case "focus":
            let id = try workspaceID(orchestrator: orchestrator)
            guard let windowName = optionalValueAllowingMissingValue(for: "--window") else {
                let availableNames = try orchestrator.workspaceFocusableWindowNames(workspaceID: id)
                let suffix = availableNames.isEmpty ? "" : " Available names: \(availableNames.joined(separator: ", "))"
                throw NSError(
                    domain: "mx.cli", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "`mx workspace focus` requires --window <name> so focus targets stay explicit.\(suffix)"])
            }
            try orchestrator.focusWorkspaceWindow(workspaceID: id, name: windowName)
            try output.emit(
                text: "Focused workspace window \(windowName) for workspace \(id)",
                json: MutationResultPayload(
                    message: "Focused workspace window \(windowName).",
                    resource: ["workspaceID": id, "windowName": windowName]))
        case "runtime":
            let id = try workspaceID(orchestrator: orchestrator)
            let status = try orchestrator.workspaceRuntimeStatus(workspaceID: id)
            let processes = try orchestrator.runningProcesses(workspaceID: id)
            let windows = try orchestrator.windows(workspaceID: id)
            var resultsByProcessID: [String: [StatusResultPayload]] = [:]
            for process in processes {
                resultsByProcessID[process.id] = try orchestrator.statusResults(processID: process.id).map(StatusResultPayload.init)
            }
            let payload = WorkspaceRuntimePayload(
                status: .init(status),
                processes: processes,
                windows: windows.map(WindowRecordPayload.init),
                statusResultsByProcessID: resultsByProcessID,
                agentWindows: try orchestrator.agentWindows(workspaceID: id))
            try output.emit(
                text: "Workspace runtime is only available with --json.",
                json: payload)
        default: throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown workspace action: \(args[2])"])
        }
    }

    private func workspaceID(orchestrator: MuxyOrchestrator) throws -> String {
        let dir = optionalValue(for: "--dir") ?? FileManager.default.currentDirectoryPath
        let normalizedDir = normalizePath(dir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedDir) else {
            throw NSError(
                domain: "mx.cli", code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Workspace not found at: \(normalizedDir). Use --dir <path> to specify a different workspace directory."
                ])
        }
        return workspace.id
    }

    private func workspaceRecord(orchestrator: MuxyOrchestrator) throws -> WorkspaceRecord {
        let id = try workspaceID(orchestrator: orchestrator)
        guard let workspace = try orchestrator.store.workspace(id: id) else {
            throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Workspace not found for id \(id)"])
        }
        return workspace
    }

    private func workspaceSettings(orchestrator: MuxyOrchestrator) throws -> WorkspaceSettings {
        let workspace = try workspaceRecord(orchestrator: orchestrator)
        guard let settings = try orchestrator.workspaceSettings(workspaceID: workspace.id) else {
            throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Workspace settings not found for \(workspace.dir)"])
        }
        return settings
    }

    private func runWorkspaceSettingsSubcommand(orchestrator: MuxyOrchestrator) throws {
        guard args.count >= 4 else {
            let settings = try workspaceSettings(orchestrator: orchestrator)
            try output.emit(
                text: "Workspace settings are only available with --json.",
                json: WorkspaceSettingsPayload(settings))
            return
        }

        switch args[3] {
        case "get":
            let settings = try workspaceSettings(orchestrator: orchestrator)
            try output.emit(
                text: "Workspace settings are only available with --json.",
                json: WorkspaceSettingsPayload(settings))
        case "update":
            let workspace = try workspaceRecord(orchestrator: orchestrator)
            let stopScript = optionalValue(for: "--stop-script")
            let clearStopScript = args.contains("--clear-stop-script")
            if stopScript == nil, !clearStopScript {
                throw NSError(
                    domain: "mx.cli",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "No updates provided. Use --stop-script <script> or --clear-stop-script."])
            }
            if stopScript != nil, clearStopScript {
                throw NSError(
                    domain: "mx.cli",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Use either --stop-script <script> or --clear-stop-script, but not both."])
            }
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
                if clearStopScript {
                    settings.stopScript = nil
                } else if let stopScript {
                    settings.stopScript = stopScript
                }
            }
            let updatedSettings = try workspaceSettings(orchestrator: orchestrator)
            try output.emit(
                text: "Updated workspace settings for \(workspace.dir)",
                json: MutationResultPayload(message: "Updated workspace settings.", resource: WorkspaceSettingsPayload(updatedSettings)))
        default:
            throw NSError(
                domain: "mx.cli",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unknown action: \(args[3]). Use: workspace settings [get]|update"])
        }
    }

    private func runWorkspacePortSubcommand(orchestrator: MuxyOrchestrator) throws {
        guard args.count >= 4 else {
            throw NSError(
                domain: "mx.cli", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Missing action. Use: workspace port add|remove|list [--dir <path>] [--name <name>]"])
        }

        let workspace = try workspaceRecord(orchestrator: orchestrator)
        switch args[3] {
        case "add":
            let name = try value(for: "--name")
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
                if !settings.ports.contains(where: { $0.name == name }) {
                    settings.ports.append(PortDefinition(name: name))
                }
            }
            let updated = try workspaceSettings(orchestrator: orchestrator)
            try output.emit(
                text: "Added workspace port \(name) to \(workspace.dir)",
                json: MutationResultPayload(message: "Added workspace port \(name).", resource: WorkspaceSettingsPayload(updated)))
        case "remove":
            let name = try value(for: "--name")
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
                settings.ports.removeAll { $0.name == name }
            }
            let updated = try workspaceSettings(orchestrator: orchestrator)
            try output.emit(
                text: "Removed workspace port \(name) from \(workspace.dir)",
                json: MutationResultPayload(message: "Removed workspace port \(name).", resource: WorkspaceSettingsPayload(updated)))
        case "list":
            let settings = try workspaceSettings(orchestrator: orchestrator)
            try output.emitLines(
                text: settings.ports.map(\.name),
                json: settings.ports)
        default:
            throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown action: \(args[3]). Use: workspace port add|remove|list"])
        }
    }

    private func runWorkspaceProcessSubcommand(orchestrator: MuxyOrchestrator) throws {
        guard args.count >= 4 else {
            throw NSError(
                domain: "mx.cli", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Missing action. Use: workspace process add|remove|list [--dir <path>]"])
        }

        let workspace = try workspaceRecord(orchestrator: orchestrator)
        switch args[3] {
        case "add":
            let name = optionalValue(for: "--name")
            let command = try value(for: "--command")
            let onExitStr = optionalValue(for: "--on-exit") ?? ProcessExitAction.none.rawValue
            guard let onExit = ProcessExitAction(rawValue: onExitStr) else {
                throw NSError(
                    domain: "mx.cli", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid --on-exit value '\(onExitStr)'. Use: none|restart|notify"])
            }
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
                settings.processes.append(ProcessTemplate(name: name, command: command, onExit: onExit))
            }
            let updated = try workspaceSettings(orchestrator: orchestrator)
            try output.emit(
                text: "Added workspace process \(name ?? command) to \(workspace.dir)",
                json: MutationResultPayload(message: "Added workspace process \(name ?? command).", resource: WorkspaceSettingsPayload(updated)))
        case "remove":
            let name = try value(for: "--name")
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
                settings.processes.removeAll { $0.name == name }
            }
            let updated = try workspaceSettings(orchestrator: orchestrator)
            try output.emit(
                text: "Removed workspace process \(name) from \(workspace.dir)",
                json: MutationResultPayload(message: "Removed workspace process \(name).", resource: WorkspaceSettingsPayload(updated)))
        case "list":
            let settings = try workspaceSettings(orchestrator: orchestrator)
            try output.emitLines(
                text: settings.processes.map { "\($0.name ?? "-")\t\($0.command)\ton-exit=\($0.onExit.rawValue)" },
                json: settings.processes)
        default:
            throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown action: \(args[3]). Use: workspace process add|remove|list"])
        }
    }

    private func runWorkspaceStatusCheckSubcommand(orchestrator: MuxyOrchestrator) throws {
        guard args.count >= 4 else {
            throw NSError(
                domain: "mx.cli", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Missing action. Use: workspace status-check add|remove|list [--dir <path>]"])
        }

        let workspace = try workspaceRecord(orchestrator: orchestrator)
        switch args[3] {
        case "add":
            let name = optionalValue(for: "--name")
            let process = try value(for: "--process")
            let command = try value(for: "--command")
            let interval = Int(optionalValue(for: "--interval") ?? "") ?? PollingConstants.statusCheckDefaultInterval
            let timeout = Int(optionalValue(for: "--timeout") ?? "") ?? PollingConstants.statusCheckDefaultTimeout
            let onFailStr = optionalValue(for: "--on-fail") ?? OnFailAction.none.rawValue
            guard let onFail = OnFailAction(rawValue: onFailStr) else {
                throw NSError(
                    domain: "mx.cli", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid --on-fail value '\(onFailStr)'. Use: none|restart|notify"])
            }
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
                settings.statusChecks.append(
                    StatusCheckDefinition(name: name, process: process, command: command, interval: interval, timeout: timeout, onFail: onFail))
            }
            let updated = try workspaceSettings(orchestrator: orchestrator)
            try output.emit(
                text: "Added workspace status check \(name ?? process) to \(workspace.dir)",
                json: MutationResultPayload(message: "Added workspace status check \(name ?? process).", resource: WorkspaceSettingsPayload(updated)))
        case "remove":
            let name = try value(for: "--name")
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
                settings.statusChecks.removeAll { $0.name == name }
            }
            let updated = try workspaceSettings(orchestrator: orchestrator)
            try output.emit(
                text: "Removed workspace status check \(name) from \(workspace.dir)",
                json: MutationResultPayload(message: "Removed workspace status check \(name).", resource: WorkspaceSettingsPayload(updated)))
        case "list":
            let settings = try workspaceSettings(orchestrator: orchestrator)
            try output.emitLines(
                text: settings.statusChecks.map {
                    "\($0.name ?? "-")\tprocess=\($0.process)\tcommand=\($0.command)\tinterval=\($0.interval)\ttimeout=\($0.timeout)\ton-fail=\($0.onFail.rawValue)"
                },
                json: settings.statusChecks)
        default:
            throw NSError(
                domain: "mx.cli",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unknown action: \(args[3]). Use: workspace status-check add|remove|list"])
        }
    }

    private func runWorkspaceBrowserSessionSubcommand(orchestrator: MuxyOrchestrator) throws {
        guard args.count >= 4 else {
            throw NSError(
                domain: "mx.cli", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Missing action. Use: workspace browser-session add|remove|list [--dir <path>]"])
        }

        let workspace = try workspaceRecord(orchestrator: orchestrator)
        switch args[3] {
        case "add":
            let name = optionalValue(for: "--name")
            let url = try value(for: "--url")
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
                settings.browserSessions.append(BrowserSession(name: name, url: url))
            }
            let updated = try workspaceSettings(orchestrator: orchestrator)
            try output.emit(
                text: "Added workspace browser session \(name ?? url) to \(workspace.dir)",
                json: MutationResultPayload(message: "Added workspace browser session \(name ?? url).", resource: WorkspaceSettingsPayload(updated)))
        case "remove":
            let url = try value(for: "--url")
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
                settings.browserSessions.removeAll { $0.url == url }
            }
            let updated = try workspaceSettings(orchestrator: orchestrator)
            try output.emit(
                text: "Removed workspace browser session \(url) from \(workspace.dir)",
                json: MutationResultPayload(message: "Removed workspace browser session \(url).", resource: WorkspaceSettingsPayload(updated)))
        case "list":
            let settings = try workspaceSettings(orchestrator: orchestrator)
            try output.emitLines(
                text: settings.browserSessions.map { "\($0.name ?? "-")\t\($0.url ?? "-")" },
                json: settings.browserSessions)
        default:
            throw NSError(
                domain: "mx.cli",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unknown action: \(args[3]). Use: workspace browser-session add|remove|list"])
        }
    }

    private func runDiscover(orchestrator: MuxyOrchestrator) throws {
        let nonFlagArgs = args.dropFirst().filter { !$0.hasPrefix("--") }
        guard nonFlagArgs.count == 1 else {
            throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "`mx discover` does not take any flags or arguments."])
        }
        let workspaces = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: nil)
        if workspaces.isEmpty {
            try output.emit(
                text: "No new workspaces created",
                json: MutationResultPayload(message: "No new workspaces created.", resource: [WorkspaceRecord]()))
        } else {
            try output.emitLines(
                text: ["Created \(workspaces.count) workspace(s):"] + workspaces.map { "\($0.name)\t\($0.dir)" },
                json: MutationResultPayload(message: "Created \(workspaces.count) workspace(s).", resource: workspaces))
        }
    }

    private func value(for flag: String) throws -> String {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else {
            throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing required flag \(flag)"])
        }
        return args[idx + 1]
    }

    private func optionalValue(for flag: String) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    private func optionalValueAllowingMissingValue(for flag: String) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        let candidate = args[idx + 1]
        if candidate.hasPrefix("--") { return nil }
        return candidate
    }

    private func runAgentSubcommand(orchestrator: MuxyOrchestrator) throws {
        guard args.count >= 3, args[2] == "event" else {
            throw NSError(
                domain: "mx.cli", code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Missing agent action. Use: agent event --type init|start|waiting|done|stop [--dir <path>] [--provider iterm2|ghostty]"
                ])
        }
        let hookType = try value(for: "--type")
        let dir = optionalValue(for: "--dir") ?? FileManager.default.currentDirectoryPath
        let providerArg = optionalValue(for: "--provider")

        let env = ProcessInfo.processInfo.environment
        let bundleID = env["__CFBundleIdentifier"] ?? ""
        let provider: AgentProvider
        if let p = providerArg {
            guard let parsed = AgentProvider(rawValue: p) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown provider '\(p)'. Use: iterm2|ghostty"])
            }
            provider = parsed
        } else if bundleID == "com.googlecode.iterm2" {
            provider = .iterm2
        } else if bundleID == "com.mitchellh.ghostty" {
            provider = .ghostty
        } else if hasKnownCodingAgentMarkers(env: env) {
            try output.emit(
                text: "Ignoring agent event: unsupported terminal host '\(bundleID.isEmpty ? "unknown" : bundleID)' for detected coding agent env.",
                json: MutationResultPayload<[String: String]>(
                    message: "Ignored agent event due to unsupported terminal host.",
                    resource: ["bundleIdentifier": bundleID.isEmpty ? "unknown" : bundleID]))
            return
        } else {
            // Manual/non-agent invocation from an unsupported terminal still defaults to iTerm2 semantics.
            provider = .iterm2
        }
        let label = inferredAgentLabel(env: env, provider: provider)

        // ITERM_SESSION_ID has format "wNtNpN:UUID"; extract just the UUID for consistent matching
        // against AppleScript's `id of session`, which returns only the UUID.
        let rawItermSessionID = provider == .iterm2 ? env["ITERM_SESSION_ID"] : nil
        let itermSessionID = rawItermSessionID.map { raw -> String in
            guard let colonIdx = raw.lastIndex(of: ":") else { return raw }
            return String(raw[raw.index(after: colonIdx)...])
        }
        let codexThreadID = env["CODEX_THREAD_ID"]

        // Capture the yabai window ID of the window hosting this agent session.
        let yabaiWindowID: Int? = {
            guard let json = try? Shell.runAndCapture(["yabai", "-m", "query", "--windows", "--window"]), let data = json.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = obj["id"] as? Int
            else { return nil }
            return id
        }()

        let normalizedDir = normalizePath(dir)

        func ensureWorkspace() throws -> String {
            if let ws = try orchestrator.store.workspace(dir: normalizedDir) { return ws.id }
            let ws = try orchestrator.createWorkspaceFromWorktree(worktreePath: normalizedDir)
            return ws.id
        }

        switch hookType {
        case "init":
            let wsID = try ensureWorkspace()
            try orchestrator.registerAgentWindow(
                workspaceID: wsID, provider: provider, label: label, itermSessionID: itermSessionID, codexThreadID: codexThreadID,
                yabaiWindowID: yabaiWindowID, status: .idle)
            try output.emit(
                text: "Agent init: workspace=\(wsID)",
                json: MutationResultPayload(
                    message: "Agent init recorded.",
                    resource: ["workspaceID": wsID, "status": AgentWindowStatus.idle.rawValue]))
            fireAgentEventNotification()

        case "start":
            let wsID = try ensureWorkspace()
            try orchestrator.updateAgentWindowStatus(
                workspaceID: wsID, provider: provider, itermSessionID: itermSessionID, codexThreadID: codexThreadID, yabaiWindowID: yabaiWindowID,
                label: label, status: .spinning)
            try output.emit(
                text: "Agent start: workspace=\(wsID)",
                json: MutationResultPayload(
                    message: "Agent start recorded.",
                    resource: ["workspaceID": wsID, "status": AgentWindowStatus.spinning.rawValue]))
            fireAgentEventNotification()

        case "waiting":
            let wsID = try ensureWorkspace()
            try orchestrator.updateAgentWindowStatus(
                workspaceID: wsID, provider: provider, itermSessionID: itermSessionID, codexThreadID: codexThreadID, yabaiWindowID: yabaiWindowID,
                label: label, status: .waiting)
            try output.emit(
                text: "Agent waiting: workspace=\(wsID)",
                json: MutationResultPayload(
                    message: "Agent waiting recorded.",
                    resource: ["workspaceID": wsID, "status": AgentWindowStatus.waiting.rawValue]))
            fireAgentEventNotification()

        case "done":
            let wsID = try ensureWorkspace()
            try orchestrator.updateAgentWindowStatus(
                workspaceID: wsID, provider: provider, itermSessionID: itermSessionID, codexThreadID: codexThreadID, yabaiWindowID: yabaiWindowID,
                label: label, status: .done)
            try output.emit(
                text: "Agent done: workspace=\(wsID)",
                json: MutationResultPayload(
                    message: "Agent done recorded.",
                    resource: ["workspaceID": wsID, "status": AgentWindowStatus.done.rawValue]))
            fireAgentEventNotification()

        case "stop":
            let wsID = try ensureWorkspace()
            try orchestrator.updateAgentWindowStatus(
                workspaceID: wsID, provider: provider, itermSessionID: itermSessionID, codexThreadID: codexThreadID, yabaiWindowID: yabaiWindowID,
                label: label, status: .done)
            try output.emit(
                text: "Agent stop: workspace=\(wsID)",
                json: MutationResultPayload(
                    message: "Agent stop recorded.",
                    resource: ["workspaceID": wsID, "status": AgentWindowStatus.done.rawValue]))
            fireAgentEventNotification()

        default:
            throw NSError(
                domain: "mx.cli", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unknown event type '\(hookType)'. Use: init|start|waiting|done|stop"])
        }
    }

    private func fireAgentEventNotification() {
        DistributedNotificationCenter.default().postNotificationName(
            IPCNotification.agentEventFired, object: nil, userInfo: nil, options: [.deliverImmediately])
    }

    /// Returns the inferred AgentProvider if the process is running inside a known coding agent environment,
    /// or nil if the environment cannot be identified as a coding agent.
    private func inferCodingAgentProvider() -> AgentProvider? {
        let env = ProcessInfo.processInfo.environment
        let bundleID = env["__CFBundleIdentifier"] ?? ""
        if bundleID == "com.googlecode.iterm2", env["CODEX_THREAD_ID"] != nil { return .iterm2 }
        if bundleID == "com.googlecode.iterm2", env["CLAUDE_CODE_ENTRYPOINT"] != nil { return .iterm2 }
        if bundleID == "com.mitchellh.ghostty", env["CODEX_THREAD_ID"] != nil { return .ghostty }
        if bundleID == "com.mitchellh.ghostty", env["CLAUDE_CODE_ENTRYPOINT"] != nil { return .ghostty }
        return nil
    }

    private func hasKnownCodingAgentMarkers(env: [String: String]) -> Bool { env["CODEX_THREAD_ID"] != nil || env["CLAUDE_CODE_ENTRYPOINT"] != nil }

    private func inferredAgentLabel(env: [String: String], provider: AgentProvider) -> String? {
        let bundleID = env["__CFBundleIdentifier"] ?? ""
        if (bundleID == "com.googlecode.iterm2" || bundleID == "com.mitchellh.ghostty"), env["CODEX_THREAD_ID"] != nil { return "Codex CLI" }
        if (bundleID == "com.googlecode.iterm2" || bundleID == "com.mitchellh.ghostty"), env["CLAUDE_CODE_ENTRYPOINT"] != nil {
            return "Claude Code CLI"
        }
        return nil
    }

    /// Fires an agent event for the given workspace and status, using the current environment's session identifiers.
    private func fireAgentEvent(orchestrator: MuxyOrchestrator, workspaceID: String, status: AgentWindowStatus) throws {
        let env = ProcessInfo.processInfo.environment
        let bundleID = env["__CFBundleIdentifier"] ?? ""
        let provider: AgentProvider
        if bundleID == "com.googlecode.iterm2" {
            provider = .iterm2
        } else if bundleID == "com.mitchellh.ghostty" {
            provider = .ghostty
        } else if hasKnownCodingAgentMarkers(env: env) {
            return
        } else {
            provider = .iterm2
        }
        let label = inferredAgentLabel(env: env, provider: provider)
        let rawItermSessionID = provider == .iterm2 ? env["ITERM_SESSION_ID"] : nil
        let itermSessionID = rawItermSessionID.map { raw -> String in
            guard let colonIdx = raw.lastIndex(of: ":") else { return raw }
            return String(raw[raw.index(after: colonIdx)...])
        }
        let codexThreadID = env["CODEX_THREAD_ID"]
        let yabaiWindowID: Int? = {
            guard let json = try? Shell.runAndCapture(["yabai", "-m", "query", "--windows", "--window"]), let data = json.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = obj["id"] as? Int
            else { return nil }
            return id
        }()
        try orchestrator.updateAgentWindowStatus(
            workspaceID: workspaceID, provider: provider, itermSessionID: itermSessionID, codexThreadID: codexThreadID,
            yabaiWindowID: yabaiWindowID, label: label, status: status)
        fireAgentEventNotification()
    }

    private func normalizePath(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }

    private func printHelp() {
        print(
            """
            mx command line

            Usage:
              mx --version
              mx discover
              mx dashboard [--json]

              mx project list
              mx project get --dir <path>
              mx project add --dir <path>
              mx project add --git-url <url>
              mx project update --dir <path> [--setup-script <script>] [--stop-script <script>]
              mx project remove --dir <path>
              mx project port list --dir <path>
              mx project port add --dir <path> --name <NAME>
              mx project port remove --dir <path> --name <NAME>
              mx project process list --dir <path>
              mx project process add --dir <path> --command <cmd> [--name <name>] [--on-exit none|restart|notify]
              mx project process remove --dir <path> --name <name>
              mx project status-check list --dir <path>
              mx project status-check add --dir <path> --process <process> --command <cmd> [--name <name>] [--interval <seconds>] [--timeout <seconds>] [--on-fail none|restart|notify]
              mx project status-check remove --dir <path> --name <name>
              mx project browser-session list --dir <path>
              mx project browser-session add --dir <path> --url <url> [--name <name>]
              mx project browser-session remove --dir <path> --url <url>

              mx workspace list --project-dir <path> [--all]
              mx workspace get [--dir <path>]
              mx workspace create --project-dir <path> --name <name> --branch <branch> [--target-branch <branch>] [--directory-name <name>] [--tooltip <text>]
              mx workspace import [--dir <path>] [--title <title>] [--tooltip <text>]
              mx workspace update [--dir <path>] [--title <title>] [--branch <branch>] [--directory-name <name>|--dirname <name>|--dir-name <name>] [--tooltip <text>|--clear-tooltip] [--active|--inactive]
              mx workspace launch [--dir <path>]
              mx workspace restart [--dir <path>]
              mx workspace up [--dir <path>] [--force-restart] [--focus <name>]
              mx workspace stop [--dir <path>]
              mx workspace archive [--dir <path>]
              mx workspace focus [--dir <path>] --window <name>
              mx workspace runtime [--dir <path>]
              mx workspace settings [get] [--dir <path>]
              mx workspace settings update [--dir <path>] [--stop-script <script>|--clear-stop-script]
              mx workspace port add|remove|list [--dir <path>] [--name <name>]
              mx workspace process add|remove|list [--dir <path>]
              mx workspace status-check add|remove|list [--dir <path>]
              mx workspace browser-session add|remove|list [--dir <path>]

              mx agent event --type init|start|waiting|done|stop [--dir <path>] [--provider iterm2|ghostty]

            Notes:
              - Append `--json` to any Muxy command to receive the canonical machine-facing API response.
              - All settings are stored in ~/.muxy/muxy.db.
              - GUI settings (⌘,) let you pick a preferred editor (VS Code, Cursor, Windsurf).
              - Runtime state is stored in ~/.muxy/muxy.db and migrated in place with additive schema changes.
              - Removing a git project first removes managed worktrees via `git worktree remove --force`, then deletes related workspace directories under ~/muxy/workspaces.
              - Removing a project deletes only muxy state unless it is a muxy-cloned git repo under ~/muxy/repos (or legacy ~/muxy/projects); those managed repository directories are deleted.
              - Workspaces snapshot project port definitions, processes, status checks, and browser sessions into the runtime DB on creation.
              - Project `setup_script` runs when a workspace is created/revived; GUI create persists workspace first and runs setup in background.
              - Launch waits for pending/running setup to complete and fails with the setup error if setup failed.
              - `mx discover` reconciles git worktrees across all registered projects by creating missing workspaces, archiving workspaces whose worktrees are no longer valid, refreshing stored branch names from disk, and running the project `setup_script` for each newly created workspace.
              - Project/workspace `stop_script` runs whenever a workspace is stopped (including restart/archive stop phase), after automatic process termination attempts.
              - `workspace up` ensures a workspace and all its processes are running: launches when stopped; when already running, restarts any exited processes. Windows open without activating the app. Add `--force-restart` to force a full stop+launch. Add `--focus <name>` to bring one named workspace window to the foreground after launch.
              - If a workspace directory is missing during stop, muxy still stops the workspace, skips `stop_script`, and prints a note.
              - For git projects, `workspace create` requires `--branch`; `--target-branch` defaults to main/master if available.
              - `workspace create --directory-name` (or `--dirname`) overrides the auto-generated git worktree directory name; allowed characters are letters, numbers, '-', and '_', with no spaces.
              - `workspace update` updates workspace metadata (`--title`, `--branch`, `--directory-name`/`--dirname`/`--dir-name`, `--tooltip`) and visibility state (`--active`/`--inactive`); protected `main`/`master` branches cannot be renamed.
              - Archiving a non-git workspace never deletes the project directory.
              - Workspaces reserve named ports from the configured port range based on project/workspace port definitions.
              - GUI window focus shortcuts use the configured direct-focus modifier plus digits 1 through 9 when the GUI is focused.
              - GUI queued window focus uses the configured sequence modifier plus digits 1 through 9 and replays them in order on modifier release.
              - GUI window cycle shortcuts are global and keep working when the GUI is not focused.
              - Each browser session, process, and coding agent uses its own dedicated top-level window.
              - Workspace focus and cycling use tracked yabai window IDs directly; missing browser windows are marked stale for later recovery.
              - Diagnostics: DEBUG=1 logs full workspace-cycle timing plus direct browser/window focus-path timing for dedicated-window focus flows.
              - GUI action shortcuts can be overridden in the app Settings.
            """)
    }
}

do { try CLI(args: CommandLine.arguments).run() } catch {
    CLITextOrJSONOutput.emitError(error, wantsJSON: CommandLine.arguments.contains("--json"))
    exit(1)
}
