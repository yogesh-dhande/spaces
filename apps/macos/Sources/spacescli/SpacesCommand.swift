import ArgumentParser
import Dispatch
import Foundation
import spacesdeviceapi
import spacesdevicecore
import spacesterminalcore
import spacesterminalghostty
import workspacecore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

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
              - Workspace and agent commands require explicit IDs.
              - `workspace create` targets this device's spacesd daemon.
              - `workspace start` waits for pending/running setup to complete and fails with the setup error if setup failed. It ensures a workspace and all its processes are running: launches when stopped; when already running, restarts any exited processes. Windows open without activating the app.
              - `workspace restart` forces a full stop and relaunch for a workspace.
              - Agent events stay explicit. Workspace runtime commands do not imply agent lifecycle. `agent signal <event>` records those lifecycle transitions for an explicit workspace and terminal session.
            """, version: AppVersion.current,
        subcommands: [
            ProjectCommand.self, WorkspaceCommand.self, AgentCommand.self, TerminalCommand.self, PairCommand.self, MobileCommand.self,
            MCPCommand.self,
        ])

    public init() {}
}

struct ProjectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "project", abstract: "Manage Spaces projects.", subcommands: [ProjectListCommand.self])
}

struct ProjectListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List projects.")

    func run() throws {
        let context = CLIContext()
        let projects = try TerminalService.sendProfileCommand(.init(operation: .projectList)).projects ?? []
        context.output.emitLines(projects.map { "\($0.id)\tname=\($0.name)\tdir=\($0.dir)" })
    }
}

struct WorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace", abstract: "Manage Spaces workspaces.",
        subcommands: [WorkspaceListCommand.self, WorkspaceCreateCommand.self, WorkspaceStartCommand.self, WorkspaceRestartCommand.self])
}

struct WorkspaceListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List workspaces.")

    @Option(name: .long, help: "Project ID. When omitted, lists workspaces from every project.") var project: String?
    @Flag(name: .long, help: "Include archived workspaces.") var includeArchived = false

    func run() throws {
        let context = CLIContext()
        let workspaces =
            try TerminalService.sendProfileCommand(.init(operation: .workspaceList, projectID: project, includeArchived: includeArchived)).workspaces
            ?? []
        context.output.emitLines(
            workspaces.map { "\($0.id)\tproject=\($0.projectID)\tbranch=\($0.branch ?? "-")\trunning=\($0.isRunning)\ttitle=\($0.title)" })
    }
}

struct WorkspaceCreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a workspace on this device.")

    @Option(name: .long, help: "Project ID.") var project: String
    @Option(name: .long, help: "Workspace branch.") var branch: String
    @Option(name: .long, help: "Workspace title. Defaults to the branch name.") var title: String?
    @Option(name: .long, help: "Base branch for new branch creation.") var baseBranch: String?
    @Flag(name: .long, help: "Use an existing branch instead of creating a new branch.") var existingBranch = false

    func run() throws {
        let context = CLIContext()
        let workspace = try requireProfileWorkspace(
            try TerminalService.sendProfileCommand(
                .init(
                    operation: .workspaceCreate, projectID: project, branch: branch, title: title, baseBranch: baseBranch,
                    existingBranch: existingBranch)))
        context.output.emit("Created workspace \(workspace.id)\tproject=\(workspace.projectID)\tbranch=\(workspace.branch ?? "-")")
    }
}

struct WorkspaceStartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Ensure a workspace is running.")

    @Option(name: .long, help: "Workspace ID.") var workspace: String

    func run() throws {
        let context = CLIContext()
        _ = try requireProfileWorkspace(try TerminalService.sendProfileCommand(.init(operation: .workspaceStart, workspaceID: workspace)))
        context.output.emit("Workspace is running \(workspace)")
    }
}

struct WorkspaceRestartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restart", abstract: "Force a full stop and relaunch for a workspace.")

    @Option(name: .long, help: "Workspace ID.") var workspace: String

    func run() throws {
        let context = CLIContext()
        _ = try requireProfileWorkspace(try TerminalService.sendProfileCommand(.init(operation: .workspaceRestart, workspaceID: workspace)))
        context.output.emit("Workspace restarted \(workspace)")
    }
}

struct AgentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent", abstract: "Manage coding-agent lifecycle state.", subcommands: [AgentSignalCommand.self])
}

struct AgentSignalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "signal", abstract: "Record a lifecycle event for an explicit terminal session.")

    @Option(name: .long, help: "Workspace ID.") var workspace: String
    @Option(name: .long, help: "Spaces terminal session ID.") var session: String
    @Argument(
        help: ArgumentHelp("Lifecycle event to record.", discussion: "Allowed values: \(AgentEventType.allValueStrings.joined(separator: ", "))."))
    var type: AgentEventType

    func run() throws {
        let context = CLIContext()
        _ = try TerminalService.sendProfileCommand(
            .init(operation: .agentSignal, workspaceID: workspace, terminalSessionID: session, agentEvent: type.rawValue))
        context.output.emit("Agent \(type.rawValue): workspace=\(workspace)")
    }
}

struct MCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Run the Spaces MCP stdio server.")

    func run() throws { try SpacesMCPStdioServer().run() }
}

struct PairCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pair", abstract: "Open a pairing window for this device's spacesd daemon.")

    @Flag(name: .long, help: "Print structured pairing metadata for SSH-assisted Mac pairing.") var json = false

    func run() throws { if json { try emitPairCommandJSON() } else { for line in try pairCommandLines() { print(line) } } }
}

struct PairingWindowPayload: Codable, Sendable, Equatable {
    let name: String
    let host: String
    let port: Int
    let pairingNonce: String
    let pairingCode: String
    let transportKey: String
    let certificateFingerprint: String
    let expiresAt: String
    let pairingLink: String
}

func pairCommandLines(
    loadControlResponse: () throws -> SpacesDeviceAPIControlResponse = {
        try SpacesDeviceAPIControlClient.openPairingWindowEnsuringCurrentTerminalService()
    }
) throws -> [String] {
    let response = try loadControlResponse()
    guard response.ok else { throw WorkspaceError.invalidArgument(message: response.message) }
    guard let window = response.pairingWindow else { throw WorkspaceError.invalidArgument(message: "spacesd did not return a pairing window.") }
    return pairingWindowLines(window)
}

func pairCommandPayload(
    loadControlResponse: () throws -> SpacesDeviceAPIControlResponse = {
        try SpacesDeviceAPIControlClient.openPairingWindowEnsuringCurrentTerminalService()
    }
) throws -> PairingWindowPayload {
    let response = try loadControlResponse()
    guard response.ok else { throw WorkspaceError.invalidArgument(message: response.message) }
    guard let window = response.pairingWindow else { throw WorkspaceError.invalidArgument(message: "spacesd did not return a pairing window.") }
    return try pairingWindowPayload(window)
}

func pairingWindowLines(_ window: SpacesDevicePairingWindowSnapshot) -> [String] {
    [
        "Spaces pairing window", "link=\(window.linkString)", "code=\(window.code)",
        "expires_at=\(ISO8601DateFormatter().string(from: window.expiresAt))",
    ]
}

func pairingWindowPayload(_ window: SpacesDevicePairingWindowSnapshot) throws -> PairingWindowPayload {
    let link = try SpacesDevicePairingLink.parse(window.linkString)
    return PairingWindowPayload(
        name: link.name, host: link.host, port: link.port, pairingNonce: link.nonce, pairingCode: link.code, transportKey: link.transportKey,
        certificateFingerprint: link.certificateFingerprint, expiresAt: ISO8601DateFormatter().string(from: window.expiresAt),
        pairingLink: window.linkString)
}

private func emitPairCommandJSON() throws {
    let payload = try pairCommandPayload()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(payload)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

private func requireProfileWorkspace(_ response: TerminalServiceProfileCommandResponse) throws -> TerminalServiceProfileWorkspaceRecord {
    guard let workspace = response.workspace else { throw ValidationError("spacesd did not return a workspace.") }
    return workspace
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
        let sessions = try TerminalService.sendProfileCommand(.init(operation: .terminalList), timeout: 5).terminalSessions ?? []
        let rows = terminalSessionRows(sessions)
        if rows.isEmpty {
            print("No terminal sessions.")
            return
        }

        for row in rows { print(row) }
    }
}

func terminalSessionRows(_ sessions: [TerminalServiceSessionSummary]) -> [String] {
    sessions.map { session in "\(session.id)\tstate=\(session.state.rawValue)\tcwd=\(session.workingDirectory)" }
}

func availableTerminalSessionRows(fileManager: FileManager = .default) throws -> [String] {
    try TerminalSessionCatalog.listLiveSessions(fileManager: fileManager).map {
        "\($0.sessionID)\tstate=\($0.runtimeState.state.rawValue)\tcwd=\($0.effectiveWorkingDirectory)"
    }
}

struct TerminalCommandCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "command", abstract: "Start a terminal session in the background.")

    @Option(name: .long, help: "Shell command to run inside the terminal session. If omitted, starts a login shell.") var command: String?

    @Option(name: .long, help: "Window or session title to track.") var title: String?

    @Option(name: .long, help: "Working directory. Defaults to the current directory.") var cwd: String?

    @Option(name: .long, help: "Shell executable path. Defaults to $SHELL or the platform login shell.") var shell: String?

    @Option(name: .long, help: "Terminal backend. Defaults to ghostty-embedded.") var backend: TerminalSessionBackendKind = .ghosttyEmbedded

    func run() throws {
        guard TerminalSessionBackendSupport.isSupported(backend) else {
            throw WorkspaceError.invalidArgument(message: "Terminal backend '\(backend.rawValue)' is not available in this build.")
        }
        let context = CLIContext()
        let launchConfiguration = terminalCommandLaunchConfiguration(
            sessionID: UUID().uuidString, backend: backend, command: command, title: title, cwd: cwd, shell: shell, context: context)
        let session = try TerminalService.createSession(launchConfiguration)

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
        #if os(macOS)
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            guard (try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths)) != nil else {
                throw WorkspaceError.invalidArgument(message: "Terminal session '\(sessionID)' does not exist.")
            }
            let requestID = UUID().uuidString
            try postCLIIPCNotification(
                name: IPCNotification.openTerminalSessionWindow,
                userInfo: [
                    IPCNotification.terminalSessionIDUserInfoKey: sessionID,
                    IPCNotification.terminalAttachmentModeUserInfoKey: TerminalAttachmentMode.owner.rawValue,
                    IPCNotification.focusRequestIDUserInfoKey: requestID,
                ])
            print("Requested owner terminal window for session \(sessionID)")
        #else
            throw WorkspaceError.invalidArgument(message: "Native Spaces terminal windows are only available on macOS.")
        #endif
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
        FileHandle.standardOutput.write(Data("Terminal proxy ready\tsession=\(sessionID)\thost=\(host)\tport=\(server.listeningPort)\n".utf8))
        dispatchMain()
    }
}

struct MobileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mobile", abstract: "Inspect the same-machine Spaces Device API.", subcommands: [MobileStatusCommand.self],
        defaultSubcommand: MobileStatusCommand.self)
}

struct MobileStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show the same-machine Spaces Device API address.")

    func run() throws { for line in try mobileStatusLines() { print(line) } }
}

func mobileStatusLines(
    loadControlResponse: () throws -> SpacesDeviceAPIControlResponse = { try SpacesDeviceAPIControlClient.statusEnsuringCurrentTerminalService() }
) throws -> [String] {
    let response = try loadControlResponse()
    guard response.ok else { throw WorkspaceError.invalidArgument(message: response.message) }
    guard let status = response.status else {
        throw WorkspaceError.invalidArgument(message: "Device API status response did not include address details.")
    }
    return mobileStatusLines(status: status)
}

func mobileStatusLines(status: SpacesDeviceAPIStatus) -> [String] {
    var lines = [
        "Spaces Device API", "port=\(status.port)", "bonjour=\(status.bonjourServiceName)\ttype=\(status.bonjourServiceType)",
        "fingerprint=\(status.certificateFingerprint)",
    ]
    if status.networkAddresses.isEmpty {
        lines.append("addresses=(none)")
    } else {
        lines.append("addresses=\(status.networkAddresses.map { "\($0):\(status.port)" }.joined(separator: ","))")
    }
    lines.append("pair=Run `spaces pair` to show iOS pairing details, or `spaces pair --json` for SSH-assisted Mac pairing.")
    return lines
}

enum AgentEventType: String, CaseIterable, ExpressibleByArgument {
    case `init` = "init"
    case working = "working"
    case blocked = "blocked"
    case done = "done"
    case exit = "exit"

    static let allValueStrings = allCases.map(\.rawValue)

    var status: AgentWindowStatus {
        switch self {
        case .`init`: .idle
        case .working: .spinning
        case .blocked: .waiting
        case .done: .done
        case .exit: .idle
        }
    }
}

private func terminalShellPath(_ explicitPath: String?) -> String {
    if let explicitPath = explicitPath?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitPath.isEmpty { return explicitPath }
    if let configured = ProcessInfo.processInfo.environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines), !configured.isEmpty {
        return configured
    }
    #if os(Linux)
        return "/bin/bash"
    #else
        return "/bin/zsh"
    #endif
}

private func terminalDefaultTitle(command: String?, cwd: String) -> String {
    if let command = command?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty { return command }
    let name = URL(fileURLWithPath: cwd).lastPathComponent
    return name.isEmpty ? "Terminal" : name
}

#if os(macOS)
    private func postCLIIPCNotification(name: Notification.Name, userInfo: [String: String]? = nil) throws {
        try IPCNotification.post(name, userInfo: userInfo)
    }
#endif
