import ArgumentParser
import Foundation
import spacesterminalcore
import systembridge
import workspacecore

/// Small manual-testing helper that exposes fixture seeding and state-dump
/// commands without expanding the user-facing `spaces` CLI surface.
struct MXE2ECommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spacese2e", abstract: "Manual real-system test helpers for Spaces.",
        subcommands: [
            SeedFixtureCommand.self, CleanupFixturesCommand.self, CreateWorkspaceCommand.self, LookupWorkspaceCommand.self,
            ShowMainWindowCommand.self, HideMainWindowCommand.self, SelectWorkspaceDetailCommand.self, OpenWorkspaceTerminalCommand.self,
            DumpWorkspaceCommand.self, FocusableWindowNamesCommand.self, ArchiveWorkspaceCommand.self, StopWorkspaceCommand.self,
            StopFixturesCommand.self, SetWorkspaceBrowserSessionURLsCommand.self, SetWorkspaceAgentLaunchersCommand.self,
            SetWorkspaceStopScriptCommand.self, SetTerminalHostCommand.self, TerminalHostAvailableCommand.self, FocusWorkspaceWindowIndexCommand.self,
            CycleWorkspaceWindowCommand.self, FocusWorkspaceProcessCommand.self, RecoverWorkspaceProcessCommand.self,
            CloseWorkspaceProcessWindowCommand.self, RecordScreenCommand.self,
        ])
}

private struct ShowMainWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show-main-window")

    func run() throws {
        DistributedNotificationCenter.default().postNotificationName(
            IPCNotification.showMainWindow, object: nil, userInfo: nil, options: [.deliverImmediately])
        try emitJSON(["success": true])
    }
}

private struct HideMainWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "hide-main-window")

    func run() throws {
        DistributedNotificationCenter.default().postNotificationName(
            IPCNotification.hideMainWindow, object: nil, userInfo: nil, options: [.deliverImmediately])
        try emitJSON(["success": true])
    }
}

private struct SelectWorkspaceDetailCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "select-workspace-detail")

    @Option(name: .long) var workspaceDir: String

    /// Tells the running Spaces app to show one workspace detail pane by
    /// workspace id, avoiding brittle sidebar accessibility traversal in the
    /// manual desktop harness.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        DistributedNotificationCenter.default().postNotificationName(
            IPCNotification.selectWorkspaceDetail, object: nil, userInfo: [IPCNotification.workspaceIDUserInfoKey: workspace.id],
            options: [.deliverImmediately])
        try emitJSON(
            WorkspaceSummaryPayload(
                id: workspace.id, title: workspace.title, dir: workspace.dir, isArchived: workspace.isArchived, isRunning: workspace.isRunning,
                notes: workspace.notes))
    }
}

private struct OpenWorkspaceTerminalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open-workspace-terminal")

    @Option(name: .long) var workspaceDir: String

    /// Tells the running Spaces app to open one built-in terminal for a
    /// workspace through the same UI-side path used by the app itself, so the
    /// manual harness can profile launch responsiveness without scripting
    /// shortcuts or sidebar clicks.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        DistributedNotificationCenter.default().postNotificationName(
            IPCNotification.openWorkspaceTerminal, object: nil, userInfo: [IPCNotification.workspaceIDUserInfoKey: workspace.id],
            options: [.deliverImmediately])
        try emitJSON(
            WorkspaceSummaryPayload(
                id: workspace.id, title: workspace.title, dir: workspace.dir, isArchived: workspace.isArchived, isRunning: workspace.isRunning,
                notes: workspace.notes))
    }
}

private struct CleanupFixturesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cleanup-fixtures")

    @Option(name: .long) var dirPrefix: String

    /// Removes prior manual-E2E fixture projects whose directories live under
    /// the supplied temp-root prefix, so repeated runs do not accumulate stale
    /// `repo` entries in the current Spaces database.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedPrefix = normalizePath(dirPrefix)
        var removedProjects: [String] = []

        for project in try orchestrator.store.projects() {
            let normalizedDir = normalizePath(project.dir)
            guard normalizedDir == normalizedPrefix || normalizedDir.hasPrefix(normalizedPrefix + "/") else { continue }
            try orchestrator.removeProject(dir: normalizedDir)
            removedProjects.append(normalizedDir)
        }

        try emitJSON(["removedProjects": removedProjects])
    }
}

