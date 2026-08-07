import Foundation
import spacesdevicecore
import spacesterminalcore

/// In-memory Device API backend for Demo Mode. Serves the bundled recording through the same client
/// paths a real daemon would: request round trips resolve from an in-memory overview + recorded
/// terminal frames, and session subscriptions replay the recorded frame immediately (matching the
/// daemon's "first frame right after subscribe" semantics the client's stream subscription relies on).
///
/// The backend is view-only. Terminal input (`send`/`key`/`takeover`/paste) is refused with a friendly
/// notice, and the mutations the UI actually offers (workspace/process/agent run-stop-restart) flip
/// in-memory row state and return the refreshed overview the daemon returns. All mutations are
/// session-lifetime only; relaunching reloads the pristine bundle.
///
/// Starting a row that has no recorded session of its own (a `notStarted` row, whether started directly
/// or by a workspace launch) synthesizes consistent state: the row is given a deterministic synthetic
/// session and process/agent id, and a matching session summary is published, so the launched row opens
/// a real terminal. The synthetic session replays the recording of a same-kind, same-name recorded slug,
/// resolved through `syntheticSessionAlias` on every stream/state path.
actor DemoDeviceBackend: SpacesDeviceAPIBackend {
    /// Shown when a viewer tries to type into a demo terminal.
    static let terminalInputRejection = "Terminal input requires a paired Mac (Demo Mode)."
    /// Shown for capabilities that have no meaning without a real paired Mac.
    static let unavailableInDemo = "Not available in Demo Mode."
    /// Shown for any command the demo backend does not model.
    static let unsupportedInDemo = "This action is not available in Demo Mode."

    private let library: DemoRecordingLibrary
    private var overview: SpacesDeviceOverviewPayload
    /// The last viewport each session was resized to. The recorded snapshot stays at its captured grid;
    /// this only patches `runtimeState.columns/rows` so the viewer sees its own size acknowledged.
    private var requestedGridBySession: [String: DemoRecordingGrid] = [:]
    /// Synthetic session ids minted for started `notStarted` rows, mapped to the recorded slug they
    /// replay. Resolved on every stream/state path so the synthesized session serves a real recording.
    private var syntheticSessionAlias: [String: String] = [:]

    init(library: DemoRecordingLibrary) {
        self.library = library
        overview = library.overview
    }

    /// Loads the bundled recording and builds a backend. Throws if the bundle is missing or malformed.
    static func makeDefault(bundle: Bundle = .main) throws -> DemoDeviceBackend {
        DemoDeviceBackend(library: try DemoRecordingLibrary.load(bundle: bundle))
    }

    // MARK: - SpacesDeviceAPIBackend

    nonisolated func makeRequestTransport() -> any SpacesDeviceAPIRequestTransport { DemoRequestTransport(backend: self) }

    nonisolated func openSessionStream(
        request: SpacesDeviceAPIRequest, onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
        onDisconnect: @escaping @MainActor (Error?) -> Void
    ) async throws -> SpacesDeviceAPIStreamHandle {
        guard case .subscribe(let subscription) = request.command else { throw DemoRecordingLibraryError.recordingMissing(sessionID: "unknown") }
        let sessionID = subscription.sessionID
        let lifecycle = DemoStreamLifecycle(onDisconnect: onDisconnect)
        let task = Task {
            let payload = await recordedPayload(forSessionID: sessionID)
            guard !Task.isCancelled else { return }
            if let payload {
                await MainActor.run { onEvent(payload) }
            } else {
                lifecycle.finish(error: DemoRecordingLibraryError.recordingMissing(sessionID: sessionID))
            }
        }
        return SpacesDeviceAPIStreamHandle {
            task.cancel()
            lifecycle.finish(error: nil)
        }
    }

    // MARK: - Request handling

    func serve(_ request: SpacesDeviceAPIRequest) -> SpacesDeviceAPIResponse {
        switch request.command {
        case .ping: return ok()
        case .overview: return SpacesDeviceAPIResponse(ok: true, message: "Loaded device overview.", result: .overview(overview))
        case .daemonStatus: return SpacesDeviceAPIResponse(ok: true, message: "Loaded daemon status.", result: .daemonStatus(overview.daemonStatus))
        case .state(let request): return serveState(request)
        case .terminalControl(let request): return serveTerminalControl(request)
        case .terminalPasteImage: return reject(Self.terminalInputRejection)

        case .launchWorkspace(let request):
            return serveWorkspaceLifecycle(workspaceID: request.workspaceID, running: true, message: "Started workspace.")
        case .stopWorkspace(let request):
            return serveWorkspaceLifecycle(workspaceID: request.workspaceID, running: false, message: "Stopped workspace.")
        case .restartWorkspace(let request):
            return serveWorkspaceLifecycle(workspaceID: request.workspaceID, running: true, message: "Restarted workspace.")

        case .runWorkspaceProcess(let request):
            return serveProcessMutation(
                workspaceID: request.workspaceID, running: true, message: "Started process.",
                matches: { matchesProcess($0, processID: nil, processKey: request.processKey, processTemplateID: request.processTemplateID) })
        case .stopWorkspaceProcess(let request):
            return serveProcessMutation(
                workspaceID: request.workspaceID, running: false, message: "Stopped process.",
                matches: {
                    matchesProcess($0, processID: request.processID, processKey: request.processKey, processTemplateID: request.processTemplateID)
                })
        case .restartWorkspaceProcess(let request):
            return serveProcessMutation(
                workspaceID: request.workspaceID, running: true, message: "Restarted process.",
                matches: {
                    matchesProcess($0, processID: request.processID, processKey: request.processKey, processTemplateID: request.processTemplateID)
                })

        case .stopCodingAgent(let request):
            return serveStopAgent(
                workspaceID: request.workspaceID, matches: { matchesAgent($0, agentID: request.agentID) })

        case .createWorkspace, .createProject, .importProject, .exportProject, .deleteProject, .pair, .requestDaemonRestart, .resolveTerminalLink,
            .readTerminalLinkChunk:
            return reject(Self.unavailableInDemo)

        default: return reject(Self.unsupportedInDemo)
        }
    }

    private func serveState(_ request: SpacesDeviceTerminalSessionRequest) -> SpacesDeviceAPIResponse {
        guard let payload = recordedPayload(forSessionID: request.sessionID) else {
            return SpacesDeviceAPIResponse(ok: false, message: "No terminal state for \(request.sessionID) in Demo Mode.", errorCode: .notFound)
        }
        return SpacesDeviceAPIResponse(ok: true, message: "Loaded terminal state.", result: .terminalState(payload))
    }

    /// Terminal control in Demo Mode is view-only: attach/detach/scroll/appearance are accepted no-ops,
    /// resize records the requested viewport so subsequent frames report it, and anything that would
    /// write to the pty (send/key/takeover/mouseButton) is refused with the demo-input notice.
    private func serveTerminalControl(_ request: SpacesDeviceTerminalControlRequest) -> SpacesDeviceAPIResponse {
        switch request.action {
        case .attach, .detach, .heartbeat, .scroll, .clearScreen, .setAppearance: return ok()
        case .resize:
            if let columns = request.columns, let rows = request.rows {
                requestedGridBySession[request.sessionID] = DemoRecordingGrid(columns: columns, rows: rows)
            }
            return ok()
        case .send, .key, .takeover, .mouseButton: return reject(Self.terminalInputRejection)
        }
    }

    // MARK: - Stream support

    private func recordedPayload(forSessionID sessionID: String) -> GhosttyRemoteSessionStatePayload? {
        // A synthesized session aliases to a recorded slug; a recorded session aliases to itself.
        let slug = syntheticSessionAlias[sessionID] ?? sessionID
        let requested = requestedGridBySession[sessionID]
        guard let payload = library.payload(forSessionSlug: slug, requested: requested) else { return nil }
        guard let requested, let runtimeState = payload.runtimeState else { return payload }
        // The recorded snapshot stays at its captured grid; only the runtime dimensions follow the
        // viewer's resize, mirroring how a real daemon acks a resize before the next render lands.
        let resized = runtimeState.demoResized(columns: requested.columns, rows: requested.rows)
        return payload.demoReplacingRuntimeState(resized)
    }

    // MARK: - Mutations

    private func serveWorkspaceLifecycle(workspaceID: String, running: Bool, message: String) -> SpacesDeviceAPIResponse {
        guard let workspace = overview.workspaces.first(where: { $0.id == workspaceID }) else { return notFound("workspace") }
        var declined = false
        var syntheses: [SynthesizedSession] = []
        let processRows = workspace.processRows.map { row -> SpacesDeviceWorkspaceProcessRow in
            guard running else { return row.demoStopped(at: Self.nowTimestamp()) }
            guard let started = startedProcessRow(row) else {
                declined = true
                return row
            }
            if let synthesis = started.synthesis { syntheses.append(synthesis) }
            return started.row
        }
        // Stopping a workspace stops its live agents; starting one leaves agent rows untouched, because
        // agents only come into existence from a command run in a terminal, never from workspace launch.
        let agentRows = workspace.codingAgentRows.map { row -> SpacesDeviceWorkspaceCodingAgentRow in
            running ? row : row.demoStopped(at: Self.nowTimestamp())
        }
        guard !declined else { return reject(Self.unsupportedInDemo) }
        commitMutation(workspaceID: workspaceID, processRows: processRows, codingAgentRows: agentRows, syntheses: syntheses)
        return mutationResponse(message: message, workspaceID: workspaceID)
    }

    private func serveProcessMutation(workspaceID: String, running: Bool, message: String, matches: (SpacesDeviceWorkspaceProcessRow) -> Bool)
        -> SpacesDeviceAPIResponse
    {
        guard let workspace = overview.workspaces.first(where: { $0.id == workspaceID }) else { return notFound("workspace") }
        var didMatch = false
        var declined = false
        var syntheses: [SynthesizedSession] = []
        let processRows = workspace.processRows.map { row -> SpacesDeviceWorkspaceProcessRow in
            guard matches(row) else { return row }
            didMatch = true
            guard running else { return row.demoStopped(at: Self.nowTimestamp()) }
            guard let started = startedProcessRow(row) else {
                declined = true
                return row
            }
            if let synthesis = started.synthesis { syntheses.append(synthesis) }
            return started.row
        }
        guard didMatch else { return notFound("process") }
        guard !declined else { return reject(Self.unsupportedInDemo) }
        commitMutation(workspaceID: workspaceID, processRows: processRows, codingAgentRows: workspace.codingAgentRows, syntheses: syntheses)
        return mutationResponse(message: message, workspaceID: workspaceID)
    }

    /// Stop is the only lifecycle control a coding agent has: an agent exists only as a live session
    /// someone started by running its command in a terminal, so there is nothing to start or restart.
    private func serveStopAgent(workspaceID: String, matches: (SpacesDeviceWorkspaceCodingAgentRow) -> Bool) -> SpacesDeviceAPIResponse {
        guard let workspace = overview.workspaces.first(where: { $0.id == workspaceID }) else { return notFound("workspace") }
        var didMatch = false
        let agentRows = workspace.codingAgentRows.map { row -> SpacesDeviceWorkspaceCodingAgentRow in
            guard matches(row) else { return row }
            didMatch = true
            return row.demoStopped(at: Self.nowTimestamp())
        }
        guard didMatch else { return notFound("agent") }
        commitMutation(workspaceID: workspaceID, processRows: workspace.processRows, codingAgentRows: agentRows, syntheses: [])
        return mutationResponse(message: "Stopped agent.", workspaceID: workspaceID)
    }

    // MARK: - Session synthesis

    /// A session synthesized for a started `notStarted` row: the alias to register and the summary to
    /// publish, committed together only once the whole mutation is confirmed to proceed.
    private struct SynthesizedSession {
        let sessionID: String
        let slug: String
        let summary: SpacesDeviceTerminalSessionSummary
    }

    /// A started process row plus the session synthesized for it, if any (`nil` for rows that already
    /// own a recorded session).
    private func startedProcessRow(_ row: SpacesDeviceWorkspaceProcessRow) -> (row: SpacesDeviceWorkspaceProcessRow, synthesis: SynthesizedSession?)?
    {
        guard row.sessionID == nil else { return (row.demoRunning(), nil) }
        guard let synthesis = synthesizeSession(kind: "process", workspaceID: row.workspaceID, rowID: row.id, title: row.name) else { return nil }
        let running = SpacesDeviceWorkspaceProcessRow(
            id: row.id, workspaceID: row.workspaceID, name: row.name, command: row.command, templateID: row.templateID,
            processID: synthesis.runtimeID, sessionID: synthesis.session.sessionID, runState: .running, exitedAt: nil, canRun: false, canStop: true,
            canRestart: true)
        return (running, synthesis.session)
    }

    /// Builds the synthetic ids and session summary for a started `notStarted` row, replaying a same-kind,
    /// same-name recorded slug. Returns `nil` when no recorded slug matches the row's name, so the caller
    /// declines the mutation rather than publishing a session with no recording behind it.
    private func synthesizeSession(kind: String, workspaceID: String, rowID: String, title: String) -> (
        runtimeID: String, session: SynthesizedSession
    )? {
        guard let slug = matchedRecordedSlug(kind: kind, title: title), let template = library.overview.sessions.first(where: { $0.id == slug })
        else { return nil }
        // Deterministic per row so repeated mutations in the same backend lifetime reuse one identity.
        let sessionID = "demo-synth-session:\(workspaceID):\(rowID)"
        let runtimeID = "demo-synth-runtime:\(workspaceID):\(rowID)"
        let summary = syntheticSummary(from: template, id: sessionID, workspaceID: workspaceID, title: title, rowSourceID: runtimeID)
        return (runtimeID, SynthesizedSession(sessionID: sessionID, slug: slug, summary: summary))
    }

    /// The deterministic recorded slug a started row of `kind` named `title` replays: the alphabetically
    /// first matching recorded session, so a name shared across workspaces (e.g. "backend") resolves the
    /// same way every time.
    private func matchedRecordedSlug(kind: String, title: String) -> String? {
        library.manifest.sessions.filter { $0.kind == kind && $0.title == title }.map(\.stableID).min()
    }

    /// A session summary for a synthesized session: the matched slug's summary with a fresh identity,
    /// workspace, title, running state, and load-time timestamps.
    private func syntheticSummary(
        from template: SpacesDeviceTerminalSessionSummary, id: String, workspaceID: String, title: String, rowSourceID: String
    ) -> SpacesDeviceTerminalSessionSummary {
        let timestamp = Self.nowTimestamp()
        return SpacesDeviceTerminalSessionSummary(
            id: id, title: title, workingDirectory: template.workingDirectory, shell: template.shell, command: template.command, state: .running,
            backend: template.backend, lifetimePolicy: template.lifetimePolicy, servicePID: template.servicePID, childPID: template.childPID,
            workspaceID: workspaceID, workspaceTitle: template.workspaceTitle, projectID: template.projectID, projectName: template.projectName,
            createdAt: timestamp, updatedAt: timestamp, isControlAvailable: template.isControlAvailable,
            isSubscriptionAvailable: template.isSubscriptionAvailable, attachmentSnapshot: template.attachmentSnapshot, rowKind: template.rowKind,
            rowSourceID: rowSourceID, hasFinalRender: template.hasFinalRender, foregroundDetectedAgentKind: template.foregroundDetectedAgentKind)
    }

    /// Registers the synthesized aliases and publishes their summaries, then replaces the workspace's rows
    /// — the single commit point every mutation reaches once it is confirmed to proceed.
    private func commitMutation(
        workspaceID: String, processRows: [SpacesDeviceWorkspaceProcessRow], codingAgentRows: [SpacesDeviceWorkspaceCodingAgentRow],
        syntheses: [SynthesizedSession]
    ) {
        var sessions = overview.sessions
        for synthesis in syntheses {
            syntheticSessionAlias[synthesis.sessionID] = synthesis.slug
            if let index = sessions.firstIndex(where: { $0.id == synthesis.sessionID }) {
                sessions[index] = synthesis.summary
            } else {
                sessions.append(synthesis.summary)
            }
        }
        let workspace = overview.workspaces.first { $0.id == workspaceID }
        guard let workspace else { return }
        let updated = workspace.demoWith(processRows: processRows, codingAgentRows: codingAgentRows)
        overview = overview.demoReplacing(workspaceID: workspaceID, workspace: updated, sessions: sessions)
    }

    // MARK: - Response builders

    private func ok() -> SpacesDeviceAPIResponse { SpacesDeviceAPIResponse(ok: true, message: "OK") }

    private func reject(_ message: String) -> SpacesDeviceAPIResponse {
        SpacesDeviceAPIResponse(ok: false, message: message, errorCode: .capabilityMissing)
    }

    private func notFound(_ subject: String) -> SpacesDeviceAPIResponse {
        SpacesDeviceAPIResponse(ok: false, message: "No such \(subject) in Demo Mode.", errorCode: .notFound)
    }

    private func mutationResponse(message: String, workspaceID: String?) -> SpacesDeviceAPIResponse {
        SpacesDeviceAPIResponse(
            ok: true, message: message, result: .mutation(SpacesDeviceMutationResult(overview: overview, workspaceID: workspaceID)))
    }

    private static func nowTimestamp() -> String { TerminalSessionTimestamp.string(from: Date()) }
}

