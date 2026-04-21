import ArgumentParser
import Foundation
import appctl
import streamctl

public struct MXCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mx",
        abstract: "Workspace import, launch, and coding-agent lifecycle commands for Muxy.",
        discussion: """
        Notes:
          - All settings are stored in ~/.muxy/muxy.db.
          - Runtime state is stored in ~/.muxy/muxy.db and migrated in place with additive schema changes.
          - Launch waits for pending/running setup to complete and fails with the setup error if setup failed.
          - `workspace up` ensures a workspace and all its processes are running: launches when stopped; when already running, restarts any exited processes. Windows open without activating the app. Add `--force-restart` to force a full stop+launch. Add `--focus <name>` to bring one named workspace window to the foreground after launch.
          - `workspace import` registers the current directory by default, or another directory via `--dir`.
          - Agent events stay explicit. `workspace import` and `workspace up` do not imply agent lifecycle.
        """,
        version: AppVersion.current,
        subcommands: [
            WorkspaceCommand.self,
            AgentCommand.self,
            DashboardRemovedCommand.self
        ]
    )

    @Flag(name: .long, help: .hidden)
    var json = false

    public init() {}

    public func validate() throws {
        if json {
            throw ValidationError("`--json` is no longer supported.")
        }
    }
}

struct WorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace",
        abstract: "Import and launch workspaces.",
        subcommands: [
            WorkspaceImportCommand.self,
            WorkspaceUpCommand.self
        ]
    )
}

struct WorkspaceImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Register a workspace for the current directory or a provided path."
    )

    @Option(name: .long, help: "Workspace directory. Defaults to the current directory.")
    var dir: String?

    @Option(name: .long, help: "Workspace title override.")
    var title: String?

    @Option(name: .long, help: "Workspace tooltip override.")
    var tooltip: String?

    func run() throws {
        let context = CLIContext()
        let orchestrator = try context.makeOrchestrator()
        let importDirectory = dir ?? context.currentDirectoryPath()
        let normalizedImportDirectory = context.normalizePath(importDirectory)
        let workspace: WorkspaceRecord

        if let existing = try orchestrator.store.workspace(dir: normalizedImportDirectory), !existing.isArchived {
            if title != nil || tooltip != nil {
                try orchestrator.updateWorkspaceMetadata(
                    workspaceID: existing.id,
                    title: title,
                    tooltip: tooltip != nil ? .some(tooltip) : nil
                )
            }

            workspace = try orchestrator.store.workspace(id: existing.id) ?? existing
            try context.output.emit(
                text: "Workspace already exists: \(workspace.title)\t\(workspace.dir)",
                json: MutationResultPayload(message: "Workspace already exists.", resource: workspace)
            )
            return
        }

        var created = try orchestrator.createWorkspaceFromWorktree(worktreePath: importDirectory, name: title)
        if let tooltip {
            try orchestrator.updateWorkspaceMetadata(workspaceID: created.id, tooltip: .some(tooltip))
            created = try requireWorkspace(id: created.id, orchestrator: orchestrator)
        }

        workspace = created
        try context.output.emit(
            text: "Created workspace \(workspace.title)\t\(workspace.dir)",
            json: MutationResultPayload(message: "Created workspace \(workspace.title).", resource: workspace)
        )
    }
}

struct WorkspaceUpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "up",
        abstract: "Ensure a workspace is running and optionally focus a tracked window."
    )

    @Option(name: .long, help: "Workspace directory. Defaults to the current directory.")
    var dir: String?

    @Flag(name: .long, help: "Force a full stop and relaunch if the workspace is already running.")
    var forceRestart = false

    @Option(name: .long, help: "Focus a named workspace window after launch.")
    var focus: String?

    @Option(name: .long, help: "Update the workspace tooltip before launch.")
    var tooltip: String?

    func run() throws {
        let context = CLIContext()
        let orchestrator = try context.makeOrchestrator()
        let workspace = try requireWorkspace(dir: dir, orchestrator: orchestrator, context: context)

        if let tooltip {
            try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, tooltip: .some(tooltip))
        }

        try orchestrator.upWorkspace(
            workspaceID: workspace.id,
            restartIfRunning: forceRestart,
            background: focus == nil
        )

        if let focus {
            try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, name: focus)
        }

        let updatedWorkspace = try requireWorkspace(id: workspace.id, orchestrator: orchestrator)
        try context.output.emit(
            text: "Workspace is running \(workspace.id)",
            json: MutationResultPayload(message: "Workspace is running.", resource: updatedWorkspace)
        )
    }
}

struct AgentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Record coding-agent lifecycle events.",
        subcommands: [AgentEventCommand.self]
    )
}

