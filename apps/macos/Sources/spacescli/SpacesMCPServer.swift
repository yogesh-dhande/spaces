import Foundation
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import workspacecore

final class SpacesMCPStdioServer {
    /// A tool handler's result: either the shared local-daemon wire envelope (every non-agent-session
    /// tool, and the agent tools that don't carry rows), or the agent-session presentation envelope
    /// (`spaces_agent_list`/`spaces_agent_status`/`spaces_agent_annotate`). Two cases instead of widening
    /// `TerminalServiceProfileCommandResponse` itself: that type is the shared wire response for every
    /// tool in this server, not just agent ones, so adding a presentation-only field to it would ripple
    /// into every other tool's JSON shape. Both cases flow through the same encode/piggyback chokepoints
    /// below so every tool, agent or not, is handled identically apart from its payload type.
    private enum MCPToolResponse {
        case profile(TerminalServiceProfileCommandResponse)
        case agentSessions(MCPAgentSessionsToolResponse)
    }

    /// JSON envelope for the agent-session-carrying tools, mirroring `TerminalServiceProfileCommandResponse`'s
    /// `message`/`agentSessions`/`pendingAgentEvents` shape but carrying `AgentSessionRowJSON` rows — the
    /// wire row plus its rendered `open` deep link and (for a remote row) paired-device id — instead of
    /// the raw daemon wire row, which carries neither.
    private struct MCPAgentSessionsToolResponse: Encodable {
        let message: String
        let agentSessions: [AgentSessionRowJSON]
        var pendingAgentEvents: [String]?

        func addingPendingAgentEvents(_ events: [String]?) -> MCPAgentSessionsToolResponse {
            guard let events, !events.isEmpty else { return self }
            var copy = self
            copy.pendingAgentEvents = events
            return copy
        }
    }

    private struct MCPToolDescriptor {
        let name: String
        let description: String
        let properties: [String: Any]
        let required: [String]
        let oneOf: [[String: Any]]
        let handler: (SpacesMCPStdioServer, [String: Any]) throws -> MCPToolResponse

        init(
            name: String, description: String, properties: [String: Any], required: [String], oneOf: [[String: Any]] = [],
            handler: @escaping (SpacesMCPStdioServer, [String: Any]) throws -> MCPToolResponse
        ) {
            self.name = name
            self.description = description
            self.properties = properties
            self.required = required
            self.oneOf = oneOf
            self.handler = handler
        }

        var definition: [String: Any] {
            SpacesMCPStdioServer.tool(name: name, description: description, properties: properties, required: required, oneOf: oneOf)
        }
    }

    private let input: FileHandle
    private let output: FileHandle
    private let encoder: JSONEncoder
    /// Reads the binary identity this process is running at construction — i.e. at `spaces mcp` start,
    /// before any tool call can have failed — which is what bounds the re-exec (see `MCPStaleImageReload`).
    private let staleImageReload: MCPStaleImageReload
    /// Bytes read from `input` that have not yet been split into a complete newline-delimited message.
    /// Internal because the stale-image reload gates on it being empty, and that invariant is unit-tested.
    var readBuffer = Data()
    /// A reload the exec gate deferred because frames were still buffered, performed by the read loop once
    /// they are drained. Internal so the deferral is unit-testable.
    var deferredReloadTarget: String?

