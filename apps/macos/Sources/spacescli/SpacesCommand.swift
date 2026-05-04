import ArgumentParser
import Foundation
import systembridge
import workspacecore

public struct SpacesCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "spaces", abstract: "Workspace registration, runtime, and coding-agent lifecycle commands for Spaces.",
        discussion: """
            Notes:
              - All settings are stored in ~/.spaces/spaces.db.
              - Runtime state is stored in ~/.spaces/spaces.db and migrated in place with additive schema changes.
              - Paths default to the current directory when omitted.
              - `import` registers the current directory by default and can apply `--title` or `--notes` when creating or re-importing a workspace.
              - `update` mutates workspace metadata after creation.
              - `start` waits for pending/running setup to complete and fails with the setup error if setup failed. It ensures a workspace and all its processes are running: launches when stopped; when already running, restarts any exited processes. Windows open without activating the app.
              - `restart` forces a full stop and relaunch for a workspace.
              - `open <name>` resolves one named tracked browser, process, or coding-agent target in the workspace and brings it to the foreground.
              - Agent events stay explicit. `import`, `start`, and `restart` do not imply agent lifecycle. `signal <event>` records those lifecycle transitions. Events from unsupported terminal hosts are dropped. Agent events fired from tmux are rejected because Spaces does not support coding agents running inside tmux.
            """, version: AppVersion.current,
        subcommands: [ImportCommand.self, UpdateCommand.self, StartCommand.self, RestartCommand.self, OpenCommand.self, SignalCommand.self])

    public init() {}
}

struct ImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import", abstract: "Register a workspace for the current directory or a provided path.")

    @Argument(help: "Workspace directory. Defaults to the current directory.") var path: String?

    @Option(name: .long, help: "Workspace title override.") var title: String?

    @Option(name: .long, help: "Workspace notes override.") var notes: String?

    func run() throws {
        let context = CLIContext()
        let orchestrator = try context.makeOrchestrator()
        let importDirectory = path ?? context.currentDirectoryPath()
        let normalizedImportDirectory = context.normalizePath(importDirectory)
        let workspace: WorkspaceRecord

        if let existing = try orchestrator.store.workspace(dir: normalizedImportDirectory), !existing.isArchived {
            if title != nil || notes != nil {
                try orchestrator.updateWorkspaceMetadata(workspaceID: existing.id, title: title, notes: notes != nil ? .some(notes) : nil)
            }

            workspace = try orchestrator.store.workspace(id: existing.id) ?? existing
            try context.output.emit(
                text: "Workspace already exists: \(workspace.title)\t\(workspace.dir)",
                json: MutationResultPayload(message: "Workspace already exists.", resource: workspace))
            return
        }

        var created = try orchestrator.createWorkspaceFromWorktree(worktreePath: importDirectory, name: title)
        if let notes {
            try orchestrator.updateWorkspaceMetadata(workspaceID: created.id, notes: .some(notes))
            created = try requireWorkspace(id: created.id, orchestrator: orchestrator)
        }

        workspace = created
        try context.output.emit(
            text: "Created workspace \(workspace.title)\t\(workspace.dir)",
            json: MutationResultPayload(message: "Created workspace \(workspace.title).", resource: workspace))
    }
}

struct UpdateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update", abstract: "Update workspace metadata for the current directory or a provided path.")

    @Argument(help: "Workspace directory. Defaults to the current directory.") var path: String?

    @Option(name: .long, help: "Workspace title override.") var title: String?

    @Option(name: .long, help: "Workspace notes override.") var notes: String?

    func validate() throws {
        if title == nil && notes == nil { throw ValidationError("Specify at least one field to update with `--title` or `--notes`.") }
    }

    func run() throws {
        let context = CLIContext()
        let orchestrator = try context.makeOrchestrator()
        let workspace = try requireWorkspace(path: path, orchestrator: orchestrator, context: context)

        try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, title: title, notes: notes != nil ? .some(notes) : nil)

        let updatedWorkspace = try requireWorkspace(id: workspace.id, orchestrator: orchestrator)
        try context.output.emit(
            text: "Updated workspace \(updatedWorkspace.title)\t\(updatedWorkspace.dir)",
            json: MutationResultPayload(message: "Updated workspace \(updatedWorkspace.title).", resource: updatedWorkspace))
    }
}

