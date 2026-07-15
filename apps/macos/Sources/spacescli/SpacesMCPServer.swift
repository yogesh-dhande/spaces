import Foundation
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import workspacecore

final class SpacesMCPStdioServer {
    private struct MCPToolDescriptor {
        let name: String
        let description: String
        let properties: [String: Any]
        let required: [String]
        let oneOf: [[String: Any]]
        let handler: (SpacesMCPStdioServer, [String: Any]) throws -> TerminalServiceProfileCommandResponse

        init(
            name: String, description: String, properties: [String: Any], required: [String], oneOf: [[String: Any]] = [],
            handler: @escaping (SpacesMCPStdioServer, [String: Any]) throws -> TerminalServiceProfileCommandResponse
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

    init(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) {
        self.input = input
        self.output = output
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
    }

    func run() throws { while let data = try readMessage() { try handleMessage(data) } }

    private static func toolDescriptors() -> [MCPToolDescriptor] {
        [
            MCPToolDescriptor(
                name: "spaces_project_list", description: "List Spaces projects on this or a paired device.",
                properties: ["device": stringSchema("Paired device name or ID. Defaults to this machine.")], required: []
            ) { server, arguments in
                if let device = try server.resolvedDevice(arguments) {
                    let projects = try SpacesDeviceClient.projects(device: device, clientApp: cliDeviceClientApp())
                    return TerminalServiceProfileCommandResponse(message: "Listed projects.", projects: projects.map(Self.profileProjectSummary))
                }
                return try TerminalService.sendProfileCommand(.projectList)
            },
            MCPToolDescriptor(
                name: "spaces_workspace_list", description: "List Spaces workspaces on this or a paired device.",
                properties: [
                    "project": stringSchema("Project ID filter."),
                    "includeArchived": boolSchema("Include archived workspaces. Not supported with device."),
                    "device": stringSchema("Paired device name or ID. Defaults to this machine."),
                ],
                required: []
            ) { server, arguments in
                if let device = try server.resolvedDevice(arguments) {
                    // The device overview carries only active workspaces, so archived ones are
                    // unreachable over this path; reject the combination rather than silently ignore it.
                    guard server.optionalBool(arguments["includeArchived"]) != true else {
                        throw MCPError.invalidArguments("includeArchived is not supported with device: a paired device's overview lists only active workspaces.")
                    }
                    var workspaces = try SpacesDeviceClient.workspaces(device: device, clientApp: cliDeviceClientApp())
                    if let project = server.optionalString(arguments["project"]) { workspaces = workspaces.filter { $0.projectID == project } }
                    return TerminalServiceProfileCommandResponse(message: "Listed workspaces.", workspaces: workspaces.map(Self.profileWorkspaceRecord))
                }
                return try TerminalService.sendProfileCommand(
                    .workspaceList(
                        .init(
                            projectID: server.optionalString(arguments["project"]),
                            includeArchived: server.optionalBool(arguments["includeArchived"]) ?? false)))
            },
            MCPToolDescriptor(
                name: "spaces_workspace_create", description: "Create a workspace on this or a paired device.",
                properties: [
                    "project": stringSchema("Project ID."), "branch": stringSchema("Workspace branch."),
                    "baseBranch": stringSchema("Base branch for new branch creation."),
                    "existingBranch": boolSchema("Use an existing branch instead of creating a new branch."),
                    "device": stringSchema("Paired device name or ID. Defaults to this machine."),
                ], required: ["project", "branch"]
            ) { server, arguments in
                let project = try server.requiredString(arguments["project"], field: "project")
                let branch = try server.requiredString(arguments["branch"], field: "branch")
                if let device = try server.resolvedDevice(arguments) {
                    let response = try SpacesDeviceClient.createWorkspace(
                        projectID: project, branch: branch, baseBranch: server.optionalString(arguments["baseBranch"]),
                        allowExistingBranchReuse: server.optionalBool(arguments["existingBranch"]) ?? false, device: device,
                        clientApp: cliDeviceClientApp())
                    return TerminalServiceProfileCommandResponse(message: response.message)
                }
                return try TerminalService.sendProfileCommand(
                    .workspaceCreate(
                        .init(
                            projectID: project, branch: branch, baseBranch: server.optionalString(arguments["baseBranch"]),
                            existingBranch: server.optionalBool(arguments["existingBranch"]) ?? false)))
            },
            MCPToolDescriptor(
                name: "spaces_workspace_start", description: "Ensure a workspace is running on this or a paired device.",
                properties: [
                    "workspace": stringSchema("Workspace ID."),
                    "device": stringSchema("Paired device name or ID. Defaults to this machine."),
                ], required: ["workspace"]
            ) { server, arguments in
                let workspace = try server.requiredString(arguments["workspace"], field: "workspace")
                if let device = try server.resolvedDevice(arguments) {
                    let response = try SpacesDeviceClient.launchWorkspace(workspaceID: workspace, device: device, clientApp: cliDeviceClientApp())
                    return TerminalServiceProfileCommandResponse(message: response.message)
                }
                return try TerminalService.sendProfileCommand(.workspaceStart(workspaceID: workspace))
            },
            MCPToolDescriptor(
                name: "spaces_workspace_restart", description: "Force a full stop and relaunch for a workspace on this or a paired device.",
                properties: [
                    "workspace": stringSchema("Workspace ID."),
                    "device": stringSchema("Paired device name or ID. Defaults to this machine."),
                ], required: ["workspace"]
            ) { server, arguments in
                let workspace = try server.requiredString(arguments["workspace"], field: "workspace")
                if let device = try server.resolvedDevice(arguments) {
                    let response = try SpacesDeviceClient.restartWorkspace(workspaceID: workspace, device: device, clientApp: cliDeviceClientApp())
                    return TerminalServiceProfileCommandResponse(message: response.message)
                }
                return try TerminalService.sendProfileCommand(.workspaceRestart(workspaceID: workspace))
            },
            MCPToolDescriptor(
                name: "spaces_terminal_list", description: "List available Spaces terminal sessions.",
                properties: ["device": stringSchema("Paired device name or ID. Defaults to this machine.")], required: []
            ) { server, arguments in
                if let device = try server.resolvedDevice(arguments) {
                    let sessions = try SpacesDeviceClient.terminalSessions(device: device, clientApp: cliDeviceClientApp())
                    let rows = sessions.map { "\($0.id)\tstate=\($0.state.rawValue)\tcwd=\($0.workingDirectory)" }
                    return TerminalServiceProfileCommandResponse(
                        message: rows.isEmpty ? "No terminal sessions on \(device.name)." : rows.joined(separator: "\n"))
                }
                return try TerminalService.sendProfileCommand(.terminalList, timeout: 5)
            },
            MCPToolDescriptor(
                name: "spaces_terminal_tail", description: "Read recent output from an explicit Spaces terminal session.",
                properties: [
                    "session": stringSchema("Spaces terminal session ID."), "lines": intSchema("Number of output lines to read. Defaults to 20."),
                    "device": stringSchema("Paired device name or ID. Defaults to this machine."),
                ], required: ["session"]
            ) { server, arguments in
                let sessionID = try server.requiredString(arguments["session"], field: "session")
                if let device = try server.resolvedDevice(arguments) {
                    let output = try SpacesDeviceClient.tailTerminalOutput(
                        sessionID: sessionID, lines: server.optionalInt(arguments["lines"]), device: device, clientApp: cliDeviceClientApp())
                    return TerminalServiceProfileCommandResponse(message: "Read terminal output.", terminalOutput: output)
                }
                return try TerminalService.sendProfileCommand(
                    .terminalTail(.init(sessionID: sessionID, lineCount: server.optionalInt(arguments["lines"]))), timeout: 5)
            },
            MCPToolDescriptor(
                name: "spaces_terminal_send", description: "Send text or raw bytes to an explicit Spaces terminal session.",
                properties: [
                    "session": stringSchema("Spaces terminal session ID."),
                    "text": stringSchema("Text to send. Use an empty string with appendNewline to press Enter."),
                    "bytes": byteArraySchema("Raw byte values to send. Each value must be an integer from 0 through 255."),
                    "appendNewline": boolSchema("Append a newline after the payload."),
                    "device": stringSchema("Paired device name or ID. Defaults to this machine."),
                ], required: ["session"], oneOf: [["required": ["text"]], ["required": ["bytes"]]]
            ) { server, arguments in
                let input = try server.terminalInputPayload(from: arguments)
                let sessionID = try server.requiredString(arguments["session"], field: "session")
                let appendNewline = server.optionalBool(arguments["appendNewline"]) ?? false
                if let device = try server.resolvedDevice(arguments) {
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
                    return TerminalServiceProfileCommandResponse(message: response.message)
                }
                return try TerminalService.sendProfileCommand(
                    .terminalSend(.init(sessionID: sessionID, input: input, appendNewline: appendNewline)), timeout: 5)
            },
            MCPToolDescriptor(
                name: "spaces_agent_list",
                description: "List coding-agent sessions on this or a paired device with status, note, project/workspace, and a spaces://terminal deep link.",
                properties: [
                    "workspace": stringSchema("Workspace ID filter. When omitted, lists agents across every workspace."),
                    "device": stringSchema("Paired device name or ID. Defaults to this machine."),
                ], required: []
            ) { server, arguments in
                if let device = try server.resolvedDevice(arguments) {
                    let rows = try SpacesDeviceClient.listAgentSessions(
                        workspaceID: server.optionalString(arguments["workspace"]), device: device, clientApp: cliDeviceClientApp())
                    return TerminalServiceProfileCommandResponse(
                        message: "Listed agent sessions.", agentSessions: rows.map(Self.profileAgentRow))
                }
                return try TerminalService.sendProfileCommand(.agentList(.init(workspaceID: server.optionalString(arguments["workspace"]))))
            },
            MCPToolDescriptor(
                name: "spaces_agent_status",
                description: "Show one coding-agent session's status, note, project/workspace, and deep link.",
                properties: [
                    "session": stringSchema("Spaces terminal session ID. Defaults to SPACES_TERMINAL_TRACKING_ID."),
                    "device": stringSchema("Paired device name or ID. Defaults to this machine."),
                ], required: []
            ) { server, arguments in
                let sessionID = try server.resolvedAgentSessionID(arguments)
                if let device = try server.resolvedDevice(arguments) {
                    let rows = try SpacesDeviceClient.listAgentSessions(sessionID: sessionID, device: device, clientApp: cliDeviceClientApp())
                    guard let row = rows.first else {
                        throw MCPError.invalidArguments("No agent session for terminal \(sessionID) on \(device.name).")
                    }
                    return TerminalServiceProfileCommandResponse(message: "Listed agent sessions.", agentSessions: [Self.profileAgentRow(row)])
                }
                let response = try TerminalService.sendProfileCommand(.agentList(.init(sessionID: sessionID)))
                guard (response.agentSessions ?? []).first != nil else { throw MCPError.invalidArguments("No agent session for terminal \(sessionID).") }
                return response
            },
            MCPToolDescriptor(
                name: "spaces_agent_annotate",
                description: "Set (or clear, with an empty note) a coding-agent session's explicit note.",
                properties: [
                    "note": stringSchema("Note text. Pass an empty string to clear the note."),
                    "session": stringSchema("Spaces terminal session ID. Defaults to SPACES_TERMINAL_TRACKING_ID."),
                    "device": stringSchema("Paired device name or ID. Defaults to this machine."),
                ], required: ["note"]
            ) { server, arguments in
                let note = try server.requiredRawString(arguments["note"], field: "note")
                let sessionID = try server.resolvedAgentSessionID(arguments)
                if let device = try server.resolvedDevice(arguments) {
                    let rows = try SpacesDeviceClient.annotateAgentSession(
                        sessionID: sessionID, note: note, device: device, clientApp: cliDeviceClientApp())
                    return TerminalServiceProfileCommandResponse(
                        message: rows.first?.note == nil ? "Cleared agent note." : "Annotated agent session.",
                        agentSessions: rows.map(Self.profileAgentRow))
                }
                return try TerminalService.sendProfileCommand(.agentAnnotate(.init(sessionID: sessionID, note: note)))
            },
            MCPToolDescriptor(
                name: "spaces_agent_spawn",
                description:
                    "Start a coding agent (claude, codex, or opencode) in a new Spaces terminal and return once the daemon detects the agent running in that terminal (foreground classification) — not when it emits a hook signal. Spawn delivers no prompt: to give the agent work, send input with spaces_terminal_send on the returned terminal session id, then poll spaces_agent_status or spaces_terminal_tail to confirm work started (and to see and answer any first-run trust/onboarding/auth dialog). Hooks enrich status but are not required to spawn. The result's subscribed field reports whether the spawning terminal was auto-subscribed; when false (the child's agent row appears only on its first hook signal), call spaces_agent_subscribe once the agent has signaled to receive blocked/done notifications.",
                properties: [
                    "command": stringSchema("Command that launches a supported coding agent (claude, codex, or opencode)."),
                    "workspace": stringSchema("Workspace ID. Defaults to the workspace containing the current directory. Required with device."),
                    "title": stringSchema("Window or session title. Defaults to the coding agent's name."),
                    "timeout": intSchema("Seconds to wait for detection. Defaults to 90."),
                    "device": stringSchema("Paired device name or ID. Spawns on that device and requires workspace. Defaults to this machine."),
                ], required: ["command"]
            ) { server, arguments in
                let command = try server.requiredString(arguments["command"], field: "command")
                let subscriber = ProcessInfo.processInfo.environment[WorkspaceOrchestrator.terminalTrackingIDEnvVar]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let subscriberSessionID = (subscriber?.isEmpty == false) ? subscriber : nil
                let result: AgentSpawnResult
                if let device = try server.resolvedDevice(arguments) {
                    guard let workspace = server.optionalString(arguments["workspace"]) else {
                        throw MCPError.invalidArguments("workspace is required with device: a remote spawn cannot infer the workspace.")
                    }
                    result = try performRemoteAgentSpawn(
                        device: device, workspace: workspace, command: command, title: server.optionalString(arguments["title"]),
                        timeoutSeconds: server.optionalInt(arguments["timeout"]) ?? 90, subscriberSessionID: subscriberSessionID)
                } else {
                    result = try performAgentSpawn(
                        cwd: FileManager.default.currentDirectoryPath, workspace: server.optionalString(arguments["workspace"]), command: command,
                        title: server.optionalString(arguments["title"]), timeoutSeconds: server.optionalInt(arguments["timeout"]) ?? 90,
                        subscriberSessionID: subscriberSessionID)
                }
                let deviceNote = result.deviceID.map { " on device \($0)" } ?? ""
                return TerminalServiceProfileCommandResponse(
                    message:
                        "Started agent session \(result.terminalSessionID) (detected \(result.detectedAgent))\(deviceNote). Send its prompt with spaces_terminal_send, then poll spaces_agent_status or spaces_terminal_tail to confirm work started."
                )
            },
            MCPToolDescriptor(
                name: "spaces_agent_interrupt", description: "Interrupt a coding-agent session by sending ESC to its terminal.",
                properties: [
                    "session": stringSchema("Child terminal session ID to interrupt."),
                    "device": stringSchema("Paired device name or ID. Defaults to this machine."),
                ], required: ["session"]
            ) { server, arguments in
                let sessionID = try server.requiredString(arguments["session"], field: "session")
                if let device = try server.resolvedDevice(arguments) {
                    let response = try SpacesDeviceClient.sendTerminalInput(
                        sessionID: sessionID, bytes: Data([27]), appendNewline: false, device: device, clientApp: cliDeviceClientApp())
                    return TerminalServiceProfileCommandResponse(message: response.message)
                }
                return try TerminalService.sendProfileCommand(
                    .terminalSend(.init(sessionID: sessionID, input: .bytes(Data([27])), appendNewline: false)), timeout: 5)
            },
            MCPToolDescriptor(
                name: "spaces_agent_kill", description: "Terminate a coding-agent session and its terminal.",
                properties: [
                    "session": stringSchema("Child terminal session ID to terminate."),
                    "device": stringSchema("Paired device name or ID. Defaults to this machine."),
                ], required: ["session"]
            ) { server, arguments in
                let sessionID = try server.requiredString(arguments["session"], field: "session")
                if let device = try server.resolvedDevice(arguments) {
                    // Mirror the local kill: stop the child's agent row (present only after its first
                    // signal) through the coding-agent stop path, else terminate the raw session, which
                    // is how a not-yet-signaled remote session is killed.
                    if let row = try SpacesDeviceClient.listAgentSessions(sessionID: sessionID, device: device, clientApp: cliDeviceClientApp()).first {
                        let response = try SpacesDeviceClient.stopCodingAgent(
                            workspaceID: row.workspaceID, agentID: row.id, agentName: nil, agentLauncherID: nil, device: device,
                            clientApp: cliDeviceClientApp())
                        return TerminalServiceProfileCommandResponse(message: response.message)
                    }
                    let response = try SpacesDeviceClient.terminateTerminalSession(
                        sessionID: sessionID, device: device, clientApp: cliDeviceClientApp())
                    return TerminalServiceProfileCommandResponse(message: response.message)
                }
                return try TerminalService.sendProfileCommand(.agentKill(.init(sessionID: sessionID)))
            },
            MCPToolDescriptor(
                name: "spaces_agent_subscribe", description: "Watch a child coding-agent session from the current (or an explicit) terminal.",
                properties: [
                    "session": stringSchema("Child terminal session ID to watch."),
                    "subscriber": stringSchema("Subscriber terminal session ID. Defaults to SPACES_TERMINAL_TRACKING_ID."),
                    "device": stringSchema("Paired device name or ID the child runs on. Records a cross-device watch. Defaults to this machine."),
                ], required: ["session"]
            ) { server, arguments in
                let sessionID = try server.requiredString(arguments["session"], field: "session")
                let subscriberSessionID = try server.resolvedSubscriberSessionID(arguments)
                // The subscriber is always a local terminal (this daemon owns it and does the watching); a
                // cross-device watch passes the child's terminal session id and the device to the local
                // daemon, which validates it against the remote and records the edge.
                if let device = try server.resolvedDevice(arguments) {
                    return try TerminalService.sendProfileCommand(
                        .agentSubscribe(.init(subscriberTerminalSessionID: subscriberSessionID, agentSessionID: sessionID, deviceID: device.id)),
                        timeout: 30)
                }
                let agentRowID = try resolvedAgentRowID(forChildTerminalSessionID: sessionID)
                return try TerminalService.sendProfileCommand(
                    .agentSubscribe(.init(subscriberTerminalSessionID: subscriberSessionID, agentSessionID: agentRowID)), timeout: 5)
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
                let sessionID = try server.requiredString(arguments["session"], field: "session")
                let subscriberSessionID = try server.resolvedSubscriberSessionID(arguments)
                if let device = try server.resolvedDevice(arguments) {
                    return try TerminalService.sendProfileCommand(
                        .agentUnsubscribe(.init(subscriberTerminalSessionID: subscriberSessionID, agentSessionID: sessionID, deviceID: device.id)),
                        timeout: 5)
                }
                let agentRowID = try resolvedAgentRowID(forChildTerminalSessionID: sessionID)
                return try TerminalService.sendProfileCommand(
                    .agentUnsubscribe(.init(subscriberTerminalSessionID: subscriberSessionID, agentSessionID: agentRowID)), timeout: 5)
            },
            MCPToolDescriptor(
                name: "spaces_device_list", description: "List paired devices reachable from this machine.", properties: [:], required: []
            ) { _, _ in
                let devices = try SpacesClientDatabase.defaultDatabase().pairedDevices()
                return TerminalServiceProfileCommandResponse(
                    message: devices.isEmpty ? "No paired devices." : SpacesPairedDeviceSelection.deviceRows(devices))
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
            let name = try requiredString(params["name"], field: "name")
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let profileResponse = try callTool(name: name, arguments: arguments)
            try sendToolResult(id: id, text: try encodedText(profileResponse), isError: false)
        } catch { try sendToolResult(id: id, text: error.localizedDescription, isError: true) }
    }

    private func callTool(name: String, arguments: [String: Any]) throws -> TerminalServiceProfileCommandResponse {
        guard let descriptor = Self.toolDescriptors().first(where: { $0.name == name }) else {
            throw MCPError.invalidArguments("Unknown Spaces tool '\(name)'.")
        }
        return try descriptor.handler(self, arguments)
    }

    private func encodedText(_ response: TerminalServiceProfileCommandResponse) throws -> String {
        let data = try encoder.encode(response)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func requiredString(_ value: Any?, field: String) throws -> String {
        guard let string = optionalString(value) else { throw MCPError.invalidArguments("\(field) is required.") }
        return string
    }

    private func requiredRawString(_ value: Any?, field: String) throws -> String {
        guard let string = value as? String else { throw MCPError.invalidArguments("\(field) is required.") }
        return string
    }

    private func resolvedDevice(_ arguments: [String: Any]) throws -> SpacesPairedDeviceRecord? {
        guard let selector = optionalString(arguments["device"]) else { return nil }
        return try SpacesPairedDeviceSelection.resolve(selector)
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
            isDefault: summary.isDefault, isArchived: summary.isArchived, isHidden: summary.isHidden, isRunning: summary.isRunning,
            lastLaunchedAt: nil, notes: summary.notes)
    }

    /// Maps a paired-device agent row to the profile row shape so remote and local `agent_*` tool
    /// results share one JSON shape (the two structs mirror each other field-for-field).
    private static func profileAgentRow(_ row: SpacesDeviceAgentSessionRow) -> TerminalServiceAgentSessionRow {
        TerminalServiceAgentSessionRow(
            id: row.id, terminalSessionID: row.terminalSessionID, agent: row.agent, label: row.label, status: row.status, note: row.note,
            projectID: row.projectID, projectName: row.projectName, workspaceID: row.workspaceID, workspaceName: row.workspaceName,
            branch: row.branch, updatedAt: row.updatedAt, lastSignalAt: row.lastSignalAt)
    }

    /// Resolves the agent's terminal session id for `status`/`annotate`, defaulting to the current
    /// Spaces terminal's `SPACES_TERMINAL_TRACKING_ID`. Internal so it is unit-testable.
    func resolvedAgentSessionID(_ arguments: [String: Any]) throws -> String {
        if let session = optionalString(arguments["session"]) { return session }
        let envValue = ProcessInfo.processInfo.environment[WorkspaceOrchestrator.terminalTrackingIDEnvVar]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let envValue, !envValue.isEmpty { return envValue }
        throw MCPError.invalidArguments(
            "session is required, or run inside a Spaces terminal so \(WorkspaceOrchestrator.terminalTrackingIDEnvVar) is set.")
    }

    /// Resolves the subscriber terminal session id for `subscribe`/`unsubscribe`, defaulting to the
    /// current Spaces terminal's `SPACES_TERMINAL_TRACKING_ID`. Internal so it is unit-testable.
    func resolvedSubscriberSessionID(_ arguments: [String: Any]) throws -> String {
        if let subscriber = optionalString(arguments["subscriber"]) { return subscriber }
        let envValue = ProcessInfo.processInfo.environment[WorkspaceOrchestrator.terminalTrackingIDEnvVar]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let envValue, !envValue.isEmpty { return envValue }
        throw MCPError.invalidArguments(
            "subscriber is required, or run inside a Spaces terminal so \(WorkspaceOrchestrator.terminalTrackingIDEnvVar) is set.")
    }

    private func optionalString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func optionalBool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    private func optionalInt(_ value: Any?) -> Int? {
        if value is Bool { return nil }
        if let int = value as? Int { return int }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            guard double.isFinite, double.rounded(.towardZero) == double else { return nil }
            return number.intValue
        }
        return nil
    }

    /// Maps the JSON `text`/`bytes` arguments into the typed `TerminalProfileInput`. The typed input
    /// makes text-xor-bytes structural on the wire, but the enforcement still lives here because MCP
    /// arguments are untyped JSON where both keys can be supplied at once; this is the only layer that
    /// must reject that. Internal (not private) so the arg-mapping rejection is unit-testable.
    func terminalInputPayload(from arguments: [String: Any]) throws -> TerminalProfileInput {
        let textValue = arguments["text"]
        let bytesValue = arguments["bytes"]
        let hasText = textValue != nil
        let hasBytes = bytesValue != nil
        guard hasText || hasBytes else { throw MCPError.invalidArguments("text or bytes is required.") }
        guard !(hasText && hasBytes) else { throw MCPError.invalidArguments("Provide text or bytes, not both.") }
        if hasText { return .text(try requiredRawString(textValue, field: "text")) }
        return .bytes(try requiredBytes(bytesValue, field: "bytes"))
    }

    private func requiredBytes(_ value: Any?, field: String) throws -> Data {
        guard let values = value as? [Any] else { throw MCPError.invalidArguments("\(field) must be an array of byte values.") }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            if value is Bool { throw MCPError.invalidArguments("\(field)[\(index)] must be an integer from 0 through 255.") }
            guard let byte = byteValue(value) else { throw MCPError.invalidArguments("\(field)[\(index)] must be an integer from 0 through 255.") }
            bytes.append(byte)
        }
        return Data(bytes)
    }

