import Foundation
import spacesdevicecore
import spacesterminalcore
import workspacecore

/// Builds the device overview from the store and the persisted terminal sessions.
///
/// Everything instance-specific (the orchestrator, the in-memory sessions a daemon's engine holds, the
/// teardown registry's snapshot, the addresses the Device API advertises) arrives as an input, so the
/// Device API server and the daemon's startup alert settle build the same overview from the same code.
struct SpacesDeviceOverviewLoader {
    let store: SQLiteStore
    /// Only its read calls are used, so the terminator and launcher it carries are never reached.
    let orchestrator: WorkspaceOrchestrator
    /// Catalog entries for live in-process cores that the persisted listing may not carry yet. Empty
    /// where no core exists, such as the daemon's startup before it has adopted or created any.
    let liveInMemorySessions: [TerminalSessionCatalogEntry]
    let workspaceIDsWithTeardownInFlight: [String]
    /// The addresses `daemonStatus` advertises. Empty before the Device API listens.
    let deviceAPIAddresses: [String]

    func load() throws -> SpacesDeviceOverviewPayload {
        // The router port is a Mac-only concept (only the macOS client runs Caddy), so remote
        // daemons never seed one and this fallback yields the canonical `AppConfig.defaultRouterPort`.
        // The reported `assignedPort.url` is a client-facing host/origin identity; the Mac client
        // rewrites the port to its own live Caddy port before navigation.
        let routerPort = (try? orchestrator.appConfig().routerPort) ?? AppConfig.defaultRouterPort
        let projects = try store.projects()
        // Batch the plain per-workspace table reads into one full-table query each, grouped by
        // workspace, so building N descriptors costs a constant number of queries instead of O(N).
        // Each batch preserves the same ORDER BY and WHERE semantics as its per-workspace counterpart,
        // so the grouped values match `store.<x>(workspaceID:)` element-for-element.
        let runningProcessesByWorkspace = try store.runningProcessesByWorkspace()
        let agentWindowsByWorkspace = try store.agentWindowsByWorkspace()
        let windowsByWorkspace = try store.windowsByWorkspace()
        let portsByWorkspace = try store.workspacePortsNamedByWorkspace()
        let setupStateByWorkspace = try store.workspaceSetupStateByWorkspace()
        // One query for the whole build: the tracked-runtime rule classifies a session per retained pane
        // and coding-agent row, and asking per row put a round trip per row on the profile database's
        // serialized lane, growing with every pane a device keeps.
        let endedSessions = try orchestrator.endedTerminalSessions(
            agentWindows: agentWindowsByWorkspace.values.flatMap { $0 }, windows: windowsByWorkspace.values.flatMap { $0 })
        let workspaces = try projects.flatMap { project in
            try store.workspaces(projectID: project.id).map { workspace in
                let slug = SpacesProfile.workspaceHostSlug(
                    branch: workspace.branch, projectName: project.name, isGitRepo: project.isGitRepo, isHomeProject: project.kind == .home,
                    workspaceID: workspace.id)
                // `resolvedWorkspaceBrowserSessions` and `workspaceSettings` stay per-workspace on
                // purpose: they rebuild the workspace's env/runtime plan internally rather than reading a
                // single table, so batching them would require restructuring orchestrator env
                // construction (out of scope for this N+1 pass).
                let resolvedBrowserSessions = try orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspace.id)
                let namedPorts = portsByWorkspace[workspace.id] ?? []
                let runningProcesses = runningProcessesByWorkspace[workspace.id] ?? []
                let agentWindows = agentWindowsByWorkspace[workspace.id] ?? []
                let windows = windowsByWorkspace[workspace.id] ?? []
                return SpacesDeviceOverviewBuilder.WorkspaceDescriptor(
                    project: project, workspace: workspace, settings: try? orchestrator.workspaceSettings(workspaceID: workspace.id),
                    runningProcesses: runningProcesses, agentWindows: agentWindows, windows: windows,
                    hasTrackedRuntimeIndicators: orchestrator.hasTrackedRuntimeIndicators(
                        runningProcesses: runningProcesses, agentWindows: agentWindows, windows: windows, endedSessions: endedSessions),
                    assignedPorts: namedPorts.map {
                        SpacesDeviceAssignedPort(name: $0.name, port: $0.port, url: "http://\($0.name).\(slug).localhost:\(routerPort)")
                    },
                    environment: orchestrator.buildWorkspaceEnv(
                        project: project, workspace: workspace, namedPorts: namedPorts.map { (port: $0.port, name: $0.name) }),
                    resolvedBrowserSessions: resolvedBrowserSessions,
                    // Mirror `orchestrator.workspaceSetupState`, which returns a succeeded default when no
                    // `workspace_settings` row exists for the workspace.
                    setupState: setupStateByWorkspace[workspace.id]
                        ?? WorkspaceSetupState(status: .succeeded, errorMessage: nil, startedAt: nil, finishedAt: nil))
            }
        }
        let localSessions = TerminalSessionCatalog.mergingLiveInMemorySessions(
            try TerminalSessionCatalog.listLiveSessions(), inMemory: liveInMemorySessions)
        let sessions = mergedTerminalSessions(localSessions)
        // One query for the whole build: the alternative asked per row, and each answer opened its own
        // connection and JSON-decoded a ~36 KB payload to test a single field.
        let sessionIDsWithFinalRender = try TerminalSessionPersistence.sessionIDsWithFinalRender()
        let workspaceRows = loadWorkspaceTerminalRows(
            workspaces: workspaces, sessions: sessions, sessionIDsWithFinalRender: sessionIDsWithFinalRender)
        // Reuse the records the overview already scanned to tally restart impact, so the inline
        // handshake costs no extra store work on the refresh hot path.
        var impact = RestartImpactCounts()
        for descriptor in workspaces { impact.accumulate(runningProcesses: descriptor.runningProcesses, agentWindows: descriptor.agentWindows) }
        let daemonStatus = Self.makeDaemonStatus(
            activeSessionCount: localSessions.count, impact: impact, restorableSessions: try store.restorableSessions().map(\.summary),
            deviceAPIAddresses: deviceAPIAddresses)
        let (automationSummaries, automationRunSummaries) = try loadAutomationOverview(liveSessions: localSessions)
        return SpacesDeviceOverviewBuilder.build(
            projects: projects, workspaces: workspaces, workspaceRows: workspaceRows, liveSessions: sessions,
            workspaceIDsWithTeardownInFlight: workspaceIDsWithTeardownInFlight, daemonStatus: daemonStatus, automations: automationSummaries,
            automationRuns: automationRunSummaries, automationAttributedSessionIDs: try store.terminalSessionIDsAttributedToExistingAutomationRuns(),
            dismissedAlertKeys: Array(try store.alertDismissalKeys()), comeBackLaterFlags: try store.comeBackLaterFlags())
    }

    /// The daemon status the Device API reports. `deviceAPIAddresses` must be the addresses a pairing link
    /// opened from the same server would offer.
    static func makeDaemonStatus(
        activeSessionCount: Int, impact: RestartImpactCounts, restorableSessions: [RestorableSessionSummary], deviceAPIAddresses: [String]
    ) -> TerminalServiceDaemonStatus {
        TerminalServiceDaemonStatus(
            version: AppVersion.current, installedVersion: InstalledSpacesVersion.current(), certificateFingerprint: nil,
            activeSessionCount: activeSessionCount, protocolVersion: SpacesWireProtocol.version, runningProcesses: impact.runningProcesses,
            activeAgents: impact.activeAgents, waitingAgents: impact.waitingAgents,
            timeZoneIdentifier: TerminalServiceDaemonStatus.currentTimeZoneIdentifier, deviceAPIAddresses: deviceAPIAddresses,
            restorableSessions: restorableSessions)
    }

    /// Builds the overview's automation section: every automation, plus the runs a client needs — all
    /// currently-active (queued/running) runs unioned with the newest `recentAutomationRunLimit` terminal
    /// runs and each automation's latest terminal run, newest first, de-duplicated. Each run summary carries its automation name and its attributed
    /// coding-agent breakdown (computed against the live-session set the overview already scanned), so a
    /// client can render run history and derive alert entries without extra calls.
    private func loadAutomationOverview(liveSessions: [TerminalSessionCatalogEntry]) throws -> (
        [TerminalServiceAutomationSummary], [TerminalServiceAutomationRunSummary]
    ) {
        let automations = try store.automations()
        let automationSummaries = automations.map(TerminalServiceAutomationSummary.init)
        let namesByAutomationID = Dictionary(automations.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        // Active runs are always included regardless of the recent window; the recent terminal window fills
        // in history, and each automation's latest terminal run is unioned in so a chatty automation can't
        // evict quieter automations' last-run status. The selection contract lives in a pure builder helper
        // so it can be unit-tested.
        let ordered = SpacesDeviceOverviewBuilder.selectOverviewRuns(
            recentTerminal: try store.terminalAutomationRuns(limit: SpacesDeviceOverviewBuilder.recentAutomationRunLimit),
            latestPerAutomation: try store.latestTerminalAutomationRunPerAutomation(), active: try store.activeAutomationRuns())
        let attributedAgentsByRunID = try AutomationAttributedAgents.summariesByRunID(runs: ordered, store: store, liveSessions: liveSessions)
        let workspaceIDsByRunID = try store.workspaceIDs(automationRunIDs: ordered.map(\.id))
        let runSummaries = ordered.map { run in
            TerminalServiceAutomationRunSummary(
                run, automationName: namesByAutomationID[run.automationID], workspaceID: workspaceIDsByRunID[run.id],
                attributedAgents: attributedAgentsByRunID[run.id] ?? [])
        }
        return (automationSummaries, runSummaries)
    }

    private func mergedTerminalSessions(_ sessions: [TerminalSessionCatalogEntry]) -> [TerminalSessionCatalogEntry] {
        var order: [String] = []
        var entriesByID: [String: TerminalSessionCatalogEntry] = [:]
        for session in sessions {
            if entriesByID[session.sessionID] == nil { order.append(session.sessionID) }
            entriesByID[session.sessionID] = session
        }
        return order.compactMap { entriesByID[$0] }
    }

    /// Builds the per-workspace terminal rows for the overview. The descriptors already carry the exact
    /// records this needs — `descriptor.runningProcesses`/`descriptor.agentWindows` are populated in
    /// `load` from the same store queries — so this reuses them instead of re-querying per
    /// workspace, which otherwise doubled the process/agent reads on the refresh hot path.
    private func loadWorkspaceTerminalRows(
        workspaces: [SpacesDeviceOverviewBuilder.WorkspaceDescriptor], sessions: [TerminalSessionCatalogEntry], sessionIDsWithFinalRender: Set<String>
    ) -> [SpacesDeviceOverviewBuilder.WorkspaceTerminalRow] {
        SpacesDeviceAPIServer.workspaceTerminalRows(
            workspaces: workspaces, sessions: sessions, sessionIDsWithFinalRender: sessionIDsWithFinalRender,
            catalogEntry: { Self.terminalCatalogEntry(sessionID: $0) },
            endedWindowSessions: Self.endedTerminalWindowSessions(workspaces: workspaces, liveSessions: sessions))
    }

    /// The ended sessions still held by a terminal-window record, read in one query for the whole build.
    ///
    /// The window walk in `workspaceTerminalRows` needs each such session's persisted launch configuration
    /// and runtime state, and there is one candidate per terminal window whose session has exited. Reading
    /// them per row would put two connection round-trips per candidate on a build that runs several times a
    /// second, on the profile database's serialized lane — the lane every mutation also waits behind. One
    /// batched read keeps the cost flat, and a device whose held sessions are all still running issues no
    /// query at all.
    ///
    /// An ended session's attachment snapshot is empty by construction: exiting detaches every client, and
    /// the ended pane a client shows is client-local and holds no attachment. So the entry is built with an
    /// empty snapshot and no live control/subscription rather than paying a query to read that back — the
    /// builder forces both availability flags false for a non-interactive session anyway.
    private static func endedTerminalWindowSessions(
        workspaces: [SpacesDeviceOverviewBuilder.WorkspaceDescriptor], liveSessions: [TerminalSessionCatalogEntry]
    ) -> [String: TerminalSessionCatalogEntry] {
        let liveSessionIDs = Set(liveSessions.map(\.sessionID))
        var candidates = Set<String>()
        for descriptor in workspaces {
            for window in descriptor.windows where window.roleValue == .terminal {
                guard let sessionID = SpacesDeviceAPIServer.normalizedTerminalSessionID(window.terminalTrackingID),
                    !liveSessionIDs.contains(sessionID)
                else { continue }
                candidates.insert(sessionID)
            }
        }
        guard let runtimes = try? TerminalSessionPersistence.endedSessionRuntimes(sessionIDs: candidates) else { return [:] }
        return Dictionary(
            runtimes.compactMap { runtime -> (String, TerminalSessionCatalogEntry)? in
                guard let paths = try? TerminalSessionPaths.forStoredSession(id: runtime.sessionID, rootDirectory: runtime.rootDirectory) else {
                    return nil
                }
                return (
                    runtime.sessionID,
                    TerminalSessionCatalogEntry(
                        launchConfiguration: runtime.launchConfiguration, runtimeState: runtime.runtimeState, attachmentSnapshot: .init(),
                        paths: paths, isControlAvailable: false, isSubscriptionAvailable: false)
                )
            }, uniquingKeysWith: { existing, _ in existing })
    }

    private static func terminalCatalogEntry(sessionID: String, fileManager: FileManager = .default) -> TerminalSessionCatalogEntry? {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID),
            let launchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths),
            let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
        else { return nil }
        guard !runtimeState.state.isInteractive || TerminalSessionCatalog.isInteractiveServiceAlive(for: runtimeState) else { return nil }
        let attachmentSnapshot = ((try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)) ?? .init()).liveWireProjection()
        return TerminalSessionCatalogEntry(
            launchConfiguration: launchConfiguration, runtimeState: runtimeState, attachmentSnapshot: attachmentSnapshot, paths: paths,
            isControlAvailable: fileManager.fileExists(atPath: paths.controlSocketPath),
            isSubscriptionAvailable: fileManager.fileExists(atPath: paths.subscriptionSocketPath))
    }
}
