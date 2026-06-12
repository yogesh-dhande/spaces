import ArgumentParser
import Darwin
import Dispatch
import Foundation
import spacesterminalcore
import spacesterminalghostty
import systembridge
import workspacecore

extension TerminalSessionBackendKind: ExpressibleByArgument {}

public struct SpacesCommand: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "spaces", abstract: "Workspace registration, runtime, and coding-agent lifecycle commands for Spaces.",
        discussion: """
            Notes:
              - Explicit `SPACES_DB_PATH` overrides the default database location.
              - Repo-local development builds default to a per-worktree profile under ~/.spaces-dev/profiles/spaces.
              - Installed or non-dev builds default to ~/.spaces/spaces.db.
              - Runtime state defaults to <profile-root>/runtime unless `SPACES_RUNTIME_DIR` overrides it.
              - Paths default to the current directory when omitted.
              - `import` registers the current directory by default and can apply `--title` or `--notes` when creating or re-importing a workspace.
              - `update` mutates workspace metadata after creation.
              - `start` waits for pending/running setup to complete and fails with the setup error if setup failed. It ensures a workspace and all its processes are running: launches when stopped; when already running, restarts any exited processes. Windows open without activating the app.
              - `restart` forces a full stop and relaunch for a workspace.
              - Agent events stay explicit. `import`, `start`, and `restart` do not imply agent lifecycle. `signal <event>` records those lifecycle transitions. Only built-in Spaces terminal sessions are accepted as coding-agent sources.
            """, version: AppVersion.current,
        subcommands: [ImportCommand.self, UpdateCommand.self, StartCommand.self, RestartCommand.self, SignalCommand.self, TerminalCommand.self])

    public init() {}
}

struct TerminalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "terminal", abstract: "Manage Spaces terminal sessions.",
        subcommands: [
            TerminalListCommand.self, TerminalCommandCommand.self, TerminalSendCommand.self, TerminalKeyCommand.self, TerminalTailCommand.self,
            TerminalShowCommand.self, TerminalTakeoverCommand.self, TerminalProxyCommand.self,
        ])
}

struct TerminalListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List available Spaces terminal sessions.")

    func run() throws {
        let rows = try availableTerminalSessionRows()
        if rows.isEmpty {
            print("No terminal sessions.")
            return
        }

        for row in rows { print(row) }
    }
}

func availableTerminalSessionRows(fileManager: FileManager = .default) throws -> [String] {
    try TerminalSessionCatalog.listLiveSessions(fileManager: fileManager).map { session in
        "\(session.sessionID)\tstate=\(session.runtimeState.state.rawValue)\tcwd=\(session.effectiveWorkingDirectory)"
    }
}

struct TerminalCommandCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "command", abstract: "Start a terminal session in the background.")

    @Option(name: .long, help: "Shell command to run inside the terminal session. If omitted, starts a login shell.") var command: String?

    @Option(name: .long, help: "Window or session title to track.") var title: String?

    @Option(name: .long, help: "Working directory. Defaults to the current directory.") var cwd: String?

    @Option(name: .long, help: "Shell executable path. Defaults to $SHELL or /bin/zsh.") var shell: String?

    @Option(name: .long, help: "Terminal backend. Defaults to ghostty-embedded.") var backend: TerminalSessionBackendKind = .ghosttyEmbedded

    func run() throws {
        guard TerminalSessionBackendSupport.isSupported(backend) else {
            throw WorkspaceError.invalidArgument(message: "Terminal backend '\(backend.rawValue)' is not available in this build.")
        }
        let context = CLIContext()
        let launchConfiguration = terminalCommandLaunchConfiguration(
            sessionID: UUID().uuidString, backend: backend, command: command, title: title, cwd: cwd, shell: shell, context: context)
        let sessionID = launchConfiguration.sessionID
        let session = try TerminalService.createSession(launchConfiguration)

        DistributedNotificationCenter.default().postNotificationName(
            IPCNotification.openTerminalSessionWindow, object: try IPCNotification.currentObject(),
            userInfo: [
                IPCNotification.terminalSessionIDUserInfoKey: sessionID,
                IPCNotification.terminalAttachmentModeUserInfoKey: TerminalAttachmentMode.owner.rawValue,
            ], options: [.deliverImmediately])

        print(
            "Started terminal session \(session.id)\ttitle=\(session.title)\tbackend=\(session.backend.rawValue)\tlocation=local\tcwd=\(session.workingDirectory)"
        )
    }
}

