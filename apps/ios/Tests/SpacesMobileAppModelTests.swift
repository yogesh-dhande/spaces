#if canImport(UIKit)
    import XCTest
    import spacesterminalcore
    import spacesmobilecore
    @testable import SpacesMobile

    @MainActor
    final class SpacesMobileAppModelTests: XCTestCase {
        func testWorkspaceGroupsFilterByTypeStateAndSearch() {
            let model = SpacesMobileAppModel()
            model.overview = makeOverview()

            XCTAssertEqual(model.workspaceGroups.count, 2)
            XCTAssertEqual(model.workspaceGroups.first?.rows.count, 2)

            model.visibleRowTypes = [.codingAgents]
            XCTAssertEqual(model.workspaceGroups.map { $0.workspace.title }, ["Feature"])
            XCTAssertEqual(model.workspaceGroups.first?.rows.map(\.title), ["Codex"])

            model.visibleRowTypes = Set(SpacesMobileWorkspaceRowType.allCases)
            model.visibleRunStates = [.running]
            XCTAssertEqual(model.workspaceGroups.first?.rows.map(\.title), ["api", "Codex"])

            model.visibleRunStates = Set([.notStarted, .running, .exited])
            model.searchText = "docs"
            XCTAssertEqual(model.workspaceGroups.map { $0.workspace.title }, ["Docs"])
            XCTAssertEqual(model.workspaceGroups.first?.rows.map(\.title), ["shell"])
        }

        func testRuntimeRowActionAvailabilitySurvivesModelMapping() {
            let model = SpacesMobileAppModel()
            model.overview = makeOverview()

            let rows = model.workspaceGroups.flatMap(\.rows)
            let process = rows.first { $0.title == "api" }
            let terminal = rows.first { $0.title == "shell" }

            XCTAssertEqual(process?.canStop, true)
            XCTAssertEqual(process?.canRestart, true)
            XCTAssertEqual(process?.sessionID, "session-api")
            XCTAssertEqual(terminal?.canRun, false)
            XCTAssertEqual(terminal?.runState, .exited)
        }

        func testRefreshedSessionLookupIgnoresVisibleFilters() {
            let model = SpacesMobileAppModel()
            model.overview = makeOverview(sessions: [makeSession(id: "session-api")])
            model.visibleRunStates = [.notStarted]

            XCTAssertTrue(model.workspaceGroups.flatMap(\.rows).isEmpty)
            XCTAssertEqual(model.refreshedSession(forRowID: "process:process-api")?.id, "session-api")
        }

        func testMutationCancellationDoesNotShowConnectionError() async {
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesMobileBridgeClient(settings: settings) { _ in
                throw CancellationError()
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)

            let session = await model.openWorkspaceTerminal(workspaceID: "workspace-feature")

            XCTAssertNil(session)
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.isMutating)
        }

        private func makeOverview(sessions: [SpacesMobileTerminalSessionSummary] = []) -> SpacesMobileOverviewPayload {
            let project = SpacesMobileProjectSummary(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
            let feature = SpacesMobileWorkspaceSummary(
                id: "workspace-feature", projectID: project.id, projectName: project.name, title: "Feature", branch: "feature",
                targetBranch: "main", dir: "/repo/feature", isRunning: true, isArchived: false, isHidden: false, isDefault: false,
                sessionCount: 1,
                processRows: [
                    SpacesMobileWorkspaceProcessRow(
                        id: "process-api", workspaceID: "workspace-feature", name: "api", command: "npm run dev", processID: "runtime-api",
                        sessionID: "session-api", runState: .running, canRun: false, canStop: true, canRestart: true)
                ],
                codingAgentRows: [
                    SpacesMobileWorkspaceCodingAgentRow(
                        id: "agent-codex", workspaceID: "workspace-feature", name: "Codex", command: "codex", agentID: "runtime-codex",
                        sessionID: "session-codex", isConfigured: true, runState: .running, activityState: .spinning, canRun: false,
                        canStop: true, canRestart: true)
                ],
                terminalRows: [])
            let docs = SpacesMobileWorkspaceSummary(
                id: "workspace-docs", projectID: project.id, projectName: project.name, title: "Docs", branch: "docs", targetBranch: "main",
                dir: "/repo/docs", isRunning: false, isArchived: false, isHidden: false, isDefault: false, sessionCount: 0,
                processRows: [],
                codingAgentRows: [],
                terminalRows: [
                    SpacesMobileWorkspaceTerminalRow(
                        id: "terminal-shell", workspaceID: "workspace-docs", title: "shell", workingDirectory: "/repo/docs", sessionID: nil,
                        runState: .exited, canOpenTerminal: false)
                ])
            return SpacesMobileOverviewPayload(projects: [project], workspaces: [feature, docs], sessions: sessions)
        }

        private func makeSession(id: String) -> SpacesMobileTerminalSessionSummary {
            SpacesMobileTerminalSessionSummary(
                id: id,
                title: "api",
                workingDirectory: "/repo/feature",
                state: .running,
                backend: .ghosttyEmbedded,
                lifetimePolicy: .persistent,
                servicePID: 100,
                childPID: 101,
                workspaceID: "workspace-feature",
                workspaceTitle: "Feature",
                projectID: "project-1",
                projectName: "Project",
                createdAt: "2026-01-01T00:00:00Z",
                updatedAt: "2026-01-01T00:00:01Z",
                isControlAvailable: true,
                isSubscriptionAvailable: true,
                attachmentSnapshot: TerminalSessionAttachmentSnapshot()
            )
        }
    }
#endif