struct StartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Ensure a workspace is running.")

    @Argument(help: "Workspace directory. Defaults to the current directory.") var path: String?

    func run() throws {
        let context = CLIContext()
        let orchestrator = try context.makeOrchestrator()
        let workspace = try requireWorkspace(path: path, orchestrator: orchestrator, context: context)

        try orchestrator.upWorkspace(workspaceID: workspace.id, restartIfRunning: false, background: true)

        let updatedWorkspace = try requireWorkspace(id: workspace.id, orchestrator: orchestrator)
        try context.output.emit(
            text: "Workspace is running \(workspace.id)", json: MutationResultPayload(message: "Workspace is running.", resource: updatedWorkspace))
    }
}

struct RestartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restart", abstract: "Force a full stop and relaunch for a workspace.")

    @Argument(help: "Workspace directory. Defaults to the current directory.") var path: String?

    func run() throws {
        let context = CLIContext()
        let orchestrator = try context.makeOrchestrator()
        let workspace = try requireWorkspace(path: path, orchestrator: orchestrator, context: context)

        try orchestrator.upWorkspace(workspaceID: workspace.id, restartIfRunning: true, background: true)

        let updatedWorkspace = try requireWorkspace(id: workspace.id, orchestrator: orchestrator)
        try context.output.emit(
            text: "Workspace restarted \(workspace.id)", json: MutationResultPayload(message: "Workspace restarted.", resource: updatedWorkspace))
    }
}

struct OpenCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "open", abstract: "Open or focus one named tracked workspace target.")

    @Argument(help: "Name of the tracked browser, process, or coding-agent target to open.") var name: String

    @Argument(help: "Workspace directory. Defaults to the current directory.") var path: String?

    func run() throws {
        let context = CLIContext()
        let orchestrator = try context.makeOrchestrator()
        let workspace = try requireWorkspace(path: path, orchestrator: orchestrator, context: context)

        try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, name: name)

        let updatedWorkspace = try requireWorkspace(id: workspace.id, orchestrator: orchestrator)
        try context.output.emit(
            text: "Opened workspace target \(name)\tworkspace=\(workspace.id)",
            json: MutationResultPayload(message: "Opened workspace target.", resource: updatedWorkspace))
    }
}

struct SignalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "signal", abstract: "Record an explicit lifecycle event for the current coding-agent terminal.")

    @Argument(
        help: ArgumentHelp("Lifecycle event to record.", discussion: "Allowed values: \(AgentEventType.allValueStrings.joined(separator: ", "))."))
    var type: AgentEventType

    @Argument(help: "Workspace directory. Defaults to the current directory.") var path: String?

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
            workspaceID: workspace.id, environment: environment, orchestrator: orchestrator, context: context)
        guard let agentContext else { return }

        switch type {
        case .`init`:
            try orchestrator.registerAgentWindow(
                workspaceID: workspace.id, provider: agentContext.provider, label: agentContext.label,
                terminalTrackingID: agentContext.terminalTrackingID, terminalNativeID: agentContext.terminalNativeID,
                codexThreadID: agentContext.codexThreadID, yabaiWindowID: agentContext.yabaiWindowID, status: .idle)
        case .start, .waiting, .done:
            try orchestrator.updateAgentWindowStatus(
                workspaceID: workspace.id, provider: agentContext.provider, terminalTrackingID: agentContext.terminalTrackingID,
                codexThreadID: agentContext.codexThreadID, terminalNativeID: agentContext.terminalNativeID, yabaiWindowID: agentContext.yabaiWindowID,
                label: agentContext.label, status: type.status)
        case .exit:
            try orchestrator.handleAgentExit(
                workspaceID: workspace.id, provider: agentContext.provider, terminalTrackingID: agentContext.terminalTrackingID,
                codexThreadID: agentContext.codexThreadID, terminalNativeID: agentContext.terminalNativeID, yabaiWindowID: agentContext.yabaiWindowID,
                label: agentContext.label)
        }

        try context.output.emit(
            text: "Agent \(type.rawValue): workspace=\(workspace.id)",
            json: MutationResultPayload(
                message: "Agent \(type.rawValue) recorded.", resource: ["workspaceID": workspace.id, "status": type.status.rawValue]))
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
        case .`init`: .idle
        case .start: .spinning
        case .waiting: .waiting
        case .done: .done
        case .exit: .idle
        }
    }
}