    init(input: FileHandle = .standardInput, output: FileHandle = .standardOutput, staleImageReload: MCPStaleImageReload = MCPStaleImageReload()) {
        self.input = input
        self.output = output
        self.staleImageReload = staleImageReload
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    func run() throws {
        while let data = readMessage() {
            try handleMessage(data)
            performDeferredReloadIfDrained()
        }
    }

    /// Performs a reload the exec gate deferred, at the first point every drained frame has been answered
    /// and the loop would otherwise block for new input. This is the drain point the deferral contract in
    /// `respondToFailedToolCall` names; without it a buffered frame that raises no daemon call of its own
    /// (a notification, a `tools/list`) would leave this image stale and blocked, and the client's retry
    /// would have to fail a second time before the reload happened. The message-boundary invariant holds
    /// by construction here: `handleMessage` has returned, so any response it wrote is a complete frame.
    /// The target is taken before the attempt, so a failed `execv` leaves the server on the same footing
    /// as the direct path — serving the stale image, re-deciding on the next mismatch.
    private func performDeferredReloadIfDrained() {
        guard readBuffer.isEmpty, let target = deferredReloadTarget else { return }
        deferredReloadTarget = nil
        staleImageReload.reload(into: target)
    }

    private static func toolDescriptors() -> [MCPToolDescriptor] {
        [
            MCPToolDescriptor(
                name: "spaces_project_list", description: "List Spaces projects on this or a paired device.",
                properties: ["device": stringSchema("Paired device name or ID. Defaults to this machine.")], required: []
            ) { server, arguments in
                let args = try decodeMCPArguments(ProjectListArguments.self, from: arguments)
                if let device = try server.resolvedDevice(args.device) {
                    let projects = try SpacesDeviceClient.projects(device: device, clientApp: cliDeviceClientApp())
                    return .profile(
                        TerminalServiceProfileCommandResponse(message: "Listed projects.", projects: projects.map(Self.profileProjectSummary)))
                }
                return .profile(try TerminalService.sendProfileCommand(.projectList))
            },
            MCPToolDescriptor(
                name: "spaces_workspace_list", description: "List Spaces workspaces on this or a paired device.",
                properties: [
                    "project": stringSchema("Project ID filter."), "device": stringSchema("Paired device name or ID. Defaults to this machine."),
                ], required: []
            ) { server, arguments in
                let args = try decodeMCPArguments(WorkspaceListArguments.self, from: arguments)
                if let device = try server.resolvedDevice(args.device) {
                    var workspaces = try SpacesDeviceClient.workspaces(device: device, clientApp: cliDeviceClientApp())
                    if let project = args.project { workspaces = workspaces.filter { $0.projectID == project } }
                    return .profile(
                        TerminalServiceProfileCommandResponse(message: "Listed workspaces.", workspaces: workspaces.map(Self.profileWorkspaceRecord)))
                }
                return .profile(try TerminalService.sendProfileCommand(.workspaceList(.init(projectID: args.project))))
            },
            MCPToolDescriptor(
                name: "spaces_workspace_create",
                description:
                    "Create a workspace. For a git project this creates a git worktree on a new branch (set existingBranch to reuse an existing branch instead) and runs the project's setup; for a non-git project it uses the project directory. The workspace is created but NOT started — call spaces_workspace_start to launch it. On the local path the result carries the created workspace record (id, dir, branch). Project IDs come from spaces_project_list.",
                properties: [
                    "project": stringSchema("Project ID from spaces_project_list."), "branch": stringSchema("Workspace branch."),
                    "baseBranch": stringSchema("Base branch for new branch creation."),
                    "existingBranch": boolSchema("Use an existing branch instead of creating a new branch."),
                    "device": stringSchema("Paired device name or ID. Defaults to this machine."),
                ], required: ["project", "branch"]
            ) { server, arguments in
                let args = try decodeMCPArguments(WorkspaceCreateArguments.self, from: arguments)
                if let device = try server.resolvedDevice(args.device) {
                    let response = try SpacesDeviceClient.createWorkspace(
                        projectID: args.project, branch: args.branch, baseBranch: args.baseBranch,
                        allowExistingBranchReuse: args.existingBranch ?? false, device: device, clientApp: cliDeviceClientApp())
                    return .profile(TerminalServiceProfileCommandResponse(message: response.message))
                }
                return .profile(
                    try TerminalService.sendProfileCommand(
                        .workspaceCreate(
                            .init(
                                projectID: args.project, branch: args.branch, baseBranch: args.baseBranch,
                                existingBranch: args.existingBranch ?? false))))
            },
            MCPToolDescriptor(
                name: "spaces_workspace_start", description: "Ensure a workspace is running on this or a paired device.",
                properties: [
                    "workspace": stringSchema("Workspace ID."), "device": stringSchema("Paired device name or ID. Defaults to this machine."),
                ], required: ["workspace"]
            ) { server, arguments in
                let args = try decodeMCPArguments(WorkspaceStartArguments.self, from: arguments)
                if let device = try server.resolvedDevice(args.device) {
                    let response = try SpacesDeviceClient.launchWorkspace(
                        workspaceID: args.workspace, device: device, clientApp: cliDeviceClientApp())
                    return .profile(TerminalServiceProfileCommandResponse(message: response.message))
                }
                return .profile(
                    try TerminalService.sendProfileCommand(
                        .workspaceStart(.init(cwd: FileManager.default.currentDirectoryPath, workspaceID: args.workspace))))
            },
            MCPToolDescriptor(
                name: "spaces_workspace_restart", description: "Force a full stop and relaunch for a workspace on this or a paired device.",
                properties: [
                    "workspace": stringSchema("Workspace ID."), "device": stringSchema("Paired device name or ID. Defaults to this machine."),
                ], required: ["workspace"]
            ) { server, arguments in
                let args = try decodeMCPArguments(WorkspaceRestartArguments.self, from: arguments)
                if let device = try server.resolvedDevice(args.device) {
                    let response = try SpacesDeviceClient.restartWorkspace(
                        workspaceID: args.workspace, device: device, clientApp: cliDeviceClientApp())
                    return .profile(TerminalServiceProfileCommandResponse(message: response.message))
                }
                return .profile(
                    try TerminalService.sendProfileCommand(
                        .workspaceRestart(.init(cwd: FileManager.default.currentDirectoryPath, workspaceID: args.workspace))))
            },
            MCPToolDescriptor(
                name: "spaces_terminal_list", description: "List available Spaces terminal sessions.",
                properties: ["device": stringSchema("Paired device name or ID. Defaults to this machine.")], required: []
            ) { server, arguments in
                let args = try decodeMCPArguments(TerminalListArguments.self, from: arguments)
                if let device = try server.resolvedDevice(args.device) {
                    let sessions = try SpacesDeviceClient.terminalSessions(device: device, clientApp: cliDeviceClientApp())
                    let rows = sessions.map { "\($0.id)\tstate=\($0.state.rawValue)\tcwd=\($0.workingDirectory)" }
                    return .profile(
                        TerminalServiceProfileCommandResponse(
                            message: rows.isEmpty ? "No terminal sessions on \(device.name)." : rows.joined(separator: "\n")))
                }
                return .profile(try TerminalService.sendProfileCommand(.terminalList, timeout: 5))
            },
            MCPToolDescriptor(
                name: "spaces_terminal_tail",
                description:
                    "Read recent rendered output from an explicit Spaces terminal session, omitting inline suggestions in identified agent sessions.",
                properties: [
                    "session": stringSchema("Spaces terminal session ID."), "lines": intSchema("Number of output lines to read. Defaults to 20."),
                    "device": stringSchema("Paired device name or ID. Defaults to this machine."),
                ], required: ["session"]
            ) { server, arguments in
                let args = try decodeMCPArguments(TerminalTailArguments.self, from: arguments)
                if let device = try server.resolvedDevice(args.device) {
                    let output = try SpacesDeviceClient.tailTerminalOutput(
                        sessionID: args.session, lines: args.lines, device: device, clientApp: cliDeviceClientApp())
                    return .profile(TerminalServiceProfileCommandResponse(message: "Read terminal output.", terminalOutput: output))
                }
                return .profile(
                    try TerminalService.sendProfileCommand(
                        .terminalTail(.init(sessionID: args.session, lineCount: args.lines)), timeout: 5))
            },
            MCPToolDescriptor(
                name: "spaces_terminal_send",
                description:
                    "Send text or raw bytes to an explicit Spaces terminal session. Text with submit=true reliably submits: the session host writes the text as a paste and then a separate Enter keystroke (carriage return) so every supported agent TUI (Claude Code, Codex, OpenCode) runs the line instead of leaving it as an unsubmitted paste — one call is enough, submit-safety is server-side. An empty text with submit presses Enter alone (e.g. to answer a TUI dialog).",
                properties: [
                    "session": stringSchema("Spaces terminal session ID."),
                    "text": stringSchema("Text to send. Use an empty string with submit to press Enter alone."),
                    "bytes": byteArraySchema("Raw byte values to send. Each value must be an integer from 0 through 255."),
                    "submit": boolSchema("Send a separate Enter keystroke after the payload; with text this submits the line."),
                    "device": stringSchema("Paired device name or ID. Defaults to this machine."),
                ], required: ["session"], oneOf: [["required": ["text"]], ["required": ["bytes"]]]
            ) { server, arguments in
                let args = try decodeMCPArguments(TerminalSendArguments.self, from: arguments)
                let input = try args.input.resolvedInput()
                let sessionID = try mcpRequired(args.session, field: "session")
                let appendNewline = args.submit ?? false
                if let device = try server.resolvedDevice(args.device) {
                    let text: String?
                    let bytes: Data?
                    switch input {
                    case .text(let value):
                        text = value
                        bytes = nil
                    case .bytes(let value):
                        text = nil
                        bytes = value
                    }
                    let response = try SpacesDeviceClient.sendTerminalInput(
                        sessionID: sessionID, text: text, bytes: bytes, appendNewline: appendNewline, device: device, clientApp: cliDeviceClientApp())
                    return .profile(TerminalServiceProfileCommandResponse(message: response.message))
                }
                return .profile(
                    try TerminalService.sendProfileCommand(
                        .terminalSend(.init(sessionID: sessionID, input: input, appendNewline: appendNewline)), timeout: 5))
            },
            MCPToolDescriptor(
                name: "spaces_agent_list",
                description:
                    "List coding-agent sessions on this or a paired device with status, note, project/workspace, and a spaces://terminal deep link.",
                properties: [
                    "workspace": stringSchema("Workspace ID filter. When omitted, lists agents across every workspace."),
                    "device": stringSchema("Paired device name or ID. Defaults to this machine."),
                ], required: []
            ) { server, arguments in
                let args = try decodeMCPArguments(AgentListArguments.self, from: arguments)
                if let device = try server.resolvedDevice(args.device) {
                    let rows = try SpacesDeviceClient.listAgentSessions(
                        workspaceID: args.workspace, device: device, clientApp: cliDeviceClientApp())
                    return .agentSessions(
                        MCPAgentSessionsToolResponse(
                            message: "Listed agent sessions.", agentSessions: rows.map { AgentSessionRowJSON($0, deviceID: device.id) }))
                }
                let rows = try TerminalService.sendProfileCommand(.agentList(.init(workspaceID: args.workspace))).agentSessions ?? []
                return .agentSessions(
                    MCPAgentSessionsToolResponse(message: "Listed agent sessions.", agentSessions: rows.map { AgentSessionRowJSON($0) }))
            },
            MCPToolDescriptor(
                name: "spaces_agent_status",
                description:
                    "Show one coding-agent session's status, note, project/workspace, and deep link. Fails until the agent has emitted its first hook signal (no agent row exists before then) — retry after the child starts working.",
                properties: [
                    "session": stringSchema("Spaces terminal session ID. Defaults to SPACES_TERMINAL_TRACKING_ID."),
                    "device": stringSchema("Paired device name or ID. Defaults to this machine."),
                ], required: []
            ) { server, arguments in
                let args = try decodeMCPArguments(AgentStatusArguments.self, from: arguments)
                let sessionID = try server.resolvedAgentSessionID(args.session)
                if let device = try server.resolvedDevice(args.device) {
                    let rows = try SpacesDeviceClient.listAgentSessions(sessionID: sessionID, device: device, clientApp: cliDeviceClientApp())
                    guard let row = rows.first else {
                        throw MCPError.invalidArguments("No agent session for terminal \(sessionID) on \(device.name).")
                    }
                    return .agentSessions(
                        MCPAgentSessionsToolResponse(
                            message: "Listed agent sessions.", agentSessions: [AgentSessionRowJSON(row, deviceID: device.id)]))
                }
                let rows = try TerminalService.sendProfileCommand(.agentList(.init(sessionID: sessionID))).agentSessions ?? []
                guard let row = rows.first else { throw MCPError.invalidArguments("No agent session for terminal \(sessionID).") }
                return .agentSessions(MCPAgentSessionsToolResponse(message: "Listed agent sessions.", agentSessions: [AgentSessionRowJSON(row)]))
            },
            MCPToolDescriptor(
                name: "spaces_agent_annotate",
                description:
                    "Set (or clear, with an empty note) a coding-agent session's explicit note. Fails until the agent has emitted its first hook signal (no agent row exists before then) — retry after the child starts working.",
                properties: [
                    "note": stringSchema("Note text. Pass an empty string to clear the note."),
                    "session": stringSchema("Spaces terminal session ID. Defaults to SPACES_TERMINAL_TRACKING_ID."),
                    "device": stringSchema("Paired device name or ID. Defaults to this machine."),
                ], required: ["note"]
            ) { server, arguments in
                let args = try decodeMCPArguments(AgentAnnotateArguments.self, from: arguments)
                let sessionID = try server.resolvedAgentSessionID(args.session)
                if let device = try server.resolvedDevice(args.device) {
                    let rows = try SpacesDeviceClient.annotateAgentSession(
                        sessionID: sessionID, note: args.note, device: device, clientApp: cliDeviceClientApp())
                    return .agentSessions(
                        MCPAgentSessionsToolResponse(
                            message: rows.first?.note == nil ? "Cleared agent note." : "Annotated agent session.",
                            agentSessions: rows.map { AgentSessionRowJSON($0, deviceID: device.id) }))
                }
                let response = try TerminalService.sendProfileCommand(.agentAnnotate(.init(sessionID: sessionID, note: args.note)))
                return .agentSessions(
                    MCPAgentSessionsToolResponse(
                        message: response.message, agentSessions: (response.agentSessions ?? []).map { AgentSessionRowJSON($0) }))
            },
            MCPToolDescriptor(
                name: "spaces_agent_spawn",
                description:
                    "Start a coding agent (\(CodingAgent.commandListText)) in a new Spaces terminal and return once the daemon detects the agent running in that terminal (foreground classification) — not when it emits a hook signal. The result carries a structured agentSpawn object: terminalSessionID, workspaceID, detectedAgent, deviceID, subscribed, and open (a spaces://terminal deep link, device-qualified when deviceID is set). Spawn delivers no prompt: to give the agent work, send input with spaces_terminal_send on agentSpawn.terminalSessionID, then poll spaces_agent_status or spaces_terminal_tail to confirm work started (and to see and answer any first-run trust/onboarding/auth dialog). Hooks enrich status but are not required to spawn. agentSpawn.subscribed reports whether the spawning terminal was auto-subscribed; when false (the child's agent row appears only on its first hook signal), call spaces_agent_subscribe once the agent has signaled to receive blocked/done notifications.",
                properties: [
                    "command": stringSchema("Command that launches a supported coding agent (\(CodingAgent.commandListText))."),
                    "workspace": stringSchema("Workspace ID. Defaults to the workspace containing the current directory. Required with device."),
                    "title": stringSchema("Window or session title. Defaults to the coding agent's name."),
                    "timeout": intSchema("Seconds to wait for detection. Defaults to 90."),
                    "device": stringSchema("Paired device name or ID. Spawns on that device and requires workspace. Defaults to this machine."),
                ], required: ["command"]
            ) { server, arguments in
                let args = try decodeMCPArguments(AgentSpawnArguments.self, from: arguments)
                let subscriber = ProcessInfo.processInfo.environment[WorkspaceOrchestrator.terminalTrackingIDEnvVar]?.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                let subscriberSessionID = (subscriber?.isEmpty == false) ? subscriber : nil
                let result: AgentSpawnResult
                if let device = try server.resolvedDevice(args.device) {
                    guard let workspace = args.workspace else {
                        throw MCPError.invalidArguments("workspace is required with device: a remote spawn cannot infer the workspace.")
                    }
                    result = try performRemoteAgentSpawn(
                        device: device, workspace: workspace, command: args.command, title: args.title,
                        timeoutSeconds: args.timeout ?? 90, subscriberSessionID: subscriberSessionID)
                } else {
                    // The MCP server itself inherits SPACES_AUTOMATION_RUN_ID whenever a script automation
                    // launches an MCP-capable orchestrator, exactly like the `agent spawn` CLI path (see
                    // AgentSpawnCommand.run() and resolvedAutomationRunID()'s doc comment). Forward it so the
                    // spawned agent is attributed to the run and stays reachable through Cancel, End agents,
                    // and retention cleanup.
                    result = try performAgentSpawn(
                        cwd: FileManager.default.currentDirectoryPath, workspace: args.workspace, command: args.command,
                        title: args.title, timeoutSeconds: args.timeout ?? 90,
                        subscriberSessionID: subscriberSessionID, automationRunID: resolvedAutomationRunID())
                }
                let deviceNote = result.deviceID.map { " on device \($0)" } ?? ""
                return .profile(
                    TerminalServiceProfileCommandResponse(
                        message:
                            "Started agent session \(result.terminalSessionID) (detected \(result.detectedAgent))\(deviceNote). Send its prompt with spaces_terminal_send, then poll spaces_agent_status or spaces_terminal_tail to confirm work started.",
                        agentSpawn: TerminalServiceAgentSpawnResult(
                            terminalSessionID: result.terminalSessionID, workspaceID: result.workspaceID, detectedAgent: result.detectedAgent,
                            deviceID: result.deviceID, subscribed: result.subscribed, open: result.open)))
            },
            MCPToolDescriptor(
                name: "spaces_agent_kill", description: "Terminate a coding-agent session and its terminal.",
                properties: [
                    "session": stringSchema("Child terminal session ID to terminate."),
                    "device": stringSchema("Paired device name or ID. Defaults to this machine."),
                ], required: ["session"]
            ) { server, arguments in
                let args = try decodeMCPArguments(AgentKillArguments.self, from: arguments)
                if let device = try server.resolvedDevice(args.device) {
                    // The remote daemon's `killAgentSession` runs the same notify-then-stop flow as the
                    // local `.agentKill`: a hook-signaled child's subscribers are told it exited before its
                    // row is deleted, and a not-yet-signaled `.agent`-kind session is terminated.
                    let response = try SpacesDeviceClient.killAgentSession(
                        sessionID: args.session, device: device, clientApp: cliDeviceClientApp())
                    return .profile(TerminalServiceProfileCommandResponse(message: response.message))
                }
                return .profile(try TerminalService.sendProfileCommand(.agentKill(.init(sessionID: args.session))))
            },
            MCPToolDescriptor(
                name: "spaces_agent_subscribe",
                description:
                    "Watch a child coding-agent session from the current (or an explicit) terminal. While watching, each time the child goes blocked/done/exited you get one event block — a `[spaces] <label> (<kind>) is <blocked|done|exited>` line followed by indented project/workspace/branch/session/note/link fields. When you are idle it is injected into your terminal; when you are busy it is attached as `pendingAgentEvents` on the result of your next spaces_* tool call, so you learn a child is blocked without waiting for your own turn boundary. Fails until the child has emitted its first hook signal (there is no agent row to watch before then) — retry after the child starts working.",
                properties: [
                    "session": stringSchema("Child terminal session ID to watch."),
                    "subscriber": stringSchema("Subscriber terminal session ID. Defaults to SPACES_TERMINAL_TRACKING_ID."),
                    "device": stringSchema("Paired device name or ID the child runs on. Records a cross-device watch. Defaults to this machine."),
                ], required: ["session"]
            ) { server, arguments in
                let args = try decodeMCPArguments(AgentSubscribeArguments.self, from: arguments)
                let subscriberSessionID = try server.resolvedSubscriberSessionID(args.subscriber)
                // The subscriber is always a local terminal (this daemon owns it and does the watching); a
                // cross-device watch passes the child's terminal session id and the device to the local
                // daemon, which validates it against the remote and records the edge.
                if let device = try server.resolvedDevice(args.device) {
                    return .profile(
                        try TerminalService.sendProfileCommand(
                            .agentSubscribe(
                                .init(subscriberTerminalSessionID: subscriberSessionID, agentSessionID: args.session, deviceID: device.id)),
                            timeout: 30))
                }
                let agentRowID = try resolvedAgentRowID(forChildTerminalSessionID: args.session)
                return .profile(
                    try TerminalService.sendProfileCommand(
                        .agentSubscribe(.init(subscriberTerminalSessionID: subscriberSessionID, agentSessionID: agentRowID)), timeout: 5))
            },
            MCPToolDescriptor(
                name: "spaces_agent_unsubscribe",
                description: "Stop watching a child coding-agent session from the current (or an explicit) terminal.",
                properties: [
                    "session": stringSchema("Child terminal session ID to stop watching."),
                    "subscriber": stringSchema("Subscriber terminal session ID. Defaults to SPACES_TERMINAL_TRACKING_ID."),
                    "device": stringSchema("Paired device name or ID the child runs on (for a cross-device watch). Defaults to this machine."),
                ], required: ["session"]
            ) { server, arguments in
                let args = try decodeMCPArguments(AgentUnsubscribeArguments.self, from: arguments)
                let subscriberSessionID = try server.resolvedSubscriberSessionID(args.subscriber)
                if let device = try server.resolvedDevice(args.device) {
                    return .profile(
                        try TerminalService.sendProfileCommand(
                            .agentUnsubscribe(
                                .init(subscriberTerminalSessionID: subscriberSessionID, agentSessionID: args.session, deviceID: device.id)),
                            timeout: 5))
                }
                let agentRowID = try resolvedAgentRowID(forChildTerminalSessionID: args.session)
                return .profile(
                    try TerminalService.sendProfileCommand(
                        .agentUnsubscribe(.init(subscriberTerminalSessionID: subscriberSessionID, agentSessionID: agentRowID)), timeout: 5))
            },
            MCPToolDescriptor(
                name: "spaces_device_list", description: "List paired devices reachable from this machine.", properties: [:], required: []
            ) { _, _ in
                let devices = try SpacesClientDatabase.defaultDatabase().pairedDevices()
                return .profile(
                    TerminalServiceProfileCommandResponse(
                        message: devices.isEmpty ? "No paired devices." : SpacesPairedDeviceSelection.deviceRows(devices)))
            },
        ]
    }

    static func toolDefinitions() -> [[String: Any]] { toolDescriptors().map(\.definition) }

    private static func tool(name: String, description: String, properties: [String: Any], required: [String], oneOf: [[String: Any]] = [])
        -> [String: Any]
    {
        var inputSchema: [String: Any] = ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
        if !oneOf.isEmpty { inputSchema["oneOf"] = oneOf }
        return ["name": name, "description": description, "inputSchema": inputSchema]
    }

    private static func stringSchema(_ description: String) -> [String: Any] { ["type": "string", "description": description] }

    private static func boolSchema(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }

    private static func intSchema(_ description: String) -> [String: Any] { ["type": "integer", "minimum": 1, "description": description] }

    private static func byteArraySchema(_ description: String) -> [String: Any] {
        ["type": "array", "items": ["type": "integer", "minimum": 0, "maximum": 255], "description": description]
    }

    private func handleMessage(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            try sendError(id: nil, code: -32700, message: "Invalid JSON-RPC message.")
            return
        }
        let id = object["id"]
        guard let method = object["method"] as? String else {
            try sendError(id: id, code: -32600, message: "Missing JSON-RPC method.")
            return
        }

        switch method {
        case "initialize":
            try sendResponse(
                id: id,
                result: [
                    "protocolVersion": "2024-11-05", "capabilities": ["tools": [:]], "serverInfo": ["name": "spaces", "version": AppVersion.current],
                ])
        case "notifications/initialized": return
        case "ping": try sendResponse(id: id, result: [:])
        case "tools/list": try sendResponse(id: id, result: ["tools": Self.toolDefinitions()])
        case "tools/call": try handleToolCall(id: id, params: object["params"] as? [String: Any])
        default: try sendError(id: id, code: -32601, message: "Unsupported MCP method '\(method)'.")
        }
    }

