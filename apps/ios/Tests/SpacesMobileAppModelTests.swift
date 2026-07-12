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
            XCTAssertEqual(model.workspaceGroups.map { $0.workspace.displayName }, ["feature"])
            XCTAssertEqual(model.workspaceGroups.first?.rows.map(\.title), ["Codex"])

            model.visibleRowTypes = Set(SpacesMobileWorkspaceRowType.allCases)
            model.visibleRunStates = [.running]
            XCTAssertEqual(model.workspaceGroups.first?.rows.map(\.title), ["api", "Codex"])

            model.visibleRunStates = Set([.notStarted, .running, .exited])
            model.searchText = "docs"
            XCTAssertEqual(model.workspaceGroups.map { $0.workspace.displayName }, ["docs"])
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

        func testBrowserSessionRowsBuiltFromResolvedRoutes() {
            let model = makeModel()
            model.overview = makeOverview(
                featureAssignedPorts: [SpacesDeviceAssignedPort(name: "web", port: 3_000, url: "http://web.feature.localhost:3000")],
                featureConfig: SpacesDeviceWorkspaceConfig(
                    resolvedBrowserSessions: [SpacesDeviceBrowserSession(name: "Dashboard", url: "http://localhost:3000/dashboard")]))

            let rows = model.workspaceGroups.first { $0.workspace.id == "workspace-feature" }?.rows ?? []
            let browserRow = rows.first { row in
                if case .browserSession = row.source { return true }
                return false
            }

            XCTAssertEqual(browserRow?.id, "browser:workspace-feature:web:0")
            XCTAssertEqual(browserRow?.title, "Dashboard")
            XCTAssertEqual(browserRow?.detail, "localhost:3000/dashboard")
            XCTAssertEqual(browserRow?.type, .browserSessions)
            XCTAssertNil(browserRow?.sessionID)
            XCTAssertEqual(browserRow?.canRun, false)
            XCTAssertEqual(browserRow?.canStop, false)
            XCTAssertEqual(browserRow?.canRestart, false)
        }

        func testBrowserSessionRowsSurviveRunStateFilter() {
            let model = makeModel()
            model.overview = makeOverview(
                featureAssignedPorts: [SpacesDeviceAssignedPort(name: "web", port: 3_000, url: "http://web.feature.localhost:3000")],
                featureConfig: SpacesDeviceWorkspaceConfig(
                    resolvedBrowserSessions: [SpacesDeviceBrowserSession(name: "Dashboard", url: "http://localhost:3000/dashboard")]))
            // A run-state filter that excludes every "real" run state must still leave browser rows visible.
            model.visibleRunStates = [.running]

            let rows = model.workspaceGroups.first { $0.workspace.id == "workspace-feature" }?.rows ?? []
            XCTAssertTrue(rows.contains { $0.title == "Dashboard" })
        }

        func testRowTypeFilterExcludesAndIncludesBrowserSessions() {
            let model = makeModel()
            model.overview = makeOverview(
                featureAssignedPorts: [SpacesDeviceAssignedPort(name: "web", port: 3_000, url: "http://web.feature.localhost:3000")],
                featureConfig: SpacesDeviceWorkspaceConfig(
                    resolvedBrowserSessions: [SpacesDeviceBrowserSession(name: "Dashboard", url: "http://localhost:3000/dashboard")]))

            model.visibleRowTypes = Set(SpacesMobileWorkspaceRowType.allCases.filter { $0 != .browserSessions })
            let rowsWithFilterOff = model.workspaceGroups.first { $0.workspace.id == "workspace-feature" }?.rows ?? []
            XCTAssertFalse(rowsWithFilterOff.contains { $0.title == "Dashboard" })

            model.visibleRowTypes = Set(SpacesMobileWorkspaceRowType.allCases)
            let rowsWithFilterOn = model.workspaceGroups.first { $0.workspace.id == "workspace-feature" }?.rows ?? []
            XCTAssertTrue(rowsWithFilterOn.contains { $0.title == "Dashboard" })
        }

        func testBrowserSessionProxyURLUsesFixedPortAndIdentityHost() {
            let model = makeModel()
            let route = SpacesDeviceBrowserSessionRoute.routes(
                resolvedBrowserSessions: [SpacesDeviceBrowserSession(name: "Dashboard", url: "http://localhost:3000/dashboard")],
                assignedPorts: [SpacesDeviceAssignedPort(name: "web", port: 3_000, url: "http://web.feature.localhost:3000")]
            ).first!
            let row = SpacesMobileBrowserSessionRow(workspaceID: "workspace-feature", index: 0, route: route)

            let url = model.browserSessionProxyURL(for: row)

            XCTAssertEqual(url?.absoluteString, "http://web.feature.localhost:47898/dashboard")
        }

        func testBrowserProxyStopReturnsProxyToIdle() async throws {
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let proxyPort = UInt16.random(in: 49_152...65_500)
            let proxy = SpacesMobileBrowserProxy(port: proxyPort, installationID: settings.installationID)
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client, browserProxy: proxy)

            model.browserProxyStart()
            try await waitForBrowserProxyStatus(model, .running(port: proxyPort))
            model.browserProxyStop()
            try await waitForBrowserProxyStatus(model, .idle)
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

        func testOpenWorkspaceTerminalReturnsStartingSessionFromMutationOverview() async {
            let startingSession = makeSession(id: "session-shell-new", state: .starting, isControlAvailable: false, isSubscriptionAvailable: false)
            let refreshedOverview = makeOverview(sessions: [startingSession])
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(
                    ok: true,
                    message: "Opened workspace terminal.",
                    result: .mutation(
                        SpacesDeviceMutationResult(
                            overview: refreshedOverview,
                            workspaceID: "workspace-feature",
                            sessionID: startingSession.id)))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)

            let session = await model.openWorkspaceTerminal(workspaceID: "workspace-feature")

            XCTAssertEqual(session?.id, startingSession.id)
            XCTAssertEqual(session?.state, .starting)
            XCTAssertEqual(session?.isControlAvailable, false)
            XCTAssertEqual(session?.isSubscriptionAvailable, false)
            XCTAssertEqual(model.overview, refreshedOverview)
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.isMutating)
            let request = await recorder.snapshot().first
            XCTAssertEqual(request?.commandName, "openWorkspaceTerminal")
        }

        func testMutationOverviewUpdatesBrowserProxyRoutes() async {
            let refreshedOverview = makeOverview(
                featureAssignedPorts: [SpacesDeviceAssignedPort(name: "web", port: 3_000, url: "http://web.feature.localhost:3000")],
                featureConfig: SpacesDeviceWorkspaceConfig(
                    resolvedBrowserSessions: [SpacesDeviceBrowserSession(name: "Dashboard", url: "http://localhost:3000/dashboard")]))
            let recorder = SpacesMobileRequestRecorder()
            var settings = SpacesMobileConnectionSettings()
            settings.host = "127.0.0.1"
            settings.port = 47_847
            settings.certificateFingerprint = "fp-1"
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(
                    ok: true,
                    message: "Created workspace.",
                    result: .mutation(
                        SpacesDeviceMutationResult(
                            overview: refreshedOverview,
                            workspaceID: "workspace-feature")))
            }
            let proxy = SpacesMobileBrowserProxy(port: UInt16.random(in: 49_152...65_500), installationID: settings.installationID)
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client, browserProxy: proxy)
            model.activeDeviceID = "device-1"
            model.pairedDevices = [
                SpacesMobilePairedDeviceRecord(
                    id: "device-1", name: "Studio", host: settings.host, port: settings.port, certificateFingerprint: settings.certificateFingerprint,
                    createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", lastSelectedAt: nil)
            ]

            await model.createWorkspace(
                projectID: "project-1",
                branch: "feature",
                baseBranch: "main",
                directoryName: nil,
                allowExistingBranchReuse: false)

            let commandNames = await recorder.snapshot().map(\.commandName)
            XCTAssertEqual(commandNames, ["createWorkspace"])
            let browserRow = model.workspaceGroups.flatMap(\.rows).compactMap { row -> SpacesMobileBrowserSessionRow? in
                guard case .browserSession(let browserRow) = row.source else { return nil }
                return browserRow
            }.first
            XCTAssertEqual(browserRow?.id, "browser:workspace-feature:web:0")
            let target = await proxy.routeTarget(forHost: "web.feature.localhost")
            XCTAssertEqual(target?.deviceID, "device-1")
            XCTAssertEqual(target?.deviceName, "Studio")
            XCTAssertEqual(target?.host, "127.0.0.1")
            XCTAssertEqual(target?.port, 47_847)
            XCTAssertEqual(target?.certificateFingerprint, "fp-1")
            XCTAssertEqual(target?.workspaceID, "workspace-feature")
            XCTAssertEqual(target?.serviceName, "web")
            XCTAssertFalse(target?.proxyAuthToken.isEmpty ?? true)
            if let browserRow {
                let request = model.browserSessionProxyRequest(for: browserRow)
                XCTAssertEqual(request?.url.absoluteString, "http://web.feature.localhost:47898/dashboard")
                XCTAssertEqual(request?.authToken, target?.proxyAuthToken)
            }
        }

        func testRefreshUsesEmbeddedStatusWithoutSecondHandshake() async {
            let overview = makeOverview(daemonStatus: daemonStatus(protocolVersion: SpacesWireProtocol.version))
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)

            await model.refresh()

            // The verdict rode inline on the overview, so the compatible steady state makes one round-trip.
            let commandNames = await recorder.snapshot().map(\.commandName)
            XCTAssertEqual(commandNames, ["overview"])
            XCTAssertEqual(model.compatibility, .compatible)
            XCTAssertEqual(model.daemonStatus?.protocolVersion, SpacesWireProtocol.version)
            XCTAssertEqual(model.overview, overview)
            XCTAssertFalse(model.isActiveDeviceBlocked)
        }

        func testRefreshBlocksOnIncompatibleEmbeddedStatus() async {
            let overview = makeOverview(daemonStatus: daemonStatus(protocolVersion: SpacesWireProtocol.version + 1))
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)

            await model.refresh()

            let commandNames = await recorder.snapshot().map(\.commandName)
            XCTAssertEqual(commandNames, ["overview"])
            XCTAssertTrue(model.isActiveDeviceBlocked)
            // Blocked: do not surface the incompatible daemon's stale workspace data.
            XCTAssertNil(model.overview)
        }

        private func makeOverview(
            sessions: [SpacesDeviceTerminalSessionSummary] = [],
            featureProcessRows: [SpacesDeviceWorkspaceProcessRow]? = nil,
            featureCodingAgentRows: [SpacesDeviceWorkspaceCodingAgentRow]? = nil,
            featureAssignedPorts: [SpacesDeviceAssignedPort] = [],
            featureConfig: SpacesDeviceWorkspaceConfig = SpacesDeviceWorkspaceConfig(),
            daemonStatus: TerminalServiceDaemonStatus = TerminalServiceDaemonStatus(
                version: "1.0.0", artifactVersion: nil, certificateFingerprint: nil, activeSessionCount: 0, protocolVersion: SpacesWireProtocol.version)
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
                id: "workspace-feature", projectID: project.id, projectName: project.name, branch: "feature",
                baseBranch: "main", dir: "/repo/feature", isRunning: true, isArchived: false, isHidden: false, isDefault: false,
                sessionCount: 1,
                assignedPorts: featureAssignedPorts,
                config: featureConfig,
                processRows: processRows,
                codingAgentRows: codingAgentRows,
                terminalRows: [])
            let docs = SpacesDeviceWorkspaceSummary(
                id: "workspace-docs", projectID: project.id, projectName: project.name, branch: "docs", baseBranch: "main",
                dir: "/repo/docs", isRunning: false, isArchived: false, isHidden: false, isDefault: false, sessionCount: 0,
                processRows: [],
                codingAgentRows: [],
                terminalRows: [
                    SpacesDeviceWorkspaceTerminalRow(
                        id: "terminal-shell", workspaceID: "workspace-docs", title: "shell", workingDirectory: "/repo/docs", sessionID: nil,
                        runState: .exited, canOpenTerminal: false)
                ])
            return SpacesDeviceOverviewPayload(
                projects: [project], workspaces: [feature, docs], sessions: sessions, daemonStatus: daemonStatus)
        }

        private func daemonStatus(protocolVersion: Int) -> TerminalServiceDaemonStatus {
            TerminalServiceDaemonStatus(
                version: "1.0.0", artifactVersion: nil, certificateFingerprint: nil, activeSessionCount: 0, protocolVersion: protocolVersion)
        }

        private func makeSession(
            id: String,
            state: TerminalSessionState = .running,
            isControlAvailable: Bool = true,
            isSubscriptionAvailable: Bool = true
        ) -> SpacesDeviceTerminalSessionSummary {
            SpacesDeviceTerminalSessionSummary(
                id: id,
                title: "api",
                workingDirectory: "/repo/feature",
                shell: "/bin/zsh",
                command: nil,
                state: state,
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
                isControlAvailable: isControlAvailable,
                isSubscriptionAvailable: isSubscriptionAvailable,
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

        private func waitForBrowserProxyStatus(_ model: SpacesMobileAppModel, _ expected: BrowserProxyStatus) async throws {
            for _ in 0..<80 {
                if model.browserProxyStatus == expected { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTFail("Expected browser proxy status \(expected), got \(model.browserProxyStatus).")
        }
    }
#endif