private struct StopWorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop-workspace")

    @Option(name: .long) var workspaceDir: String

    /// Stops one real workspace through the production lifecycle path so the
    /// manual harness can close tracked terminals/browser windows between
    /// phases without widening the public CLI.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        _ = try orchestrator.stopWorkspace(workspaceID: workspace.id)
        guard let updated = try orchestrator.store.workspace(id: workspace.id) else {
            throw ValidationError("Workspace disappeared: \(workspace.id)")
        }
        try emitJSON(
            WorkspaceSummaryPayload(
                id: updated.id, title: updated.title, dir: updated.dir, isArchived: updated.isArchived, isRunning: updated.isRunning,
                notes: updated.notes))
    }
}

private struct StopFixturesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop-fixtures")

    @Option(name: .long) var dirPrefix: String

    /// Stops every fixture workspace under the supplied temp-root prefix so the
    /// suite can reset runtime state and close tracked windows between runs.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedPrefix = normalizePath(dirPrefix)
        var stoppedWorkspaces: [String] = []

        for project in try orchestrator.store.projects() {
            let normalizedDir = normalizePath(project.dir)
            guard normalizedDir == normalizedPrefix || normalizedDir.hasPrefix(normalizedPrefix + "/") else { continue }
            for workspace in try orchestrator.store.workspaces(projectID: project.id, includeArchived: true) {
                _ = try? orchestrator.stopWorkspace(workspaceID: workspace.id)
                stoppedWorkspaces.append(workspace.dir)
            }
        }

        try emitJSON(["stoppedWorkspaces": stoppedWorkspaces])
    }
}