    private func handleToolCall(id: Any?, params: [String: Any]?) throws {
        do {
            guard let params else { throw MCPError.invalidArguments("Missing tool call parameters.") }
            // Envelope-level extraction of the JSON-RPC call's own "name" field, not a per-tool argument —
            // out of scope for the Codable argument structs below, which decode each tool's `arguments`.
            guard let rawName = params["name"] as? String else { throw MCPError.invalidArguments("name is required.") }
            let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { throw MCPError.invalidArguments("name is required.") }
            let name = trimmedName
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let profileResponse = try callTool(name: name, arguments: arguments)
            let withPendingEvents = try attachingPendingAgentEvents(to: profileResponse)
            try sendToolResult(id: id, text: try encodedText(withPendingEvents), isError: false)
        } catch { try respondToFailedToolCall(id: id, error: error) }
    }

    /// Answers a failed tool call, and reloads this process's binary image when the failure was a daemon
    /// that has moved ahead of it (see `MCPStaleImageReload`). The answer is written first and the exec
    /// runs only after those bytes are on stdout: `writeJSONObject` completes one whole newline-delimited
    /// message, so the exec always lands on a message boundary and never truncates a half-written frame.
    /// Internal so that ordering is unit-testable.
    ///
    /// The exec is additionally gated on `readBuffer` being empty. `readMessage` drains whatever
    /// `availableData` returns, so a client that pipelined can leave whole further frames — or the front
    /// of a partial one — sitting in this image's memory, and exec discards all of it: unread bytes still
    /// in the stdin pipe are inherited by the successor, but drained bytes are gone. An empty buffer is
    /// therefore the invariant that makes a lost or torn frame impossible.
    ///
    /// The gate defers rather than drops: a non-empty buffer records the target and the read loop performs
    /// the reload at `performDeferredReloadIfDrained`, the first point every drained frame has been
    /// answered. That is what keeps the promise the retry answer makes — the client's next call reaches a
    /// current image — no matter what those buffered frames turn out to be. A buffered frame that does
    /// itself hit this path with an empty buffer reloads directly and makes the record redundant.
    func respondToFailedToolCall(id: Any?, error: Error) throws {
        guard let execTarget = staleImageReload.execTarget(for: error) else {
            try sendToolResult(id: id, text: error.localizedDescription, isError: true)
            return
        }
        try sendToolResult(id: id, text: MCPStaleImageReload.retryMessage, isError: true)
        guard readBuffer.isEmpty else {
            deferredReloadTarget = execTarget
            return
        }
        staleImageReload.reload(into: execTarget)
    }

