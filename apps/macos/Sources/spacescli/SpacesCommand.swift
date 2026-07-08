import ArgumentParser
import Foundation
import spacesclientcore
import spacesdeviceapi
import spacesdevicecore
import spacesterminalcore
import workspacecore

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
        subcommands: [ProjectCommand.self, WorkspaceCommand.self, AgentCommand.self, TerminalCommand.self, DeviceCommand.self, MCPCommand.self])

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
        let projects = try TerminalService.sendProfileCommand(.projectList).projects ?? []
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
            try TerminalService.sendProfileCommand(.workspaceList(.init(projectID: project, includeArchived: includeArchived))).workspaces ?? []
        context.output.emitLines(
            workspaces.map { "\($0.id)\tproject=\($0.projectID)\tbranch=\($0.branch ?? "-")\trunning=\($0.isRunning)\tname=\($0.displayName)" })
    }
}

struct WorkspaceCreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a workspace on this device.")

    @Option(name: .long, help: "Project ID.") var project: String
    @Option(name: .long, help: "Workspace branch.") var branch: String
    @Option(name: .long, help: "Base branch for new branch creation.") var baseBranch: String?
    @Flag(name: .long, help: "Use an existing branch instead of creating a new branch.") var existingBranch = false

    func run() throws {
        let context = CLIContext()
        let workspace = try requireProfileWorkspace(
            try TerminalService.sendProfileCommand(
                .workspaceCreate(.init(projectID: project, branch: branch, baseBranch: baseBranch, existingBranch: existingBranch))))
        context.output.emit("Created workspace \(workspace.id)\tproject=\(workspace.projectID)\tbranch=\(workspace.branch ?? "-")")
    }
}

struct WorkspaceStartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Ensure a workspace is running.")

    @Option(name: .long, help: "Workspace ID.") var workspace: String

    func run() throws {
        let context = CLIContext()
        _ = try requireProfileWorkspace(try TerminalService.sendProfileCommand(.workspaceStart(workspaceID: workspace)))
        context.output.emit("Workspace is running \(workspace)")
    }
}

struct WorkspaceRestartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "restart", abstract: "Force a full stop and relaunch for a workspace.")

    @Option(name: .long, help: "Workspace ID.") var workspace: String

    func run() throws {
        let context = CLIContext()
        _ = try requireProfileWorkspace(try TerminalService.sendProfileCommand(.workspaceRestart(workspaceID: workspace)))
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
        _ = try TerminalService.sendProfileCommand(.agentSignal(.init(workspaceID: workspace, terminalSessionID: session, event: type.rawValue)))
        context.output.emit("Agent \(type.rawValue): workspace=\(workspace)")
    }
}

struct MCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Run the Spaces MCP stdio server.")

    func run() throws { try SpacesMCPStdioServer().run() }
}

struct PairingWindowPayload: Codable, Sendable, Equatable {
    let name: String
    let host: String
    let port: Int
    let pairingNonce: String
    let pairingCode: String
    let certificateFingerprint: String
    let expiresAt: String
    let pairingLink: String
    let protocolVersion: Int
    let appVersion: String
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
        name: link.name, host: link.host, port: link.port, pairingNonce: link.nonce, pairingCode: link.code,
        certificateFingerprint: link.certificateFingerprint, expiresAt: ISO8601DateFormatter().string(from: window.expiresAt),
        pairingLink: window.linkString, protocolVersion: link.protocolVersion, appVersion: link.appVersion)
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

struct DeviceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "device", abstract: "Manage paired devices.",
        subcommands: [DeviceListCommand.self, DevicePairCommand.self, DeviceRemoveCommand.self])
}

struct DeviceListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List paired devices.")

    func run() throws {
        let devices = try SpacesClientDatabase.defaultDatabase().pairedDevices()
        guard !devices.isEmpty else {
            print("No paired devices.")
            return
        }
        print(SpacesPairedDeviceSelection.deviceRows(devices))
    }
}