func terminalCommandLaunchConfiguration(
    sessionID: String, backend: TerminalSessionBackendKind, command: String?, title: String?, cwd: String?, shell: String?,
    createdAt: String = ISO8601DateFormatter().string(from: Date()), context: CLIContext = CLIContext()
) -> TerminalSessionLaunchConfiguration {
    let workingDirectory = context.normalizePath(cwd ?? context.currentDirectoryPath())
    let resolvedShell = terminalShellPath(shell)
    let resolvedTitle = title ?? terminalDefaultTitle(command: command, cwd: workingDirectory)
    return TerminalSessionLaunchConfiguration(
        sessionID: sessionID, backend: backend, lifetimePolicy: .persistent, title: resolvedTitle, workingDirectory: workingDirectory,
        shell: resolvedShell, command: command, createdAt: createdAt)
}

struct TerminalSendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "send", abstract: "Send text to a Spaces terminal session.")

    @Argument(help: "Terminal session ID.") var sessionID: String
    @Argument(help: "Text to send.") var text: String
    @Flag(name: .long, help: "Append a newline after the text.") var newline = false

    func run() throws {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else {
            throw WorkspaceError.invalidArgument(message: "Terminal session '\(sessionID)' is not available.")
        }
        let response = try TerminalControlClient.send(
            request: TerminalControlRequest(command: "send", text: text, appendNewline: newline), socketPath: paths.controlSocketPath)
        guard response.ok else { throw WorkspaceError.invalidArgument(message: response.message) }
        print("Sent input to terminal session \(sessionID)")
    }
}

struct TerminalKeyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "key", abstract: "Send a named key or control chord to a Spaces terminal session.")

    @Argument(help: "Terminal session ID.") var sessionID: String
    @Argument(help: "Key spec such as enter, esc, up, down, ctrl+c, cmd+left, or cmd+k.") var key: String

    func run() throws {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else {
            throw WorkspaceError.invalidArgument(message: "Terminal session '\(sessionID)' is not available.")
        }
        let response = try TerminalControlClient.send(request: TerminalControlRequest(command: "key", key: key), socketPath: paths.controlSocketPath)
        guard response.ok else { throw WorkspaceError.invalidArgument(message: response.message) }
        print("Sent key to terminal session \(sessionID)")
    }
}

struct TerminalTailCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tail", abstract: "Show recent output from a Spaces terminal session.")

    @Argument(help: "Terminal session ID.") var sessionID: String
    @Option(name: .long, help: "Number of lines to print.") var lines: Int = 20

    func run() throws {
        let startedAt = Date()
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        guard FileManager.default.fileExists(atPath: paths.outputPath) else {
            throw WorkspaceError.invalidArgument(message: "Terminal session '\(sessionID)' has no output yet.")
        }
        let tailed = try TerminalOutputTail.tail(path: paths.outputPath, lineCount: lines)
        TerminalPerformance.logMetric(
            "terminal_tail_command", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true,
            detail: "lines=\(lines) output_chars=\(tailed.count)")
        print(tailed)
    }
}

