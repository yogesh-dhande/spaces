#if canImport(UIKit)
    import XCTest
    import spacesterminalcore
    import spacesmobilecore
    @testable import SpacesMobile

    private actor SpacesMobileRequestRecorder {
        private var requests: [SpacesMobileBridgeRequest] = []

        func append(_ request: SpacesMobileBridgeRequest) { requests.append(request) }
        func snapshot() -> [SpacesMobileBridgeRequest] { requests }
    }

    private actor AsyncGate {
        private var didStart = false
        private var didRelease = false
        private var startContinuations: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuation: CheckedContinuation<Void, Never>?

        func markStarted() {
            didStart = true
            let continuations = startContinuations
            startContinuations.removeAll()
            continuations.forEach { $0.resume() }
        }

        func waitUntilStarted() async {
            if didStart { return }
            await withCheckedContinuation { continuation in
                startContinuations.append(continuation)
            }
        }

        func waitUntilReleased() async {
            if didRelease { return }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        func release() {
            didRelease = true
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

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

        func testStopTerminalRowSendsWorkspaceTerminalStopMutation() async {
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesMobileBridgeClient(settings: settings) { request in
                await recorder.append(request)
                return SpacesMobileBridgeResponse(ok: true, message: "stopped")
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            let row = SpacesMobileWorkspaceRuntimeRow(
                source: .terminal(
                    SpacesMobileWorkspaceTerminalRow(
                        id: "terminal-shell", workspaceID: "workspace-docs", title: "shell", workingDirectory: "/repo/docs",
                        sessionID: "session-shell", runState: .running, canOpenTerminal: true, canStop: true)))

            await model.stop(row: row)

            let request = await recorder.snapshot().first
            XCTAssertEqual(request?.command, "stopWorkspaceTerminal")
            XCTAssertEqual(request?.workspaceID, "workspace-docs")
            XCTAssertEqual(request?.sessionID, "session-shell")
            XCTAssertFalse(model.isMutating)
        }

        func testRunRowWithExistingSessionSendsRunMutation() async {
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesMobileBridgeClient(settings: settings) { request in
                await recorder.append(request)
                return SpacesMobileBridgeResponse(ok: true, message: "running")
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            let row = SpacesMobileWorkspaceRuntimeRow(
                source: .process(
                    SpacesMobileWorkspaceProcessRow(
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
            XCTAssertEqual(request?.command, "runWorkspaceProcess")
            XCTAssertEqual(request?.workspaceID, "workspace-feature")
            XCTAssertEqual(request?.processKey, "api")
            XCTAssertEqual(request?.processTemplateID, "template-api")
            XCTAssertFalse(model.isMutating)
        }

        func testRunProcessTimeoutRequiresFreshSessionWhenRowRetainsExitedSession() async {
            let oldRow = SpacesMobileWorkspaceProcessRow(
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
            let newRow = SpacesMobileWorkspaceProcessRow(
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
            let client = SpacesMobileBridgeClient(settings: settings) { request in
                await recorder.append(request)
                if request.command == "runWorkspaceProcess" {
                    throw SpacesMobileBridgeClientError.requestTimedOut
                }
                return SpacesMobileBridgeResponse(ok: true, message: "loaded", overview: refreshedOverview)
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.overview = makeOverview(sessions: [makeSession(id: "session-api-old")], featureProcessRows: [oldRow])

            let session = await model.run(row: SpacesMobileWorkspaceRuntimeRow(source: .process(oldRow)))
            let requests = await recorder.snapshot()

            XCTAssertEqual(session?.id, "session-api-new")
            XCTAssertEqual(requests.map(\.command), ["runWorkspaceProcess", "overview"])
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.isMutating)
        }

        func testRunAgentTimeoutRequiresFreshSessionWhenRowRetainsExitedSession() async {
            let oldRow = SpacesMobileWorkspaceCodingAgentRow(
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
            let newRow = SpacesMobileWorkspaceCodingAgentRow(
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
            let client = SpacesMobileBridgeClient(settings: settings) { request in
                await recorder.append(request)
                if request.command == "runCodingAgent" {
                    throw SpacesMobileBridgeClientError.requestTimedOut
                }
                return SpacesMobileBridgeResponse(ok: true, message: "loaded", overview: refreshedOverview)
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.overview = makeOverview(sessions: [makeSession(id: "session-codex-old")], featureProcessRows: [], featureCodingAgentRows: [oldRow])

            let session = await model.run(row: SpacesMobileWorkspaceRuntimeRow(source: .codingAgent(oldRow)))
            let requests = await recorder.snapshot()

            XCTAssertEqual(session?.id, "session-codex-new")
            XCTAssertEqual(requests.map(\.command), ["runCodingAgent", "overview"])
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.isMutating)
        }

        func testRefreshedSessionLookupIgnoresVisibleFilters() {
            let model = SpacesMobileAppModel()
            model.overview = makeOverview(sessions: [makeSession(id: "session-api")])
            model.visibleRunStates = [.notStarted]

            XCTAssertTrue(model.workspaceGroups.flatMap(\.rows).isEmpty)
            XCTAssertEqual(model.refreshedSession(forRowID: "process:process-api")?.id, "session-api")
        }

        func testRuntimeRowLookupBySessionIgnoresVisibleFilters() {
            let model = SpacesMobileAppModel()
            model.overview = makeOverview(sessions: [makeSession(id: "session-api")])
            model.visibleRunStates = [.notStarted]

            XCTAssertTrue(model.workspaceGroups.flatMap(\.rows).isEmpty)
            XCTAssertEqual(model.runtimeRow(forSessionID: "session-api")?.title, "api")
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

        func testClientLaunchSpacesAppSendsAuthenticatedCommandAndClientIdentity() async throws {
            let recorder = SpacesMobileRequestRecorder()
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "auth-token"
            settings.transportKey = "transport-key"
            settings.installationID = "INSTALLATION-LAUNCH"
            let client = SpacesMobileBridgeClient(settings: settings) { request in
                await recorder.append(request)
                return SpacesMobileBridgeResponse(ok: true, message: "Launched Spaces on Mac.")
            }

            try await client.launchSpacesApp()

            let request = await recorder.snapshot().first
            XCTAssertEqual(request?.command, "launchSpacesApp")
            XCTAssertEqual(request?.authToken, "auth-token")
            XCTAssertEqual(request?.clientApp?.installationID, "INSTALLATION-LAUNCH")
            XCTAssertEqual(request?.clientApp?.platform, "ios")
            XCTAssertFalse(request?.clientApp?.deviceName.isEmpty ?? true)
        }

        func testModelLaunchSpacesAppTogglesStateAndKeepsOverview() async {
            let recorder = SpacesMobileRequestRecorder()
            let gate = AsyncGate()
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "auth-token"
            settings.transportKey = "transport-key"
            let client = SpacesMobileBridgeClient(settings: settings) { request in
                await recorder.append(request)
                await gate.markStarted()
                await gate.waitUntilReleased()
                return SpacesMobileBridgeResponse(ok: true, message: "Launched Spaces on Mac.")
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            let overview = makeOverview(sessions: [makeSession(id: "session-api")])
            model.overview = overview

            let task = Task { await model.launchSpacesAppIfNeeded() }
            await gate.waitUntilStarted()

            XCTAssertTrue(model.isLaunchingSpacesApp)
            XCTAssertEqual(model.overview, overview)

            await gate.release()
            await task.value

            let requests = await recorder.snapshot()
            XCTAssertEqual(requests.map(\.command), ["launchSpacesApp"])
            XCTAssertFalse(model.isLaunchingSpacesApp)
            XCTAssertEqual(model.overview, overview)
            XCTAssertNil(model.errorMessage)
        }

        func testModelLaunchSpacesAppSurfacesErrors() async {
            var settings = SpacesMobileConnectionSettings()
            settings.authToken = "auth-token"
            settings.transportKey = "transport-key"
            let client = SpacesMobileBridgeClient(settings: settings) { _ in
                SpacesMobileBridgeResponse(ok: false, message: "Unable to find SpacesApp.")
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)

            await model.launchSpacesAppIfNeeded()

            XCTAssertFalse(model.isLaunchingSpacesApp)
            XCTAssertEqual(model.errorMessage, "Unable to find SpacesApp.")
        }

        private func makeOverview(
            sessions: [SpacesMobileTerminalSessionSummary] = [],
            featureProcessRows: [SpacesMobileWorkspaceProcessRow]? = nil,
            featureCodingAgentRows: [SpacesMobileWorkspaceCodingAgentRow]? = nil
        ) -> SpacesMobileOverviewPayload {
            let project = SpacesMobileProjectSummary(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
            let processRows =
                featureProcessRows
                ?? [
                    SpacesMobileWorkspaceProcessRow(
                        id: "process-api", workspaceID: "workspace-feature", name: "api", command: "npm run dev", processID: "runtime-api",
                        sessionID: "session-api", runState: .running, canRun: false, canStop: true, canRestart: true)
                ]
            let codingAgentRows =
                featureCodingAgentRows
                ?? [
                    SpacesMobileWorkspaceCodingAgentRow(
                        id: "agent-codex", workspaceID: "workspace-feature", name: "Codex", command: "codex", agentID: "runtime-codex",
                        sessionID: "session-codex", isConfigured: true, runState: .running, activityState: .spinning, canRun: false,
                        canStop: true, canRestart: true)
                ]
            let feature = SpacesMobileWorkspaceSummary(
                id: "workspace-feature", projectID: project.id, projectName: project.name, title: "Feature", branch: "feature",
                targetBranch: "main", dir: "/repo/feature", isRunning: true, isArchived: false, isHidden: false, isDefault: false,
                sessionCount: 1,
                processRows: processRows,
                codingAgentRows: codingAgentRows,
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