struct AgentInvocationContext {
    let provider: AgentProvider
    let label: String?
    let terminalTrackingID: String?
    let terminalNativeID: String?
    let codexThreadID: String?
    let yabaiWindowID: Int?
}

func resolveAgentInvocationContext(workspaceID: String, environment: [String: String], orchestrator: WorkspaceOrchestrator, context: CLIContext)
    throws -> AgentInvocationContext?
{
    guard let resolvedProvider = resolveProvider(environment: environment) else { return nil }
    let focusedWindowID = context.currentYabaiWindowID()
    let adapter = terminalAdapter(for: resolvedProvider)
    let trackingIdentity = try adapter?.resolveCurrentTrackingIdentity(environment: environment, yabaiFocusedWindowID: focusedWindowID)
    let splitIdentity = splitTrackingIdentity(trackingIdentity)
    if resolvedProvider == .ghostty, splitIdentity.sessionID?.isEmpty != false { return nil }
    let terminalNativeID =
        resolvedProvider == .ghostty
        ? try resolveTrackedGhosttyNativeTerminalID(workspaceID: workspaceID, terminalTrackingID: splitIdentity.sessionID, orchestrator: orchestrator)
        : nil
    let resolvedYabaiWindowID: Int?
    if resolvedProvider == .ghostty {
        resolvedYabaiWindowID = splitIdentity.windowID
    } else if splitIdentity.sessionID?.isEmpty == false {
        // iTerm session IDs are already stable terminal identities. Falling back
        // to whichever yabai window happens to be focused at event time can
        // misattribute agent events to the Spaces app window.
        resolvedYabaiWindowID = nil
    } else {
        resolvedYabaiWindowID = splitIdentity.windowID ?? focusedWindowID
    }
    return AgentInvocationContext(
        provider: resolvedProvider, label: inferredAgentLabel(environment: environment), terminalTrackingID: splitIdentity.sessionID,
        terminalNativeID: terminalNativeID, codexThreadID: environment["CODEX_THREAD_ID"], yabaiWindowID: resolvedYabaiWindowID)
}

private func requireWorkspace(id: String, orchestrator: WorkspaceOrchestrator) throws -> WorkspaceRecord {
    guard let workspace = try orchestrator.store.workspace(id: id) else { throw ValidationError("Workspace not found for id \(id)") }

    return workspace
}

private func requireWorkspace(path: String?, orchestrator: WorkspaceOrchestrator, context: CLIContext) throws -> WorkspaceRecord {
    let directory = path ?? context.currentDirectoryPath()
    let normalizedDirectory = context.normalizePath(directory)
    guard let workspace = try orchestrator.store.workspace(dir: normalizedDirectory) else {
        throw ValidationError("Workspace not found at: \(normalizedDirectory). Run `spaces import [path]` first.")
    }

    return workspace
}

