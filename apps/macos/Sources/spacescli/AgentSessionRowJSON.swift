import Foundation
import spacesdevicecore
import spacesterminalcore

/// JSON presentation of one coding-agent session row, shared by `spaces agent list`/`spaces agent status
/// --json` and the `spaces_agent_list`/`spaces_agent_status`/`spaces_agent_annotate` MCP tools.
///
/// The wire rows (`TerminalServiceAgentSessionRow`, the local daemon protocol type, and
/// `SpacesDeviceAgentSessionRow`, the cross-device Device API type) carry no rendered link and no device
/// id — the text row renderer (`agentSessionRow(_:deviceID:)` in SpacesCommand.swift) builds the
/// `spaces://terminal` deep link itself via `SpacesTerminalDeepLink` and prints it as an `open=` column.
/// Structured (`--json`/MCP) consumers need the same thing without reconstructing it, so this type wraps
/// the wire row's fields with `open` (identical to the text row's `open=` value) and, for a row read from
/// a paired device, `deviceID` (the resolved paired-device id that qualifies `open`). Session id
/// resolution matches the text path: `row.terminalSessionID ?? row.id`.
///
/// Deliberately not a change to either wire row type: `TerminalServiceAgentSessionRow` is the local
/// daemon's wire protocol (widening it would ripple into every consumer that decodes it) and
/// `SpacesDeviceAgentSessionRow` is the cross-device Device API type (protocol changes there are deferred
/// to issue #167). This presentation type lives entirely in the CLI/MCP layer that renders output.
struct AgentSessionRowJSON: Codable, Equatable {
    let id: String
    let terminalSessionID: String
    let agent: String?
    let label: String?
    let status: String
    let note: String?
    let projectID: String
    let projectName: String
    let workspaceID: String
    let workspaceName: String
    let workspaceDir: String
    let branch: String?
    let updatedAt: String
    let lastSignalAt: String?
    /// The paired device this session runs on, or nil for a local session. Matches the `?device=` query
    /// item on `open`.
    let deviceID: String?
    /// Rendered `spaces://terminal/<session-id>` deep link, device-qualified when `deviceID` is set —
    /// exactly what the text row's `open=` column prints.
    let open: String

    private init(
        id: String, terminalSessionID: String?, agent: String?, label: String?, status: String, note: String?, projectID: String, projectName: String,
        workspaceID: String, workspaceName: String, workspaceDir: String, branch: String?, updatedAt: String, lastSignalAt: String?, deviceID: String?
    ) {
        let resolvedSessionID = terminalSessionID ?? id
        self.id = id
        self.terminalSessionID = resolvedSessionID
        self.agent = agent
        self.label = label
        self.status = status
        self.note = note
        self.projectID = projectID
        self.projectName = projectName
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.workspaceDir = workspaceDir
        self.branch = branch
        self.updatedAt = updatedAt
        self.lastSignalAt = lastSignalAt
        self.deviceID = deviceID
        self.open = SpacesTerminalDeepLink(sessionID: resolvedSessionID, deviceID: deviceID).absoluteString
    }

    /// Wraps a local daemon agent row. `deviceID` is nil for this machine's own sessions.
    init(_ row: TerminalServiceAgentSessionRow, deviceID: String? = nil) {
        self.init(
            id: row.id, terminalSessionID: row.terminalSessionID, agent: row.agent, label: row.label, status: row.status, note: row.note,
            projectID: row.projectID, projectName: row.projectName, workspaceID: row.workspaceID, workspaceName: row.workspaceName,
            workspaceDir: row.workspaceDir, branch: row.branch, updatedAt: row.updatedAt, lastSignalAt: row.lastSignalAt, deviceID: deviceID)
    }

    /// Wraps a paired-device agent row read over the Device API. `deviceID` is required (unlike the local
    /// overload) because a remote row always resolves to the paired device it was read from.
    init(_ row: SpacesDeviceAgentSessionRow, deviceID: String) {
        self.init(
            id: row.id, terminalSessionID: row.terminalSessionID, agent: row.agent, label: row.label, status: row.status, note: row.note,
            projectID: row.projectID, projectName: row.projectName, workspaceID: row.workspaceID, workspaceName: row.workspaceName,
            workspaceDir: row.workspaceDir, branch: row.branch, updatedAt: row.updatedAt, lastSignalAt: row.lastSignalAt, deviceID: deviceID)
    }
}