struct TerminalShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Open a native Spaces window for a terminal session.")

    @Argument(help: "Terminal session ID.") var sessionID: String

    func run() throws {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        guard (try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths)) != nil else {
            throw WorkspaceError.invalidArgument(message: "Terminal session '\(sessionID)' does not exist.")
        }
        DistributedNotificationCenter.default().postNotificationName(
            IPCNotification.openTerminalSessionWindow, object: try IPCNotification.currentObject(),
            userInfo: [
                IPCNotification.terminalSessionIDUserInfoKey: sessionID,
                IPCNotification.terminalAttachmentModeUserInfoKey: TerminalAttachmentMode.owner.rawValue,
            ], options: [.deliverImmediately])
        print("Requested owner terminal window for session \(sessionID)")
    }
}

struct TerminalTakeoverCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "takeover", abstract: "Transfer terminal input ownership to a client.")

    @Argument(help: "Terminal session ID.") var sessionID: String
    @Argument(help: "Terminal client ID that should become the new owner.") var clientID: String

    func run() throws {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else {
            throw WorkspaceError.invalidArgument(message: "Terminal session '\(sessionID)' is not available.")
        }
        let response = try TerminalControlClient.send(
            request: TerminalControlRequest(command: "takeover", clientID: clientID), socketPath: paths.controlSocketPath)
        guard response.ok else { throw WorkspaceError.invalidArgument(message: response.message) }
        print("Transferred terminal ownership for session \(sessionID) to \(clientID)")
    }
}

struct TerminalProxyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "proxy", abstract: "Expose a Spaces terminal session over TCP for mobile or remote control.")

    @Argument(help: "Terminal session ID.") var sessionID: String
    @Option(name: .long, help: "TCP host to bind. Use 127.0.0.1 for local-only access.") var host = "127.0.0.1"
    @Option(name: .long, help: "TCP port to bind. Use 0 to choose an ephemeral port.") var port = 0
    @Option(name: .long, help: "Shared auth token required by remote clients.") var authToken: String

    func run() throws {
        let paths = try TerminalSessionPaths.forSession(id: sessionID)
        guard FileManager.default.fileExists(atPath: paths.controlSocketPath) else {
            throw WorkspaceError.invalidArgument(message: "Terminal session '\(sessionID)' is not available.")
        }

        let queue = DispatchQueue(label: "spaces.terminal.proxy.\(sessionID)")
        let server = TerminalControlTCPServer(host: host, port: port, authToken: authToken, queue: queue) { request in
            switch request.command {
            case "tail":
                if let clientID = request.clientID {
                    _ = try? TerminalControlClient.send(
                        request: TerminalControlRequest(command: "heartbeat", clientID: clientID), socketPath: paths.controlSocketPath)
                }
                let tailed = try TerminalOutputTail.tail(path: paths.outputPath, lineCount: max(request.lineCount ?? 40, 1))
                return TerminalControlResponse(ok: true, message: tailed)
            default: return try TerminalControlClient.send(request: request, socketPath: paths.controlSocketPath)
            }
        }
        try server.start()
        print("Terminal proxy ready\tsession=\(sessionID)\thost=\(host)\tport=\(server.listeningPort)")
        fflush(stdout)
        dispatchMain()
    }
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
        let computeHost = try orchestrator.effectiveComputeHost(workspaceID: workspace.id)
        try context.output.emit(
            text: "Workspace is running \(workspace.id)\thost=\(computeHost.displayName)",
            json: MutationResultPayload(message: "Workspace is running.", resource: updatedWorkspace))
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
        let computeHost = try orchestrator.effectiveComputeHost(workspaceID: workspace.id)
        try context.output.emit(
            text: "Workspace restarted \(workspace.id)\thost=\(computeHost.displayName)",
            json: MutationResultPayload(message: "Workspace restarted.", resource: updatedWorkspace))
    }
}

