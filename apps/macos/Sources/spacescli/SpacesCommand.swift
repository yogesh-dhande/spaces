import ArgumentParser
import Darwin
import Dispatch
import Foundation
import spacesmobilebridge
import spacesmobilecore
import spacesterminalcore
import spacesterminalghostty
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
              - Workspace and agent commands require explicit IDs.
              - `workspace create` requires project, branch, and host so workspace identity is host-scoped.
              - `workspace start` waits for pending/running setup to complete and fails with the setup error if setup failed. It ensures a workspace and all its processes are running: launches when stopped; when already running, restarts any exited processes. Windows open without activating the app.
              - `workspace restart` forces a full stop and relaunch for a workspace.
              - Agent events stay explicit. Workspace runtime commands do not imply agent lifecycle. `agent signal <event>` records those lifecycle transitions for an explicit workspace and terminal session.
            """, version: AppVersion.current,
        subcommands: [ProjectCommand.self, WorkspaceCommand.self, AgentCommand.self, TerminalCommand.self, MobileCommand.self, MCPCommand.self])

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
        try context.output.emitLines(text: projects.map { "\($0.id)\tname=\($0.name)\tdir=\($0.dir)" }, json: projects)
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
        try context.output.emitLines(
            text: workspaces.map {
                "\($0.id)\tproject=\($0.projectID)\thost=\($0.hostID)\tbranch=\($0.branch ?? "-")\trunning=\($0.isRunning)\ttitle=\($0.title)"
            }, json: workspaces)
    }
}

struct WorkspaceCreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create an explicit host-scoped workspace.")

    @Option(name: .long, help: "Project ID.") var project: String
    @Option(name: .long, help: "Workspace branch.") var branch: String
    @Option(name: .long, help: "Host ID, or local for the Mac.") var host: String
    @Option(name: .long, help: "Workspace title. Defaults to the branch name.") var title: String?
    @Option(name: .long, help: "Target branch for new branch creation.") var targetBranch: String?
    @Flag(name: .long, help: "Use an existing branch instead of creating a new branch.") var existingBranch = false

    func run() throws {
        let context = CLIContext()
        let workspace = try requireProfileWorkspace(
            try TerminalService.sendProfileCommand(
                .init(
                    operation: .workspaceCreate, projectID: project, branch: branch, hostID: host, title: title, targetBranch: targetBranch,
                    existingBranch: existingBranch)))
        try context.output.emit(
            text: "Created workspace \(workspace.id)\tproject=\(workspace.projectID)\thost=\(workspace.hostID)\tbranch=\(workspace.branch ?? "-")",
            json: MutationResultPayload(message: "Created workspace.", resource: workspace))
    }
}

struct WorkspaceStartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Ensure a workspace is running.")

    @Option(name: .long, help: "Workspace ID.") var workspace: String

    func run() throws {
        let context = CLIContext()
        let updated = try requireProfileWorkspace(try TerminalService.sendProfileCommand(.init(operation: .workspaceStart, workspaceID: workspace)))
        try context.output.emit(
            text: "Workspace is running \(workspace)\thost=\(updated.hostID)",
            json: MutationResultPayload(message: "Workspace is running.", resource: updated))
    }
}

struct WorkspaceRestartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restart", abstract: "Force a full stop and relaunch for a workspace.")

    @Option(name: .long, help: "Workspace ID.") var workspace: String

    func run() throws {
        let context = CLIContext()
        let updated = try requireProfileWorkspace(try TerminalService.sendProfileCommand(.init(operation: .workspaceRestart, workspaceID: workspace)))
        try context.output.emit(
            text: "Workspace restarted \(workspace)\thost=\(updated.hostID)",
            json: MutationResultPayload(message: "Workspace restarted.", resource: updated))
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
        let response = try TerminalService.sendProfileCommand(
            .init(operation: .agentSignal, workspaceID: workspace, terminalSessionID: session, agentEvent: type.rawValue))
        try context.output.emit(
            text: "Agent \(type.rawValue): workspace=\(workspace)",
            json: MutationResultPayload(
                message: response.message, resource: ["workspaceID": workspace, "sessionID": session, "status": type.status.rawValue]))
    }
}

struct MCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Run the Spaces MCP stdio server.")

    func run() throws { try SpacesMCPStdioServer().run() }
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
        let requestID = UUID().uuidString
        DistributedNotificationCenter.default().postNotificationName(
            IPCNotification.openTerminalSessionWindow, object: try IPCNotification.currentObject(),
            userInfo: [
                IPCNotification.terminalSessionIDUserInfoKey: sessionID,
                IPCNotification.terminalAttachmentModeUserInfoKey: TerminalAttachmentMode.owner.rawValue,
                IPCNotification.focusRequestIDUserInfoKey: requestID,
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

struct MobileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mobile", abstract: "Expose first-party workspace and terminal browsing for the iOS client.",
        subcommands: [MobileStatusCommand.self, MobileServeCommand.self], defaultSubcommand: MobileStatusCommand.self)
}

struct MobileStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show the first-party mobile bridge address.")

    func run() throws { for line in try mobileStatusLines() { print(line) } }
}

func mobileStatusLines(
    loadControlResponse: () throws -> SpacesMobileBridgeControlResponse = {
        try SpacesMobileBridgeControlClient.statusEnsuringCurrentTerminalService()
    }
) throws -> [String] {
    let response = try loadControlResponse()
    guard response.ok else { throw WorkspaceError.invalidArgument(message: response.message) }
    guard let status = response.status else {
        throw WorkspaceError.invalidArgument(message: "Mobile bridge status response did not include address details.")
    }
    return mobileStatusLines(status: status)
}

func mobileStatusLines(status: SpacesMobileBridgeStatus) -> [String] {
    var lines = ["Spaces mobile bridge", "port=\(status.port)", "bonjour=\(status.bonjourServiceName)\ttype=\(status.bonjourServiceType)"]
    if status.networkAddresses.isEmpty {
        lines.append("addresses=(none)")
    } else {
        lines.append("addresses=\(status.networkAddresses.map { "\($0):\(status.port)" }.joined(separator: ","))")
    }
    lines.append("iphone=Open Mobile Connection in the Mac app to show a QR code to scan with the Spaces iOS app.")
    return lines
}

struct MobileServeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "serve", abstract: "Run a standalone first-party mobile bridge for the iOS client.")

    @Option(name: .long, help: "TCP host to bind. Defaults to all IPv4 interfaces for iPhone and simulator access.") var host =
        SpacesMobileBridgeDefaults.host
    @Option(name: .long, help: "TCP port to bind. Defaults to the stable first-party mobile bridge port.") var port = SpacesMobileBridgeDefaults.port
    @Option(name: .long, help: "One-time pairing code accepted by the first-party iOS client. Defaults to a generated 8-digit code.") var pairingCode:
        String?
    @Option(name: .long, help: "Number of one-time pairing windows to emit in standalone harness mode.") var pairingWindowCount = 1

    func run() throws {
        guard pairingWindowCount > 0 else { throw ValidationError("--pairing-window-count must be greater than zero.") }
        let trimmedPairingCode = pairingCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPairingCode =
            if let trimmedPairingCode, !trimmedPairingCode.isEmpty { trimmedPairingCode } else {
                SpacesMobilePairingCoordinator.generatePairingCode()
            }
        let transportKey = SpacesMobileBridgeSettings.generateTransportKey()
        let pairingWindowEmitter = MobileServePairingWindowEmitter(
            bindHost: host, totalWindowCount: pairingWindowCount, firstPairingCode: resolvedPairingCode)
        let server = try SpacesMobileBridgeServer(host: host, port: port, transportKey: transportKey) { _ in
            pairingWindowEmitter.openNextWindow(label: "Spaces mobile pairing window")
        }
        pairingWindowEmitter.server = server
        try server.start()
        pairingWindowEmitter.linkHost = mobileServePairingLinkHost(host: host)
        pairingWindowEmitter.openNextWindow(label: "Spaces mobile bridge ready")
        withExtendedLifetime(server) { dispatchMain() }
    }
}

private final class MobileServePairingWindowEmitter: @unchecked Sendable {
    weak var server: SpacesMobileBridgeServer?
    var linkHost = SpacesMobileBridgeDefaults.loopbackHost

    private let lock = NSLock()
    private let bindHost: String
    private let totalWindowCount: Int
    private var emittedWindowCount = 0
    private var nextPairingCode: String?

    init(bindHost: String, totalWindowCount: Int, firstPairingCode: String) {
        self.bindHost = bindHost
        self.totalWindowCount = totalWindowCount
        nextPairingCode = firstPairingCode
    }

    func openNextWindow(label: String) {
        lock.lock()
        guard emittedWindowCount < totalWindowCount, let server else {
            lock.unlock()
            return
        }
        emittedWindowCount += 1
        let code = nextPairingCode ?? SpacesMobilePairingCoordinator.generatePairingCode()
        nextPairingCode = nil
        lock.unlock()

        let window = server.openPairingWindow(host: linkHost, name: "Spaces Standalone", code: code)
        print(
            "\(label)\thost=\(bindHost)\tport=\(server.listeningPort)\tpairing_link=\(window.linkString)\tpairing_code=\(window.code)\texpires_at=\(ISO8601DateFormatter().string(from: window.expiresAt))\tbundle=\(SpacesMobileFirstPartyPolicy.allowedBundleID)"
        )
        fflush(stdout)
    }
}

func mobileServePairingLinkHost(host: String) -> String { SpacesMobileBridgeNetworkInterfaces.pairingLinkHost(boundHost: host) }

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