    private func byteValue(_ value: Any) -> UInt8? {
        if let int = value as? Int { return (0...255).contains(int) ? UInt8(int) : nil }
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded(.towardZero) == double else { return nil }
        let int = number.intValue
        return (0...255).contains(int) ? UInt8(int) : nil
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

    private func writeJSONObject(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        let header = "Content-Length: \(data.count)\r\n\r\n"
        output.write(Data(header.utf8))
        output.write(data)
    }

    private func readMessage() throws -> Data? {
        var header = Data()
        let crlfTerminator = Data("\r\n\r\n".utf8)
        let lfTerminator = Data("\n\n".utf8)
        while !data(header, hasSuffix: crlfTerminator), !data(header, hasSuffix: lfTerminator) {
            let byte = input.readData(ofLength: 1)
            if byte.isEmpty {
                if header.isEmpty { return nil }
                throw MCPError.invalidMessage("Unexpected EOF while reading MCP headers.")
            }
            header.append(byte)
        }
        guard let headerText = String(data: header, encoding: .utf8) else { throw MCPError.invalidMessage("MCP headers were not UTF-8.") }
        let length = try contentLength(from: headerText)
        let body = input.readData(ofLength: length)
        guard body.count == length else { throw MCPError.invalidMessage("Unexpected EOF while reading MCP body.") }
        return body
    }

    private func data(_ data: Data, hasSuffix suffix: Data) -> Bool {
        guard data.count >= suffix.count else { return false }
        return data.suffix(suffix.count).elementsEqual(suffix)
    }

    private func contentLength(from headerText: String) throws -> Int {
        for line in headerText.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { continue }
            if let length = Int(parts[1]), length >= 0 { return length }
        }
        throw MCPError.invalidMessage("Missing MCP Content-Length header.")
    }
}

private enum MCPError: LocalizedError {
    case invalidMessage(String)
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .invalidMessage(let message), .invalidArguments(let message): message
        }
    }
}
