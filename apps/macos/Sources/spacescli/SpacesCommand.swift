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
              - The running spacesd owns profile schema upgrades. If a staged helper requires a newer schema, run `spaces daemon apply-update` so the daemon updates in place without stopping its sessions.
              - Workspace commands require explicit IDs; agent signal defaults workspace/session IDs from Spaces terminal environment.
              - `project list`, `workspace list`, and `workspace create`/`start`/`restart` accept `--device <name-or-id>` to read or act on a paired device; the discovery listings read the device's overview, so `workspace list --device` shows only active workspaces and rejects `--include-archived`. Omitting `--device` targets this device's spacesd daemon.
              - `workspace start` waits for pending/running setup to complete and fails with the setup error if setup failed. It ensures a workspace and all its processes are running: launches when stopped; when already running, restarts any exited processes. Windows open without activating the app.
              - `workspace restart` forces a full stop and relaunch for a workspace.
              - Agent events stay explicit. Workspace runtime commands do not imply agent lifecycle. `agent signal <event>` records those lifecycle transitions for the current Spaces terminal session, or no-ops outside one.
              - `agent list`/`agent status` report coding-agent sessions with status, note, project/workspace context, and a spaces://terminal deep link. `agent annotate` sets an explicit note (empty clears it). `status`/`annotate` default the session to SPACES_TERMINAL_TRACKING_ID.
              - `agent spawn --command <cmd>` starts a supported coding agent (claude, codex, opencode) in a new terminal and blocks until the daemon's foreground classifier detects it running (not until a hook signal — a promptless Codex never signals). It delivers no prompt — the orchestrator sends the prompt with `terminal send` and confirms work with `terminal tail`/`agent status`. It auto-subscribes the current terminal once the child has an agent row. `agent kill <session>` terminates the session, and `agent subscribe`/`unsubscribe <session>` record a watch edge (subscriber defaults to SPACES_TERMINAL_TRACKING_ID). Keystrokes go to a child through `terminal send`; agent status comes only from the agent's own signals, so sending input never moves it.
              - `agent spawn`/`list`/`status`/`annotate`/`kill`/`subscribe`/`unsubscribe` accept `--device <name-or-id>` to act on a paired device; remote `spawn` requires `--workspace`, auto-subscribes the current terminal to the remote child, and remote `kill` works before the child signals (it terminates the session directly when no agent row exists yet). `agent subscribe --device` records a cross-device watch: the current terminal receives the same blocked/done/exited notification lines for the remote child, delivered by this machine's daemon (device-qualified deep links). A `--device` naming this machine is validated like a local watch (self-edges and subscription cycles are rejected); cross-device cycles to a remote device cannot be detected (the remote's own subscriptions are not queryable locally).
            """, version: AppVersion.current,
        subcommands: [
            ProjectCommand.self, WorkspaceCommand.self, AgentCommand.self, TerminalCommand.self, DeviceCommand.self, DaemonCommand.self,
            MCPCommand.self,
        ])

    public init() {}
}

struct ProjectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "project", abstract: "Manage Spaces projects.", subcommands: [ProjectListCommand.self])
}

/// Renders one project as a tab-separated row. Shared by the local and `--device` paths so both forms
/// print identical columns; the two overloads adapt the local profile summary and the device overview
/// summary to the same primitives.
func projectListRow(id: String, name: String, dir: String) -> String { "\(id)\tname=\(name)\tdir=\(dir)" }
func projectListRow(_ summary: TerminalServiceProfileProjectSummary) -> String {
    projectListRow(id: summary.id, name: summary.name, dir: summary.dir)
}
func projectListRow(_ summary: SpacesDeviceProjectSummary) -> String { projectListRow(id: summary.id, name: summary.name, dir: summary.dir) }

/// Renders one workspace as a tab-separated row. Shared by the local and `--device` paths; the device
/// overview carries every column the local record surfaces here (id, project, branch, run state, name).
func workspaceListRow(id: String, projectID: String, branch: String?, isRunning: Bool, displayName: String) -> String {
    "\(id)\tproject=\(projectID)\tbranch=\(branch ?? "-")\trunning=\(isRunning)\tname=\(displayName)"
}
func workspaceListRow(_ record: TerminalServiceProfileWorkspaceRecord) -> String {
    workspaceListRow(id: record.id, projectID: record.projectID, branch: record.branch, isRunning: record.isRunning, displayName: record.displayName)
}
func workspaceListRow(_ summary: SpacesDeviceWorkspaceSummary) -> String {
    workspaceListRow(
        id: summary.id, projectID: summary.projectID, branch: summary.branch, isRunning: summary.isRunning, displayName: summary.displayName)
}

struct ProjectListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List projects on this or a paired device.")

    @Option(name: .long, help: "Paired device name or ID. Defaults to this machine's local projects.") var device: String?

    func run() throws {
        let context = CLIContext()
        if let device {
            let record = try SpacesPairedDeviceSelection.resolve(device)
            let projects = try SpacesDeviceClient.projects(device: record, clientApp: cliDeviceClientApp())
            context.output.emitLines(projects.map(projectListRow))
            return
        }
        let projects = try TerminalService.sendProfileCommand(.projectList).projects ?? []
        context.output.emitLines(projects.map(projectListRow))
    }
}

struct WorkspaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace", abstract: "Manage Spaces workspaces.",
        subcommands: [WorkspaceListCommand.self, WorkspaceCreateCommand.self, WorkspaceStartCommand.self, WorkspaceRestartCommand.self])
}

struct WorkspaceListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List workspaces on this or a paired device.")

    @Option(name: .long, help: "Project ID. When omitted, lists workspaces from every project.") var project: String?
    @Flag(name: .long, help: "Include archived workspaces. Not supported with --device.") var includeArchived = false
    @Option(name: .long, help: "Paired device name or ID. Defaults to this machine's local workspaces.") var device: String?

    func run() throws {
        let context = CLIContext()
        if let device {
            // The device overview carries only active workspaces, so archived ones are unreachable over
            // this path. Reject the flag combination loudly rather than silently ignoring it and
            // returning a subset that looks like the full archived listing.
            guard !includeArchived else {
                throw ValidationError("--include-archived is not supported with --device: a paired device's overview lists only active workspaces.")
            }
            let record = try SpacesPairedDeviceSelection.resolve(device)
            var workspaces = try SpacesDeviceClient.workspaces(device: record, clientApp: cliDeviceClientApp())
            if let project { workspaces = workspaces.filter { $0.projectID == project } }
            context.output.emitLines(workspaces.map(workspaceListRow))
            return
        }
        let workspaces =
            try TerminalService.sendProfileCommand(.workspaceList(.init(projectID: project, includeArchived: includeArchived))).workspaces ?? []
        context.output.emitLines(workspaces.map(workspaceListRow))
    }
}

struct WorkspaceCreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a workspace on this or a paired device.")

    @Option(name: .long, help: "Project ID.") var project: String
    @Option(name: .long, help: "Workspace branch.") var branch: String
    @Option(name: .long, help: "Base branch for new branch creation.") var baseBranch: String?
    @Flag(name: .long, help: "Use an existing branch instead of creating a new branch.") var existingBranch = false
    @Option(name: .long, help: "Paired device name or ID. Defaults to this machine.") var device: String?

    func run() throws {
        let context = CLIContext()
        if let device {
            let record = try SpacesPairedDeviceSelection.resolve(device)
            // The remote path runs the workspace's setup script in the background, so the response
            // returns before setup completes; the message reports the created workspace by name.
            let response = try SpacesDeviceClient.createWorkspace(
                projectID: project, branch: branch, baseBranch: baseBranch, allowExistingBranchReuse: existingBranch, device: record,
                clientApp: cliDeviceClientApp())
            context.output.emit(response.message)
            return
        }
        let workspace = try requireProfileWorkspace(
            try TerminalService.sendProfileCommand(
                .workspaceCreate(.init(projectID: project, branch: branch, baseBranch: baseBranch, existingBranch: existingBranch))))
        context.output.emit("Created workspace \(workspace.id)\tproject=\(workspace.projectID)\tbranch=\(workspace.branch ?? "-")")
    }
}

struct WorkspaceStartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "start", abstract: "Ensure a workspace is running on this or a paired device.")

    @Option(name: .long, help: "Workspace ID.") var workspace: String
    @Option(name: .long, help: "Paired device name or ID. Defaults to this machine.") var device: String?

    func run() throws {
        let context = CLIContext()
        if let device {
            let record = try SpacesPairedDeviceSelection.resolve(device)
            let response = try SpacesDeviceClient.launchWorkspace(workspaceID: workspace, device: record, clientApp: cliDeviceClientApp())
            context.output.emit(response.message)
            return
        }
        _ = try requireProfileWorkspace(try TerminalService.sendProfileCommand(.workspaceStart(workspaceID: workspace)))
        context.output.emit("Workspace is running \(workspace)")
    }
}

struct WorkspaceRestartCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart", abstract: "Force a full stop and relaunch for a workspace on this or a paired device.")

    @Option(name: .long, help: "Workspace ID.") var workspace: String
    @Option(name: .long, help: "Paired device name or ID. Defaults to this machine.") var device: String?

    func run() throws {
        let context = CLIContext()
        if let device {
            let record = try SpacesPairedDeviceSelection.resolve(device)
            let response = try SpacesDeviceClient.restartWorkspace(workspaceID: workspace, device: record, clientApp: cliDeviceClientApp())
            context.output.emit(response.message)
            return
        }
        _ = try requireProfileWorkspace(try TerminalService.sendProfileCommand(.workspaceRestart(workspaceID: workspace)))
        context.output.emit("Workspace restarted \(workspace)")
    }
}

struct AgentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent", abstract: "Manage and orchestrate coding-agent sessions.",
        subcommands: [
            AgentSignalCommand.self, AgentListCommand.self, AgentStatusCommand.self, AgentAnnotateCommand.self, AgentSpawnCommand.self,
            AgentKillCommand.self, AgentSubscribeCommand.self, AgentUnsubscribeCommand.self,
        ])
}

/// Renders one agent session as a tab-separated `key=value` row, matching the terminal-list convention.
/// The leading column is the terminal session id (the target for `terminal send`, subscriptions, and the
/// `open` deep link); missing optional values render as `-`. `deviceID`, when present, qualifies the
/// `open` deep link so it points at the agent on its paired device (`?device=<id>`). `signaled=`
/// reports whether the agent has emitted at least one lifecycle hook signal (`lastSignalAt` is set) —
/// informational hook-health, distinct from spawn's foreground-detection readiness.
func agentSessionRow(
    terminalSessionID: String, agent: String?, status: String, signaled: Bool, note: String?, projectName: String, workspaceName: String,
    branch: String?, deviceID: String? = nil
) -> String {
    [
        terminalSessionID, "agent=\(agent ?? "-")", "status=\(status)", "signaled=\(signaled)", "note=\(note ?? "-")", "project=\(projectName)",
        "workspace=\(workspaceName)", "branch=\(branch ?? "-")",
        "open=\(SpacesTerminalDeepLink(sessionID: terminalSessionID, deviceID: deviceID).absoluteString)",
    ].joined(separator: "\t")
}

func agentSessionRow(_ row: TerminalServiceAgentSessionRow) -> String {
    agentSessionRow(
        terminalSessionID: row.terminalSessionID ?? row.id, agent: row.agent, status: row.status, signaled: row.lastSignalAt != nil, note: row.note,
        projectName: row.projectName, workspaceName: row.workspaceName, branch: row.branch)
}

/// Renders a paired-device agent row, qualifying the `open` deep link with the device record id so a
/// click resolves the session on its owning device.
func agentSessionRow(_ row: SpacesDeviceAgentSessionRow, deviceID: String) -> String {
    agentSessionRow(
        terminalSessionID: row.terminalSessionID ?? row.id, agent: row.agent, status: row.status, signaled: row.lastSignalAt != nil, note: row.note,
        projectName: row.projectName, workspaceName: row.workspaceName, branch: row.branch, deviceID: deviceID)
}

/// Resolves the terminal session id to act on for `status`/`annotate`, defaulting to the current Spaces
/// terminal's `SPACES_TERMINAL_TRACKING_ID`. Unlike `agent signal`, these commands always target a
/// specific session, so a missing id is an error rather than a silent no-op.
func resolvedAgentSessionID(_ session: String?, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
    if let session = session?.trimmingCharacters(in: .whitespacesAndNewlines), !session.isEmpty { return session }
    let envValue = environment[WorkspaceOrchestrator.terminalTrackingIDEnvVar]?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let envValue, !envValue.isEmpty { return envValue }
    throw ValidationError("--session is required, or run inside a Spaces terminal so \(WorkspaceOrchestrator.terminalTrackingIDEnvVar) is set.")
}

struct AgentListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List coding-agent sessions on this or a paired device.")

    @Option(name: .long, help: "Workspace ID. When omitted, lists agents across every workspace.") var workspace: String?
    @Option(name: .long, help: "Paired device name or ID. Defaults to this machine's local sessions.") var device: String?
    @Flag(name: .long, help: "Emit machine-readable JSON.") var json = false

    func run() throws {
        let context = CLIContext()
        if let device {
            let record = try SpacesPairedDeviceSelection.resolve(device)
            let rows = try SpacesDeviceClient.listAgentSessions(workspaceID: workspace, device: record, clientApp: cliDeviceClientApp())
            if json {
                try context.output.emitJSON(rows.map { AgentSessionRowJSON($0, deviceID: record.id) })
                return
            }
            if rows.isEmpty {
                context.output.emit("No agent sessions.")
                return
            }
            context.output.emitLines(rows.map { agentSessionRow($0, deviceID: record.id) })
            return
        }
        let rows = try TerminalService.sendProfileCommand(.agentList(.init(workspaceID: workspace))).agentSessions ?? []
        if json {
            try context.output.emitJSON(rows.map { AgentSessionRowJSON($0) })
            return
        }
        if rows.isEmpty {
            context.output.emit("No agent sessions.")
            return
        }
        context.output.emitLines(rows.map(agentSessionRow))
    }
}

struct AgentStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show a single coding-agent session's status.")

    @Option(name: .long, help: "Spaces terminal session ID. Defaults to SPACES_TERMINAL_TRACKING_ID.") var session: String?
    @Option(name: .long, help: "Paired device name or ID. Defaults to this machine's local sessions.") var device: String?
    @Flag(name: .long, help: "Emit machine-readable JSON.") var json = false

    func run() throws {
        let context = CLIContext()
        if let device {
            let record = try SpacesPairedDeviceSelection.resolve(device)
            let sessionID = try resolvedAgentSessionID(session)
            guard let row = try SpacesDeviceClient.listAgentSessions(sessionID: sessionID, device: record, clientApp: cliDeviceClientApp()).first
            else { throw ValidationError("No agent session for terminal \(sessionID) on \(record.name).") }
            if json {
                try context.output.emitJSON(AgentSessionRowJSON(row, deviceID: record.id))
                return
            }
            context.output.emit(agentSessionRow(row, deviceID: record.id))
            return
        }
        let sessionID = try resolvedAgentSessionID(session)
        guard let row = (try TerminalService.sendProfileCommand(.agentList(.init(sessionID: sessionID))).agentSessions ?? []).first else {
            throw ValidationError("No agent session for terminal \(sessionID).")
        }
        if json {
            try context.output.emitJSON(AgentSessionRowJSON(row))
            return
        }
        context.output.emit(agentSessionRow(row))
    }
}

struct AgentAnnotateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "annotate", abstract: "Set (or clear, with an empty note) a coding-agent session's note.")

    @Argument(help: "Note text. Pass an empty string to clear the note.") var note: String
    @Option(name: .long, help: "Spaces terminal session ID. Defaults to SPACES_TERMINAL_TRACKING_ID.") var session: String?
    @Option(name: .long, help: "Paired device name or ID. Defaults to this machine's local sessions.") var device: String?

    func run() throws {
        let context = CLIContext()
        let sessionID = try resolvedAgentSessionID(session)
        if let device {
            let record = try SpacesPairedDeviceSelection.resolve(device)
            let rows = try SpacesDeviceClient.annotateAgentSession(sessionID: sessionID, note: note, device: record, clientApp: cliDeviceClientApp())
            context.output.emit(rows.first?.note == nil ? "Cleared agent note." : "Annotated agent session.")
            return
        }
        let response = try TerminalService.sendProfileCommand(.agentAnnotate(.init(sessionID: sessionID, note: note)))
        context.output.emit(response.message)
    }
}

/// Raised when a spawned agent's process is never identified as a running coding agent within the
/// readiness budget — the daemon's foreground classifier saw nothing. The session is left running for
/// inspection.
struct AgentSpawnDetectionTimeoutError: LocalizedError {
    let sessionID: String
    let command: String
    let timeoutSeconds: Int

    var errorDescription: String? {
        "Agent session \(sessionID) was not detected as a running coding agent within \(timeoutSeconds)s (foreground classification never identified `\(command)`). The session is left running; inspect with: spaces terminal tail \(sessionID)"
    }
}

/// Raised when a spawned agent's child ends before it is ever identified as a running coding agent — the
/// command did not run (an unresolvable binary, an immediately rejected argument, a crash on start).
///
/// The child's exit is the cause and is reported as such, along with the last lines it wrote, which is
/// where the shell's own diagnosis lands (`zsh:1: command not found: claude`). Blaming foreground
/// classification here would point the reader at the classifier for a command that never ran.
/// `deviceName` is nil for a local spawn and the paired device's name for a remote one, which qualifies
/// the inspect hint so it names the device the session lives on.
struct AgentSpawnChildExitedError: LocalizedError {
    let sessionID: String
    let command: String
    let state: TerminalSessionState
    let lastOutputLines: [String]
    let deviceName: String?

    var errorDescription: String? {
        let output = lastOutputLines.isEmpty ? "It produced no output." : "Last output: \(lastOutputLines.joined(separator: " / "))."
        let deviceSuffix = deviceName.map { " --device \($0)" } ?? ""
        return
            "Agent session \(sessionID) \(state.rawValue) before it was detected as a running coding agent: `\(command)` did not stay running. \(output) Inspect with: spaces terminal tail \(sessionID)\(deviceSuffix)"
    }
}

/// Result of a `spaces agent spawn`: the terminal session the daemon started and which coding agent
/// foreground detection identified. `deviceID` is nil for a local spawn and the paired device's id for a
/// remote one (it qualifies the `open` deep link). `agent list`/`status` (keyed on `terminalSessionID`)
/// surface the agent's live status once it reports one — the agent row may not exist yet at spawn return
/// (rows appear on the first hook signal), which is also why `subscribed` can be false.
///
/// `open` is computed once here (mirroring `AgentSessionRowJSON`), so the text row (`agentSpawnResultLine`,
/// which reads `result.open`), `--json`, and the MCP `spaces_agent_spawn` tool (which forwards it onto
/// `TerminalServiceAgentSpawnResult.open`) can never disagree on the rendered deep link.
struct AgentSpawnResult: Codable, Equatable {
    let terminalSessionID: String
    let workspaceID: String?
    let detectedAgent: String
    /// nil for a local spawn; the paired device's id for a remote one.
    let deviceID: String?
    /// False when the child had no agent row yet at spawn return (rows appear on the first hook
    /// signal), so no watch edge was recorded; the caller subscribes explicitly once the agent signals.
    let subscribed: Bool
    /// Rendered `spaces://terminal/<session-id>` deep link, device-qualified when `deviceID` is set —
    /// exactly what the text row's `open=` column prints.
    let open: String

    init(terminalSessionID: String, workspaceID: String?, detectedAgent: String, deviceID: String?, subscribed: Bool) {
        self.terminalSessionID = terminalSessionID
        self.workspaceID = workspaceID
        self.detectedAgent = detectedAgent
        self.deviceID = deviceID
        self.subscribed = subscribed
        self.open = SpacesTerminalDeepLink(sessionID: terminalSessionID, deviceID: deviceID).absoluteString
    }
}

/// Spawns a coding agent on this machine and blocks until the daemon's foreground classifier identifies
/// it in the new terminal (readiness = detection, NOT a hook signal). It delivers no prompt: spawn
/// returns at detection, and the orchestrator sends the prompt with `terminal send` and confirms work
/// with `terminal tail`/`agent status`. A child that ends before it is identified fails the spawn at that
/// moment, reporting its exit and last output. Auto-subscribes the spawning terminal when the child
/// already has an agent row. Shared by `agent spawn` and the `spaces_agent_spawn` MCP tool so both block
/// identically.
func performAgentSpawn(
    cwd: String, workspace: String?, command: String, title: String?, timeoutSeconds: Int, subscriberSessionID: String?,
    pollInterval: TimeInterval = 0.5
) throws -> AgentSpawnResult {
    let spawnResponse = try TerminalService.sendProfileCommand(
        .agentSpawn(.init(cwd: cwd, workspaceID: workspace, command: command, title: title)), timeout: TerminalService.createSessionRequestTimeout())
    guard let session = spawnResponse.terminalSession else {
        throw WorkspaceError.invalidArgument(message: "spacesd did not return an agent session.")
    }
    let childSessionID = session.id
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))

    // Readiness = foreground detection: block until the daemon's classifier identifies a coding agent in
    // this terminal. This does not wait for a hook signal (a promptless Codex never emits one), and the
    // agent orchestration row may not exist yet at this point. A child that ends first ends the wait
    // immediately with its own exit as the cause.
    let detected: TerminalDetectedAgentKind
    switch try AgentSpawnReadiness.awaitReadiness(
        deadline: deadline, pollInterval: pollInterval, snapshot: { try spawnedSessionSnapshot(childSessionID: childSessionID) })
    {
    case .detected(let kind): detected = kind
    case .ended(let state):
        throw AgentSpawnChildExitedError(
            sessionID: childSessionID, command: command, state: state, lastOutputLines: lastSpawnedSessionOutputLines(childSessionID: childSessionID),
            deviceName: nil)
    case .timedOut: throw AgentSpawnDetectionTimeoutError(sessionID: childSessionID, command: command, timeoutSeconds: timeoutSeconds)
    }

    // Auto-subscribe the spawning terminal, but only when the child already has an agent row: rows
    // appear on the first hook signal, and a spawned `.agent` session has none at detection time. No
    // row → skip cleanly (there is nothing to key the subscription on yet).
    var subscribed = false
    if let subscriberSessionID, subscriberSessionID != childSessionID,
        let rowID = try resolvedAgentRowIDIfPresent(forChildTerminalSessionID: childSessionID)
    {
        _ = try TerminalService.sendProfileCommand(
            .agentSubscribe(.init(subscriberTerminalSessionID: subscriberSessionID, agentSessionID: rowID)), timeout: 5)
        subscribed = true
    }

    return AgentSpawnResult(
        terminalSessionID: childSessionID, workspaceID: session.launchConfiguration?.workspaceID, detectedAgent: detected.displayLabel, deviceID: nil,
        subscribed: subscribed)
}

/// One readiness poll of a locally spawned session, read from the session's runtime state — the record
/// the daemon writes for it, carrying both the foreground classification and the run state.
///
/// It is read directly rather than through `.terminalList`, which lists only live interactive sessions:
/// a child that died is exactly the case spawn has to detect, and it drops out of that listing instead of
/// reporting that it ended.
private func spawnedSessionSnapshot(childSessionID: String) throws -> AgentSpawnReadiness.SessionSnapshot {
    let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: try TerminalSessionPaths.forSession(id: childSessionID))
    return .init(detectedKind: runtimeState.foregroundDetectedAgentKind, state: runtimeState.state)
}

/// The last lines a spawned session wrote, for the failure message. Best effort: a child that died
/// before writing anything has no output to read, and its exit is still the error worth reporting.
private func lastSpawnedSessionOutputLines(childSessionID: String) -> [String] {
    guard
        let tail = try? TerminalService.sendProfileCommand(.terminalTail(.init(sessionID: childSessionID, lineCount: 20)), timeout: 5).terminalOutput
    else { return [] }
    return AgentSpawnReadiness.lastNonBlankLines(inTail: tail)
}

/// One readiness poll of a session spawned on a paired device, read from the device overview's terminal
/// session summary (`SpacesDeviceClient.terminalSessions`). This is the remote analogue of
/// `spawnedSessionSnapshot`: the summary carries the daemon's live foreground detection and run state
/// over the wire, so a spawned-but-unsignaled remote session reports its detected kind even though no
/// agent-orchestration row exists yet. The detected-kind wire field is the kind's raw value; an
/// unrecognized value maps to nil so the poll keeps going. A session the overview does not carry reports
/// no state, which also leaves the poll running.
private func remoteSpawnedSessionSnapshot(childSessionID: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp) throws
    -> AgentSpawnReadiness.SessionSnapshot
{
    let summaries = try SpacesDeviceClient.terminalSessions(device: device, clientApp: clientApp)
    guard let summary = summaries.first(where: { $0.id == childSessionID }) else { return .init(detectedKind: nil, state: nil) }
    return .init(detectedKind: summary.foregroundDetectedAgentKind.flatMap(TerminalDetectedAgentKind.init(rawValue:)), state: summary.state)
}

/// The last lines a session spawned on a paired device wrote, for the failure message. Best effort for
/// the same reason as `lastSpawnedSessionOutputLines`.
private func lastRemoteSpawnedSessionOutputLines(childSessionID: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp)
    -> [String]
{
    guard let tail = try? SpacesDeviceClient.tailTerminalOutput(sessionID: childSessionID, lines: 20, device: device, clientApp: clientApp) else {
        return []
    }
    return AgentSpawnReadiness.lastNonBlankLines(inTail: tail)
}

/// The agent-session row id bound to a child terminal session, or nil when none exists yet (the child
/// has not reported a hook signal). Unlike `resolvedAgentRowID`, a missing row is not an error: spawn's
/// auto-subscribe skips cleanly when the row has not appeared.
private func resolvedAgentRowIDIfPresent(forChildTerminalSessionID childSessionID: String) throws -> String? {
    try TerminalService.sendProfileCommand(.agentList(.init(sessionID: childSessionID)), timeout: 5).agentSessions?.first?.id
}

/// Spawns a coding agent on a paired device and blocks until the device's foreground classifier
/// identifies it — detection-based readiness, matching the local path. The Device API carries the
/// daemon's foreground detection over the wire on the terminal session summary
/// (`SpacesDeviceTerminalSessionSummary.foregroundDetectedAgentKind`), read from the device overview, so
/// a remote client polls detection and the child's run state just as the local CLI polls the session's
/// own runtime state — including the fail-fast on a child that ends first. Detection is read from
/// the terminal summary, not `listAgentSessions`, because the spawned `.agent` session has no
/// agent-orchestration row until its first hook signal (a promptless Codex never signals). It delivers
/// no prompt: the orchestrator sends the prompt through the device terminal-input path and confirms work
/// itself. Auto-subscribes the spawning terminal to the remote child as a cross-device watch edge, but
/// only once the child has an agent row on the device (cross-device subscribe validates against the
/// remote agent listing, which is empty until the first hook signal) — no row → skip cleanly, matching
/// local. Returns the spawn result carrying the device id so the `open` deep link is device-qualified.
func performRemoteAgentSpawn(
    device: SpacesPairedDeviceRecord, workspace: String, command: String, title: String?, timeoutSeconds: Int, subscriberSessionID: String?,
    pollInterval: TimeInterval = 0.5
) throws -> AgentSpawnResult {
    let clientApp = cliDeviceClientApp()
    let spawnResponse = try SpacesDeviceClient.spawnAgentSession(
        workspaceID: workspace, command: command, title: title, device: device, clientApp: clientApp)
    guard let childSessionID = spawnResponse.sessionID else {
        throw WorkspaceError.invalidArgument(message: "\(device.name) did not return an agent session.")
    }
    let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))

    let detected: TerminalDetectedAgentKind
    switch try AgentSpawnReadiness.awaitReadiness(
        deadline: deadline, pollInterval: pollInterval,
        snapshot: { try remoteSpawnedSessionSnapshot(childSessionID: childSessionID, device: device, clientApp: clientApp) })
    {
    case .detected(let kind): detected = kind
    case .ended(let state):
        throw AgentSpawnChildExitedError(
            sessionID: childSessionID, command: command, state: state,
            lastOutputLines: lastRemoteSpawnedSessionOutputLines(childSessionID: childSessionID, device: device, clientApp: clientApp),
            deviceName: device.name)
    case .timedOut: throw AgentSpawnRemoteDetectionTimeoutError(sessionID: childSessionID, command: command, timeoutSeconds: timeoutSeconds)
    }

    var subscribed = false
    if let subscriberSessionID, subscriberSessionID != childSessionID,
        try SpacesDeviceClient.listAgentSessions(sessionID: childSessionID, device: device, clientApp: clientApp).contains(where: {
            $0.terminalSessionID == childSessionID
        })
    {
        // The cross-device watch edge is recorded on the local daemon (which owns this terminal); it
        // keys on the child's terminal session id and names the device the child lives on.
        _ = try TerminalService.sendProfileCommand(
            .agentSubscribe(.init(subscriberTerminalSessionID: subscriberSessionID, agentSessionID: childSessionID, deviceID: device.id)), timeout: 30
        )
        subscribed = true
    }

    return AgentSpawnResult(
        terminalSessionID: childSessionID, workspaceID: workspace, detectedAgent: detected.displayLabel, deviceID: device.id, subscribed: subscribed)
}

/// Raised when a remote spawned agent's process is never identified as a running coding agent within the
/// readiness budget — the device's foreground classifier saw nothing. The session is left running on the
/// device for inspection. Mirrors the local `AgentSpawnDetectionTimeoutError` (remote readiness is
/// detection-based, not signal-based).
struct AgentSpawnRemoteDetectionTimeoutError: LocalizedError {
    let sessionID: String
    let command: String
    let timeoutSeconds: Int

    var errorDescription: String? {
        "Remote agent session \(sessionID) was not detected as a running coding agent within \(timeoutSeconds)s (foreground classification never identified `\(command)`). The session is left running; inspect with: spaces terminal tail \(sessionID) --device <name>"
    }
}

/// Resolves the agent-session row id watched by a subscription, given the child's terminal session id.
/// Subscriptions target the agent **row** id, but users address the child by its terminal session id,
/// so this bridges the two through the daemon's agent listing. Errors loudly when the child has no
/// agent row (it has not signaled its hooks yet).
func resolvedAgentRowID(forChildTerminalSessionID childSessionID: String) throws -> String {
    let rows = try TerminalService.sendProfileCommand(.agentList(.init(sessionID: childSessionID)), timeout: 5).agentSessions ?? []
    guard let row = rows.first else {
        throw ValidationError(
            "No agent session for terminal \(childSessionID). The child must have reported a lifecycle signal before it can be watched.")
    }
    return row.id
}

/// Resolves the subscriber terminal session id for `agent subscribe`/`unsubscribe`, defaulting to the
/// current Spaces terminal's `SPACES_TERMINAL_TRACKING_ID`. Errors when neither is available.
func resolvedSubscriberSessionID(_ subscriber: String?, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
    if let subscriber = subscriber?.trimmingCharacters(in: .whitespacesAndNewlines), !subscriber.isEmpty { return subscriber }
    let envValue = environment[WorkspaceOrchestrator.terminalTrackingIDEnvVar]?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let envValue, !envValue.isEmpty { return envValue }
    throw ValidationError("--subscriber is required, or run inside a Spaces terminal so \(WorkspaceOrchestrator.terminalTrackingIDEnvVar) is set.")
}

struct AgentSpawnCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spawn", abstract: "Start a coding agent in a new Spaces terminal and block until it is detected running.",
        discussion: """
            Readiness is foreground detection: spawn returns once the daemon's foreground classifier
            identifies the coding agent in the new terminal — not when it emits a hook signal (a
            promptless Codex never does). Hooks are not required to spawn; they enrich live status when
            present. Spawn delivers no prompt — to give the agent work, the orchestrator sends input
            with `spaces terminal send <id>` and confirms progress with `spaces terminal tail <id>` /
            `spaces agent status`; the orchestrator can also see and answer any first-run trust,
            onboarding, or auth dialog that spawn's detection cannot. The command runs through an
            interactive login shell, so it resolves the same binaries a Spaces terminal does. If the
            command ends without ever being detected spawn fails at that moment and reports the child's
            exit and last output; if it keeps running but is never detected, spawn errors at the timeout
            and leaves the session running for inspection with `spaces terminal tail <id>`.
            --device spawns on a paired device, detected the same way over the Device API.
            """)

    @Option(name: .long, help: "Command that launches a supported coding agent (claude, codex, or opencode).") var command: String
    @Option(name: .long, help: "Workspace ID. Defaults to the workspace containing the current directory. Required with --device.") var workspace:
        String?
    @Option(name: .long, help: "Window or session title. Defaults to the coding agent's name.") var title: String?
    @Option(name: .long, help: "Seconds to wait for detection before giving up.") var timeout: Int = 90
    @Option(name: .long, help: "Paired device name or ID. Spawns on that device and requires --workspace. Defaults to this machine.") var device:
        String?
    @Flag(name: .long, help: "Emit machine-readable JSON.") var json = false

    func run() throws {
        let context = CLIContext()
        let subscriber = ProcessInfo.processInfo.environment[WorkspaceOrchestrator.terminalTrackingIDEnvVar]?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let subscriberSessionID = (subscriber?.isEmpty == false) ? subscriber : nil
        let result: AgentSpawnResult
        if let device {
            // Validate the required workspace before resolving the device so `--device` without
            // `--workspace` fails with the actionable message rather than a device-lookup error.
            guard let workspace = workspace?.trimmingCharacters(in: .whitespacesAndNewlines), !workspace.isEmpty else {
                throw ValidationError("--workspace is required with --device: a remote spawn cannot infer the workspace from the current directory.")
            }
            let record = try SpacesPairedDeviceSelection.resolve(device)
            result = try performRemoteAgentSpawn(
                device: record, workspace: workspace, command: command, title: title, timeoutSeconds: timeout,
                subscriberSessionID: subscriberSessionID)
        } else {
            result = try performAgentSpawn(
                cwd: context.currentDirectoryPath(), workspace: workspace, command: command, title: title, timeoutSeconds: timeout,
                subscriberSessionID: subscriberSessionID)
        }
        if json {
            try context.output.emitJSON(result)
            return
        }
        context.output.emit(agentSpawnResultLine(result))
    }
}

/// Renders an `agent spawn` result as tab-separated key/value columns, leading with the child terminal
/// session id (the target for `terminal send`, `terminal tail`, `agent status`, and the `open` deep
/// link). A remote result's `deviceID` qualifies the deep link so it resolves on the child's device.
func agentSpawnResultLine(_ result: AgentSpawnResult) -> String {
    [
        result.terminalSessionID, "detected=\(result.detectedAgent)", "workspace=\(result.workspaceID ?? "-")", "subscribed=\(result.subscribed)",
        "open=\(result.open)",
    ].joined(separator: "\t")
}

struct AgentKillCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "kill", abstract: "Terminate a coding-agent session and its terminal.")

    @Argument(help: "Child terminal session ID to terminate.") var session: String
    @Option(name: .long, help: "Paired device name or ID. Defaults to this machine's local sessions.") var device: String?

    func run() throws {
        let context = CLIContext()
        if let device {
            let record = try SpacesPairedDeviceSelection.resolve(device)
            // The remote daemon's `killAgentSession` runs the same notify-then-stop flow as the local
            // `.agentKill`: a hook-signaled child's subscribers are told it exited before its row is
            // deleted, and a not-yet-signaled `.agent`-kind session is terminated — one call covers both.
            let response = try SpacesDeviceClient.killAgentSession(sessionID: session, device: record, clientApp: cliDeviceClientApp())
            context.output.emit(response.message)
            return
        }
        let response = try TerminalService.sendProfileCommand(.agentKill(.init(sessionID: session)))
        context.output.emit(response.message)
    }
}

struct AgentSubscribeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "subscribe", abstract: "Watch a child coding-agent session from the current (or an explicit) terminal.")

    @Argument(help: "Child terminal session ID to watch.") var session: String
    @Option(name: .long, help: "Subscriber terminal session ID. Defaults to SPACES_TERMINAL_TRACKING_ID.") var subscriber: String?
    @Option(name: .long, help: "Paired device name or ID the child runs on. Records a cross-device watch. Defaults to this machine.") var device:
        String?

    func run() throws {
        let context = CLIContext()
        let subscriberSessionID = try resolvedSubscriberSessionID(subscriber)
        if let device {
            // The subscriber is always a local terminal: the watching daemon (this machine) owns it and
            // does the watching. The child's terminal session id is passed as-is; the local daemon
            // validates it against the remote device and records the cross-device edge.
            let record = try SpacesPairedDeviceSelection.resolve(device)
            let response = try TerminalService.sendProfileCommand(
                .agentSubscribe(.init(subscriberTerminalSessionID: subscriberSessionID, agentSessionID: session, deviceID: record.id)), timeout: 30)
            context.output.emit(response.message)
            return
        }
        let agentRowID = try resolvedAgentRowID(forChildTerminalSessionID: session)
        let response = try TerminalService.sendProfileCommand(
            .agentSubscribe(.init(subscriberTerminalSessionID: subscriberSessionID, agentSessionID: agentRowID)), timeout: 5)
        context.output.emit(response.message)
    }
}

struct AgentUnsubscribeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unsubscribe", abstract: "Stop watching a child coding-agent session from the current (or an explicit) terminal.")

    @Argument(help: "Child terminal session ID to stop watching.") var session: String
    @Option(name: .long, help: "Subscriber terminal session ID. Defaults to SPACES_TERMINAL_TRACKING_ID.") var subscriber: String?
    @Option(name: .long, help: "Paired device name or ID the child runs on (for a cross-device watch). Defaults to this machine.") var device: String?

    func run() throws {
        let context = CLIContext()
        let subscriberSessionID = try resolvedSubscriberSessionID(subscriber)
        if let device {
            // A cross-device edge keys on the child's terminal session id, so unsubscribe needs no remote
            // call and works even when the device is offline.
            let record = try SpacesPairedDeviceSelection.resolve(device)
            let response = try TerminalService.sendProfileCommand(
                .agentUnsubscribe(.init(subscriberTerminalSessionID: subscriberSessionID, agentSessionID: session, deviceID: record.id)), timeout: 5)
            context.output.emit(response.message)
            return
        }
        let agentRowID = try resolvedAgentRowID(forChildTerminalSessionID: session)
        let response = try TerminalService.sendProfileCommand(
            .agentUnsubscribe(.init(subscriberTerminalSessionID: subscriberSessionID, agentSessionID: agentRowID)), timeout: 5)
        context.output.emit(response.message)
    }
}

struct AgentSignalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "signal", abstract: "Record a lifecycle event for a Spaces terminal session.")

    @Option(name: .long, help: "Workspace ID. Defaults to SPACES_WORKSPACE_ID.") var workspace: String?
    @Option(name: .long, help: "Spaces terminal session ID. Defaults to SPACES_TERMINAL_TRACKING_ID.") var session: String?
    @Argument(
        help: ArgumentHelp("Lifecycle event to record.", discussion: "Allowed values: \(AgentEventType.allValueStrings.joined(separator: ", "))."))
    var type: AgentEventType

    func run() throws {
        guard let context = try Self.resolvedSignalContext(workspace: workspace, session: session, environment: ProcessInfo.processInfo.environment)
        else { return }
        let cliContext = CLIContext()
        _ = try TerminalService.sendProfileCommand(
            .agentSignal(.init(workspaceID: context.workspaceID, terminalSessionID: context.sessionID, event: type.rawValue)))
        cliContext.output.emit("Agent \(type.rawValue): workspace=\(context.workspaceID)")
    }

    /// Resolves the workspace and session to signal for, or `nil` when this is not a Spaces-managed
    /// terminal and the caller supplied nothing — the case that lets globally-installed agent hooks run
    /// harmlessly in any terminal.
    ///
    /// Passing one ID explicitly and not the other is a different situation: the caller meant to name a
    /// session, so silently reporting nothing would hide their mistake. That errors instead.
    static func resolvedSignalContext(workspace: String?, session: String?, environment: [String: String]) throws -> (
        workspaceID: String, sessionID: String
    )? {
        let workspaceID = nonEmpty(workspace) ?? nonEmpty(environment["SPACES_WORKSPACE_ID"])
        let sessionID = nonEmpty(session) ?? nonEmpty(environment[WorkspaceOrchestrator.terminalTrackingIDEnvVar])
        if let workspaceID, let sessionID { return (workspaceID, sessionID) }
        guard nonEmpty(workspace) == nil, nonEmpty(session) == nil else {
            throw ValidationError("--workspace and --session must be given together, or both omitted to use the Spaces terminal environment.")
        }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

struct MCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mcp", abstract: "Run the Spaces MCP stdio server.")

    func run() throws { try SpacesMCPStdioServer().run() }
}

struct PairingWindowPayload: Codable, Sendable, Equatable {
    let name: String
    let hosts: [String]
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
        name: link.name, hosts: link.hosts, port: link.port, pairingNonce: link.nonce, pairingCode: link.code,
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

struct DaemonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon", abstract: "Manage the spacesd daemon on this device.", subcommands: [DaemonApplyUpdateCommand.self])
}

struct DaemonApplyUpdateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply-update", abstract: "Ask the running daemon to apply a staged binary update in place (running sessions keep running).",
        discussion: """
            Sends the frozen applyStagedUpdate command to this device's spacesd over its local socket.
            The daemon quiesces its terminal sessions, writes a handoff table, and execs its already-staged
            binary at the same pid, so running shells, coding agents, and workspace processes are not
            interrupted. This is the mechanism the Linux installer uses to apply a reinstall without a
            systemd restart; it does not start spacesd and does not retry if the daemon is not reachable.
            """)

    func run() throws {
        let context = CLIContext()
        let socketPath = try TerminalServicePaths.socketPath()
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw WorkspaceError.invalidArgument(message: "spacesd is not running for this user. Expected daemon socket at \(socketPath).")
        }
        let response = try TerminalServiceClient.send(
            request: TerminalServiceRequest(command: .applyStagedUpdate), socketPath: socketPath, timeout: 5)
        guard response.ok else { throw TerminalServiceError.requestFailed(response.message) }
        context.output.emit(response.message)
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
    static let configuration = CommandConfiguration(commandName: "command", abstract: "Start an ad hoc terminal session in a workspace.")

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
    @Flag(
        name: .long,
        help:
            "Submit the text: send it as a paste, then a separate Enter keystroke (carriage return) so every supported agent TUI (Claude Code, Codex, OpenCode) runs the line instead of leaving it as an unsubmitted paste."
    ) var submit = false
    @Option(name: .long, help: "Paired device name or ID. Defaults to this machine's local sessions.") var device: String?

    func run() throws { try sendTerminalInput(.text(text), sessionID: sessionID, appendNewline: submit, device: device) }
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
    static let configuration = CommandConfiguration(
        commandName: "tail", abstract: "Show recent rendered output, omitting inline suggestions in identified agent sessions.")

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