/// Matches a process row against whatever identifier the request carried (id, template, or key).
private func matchesProcess(_ row: SpacesDeviceWorkspaceProcessRow, processID: String?, processKey: String?, processTemplateID: String?) -> Bool {
    if let processID, processID == row.processID || processID == row.id { return true }
    if let processTemplateID, processTemplateID == row.templateID { return true }
    if let processKey, processKey == row.name { return true }
    return false
}

private func matchesAgent(_ row: SpacesDeviceWorkspaceCodingAgentRow, agentID: String?) -> Bool {
    guard let agentID else { return false }
    return agentID == row.agentID || agentID == row.id
}

/// Forwards a demo request into the backing actor. `close` is a no-op — there is no connection to tear
/// down.
private struct DemoRequestTransport: SpacesDeviceAPIRequestTransport {
    let backend: DemoDeviceBackend

    func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse { await backend.serve(request) }
    func close() async {}
}

/// Guards the one-shot `onDisconnect` callback and dispatches it to the main actor, mirroring the
/// network backend's stream lifecycle.
private final class DemoStreamLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let onDisconnect: @MainActor (Error?) -> Void

    init(onDisconnect: @escaping @MainActor (Error?) -> Void) { self.onDisconnect = onDisconnect }

    func finish(error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        Task { @MainActor in onDisconnect(error) }
    }
}