private struct SeedFixtureCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "seed-fixture")

    @Option(name: .long) var projectDir: String
    @Option(name: .long) var docsURL: String
    @Option(name: .long) var adminURL: String
    @Option(name: .long) var workspaceTitle: String?

    /// Registers a local git repo as a Spaces project and seeds deterministic
    /// browser/process defaults that the manual E2E script can assert against.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedProjectDir = normalizePath(projectDir)
        try materializeDemoFixtureIfNeeded(projectDir: normalizedProjectDir, variant: "beacon")
        let project = try orchestrator.project(dir: normalizedProjectDir) ?? orchestrator.addProject(dir: normalizedProjectDir)
        let pythonExecutable = try resolveExecutablePath(named: "python3")
        let frontendCommand = fixtureServiceCommand(
            pythonExecutable: pythonExecutable,
            arguments: [
                "-m", "spaces_e2e_demo", "frontend", "--port", "$APP_PORT", "--site-dir", ".spaces-e2e-demo/site", "--backend-url",
                "http://127.0.0.1:$API_PORT",
            ])
        let backendCommand = fixtureServiceCommand(
            pythonExecutable: pythonExecutable,
            arguments: ["-m", "spaces_e2e_demo", "backend", "--port", "$API_PORT", "--data-dir", ".spaces-e2e-demo/api"])

        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.ports = [.init(name: "APP_PORT"), .init(name: "API_PORT")]
            config.stopScript =
                #"bash -lc 'for port in "$APP_PORT" "$API_PORT"; do if [ -n "$port" ]; then pids=(); while IFS= read -r pid; do [ -n "$pid" ] && pids+=("$pid"); done < <(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true); for pid in "${pids[@]}"; do kill "$pid" >/dev/null 2>&1 || true; done; sleep 0.5; for pid in "${pids[@]}"; do kill -0 "$pid" >/dev/null 2>&1 && kill -9 "$pid" >/dev/null 2>&1 || true; done; fi; done; printf "project-stop:%s\n" "${SPACES_WORKSPACE_DIR}" >> "${SPACES_E2E_EVENTS_LOG:-/tmp/spaces-e2e-events.log}"'"#
            config.processes = [
                .init(name: "frontend", command: frontendCommand, executionMode: .shell),
                .init(name: "backend", command: backendCommand, executionMode: .shell),
            ]
            config.browserSessions = [.init(name: "docs", url: docsURL), .init(name: "admin", url: adminURL)]
            config.agentLaunchers = []
        }

        if let workspaceTitle {
            let trimmedWorkspaceTitle = workspaceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedWorkspaceTitle.isEmpty, let workspace = try orchestrator.store.workspace(dir: project.dir) {
                try orchestrator.updateWorkspaceName(workspaceID: workspace.id, name: trimmedWorkspaceTitle)
            }
        }

        // The default workspace inherits project port definitions lazily, but
        // the manual shell harness needs the concrete reserved port numbers
        // immediately so it can start localhost fixture servers before launch.
        if let workspace = try orchestrator.store.workspace(dir: project.dir) {
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { _ in }
        }

        let payload = SeedFixturePayload(
            projectID: project.id,
            defaultWorkspace: try orchestrator.store.workspace(dir: project.dir).map {
                WorkspaceSummaryPayload(id: $0.id, title: $0.title, dir: $0.dir, isArchived: $0.isArchived, isRunning: $0.isRunning, notes: $0.notes)
            })
        try emitJSON(payload)
    }

    /// Resolves the executable up front because the seeded process command is
    /// launched by the GUI app through tmux, not by an interactive shell that
    /// necessarily inherits the user's PATH customizations.
    private func resolveExecutablePath(named name: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let path = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, let path, !path.isEmpty else { throw ValidationError("Required executable not found in PATH: \(name)") }
        return path
    }

    private func shellQuoted(_ raw: String) -> String { "'\(raw.replacingOccurrences(of: "'", with: "'\\''"))'" }

    private func shellToken(_ raw: String) -> String { raw.contains("$") ? raw : shellQuoted(raw) }

    private func fixtureServiceCommand(pythonExecutable: String, arguments: [String]) -> String {
        let joinedArguments = ([shellQuoted(pythonExecutable)] + arguments.map(shellToken)).joined(separator: " ")
        return "export PYTHONPATH=.spaces-e2e-demo/src; exec \(joinedArguments)"
    }

    private func materializeDemoFixtureIfNeeded(projectDir: String, variant: String) throws {
        let fileManager = FileManager.default
        let projectURL = URL(fileURLWithPath: projectDir, isDirectory: true)
        let demoRoot = projectURL.appendingPathComponent(".spaces-e2e-demo", isDirectory: true)
        let pyprojectURL = demoRoot.appendingPathComponent("pyproject.toml")
        let mainURL = demoRoot.appendingPathComponent("src/spaces_e2e_demo/__main__.py")
        let siteURL = demoRoot.appendingPathComponent("site", isDirectory: true)
        let apiURL = demoRoot.appendingPathComponent("api", isDirectory: true)
        if fileManager.fileExists(atPath: pyprojectURL.path), fileManager.fileExists(atPath: mainURL.path),
            fileManager.fileExists(atPath: siteURL.path), fileManager.fileExists(atPath: apiURL.path)
        {
            return
        }

        let fixtureRoot = try resolveDemoFixtureRoot()
        let templateRoot = fixtureRoot.appendingPathComponent("templates/\(variant)", isDirectory: true)
        let pyprojectSource = fixtureRoot.appendingPathComponent("pyproject.toml")
        let lockSource = fixtureRoot.appendingPathComponent("uv.lock")
        let srcSource = fixtureRoot.appendingPathComponent("src", isDirectory: true)
        let siteSource = templateRoot.appendingPathComponent("site", isDirectory: true)
        let apiSource = templateRoot.appendingPathComponent("api", isDirectory: true)

        guard fileManager.fileExists(atPath: pyprojectSource.path), fileManager.fileExists(atPath: srcSource.path),
            fileManager.fileExists(atPath: siteSource.path), fileManager.fileExists(atPath: apiSource.path)
        else { throw ValidationError("Demo fixture source is incomplete: \(fixtureRoot.path)") }

        if fileManager.fileExists(atPath: demoRoot.path) { try fileManager.removeItem(at: demoRoot) }
        try fileManager.createDirectory(at: demoRoot, withIntermediateDirectories: true)
        try fileManager.copyItem(at: pyprojectSource, to: pyprojectURL)
        if fileManager.fileExists(atPath: lockSource.path) {
            try fileManager.copyItem(at: lockSource, to: demoRoot.appendingPathComponent("uv.lock"))
        }
        try fileManager.copyItem(at: srcSource, to: demoRoot.appendingPathComponent("src", isDirectory: true))
        try fileManager.copyItem(at: siteSource, to: siteURL)
        try fileManager.copyItem(at: apiSource, to: apiURL)
    }

    private func resolveDemoFixtureRoot() throws -> URL {
        let fileManager = FileManager.default
        var candidates: [String] = []
        candidates.append(normalizePath("apps/macos/Tests/fixtures/e2e_demo"))
        if let spacesProjectDir = ProcessInfo.processInfo.environment["SPACES_PROJECT_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !spacesProjectDir.isEmpty
        {
            candidates.append(
                URL(fileURLWithPath: spacesProjectDir, isDirectory: true).appendingPathComponent(
                    "apps/macos/Tests/fixtures/e2e_demo", isDirectory: true
                ).path)
        }

        for candidate in candidates {
            let candidateURL = URL(fileURLWithPath: candidate, isDirectory: true)
            if fileManager.fileExists(atPath: candidateURL.appendingPathComponent("pyproject.toml").path) { return candidateURL }
        }

        throw ValidationError("Unable to locate apps/macos/Tests/fixtures/e2e_demo. Set SPACES_PROJECT_DIR to an original checkout if needed.")
    }
}