struct SignalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "signal", abstract: "Record an explicit lifecycle event for the current coding-agent terminal.",
        discussion:
            "Events are accepted from tracked Spaces terminal sessions. Set SPACES_AGENT_LABEL to override the agent row label for custom hook integrations."
    )

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
        let existingAgent = try existingAgentSignalTarget(workspaceID: workspace.id, agentContext: agentContext, orchestrator: orchestrator)
        let signalLabel = agentContext.label ?? agentSignalRuntimeLabel(agentContext: agentContext) ?? normalizedNonEmpty(existingAgent?.label)
        let canRecordSignal = existingAgent != nil || type == .`init` || (type.establishesAgentFromEvidence && normalizedNonEmpty(signalLabel) != nil)
        if !canRecordSignal {
            try context.output.emit(
                text: "Ignored agent \(type.rawValue): no active agent row\tworkspace=\(workspace.id)",
                json: MutationResultPayload(message: "Agent \(type.rawValue) ignored.", resource: ["workspaceID": workspace.id]))
            return
        }

        switch type {
        case .`init`:
            try orchestrator.registerAgentWindow(
                workspaceID: workspace.id, provider: agentContext.provider, label: signalLabel, terminalTrackingID: agentContext.terminalTrackingID,
                terminalNativeID: agentContext.terminalNativeID, codexThreadID: agentContext.codexThreadID, yabaiWindowID: agentContext.yabaiWindowID,
                status: existingAgent?.status ?? .idle, eventType: type.rawValue, eventSource: "spaces_signal",
                environmentKeys: agentContext.environmentKeys)
        case .start, .waiting, .done:
            try orchestrator.updateAgentWindowStatus(
                workspaceID: workspace.id, provider: agentContext.provider, terminalTrackingID: agentContext.terminalTrackingID,
                codexThreadID: agentContext.codexThreadID, terminalNativeID: agentContext.terminalNativeID, yabaiWindowID: agentContext.yabaiWindowID,
                label: signalLabel, status: type.status, eventType: type.rawValue, eventSource: "spaces_signal",
                environmentKeys: agentContext.environmentKeys)
        case .exit:
            guard let existingAgent else { return }
            // Exit mutates the row resolved above; runtime labels can collide with reserved launcher names
            // and are not proof that an ad-hoc session owns a configured launcher slot.
            try orchestrator.handleAgentExit(
                existingAgent, terminalNativeID: agentContext.terminalNativeID, yabaiWindowID: agentContext.yabaiWindowID, eventType: type.rawValue,
                eventSource: "spaces_signal", environmentKeys: agentContext.environmentKeys)
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

    var establishesAgentFromEvidence: Bool {
        switch self {
        case .start, .waiting, .done: true
        case .`init`, .exit: false
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
    let environmentKeys: [String]
}

func resolveAgentInvocationContext(workspaceID: String, environment: [String: String], orchestrator: WorkspaceOrchestrator, context: CLIContext)
    throws -> AgentInvocationContext?
{
    guard let resolvedProvider = resolveProvider(environment: environment) else { return nil }
    let focusedWindowID = context.currentYabaiWindowID()
    let spacesTrackingID = environment[WorkspaceOrchestrator.terminalTrackingIDEnvVar]?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trackingIdentity: TerminalTrackingIdentity? =
        if resolvedProvider == .spaces, let spacesTrackingID, !spacesTrackingID.isEmpty { .session(spacesTrackingID) } else { nil }
    let splitIdentity = splitTrackingIdentity(trackingIdentity)
    guard splitIdentity.sessionID?.isEmpty == false else { return nil }
    let terminalNativeID = splitIdentity.sessionID
    let resolvedYabaiWindowID = splitIdentity.windowID ?? focusedWindowID
    return AgentInvocationContext(
        provider: resolvedProvider, label: inferredAgentLabel(environment: environment), terminalTrackingID: splitIdentity.sessionID,
        terminalNativeID: terminalNativeID, codexThreadID: environment["CODEX_THREAD_ID"], yabaiWindowID: resolvedYabaiWindowID,
        environmentKeys: environment.keys.sorted())
}

func existingAgentSignalTarget(workspaceID: String, agentContext: AgentInvocationContext, orchestrator: WorkspaceOrchestrator) throws
    -> AgentWindowRecord?
{
    let terminalIDs = Set([agentContext.terminalTrackingID, agentContext.terminalNativeID].compactMap { normalizedNonEmpty($0) })
    let codexThreadID = normalizedNonEmpty(agentContext.codexThreadID)
    return try orchestrator.agentWindows(workspaceID: workspaceID).first { record in
        guard record.provider == agentContext.provider else { return false }
        if let recordTerminalID = normalizedNonEmpty(record.terminalTrackingID), terminalIDs.contains(recordTerminalID) { return true }
        if let codexThreadID, normalizedNonEmpty(record.codexThreadID) == codexThreadID { return true }
        return false
    }
}

func agentSignalRuntimeLabel(agentContext: AgentInvocationContext) -> String? {
    guard agentContext.provider == .spaces, let sessionID = normalizedNonEmpty(agentContext.terminalTrackingID ?? agentContext.terminalNativeID),
        let paths = try? TerminalSessionPaths.forSession(id: sessionID)
    else { return nil }
    if let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths), launchConfiguration.kind == .agent {
        return normalizedNonEmpty(launchConfiguration.title)
    }
    guard let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths), let kind = runtimeState.foregroundDetectedAgentKind
    else { return nil }
    return normalizedNonEmpty(runtimeState.foregroundDisplayLabel) ?? kind.displayLabel
}

