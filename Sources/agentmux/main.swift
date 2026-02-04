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
        let db = try databasePath()
        let store = try SQLiteStore(path: db)
        let orchestrator = StreamOrchestrator(store: store)

        switch command {
        case "seed-json":
            let file = try value(for: "--file")
            try SeedLoader.importJSON(filePath: file, store: store)
            print("Imported seed data into \(db)")

        case "project":
            try runProjectSubcommand(orchestrator: orchestrator)

        case "stream":
            try runStreamSubcommand(orchestrator: orchestrator)

        case "show":
            let project = try value(for: "--project")
            let stream = try value(for: "--stream")
            try orchestrator.show(projectName: project, streamName: stream)

        case "hide":
            let project = try value(for: "--project")
            let stream = try value(for: "--stream")
            try orchestrator.hide(projectName: project, streamName: stream)

        case "focus":
            let project = try value(for: "--project")
            let stream = try value(for: "--stream")
            try orchestrator.focus(projectName: project, streamName: stream)

        case "list-active":
            let active = try orchestrator.listActive()
            for stream in active {
                print("\(stream.projectName)\t\(stream.streamName)\t\(stream.activatedAt)\t\(stream.worktreePath)")
            }

        case "doctor":
            let project = optionalValue(for: "--project")
            let stream = optionalValue(for: "--stream")
            let reports = try orchestrator.doctor(projectName: project, streamName: stream)
            if reports.isEmpty {
                print("No streams found.")
            }
            for report in reports {
                let editor = report.editorWindowFound ? "ok" : "missing"
                let chrome = report.chromeWindowFound ? "ok" : "missing"
                let terminal = "\(report.terminalWindowCount)/\(report.expectedTerminalWindowCount)"
                print("\(report.projectName)\t\(report.streamName)\teditor:\(editor)\tchrome:\(chrome)\tterminal:\(terminal)")
                print("  identity editor=\(report.editorMatchTitle ?? "-") chrome=\(report.chromeAnchorURL ?? "-") terminal=\(report.terminalTitlePrefix ?? "-") updated=\(report.identityUpdatedAt ?? "-")")
            }

        default:
            printHelp()
        }
    }

    private func runProjectSubcommand(orchestrator: StreamOrchestrator) throws {
        guard args.count >= 3 else {
            throw NSError(domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing project action. Use: project create|update|delete|list|terminal"])
        }

        switch args[2] {
        case "list":
            let projects = try orchestrator.listProjects()
            for project in projects {
                print("\(project.name)\t\(project.repoRoot)\teditor=\(project.defaultEditor.rawValue)\tbrowser=\(project.defaultBrowser.rawValue)\tterminal=\(project.defaultTerminal.rawValue)")
            }

        case "create":
            let name = try value(for: "--name")
            let repoRoot = try value(for: "--repo-root")
            let browserTabs = csvList(for: "--browser-tabs")
            let created = try orchestrator.createProject(
                name: name,
                repoRoot: repoRoot,
                editor: optionalValue(for: "--editor"),
                browser: optionalValue(for: "--browser"),
                terminal: optionalValue(for: "--terminal"),
                editorDisplay: intValue(for: "--editor-display"),
                editorTile: optionalValue(for: "--editor-tile"),
                browserDisplay: intValue(for: "--browser-display"),
                browserTile: optionalValue(for: "--browser-tile"),
                browserTabs: browserTabs
            )
            print("Created project \(created.name)\t\(created.repoRoot)")

        case "update":
            let name = try value(for: "--name")
            let tabsFlagPresent = args.contains("--browser-tabs")
            let updated = try orchestrator.updateProject(
                name: name,
                repoRoot: optionalValue(for: "--repo-root"),
                editor: optionalValue(for: "--editor"),
                browser: optionalValue(for: "--browser"),
                terminal: optionalValue(for: "--terminal"),
                editorDisplay: intValue(for: "--editor-display"),
                editorTile: optionalValue(for: "--editor-tile"),
                browserDisplay: intValue(for: "--browser-display"),
                browserTile: optionalValue(for: "--browser-tile"),
                browserTabs: tabsFlagPresent ? csvList(for: "--browser-tabs") : nil
            )
            print("Updated project \(updated.name)")

        case "delete":
            let name = try value(for: "--name")
            try orchestrator.deleteProject(name: name)
            print("Deleted project \(name)")

        case "terminal":
            try runProjectTerminalSubcommand(orchestrator: orchestrator)

        default:
            throw NSError(domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown project action: \(args[2])"])
        }
    }

    private func runProjectTerminalSubcommand(orchestrator: StreamOrchestrator) throws {
        guard args.count >= 4 else {
            throw NSError(domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing project terminal action. Use: project terminal list|add|update|remove"])
        }

        switch args[3] {
        case "list":
            let project = try value(for: "--project")
            let terminals = try orchestrator.listProjectTerminals(projectName: project)
            for (index, terminal) in terminals.enumerated() {
                print("\(index)\tdisplay=\(terminal.layout.displayIndex)\ttile=\(terminal.layout.tile.rawValue)\tcommand=\(terminal.command ?? "")")
            }

        case "add":
            let project = try value(for: "--project")
            let display = try requiredIntValue(for: "--display")
            let tile = try value(for: "--tile")
            let command = optionalValue(for: "--command")
            let updated = try orchestrator.addProjectTerminal(
                projectName: project,
                displayIndex: display,
                tile: tile,
                command: command
            )
            print("Added terminal spec. count=\(updated.terminals.count)")

        case "update":
            let project = try value(for: "--project")
            let index = try requiredIntValue(for: "--index")
            let display = intValue(for: "--display")
            let tile = optionalValue(for: "--tile")
            let command = optionalValue(for: "--command")
            let updated = try orchestrator.updateProjectTerminal(
                projectName: project,
                index: index,
                displayIndex: display,
                tile: tile,
                command: command
            )
            print("Updated terminal spec at index \(index). count=\(updated.terminals.count)")

        case "remove":
            let project = try value(for: "--project")
            let index = try requiredIntValue(for: "--index")
            let updated = try orchestrator.removeProjectTerminal(projectName: project, index: index)
            print("Removed terminal spec at index \(index). count=\(updated.terminals.count)")

        default:
            throw NSError(domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown project terminal action: \(args[3])"])
        }
    }

    private func runStreamSubcommand(orchestrator: StreamOrchestrator) throws {
        guard args.count >= 3 else {
            throw NSError(domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing stream action. Use: stream create|destroy|list"])
        }

        switch args[2] {
        case "create":
            let project = try value(for: "--project")
            let stream = try value(for: "--stream")
            let worktreePath = optionalValue(for: "--worktree")
            let created = try orchestrator.create(projectName: project, streamName: stream, worktreePath: worktreePath)
            print("Created stream \(created.name)\t\(created.worktreePath)")

        case "destroy":
            let project = try value(for: "--project")
            let stream = try value(for: "--stream")
            let removeBranch = args.contains("--remove-branch")
            try orchestrator.destroy(projectName: project, streamName: stream, removeBranch: removeBranch)
            print("Destroyed stream \(stream)")

        case "list":
            let project = try value(for: "--project")
            let streams = try orchestrator.list(projectName: project)
            for stream in streams {
                let marker = stream.isActive ? "*" : " "
                print("\(marker)\t\(stream.name)\t\(stream.worktreePath)")
            }

        default:
            throw NSError(domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown stream action: \(args[2])"])
        }
    }

    private func value(for flag: String) throws -> String {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else {
            throw NSError(domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing required flag \(flag)"])
        }
        return args[idx + 1]
    }

    private func optionalValue(for flag: String) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else {
            return nil
        }
        return args[idx + 1]
    }

    private func intValue(for flag: String) -> Int? {
        guard let raw = optionalValue(for: flag) else {
            return nil
        }
        return Int(raw)
    }

    private func requiredIntValue(for flag: String) throws -> Int {
        guard let raw = optionalValue(for: flag), let value = Int(raw) else {
            throw NSError(domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing or invalid integer flag \(flag)"])
        }
        return value
    }

    private func csvList(for flag: String) -> [String] {
        guard let raw = optionalValue(for: flag) else {
            return []
        }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func databasePath() throws -> String {
        if let override = optionalValue(for: "--db"), !override.isEmpty {
            return override
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".agentmux", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("agentmux.db").path
    }

    private func printHelp() {
        print("""
        agentmux command line

        Usage:
          agentmux seed-json --file <seed.json>

          agentmux project list
          agentmux project create --name <name> --repo-root <path> [--editor windsurf|vscode|cursor] [--browser chrome] [--terminal terminal] [--editor-display <n>] [--editor-tile <tile>] [--browser-display <n>] [--browser-tile <tile>] [--browser-tabs <u1,u2,...>]
          agentmux project update --name <name> [--repo-root <path>] [--editor windsurf|vscode|cursor] [--browser chrome] [--terminal terminal] [--editor-display <n>] [--editor-tile <tile>] [--browser-display <n>] [--browser-tile <tile>] [--browser-tabs <u1,u2,...>]
          agentmux project delete --name <name>
          agentmux project terminal list --project <name>
          agentmux project terminal add --project <name> --display <n> --tile <tile> [--command <shell>]
          agentmux project terminal update --project <name> --index <n> [--display <n>] [--tile <tile>] [--command <shell>]
          agentmux project terminal remove --project <name> --index <n>

          agentmux stream list --project <name>
          agentmux stream create --project <name> --stream <name> [--worktree <path>]
          agentmux stream destroy --project <name> --stream <name> [--remove-branch]

          agentmux show --project <name> --stream <name>
          agentmux hide --project <name> --stream <name>
          agentmux focus --project <name> --stream <name>
          agentmux list-active
          agentmux doctor [--project <name>] [--stream <name>]

        Optional:
          --db <path> overrides default database path (~/.agentmux/agentmux.db)
        """)
    }
}

do {
    try CLI(args: CommandLine.arguments).run()
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