// MARK: - In-memory row edits

extension SpacesDeviceOverviewPayload {
    /// Returns a copy with one workspace and the session list replaced. Projects and daemon status carry
    /// through unchanged. Sessions are replaced wholesale so a mutation can publish synthesized session
    /// summaries alongside the mutated workspace in one step.
    fileprivate func demoReplacing(workspaceID: String, workspace: SpacesDeviceWorkspaceSummary, sessions: [SpacesDeviceTerminalSessionSummary])
        -> SpacesDeviceOverviewPayload
    {
        let workspaces = workspaces.map { $0.id == workspaceID ? workspace : $0 }
        // The demo daemon retains exactly the sessions it publishes: every demo session is either a
        // recorded replay or a synthesized row-backed session, so the keep-set is the session ids.
        return SpacesDeviceOverviewPayload(
            projects: projects, workspaces: workspaces, sessions: sessions, retainedTerminalSessionIDs: sessions.map(\.id).sorted(),
            daemonStatus: daemonStatus)
    }
}

extension SpacesDeviceWorkspaceSummary {
    /// Rebuilds the workspace with new process/agent rows, recomputing `isRunning` from them so the
    /// summary stays internally consistent after a mutation.
    fileprivate func demoWith(processRows: [SpacesDeviceWorkspaceProcessRow], codingAgentRows: [SpacesDeviceWorkspaceCodingAgentRow])
        -> SpacesDeviceWorkspaceSummary
    {
        let running = processRows.contains { $0.runState == .running } || codingAgentRows.contains { $0.runState == .running }
        return SpacesDeviceWorkspaceSummary(
            id: id, projectID: projectID, projectName: projectName, branch: branch, baseBranch: baseBranch, dir: dir, isRunning: running,
            isHidden: isHidden, isDefault: isDefault, notes: notes, sessionCount: sessionCount, assignedPorts: assignedPorts,
            environment: environment, setupState: setupState, config: config, processRows: processRows, codingAgentRows: codingAgentRows,
            terminalRows: terminalRows)
    }
}

