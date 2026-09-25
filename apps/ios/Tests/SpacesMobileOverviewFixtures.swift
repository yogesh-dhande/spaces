#if canImport(UIKit)
    import spacesdevicecore
    import spacesterminalcore

    // MARK: - Shared overview/workspace/agent-row fixtures
    //
    // `SpacesMobileAgentsTests` and `SpacesMobileAlertsTests` both build daemon-overview payloads around
    // one "workspace-feature" workspace with the same project/branch/workspace defaults; this file holds
    // the fixture builders they share (moved here verbatim from `SpacesMobileAlertsTests`, whose versions
    // were supersets of `SpacesMobileAgentsTests`'s narrower ones). `SpacesMobileAutomationsTests`,
    // `SpacesMobileAppModelTests`, and `BrowserProxyTests` each build a genuinely different overview shape
    // for their own tests (no projects, a two-workspace fixture, a single assigned-port workspace) and
    // keep their own private, differently-labeled `makeOverview`/`makeWorkspace` helpers, which Swift's
    // member-over-global lookup keeps distinct from the module-level functions below.

    func makeOverview(
        workspaces: [SpacesDeviceWorkspaceSummary]? = nil, projectIsHidden: Bool = false, codingAgentRows: [SpacesDeviceWorkspaceCodingAgentRow] = [],
        processRows: [SpacesDeviceWorkspaceProcessRow] = [], terminalRows: [SpacesDeviceWorkspaceTerminalRow] = [],
        sessions: [SpacesDeviceTerminalSessionSummary] = []
    ) -> SpacesDeviceOverviewPayload {
        let project = SpacesDeviceProjectSummary(
            id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main", isHidden: projectIsHidden)
        let resolvedWorkspaces =
            workspaces ?? [
                makeWorkspace(
                    id: "workspace-feature", branch: "feature", codingAgentRows: codingAgentRows, processRows: processRows, terminalRows: terminalRows
                )
            ]
        return SpacesDeviceOverviewPayload(
            projects: [project], workspaces: resolvedWorkspaces, sessions: sessions,
            daemonStatus: TerminalServiceDaemonStatus(
                version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0,
                protocolVersion: SpacesWireProtocol.version))
    }

    func makeWorkspace(
        id: String, branch: String?, isHidden: Bool = false, codingAgentRows: [SpacesDeviceWorkspaceCodingAgentRow] = [],
        processRows: [SpacesDeviceWorkspaceProcessRow] = [], terminalRows: [SpacesDeviceWorkspaceTerminalRow] = []
    ) -> SpacesDeviceWorkspaceSummary {
        SpacesDeviceWorkspaceSummary(
            id: id, projectID: "project-1", projectName: "Project", branch: branch, baseBranch: "main", dir: "/repo/\(id)", isRunning: true,
            isHidden: isHidden, isDefault: false,
            hasTrackedRuntimeIndicators: processRows.contains { $0.runState == .running } || codingAgentRows.contains { $0.runState == .running }
                || terminalRows.contains { $0.runState == .running }, processRows: processRows, codingAgentRows: codingAgentRows,
            terminalRows: terminalRows)
    }

    /// A home-project workspace fixture: the daemon's one workspace of `projectKind == .home`, rooted at a
    /// stand-in home directory. Kept separate from `makeWorkspace`, whose fixed "Project"/"project-1"
    /// identity and forced `isRunning: true` do not fit a workspace no configured process ever runs in.
    func makeHomeWorkspace(dir: String = "/Users/someone") -> SpacesDeviceWorkspaceSummary {
        SpacesDeviceWorkspaceSummary(
            id: "workspace-home", projectID: "project-home", projectName: ProjectKind.homeProjectName, projectKind: .home, branch: nil,
            baseBranch: nil, dir: dir, isRunning: false, isHidden: false, isDefault: true, hasTrackedRuntimeIndicators: false)
    }

    func makeAgentRow(
        id: String, workspaceID: String = "workspace-feature", name: String = "claude", runState: SpacesDeviceRunState = .running,
        activityState: SpacesDeviceCodingAgentActivityState, updatedAt: String? = nil
    ) -> SpacesDeviceWorkspaceCodingAgentRow {
        SpacesDeviceWorkspaceCodingAgentRow(
            id: id, workspaceID: workspaceID, name: name, command: name, agentID: "runtime-\(id)", sessionID: "session-\(id)", runState: runState,
            activityState: activityState, updatedAt: updatedAt, canStop: true)
    }
#endif
