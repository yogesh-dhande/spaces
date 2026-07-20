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
    ) throws -> SpacesDeviceAPIStreamHandle {
        guard case .subscribe(let subscription) = request.command else {
            throw DemoRecordingLibraryError.recordingMissing(sessionID: "unknown")
        }
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

        case .launchWorkspace(let request): return serveWorkspaceLifecycle(workspaceID: request.workspaceID, running: true, message: "Started workspace.")
        case .stopWorkspace(let request): return serveWorkspaceLifecycle(workspaceID: request.workspaceID, running: false, message: "Stopped workspace.")
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

        case .runCodingAgent(let request):
            return serveAgentMutation(
                workspaceID: request.workspaceID, running: true, message: "Started agent.",
                matches: { matchesAgent($0, agentID: nil, agentName: request.agentName, launcherID: request.agentLauncherID) })
        case .stopCodingAgent(let request):
            return serveAgentMutation(
                workspaceID: request.workspaceID, running: false, message: "Stopped agent.",
                matches: { matchesAgent($0, agentID: request.agentID, agentName: request.agentName, launcherID: request.agentLauncherID) })
        case .restartCodingAgent(let request):
            return serveAgentMutation(
                workspaceID: request.workspaceID, running: true, message: "Restarted agent.",
                matches: { matchesAgent($0, agentID: request.agentID, agentName: request.agentName, launcherID: request.agentLauncherID) })

        case .createWorkspace, .createProject, .importProject, .exportProject, .deleteProject, .pair, .requestDaemonRestart, .resolveTerminalLink,
            .readTerminalLinkChunk:
            return reject(Self.unavailableInDemo)

        default:
            return reject(Self.unsupportedInDemo)
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
    /// write to the pty (send/key/takeover) is refused with the demo-input notice.
    private func serveTerminalControl(_ request: SpacesDeviceTerminalControlRequest) -> SpacesDeviceAPIResponse {
        switch request.action {
        case .attach, .detach, .heartbeat, .scroll, .clearScreen, .setAppearance:
            return ok()
        case .resize:
            if let columns = request.columns, let rows = request.rows {
                requestedGridBySession[request.sessionID] = DemoRecordingGrid(columns: columns, rows: rows)
            }
            return ok()
        case .send, .key, .takeover:
            return reject(Self.terminalInputRejection)
        }
    }

    // MARK: - Stream support

    private func recordedPayload(forSessionID sessionID: String) -> GhosttyRemoteSessionStatePayload? {
        let requested = requestedGridBySession[sessionID]
        guard let payload = library.payload(forSessionSlug: sessionID, requested: requested) else { return nil }
        guard let requested, let runtimeState = payload.runtimeState else { return payload }
        // The recorded snapshot stays at its captured grid; only the runtime dimensions follow the
        // viewer's resize, mirroring how a real daemon acks a resize before the next render lands.
        let resized = runtimeState.demoResized(columns: requested.columns, rows: requested.rows)
        return payload.demoReplacingRuntimeState(resized)
    }

    // MARK: - Mutations

    private func serveWorkspaceLifecycle(workspaceID: String, running: Bool, message: String) -> SpacesDeviceAPIResponse {
        guard overview.workspaces.contains(where: { $0.id == workspaceID }) else { return notFound("workspace") }
        overview = overview.demoReplacingWorkspace(id: workspaceID) { workspace in
            let processRows = workspace.processRows.map { running ? $0.demoRunning() : $0.demoStopped(at: Self.nowTimestamp()) }
            let agentRows = workspace.codingAgentRows.map { running ? $0.demoRunning() : $0.demoStopped(at: Self.nowTimestamp()) }
            return workspace.demoWith(processRows: processRows, codingAgentRows: agentRows)
        }
        return mutationResponse(message: message, workspaceID: workspaceID)
    }

    private func serveProcessMutation(
        workspaceID: String, running: Bool, message: String, matches: (SpacesDeviceWorkspaceProcessRow) -> Bool
    ) -> SpacesDeviceAPIResponse {
        guard overview.workspaces.contains(where: { $0.id == workspaceID }) else { return notFound("workspace") }
        var didMatch = false
        overview = overview.demoReplacingWorkspace(id: workspaceID) { workspace in
            let processRows = workspace.processRows.map { row -> SpacesDeviceWorkspaceProcessRow in
                guard matches(row) else { return row }
                didMatch = true
                return running ? row.demoRunning() : row.demoStopped(at: Self.nowTimestamp())
            }
            return workspace.demoWith(processRows: processRows, codingAgentRows: workspace.codingAgentRows)
        }
        guard didMatch else { return notFound("process") }
        return mutationResponse(message: message, workspaceID: workspaceID)
    }

    private func serveAgentMutation(
        workspaceID: String, running: Bool, message: String, matches: (SpacesDeviceWorkspaceCodingAgentRow) -> Bool
    ) -> SpacesDeviceAPIResponse {
        guard overview.workspaces.contains(where: { $0.id == workspaceID }) else { return notFound("workspace") }
        var didMatch = false
        overview = overview.demoReplacingWorkspace(id: workspaceID) { workspace in
            let agentRows = workspace.codingAgentRows.map { row -> SpacesDeviceWorkspaceCodingAgentRow in
                guard matches(row) else { return row }
                didMatch = true
                return running ? row.demoRunning() : row.demoStopped(at: Self.nowTimestamp())
            }
            return workspace.demoWith(processRows: workspace.processRows, codingAgentRows: agentRows)
        }
        guard didMatch else { return notFound("agent") }
        return mutationResponse(message: message, workspaceID: workspaceID)
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
        SpacesDeviceAPIResponse(ok: true, message: message, result: .mutation(SpacesDeviceMutationResult(overview: overview, workspaceID: workspaceID)))
    }

    private static func nowTimestamp() -> String { TerminalSessionTimestamp.string(from: Date()) }
}

