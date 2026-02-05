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
                print("\(stream.projectName)\t\(stream.streamName)\t\(stream.activatedAt)\t\(stream.worktreePath)\tdisplay=\(stream.displayIndex)\tspace=\(stream.spaceIndex)")
            }

        case "doctor":
            let project = optionalValue(for: "--project")
            let stream = optionalValue(for: "--stream")
            let reports = try orchestrator.doctor(projectName: project, streamName: stream)
            if reports.isEmpty {
                print("No streams found.")
            }
            for report in reports {
                print("\(report.projectName)\t\(report.streamName)\twindows=\(report.windowsFound)/\(report.windowsExpected)\tspace=\(report.spaceIndex)\tdisplay=\(report.displayIndex)")
                if !report.yabaiAvailable {
                    print("  diagnostic: yabai not available. Install and start yabai, then retry.")
                }
                if !report.missingWindowIDs.isEmpty {
                    let list = report.missingWindowIDs.map(String.init).joined(separator: ",")
                    print("  missing_window_ids=\(list)")
                }
            }

        default:
            printHelp()
        }
    }

    private func runProjectSubcommand(orchestrator: StreamOrchestrator) throws {
        guard args.count >= 3 else {
            throw NSError(domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing project action. Use: project create|update|delete|list"])
        }

        switch args[2] {
        case "list":
            let projects = try orchestrator.listProjects()
            for project in projects {
                print("\(project.name)\t\(project.repoRoot)")
            }

        case "create":
            let name = try value(for: "--name")
            let repoRoot = try value(for: "--repo-root")
            let created = try orchestrator.createProject(name: name, repoRoot: repoRoot)
            print("Created project \(created.name)\t\(created.repoRoot)")

        case "update":
            let name = try value(for: "--name")
            let updated = try orchestrator.updateProject(
                name: name,
                repoRoot: optionalValue(for: "--repo-root")
            )
            print("Updated project \(updated.name)")

        case "delete":
            let name = try value(for: "--name")
            try orchestrator.deleteProject(name: name)
            print("Deleted project \(name)")

        default:
            throw NSError(domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown project action: \(args[2])"])
        }
    }

    private func runStreamSubcommand(orchestrator: StreamOrchestrator) throws {
        guard args.count >= 3 else {
            throw NSError(domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing stream action. Use: stream create|update|destroy|list|capture"])
        }

        switch args[2] {
        case "create":
            let project = try value(for: "--project")
            let stream = try value(for: "--stream")
            let worktreePath = optionalValue(for: "--worktree")
            let display = try requiredIntValue(for: "--display")
            let space = try requiredIntValue(for: "--space")
            let created = try orchestrator.create(projectName: project, streamName: stream, worktreePath: worktreePath, displayIndex: display, spaceIndex: space)
            print("Created stream \(created.name)\t\(created.worktreePath)\tdisplay=\(created.displayIndex)\tspace=\(created.spaceIndex)")

        case "update":
            let project = try value(for: "--project")
            let stream = try value(for: "--stream")
            let updated = try orchestrator.updateStream(
                projectName: project,
                streamName: stream,
                displayIndex: intValue(for: "--display"),
                spaceIndex: intValue(for: "--space")
            )
            print("Updated stream \(updated.name)\tdisplay=\(updated.displayIndex)\tspace=\(updated.spaceIndex)")

        case "capture":
            let project = try value(for: "--project")
            let stream = try value(for: "--stream")
            try orchestrator.capture(projectName: project, streamName: stream)
            print("Captured windows for \(project)/\(stream)")

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
                print("\(marker)\t\(stream.name)\t\(stream.worktreePath)\tdisplay=\(stream.displayIndex)\tspace=\(stream.spaceIndex)")
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
          agentmux project create --name <name> --repo-root <path>
          agentmux project update --name <name> [--repo-root <path>]
          agentmux project delete --name <name>

          agentmux stream list --project <name>
          agentmux stream create --project <name> --stream <name> --display <n> --space <n> [--worktree <path>]
          agentmux stream update --project <name> --stream <name> [--display <n>] [--space <n>]
          agentmux stream capture --project <name> --stream <name>
          agentmux stream destroy --project <name> --stream <name> [--remove-branch]

          agentmux show --project <name> --stream <name>
          agentmux hide --project <name> --stream <name>
          agentmux focus --project <name> --stream <name>
          agentmux list-active
          agentmux doctor [--project <name>] [--stream <name>]

        Notes:
          - `show` focuses captured windows; if none can be focused, close/reopen the target app windows and re-run `stream capture`.

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
