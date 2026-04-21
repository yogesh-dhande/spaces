import Foundation
import appctl
import streamctl

struct CLI {
    let args: [String]
    private let output = CLITextOrJSONOutput()

    func run() throws {
        if args.contains("--json") {
            throw NSError(
                domain: "mx.cli",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "`--json` is no longer supported."])
        }

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
        case "workspace": try runWorkspaceSubcommand(orchestrator: orchestrator)
        case "dashboard":
            throw NSError(
                domain: "mx.cli",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "`mx dashboard` was removed with the Tauri proof of concept."])
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
                        "Unsupported command."
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
                        "Missing workspace action. Use: workspace import|up"
                ])
        }
        switch args[2] {
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
                    text: "Workspace already exists: \(workspace.title)\t\(workspace.dir)",
                    json: MutationResultPayload(message: "Workspace already exists.", resource: workspace))
            } else {
                var created = try orchestrator.createWorkspaceFromWorktree(worktreePath: dir, name: title)
                if let tooltip {
                    try orchestrator.updateWorkspaceMetadata(workspaceID: created.id, tooltip: .some(tooltip))
                    created = try orchestrator.store.workspace(id: created.id)!
                }
                workspace = created
                try output.emit(
                    text: "Created workspace \(workspace.title)\t\(workspace.dir)",
                    json: MutationResultPayload(message: "Created workspace \(workspace.title).", resource: workspace))
            }
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
                text: CLITextRenderer.workspaceSettingsLines(settings),
                json: "")
            return
        }

        switch args[3] {
        case "get":
            let settings = try workspaceSettings(orchestrator: orchestrator)
            try output.emit(
                text: CLITextRenderer.workspaceSettingsLines(settings),
                json: "")
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
            throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsupported command."])
        }
        let workspaces = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: nil)
        if workspaces.isEmpty {
            try output.emit(
                text: "No new workspaces created",
                json: MutationResultPayload(message: "No new workspaces created.", resource: [WorkspaceRecord]()))
        } else {
            try output.emitLines(
                text: ["Created \(workspaces.count) workspace(s):"] + workspaces.map { "\($0.title)\t\($0.dir)" },
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
              mx workspace import [--dir <path>] [--title <title>] [--tooltip <text>]
              mx workspace up [--dir <path>] [--force-restart] [--focus <name>]
              mx agent event --type init|start|waiting|done|stop [--dir <path>] [--provider iterm2|ghostty]

            Notes:
              - All settings are stored in ~/.muxy/muxy.db.
              - Runtime state is stored in ~/.muxy/muxy.db and migrated in place with additive schema changes.
              - Launch waits for pending/running setup to complete and fails with the setup error if setup failed.
              - `workspace up` ensures a workspace and all its processes are running: launches when stopped; when already running, restarts any exited processes. Windows open without activating the app. Add `--force-restart` to force a full stop+launch. Add `--focus <name>` to bring one named workspace window to the foreground after launch.
              - `workspace import` registers the current directory by default, or another directory via `--dir`.
              - Agent events stay explicit. `workspace import` and `workspace up` do not imply agent lifecycle.
            """)
    }
}

do { try CLI(args: CommandLine.arguments).run() } catch {
    CLITextOrJSONOutput.emitError(error, wantsJSON: false)
    exit(1)
}
