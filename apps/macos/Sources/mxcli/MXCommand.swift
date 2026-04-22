import ArgumentParser
import Foundation
import appctl
import streamctl

public struct MXCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mx",
        abstract: "Workspace registration, runtime, and coding-agent lifecycle commands for Muxy.",
        discussion: """
        Notes:
          - All settings are stored in ~/.muxy/muxy.db.
          - Runtime state is stored in ~/.muxy/muxy.db and migrated in place with additive schema changes.
          - Paths default to the current directory when omitted.
          - `workspace import` registers the current directory by default and can apply `--title` or `--tooltip` when creating or re-importing a workspace.
          - `workspace update` mutates workspace metadata after creation.
          - `workspace up` waits for pending/running setup to complete and fails with the setup error if setup failed. It ensures a workspace and all its processes are running: launches when stopped; when already running, restarts any exited processes. Windows open without activating the app. Add `--restart` to force a full stop+launch. Add `--focus <name>` to bring one named workspace window to the foreground after launch.
          - Agent events stay explicit. `workspace import` and `workspace up` do not imply agent lifecycle. Events from unsupported terminal hosts are dropped. Agent events fired from tmux are rejected because Muxy does not support coding agents running inside tmux.
        """,
        version: AppVersion.current,
        subcommands: [
            WorkspaceCommand.self,
            AgentCommand.self
        ]
    )

    public init() {}
}

struct WorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace",
        abstract: "Import, update, and launch workspaces.",
        subcommands: [
            WorkspaceImportCommand.self,
            WorkspaceUpdateCommand.self,
            WorkspaceUpCommand.self
        ]
    )
}

struct WorkspaceImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Register a workspace for the current directory or a provided path."
    )

    @Argument(help: "Workspace directory. Defaults to the current directory.")
    var path: String?

    @Option(name: .long, help: "Workspace title override.")
    var title: String?

    @Option(name: .long, help: "Workspace tooltip override.")
    var tooltip: String?

    func run() throws {
        let context = CLIContext()
        let orchestrator = try context.makeOrchestrator()
        let importDirectory = path ?? context.currentDirectoryPath()
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

struct WorkspaceUpdateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update workspace metadata for the current directory or a provided path."
    )

    @Argument(help: "Workspace directory. Defaults to the current directory.")
    var path: String?

    @Option(name: .long, help: "Workspace title override.")
    var title: String?

    @Option(name: .long, help: "Workspace tooltip override.")
    var tooltip: String?

    func validate() throws {
        if title == nil && tooltip == nil {
            throw ValidationError("Specify at least one field to update with `--title` or `--tooltip`.")
        }
    }

    func run() throws {
        let context = CLIContext()
        let orchestrator = try context.makeOrchestrator()
        let workspace = try requireWorkspace(path: path, orchestrator: orchestrator, context: context)

        try orchestrator.updateWorkspaceMetadata(
            workspaceID: workspace.id,
            title: title,
            tooltip: tooltip != nil ? .some(tooltip) : nil
        )

        let updatedWorkspace = try requireWorkspace(id: workspace.id, orchestrator: orchestrator)
        try context.output.emit(
            text: "Updated workspace \(updatedWorkspace.title)\t\(updatedWorkspace.dir)",
            json: MutationResultPayload(message: "Updated workspace \(updatedWorkspace.title).", resource: updatedWorkspace)
        )
    }
}

struct WorkspaceUpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "up",
        abstract: "Ensure a workspace is running and optionally focus a tracked window."
    )

    @Argument(help: "Workspace directory. Defaults to the current directory.")
    var path: String?

    @Flag(name: .long, help: "Force a full stop and relaunch if the workspace is already running.")
    var restart = false

    @Option(name: .long, help: "Focus a named workspace window after launch.")
    var focus: String?

    func run() throws {
        let context = CLIContext()
        let orchestrator = try context.makeOrchestrator()
        let workspace = try requireWorkspace(path: path, orchestrator: orchestrator, context: context)

        try orchestrator.upWorkspace(
            workspaceID: workspace.id,
            restartIfRunning: restart,
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
        abstract: "Record an explicit lifecycle event for the current coding-agent terminal."
    )

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Lifecycle event to record.",
            discussion: "Allowed values: \(AgentEventType.allValueStrings.joined(separator: ", "))."
        )
    )
    var type: AgentEventType

    @Argument(help: "Workspace directory. Defaults to the current directory.")
    var path: String?

    func run() throws {
        let context = CLIContext()
        let orchestrator = try context.makeOrchestrator()
        let environment = context.environment()
        if let dropResult = agentEventDropResult(type: type, environment: environment, context: context) {
            try context.output.emit(text: dropResult.text, json: dropResult.payload)
            return
        }
        let directory = path ?? context.currentDirectoryPath()
        let normalizedDirectory = context.normalizePath(directory)
        let workspace = try requireWorkspace(path: normalizedDirectory, orchestrator: orchestrator, context: context)
        let agentContext = try resolveAgentInvocationContext(
            workspaceID: workspace.id,
            environment: environment,
            orchestrator: orchestrator,
            context: context)
        guard let agentContext else { return }

        switch type {
        case .`init`:
            try orchestrator.registerAgentWindow(
                workspaceID: workspace.id,
                provider: agentContext.provider,
                label: agentContext.label,
                itermSessionID: agentContext.iTermSessionID,
                codexThreadID: agentContext.codexThreadID,
                yabaiWindowID: agentContext.yabaiWindowID,
                status: .idle
            )
        case .start, .waiting, .done:
            try orchestrator.updateAgentWindowStatus(
                workspaceID: workspace.id,
                provider: agentContext.provider,
                itermSessionID: agentContext.iTermSessionID,
                codexThreadID: agentContext.codexThreadID,
                yabaiWindowID: agentContext.yabaiWindowID,
                label: agentContext.label,
                status: type.status
            )
        case .exit:
            try orchestrator.handleAgentExit(
                workspaceID: workspace.id,
                provider: agentContext.provider,
                itermSessionID: agentContext.iTermSessionID,
                codexThreadID: agentContext.codexThreadID,
                yabaiWindowID: agentContext.yabaiWindowID,
                label: agentContext.label
            )
        }

        try context.output.emit(
            text: "Agent \(type.rawValue): workspace=\(workspace.id)",
            json: MutationResultPayload(
                message: "Agent \(type.rawValue) recorded.",
                resource: ["workspaceID": workspace.id, "status": type.status.rawValue]
            )
        )
        context.fireAgentEventNotification()
    }
}

