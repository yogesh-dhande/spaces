import Foundation
import streamctl

struct CLI {
    let args: [String]

    func run() throws {
        guard args.count >= 2 else {
            printHelp()
            return
        }

        let command = args[1]

        if command == "version" || command == "--version" {
            print("mx \(AppVersion.current)")
            return
        }

        let db = try DatabaseLocator.defaultPath()
        let store = try SQLiteStore(path: db)
        let orchestrator = MuxyOrchestrator(store: store)

        _ = try orchestrator.syncConfig()

        switch command {
        case "config": try runConfigSubcommand(orchestrator: orchestrator)
        case "settings": try runSettingsSubcommand(orchestrator: orchestrator)
        case "project": try runProjectSubcommand(orchestrator: orchestrator)
        case "workspace": try runWorkspaceSubcommand(orchestrator: orchestrator)
        default: printHelp()
        }
    }

    private func runConfigSubcommand(orchestrator: MuxyOrchestrator) throws {
        guard args.count >= 3 else {
            throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing config action. Use: config show|set"])
        }
        switch args[2] {
        case "show":
            let config = try orchestrator.appConfig()
            let projectCount = try orchestrator.listProjects().count
            print("editor=\(config.editor?.rawValue ?? "none") port_range=\(config.portRange.start)-\(config.portRange.end) projects=\(projectCount)")
        case "set":
            if let rawEditor = optionalValue(for: "--editor") {
                guard let pref = EditorPreference(rawValue: rawEditor) else {
                    throw NSError(
                        domain: "mx.cli", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Unknown editor: \(rawEditor). Use: none|vscode|cursor|windsurf|vim"])
                }
                _ = try orchestrator.updateEditorPreference(pref == .none ? nil : pref)
                print("editor=\(pref.rawValue)")
            } else if let rangeStr = optionalValue(for: "--port-range") {
                let parts = rangeStr.split(separator: "-").compactMap { Int($0) }
                guard parts.count == 2, parts[0] > 0, parts[1] > parts[0] else {
                    throw NSError(
                        domain: "mx.cli", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid port range: \(rangeStr). Format: <start>-<end> e.g. 20000-30000"])
                }
                _ = try orchestrator.updatePortRange(PortRange(start: parts[0], end: parts[1]))
                print("port_range=\(parts[0])-\(parts[1])")
            } else {
                throw NSError(
                    domain: "mx.cli", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Use --editor <value> or --port-range <start>-<end>"])
            }
        default: throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown config action: \(args[2]). Use: show|set"])
        }
    }

    private func runProjectSubcommand(orchestrator: MuxyOrchestrator) throws {
        guard args.count >= 3 else {
            throw NSError(
                domain: "mx.cli", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Missing project action. Use: project list|add|update|remove|port|process|status-check|browser-session"]
            )
        }

        switch args[2] {
        case "port": try runProjectPortSubcommand(orchestrator: orchestrator)
        case "process": try runProjectProcessSubcommand(orchestrator: orchestrator)
        case "status-check": try runProjectStatusCheckSubcommand(orchestrator: orchestrator)
        case "browser-session": try runProjectBrowserSessionSubcommand(orchestrator: orchestrator)
        case "list":
            let projects = try orchestrator.listProjects()
            for project in projects {
                print("\(project.name)\t\(project.dir)\tgit=\(project.isGitRepo ? "yes" : "no")\tdefault_branch=\(project.defaultBranch ?? "-")")
            }
        case "add":
            let dir = optionalValue(for: "--dir")
            let gitURL = optionalValue(for: "--git-url")
            if dir != nil, gitURL != nil {
                throw NSError(
                    domain: "mx.cli", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Use either --dir <path> or --git-url <url>, but not both."])
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
            print("Added project \(record.name)\t\(record.dir)")
        case "update":
            let dir = try value(for: "--dir")
            let setupScript = optionalValue(for: "--setup-script")
            let stopScript = optionalValue(for: "--stop-script")
            try orchestrator.updateProjectConfig(projectID: normalizePath(dir)) { project in
                if let setupScript { project.setupScript = setupScript }
                if let stopScript { project.stopScript = stopScript }
            }
            print("Updated project \(dir)")
        case "remove":
            let dir = try value(for: "--dir")
            try orchestrator.removeProject(dir: dir)
            print("Removed project \(dir)")
        default: throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown project action: \(args[2])"])
        }
    }

    private func runProjectPortSubcommand(orchestrator: MuxyOrchestrator) throws {
        guard args.count >= 4 else {
            throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing action. Use: project port add|remove|list --dir <path> [--name <name>]"])
        }
        let dir = try value(for: "--dir")
        let projectID = normalizePath(dir)
        switch args[3] {
        case "add":
            let name = try value(for: "--name")
            try orchestrator.updateProjectConfig(projectID: projectID) { config in
                if !config.ports.contains(where: { $0.name == name }) {
                    config.ports.append(PortDefinition(name: name))
                }
            }
            print("Added port \(name) to \(dir)")
        case "remove":
            let name = try value(for: "--name")
            try orchestrator.updateProjectConfig(projectID: projectID) { config in
                config.ports.removeAll { $0.name == name }
            }
            print("Removed port \(name) from \(dir)")
        case "list":
            guard let project = try orchestrator.project(id: projectID) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Project not found for dir \(dir)"])
            }
            for port in project.ports { print(port.name) }
        default:
            throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown action: \(args[3]). Use: project port add|remove|list"])
        }
    }

    private func runProjectProcessSubcommand(orchestrator: MuxyOrchestrator) throws {
        guard args.count >= 4 else {
            throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing action. Use: project process add|remove|list --dir <path>"])
        }
        let dir = try value(for: "--dir")
        let projectID = normalizePath(dir)
        switch args[3] {
        case "add":
            let name = optionalValue(for: "--name")
            let command = try value(for: "--command")
            try orchestrator.updateProjectConfig(projectID: projectID) { config in
                config.processes.append(ProcessTemplate(name: name, command: command))
            }
            print("Added process \(name ?? command) to \(dir)")
        case "remove":
            let name = try value(for: "--name")
            try orchestrator.updateProjectConfig(projectID: projectID) { config in
                config.processes.removeAll { $0.name == name }
            }
            print("Removed process \(name) from \(dir)")
        case "list":
            guard let project = try orchestrator.project(id: projectID) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Project not found for dir \(dir)"])
            }
            for process in project.processes {
                print("\(process.name ?? "-")\t\(process.command)")
            }
        default:
            throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown action: \(args[3]). Use: project process add|remove|list"])
        }
    }

    private func runProjectStatusCheckSubcommand(orchestrator: MuxyOrchestrator) throws {
        guard args.count >= 4 else {
            throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing action. Use: project status-check add|remove|list --dir <path>"])
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
            let onExitStr = optionalValue(for: "--on-exit") ?? StatusCheckOnExit.none.rawValue
            guard let onExit = StatusCheckOnExit(rawValue: onExitStr) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid --on-exit value '\(onExitStr)'. Use: none|restart|notify"])
            }
            let interval: Int
            if let s = intervalStr {
                guard let n = Int(s), n > 0 else {
                    throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid --interval '\(s)'. Must be a positive integer."])
                }
                interval = n
            } else {
                interval = PollingConstants.statusCheckDefaultInterval
            }
            let timeout: Int
            if let s = timeoutStr {
                guard let n = Int(s), n > 0 else {
                    throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid --timeout '\(s)'. Must be a positive integer."])
                }
                timeout = n
            } else {
                timeout = PollingConstants.statusCheckDefaultTimeout
            }
            try orchestrator.updateProjectConfig(projectID: projectID) { config in
                config.statusChecks.append(
                    StatusCheckDefinition(name: name, process: process, command: command, interval: interval, timeout: timeout, onExit: onExit)
                )
            }
            print("Added status check \(name ?? process) to \(dir)")
        case "remove":
            let name = try value(for: "--name")
            try orchestrator.updateProjectConfig(projectID: projectID) { config in
                config.statusChecks.removeAll { $0.name == name }
            }
            print("Removed status check \(name) from \(dir)")
        case "list":
            guard let project = try orchestrator.project(id: projectID) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Project not found for dir \(dir)"])
            }
            for check in project.statusChecks {
                print("\(check.name ?? "-")\tprocess=\(check.process)\tcommand=\(check.command)\tinterval=\(check.interval)\ttimeout=\(check.timeout)\ton-exit=\(check.onExit.rawValue)")
            }
        default:
            throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown action: \(args[3]). Use: project status-check add|remove|list"])
        }
    }

    private func runProjectBrowserSessionSubcommand(orchestrator: MuxyOrchestrator) throws {
        guard args.count >= 4 else {
            throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing action. Use: project browser-session add|remove|list --dir <path>"])
        }
        let dir = try value(for: "--dir")
        let projectID = normalizePath(dir)
        switch args[3] {
        case "add":
            let url = try value(for: "--url")
            try orchestrator.updateProjectConfig(projectID: projectID) { config in
                config.browserSessions.append(BrowserSession(url: url))
            }
            print("Added browser session \(url) to \(dir)")
        case "remove":
            let url = try value(for: "--url")
            try orchestrator.updateProjectConfig(projectID: projectID) { config in
                config.browserSessions.removeAll { $0.url == url }
            }
            print("Removed browser session \(url) from \(dir)")
        case "list":
            guard let project = try orchestrator.project(id: projectID) else {
                throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Project not found for dir \(dir)"])
            }
            for session in project.browserSessions {
                print(session.url ?? "-")
            }
        default:
            throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown action: \(args[3]). Use: project browser-session add|remove|list"])
        }
    }

    private func runWorkspaceSubcommand(orchestrator: MuxyOrchestrator) throws {
        guard args.count >= 3 else {
            throw NSError(
                domain: "mx.cli", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Missing workspace action. Use: workspace list|create|import|discover|launch|restart|stop|archive|activate"])
        }
        switch args[2] {
        case "list":
            let projectDir = try value(for: "--project-dir")
            let projectID = normalizePath(projectDir)
            let workspaces = try orchestrator.listWorkspaces(projectID: projectID, includeArchived: args.contains("--all"))
            for ws in workspaces {
                let flags = [ws.isDefault ? "default" : nil, ws.isRunning ? "running" : nil, ws.isArchived ? "archived" : nil].compactMap { $0 }
                    .joined(separator: ",")
                print("\(ws.name)\t\(ws.dir)\t\(flags)")
            }
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
            let projectID = normalizePath(projectDir)
            let workspace = try orchestrator.createWorkspace(
                projectID: projectID, name: name, branch: branch, targetBranch: targetBranch, directoryName: directoryName)
            print("Created workspace \(workspace.name)\t\(workspace.dir)")
        case "import":
            let dir = optionalValue(for: "--dir") ?? FileManager.default.currentDirectoryPath
            let name = optionalValue(for: "--name")
            let workspace = try orchestrator.createWorkspaceFromWorktree(worktreePath: dir, name: name)
            print("Created workspace \(workspace.name)\t\(workspace.dir)")
        case "discover":
            let projectDir = optionalValue(for: "--project-dir")
            let projectID = projectDir.map { normalizePath($0) }
            let workspaces = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: projectID)
            if workspaces.isEmpty {
                print("No new workspaces created")
            } else {
                print("Created \(workspaces.count) workspace(s):")
                for ws in workspaces {
                    print("\(ws.name)\t\(ws.dir)")
                }
            }
        case "launch":
            let id = try workspaceID(orchestrator: orchestrator)
            try orchestrator.launchWorkspace(workspaceID: id)
            print("Launched workspace \(id)")
        case "restart":
            let id = try workspaceID(orchestrator: orchestrator)
            try orchestrator.restartWorkspace(workspaceID: id)
            print("Restarted workspace \(id)")
        case "stop":
            let id = try workspaceID(orchestrator: orchestrator)
            try orchestrator.stopWorkspace(workspaceID: id)
            print("Stopped workspace \(id)")
        case "archive":
            let id = try workspaceID(orchestrator: orchestrator)
            try orchestrator.archiveWorkspace(workspaceID: id)
            print("Archived workspace \(id)")
        case "activate":
            let id = try workspaceID(orchestrator: orchestrator)
            try orchestrator.setActiveWorkspace(id: id)
            print("Activated workspace \(id)")
        default: throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown workspace action: \(args[2])"])
        }
    }

    private func workspaceID(orchestrator: MuxyOrchestrator) throws -> String {
        let dir = optionalValue(for: "--dir") ?? FileManager.default.currentDirectoryPath
        let normalizedDir = normalizePath(dir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedDir) else {
            throw NSError(
                domain: "mx.cli", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Workspace not found at: \(normalizedDir). Use --dir <path> to specify a different workspace directory."])
        }
        return workspace.id
    }

    private func runSettingsSubcommand(orchestrator: MuxyOrchestrator) throws {
        guard args.count >= 3 else {
            throw NSError(
                domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing settings action. Use: settings get|set|reset"])
        }

        switch args[2] {
        case "get":
            if args.contains("--gui-hotkey") {
                let current = try orchestrator.guiHotkey()
                print("gui-hotkey\t\(current)")
            } else if args.contains("--gui-next-shortcut") {
                let current = try orchestrator.guiNextShortcut()
                print("gui-next-shortcut\t\(current)")
            } else if args.contains("--gui-prev-shortcut") {
                let current = try orchestrator.guiPreviousShortcut()
                print("gui-prev-shortcut\t\(current)")
            } else if args.contains("--gui-show-shortcut") {
                let current = try orchestrator.guiShowShortcut()
                print("gui-show-shortcut\t\(current)")
            } else if args.contains("--gui-add-project-shortcut") {
                let current = try orchestrator.guiAddProjectShortcut()
                print("gui-add-project-shortcut\t\(current)")
            } else if args.contains("--gui-add-workspace-shortcut") {
                let current = try orchestrator.guiAddWorkspaceShortcut()
                print("gui-add-workspace-shortcut\t\(current)")
            } else if args.contains("--gui-reload-shortcut") {
                let current = try orchestrator.guiReloadShortcut()
                print("gui-reload-shortcut\t\(current)")
            } else if args.contains("--gui-open-editor-shortcut") {
                let current = try orchestrator.guiOpenEditorShortcut()
                print("gui-open-editor-shortcut\t\(current)")
            } else if args.contains("--gui-open-terminal-shortcut") {
                let current = try orchestrator.guiOpenTerminalShortcut()
                print("gui-open-terminal-shortcut\t\(current)")
            } else if args.contains("--gui-open-finder-shortcut") {
                let current = try orchestrator.guiOpenFinderShortcut()
                print("gui-open-finder-shortcut\t\(current)")
            } else if args.contains("--gui-open-settings-shortcut") {
                let current = try orchestrator.guiOpenSettingsShortcut()
                print("gui-open-settings-shortcut\t\(current)")
            } else {
                throw NSError(
                    domain: "mx.cli", code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Missing setting flag. Use: settings get --gui-hotkey|--gui-next-shortcut|--gui-prev-shortcut|--gui-show-shortcut|--gui-add-project-shortcut|--gui-add-workspace-shortcut|--gui-reload-shortcut|--gui-open-editor-shortcut|--gui-open-terminal-shortcut|--gui-open-finder-shortcut|--gui-open-settings-shortcut"
                    ])
            }

        case "set":
            if let raw = optionalValue(for: "--gui-hotkey") {
                let spec = try HotkeySpec.parse(raw)
                try orchestrator.setGUIHotkey(spec.normalized)
                print("Updated gui-hotkey\t\(spec.normalized)")
            } else if let raw = optionalValue(for: "--gui-next-shortcut") {
                let spec = try HotkeySpec.parse(raw)
                try orchestrator.setGUINextShortcut(spec.normalized)
                print("Updated gui-next-shortcut\t\(spec.normalized)")
            } else if let raw = optionalValue(for: "--gui-prev-shortcut") {
                let spec = try HotkeySpec.parse(raw)
                try orchestrator.setGUIPreviousShortcut(spec.normalized)
                print("Updated gui-prev-shortcut\t\(spec.normalized)")
            } else if let raw = optionalValue(for: "--gui-show-shortcut") {
                let spec = try HotkeySpec.parse(raw)
                try orchestrator.setGUIShowShortcut(spec.normalized)
                print("Updated gui-show-shortcut\t\(spec.normalized)")
            } else if let raw = optionalValue(for: "--gui-add-project-shortcut") {
                let spec = try HotkeySpec.parse(raw)
                try orchestrator.setGUIAddProjectShortcut(spec.normalized)
                print("Updated gui-add-project-shortcut\t\(spec.normalized)")
            } else if let raw = optionalValue(for: "--gui-add-workspace-shortcut") {
                let spec = try HotkeySpec.parse(raw)
                try orchestrator.setGUIAddWorkspaceShortcut(spec.normalized)
                print("Updated gui-add-workspace-shortcut\t\(spec.normalized)")
            } else if let raw = optionalValue(for: "--gui-reload-shortcut") {
                let spec = try HotkeySpec.parse(raw)
                try orchestrator.setGUIReloadShortcut(spec.normalized)
                print("Updated gui-reload-shortcut\t\(spec.normalized)")
            } else if let raw = optionalValue(for: "--gui-open-editor-shortcut") {
                let spec = try HotkeySpec.parse(raw)
                try orchestrator.setGUIOpenEditorShortcut(spec.normalized)
                print("Updated gui-open-editor-shortcut\t\(spec.normalized)")
            } else if let raw = optionalValue(for: "--gui-open-terminal-shortcut") {
                let spec = try HotkeySpec.parse(raw)
                try orchestrator.setGUIOpenTerminalShortcut(spec.normalized)
                print("Updated gui-open-terminal-shortcut\t\(spec.normalized)")
            } else if let raw = optionalValue(for: "--gui-open-finder-shortcut") {
                let spec = try HotkeySpec.parse(raw)
                try orchestrator.setGUIOpenFinderShortcut(spec.normalized)
                print("Updated gui-open-finder-shortcut\t\(spec.normalized)")
            } else if let raw = optionalValue(for: "--gui-open-settings-shortcut") {
                let spec = try HotkeySpec.parse(raw)
                try orchestrator.setGUIOpenSettingsShortcut(spec.normalized)
                print("Updated gui-open-settings-shortcut\t\(spec.normalized)")
            } else {
                throw NSError(
                    domain: "mx.cli", code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Missing setting flag/value. Use: settings set --gui-hotkey|--gui-next-shortcut|--gui-prev-shortcut|--gui-show-shortcut|--gui-add-project-shortcut|--gui-add-workspace-shortcut|--gui-reload-shortcut|--gui-open-editor-shortcut|--gui-open-terminal-shortcut|--gui-open-finder-shortcut|--gui-open-settings-shortcut <spec>"
                    ])
            }

        case "reset":
            if args.contains("--gui-hotkey") {
                try orchestrator.setGUIHotkey(nil)
                print("Reset gui-hotkey\t\(SettingsKey.defaultGUIHotkey)")
            } else if args.contains("--gui-next-shortcut") {
                try orchestrator.setGUINextShortcut(nil)
                print("Reset gui-next-shortcut\t\(SettingsKey.defaultGUINextShortcut)")
            } else if args.contains("--gui-prev-shortcut") {
                try orchestrator.setGUIPreviousShortcut(nil)
                print("Reset gui-prev-shortcut\t\(SettingsKey.defaultGUIPreviousShortcut)")
            } else if args.contains("--gui-show-shortcut") {
                try orchestrator.setGUIShowShortcut(nil)
                print("Reset gui-show-shortcut\t\(SettingsKey.defaultGUIShowShortcut)")
            } else if args.contains("--gui-add-project-shortcut") {
                try orchestrator.setGUIAddProjectShortcut(nil)
                print("Reset gui-add-project-shortcut\t\(SettingsKey.defaultGUIAddProjectShortcut)")
            } else if args.contains("--gui-add-workspace-shortcut") {
                try orchestrator.setGUIAddWorkspaceShortcut(nil)
                print("Reset gui-add-workspace-shortcut\t\(SettingsKey.defaultGUIAddWorkspaceShortcut)")
            } else if args.contains("--gui-reload-shortcut") {
                try orchestrator.setGUIReloadShortcut(nil)
                print("Reset gui-reload-shortcut\t\(SettingsKey.defaultGUIReloadShortcut)")
            } else if args.contains("--gui-open-editor-shortcut") {
                try orchestrator.setGUIOpenEditorShortcut(nil)
                print("Reset gui-open-editor-shortcut\t\(SettingsKey.defaultGUIOpenEditorShortcut)")
            } else if args.contains("--gui-open-terminal-shortcut") {
                try orchestrator.setGUIOpenTerminalShortcut(nil)
                print("Reset gui-open-terminal-shortcut\t\(SettingsKey.defaultGUIOpenTerminalShortcut)")
            } else if args.contains("--gui-open-finder-shortcut") {
                try orchestrator.setGUIOpenFinderShortcut(nil)
                print("Reset gui-open-finder-shortcut\t\(SettingsKey.defaultGUIOpenFinderShortcut)")
            } else if args.contains("--gui-open-settings-shortcut") {
                try orchestrator.setGUIOpenSettingsShortcut(nil)
                print("Reset gui-open-settings-shortcut\t\(SettingsKey.defaultGUIOpenSettingsShortcut)")
            } else {
                throw NSError(
                    domain: "mx.cli", code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Missing setting flag. Use: settings reset --gui-hotkey|--gui-next-shortcut|--gui-prev-shortcut|--gui-show-shortcut|--gui-add-project-shortcut|--gui-add-workspace-shortcut|--gui-reload-shortcut|--gui-open-editor-shortcut|--gui-open-terminal-shortcut|--gui-open-finder-shortcut|--gui-open-settings-shortcut"
                    ])
            }

        default: throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown settings action: \(args[2])"])
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

    private func normalizePath(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }

    private func printHelp() {
        print(
            """
            mx command line

            Usage:
              mx version

              mx config show
              mx config set --editor none|vscode|cursor|windsurf|vim
              mx config set --port-range <start>-<end>

              mx settings get --gui-hotkey
              mx settings get --gui-next-shortcut
              mx settings get --gui-prev-shortcut
              mx settings get --gui-show-shortcut
              mx settings get --gui-add-project-shortcut
              mx settings get --gui-add-workspace-shortcut
              mx settings get --gui-reload-shortcut
              mx settings get --gui-open-editor-shortcut
              mx settings get --gui-open-terminal-shortcut
              mx settings get --gui-open-finder-shortcut
              mx settings get --gui-open-settings-shortcut
              mx settings set --gui-hotkey <spec>
              mx settings set --gui-next-shortcut <spec>
              mx settings set --gui-prev-shortcut <spec>
              mx settings set --gui-show-shortcut <spec>
              mx settings set --gui-add-project-shortcut <spec>
              mx settings set --gui-add-workspace-shortcut <spec>
              mx settings set --gui-reload-shortcut <spec>
              mx settings set --gui-open-editor-shortcut <spec>
              mx settings set --gui-open-terminal-shortcut <spec>
              mx settings set --gui-open-finder-shortcut <spec>
              mx settings set --gui-open-settings-shortcut <spec>
              mx settings reset --gui-hotkey
              mx settings reset --gui-next-shortcut
              mx settings reset --gui-prev-shortcut
              mx settings reset --gui-show-shortcut
              mx settings reset --gui-add-project-shortcut
              mx settings reset --gui-add-workspace-shortcut
              mx settings reset --gui-reload-shortcut
              mx settings reset --gui-open-editor-shortcut
              mx settings reset --gui-open-terminal-shortcut
              mx settings reset --gui-open-finder-shortcut
              mx settings reset --gui-open-settings-shortcut

              mx project list
              mx project add --dir <path>
              mx project add --git-url <url>
              mx project update --dir <path> [--setup-script <script>] [--stop-script <script>]
              mx project remove --dir <path>
              mx project port list --dir <path>
              mx project port add --dir <path> --name <NAME>
              mx project port remove --dir <path> --name <NAME>
              mx project process list --dir <path>
              mx project process add --dir <path> --command <cmd> [--name <name>]
              mx project process remove --dir <path> --name <name>
              mx project status-check list --dir <path>
              mx project status-check add --dir <path> --process <process> --command <cmd> [--name <name>] [--interval <seconds>] [--timeout <seconds>] [--on-exit none|restart|notify]
              mx project status-check remove --dir <path> --name <name>
              mx project browser-session list --dir <path>
              mx project browser-session add --dir <path> --url <url>
              mx project browser-session remove --dir <path> --url <url>

              mx workspace list --project-dir <path> [--all]
              mx workspace create --project-dir <path> --name <name> --branch <branch> [--target-branch <branch>] [--directory-name <name>]
              mx workspace import [--dir <path>] [--name <name>]
              mx workspace discover [--project-dir <path>]
              mx workspace launch [--dir <path>]
              mx workspace restart [--dir <path>]
              mx workspace stop [--dir <path>]
              mx workspace archive [--dir <path>]
              mx workspace activate [--dir <path>]

            Notes:
              - Configuration (editor, port_range) is stored in ~/.muxy/muxy.db. YAML config is no longer used.
              - GUI settings (⌘,) let you pick a preferred editor (VS Code, Cursor, Windsurf).
              - Runtime state is stored in ~/.muxy/muxy.db and rebuilt if schema changes.
              - Removing a git project first removes managed worktrees via `git worktree remove --force`, then deletes related workspace directories under ~/muxy/workspaces.
              - Removing a project deletes only muxy state unless it is an muxy-cloned git repo under ~/muxy/projects; those managed project directories are deleted.
              - Workspaces snapshot project processes, status checks, and browser sessions into the runtime DB on creation.
              - Project `setup_script` runs when a workspace is created/revived.
              - Project/workspace `stop_script` runs whenever a workspace is stopped (including restart/archive stop phase), after automatic process termination attempts.
              - For git projects, `workspace create` requires `--branch`; `--target-branch` defaults to main/master if available.
              - `workspace create --directory-name` (or `--dirname`) overrides the auto-generated git worktree directory name; allowed characters are letters, numbers, '-', and '_', with no spaces.
              - Archiving a non-git workspace never deletes the project directory.
              - Workspaces reserve PORT0-PORT9 from the configured port range.
              - GUI window focus shortcuts: cmd+1 through cmd+9 (when GUI is focused).
              - GUI window cycle shortcuts: cmd+shift+[ and cmd+shift+] (global, when GUI is not focused).
              - Chrome tab scans used for workspace window list/cycle are debounced to at most once every \(Int(PollingConstants.browserWindowScanDebounceInterval)) seconds per workspace browser-session config.
              - Browser window focus targets cached tab index first, validates focused active-tab URL, auto-corrects with one refresh, then falls back to URL matching when needed.
              - Diagnostics: DEBUG=1 logs browser scan timing and browser focus-path timing (including cache hit/miss and fallback decisions).
              - GUI action shortcuts can be overridden in Settings or via `mx settings set ...`.
            """)
    }
}

do { try CLI(args: CommandLine.arguments).run() } catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
