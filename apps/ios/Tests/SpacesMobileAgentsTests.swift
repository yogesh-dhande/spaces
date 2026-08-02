#if canImport(UIKit)
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    @MainActor final class SpacesMobileAgentsTests: XCTestCase {
        func testGroupsMembershipOrderingAndCounts() {
            let overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-idle-exited", runState: .exited, activityState: .idle),
                makeAgentRow(id: "agent-waiting", runState: .running, activityState: .waiting),
                makeAgentRow(id: "agent-spinning", runState: .running, activityState: .spinning),
                makeAgentRow(id: "agent-not-started", runState: .notStarted, activityState: .idle),
                makeAgentRow(id: "agent-running-idle", runState: .running, activityState: .idle),
                makeAgentRow(id: "agent-done", runState: .running, activityState: .done),
            ])

            let groups = SpacesMobileAgentGrouping.groups(in: overview)

            XCTAssertEqual(groups.map(\.kind), [.blocked, .done, .working, .notRunning])
            XCTAssertEqual(groups.map(\.kind.label), ["Blocked", "Done", "Working", "Not running"])
            XCTAssertEqual(groups.map { $0.entries.count }, [1, 1, 2, 2])
            XCTAssertEqual(groups[0].entries.map { $0.row.id }, ["agent-waiting"])
            XCTAssertEqual(groups[1].entries.map { $0.row.id }, ["agent-done"])
            XCTAssertEqual(groups[2].entries.map { $0.row.id }, ["agent-spinning", "agent-running-idle"])
            XCTAssertEqual(groups[3].entries.map { $0.row.id }, ["agent-idle-exited", "agent-not-started"])
        }

        /// A finished agent has a result the user has not read yet, so it bands ahead of the agents still
        /// working — regardless of whether its terminal is still alive.
        func testDoneAgentBandsBeforeWorkingRegardlessOfRunState() {
            XCTAssertEqual(SpacesMobileAgentGrouping.kind(for: makeAgentRow(id: "agent-a", runState: .running, activityState: .done)), .done)
            XCTAssertEqual(SpacesMobileAgentGrouping.kind(for: makeAgentRow(id: "agent-b", runState: .exited, activityState: .done)), .done)

            let overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-spinning", runState: .running, activityState: .spinning),
                makeAgentRow(id: "agent-done", runState: .exited, activityState: .done),
            ])

            XCTAssertEqual(SpacesMobileAgentGrouping.groups(in: overview).map(\.kind), [.done, .working])
        }

        /// An agent waiting for input is the one thing on this tab that needs the user, so it bands first.
        func testBlockedAgentBandsFirst() {
            XCTAssertEqual(SpacesMobileAgentGrouping.kind(for: makeAgentRow(id: "agent-a", runState: .running, activityState: .waiting)), .blocked)

            let overview = makeOverview(codingAgentRows: [
                makeAgentRow(id: "agent-not-started", runState: .notStarted, activityState: .idle),
                makeAgentRow(id: "agent-spinning", runState: .running, activityState: .spinning),
                makeAgentRow(id: "agent-done", runState: .running, activityState: .done),
                makeAgentRow(id: "agent-waiting", runState: .running, activityState: .waiting),
            ])

            XCTAssertEqual(SpacesMobileAgentGrouping.groups(in: overview).first?.kind, .blocked)
        }

        /// An idle agent says nothing about itself, so its terminal decides which band it lands in.
        func testIdleAgentBandsOnItsTerminalRunState() {
            XCTAssertEqual(SpacesMobileAgentGrouping.kind(for: makeAgentRow(id: "agent-a", runState: .running, activityState: .idle)), .working)
            XCTAssertEqual(SpacesMobileAgentGrouping.kind(for: makeAgentRow(id: "agent-b", runState: .notStarted, activityState: .idle)), .notRunning)
            XCTAssertEqual(SpacesMobileAgentGrouping.kind(for: makeAgentRow(id: "agent-c", runState: .exited, activityState: .idle)), .notRunning)
        }

        /// An exited agent still owns an interactive terminal (`runState == .running`), but the agent
        /// process is gone. It must group under "Not running" rather than "Working", and its status dot
        /// must read as exited rather than inheriting the terminal's still-running state.
        func testExitedAgentGroupsAsNotRunningDespiteRunningTerminal() {
            let row = makeAgentRow(id: "agent-exited-running-terminal", runState: .running, activityState: .exited)

            XCTAssertEqual(SpacesMobileAgentGrouping.kind(for: row), .notRunning)
            XCTAssertEqual(StatusDot.Kind(runState: .running, activityState: .exited), .exited)
        }

        func testOmitsEmptyGroups() {
            let overview = makeOverview(codingAgentRows: [makeAgentRow(id: "agent-not-started", runState: .notStarted, activityState: .idle)])

            let groups = SpacesMobileAgentGrouping.groups(in: overview)

            XCTAssertEqual(groups.map(\.kind), [.notRunning])
        }

        func testSkipsHiddenWorkspaces() {
            let workspace = makeWorkspace(
                id: "workspace-hidden", branch: "feature", isHidden: true,
                codingAgentRows: [makeAgentRow(id: "agent-a", runState: .notStarted, activityState: .idle)])
            let overview = makeOverview(workspaces: [workspace])

            XCTAssertTrue(SpacesMobileAgentGrouping.groups(in: overview).isEmpty)
        }

        func testDetailShowsProjectAndBranchOrSingleSharedName() {
            let gitEntry = SpacesMobileAgentEntry(
                row: makeAgentRow(id: "agent-a", runState: .running, activityState: .spinning), workspaceDisplayName: "ios-redesign",
                projectName: "spaces")
            XCTAssertEqual(gitEntry.detail, "spaces · ios-redesign")

            let nonGitEntry = SpacesMobileAgentEntry(
                row: makeAgentRow(id: "agent-b", runState: .notStarted, activityState: .idle), workspaceDisplayName: "notes-app",
                projectName: "Notes-App")
            XCTAssertEqual(nonGitEntry.detail, "notes-app")
        }

        func testAgentStatusDotReflectsActivityState() {
            XCTAssertEqual(StatusDot.Kind(runState: .running, activityState: .waiting), .waiting)
            XCTAssertEqual(StatusDot.Kind(runState: .running, activityState: .done), .done)
            XCTAssertEqual(StatusDot.Kind(runState: .running, activityState: .spinning), .running)
            XCTAssertEqual(StatusDot.Kind(runState: .running, activityState: .idle), .running)
            XCTAssertEqual(StatusDot.Kind(runState: .exited, activityState: .idle), .exited)
            XCTAssertEqual(StatusDot.Kind(runState: .notStarted, activityState: .idle), .idle)

            let agentRow = SpacesMobileWorkspaceRuntimeRow(
                source: .codingAgent(makeAgentRow(id: "agent-a", runState: .running, activityState: .done)))
            XCTAssertEqual(agentRow.statusDotKind, .done)

            let processRow = SpacesMobileWorkspaceRuntimeRow(
                source: .process(
                    SpacesDeviceWorkspaceProcessRow(
                        id: "process-a", workspaceID: "workspace-feature", name: "web", command: "npm run dev", processID: nil, sessionID: nil,
                        runState: .exited, canRun: true, canStop: false, canRestart: false)))
            XCTAssertEqual(processRow.statusDotKind, .exited)
        }

        func testWorkspaceCollapseToggle() {
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in SpacesDeviceAPIResponse(ok: true, message: "ok") }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)

            XCTAssertFalse(model.collapsedWorkspaceIDs.contains("workspace-feature"))

            model.toggleWorkspaceCollapsed("workspace-feature")
            XCTAssertTrue(model.collapsedWorkspaceIDs.contains("workspace-feature"))

            model.toggleWorkspaceCollapsed("workspace-feature")
            XCTAssertFalse(model.collapsedWorkspaceIDs.contains("workspace-feature"))
        }

        // MARK: - Fixtures

        private func makeOverview(workspaces: [SpacesDeviceWorkspaceSummary]? = nil, codingAgentRows: [SpacesDeviceWorkspaceCodingAgentRow] = [])
            -> SpacesDeviceOverviewPayload
        {
            let project = SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
            let resolvedWorkspaces = workspaces ?? [makeWorkspace(id: "workspace-feature", branch: "feature", codingAgentRows: codingAgentRows)]
            return SpacesDeviceOverviewPayload(
                projects: [project], workspaces: resolvedWorkspaces, sessions: [],
                daemonStatus: TerminalServiceDaemonStatus(
                    version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0,
                    protocolVersion: SpacesWireProtocol.version))
        }

        private func makeWorkspace(id: String, branch: String?, isHidden: Bool = false, codingAgentRows: [SpacesDeviceWorkspaceCodingAgentRow] = [])
            -> SpacesDeviceWorkspaceSummary
        {
            SpacesDeviceWorkspaceSummary(
                id: id, projectID: "project-1", projectName: "Project", branch: branch, baseBranch: "main", dir: "/repo/\(id)", isRunning: true,
                isHidden: isHidden, isDefault: false, sessionCount: 0, codingAgentRows: codingAgentRows)
        }

        private func makeAgentRow(id: String, runState: SpacesDeviceRunState, activityState: SpacesDeviceCodingAgentActivityState)
            -> SpacesDeviceWorkspaceCodingAgentRow
        {
            SpacesDeviceWorkspaceCodingAgentRow(
                id: id, workspaceID: "workspace-feature", name: "claude", command: "claude", agentID: runState == .notStarted ? nil : "runtime-\(id)",
                sessionID: runState == .notStarted ? nil : "session-\(id)", isConfigured: true, runState: runState, activityState: activityState,
                canRun: runState != .running, canStop: runState == .running, canRestart: runState == .running)
        }
    }
#endif