struct AgentEventCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "event",
        abstract: "Attach an explicit lifecycle event to the current coding-agent terminal."
    )

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Lifecycle event to record.",
            discussion: "Allowed values: \(AgentEventType.allValueStrings.joined(separator: ", "))."
        )
    )
    var type: AgentEventType

    @Option(name: .long, help: "Workspace directory. Defaults to the current directory.")
    var dir: String?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Terminal host for the event. Defaults to the inferred host.",
            discussion: "Allowed values: \(AgentProvider.allValueStrings.joined(separator: ", "))."
        )
    )
    var provider: AgentProvider?

    func run() throws {
        let context = CLIContext()
        let orchestrator = try context.makeOrchestrator()
        let environment = context.environment()
        let directory = dir ?? context.currentDirectoryPath()
        let normalizedDirectory = context.normalizePath(directory)
        let resolvedProvider = try resolveProvider(explicitProvider: provider, environment: environment)
        let agentContext = AgentInvocationContext(
            provider: resolvedProvider,
            label: inferredAgentLabel(environment: environment),
            iTermSessionID: normalizedItermSessionID(environment: environment, provider: resolvedProvider),
            codexThreadID: environment["CODEX_THREAD_ID"],
            yabaiWindowID: context.currentYabaiWindowID()
        )
        let workspaceID = try ensureWorkspace(directory: normalizedDirectory, orchestrator: orchestrator)

        switch type {
        case .`init`:
            try orchestrator.registerAgentWindow(
                workspaceID: workspaceID,
                provider: agentContext.provider,
                label: agentContext.label,
                itermSessionID: agentContext.iTermSessionID,
                codexThreadID: agentContext.codexThreadID,
                yabaiWindowID: agentContext.yabaiWindowID,
                status: .idle
            )
        case .start, .waiting, .done, .stop:
            try orchestrator.updateAgentWindowStatus(
                workspaceID: workspaceID,
                provider: agentContext.provider,
                itermSessionID: agentContext.iTermSessionID,
                codexThreadID: agentContext.codexThreadID,
                yabaiWindowID: agentContext.yabaiWindowID,
                label: agentContext.label,
                status: type.status
            )
        }

        try context.output.emit(
            text: "Agent \(type.rawValue): workspace=\(workspaceID)",
            json: MutationResultPayload(
                message: "Agent \(type.rawValue) recorded.",
                resource: ["workspaceID": workspaceID, "status": type.status.rawValue]
            )
        )
        context.fireAgentEventNotification()
    }
}

struct DashboardRemovedCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dashboard",
        abstract: "Removed command.",
        shouldDisplay: false
    )

    func run() throws {
        throw ValidationError("`mx dashboard` was removed with the Tauri proof of concept.")
    }
}

enum AgentEventType: String, CaseIterable, ExpressibleByArgument {
    case `init` = "init"
    case start = "start"
    case waiting = "waiting"
    case done = "done"
    case stop = "stop"

    static let allValueStrings = allCases.map(\.rawValue)

    var status: AgentWindowStatus {
        switch self {
        case .`init`:
            .idle
        case .start:
            .spinning
        case .waiting:
            .waiting
        case .done, .stop:
            .done
        }
    }
}

extension AgentProvider: ExpressibleByArgument, CaseIterable {
    public static var allCases: [Self] { [.iterm2, .ghostty] }

    public static var allValueStrings: [String] { allCases.map(\.rawValue) }
}

private struct AgentInvocationContext {
    let provider: AgentProvider
    let label: String?
    let iTermSessionID: String?
    let codexThreadID: String?
    let yabaiWindowID: Int?
}

private func requireWorkspace(id: String, orchestrator: MuxyOrchestrator) throws -> WorkspaceRecord {
    guard let workspace = try orchestrator.store.workspace(id: id) else {
        throw ValidationError("Workspace not found for id \(id)")
    }

    return workspace
}

private func requireWorkspace(dir: String?, orchestrator: MuxyOrchestrator, context: CLIContext) throws -> WorkspaceRecord {
    let directory = dir ?? context.currentDirectoryPath()
    let normalizedDirectory = context.normalizePath(directory)
    guard let workspace = try orchestrator.store.workspace(dir: normalizedDirectory) else {
        throw ValidationError(
            "Workspace not found at: \(normalizedDirectory). Use `--dir <path>` to specify a different workspace directory."
        )
    }

    return workspace
}

private func ensureWorkspace(directory: String, orchestrator: MuxyOrchestrator) throws -> String {
    if let workspace = try orchestrator.store.workspace(dir: directory) {
        return workspace.id
    }

    return try orchestrator.createWorkspaceFromWorktree(worktreePath: directory).id
}

private func resolveProvider(explicitProvider: AgentProvider?, environment: [String: String]) throws -> AgentProvider {
    if let explicitProvider {
        return explicitProvider
    }

    let bundleIdentifier = environment["__CFBundleIdentifier"] ?? ""
    if bundleIdentifier == "com.googlecode.iterm2" {
        return .iterm2
    }
    if bundleIdentifier == "com.mitchellh.ghostty" {
        return .ghostty
    }
    if hasKnownCodingAgentMarkers(environment: environment) {
        let host = bundleIdentifier.isEmpty ? "unknown" : bundleIdentifier
        throw ValidationError("Ignoring agent event: unsupported terminal host '\(host)' for detected coding agent env.")
    }

    return .iterm2
}

private func hasKnownCodingAgentMarkers(environment: [String: String]) -> Bool {
    environment["CODEX_THREAD_ID"] != nil || environment["CLAUDE_CODE_ENTRYPOINT"] != nil
}

private func inferredAgentLabel(environment: [String: String]) -> String? {
    let bundleIdentifier = environment["__CFBundleIdentifier"] ?? ""
    if (bundleIdentifier == "com.googlecode.iterm2" || bundleIdentifier == "com.mitchellh.ghostty"),
        environment["CODEX_THREAD_ID"] != nil {
        return "Codex CLI"
    }
    if (bundleIdentifier == "com.googlecode.iterm2" || bundleIdentifier == "com.mitchellh.ghostty"),
        environment["CLAUDE_CODE_ENTRYPOINT"] != nil {
        return "Claude Code CLI"
    }

    return nil
}

private func normalizedItermSessionID(environment: [String: String], provider: AgentProvider) -> String? {
    guard provider == .iterm2, let raw = environment["ITERM_SESSION_ID"] else {
        return nil
    }
    guard let colonIndex = raw.lastIndex(of: ":") else {
        return raw
    }

    return String(raw[raw.index(after: colonIndex)...])
}