private func normalizedNonEmpty(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let trimmed, !trimmed.isEmpty else { return nil }
    return trimmed
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
    let spacesTerminalHost = environment["SPACES_TERMINAL_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    if spacesTerminalHost == TerminalHost.spaces.rawValue { return .spaces }
    return nil
}

func agentEventDropResult(type: AgentEventType, environment: [String: String], context: CLIContext) -> (
    text: String, payload: MutationResultPayload<[String: String]>
)? {
    guard let provider = resolveProvider(environment: environment) else {
        return (
            "Dropped agent event \(type.rawValue): non-Spaces terminal",
            MutationResultPayload<[String: String]>(message: "Dropped non-Spaces agent event.", resource: nil)
        )
    }
    if provider == .spaces, environment[WorkspaceOrchestrator.terminalTrackingIDEnvVar]?.isEmpty != false {
        return (
            "Dropped agent event \(type.rawValue): untracked Spaces terminal",
            MutationResultPayload<[String: String]>(message: "Dropped untracked Spaces agent event.", resource: nil)
        )
    }
    return nil
}

private func inferredAgentLabel(environment: [String: String]) -> String? {
    if let label = environment[WorkspaceOrchestrator.agentLabelEnvVar]?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
        return label
    }
    if environment["CODEX_THREAD_ID"] != nil { return "codex cli" }
    if environment["CODEX_MANAGED_BY_NPM"] != nil { return "codex cli" }
    if environment["CLAUDE_CODE_ENTRYPOINT"] != nil { return "claude cli" }
    if environment.keys.contains(where: { $0.uppercased().hasPrefix("OPENCODE") }) { return "opencode cli" }

    return nil
}

private func agentProvider(for terminalApp: String?) -> AgentProvider? {
    switch terminalApp {
    case TerminalHost.spaces.appName: return .spaces
    default: return nil
    }
}

private func splitTrackingIdentity(_ identity: TerminalTrackingIdentity?) -> (sessionID: String?, windowID: Int?) {
    switch identity {
    case .session(let id): return (id, nil)
    case .window(let id): return (nil, id)
    case nil: return (nil, nil)
    }
}

private func terminalShellPath(_ explicitPath: String?) -> String {
    if let explicitPath = explicitPath?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitPath.isEmpty { return explicitPath }
    if let configured = ProcessInfo.processInfo.environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
        return configured
    }
    return "/bin/zsh"
}

private func terminalDefaultTitle(command: String?, cwd: String) -> String {
    if let command = command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty { return command }
    let name = URL(fileURLWithPath: cwd).lastPathComponent
    return name.isEmpty ? "Terminal" : name
}