struct DevicePairCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pair", abstract: "Open a pairing window for this device, or pair this client with another device.",
        discussion: """
            With no source, opens a pairing window on this device's spacesd daemon and prints its
            spaces://pair link (use --json for machine-readable metadata).

            Provide a source to pair this client with another device:
              --ssh user@host   SSH sugar: fetches the target's pairing link over SSH, then redeems it.
              --link <link>     Redeems a spaces://pair link printed by `spaces device pair` on the target device.
            """)

    @Option(name: .long, help: "SSH destination (user@host or host) of the device to pair.") var ssh: String?
    @Option(name: .long, help: "SSH port. Defaults to 22.") var sshPort: Int?
    @Option(name: .long, help: "A spaces://pair link from the target device's pairing window.") var link: String?
    @Flag(name: .long, help: "When opening a pairing window, print structured metadata for SSH-assisted pairing.") var json = false

    func validate() throws {
        if ssh != nil, link != nil { throw ValidationError("Provide at most one of --ssh or --link.") }
        if ssh == nil, sshPort != nil { throw ValidationError("--ssh-port requires --ssh.") }
        if json, ssh != nil || link != nil { throw ValidationError("--json only applies when opening a pairing window (omit --ssh and --link).") }
    }

    func run() throws {
        // No source: open a pairing window on this device's daemon (the target of an SSH or link pair).
        if ssh == nil, link == nil {
            if json { try emitPairCommandJSON() } else { for line in try pairCommandLines() { print(line) } }
            return
        }
        let result: SpacesRemoteDevicePairingResult
        if let ssh {
            let (sshUser, sshHost) = Self.parsedSSHDestination(ssh)
            result = try SpacesDevicePairingClient.pairRemoteDevice(
                SpacesRemoteDevicePairingRequest(
                    sshHost: sshHost, sshUser: sshUser, sshPort: sshPort,
                    clientInstallationID: SpacesDevicePairingClient.localMacClientInstallationID(),
                    clientBundleID: SpacesDeviceFirstPartyPolicy.macOSBundleID, clientDeviceName: cliDeviceName(), clientAppVersion: AppVersion.short)
            )
        } else {
            let parsedLink = try SpacesDevicePairingLink.parse(link ?? "")
            result = try SpacesDevicePairingClient.pairDevice(
                link: parsedLink, clientInstallationID: SpacesDevicePairingClient.localMacClientInstallationID(),
                clientBundleID: SpacesDeviceFirstPartyPolicy.macOSBundleID, clientDeviceName: cliDeviceName(), clientAppVersion: AppVersion.short)
        }
        print("Paired \(result.name)\tid=\(result.deviceID)\tendpoint=\(result.host):\(result.port)")
    }

    static func parsedSSHDestination(_ value: String) -> (user: String?, host: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let atIndex = trimmed.firstIndex(of: "@"), atIndex != trimmed.startIndex else { return (nil, trimmed) }
        return (String(trimmed[trimmed.startIndex..<atIndex]), String(trimmed[trimmed.index(after: atIndex)...]))
    }
}

struct DeviceRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove a paired device and its stored credential.")

    @Argument(help: "Paired device name or ID.") var device: String

    func run() throws {
        let record = try SpacesPairedDeviceSelection.resolve(device)
        try SpacesClientDatabase.defaultDatabase().deletePairedDevice(id: record.id)
        try SpacesDeviceCredentialStore.deleteToken(deviceID: record.id)
        print("Removed paired device \(record.name) (\(record.id))")
    }
}

struct TerminalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "terminal", abstract: "Manage Spaces terminal sessions.",
        subcommands: [
            TerminalListCommand.self, TerminalCommandCommand.self, TerminalSendCommand.self, TerminalTailCommand.self, TerminalShowCommand.self,
        ])
}

struct TerminalListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List available Spaces terminal sessions.")

    @Option(name: .long, help: "Paired device name or ID. Defaults to this machine's local sessions.") var device: String?

    func run() throws {
        let rows: [String]
        if let device {
            let record = try SpacesPairedDeviceSelection.resolve(device)
            let sessions = try SpacesDeviceClient.terminalSessions(device: record, clientApp: cliDeviceClientApp())
            rows = sessions.map { "\($0.id)\tstate=\($0.state.rawValue)\tcwd=\($0.workingDirectory)" }
        } else {
            let sessions = try TerminalService.sendProfileCommand(.terminalList, timeout: 5).terminalSessions ?? []
            rows = terminalSessionRows(sessions)
        }
        if rows.isEmpty {
            print("No terminal sessions.")
            return
        }

        for row in rows { print(row) }
    }
}

/// The CLI presents the same per-profile client identity as the GUI app, so a device paired from
/// either surface is usable from both.
func cliDeviceClientApp() -> SpacesDeviceClientApp { SpacesDeviceClient.macOSClientApp(deviceName: cliDeviceName(), appVersion: AppVersion.short) }