    /// Drains any events a watched child queued for the current Spaces terminal
    /// (`SPACES_TERMINAL_TRACKING_ID`, inherited since the MCP server runs inside the orchestrator's
    /// terminal) while this orchestrator was busy — the busy-time counterpart to idle injection: no
    /// polling, no timers. The consume command always targets the local daemon — a subscriber is always
    /// local even for a remote-device tool call. nil outside a Spaces terminal (env unset) or when
    /// nothing is queued. Shared by both `attachingPendingAgentEvents` overloads below.
    private func drainedPendingAgentEvents() throws -> [String]? {
        let subscriber = ProcessInfo.processInfo.environment[WorkspaceOrchestrator.terminalTrackingIDEnvVar]?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard let subscriber, !subscriber.isEmpty else { return nil }
        return try TerminalService.sendProfileCommand(.agentConsumePendingEvents(subscriberTerminalSessionID: subscriber), timeout: 5)
            .pendingAgentEvents
    }

    /// After a tool handler returns successfully, attaches any pending agent events drained by
    /// `drainedPendingAgentEvents()`. Reached only on the success path, so an errored tool call never
    /// consumes. Both `MCPToolResponse` cases carry an `addingPendingAgentEvents` that no-ops when there
    /// is nothing to attach, so this stays a plain dispatch over the two payload types.
    private func attachingPendingAgentEvents(to response: MCPToolResponse) throws -> MCPToolResponse {
        let events = try drainedPendingAgentEvents()
        switch response {
        case .profile(let profile): return .profile(profile.addingPendingAgentEvents(events))
        case .agentSessions(let agentSessions): return .agentSessions(agentSessions.addingPendingAgentEvents(events))
        }
    }