private struct LookupWorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "lookup-workspace")

    @Option(name: .long) var projectDir: String
    @Option(name: .long) var title: String

    /// Resolves the workspace created by the GUI flow so the shell harness can
    /// pivot from user-visible titles to stable workspace directories and IDs.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        guard let payload = try workspaceSummary(orchestrator: orchestrator, projectDir: projectDir, title: title) else {
            throw ValidationError("Workspace not found: \(title)")
        }
        try emitJSON(payload)
    }
}

private struct CreateWorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create-workspace")

    @Option(name: .long) var projectDir: String
    @Option(name: .long) var title: String
    @Option(name: .long) var branch: String
    @Option(name: .long) var targetBranch: String?
    @Option(name: .long) var directoryName: String?
    @Option(name: .long) var notes: String?
    @Flag(name: .long) var existingBranch = false

    /// Creates a real workspace record and worktree through the production
    /// orchestrator so the shell harness can validate add/remove flows without
    /// depending on fragile GUI-only form automation. `--existing-branch`
    /// mirrors the app's Existing branch flow for fixture-backed worktrees.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedProjectDir = normalizePath(projectDir)
        guard let project = try orchestrator.project(dir: normalizedProjectDir) else {
            throw ValidationError("Project not found: \(normalizedProjectDir)")
        }
        var workspace = try orchestrator.createWorkspace(
            projectID: project.id, name: title, branch: branch, targetBranch: targetBranch, directoryName: directoryName, runSetupScript: false,
            allowRemoteBranchLookup: false, allowExistingBranchReuse: existingBranch)
        if let notes {
            try orchestrator.updateWorkspaceNotes(workspaceID: workspace.id, notes: notes)
            workspace = try orchestrator.store.workspace(dir: workspace.dir) ?? workspace
        }
        try emitJSON(
            WorkspaceSummaryPayload(
                id: workspace.id, title: workspace.title, dir: workspace.dir, isArchived: workspace.isArchived, isRunning: workspace.isRunning,
                notes: workspace.notes))
    }
}