func cliDeviceName() -> String {
    #if os(macOS)
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    #else
        ProcessInfo.processInfo.hostName
    #endif
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
    static let configuration = CommandConfiguration(commandName: "command", abstract: "Start a background terminal session in a workspace.")

    @Option(name: .long, help: "Workspace ID. Defaults to the workspace containing the current directory.") var workspace: String?

    @Option(name: .long, help: "Shell command to run inside the terminal session. If omitted, starts a login shell.") var command: String?

    @Option(name: .long, help: "Window or session title to track.") var title: String?

    func run() throws {
        let context = CLIContext()
        // This RPC synchronously launches the terminal session (Ghostty spawn, workspace setup),
        // unlike other profile commands' quick metadata reads/writes, so it needs the same
        // SPACESD_CREATE_TIMEOUT-configurable budget as the old direct TerminalService.createSession
        // path — the default 15s profile-command timeout can trip before a slow launch finishes,
        // even though the daemon keeps creating the session in the background.
        let response = try TerminalService.sendProfileCommand(
            .terminalCommand(.init(cwd: context.currentDirectoryPath(), workspaceID: workspace, command: command, title: title)),
            timeout: TerminalService.createSessionRequestTimeout())
        guard let session = response.terminalSession else {
            throw WorkspaceError.invalidArgument(message: "spacesd did not return a terminal session.")
        }
        context.output.emit(
            "Started terminal session \(session.id)\ttitle=\(session.title)\tbackend=\(session.backend.rawValue)\tlocation=local\tcwd=\(session.workingDirectory)"
        )
    }
}

struct TerminalSendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send", abstract: "Send text or raw bytes to a Spaces terminal session.",
        subcommands: [TerminalSendTextCommand.self, TerminalSendBytesCommand.self])
}

struct TerminalSendTextCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "text", abstract: "Send UTF-8 text to a Spaces terminal session.")

    @Argument(help: "Terminal session ID.") var sessionID: String
    @Argument(help: "Text to send.") var text: String
    @Flag(name: .long, help: "Append a newline after the text.") var newline = false
    @Option(name: .long, help: "Paired device name or ID. Defaults to this machine's local sessions.") var device: String?

    func run() throws { try sendTerminalInput(.text(text), sessionID: sessionID, appendNewline: newline, device: device) }
}

struct TerminalSendBytesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "bytes", abstract: "Send decimal byte values to a Spaces terminal session.")

    @Argument(help: "Terminal session ID.") var sessionID: String
    @Argument(help: "Decimal byte value from 0 through 255.") var byte: TerminalByteArgument
    @Argument(help: "Additional decimal byte values from 0 through 255.") var additionalBytes: [TerminalByteArgument] = []
    @Option(name: .long, help: "Paired device name or ID. Defaults to this machine's local sessions.") var device: String?

    var bytes: [TerminalByteArgument] { [byte] + additionalBytes }

    func run() throws { try sendTerminalInput(.bytes(Data(bytes.map(\.value))), sessionID: sessionID, appendNewline: false, device: device) }
}

struct TerminalByteArgument: ExpressibleByArgument, Equatable {
    let value: UInt8

    init?(argument: String) {
        guard !argument.isEmpty, argument.allSatisfy(\.isNumber), let intValue = Int(argument), (0...255).contains(intValue) else { return nil }
        value = UInt8(intValue)
    }
}

private func sendTerminalInput(_ input: TerminalProfileInput, sessionID: String, appendNewline: Bool, device: String?) throws {
    if let device {
        let record = try SpacesPairedDeviceSelection.resolve(device)
        let text: String?
        let bytes: Data?
        switch input {
        case .text(let value): (text, bytes) = (value, nil)
        case .bytes(let value): (text, bytes) = (nil, value)
        }
        _ = try SpacesDeviceClient.sendTerminalInput(
            sessionID: sessionID, text: text, bytes: bytes, appendNewline: appendNewline, device: record, clientApp: cliDeviceClientApp())
        print("Sent input to terminal session \(sessionID) on \(record.name)")
        return
    }
    _ = try TerminalService.sendProfileCommand(.terminalSend(.init(sessionID: sessionID, input: input, appendNewline: appendNewline)), timeout: 5)
    print("Sent input to terminal session \(sessionID)")
}

struct TerminalTailCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tail", abstract: "Show recent output from a Spaces terminal session.")

    @Argument(help: "Terminal session ID.") var sessionID: String
    @Option(name: .long, help: "Number of lines to print.") var lines: Int = 20
    @Option(name: .long, help: "Paired device name or ID. Defaults to this machine's local sessions.") var device: String?

    func run() throws {
        if let device {
            let record = try SpacesPairedDeviceSelection.resolve(device)
            print(try SpacesDeviceClient.tailTerminalOutput(sessionID: sessionID, lines: lines, device: record, clientApp: cliDeviceClientApp()))
            return
        }
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

#if os(macOS)
    private func postCLIIPCNotification(name: Notification.Name, userInfo: [String: String]? = nil) throws {
        try IPCNotification.post(name, userInfo: userInfo)
    }
#endif
