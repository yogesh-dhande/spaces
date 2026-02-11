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
            let dir = try value(for: "--dir")
            let record = try orchestrator.addProject(dir: dir)
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
                        "Missing workspace action. Use: workspace list|create|launch|stop|archive|activate"
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
            let projectID = normalizePath(projectDir)
            let workspace = try orchestrator.createWorkspace(projectID: projectID, name: name)
            print("Created workspace \(workspace.name)\t\(workspace.dir)")
        case "launch":
            let id = try workspaceID(orchestrator: orchestrator)
            try orchestrator.launchWorkspace(workspaceID: id)
            print("Launched workspace \(id)")
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
            } else {
                throw NSError(
                    domain: "agentmux.cli",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Missing setting flag. Use: settings get --gui-hotkey|--gui-next-shortcut|--gui-prev-shortcut|--gui-show-shortcut"
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
            } else {
                throw NSError(
                    domain: "agentmux.cli",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Missing setting flag/value. Use: settings set --gui-hotkey|--gui-next-shortcut|--gui-prev-shortcut|--gui-show-shortcut <spec>"
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
            } else {
                throw NSError(
                    domain: "agentmux.cli",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Missing setting flag. Use: settings reset --gui-hotkey|--gui-next-shortcut|--gui-prev-shortcut|--gui-show-shortcut"
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
              agentmux settings set --gui-hotkey <spec>
              agentmux settings set --gui-next-shortcut <spec>
              agentmux settings set --gui-prev-shortcut <spec>
              agentmux settings set --gui-show-shortcut <spec>
              agentmux settings reset --gui-hotkey
              agentmux settings reset --gui-next-shortcut
              agentmux settings reset --gui-prev-shortcut
              agentmux settings reset --gui-show-shortcut

              agentmux project list
              agentmux project add --dir <path>
              agentmux project update --dir <path> [--setup-script <script>] [--cleanup-script <script>]
              agentmux project remove --dir <path>

              agentmux workspace list --project-dir <path> [--all]
              agentmux workspace create --project-dir <path> --name <name>
              agentmux workspace launch --project-dir <path> --name <name>
              agentmux workspace stop --project-dir <path> --name <name>
              agentmux workspace archive --project-dir <path> --name <name>
              agentmux workspace activate --project-dir <path> --name <name>

            Notes:
              - Configuration is stored in ~/.agentmux/config.yaml (YAML is source of truth).
              - Runtime state is stored in ~/.agentmux/agentmux.db and rebuilt if schema changes.
              - Workspaces snapshot project processes, status checks, and browser sessions into the runtime DB on creation.
              - Workspaces reserve PORT0-PORT9 from the configured port range.
              - GUI window focus shortcuts: cmd+shift+1 through cmd+shift+9 (when GUI is focused).
              - GUI window cycle shortcuts: cmd+shift+[ and cmd+shift+] (global, when GUI is not focused).
            """)
    }
}

do {
    try CLI(args: CommandLine.arguments).run()
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
