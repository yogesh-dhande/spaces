#if canImport(UIKit)
    import XCTest
    import spacesterminalcore
    import spacesdevicecore
    @testable import SpacesMobile

    private actor SpacesMobileRequestRecorder {
        private var requests: [SpacesDeviceAPIRequest] = []

        func append(_ request: SpacesDeviceAPIRequest) { requests.append(request) }
        func snapshot() -> [SpacesDeviceAPIRequest] { requests }
    }

    @MainActor
    final class SpacesMobileAppModelTests: XCTestCase {
        func testWorkspaceGroupsFilterByTypeStateAndSearch() {
            let model = makeModel()
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
            let model = makeModel()
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

        func testStopTerminalRowSendsWorkspaceTerminalStopMutation() async {
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(ok: true, message: "stopped")
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            let row = SpacesMobileWorkspaceRuntimeRow(
                source: .terminal(
                    SpacesDeviceWorkspaceTerminalRow(
                        id: "terminal-shell", workspaceID: "workspace-docs", title: "shell", workingDirectory: "/repo/docs",
                        sessionID: "session-shell", runState: .running, canOpenTerminal: true, canStop: true)))

            await model.stop(row: row)

            let request = await recorder.snapshot().first
            XCTAssertEqual(request?.commandName, "stopWorkspaceTerminal")
            guard case .stopWorkspaceTerminal(let payload)? = request?.command else {
                XCTFail("Expected stopWorkspaceTerminal request.")
                return
            }
            XCTAssertEqual(payload.workspaceID, "workspace-docs")
            XCTAssertEqual(payload.sessionID, "session-shell")
            XCTAssertFalse(model.isMutating)
        }

        func testRunRowWithExistingSessionSendsRunMutation() async {
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(ok: true, message: "running")
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            let row = SpacesMobileWorkspaceRuntimeRow(
                source: .process(
                    SpacesDeviceWorkspaceProcessRow(
                        id: "template-api",
                        workspaceID: "workspace-feature",
                        name: "api",
                        command: "npm run dev",
                        templateID: "template-api",
                        processID: "runtime-api",
                        sessionID: "session-api-old",
                        runState: .exited,
                        canRun: true,
                        canStop: false,
                        canRestart: false)))

            _ = await model.run(row: row)

            let request = await recorder.snapshot().first
            XCTAssertEqual(request?.commandName, "runWorkspaceProcess")
            guard case .runWorkspaceProcess(let payload)? = request?.command else {
                XCTFail("Expected runWorkspaceProcess request.")
                return
            }
            XCTAssertEqual(payload.workspaceID, "workspace-feature")
            XCTAssertEqual(payload.processKey, "api")
            XCTAssertEqual(payload.processTemplateID, "template-api")
            XCTAssertFalse(model.isMutating)
        }

        func testRunProcessTimeoutRequiresFreshSessionWhenRowRetainsExitedSession() async {
            let oldRow = SpacesDeviceWorkspaceProcessRow(
                id: "template-api",
                workspaceID: "workspace-feature",
                name: "api",
                command: "npm run dev",
                templateID: "template-api",
                processID: "runtime-api-old",
                sessionID: "session-api-old",
                runState: .exited,
                canRun: true,
                canStop: false,
                canRestart: false)
            let newRow = SpacesDeviceWorkspaceProcessRow(
                id: "template-api",
                workspaceID: "workspace-feature",
                name: "api",
                command: "npm run dev",
                templateID: "template-api",
                processID: "runtime-api-new",
                sessionID: "session-api-new",
                runState: .running,
                canRun: false,
                canStop: true,
                canRestart: true)
            let refreshedOverview = makeOverview(sessions: [makeSession(id: "session-api-new")], featureProcessRows: [newRow])
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                if request.commandName == "runWorkspaceProcess" {
                    throw SpacesDeviceAPIClientError.requestTimedOut
                }
                return SpacesDeviceAPIResponse(ok: true, message: "loaded", result: .overview(refreshedOverview))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.overview = makeOverview(sessions: [makeSession(id: "session-api-old")], featureProcessRows: [oldRow])

            let session = await model.run(row: SpacesMobileWorkspaceRuntimeRow(source: .process(oldRow)))
            let requests = await recorder.snapshot()

            XCTAssertEqual(session?.id, "session-api-new")
            XCTAssertEqual(requests.map(\.commandName), ["runWorkspaceProcess", "overview"])
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.isMutating)
        }

        func testRunAgentTimeoutRequiresFreshSessionWhenRowRetainsExitedSession() async {
            let oldRow = SpacesDeviceWorkspaceCodingAgentRow(
                id: "agent-codex",
                workspaceID: "workspace-feature",
                name: "Codex",
                command: "codex",
                launcherID: "launcher-codex",
                agentID: "agent-old",
                sessionID: "session-codex-old",
                isConfigured: true,
                runState: .exited,
                activityState: .idle,
                canRun: true,
                canStop: false,
                canRestart: false)
            let newRow = SpacesDeviceWorkspaceCodingAgentRow(
                id: "agent-codex",
                workspaceID: "workspace-feature",
                name: "Codex",
                command: "codex",
                launcherID: "launcher-codex",
                agentID: "agent-new",
                sessionID: "session-codex-new",
                isConfigured: true,
                runState: .running,
                activityState: .spinning,
                canRun: false,
                canStop: true,
                canRestart: true)
            let refreshedOverview = makeOverview(
                sessions: [makeSession(id: "session-codex-new")], featureProcessRows: [], featureCodingAgentRows: [newRow])
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                if request.commandName == "runCodingAgent" {
                    throw SpacesDeviceAPIClientError.requestTimedOut
                }
                return SpacesDeviceAPIResponse(ok: true, message: "loaded", result: .overview(refreshedOverview))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.overview = makeOverview(sessions: [makeSession(id: "session-codex-old")], featureProcessRows: [], featureCodingAgentRows: [oldRow])

            let session = await model.run(row: SpacesMobileWorkspaceRuntimeRow(source: .codingAgent(oldRow)))
            let requests = await recorder.snapshot()

            XCTAssertEqual(session?.id, "session-codex-new")
            XCTAssertEqual(requests.map(\.commandName), ["runCodingAgent", "overview"])
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.isMutating)
        }

        func testRefreshedSessionLookupIgnoresVisibleFilters() {
            let model = makeModel()
            model.overview = makeOverview(sessions: [makeSession(id: "session-api")])
            model.visibleRunStates = [.notStarted]

            XCTAssertTrue(model.workspaceGroups.flatMap(\.rows).isEmpty)
            XCTAssertEqual(model.refreshedSession(forRowID: "process:process-api")?.id, "session-api")
        }

        func testRuntimeRowLookupBySessionIgnoresVisibleFilters() {
            let model = makeModel()
            model.overview = makeOverview(sessions: [makeSession(id: "session-api")])
            model.visibleRunStates = [.notStarted]

            XCTAssertTrue(model.workspaceGroups.flatMap(\.rows).isEmpty)
            XCTAssertEqual(model.runtimeRow(forSessionID: "session-api")?.title, "api")
        }

        func testTerminalGroupsExcludeSessionsRepresentedByWorkspaceRows() {
            let model = makeModel()
            model.overview = makeOverview(sessions: [makeSession(id: "session-api"), makeSession(id: "session-orphan")])

            XCTAssertEqual(model.workspaceGroups.flatMap(\.rows).compactMap(\.sessionID), ["session-api", "session-codex"])
            XCTAssertEqual(model.terminalGroups.flatMap(\.sessions).map(\.id), ["session-orphan"])
        }

        func testMutationCancellationDoesNotShowConnectionError() async {
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                throw CancellationError()
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)

            let session = await model.openWorkspaceTerminal(workspaceID: "workspace-feature")

            XCTAssertNil(session)
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.isMutating)
        }

        private func makeOverview(
            sessions: [SpacesDeviceTerminalSessionSummary] = [],
            featureProcessRows: [SpacesDeviceWorkspaceProcessRow]? = nil,
            featureCodingAgentRows: [SpacesDeviceWorkspaceCodingAgentRow]? = nil
        ) -> SpacesDeviceOverviewPayload {
            let project = SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
            let processRows =
                featureProcessRows
                ?? [
                    SpacesDeviceWorkspaceProcessRow(
                        id: "process-api", workspaceID: "workspace-feature", name: "api", command: "npm run dev", processID: "runtime-api",
                        sessionID: "session-api", runState: .running, canRun: false, canStop: true, canRestart: true)
                ]
            let codingAgentRows =
                featureCodingAgentRows
                ?? [
                    SpacesDeviceWorkspaceCodingAgentRow(
                        id: "agent-codex", workspaceID: "workspace-feature", name: "Codex", command: "codex", agentID: "runtime-codex",
                        sessionID: "session-codex", isConfigured: true, runState: .running, activityState: .spinning, canRun: false,
                        canStop: true, canRestart: true)
                ]
            let feature = SpacesDeviceWorkspaceSummary(
                id: "workspace-feature", projectID: project.id, projectName: project.name, title: "Feature", branch: "feature",
                baseBranch: "main", dir: "/repo/feature", isRunning: true, isArchived: false, isHidden: false, isDefault: false,
                sessionCount: 1,
                processRows: processRows,
                codingAgentRows: codingAgentRows,
                terminalRows: [])
            let docs = SpacesDeviceWorkspaceSummary(
                id: "workspace-docs", projectID: project.id, projectName: project.name, title: "Docs", branch: "docs", baseBranch: "main",
                dir: "/repo/docs", isRunning: false, isArchived: false, isHidden: false, isDefault: false, sessionCount: 0,
                processRows: [],
                codingAgentRows: [],
                terminalRows: [
                    SpacesDeviceWorkspaceTerminalRow(
                        id: "terminal-shell", workspaceID: "workspace-docs", title: "shell", workingDirectory: "/repo/docs", sessionID: nil,
                        runState: .exited, canOpenTerminal: false)
                ])
            return SpacesDeviceOverviewPayload(projects: [project], workspaces: [feature, docs], sessions: sessions)
        }

        private func makeSession(id: String) -> SpacesDeviceTerminalSessionSummary {
            SpacesDeviceTerminalSessionSummary(
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

        private func makeModel() -> SpacesMobileAppModel {
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            return SpacesMobileAppModel(settings: settings, bridgeClient: client)
        }
    }
#endif
