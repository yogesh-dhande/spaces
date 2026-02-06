import Foundation
import appctl
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

        case "wrap":
            let exitCode = try runWrapCommand(store: store, dbPath: db)
            exit(exitCode)

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

    private func runWrapCommand(store: SQLiteStore, dbPath: String) throws -> Int32 {
        let projectName = optionalValue(for: "--project")
        let streamName = optionalValue(for: "--stream")
        if (projectName != nil) != (streamName != nil) {
            throw NSError(domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Both --project and --stream are required when specifying a target stream."])
        }
        let command = try commandAfterDoubleDash()
        if let projectName, let streamName {
            guard let project = try store.project(named: projectName) else {
                throw NSError(domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown project: \(projectName)"])
            }
            guard let _ = try store.stream(projectID: project.id, name: streamName) else {
                throw NSError(domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown stream: \(projectName)/\(streamName)"])
            }
        }

        let yabai = YabaiAdapter()
        guard let focused = try yabai.focusedWindow() else {
            throw NSError(domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "No focused window found via yabai. Focus the target terminal window and retry."])
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmux-wrap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let env = ProcessInfo.processInfo.environment
        let inactivityThreshold = Double(env["INACTIVITY_THRESHOLD"] ?? "") ?? 2.0
        let pollInterval = Double(env["POLL_INTERVAL"] ?? "") ?? 0.25

        let resolver = StreamResolver(
            dbPath: dbPath,
            preferredProject: projectName,
            preferredStream: streamName
        )

        let mapping = try resolver.resolve(windowID: focused.id)
        if let mapping {
            let statusFile = statusFileURL(for: mapping, windowID: focused.id)
            let statusDir = statusFile.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: statusDir, withIntermediateDirectories: true)

            if ProcessInfo.processInfo.environment["AGENTMUX_WRAP_DEBUG"] == "1" {
                fputs("wrap: mapped project=\(mapping.project.name) stream=\(mapping.stream.name) worktree=\(mapping.stream.worktreePath)\n", stderr)
                fputs("wrap: focused_window_id \(focused.id)\n", stderr)
            }

            try writeStatusSeed(path: statusFile.path)

            return try runAgentWrap(
                command: command,
                statusFile: statusFile,
                inactivityThreshold: inactivityThreshold,
                pollInterval: pollInterval,
                debug: ProcessInfo.processInfo.environment["AGENTMUX_WRAP_DEBUG"] == "1"
            )
        } else {
            fputs("wrap: no captured stream found for focused window; running without status.\n", stderr)
            return try runDirect(command: command, debug: ProcessInfo.processInfo.environment["AGENTMUX_WRAP_DEBUG"] == "1")
        }
    }

    private func commandAfterDoubleDash() throws -> [String] {
        if let idx = args.firstIndex(of: "--"), idx + 1 < args.count {
            let command = Array(args[(idx + 1)...])
            guard !command.isEmpty else {
                throw NSError(domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing command. Use: wrap [--project <name> --stream <name>] -- <command> [args...]"])
            }
            return command
        }

        if args.contains("--project") || args.contains("--stream") {
            throw NSError(domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing -- delimiter. Use: wrap [--project <name> --stream <name>] -- <command> [args...]"])
        }

        guard args.count >= 3 else {
            throw NSError(domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing command. Use: wrap [--project <name> --stream <name>] <command> [args...]"])
        }
        let command = Array(args[2...])
        guard !command.isEmpty else {
            throw NSError(domain: "agentmux.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing command. Use: wrap [--project <name> --stream <name>] <command> [args...]"])
        }
        return command
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
            fputs("Warning: --db is for internal/testing use. The database location is managed automatically.\n", stderr)
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
          agentmux list-active
          agentmux doctor [--project <name>] [--stream <name>]
          agentmux wrap [--project <name> --stream <name>] -- <command> [args...]
          agentmux wrap [--project <name> --stream <name>] <command> [args...]

        Notes:
          - `show` captures current space windows before focusing; if none can be focused, close/reopen the target app windows and re-run `show`.
          - `wrap` runs a command under a PTY and writes status to <worktree>/.agentmux/status/window-<id>.json once the focused window is captured.
          - Database state is stored at ~/.agentmux/agentmux.db and is managed automatically.
        """)
    }
}

private struct StreamMapping {
    let project: Project
    let stream: streamctl.Stream
}

private final class StreamResolver {
    private let store: SQLiteStore
    private let preferredProject: String?
    private let preferredStream: String?

    init(dbPath: String, preferredProject: String?, preferredStream: String?) {
        self.store = (try? SQLiteStore(path: dbPath)) ?? {
            fatalError("Failed to open SQLite store at \(dbPath)")
        }()
        self.preferredProject = preferredProject
        self.preferredStream = preferredStream
    }

    func resolve(windowID: Int) throws -> StreamMapping? {
        if let preferredProject, let preferredStream {
            guard let project = try store.project(named: preferredProject) else {
                throw NSError(domain: "agentmux.wrap", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown project: \(preferredProject)"])
            }
            guard let stream = try store.stream(projectID: project.id, name: preferredStream) else {
                throw NSError(domain: "agentmux.wrap", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unknown stream: \(preferredProject)/\(preferredStream)"])
            }
            if let identity = try store.windowIdentity(streamID: stream.id),
               identity.windows.contains(where: { $0.id == windowID }) {
                return StreamMapping(project: project, stream: stream)
            }
            return nil
        }

        let projects = try store.projects()
        var matches: [StreamMapping] = []
        for project in projects {
            let streams = try store.fullStreams(projectID: project.id)
            for stream in streams {
                guard let identity = try store.windowIdentity(streamID: stream.id) else { continue }
                if identity.windows.contains(where: { $0.id == windowID }) {
                    matches.append(StreamMapping(project: project, stream: stream))
                }
            }
        }

        if matches.count > 1 {
            throw NSError(domain: "agentmux.wrap", code: 2, userInfo: [NSLocalizedDescriptionKey: "Focused window matches multiple streams. Use --project/--stream to disambiguate."])
        }
        return matches.first
    }
}

private func statusFileURL(for mapping: StreamMapping, windowID: Int) -> URL {
    let worktreeURL = URL(fileURLWithPath: mapping.stream.worktreePath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .standardizedFileURL
    let statusDir = worktreeURL
        .appendingPathComponent(".agentmux", isDirectory: true)
        .appendingPathComponent("status", isDirectory: true)
    return statusDir.appendingPathComponent("window-\(windowID).json")
}

private func runAgentWrap(
    command: [String],
    statusFile: URL,
    inactivityThreshold: Double,
    pollInterval: Double,
    debug: Bool
) throws -> Int32 {
    let cwd = FileManager.default.currentDirectoryPath
    let scriptFile = URL(fileURLWithPath: cwd).appendingPathComponent("prototypes/agentwrap.sh")
    guard FileManager.default.fileExists(atPath: scriptFile.path) else {
        throw NSError(domain: "agentmux.wrap", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing prototypes/agentwrap.sh."])
    }

    let absoluteStatus = URL(fileURLWithPath: statusFile.path, relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL
    let statusDir = absoluteStatus.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: statusDir, withIntermediateDirectories: true)
    setenv("STATUS_FILE", absoluteStatus.path, 1)
    setenv("INACTIVITY_THRESHOLD", String(Int(inactivityThreshold)), 1)
    let pollMicros = max(1, Int(pollInterval * 1_000_000))
    setenv("POLL_INTERVAL", String(Double(pollMicros) / 1_000_000), 1)

    if debug {
        fputs("wrap: exec \(scriptFile.path) " + command.joined(separator: " ") + "\n", stderr)
        fputs("wrap: status_file \(absoluteStatus.path)\n", stderr)
    }
    return execBash(scriptPath: scriptFile.path, command: command)
}

private func writeStatusSeed(path: String) throws {
    let now = ISO8601DateFormatter().string(from: Date())
    let json = """
    {
      "state": "starting",
      "timestamp": "\(now)",
      "exit_code": null,
      "last_output": "launching"
    }
    """
    try json.write(toFile: path, atomically: true, encoding: .utf8)
}

private func runDirect(command: [String], debug: Bool) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command
    process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError
    if debug {
        fputs("wrap: exec (direct) " + command.joined(separator: " ") + "\n", stderr)
    }
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

private func execBash(scriptPath: String, command: [String]) -> Int32 {
    var argv: [UnsafeMutablePointer<CChar>?] = []
    argv.append(strdup("/bin/bash"))
    argv.append(strdup(scriptPath))
    for arg in command {
        argv.append(strdup(arg))
    }
    argv.append(nil)
    execv("/bin/bash", &argv)
    return -1
}

do {
    try CLI(args: CommandLine.arguments).run()
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