private struct DumpWorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dump-workspace")

    @Option(name: .long) var workspaceDir: String

    /// Dumps persisted workspace/runtime state as JSON so the manual E2E script
    /// can assert on the real database contents without reaching into SQLite
    /// directly.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        let appConfig = try orchestrator.appConfig()
        let payload = WorkspaceDumpPayload(
            appTerminalHost: appConfig.terminalHost.rawValue,
            workspace: .init(
                id: workspace.id, title: workspace.title, dir: workspace.dir, isArchived: workspace.isArchived, isRunning: workspace.isRunning,
                notes: workspace.notes),
            settings: try orchestrator.workspaceSettings(workspaceID: workspace.id).map {
                WorkspaceSettingsPayload(
                    stopScript: $0.stopScript, ports: $0.ports.map(\.name), processes: $0.processes.map { .init(name: $0.name, command: $0.command) },
                    browserSessions: $0.browserSessions.map { .init(name: $0.name, url: $0.url) },
                    agentLaunchers: $0.agentLaunchers.map { .init(name: $0.name, command: $0.command) })
            },
            runningProcesses: try orchestrator.runningProcesses(workspaceID: workspace.id).map {
                RunningProcessPayload(
                    id: $0.id, name: $0.templateName, pid: try resolvedPID(for: $0), status: $0.status.rawValue, terminalApp: $0.terminalApp,
                    terminalTrackingID: $0.terminalTrackingID, terminalNativeID: $0.terminalNativeID, tmuxWindowID: $0.tmuxWindowID,
                    windowID: $0.windowID)
            },
            windows: try orchestrator.windows(workspaceID: workspace.id).map {
                WindowPayload(
                    name: $0.name, app: $0.app, role: $0.role, detail: $0.detail, targetURL: $0.targetURL, windowID: $0.windowID,
                    terminalTrackingID: $0.terminalTrackingID, terminalNativeID: $0.terminalNativeID, itermTabIndex: $0.itermTabIndex)
            },
            agentWindows: try orchestrator.agentWindows(workspaceID: workspace.id).map {
                AgentWindowPayload(
                    id: $0.id, label: $0.label, provider: $0.provider.rawValue, status: $0.status.rawValue, terminalTrackingID: $0.terminalTrackingID,
                    terminalNativeID: $0.terminalNativeID, windowID: $0.windowID, yabaiWindowID: $0.yabaiWindowID)
            })
        try emitJSON(payload)
    }

    private func resolvedPID(for process: RunningProcessRecord) throws -> Int? {
        if let pid = process.pid { return pid }
        guard process.terminalApp == TerminalHost.spaces.appName else { return nil }
        guard let sessionID = process.terminalTrackingID ?? process.terminalNativeID, !sessionID.isEmpty else { return nil }
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        return try TerminalSessionPersistence.readRuntimeState(paths: paths).childPID.map(Int.init)
    }
}

private struct FocusWorkspaceProcessCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "focus-workspace-process")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var processName: String
    @Option(name: .long) var requestID: String?

    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        guard let process = try orchestrator.runningProcesses(workspaceID: workspace.id).first(where: { $0.templateName == processName }) else {
            throw ValidationError("Running process not found: \(processName)")
        }
        try orchestrator.focusWorkspaceProcess(workspaceID: workspace.id, processID: process.id, requestID: requestID)
        try emitJSON(["workspaceID": workspace.id, "processID": process.id, "processName": process.templateName, "requestID": requestID ?? ""])
    }
}

private struct FocusWorkspaceWindowIndexCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "focus-workspace-window-index")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var index: Int

    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: index)
        try emitJSON(["workspaceID": workspace.id, "index": String(index)])
    }
}

private struct CycleWorkspaceWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "cycle-workspace-window")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var direction: String

    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        switch direction {
        case "next", "previous":
            DistributedNotificationCenter.default().postNotificationName(
                IPCNotification.cycleWorkspaceWindow, object: nil,
                userInfo: [IPCNotification.workspaceIDUserInfoKey: workspace.id, IPCNotification.cycleDirectionUserInfoKey: direction],
                options: [.deliverImmediately])
        default: throw ValidationError("Unsupported direction: \(direction)")
        }
        try emitJSON(["workspaceID": workspace.id, "direction": direction])
    }
}

private struct RecoverWorkspaceProcessCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "recover-workspace-process")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var processName: String

    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        try orchestrator.recoverMissingConfiguredProcess(workspaceID: workspace.id, processKey: processName)
        try emitJSON(["workspaceID": workspace.id, "processName": processName])
    }
}

private struct CloseWorkspaceProcessWindowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "close-workspace-process-window")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var processName: String

    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        guard let process = try orchestrator.runningProcesses(workspaceID: workspace.id).first(where: { $0.templateName == processName }) else {
            throw ValidationError("Running process not found: \(processName)")
        }
        guard let sessionID = process.terminalNativeID ?? process.terminalTrackingID, !sessionID.isEmpty else {
            throw ValidationError("Running process has no built-in terminal session: \(processName)")
        }
        DistributedNotificationCenter.default().postNotificationName(
            IPCNotification.closeTerminalSessionWindow, object: nil, userInfo: [IPCNotification.terminalSessionIDUserInfoKey: sessionID],
            options: [.deliverImmediately])
        try emitJSON(["workspaceID": workspace.id, "processName": processName, "sessionID": sessionID])
    }
}

private struct SetWorkspaceAgentLaunchersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set-workspace-agent-launchers")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var name: String?
    @Option(name: .long) var command: String?
    @Flag(name: .long) var clear = false

    /// Replaces workspace coding-agent launchers through the production
    /// workspace-settings path so the manual harness can launch a mock agent
    /// without driving the nested settings UI.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        if clear && (name != nil || command != nil) { throw ValidationError("--clear cannot be combined with --name or --command") }
        if !clear
            && (name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                || command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
        {
            throw ValidationError("--name and --command are required unless --clear is used")
        }
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            if clear { settings.agentLaunchers = [] } else { settings.agentLaunchers = [AgentLauncher(name: name!, command: command!)] }
        }
        guard let updated = try orchestrator.workspaceSettings(workspaceID: workspace.id) else {
            throw ValidationError("Workspace settings missing at: \(normalizedWorkspaceDir)")
        }
        try emitJSON(
            WorkspaceSettingsPayload(
                stopScript: updated.stopScript, ports: updated.ports.map(\.name),
                processes: updated.processes.map { .init(name: $0.name, command: $0.command) },
                browserSessions: updated.browserSessions.map { .init(name: $0.name, url: $0.url) },
                agentLaunchers: updated.agentLaunchers.map { .init(name: $0.name, command: $0.command) }))
    }
}

private struct FocusableWindowNamesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "focusable-window-names")

    @Option(name: .long) var workspaceDir: String

    /// Returns the current indexed focus order used by direct window shortcuts
    /// and CLI numeric focus paths so the shell harness can align its keyboard
    /// assertions with production ordering.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        try emitJSON(["names": try orchestrator.workspaceFocusableWindowNames(workspaceID: workspace.id)])
    }
}

private struct ArchiveWorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "archive-workspace")

    @Option(name: .long) var workspaceDir: String

    /// Archives one workspace through the production lifecycle path so the
    /// manual harness can fall back when the archive confirmation UI is flaky.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        _ = try orchestrator.archiveWorkspace(workspaceID: workspace.id)
        guard let updated = try orchestrator.store.workspace(id: workspace.id) else {
            throw ValidationError("Workspace disappeared: \(workspace.id)")
        }
        try emitJSON(
            WorkspaceSummaryPayload(
                id: updated.id, title: updated.title, dir: updated.dir, isArchived: updated.isArchived, isRunning: updated.isRunning,
                notes: updated.notes))
    }
}

private struct SetWorkspaceStopScriptCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set-workspace-stop-script")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var stopScript: String

    /// Updates one workspace override through the production workspace-settings
    /// path so the shell harness can validate persisted override behavior
    /// without depending on nested text-editor accessibility.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in settings.stopScript = stopScript }
        guard let updated = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace disappeared at: \(normalizedWorkspaceDir)")
        }
        try emitJSON(
            WorkspaceSummaryPayload(
                id: updated.id, title: updated.title, dir: updated.dir, isArchived: updated.isArchived, isRunning: updated.isRunning,
                notes: updated.notes))
    }
}

private struct SetWorkspaceBrowserSessionURLsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set-workspace-browser-session-urls")

    @Option(name: .long) var workspaceDir: String
    @Option(name: .long) var docsURL: String
    @Option(name: .long) var adminURL: String

    /// Rewrites the standard manual-E2E browser session URLs for one workspace
    /// so concurrent fixture workspaces can be distinguished reliably in
    /// Chrome-window focus and cycling assertions.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        let normalizedWorkspaceDir = normalizePath(workspaceDir)
        guard let workspace = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace not found at: \(normalizedWorkspaceDir)")
        }
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.browserSessions = settings.browserSessions.map { session in
                var updated = session
                switch session.name {
                case "docs": updated.url = docsURL
                case "admin": updated.url = adminURL
                default: break
                }
                return updated
            }
        }
        guard let updated = try orchestrator.store.workspace(dir: normalizedWorkspaceDir) else {
            throw ValidationError("Workspace disappeared at: \(normalizedWorkspaceDir)")
        }
        try emitJSON(
            WorkspaceSummaryPayload(
                id: updated.id, title: updated.title, dir: updated.dir, isArchived: updated.isArchived, isRunning: updated.isRunning,
                notes: updated.notes))
    }
}