private func resolveProvider(environment: [String: String]) -> AgentProvider? {
    let bundleIdentifier = environment["__CFBundleIdentifier"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if bundleIdentifier == TerminalHost.iterm2.bundleIdentifier { return .iterm2 }
    if bundleIdentifier == TerminalHost.ghostty.bundleIdentifier { return .ghostty }

    let itermSessionID = environment["ITERM_SESSION_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !itermSessionID.isEmpty { return .iterm2 }

    let termProgram = environment["TERM_PROGRAM"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    if termProgram == "iterm.app" { return .iterm2 }
    if termProgram == "ghostty" { return .ghostty }

    let term = environment["TERM"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    if term.contains("ghostty") { return .ghostty }

    return nil
}

func agentEventDropResult(type: AgentEventType, environment: [String: String], context: CLIContext) -> (
    text: String, payload: MutationResultPayload<[String: String]>
)? {
    if context.currentTmuxWindowID(environment: environment) != nil {
        return (
            "Dropped agent event \(type.rawValue): coding agents run from tmux are not supported by Spaces",
            MutationResultPayload<[String: String]>(message: "Dropped tmux-backed agent event.", resource: nil)
        )
    }
    guard let provider = resolveProvider(environment: environment) else {
        return (
            "Dropped agent event \(type.rawValue): unsupported terminal host",
            MutationResultPayload<[String: String]>(message: "Dropped unsupported agent event.", resource: nil)
        )
    }
    if provider == .ghostty, environment[WorkspaceOrchestrator.terminalTrackingIDEnvVar]?.isEmpty != false {
        return (
            "Dropped agent event \(type.rawValue): untracked Ghostty terminal",
            MutationResultPayload<[String: String]>(message: "Dropped untracked Ghostty agent event.", resource: nil)
        )
    }
    return nil
}

private func inferredAgentLabel(environment: [String: String]) -> String? {
    if let label = environment[WorkspaceOrchestrator.agentLabelEnvVar]?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
        return label
    }
    if environment["CODEX_THREAD_ID"] != nil { return "Codex CLI" }
    if environment["CLAUDE_CODE_ENTRYPOINT"] != nil { return "Claude Code CLI" }

    return nil
}

private func agentProvider(for terminalApp: String?) -> AgentProvider? {
    switch terminalApp {
    case TerminalHost.iterm2.appName: return .iterm2
    case TerminalHost.ghostty.appName: return .ghostty
    default: return nil
    }
}

private func terminalAdapter(for provider: AgentProvider) -> (any TerminalAdapter)? {
    switch provider {
    case .iterm2: return Iterm2Adapter()
    case .ghostty: return GhosttyAdapter()
    }
}

private func splitTrackingIdentity(_ identity: TerminalTrackingIdentity?) -> (sessionID: String?, windowID: Int?) {
    switch identity {
    case .session(let id): return (id, nil)
    case .window(let id): return (nil, id)
    case .tmux, nil: return (nil, nil)
    }
}

private func resolveTrackedGhosttyNativeTerminalID(workspaceID: String, terminalTrackingID: String?, orchestrator: WorkspaceOrchestrator) throws
    -> String?
{
    guard let terminalTrackingID, !terminalTrackingID.isEmpty else { return nil }

    // Ghostty hooks only know the Spaces-issued tracking token. Recover the host-native terminal ID
    // only when tracked rows already agree on a single value; otherwise return nil and let the
    // event stay unbound rather than guessing from frontmost Ghostty state.
    let windowNativeIDs = try orchestrator.store.windows(workspaceID: workspaceID).compactMap { window -> String? in
        guard window.role == "terminal", window.app == TerminalHost.ghostty.appName else { return nil }
        guard window.terminalTrackingID == terminalTrackingID else { return nil }
        guard let nativeID = window.terminalNativeID, !nativeID.isEmpty else { return nil }
        return nativeID
    }
    let processNativeIDs = try orchestrator.store.runningProcesses(workspaceID: workspaceID).compactMap { process -> String? in
        guard process.terminalApp == TerminalHost.ghostty.appName else { return nil }
        guard process.terminalTrackingID == terminalTrackingID else { return nil }
        guard let nativeID = process.terminalNativeID, !nativeID.isEmpty else { return nil }
        return nativeID
    }
    let agentNativeIDs = try orchestrator.store.agentWindows(workspaceID: workspaceID).compactMap { record -> String? in
        guard record.provider == .ghostty else { return nil }
        guard record.terminalTrackingID == terminalTrackingID else { return nil }
        guard let nativeID = record.terminalNativeID, !nativeID.isEmpty else { return nil }
        return nativeID
    }

    let nativeIDs = Set(windowNativeIDs + processNativeIDs + agentNativeIDs)
    guard nativeIDs.count == 1 else { return nil }
    return nativeIDs.first
}