extension SpacesDeviceWorkspaceProcessRow {
    fileprivate func demoRunning() -> SpacesDeviceWorkspaceProcessRow {
        SpacesDeviceWorkspaceProcessRow(
            id: id, workspaceID: workspaceID, name: name, command: command, templateID: templateID, processID: processID, sessionID: sessionID,
            runState: .running, exitedAt: nil, canRun: false, canStop: true, canRestart: true)
    }

    fileprivate func demoStopped(at exitedAt: String) -> SpacesDeviceWorkspaceProcessRow {
        SpacesDeviceWorkspaceProcessRow(
            id: id, workspaceID: workspaceID, name: name, command: command, templateID: templateID, processID: processID, sessionID: sessionID,
            runState: .exited, exitedAt: exitedAt, canRun: true, canStop: false, canRestart: false)
    }
}

extension SpacesDeviceWorkspaceCodingAgentRow {
    fileprivate func demoStopped(at updatedAt: String) -> SpacesDeviceWorkspaceCodingAgentRow {
        SpacesDeviceWorkspaceCodingAgentRow(
            id: id, workspaceID: workspaceID, name: name, command: command, agentID: agentID, sessionID: sessionID, runState: .exited,
            activityState: .exited, updatedAt: updatedAt, canStop: false)
    }
}