private struct SetTerminalHostCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set-terminal-host")

    @Argument var host: String

    /// Updates the persisted default terminal host without routing through the
    /// user-facing CLI, keeping this helper focused on manual test setup.
    func run() throws {
        let orchestrator = try makeOrchestrator()
        guard let terminalHost = TerminalHost(rawValue: host.lowercased()) else { throw ValidationError("Unsupported terminal host: \(host)") }
        let config = try orchestrator.updateTerminalHost(terminalHost)
        try emitJSON(["terminalHost": config.terminalHost.rawValue])
    }
}

private struct TerminalHostAvailableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "terminal-host-available")

    @Argument var host: String

    /// Reports whether one concrete terminal host is available using the same
    /// adapter-level availability checks the app relies on for setup/runtime.
    func run() throws {
        guard let terminalHost = TerminalHost(rawValue: host.lowercased()) else { throw ValidationError("Unsupported terminal host: \(host)") }
        let available = SetupChecker().isTerminalHostAvailable(named: terminalHost.rawValue)
        try emitJSON(TerminalHostAvailabilityPayload(host: terminalHost.rawValue, available: available))
    }
}

private struct SeedFixturePayload: Codable {
    let projectID: String
    let defaultWorkspace: WorkspaceSummaryPayload?
}

private struct TerminalHostAvailabilityPayload: Codable {
    let host: String
    let available: Bool
}

private struct WorkspaceDumpPayload: Codable {
    let appTerminalHost: String
    let workspace: WorkspaceSummaryPayload
    let settings: WorkspaceSettingsPayload?
    let runningProcesses: [RunningProcessPayload]
    let windows: [WindowPayload]
    let agentWindows: [AgentWindowPayload]
}

private struct WorkspaceSummaryPayload: Codable {
    let id: String
    let title: String
    let dir: String
    let isArchived: Bool
    let isRunning: Bool
    let notes: String?
}

private struct WorkspaceSettingsPayload: Codable {
    let stopScript: String?
    let ports: [String]
    let processes: [NamedCommandPayload]
    let browserSessions: [NamedURLPayload]
    let agentLaunchers: [NamedCommandPayload]
}

private struct NamedCommandPayload: Codable {
    let name: String?
    let command: String
}

private struct NamedURLPayload: Codable {
    let name: String?
    let url: String?
}

private struct RunningProcessPayload: Codable {
    let id: String
    let name: String
    let pid: Int?
    let status: String
    let terminalApp: String?
    let terminalTrackingID: String?
    let terminalNativeID: String?
    let tmuxWindowID: String?
    let windowID: Int?
}

private struct WindowPayload: Codable {
    let name: String?
    let app: String
    let role: String
    let detail: String?
    let targetURL: String?
    let windowID: Int?
    let terminalTrackingID: String?
    let terminalNativeID: String?
    let itermTabIndex: Int?
}

private struct AgentWindowPayload: Codable {
    let id: String
    let label: String?
    let provider: String
    let status: String
    let terminalTrackingID: String?
    let terminalNativeID: String?
    let windowID: Int?
    let yabaiWindowID: Int?
}

/// Looks up one workspace by project directory and title, matching the GUI's
/// visible naming semantics rather than internal IDs.
private func workspaceSummary(orchestrator: WorkspaceOrchestrator, projectDir: String, title: String) throws -> WorkspaceSummaryPayload? {
    let normalizedProjectDir = normalizePath(projectDir)
    guard let project = try orchestrator.project(dir: normalizedProjectDir) else { return nil }
    guard let workspace = try orchestrator.listWorkspaces(projectID: project.id, includeArchived: true).first(where: { $0.title == title }) else {
        return nil
    }
    return WorkspaceSummaryPayload(
        id: workspace.id, title: workspace.title, dir: workspace.dir, isArchived: workspace.isArchived, isRunning: workspace.isRunning,
        notes: workspace.notes)
}

/// Shared JSON encoder for the shell harness.
private func emitJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value))
    FileHandle.standardOutput.write(Data("\n".utf8))
}

/// Builds the same real orchestrator used by the app and CLI so the manual E2E
/// helper exercises production storage and lifecycle code.
private func makeOrchestrator() throws -> WorkspaceOrchestrator { try WorkspaceOrchestrator(store: .init(path: DatabaseLocator.defaultPath())) }

/// Normalizes filesystem paths before lookups so shell callers can pass either
/// relative or absolute values safely.
private func normalizePath(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

MXE2ECommand.main()
