import ArgumentParser
import Foundation
import systembridge
import workspacecore

/// Small manual-testing helper that exposes fixture seeding and state-dump
/// commands without expanding the user-facing `spaces` CLI surface.
struct MXE2ECommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spacese2e", abstract: "Manual real-system test helpers for Spaces.",
        subcommands: [
            SeedFixtureCommand.self, CleanupFixturesCommand.self, CreateWorkspaceCommand.self, LookupWorkspaceCommand.self,
            SelectWorkspaceDetailCommand.self, DumpWorkspaceCommand.self, FocusableWindowNamesCommand.self, ArchiveWorkspaceCommand.self,
            StopWorkspaceCommand.self, StopFixturesCommand.self, SetWorkspaceBrowserSessionURLsCommand.self, SetWorkspaceAgentLaunchersCommand.self,
            SetWorkspaceStopScriptCommand.self, SetTerminalHostCommand.self, TerminalHostAvailableCommand.self, RecordScreenCommand.self,
        ])
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
        let project = try orchestrator.project(dir: normalizedProjectDir) ?? orchestrator.addProject(dir: normalizedProjectDir)
        let uvExecutable = try resolveExecutablePath(named: "uv")
        let frontendCommand =
            "\(uvExecutable) run --project .spaces-e2e-demo spaces-e2e-demo frontend --port $APP_PORT --site-dir .spaces-e2e-demo/site --backend-url http://127.0.0.1:$API_PORT"
        let backendCommand = "\(uvExecutable) run --project .spaces-e2e-demo spaces-e2e-demo backend --port $API_PORT --data-dir .spaces-e2e-demo/api"

        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.ports = [.init(name: "APP_PORT"), .init(name: "API_PORT")]
            config.stopScript =
                #"bash -lc 'printf "project-stop:%s\n" "${SPACES_WORKSPACE_DIR}" >> "${SPACES_E2E_EVENTS_LOG:-/tmp/spaces-e2e-events.log}"'"#
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
                    id: $0.id, name: $0.templateName, pid: $0.pid, status: $0.status.rawValue, terminalApp: $0.terminalApp,
                    terminalTrackingID: $0.terminalTrackingID, terminalNativeID: $0.terminalNativeID, tmuxWindowID: $0.tmuxWindowID)
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
        let available: Bool =
            switch terminalHost {
            case .iterm2: Iterm2Adapter().isAvailable()
            case .ghostty: GhosttyAdapter().isAvailable()
            }
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