/// Matches a process row against whatever identifier the request carried (id, template, or key).
private func matchesProcess(
    _ row: SpacesDeviceWorkspaceProcessRow, processID: String?, processKey: String?, processTemplateID: String?
) -> Bool {
    if let processID, processID == row.processID || processID == row.id { return true }
    if let processTemplateID, processTemplateID == row.templateID { return true }
    if let processKey, processKey == row.name { return true }
    return false
}

/// Matches an agent row against whatever identifier the request carried (id, launcher, or name).
private func matchesAgent(_ row: SpacesDeviceWorkspaceCodingAgentRow, agentID: String?, agentName: String?, launcherID: String?) -> Bool {
    if let agentID, agentID == row.agentID || agentID == row.id { return true }
    if let launcherID, launcherID == row.launcherID { return true }
    if let agentName, agentName == row.name { return true }
    return false
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
    /// Returns a copy with one workspace replaced by `transform`. Other workspaces, projects, sessions,
    /// and daemon status are carried through unchanged.
    fileprivate func demoReplacingWorkspace(
        id: String, _ transform: (SpacesDeviceWorkspaceSummary) -> SpacesDeviceWorkspaceSummary
    ) -> SpacesDeviceOverviewPayload {
        let workspaces = workspaces.map { $0.id == id ? transform($0) : $0 }
        return SpacesDeviceOverviewPayload(projects: projects, workspaces: workspaces, sessions: sessions, daemonStatus: daemonStatus)
    }
}

extension SpacesDeviceWorkspaceSummary {
    /// Rebuilds the workspace with new process/agent rows, recomputing `isRunning` from them so the
    /// summary stays internally consistent after a mutation.
    fileprivate func demoWith(
        processRows: [SpacesDeviceWorkspaceProcessRow], codingAgentRows: [SpacesDeviceWorkspaceCodingAgentRow]
    ) -> SpacesDeviceWorkspaceSummary {
        let running = processRows.contains { $0.runState == .running } || codingAgentRows.contains { $0.runState == .running }
        return SpacesDeviceWorkspaceSummary(
            id: id, projectID: projectID, projectName: projectName, branch: branch, baseBranch: baseBranch, dir: dir, isRunning: running,
            isArchived: isArchived, isHidden: isHidden, isDefault: isDefault, notes: notes, sessionCount: sessionCount, assignedPorts: assignedPorts,
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
    fileprivate func demoRunning() -> SpacesDeviceWorkspaceCodingAgentRow {
        SpacesDeviceWorkspaceCodingAgentRow(
            id: id, workspaceID: workspaceID, name: name, command: command, launcherID: launcherID, agentID: agentID, sessionID: sessionID,
            isConfigured: isConfigured, runState: .running, activityState: .spinning, updatedAt: TerminalSessionTimestamp.string(from: Date()),
            canRun: false, canStop: true, canRestart: true)
    }

    fileprivate func demoStopped(at updatedAt: String) -> SpacesDeviceWorkspaceCodingAgentRow {
        SpacesDeviceWorkspaceCodingAgentRow(
            id: id, workspaceID: workspaceID, name: name, command: command, launcherID: launcherID, agentID: agentID, sessionID: sessionID,
            isConfigured: isConfigured, runState: .exited, activityState: .exited, updatedAt: updatedAt, canRun: true, canStop: false, canRestart: true)
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