extension GhosttyRemoteSessionStatePayload {
    /// Returns a copy carrying a resized `runtimeState`; every other field (including the recorded render
    /// blob) is unchanged.
    fileprivate func demoReplacingRuntimeState(_ runtimeState: TerminalSessionRuntimeState) -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: sessionID, reason: reason, emittedAt: emittedAt, sessionStateRevision: sessionStateRevision,
            sessionStateFlags: sessionStateFlags, screenStateRevision: screenStateRevision, runtimeState: runtimeState,
            attachmentSnapshot: attachmentSnapshot, title: title, workingDirectory: workingDirectory, outputByteCount: outputByteCount,
            outputEndByteOffset: outputEndByteOffset, renderUpdate: renderUpdate)
    }
}

extension TerminalSessionRuntimeState {
    /// Returns a copy with the viewport dimensions replaced, keeping every other runtime field.
    fileprivate func demoResized(columns: Int, rows: Int) -> TerminalSessionRuntimeState {
        TerminalSessionRuntimeState(
            sessionID: sessionID, backend: backend, servicePID: servicePID, childPID: childPID, state: state, updatedAt: updatedAt,
            exitedAt: exitedAt, title: title, workingDirectory: workingDirectory, columns: columns, rows: rows, foregroundPID: foregroundPID,
            foregroundExecutablePath: foregroundExecutablePath, foregroundExecutableName: foregroundExecutableName, foregroundArgv: foregroundArgv,
            foregroundDetectedAgentKind: foregroundDetectedAgentKind, foregroundDisplayLabel: foregroundDisplayLabel,
            foregroundDisplayCommand: foregroundDisplayCommand)
    }
}
