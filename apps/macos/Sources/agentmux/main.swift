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
        let db = try DatabaseLocator.defaultPath()
        let configPath = try ConfigStore.defaultPath()
        let store = try SQLiteStore(path: db)
        let configStore = ConfigStore(path: configPath)
        let orchestrator = AgentmuxOrchestrator(store: store, configStore: configStore)

        _ = try orchestrator.syncConfig()

        switch command {
        case "config":
            try runConfigSubcommand(orchestrator: orchestrator, path: configPath)
        case "settings":
            try runSettingsSubcommand(orchestrator: orchestrator)
        case "project":
            try runProjectSubcommand(orchestrator: orchestrator)
        case "workspace":
            try runWorkspaceSubcommand(orchestrator: orchestrator)
        default:
            printHelp()
        }
    }

    private func runConfigSubcommand(orchestrator: AgentmuxOrchestrator, path: String) throws {
        guard args.count >= 3 else {
            throw NSError(
                domain: "agentmux.cli", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Missing config action. Use: config path|show"])
        }
        switch args[2] {
        case "path":
            print(path)
        case "show":
            let config = try ConfigStore(path: path).load()
            print(
                "editor=\(config.editor?.rawValue ?? "none") port_range=\(config.portRange.start)-\(config.portRange.end) projects=\(config.projects.count)"
            )
        default:
            throw NSError(
                domain: "agentmux.cli", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unknown config action: \(args[2])"])
        }
    }

    private func runProjectSubcommand(orchestrator: AgentmuxOrchestrator) throws {
        guard args.count >= 3 else {
            throw NSError(
                domain: "agentmux.cli", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Missing project action. Use: project list|add|update|remove"])
        }

        switch args[2] {
        case "list":
            let projects = try orchestrator.listProjects()
            for project in projects {
                print(
                    "\(project.name)\t\(project.dir)\tgit=\(project.isGitRepo ? "yes" : "no")\tdefault_branch=\(project.defaultBranch ?? "-")"
                )
            }
        case "add":
            let dir = optionalValue(for: "--dir")
            let gitURL = optionalValue(for: "--git-url")
            if dir != nil, gitURL != nil {
                throw NSError(
                    domain: "agentmux.cli", code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Use either --dir <path> or --git-url <url>, but not both."
                    ])
            }
            let record: ProjectRecord
            if let gitURL {
                record = try orchestrator.addProject(gitURL: gitURL)
            } else if let dir {
                record = try orchestrator.addProject(dir: dir)
            } else {
                throw NSError(
                    domain: "agentmux.cli", code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Missing required flags. Use: project add --dir <path> or project add --git-url <url>"
                    ])
            }
            print("Added project \(record.name)\t\(record.dir)")
        case "update":
            let dir = try value(for: "--dir")
            let setupScript = optionalValue(for: "--setup-script")
            let cleanupScript = optionalValue(for: "--cleanup-script")
            guard var config = try orchestrator.projectConfig(projectID: normalizePath(dir)) else {
                throw NSError(
                    domain: "agentmux.cli", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Project not found for dir \(dir)"])
            }
            if let setupScript {
                config.setupScript = setupScript
            }
            if let cleanupScript {
                config.cleanupScript = cleanupScript
            }
            try orchestrator.updateProjectConfig(config)
            print("Updated project \(dir)")
        case "remove":
            let dir = try value(for: "--dir")
            try orchestrator.removeProject(dir: dir)
            print("Removed project \(dir)")
        default:
            throw NSError(
                domain: "agentmux.cli", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unknown project action: \(args[2])"])
        }
    }

    private func runWorkspaceSubcommand(orchestrator: AgentmuxOrchestrator) throws {
        guard args.count >= 3 else {
            throw NSError(
                domain: "agentmux.cli", code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Missing workspace action. Use: workspace list|create|launch|restart|stop|archive|activate"
                ])
        }
        switch args[2] {
        case "list":
            let projectDir = try value(for: "--project-dir")
            let projectID = normalizePath(projectDir)
            let workspaces = try orchestrator.listWorkspaces(
                projectID: projectID, includeArchived: args.contains("--all"))
            for ws in workspaces {
                let flags = [
                    ws.isDefault ? "default" : nil,
                    ws.isRunning ? "running" : nil,
                    ws.isArchived ? "archived" : nil,
                ].compactMap { $0 }.joined(separator: ",")
                print("\(ws.name)\t\(ws.dir)\t\(flags)")
            }
        case "create":
            let projectDir = try value(for: "--project-dir")
            let name = try value(for: "--name")
            let branch = optionalValue(for: "--branch")
            let targetBranch = optionalValue(for: "--target-branch")
            let projectID = normalizePath(projectDir)
            let workspace = try orchestrator.createWorkspace(
                projectID: projectID,
                name: name,
                branch: branch,
                targetBranch: targetBranch
            )
            print("Created workspace \(workspace.name)\t\(workspace.dir)")
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
        default:
            throw NSError(
                domain: "agentmux.cli", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unknown workspace action: \(args[2])"])
        }
    }

    private func workspaceID(orchestrator: AgentmuxOrchestrator) throws -> String {
        let projectDir = try value(for: "--project-dir")
        let name = try value(for: "--name")
        let projectID = normalizePath(projectDir)
        guard
            let workspace = try orchestrator.listWorkspaces(projectID: projectID, includeArchived: true).first(where: {
                $0.name == name
            })
        else {
            throw NSError(
                domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Workspace not found: \(name)"])
        }
        return workspace.id
    }

    private func runSettingsSubcommand(orchestrator: AgentmuxOrchestrator) throws {
        guard args.count >= 3 else {
            throw NSError(
                domain: "agentmux.cli", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Missing settings action. Use: settings get|set|reset"])
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
                    domain: "agentmux.cli",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Missing setting flag. Use: settings get --gui-hotkey|--gui-next-shortcut|--gui-prev-shortcut|--gui-show-shortcut|--gui-add-project-shortcut|--gui-add-workspace-shortcut|--gui-reload-shortcut|--gui-open-editor-shortcut|--gui-open-terminal-shortcut|--gui-open-finder-shortcut|--gui-open-settings-shortcut"
                    ]
                )
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
                    domain: "agentmux.cli",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Missing setting flag/value. Use: settings set --gui-hotkey|--gui-next-shortcut|--gui-prev-shortcut|--gui-show-shortcut|--gui-add-project-shortcut|--gui-add-workspace-shortcut|--gui-reload-shortcut|--gui-open-editor-shortcut|--gui-open-terminal-shortcut|--gui-open-finder-shortcut|--gui-open-settings-shortcut <spec>"
                    ]
                )
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
                    domain: "agentmux.cli",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Missing setting flag. Use: settings reset --gui-hotkey|--gui-next-shortcut|--gui-prev-shortcut|--gui-show-shortcut|--gui-add-project-shortcut|--gui-add-workspace-shortcut|--gui-reload-shortcut|--gui-open-editor-shortcut|--gui-open-terminal-shortcut|--gui-open-finder-shortcut|--gui-open-settings-shortcut"
                    ]
                )
            }

        default:
            throw NSError(
                domain: "agentmux.cli", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Unknown settings action: \(args[2])"])
        }
    }

    private func value(for flag: String) throws -> String {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else {
            throw NSError(
                domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing required flag \(flag)"])
        }
        return args[idx + 1]
    }

    private func optionalValue(for flag: String) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else {
            return nil
        }
        return args[idx + 1]
    }

    private func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func printHelp() {
        print(
            """
            agentmux command line

            Usage:
              agentmux config path
              agentmux config show

              agentmux settings get --gui-hotkey
              agentmux settings get --gui-next-shortcut
              agentmux settings get --gui-prev-shortcut
              agentmux settings get --gui-show-shortcut
              agentmux settings get --gui-add-project-shortcut
              agentmux settings get --gui-add-workspace-shortcut
              agentmux settings get --gui-reload-shortcut
              agentmux settings get --gui-open-editor-shortcut
              agentmux settings get --gui-open-terminal-shortcut
              agentmux settings get --gui-open-finder-shortcut
              agentmux settings get --gui-open-settings-shortcut
              agentmux settings set --gui-hotkey <spec>
              agentmux settings set --gui-next-shortcut <spec>
              agentmux settings set --gui-prev-shortcut <spec>
              agentmux settings set --gui-show-shortcut <spec>
              agentmux settings set --gui-add-project-shortcut <spec>
              agentmux settings set --gui-add-workspace-shortcut <spec>
              agentmux settings set --gui-reload-shortcut <spec>
              agentmux settings set --gui-open-editor-shortcut <spec>
              agentmux settings set --gui-open-terminal-shortcut <spec>
              agentmux settings set --gui-open-finder-shortcut <spec>
              agentmux settings set --gui-open-settings-shortcut <spec>
              agentmux settings reset --gui-hotkey
              agentmux settings reset --gui-next-shortcut
              agentmux settings reset --gui-prev-shortcut
              agentmux settings reset --gui-show-shortcut
              agentmux settings reset --gui-add-project-shortcut
              agentmux settings reset --gui-add-workspace-shortcut
              agentmux settings reset --gui-reload-shortcut
              agentmux settings reset --gui-open-editor-shortcut
              agentmux settings reset --gui-open-terminal-shortcut
              agentmux settings reset --gui-open-finder-shortcut
              agentmux settings reset --gui-open-settings-shortcut

              agentmux project list
              agentmux project add --dir <path>
              agentmux project add --git-url <url>
              agentmux project update --dir <path> [--setup-script <script>] [--cleanup-script <script>]
              agentmux project remove --dir <path>

              agentmux workspace list --project-dir <path> [--all]
              agentmux workspace create --project-dir <path> --name <name> [--branch <branch>] [--target-branch <branch>]
              agentmux workspace launch --project-dir <path> --name <name>
              agentmux workspace restart --project-dir <path> --name <name>
              agentmux workspace stop --project-dir <path> --name <name>
              agentmux workspace archive --project-dir <path> --name <name>
              agentmux workspace activate --project-dir <path> --name <name>

            Notes:
              - Configuration is stored in ~/.agentmux/config.yaml (YAML is source of truth).
              - GUI settings (⌘,) let you pick a preferred editor (VS Code, Cursor, Windsurf).
              - Runtime state is stored in ~/.agentmux/agentmux.db and rebuilt if schema changes.
              - Removing a git project deletes related workspace directories under ~/agentmux/workspaces.
              - Removing a project deletes only agentmux state unless it is an agentmux-cloned git repo under ~/agentmux/projects; those managed project directories are deleted.
              - Workspaces snapshot project processes, status checks, and browser sessions into the runtime DB on creation.
              - For git projects, `workspace create` requires `--branch`; `--target-branch` defaults to main/master if available.
              - Archiving a non-git workspace never deletes the project directory.
              - Workspaces reserve PORT0-PORT9 from the configured port range.
              - GUI window focus shortcuts: cmd+1 through cmd+9 (when GUI is focused).
              - GUI window cycle shortcuts: cmd+shift+[ and cmd+shift+] (global, when GUI is not focused).
              - GUI action shortcuts can be overridden in Settings or via `agentmux settings set ...`.
            """)
    }
}

do {
    try CLI(args: CommandLine.arguments).run()
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
