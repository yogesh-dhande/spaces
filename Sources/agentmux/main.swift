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
                print("\(report.projectName)\t\(report.streamName)\twindows:\(report.foundWindowCount)/\(report.expectedWindowCount)")
                let missing = report.missingWindows.isEmpty ? "-" : report.missingWindows.joined(separator: ",")
                print("  missing=\(missing) updated=\(report.identityUpdatedAt ?? "-")")
            }

        default:
            printHelp()
        }
    }

    private func runProjectSubcommand(orchestrator: StreamOrchestrator) throws {
        guard args.count >= 3 else {
            throw NSError(domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing project action. Use: project create|update|delete|list|window"])
        }

        switch args[2] {
        case "list":
            let projects = try orchestrator.listProjects()
            for project in projects {
                print("\(project.name)\t\(project.repoRoot)\twindows=\(project.windows.count)\teditor=\(project.defaultEditor.rawValue)\tbrowser=\(project.defaultBrowser.rawValue)\tterminal=\(project.defaultTerminal.rawValue)")
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

        case "window":
            try runProjectWindowSubcommand(orchestrator: orchestrator)

        default:
            throw NSError(domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown project action: \(args[2])"])
        }
    }

    private func runProjectWindowSubcommand(orchestrator: StreamOrchestrator) throws {
        guard args.count >= 4 else {
            throw NSError(domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing project window action. Use: project window list|add|update|remove"])
        }
        switch args[3] {
        case "list":
            let project = try value(for: "--project")
            let windows = try orchestrator.listProjectWindows(projectName: project)
            for (index, spec) in windows.enumerated() {
                let urls = spec.urls.joined(separator: ",")
                print("\(index)\tname=\(spec.name)\tkind=\(spec.kind.rawValue)\tbundle=\(spec.bundleID)\tdisplay=\(spec.layout.displayIndex)\ttile=\(spec.layout.tile.rawValue)\tmatch=\(spec.matchTitle ?? "")\teditor=\(spec.editorKind ?? "")\tcmd=\(spec.command ?? spec.launchCommand ?? "")\turls=\(urls)")
            }
        case "add":
            let project = try value(for: "--project")
            let name = try value(for: "--name")
            let kind = try value(for: "--kind")
            let bundleID = try value(for: "--bundle-id")
            let display = try requiredIntValue(for: "--display")
            let tile = try value(for: "--tile")
            let updated = try orchestrator.addProjectWindow(
                projectName: project,
                name: name,
                kind: kind,
                bundleID: bundleID,
                displayIndex: display,
                tile: tile,
                launchCommand: optionalValue(for: "--launch-command"),
                command: optionalValue(for: "--command"),
                urls: csvList(for: "--urls"),
                matchTitle: optionalValue(for: "--match-title"),
                editorKind: optionalValue(for: "--editor-kind")
            )
            print("Added window spec. count=\(updated.windows.count)")
        case "update":
            let project = try value(for: "--project")
            let index = try requiredIntValue(for: "--index")
            let urls = args.contains("--urls") ? csvList(for: "--urls") : nil
            let updated = try orchestrator.updateProjectWindow(
                projectName: project,
                index: index,
                name: optionalValue(for: "--name"),
                kind: optionalValue(for: "--kind"),
                bundleID: optionalValue(for: "--bundle-id"),
                displayIndex: intValue(for: "--display"),
                tile: optionalValue(for: "--tile"),
                launchCommand: optionalValue(for: "--launch-command"),
                command: optionalValue(for: "--command"),
                urls: urls,
                matchTitle: optionalValue(for: "--match-title"),
                editorKind: optionalValue(for: "--editor-kind")
            )
            print("Updated window spec at index \(index). count=\(updated.windows.count)")
        case "remove":
            let project = try value(for: "--project")
            let index = try requiredIntValue(for: "--index")
            let updated = try orchestrator.removeProjectWindow(projectName: project, index: index)
            print("Removed window spec at index \(index). count=\(updated.windows.count)")
        default:
            throw NSError(domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown project window action: \(args[3])"])
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
          agentmux project window list --project <name>
          agentmux project window add --project <name> --name <name> --kind <editor|browser|terminal|custom> --bundle-id <id> --display <n> --tile <tile> [--editor-kind <windsurf|vscode|cursor>] [--urls <u1,u2,...>] [--command <shell>] [--launch-command <shell>] [--match-title <title>]
          agentmux project window update --project <name> --index <n> [--name <name>] [--kind <...>] [--bundle-id <id>] [--display <n>] [--tile <tile>] [--editor-kind <...>] [--urls <u1,u2,...>] [--command <shell>] [--launch-command <shell>] [--match-title <title>]
          agentmux project window remove --project <name> --index <n>

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