    private func callTool(name: String, arguments: [String: Any]) throws -> MCPToolResponse {
        guard let descriptor = Self.toolDescriptors().first(where: { $0.name == name }) else {
            throw MCPError.invalidArguments("Unknown Spaces tool '\(name)'.")
        }
        return try descriptor.handler(self, arguments)
    }

    private func encodedText(_ response: MCPToolResponse) throws -> String {
        switch response {
        case .profile(let profile): return try encodedJSON(profile)
        case .agentSessions(let agentSessions): return try encodedJSON(agentSessions)
        }
    }

    private func encodedJSON(_ value: some Encodable) throws -> String {
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func resolvedDevice(_ device: String?) throws -> SpacesPairedDeviceRecord? {
        guard let device else { return nil }
        return try SpacesPairedDeviceSelection.resolve(device)
    }

    /// Maps a paired-device project summary to the profile summary shape so remote and local
    /// `spaces_project_list` results share one JSON shape.
    private static func profileProjectSummary(_ summary: SpacesDeviceProjectSummary) -> TerminalServiceProfileProjectSummary {
        TerminalServiceProfileProjectSummary(
            id: summary.id, name: summary.name, dir: summary.dir, isGitRepo: summary.isGitRepo, defaultBranch: summary.defaultBranch)
    }

    /// Maps a paired-device workspace summary to the profile record shape so remote and local
    /// `spaces_workspace_list` results share one JSON shape. `dirname` and `lastLaunchedAt` are not
    /// carried by the overview and render as null; the fields the listing surfaces (id, project, branch,
    /// run state, name) are all present.
    private static func profileWorkspaceRecord(_ summary: SpacesDeviceWorkspaceSummary) -> TerminalServiceProfileWorkspaceRecord {
        TerminalServiceProfileWorkspaceRecord(
            id: summary.id, projectID: summary.projectID, dir: summary.dir, dirname: nil, branch: summary.branch, baseBranch: summary.baseBranch,
            isDefault: summary.isDefault, isHidden: summary.isHidden, isRunning: summary.isRunning, lastLaunchedAt: nil, notes: summary.notes)
    }

    /// Resolves the agent's terminal session id for `status`/`annotate`, defaulting to the current
    /// Spaces terminal's `SPACES_TERMINAL_TRACKING_ID`. Internal so it is unit-testable.
    func resolvedAgentSessionID(_ session: String?) throws -> String {
        if let session { return session }
        let envValue = ProcessInfo.processInfo.environment[WorkspaceOrchestrator.terminalTrackingIDEnvVar]?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if let envValue, !envValue.isEmpty { return envValue }
        throw MCPError.invalidArguments(
            "session is required, or run inside a Spaces terminal so \(WorkspaceOrchestrator.terminalTrackingIDEnvVar) is set.")
    }

    /// Resolves the subscriber terminal session id for `subscribe`/`unsubscribe`, defaulting to the
    /// current Spaces terminal's `SPACES_TERMINAL_TRACKING_ID`. Internal so it is unit-testable.
    func resolvedSubscriberSessionID(_ subscriber: String?) throws -> String {
        if let subscriber { return subscriber }
        let envValue = ProcessInfo.processInfo.environment[WorkspaceOrchestrator.terminalTrackingIDEnvVar]?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if let envValue, !envValue.isEmpty { return envValue }
        throw MCPError.invalidArguments(
            "subscriber is required, or run inside a Spaces terminal so \(WorkspaceOrchestrator.terminalTrackingIDEnvVar) is set.")
    }

    private func sendToolResult(id: Any?, text: String, isError: Bool) throws {
        try sendResponse(id: id, result: ["content": [["type": "text", "text": text]], "isError": isError])
    }

    private func sendResponse(id: Any?, result: [String: Any]) throws {
        var response: [String: Any] = ["jsonrpc": "2.0", "result": result]
        response["id"] = id ?? NSNull()
        try writeJSONObject(response)
    }

    private func sendError(id: Any?, code: Int, message: String) throws {
        var response: [String: Any] = ["jsonrpc": "2.0", "error": ["code": code, "message": message]]
        response["id"] = id ?? NSNull()
        try writeJSONObject(response)
    }

    /// Writes one JSON-RPC message as a single newline-delimited line, the MCP stdio framing: compact
    /// JSON (no embedded newlines) followed by a single `\n`. `JSONSerialization` without
    /// `.prettyPrinted` never emits literal newlines, so the message occupies exactly one line.
    private func writeJSONObject(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        output.write(data)
    }

    /// Reads one newline-delimited JSON-RPC message from `input`. Accumulates bytes across reads until a
    /// `\n`, returns the line trimmed of its `\r\n` terminator, and skips blank lines between messages.
    /// Returns nil on clean EOF with nothing buffered.
    private func readMessage() -> Data? {
        while true {
            if let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
                let line = Data(readBuffer[readBuffer.startIndex..<newlineIndex])
                readBuffer = Data(readBuffer[readBuffer.index(after: newlineIndex)...])
                let trimmed = trimTrailingCarriageReturn(line)
                if trimmed.isEmpty { continue }
                return trimmed
            }
            // `availableData` returns as soon as any bytes arrive (or empty on EOF); `readData(ofLength:)`
            // would block filling the whole buffer until EOF, hanging the interactive initialize handshake
            // where the client waits for our response before sending its next line.
            let chunk = input.availableData
            if chunk.isEmpty {
                // Clean EOF: surface any final unterminated line, otherwise signal end of stream.
                let trimmed = trimTrailingCarriageReturn(readBuffer)
                readBuffer.removeAll()
                return trimmed.isEmpty ? nil : trimmed
            }
            readBuffer.append(chunk)
        }
    }

    /// Drops a single trailing `\r` so a `\r\n`-terminated line yields the bare JSON payload.
    private func trimTrailingCarriageReturn(_ data: Data) -> Data {
        guard data.last == 0x0D else { return data }
        return data.dropLast()
    }
}

enum MCPError: LocalizedError {
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message): message
        }
    }
}