enum AgentEventType: String, CaseIterable, ExpressibleByArgument {
    case `init` = "init"
    case start = "start"
    case waiting = "waiting"
    case done = "done"
    case exit = "exit"

    static let allValueStrings = allCases.map(\.rawValue)

    var status: AgentWindowStatus {
        switch self {
        case .`init`:
            .idle
        case .start:
            .spinning
        case .waiting:
            .waiting
        case .done:
            .done
        case .exit:
            .idle
        }
    }
}

struct AgentInvocationContext {
    let provider: AgentProvider
    let label: String?
    let iTermSessionID: String?
    let codexThreadID: String?
    let yabaiWindowID: Int?
}

func resolveAgentInvocationContext(
    workspaceID: String,
    environment: [String: String],
    orchestrator: MuxyOrchestrator,
    context: CLIContext
) throws -> AgentInvocationContext? {
    guard let resolvedProvider = resolveProvider(environment: environment) else {
        return nil
    }
    let focusedWindowID = context.currentYabaiWindowID()
    let trackingIdentity = try terminalAdapter(for: resolvedProvider)?
        .resolveCurrentTrackingIdentity(environment: environment, yabaiFocusedWindowID: focusedWindowID)
    let splitIdentity = splitTrackingIdentity(trackingIdentity)
    return AgentInvocationContext(
        provider: resolvedProvider,
        label: inferredAgentLabel(environment: environment),
        iTermSessionID: splitIdentity.sessionID,
        codexThreadID: environment["CODEX_THREAD_ID"],
        yabaiWindowID: splitIdentity.windowID ?? focusedWindowID)
}

private func requireWorkspace(id: String, orchestrator: MuxyOrchestrator) throws -> WorkspaceRecord {
    guard let workspace = try orchestrator.store.workspace(id: id) else {
        throw ValidationError("Workspace not found for id \(id)")
    }

    return workspace
}

private func requireWorkspace(path: String?, orchestrator: MuxyOrchestrator, context: CLIContext) throws -> WorkspaceRecord {
    let directory = path ?? context.currentDirectoryPath()
    let normalizedDirectory = context.normalizePath(directory)
    guard let workspace = try orchestrator.store.workspace(dir: normalizedDirectory) else {
        throw ValidationError(
            "Workspace not found at: \(normalizedDirectory). Run `mx workspace import [path]` first."
        )
    }

    return workspace
}

private func resolveProvider(environment: [String: String]) -> AgentProvider? {
    let bundleIdentifier = environment["__CFBundleIdentifier"] ?? ""
    if bundleIdentifier == "com.googlecode.iterm2" {
        return .iterm2
    }
    if bundleIdentifier == "com.mitchellh.ghostty" {
        return .ghostty
    }
    return nil
}

func agentEventDropResult(
    type: AgentEventType,
    environment: [String: String],
    context: CLIContext
) -> (text: String, payload: MutationResultPayload<[String: String]>)? {
    if context.currentTmuxWindowID(environment: environment) != nil {
        return (
            "Dropped agent event \(type.rawValue): coding agents run from tmux are not supported by muxy",
            MutationResultPayload<[String: String]>(
                message: "Dropped tmux-backed agent event.",
                resource: nil)
        )
    }
    guard resolveProvider(environment: environment) != nil else {
        return (
            "Dropped agent event \(type.rawValue): unsupported terminal host",
            MutationResultPayload<[String: String]>(
                message: "Dropped unsupported agent event.",
                resource: nil)
        )
    }
    return nil
}

private func inferredAgentLabel(environment: [String: String]) -> String? {
    if environment["CODEX_THREAD_ID"] != nil {
        return "Codex CLI"
    }
    if environment["CLAUDE_CODE_ENTRYPOINT"] != nil {
        return "Claude Code CLI"
    }

    return nil
}

private func agentProvider(for terminalApp: String?) -> AgentProvider? {
    switch terminalApp {
    case TerminalHost.iterm2.appName:
        return .iterm2
    case TerminalHost.ghostty.appName:
        return .ghostty
    default:
        return nil
    }
}

private func terminalAdapter(for provider: AgentProvider) -> (any TerminalAdapter)? {
    switch provider {
    case .iterm2:
        return Iterm2Adapter()
    case .ghostty:
        return GhosttyAdapter()
    }
}

private func splitTrackingIdentity(_ identity: TerminalTrackingIdentity?) -> (sessionID: String?, windowID: Int?) {
    switch identity {
    case .session(let id):
        return (id, nil)
    case .window(let id):
        return (nil, id)
    case .tmux, nil:
        return (nil, nil)
    }
}
