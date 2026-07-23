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

    /// Holds callers until opened, so tests can keep a fake request in flight deterministically.
    private actor SpacesMobileAsyncGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    @MainActor final class SpacesMobileAppModelTests: XCTestCase {
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
                featureConfig: SpacesDeviceWorkspaceConfig(resolvedBrowserSessions: [
                    SpacesDeviceBrowserSession(name: "Dashboard", url: "http://localhost:3000/dashboard")
                ]))

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

        /// Runtime rows group by family in the Mac sidebar's order: browser sessions, configured processes,
        /// coding agents, then ad hoc terminals.
        func testRuntimeRowsGroupByFamilyInMacSidebarOrder() {
            let model = makeModel()
            model.overview = makeOverview(
                featureTerminalRows: [
                    SpacesDeviceWorkspaceTerminalRow(
                        id: "terminal-shell", workspaceID: "workspace-feature", title: "shell", workingDirectory: "/repo/feature",
                        sessionID: "session-shell", runState: .running, canOpenTerminal: true, canStop: true)
                ], featureAssignedPorts: [SpacesDeviceAssignedPort(name: "web", port: 3_000, url: "http://web.feature.localhost:3000")],
                featureConfig: SpacesDeviceWorkspaceConfig(resolvedBrowserSessions: [
                    SpacesDeviceBrowserSession(name: "Dashboard", url: "http://localhost:3000/dashboard")
                ]))

            let rows = model.workspaceGroups.first { $0.workspace.id == "workspace-feature" }?.rows ?? []

            XCTAssertEqual(rows.map(\.type), [.browserSessions, .processes, .codingAgents, .workspaceTerminals])
            XCTAssertEqual(rows.map(\.title), ["Dashboard", "api", "Codex", "shell"])
        }

        /// `isHidden` is daemon-owned state shared with the Mac sidebar, so a workspace hidden on the Mac
        /// is absent from the phone's list too.
        func testHiddenWorkspaceIsExcludedFromWorkspaceGroups() {
            let model = makeModel()
            model.overview = makeOverview(featureIsHidden: true)

            let workspaceIDs = model.workspaceGroups.map(\.workspace.id)
            XCTAssertFalse(workspaceIDs.contains("workspace-feature"))
            XCTAssertTrue(workspaceIDs.contains("workspace-docs"))
        }

        /// Hiding a workspace must not leak its loose terminal sessions back into the list as their own
        /// group — hiding removes the workspace's rows, not just its band.
        func testHiddenWorkspaceLooseSessionsAreExcludedFromTerminalGroups() {
            let model = makeModel()
            model.overview = makeOverview(sessions: [makeSession(id: "session-loose")], featureIsHidden: true)

            XCTAssertFalse(model.terminalGroups.contains { $0.id == "workspace-feature" })
        }

        func testHideWorkspaceRechecksRunningStateBeforeStoppingAndHiding() async {
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let runningOverview = makeOverview(featureIsRunning: true)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                if request.commandName == "overview" { return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(runningOverview)) }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            let staleStoppedWorkspace = makeOverview(featureIsRunning: false).workspaces[0]

            await model.hideWorkspace(staleStoppedWorkspace)

            let requests = await recorder.snapshot()
            XCTAssertEqual(requests.map(\.commandName), ["overview", "stopWorkspace", "updateWorkspaceMetadata"])
        }

        /// A browser session has no run state, so its row draws no status dot — while the process and
        /// terminal rows beside it still do.
        func testBrowserSessionRowHasNoStatusDot() {
            let model = makeModel()
            model.overview = makeOverview(
                featureAssignedPorts: [SpacesDeviceAssignedPort(name: "web", port: 3_000, url: "http://web.feature.localhost:3000")],
                featureConfig: SpacesDeviceWorkspaceConfig(resolvedBrowserSessions: [
                    SpacesDeviceBrowserSession(name: "Dashboard", url: "http://localhost:3000/dashboard")
                ]))

            let rows = model.workspaceGroups.first { $0.workspace.id == "workspace-feature" }?.rows ?? []
            let browserRow = rows.first { $0.title == "Dashboard" }
            let processRow = rows.first { $0.title == "api" }

            XCTAssertEqual(browserRow?.isBrowserSession, true)
            XCTAssertNil(browserRow?.statusDotKind)
            XCTAssertEqual(processRow?.isBrowserSession, false)
            XCTAssertNotNil(processRow?.statusDotKind)
        }

        func testBrowserSessionRowsSurviveRunStateFilter() {
            let model = makeModel()
            model.overview = makeOverview(
                featureAssignedPorts: [SpacesDeviceAssignedPort(name: "web", port: 3_000, url: "http://web.feature.localhost:3000")],
                featureConfig: SpacesDeviceWorkspaceConfig(resolvedBrowserSessions: [
                    SpacesDeviceBrowserSession(name: "Dashboard", url: "http://localhost:3000/dashboard")
                ]))
            // A run-state filter that excludes every "real" run state must still leave browser rows visible.
            model.visibleRunStates = [.running]

            let rows = model.workspaceGroups.first { $0.workspace.id == "workspace-feature" }?.rows ?? []
            XCTAssertTrue(rows.contains { $0.title == "Dashboard" })
        }

        func testRowTypeFilterExcludesAndIncludesBrowserSessions() {
            let model = makeModel()
            model.overview = makeOverview(
                featureAssignedPorts: [SpacesDeviceAssignedPort(name: "web", port: 3_000, url: "http://web.feature.localhost:3000")],
                featureConfig: SpacesDeviceWorkspaceConfig(resolvedBrowserSessions: [
                    SpacesDeviceBrowserSession(name: "Dashboard", url: "http://localhost:3000/dashboard")
                ]))

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
            let client = SpacesDeviceAPIClient(settings: settings) { _ in SpacesDeviceAPIResponse(ok: true, message: "ok") }
            let proxyPort = try freeLocalTCPPort()
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
                        id: "template-api", workspaceID: "workspace-feature", name: "api", command: "npm run dev", templateID: "template-api",
                        processID: "runtime-api", sessionID: "session-api-old", runState: .exited, canRun: true, canStop: false, canRestart: false)))

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
                id: "template-api", workspaceID: "workspace-feature", name: "api", command: "npm run dev", templateID: "template-api",
                processID: "runtime-api-old", sessionID: "session-api-old", runState: .exited, canRun: true, canStop: false, canRestart: false)
            let newRow = SpacesDeviceWorkspaceProcessRow(
                id: "template-api", workspaceID: "workspace-feature", name: "api", command: "npm run dev", templateID: "template-api",
                processID: "runtime-api-new", sessionID: "session-api-new", runState: .running, canRun: false, canStop: true, canRestart: true)
            let refreshedOverview = makeOverview(sessions: [makeSession(id: "session-api-new")], featureProcessRows: [newRow])
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                if request.commandName == "runWorkspaceProcess" { throw SpacesDeviceAPIClientError.requestTimedOut }
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
                id: "agent-codex", workspaceID: "workspace-feature", name: "Codex", command: "codex", launcherID: "launcher-codex",
                agentID: "agent-old", sessionID: "session-codex-old", isConfigured: true, runState: .exited, activityState: .idle, canRun: true,
                canStop: false, canRestart: false)
            let newRow = SpacesDeviceWorkspaceCodingAgentRow(
                id: "agent-codex", workspaceID: "workspace-feature", name: "Codex", command: "codex", launcherID: "launcher-codex",
                agentID: "agent-new", sessionID: "session-codex-new", isConfigured: true, runState: .running, activityState: .spinning, canRun: false,
                canStop: true, canRestart: true)
            let refreshedOverview = makeOverview(
                sessions: [makeSession(id: "session-codex-new")], featureProcessRows: [], featureCodingAgentRows: [newRow])
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                if request.commandName == "runCodingAgent" { throw SpacesDeviceAPIClientError.requestTimedOut }
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

        func testOpenTerminalDeepLinkStagesSessionAndSelectsSpacesTab() async {
            let model = makeModel()
            model.overview = makeOverview(sessions: [makeSession(id: "session-orphan")])
            model.selectedTab = .alerts

            await model.openTerminalDeepLink(SpacesTerminalDeepLink(sessionID: "session-orphan"))

            XCTAssertEqual(model.pendingTerminalDeepLinkSession?.id, "session-orphan")
            XCTAssertEqual(model.selectedTab, .spaces)
            XCTAssertNil(model.errorMessage)
        }

        func testOpenTerminalDeepLinkForMissingSessionSurfacesError() async {
            let model = makeModel()
            model.overview = makeOverview(sessions: [makeSession(id: "session-orphan")])

            await model.openTerminalDeepLink(SpacesTerminalDeepLink(sessionID: "session-missing"))

            XCTAssertNil(model.pendingTerminalDeepLinkSession)
            XCTAssertNotNil(model.errorMessage)
        }

        func testOpenTerminalDeepLinkForUnpairedDeviceSurfacesError() async {
            let model = makeModel()
            model.overview = makeOverview(sessions: [makeSession(id: "session-orphan")])

            await model.openTerminalDeepLink(SpacesTerminalDeepLink(sessionID: "session-orphan", deviceID: "device-not-paired"))

            XCTAssertNil(model.pendingTerminalDeepLinkSession)
            XCTAssertNotNil(model.errorMessage)
        }

        // MARK: - Incoming link routing (onOpenURL)

        /// A pairing-shaped URL (scheme+host match `SpacesDevicePairingLink`) must route to `.pairing`
        /// even when the payload itself is malformed: an unsupported version, missing fields, or garbage
        /// query items. Routing must not depend on `SpacesDevicePairingLink.parse` succeeding, or a
        /// thrown parse error gets swallowed and the link silently falls through to another branch.
        func testIncomingLinkRoutingClassifiesMalformedPairingShapedURLAsPairing() {
            let unsupportedVersion = URL(string: "spaces://pair?v=1&host=10.0.0.4&port=19000&nonce=n&code=c&fp=f&pv=3&av=1.0")!
            let missingFields = URL(string: "spaces://pair?v=3")!

            XCTAssertEqual(SpacesIncomingLinkRoute.route(for: unsupportedVersion), .pairing(unsupportedVersion))
            XCTAssertEqual(SpacesIncomingLinkRoute.route(for: missingFields), .pairing(missingFields))
        }

        func testIncomingLinkRoutingClassifiesValidPairingURLAsPairing() {
            let link = SpacesDevicePairingLink(
                host: "10.0.0.4", port: 19000, nonce: "nonce", code: "code", certificateFingerprint: "fp", name: "Mac Studio", protocolVersion: 3,
                appVersion: "1.0")

            XCTAssertEqual(SpacesIncomingLinkRoute.route(for: link.url), .pairing(link.url))
        }

        func testIncomingLinkRoutingClassifiesTerminalURLAsTerminal() {
            let url = SpacesTerminalDeepLink(sessionID: "session-orphan").url

            XCTAssertEqual(SpacesIncomingLinkRoute.route(for: url), .terminal(SpacesTerminalDeepLink(sessionID: "session-orphan")))
        }

        func testIncomingLinkRoutingClassifiesUnrelatedURLAsUnrecognized() {
            let url = URL(string: "https://example.com")!

            XCTAssertEqual(SpacesIncomingLinkRoute.route(for: url), .unrecognized(url))
        }

        /// Regression for the bug where `onOpenURL` decided the route by whether
        /// `SpacesDevicePairingLink.parse` succeeded: a malformed pairing link fell through to the
        /// terminal-link branch (which also failed, wrong host) and was merely logged, leaving the user
        /// with no feedback. Routing a malformed-but-pairing-shaped link to `preparePairingLink` must
        /// surface a visible error instead of silence.
        func testMalformedPairingShapedLinkSurfacesVisibleErrorNotSilence() {
            let model = makeModel()
            let malformedPairingLink = URL(string: "spaces://pair?v=1")!

            switch SpacesIncomingLinkRoute.route(for: malformedPairingLink) {
            case .pairing(let url): model.preparePairingLink(url)
            case .terminal, .unrecognized: XCTFail("A pairing-shaped URL must route to .pairing regardless of payload validity.")
            }

            XCTAssertNotNil(model.errorMessage)
            XCTAssertNil(model.pendingPairingLink)
        }

        /// A QR payload scanned from the Spaces tab's not-paired empty state must stage the same way a
        /// `spaces://pair` deep link does — `prepareScannedPairingLink` shares `preparePairingLink`'s
        /// staging path, so a valid scan sets `pendingPairingLink` and raises `isShowingConnectionSettings`
        /// to hand off to the same confirm-and-pair alert.
        func testPrepareScannedPairingLinkStagesLinkAndRaisesConnectionSettings() {
            let model = makeModel()
            let link = SpacesDevicePairingLink(
                host: "10.0.0.4", port: 19000, nonce: "nonce", code: "code", certificateFingerprint: "fp", name: "Mac Studio", protocolVersion: 3,
                appVersion: "1.0")

            model.prepareScannedPairingLink(link.absoluteString)

            XCTAssertEqual(model.pendingPairingLink, link)
            XCTAssertTrue(model.isShowingConnectionSettings)
            XCTAssertNil(model.errorMessage)
        }

        /// A deep link can name a session created after the overview was last fetched (polling pauses
        /// while a terminal detail view is open — exactly where agent-notification links appear), so a
        /// lookup miss against the cached overview must refresh once before the link is rejected.
        func testOpenTerminalDeepLinkRefreshesStaleOverviewBeforeRejecting() async {
            let freshOverview = makeOverview(sessions: [makeSession(id: "session-new")])
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(freshOverview))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.overview = makeOverview()

            await model.openTerminalDeepLink(SpacesTerminalDeepLink(sessionID: "session-new"))

            XCTAssertEqual(model.pendingTerminalDeepLinkSession?.id, "session-new")
            XCTAssertEqual(model.selectedTab, .spaces)
            XCTAssertNil(model.errorMessage)
        }

        /// A deep link typically arrives while the app is foregrounding — the same moment the overview
        /// poller fires. Its refresh must join the in-flight fetch and resolve the session from the
        /// result instead of silently returning with no overview and rejecting the link.
        func testOpenTerminalDeepLinkResolvesWhileRefreshIsInFlight() async {
            let overview = makeOverview(sessions: [makeSession(id: "session-linked")])
            let gate = SpacesMobileAsyncGate()
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                await gate.wait()
                return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)

            let poll = Task { await model.refresh() }
            while !model.isLoading { await Task.yield() }
            let deepLink = Task { await model.openTerminalDeepLink(SpacesTerminalDeepLink(sessionID: "session-linked")) }
            // Give the deep link ample turns to reach its refresh while the poll's fetch is still
            // gated, so a refresh that drops concurrent callers is caught deterministically.
            for _ in 0..<100 { await Task.yield() }
            await gate.open()
            await deepLink.value
            await poll.value

            XCTAssertEqual(model.pendingTerminalDeepLinkSession?.id, "session-linked")
            XCTAssertNil(model.errorMessage)
        }

        /// An overview fetch begun before the connection identity changed (device switch, settings
        /// change, auth reset) must not publish afterwards: its payload belongs to the previous
        /// identity and would overwrite the reset state the change just established.
        func testIdentityChangeDiscardsInFlightRefreshResult() async {
            let overview = makeOverview()
            let gate = SpacesMobileAsyncGate()
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                await gate.wait()
                return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)

            let poll = Task { await model.refresh() }
            while !model.isLoading { await Task.yield() }
            model.handleAuthenticationFailure(message: "Token rejected.")
            await gate.open()
            await poll.value

            XCTAssertNil(model.overview, "a fetch begun before the identity change must not publish its stale overview")
            XCTAssertEqual(model.connectionNotice, "Token rejected.")
        }

        /// A failed overview fetch falls back to a standalone frozen-core handshake. If the identity
        /// changes (device switch/removal) while that fallback is still in flight, its stale verdict must
        /// not overwrite `daemonStatus`/`compatibility` for the new connection, nor clear the
        /// `connectionNotice` the identity change just published.
        func testStaleCompatibilityFallbackDoesNotOverwriteNewIdentityState() async {
            let recorder = SpacesMobileRequestRecorder()
            let gate = SpacesMobileAsyncGate()
            let settings = SpacesMobileConnectionSettings()
            let staleStatus = daemonStatus(protocolVersion: SpacesWireProtocol.version + 1)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                switch request.commandName {
                case "overview": throw SpacesDeviceAPIClientError.requestTimedOut
                case "daemonStatus":
                    await gate.wait()
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .daemonStatus(staleStatus))
                default: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)

            let refreshTask = Task { await model.refresh() }
            while !(await recorder.snapshot()).contains(where: { $0.commandName == "daemonStatus" }) { await Task.yield() }
            // The overview fetch already failed and the fallback handshake is now gated. Switch the
            // identity out from under it before letting it resolve.
            model.handleAuthenticationFailure(message: "Token rejected.")
            await gate.open()
            await refreshTask.value

            XCTAssertNil(model.daemonStatus, "a stale handshake must not publish daemon status for the new identity")
            XCTAssertNil(model.compatibility, "a stale handshake must not publish compatibility for the new identity")
            XCTAssertNil(model.overview)
            XCTAssertEqual(model.connectionNotice, "Token rejected.", "the identity change's notice must survive the stale fallback")
        }

        func testTerminalGroupsExcludeSessionsRepresentedByWorkspaceRows() {
            let model = makeModel()
            model.overview = makeOverview(sessions: [makeSession(id: "session-api"), makeSession(id: "session-orphan")])

            XCTAssertEqual(model.workspaceGroups.flatMap(\.rows).compactMap(\.sessionID), ["session-api", "session-codex"])
            XCTAssertEqual(model.terminalGroups.flatMap(\.sessions).map(\.id), ["session-orphan"])
        }

        func testMutationCancellationDoesNotShowConnectionError() async {
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in throw CancellationError() }
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
                    ok: true, message: "Opened workspace terminal.",
                    result: .mutation(
                        SpacesDeviceMutationResult(overview: refreshedOverview, workspaceID: "workspace-feature", sessionID: startingSession.id)))
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

        func testMutationOverviewUpdatesBrowserProxyRoutes() async throws {
            let refreshedOverview = makeOverview(
                featureAssignedPorts: [SpacesDeviceAssignedPort(name: "web", port: 3_000, url: "http://web.feature.localhost:3000")],
                featureConfig: SpacesDeviceWorkspaceConfig(resolvedBrowserSessions: [
                    SpacesDeviceBrowserSession(name: "Dashboard", url: "http://localhost:3000/dashboard")
                ]))
            let recorder = SpacesMobileRequestRecorder()
            var settings = SpacesMobileConnectionSettings()
            settings.host = "127.0.0.1"
            settings.port = 47_847
            settings.certificateFingerprint = "fp-1"
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(
                    ok: true, message: "Created workspace.",
                    result: .mutation(SpacesDeviceMutationResult(overview: refreshedOverview, workspaceID: "workspace-feature")))
            }
            let proxy = SpacesMobileBrowserProxy(port: try freeLocalTCPPort(), installationID: settings.installationID)
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client, browserProxy: proxy)
            model.activeDeviceID = "device-1"
            model.pairedDevices = [
                SpacesMobilePairedDeviceRecord(
                    id: "device-1", name: "Studio", host: settings.host, port: settings.port, certificateFingerprint: settings.certificateFingerprint,
                    createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", lastSelectedAt: nil)
            ]

            await model.createWorkspace(
                projectID: "project-1", branch: "feature", baseBranch: "main", directoryName: nil, allowExistingBranchReuse: false)

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

        // MARK: - Renaming runtime rows

        func testRenameAdHocTerminalRowRenamesItsSession() async throws {
            let (model, recorder) = makeRenamingModel(
                overview: makeOverview(featureTerminalRows: [
                    SpacesDeviceWorkspaceTerminalRow(
                        id: "terminal-shell", workspaceID: "workspace-feature", title: "shell", workingDirectory: "/repo/feature",
                        sessionID: "session-shell", runState: .running, canOpenTerminal: true, canStop: true)
                ]))
            let row = try XCTUnwrap(model.workspaceGroups.flatMap(\.rows).first { $0.title == "shell" })

            XCTAssertEqual(model.canRename(row: row), true)
            await model.rename(row: row, to: "  build log  ")

            guard case .renameTerminalSession(let request)? = await recorder.snapshot().first?.command else {
                return XCTFail("Expected a renameTerminalSession command.")
            }
            XCTAssertEqual(request.workspaceID, "workspace-feature")
            XCTAssertEqual(request.sessionID, "session-shell")
            XCTAssertEqual(request.title, "build log")
            XCTAssertNil(model.errorMessage)
        }

        /// A configured process is named by its workspace config, not by its session, so the rename edits the
        /// config entry — echoing every other configured field back unchanged.
        func testRenameConfiguredProcessRowEditsItsConfigEntry() async throws {
            let (model, recorder) = makeRenamingModel(overview: makeOverview(featureProcessRows: [configuredProcessRow()], featureConfig: config()))
            let row = try XCTUnwrap(model.workspaceGroups.flatMap(\.rows).first { $0.title == "api" })

            await model.rename(row: row, to: "backend")

            let requests = await recorder.snapshot()
            XCTAssertEqual(requests.map(\.commandName), ["overview", "updateWorkspaceConfig"])
            guard case .updateWorkspaceConfig(let request)? = requests.last?.command else {
                return XCTFail("Expected an updateWorkspaceConfig command.")
            }
            XCTAssertEqual(request.workspaceID, "workspace-feature")
            XCTAssertEqual(request.config.processes.map(\.name), ["backend"])
            XCTAssertEqual(request.config.processes.map(\.command), ["npm run dev"])
            XCTAssertEqual(request.config.stopScript, "npm stop")
            XCTAssertEqual(request.config.ports.map(\.name), ["web"])
            XCTAssertEqual(request.config.agentLaunchers.map(\.name), ["Codex"])
            XCTAssertEqual(request.config.browserSessions.map(\.name), ["Dashboard"])
        }

        func testRenameConfiguredCodingAgentRowEditsItsLauncherEntry() async throws {
            let (model, recorder) = makeRenamingModel(
                overview: makeOverview(featureCodingAgentRows: [configuredCodingAgentRow()], featureConfig: config()))
            let row = try XCTUnwrap(model.workspaceGroups.flatMap(\.rows).first { $0.title == "Codex" })

            await model.rename(row: row, to: "Reviewer")

            guard case .updateWorkspaceConfig(let request)? = await recorder.snapshot().last?.command else {
                return XCTFail("Expected an updateWorkspaceConfig command.")
            }
            XCTAssertEqual(request.config.agentLaunchers.map(\.name), ["Reviewer"])
            XCTAssertEqual(request.config.agentLaunchers.map(\.command), ["codex"])
            XCTAssertEqual(request.config.processes.map(\.name), ["api"])
        }

        /// The configured browser session is matched by name and its raw URL is preserved: resolution expands
        /// environment variables in the URL, so sending the resolved URL back would bake the expansion into
        /// the config.
        func testRenameBrowserSessionRowKeepsItsUnresolvedURL() async throws {
            let (model, recorder) = makeRenamingModel(
                overview: makeOverview(
                    featureAssignedPorts: [SpacesDeviceAssignedPort(name: "web", port: 3_000, url: "http://web.feature.localhost:3000")],
                    featureConfig: config()))
            let row = try XCTUnwrap(model.workspaceGroups.flatMap(\.rows).first { $0.title == "Dashboard" })

            await model.rename(row: row, to: "App")

            guard case .updateWorkspaceConfig(let request)? = await recorder.snapshot().last?.command else {
                return XCTFail("Expected an updateWorkspaceConfig command.")
            }
            XCTAssertEqual(request.config.browserSessions.map(\.name), ["App"])
            XCTAssertEqual(request.config.browserSessions.map(\.url), ["http://localhost:${PORT_web}/dashboard"])
        }

        func testRenameConfiguredRowPreservesConcurrentConfigEdits() async throws {
            let cachedOverview = makeOverview(featureProcessRows: [configuredProcessRow()], featureConfig: config())
            let latestConfig = SpacesDeviceWorkspaceConfig(
                stopScript: "updated stop",
                ports: [SpacesDeviceServiceDefinition(id: "port-api", name: "api"), SpacesDeviceServiceDefinition(id: "port-web", name: "web")],
                processes: [
                    SpacesDeviceProcessTemplate(id: "template-worker", name: "worker", command: "npm run worker"),
                    SpacesDeviceProcessTemplate(id: "template-api", name: "api", command: "npm run dev"),
                ], browserSessions: [SpacesDeviceBrowserSession(name: "Docs", url: "http://localhost:4000")],
                agentLaunchers: [SpacesDeviceAgentLauncher(id: "launcher-review", name: "Review", command: "review")])
            let latestOverview = makeOverview(featureProcessRows: [configuredProcessRow()], featureConfig: latestConfig)
            let (model, recorder) = makeRenamingModel(overview: cachedOverview, fetchedOverview: latestOverview)
            let row = try XCTUnwrap(model.workspaceGroups.flatMap(\.rows).first { $0.title == "api" })

            await model.rename(row: row, to: "backend")

            guard case .updateWorkspaceConfig(let request)? = await recorder.snapshot().last?.command else {
                return XCTFail("Expected an updateWorkspaceConfig command.")
            }
            XCTAssertEqual(request.config.stopScript, "updated stop")
            XCTAssertEqual(request.config.ports.map(\.name), ["api", "web"])
            XCTAssertEqual(request.config.processes.map(\.name), ["worker", "backend"])
            XCTAssertEqual(request.config.browserSessions.map(\.name), ["Docs"])
            XCTAssertEqual(request.config.agentLaunchers.map(\.name), ["Review"])
        }

        /// A process running without a configured entry takes its name from the running process, so there is
        /// nothing to rename and the row offers no Rename.
        func testUnconfiguredProcessRowCannotBeRenamed() async throws {
            let (model, recorder) = makeRenamingModel(overview: makeOverview(featureConfig: config()))
            let row = try XCTUnwrap(model.workspaceGroups.flatMap(\.rows).first { $0.title == "api" })

            XCTAssertEqual(model.canRename(row: row), false)
            await model.rename(row: row, to: "backend")

            let commandNames = await recorder.snapshot().map(\.commandName)
            XCTAssertEqual(commandNames, [])
        }

        func testRenameIgnoresEmptyAndUnchangedTitles() async throws {
            let (model, recorder) = makeRenamingModel(overview: makeOverview(featureProcessRows: [configuredProcessRow()], featureConfig: config()))
            let row = try XCTUnwrap(model.workspaceGroups.flatMap(\.rows).first { $0.title == "api" })

            await model.rename(row: row, to: "   ")
            await model.rename(row: row, to: "api")

            let commandNames = await recorder.snapshot().map(\.commandName)
            XCTAssertEqual(commandNames, [])
        }

        private func makeRenamingModel(overview: SpacesDeviceOverviewPayload, fetchedOverview: SpacesDeviceOverviewPayload? = nil) -> (
            model: SpacesMobileAppModel, recorder: SpacesMobileRequestRecorder
        ) {
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                if case .overview = request.command {
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(fetchedOverview ?? overview))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.overview = overview
            return (model, recorder)
        }

        /// The feature workspace's configuration, matching the configured process, launcher, and browser
        /// session the rename tests target.
        private func config() -> SpacesDeviceWorkspaceConfig {
            SpacesDeviceWorkspaceConfig(
                stopScript: "npm stop", ports: [SpacesDeviceServiceDefinition(id: "port-web", name: "web")],
                processes: [SpacesDeviceProcessTemplate(id: "template-api", name: "api", command: "npm run dev")],
                browserSessions: [SpacesDeviceBrowserSession(name: "Dashboard", url: "http://localhost:${PORT_web}/dashboard")],
                resolvedBrowserSessions: [SpacesDeviceBrowserSession(name: "Dashboard", url: "http://localhost:3000/dashboard")],
                agentLaunchers: [SpacesDeviceAgentLauncher(id: "launcher-codex", name: "Codex", command: "codex")])
        }

        private func configuredProcessRow() -> SpacesDeviceWorkspaceProcessRow {
            SpacesDeviceWorkspaceProcessRow(
                id: "template-api", workspaceID: "workspace-feature", name: "api", command: "npm run dev", templateID: "template-api",
                processID: "runtime-api", sessionID: "session-api", runState: .running, canRun: false, canStop: true, canRestart: true)
        }

        private func configuredCodingAgentRow() -> SpacesDeviceWorkspaceCodingAgentRow {
            SpacesDeviceWorkspaceCodingAgentRow(
                id: "agent-codex", workspaceID: "workspace-feature", name: "Codex", command: "codex", launcherID: "launcher-codex",
                agentID: "runtime-codex", sessionID: "session-codex", isConfigured: true, runState: .running, activityState: .spinning, canRun: false,
                canStop: true, canRestart: true)
        }

        private func makeOverview(
            sessions: [SpacesDeviceTerminalSessionSummary] = [], featureProcessRows: [SpacesDeviceWorkspaceProcessRow]? = nil,
            featureCodingAgentRows: [SpacesDeviceWorkspaceCodingAgentRow]? = nil, featureTerminalRows: [SpacesDeviceWorkspaceTerminalRow] = [],
            featureIsRunning: Bool = true, featureIsHidden: Bool = false, featureAssignedPorts: [SpacesDeviceAssignedPort] = [],
            featureConfig: SpacesDeviceWorkspaceConfig = SpacesDeviceWorkspaceConfig(),
            daemonStatus: TerminalServiceDaemonStatus = TerminalServiceDaemonStatus(
                version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0,
                protocolVersion: SpacesWireProtocol.version)
        ) -> SpacesDeviceOverviewPayload {
            let project = SpacesDeviceProjectSummary(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
            let processRows =
                featureProcessRows ?? [
                    SpacesDeviceWorkspaceProcessRow(
                        id: "process-api", workspaceID: "workspace-feature", name: "api", command: "npm run dev", processID: "runtime-api",
                        sessionID: "session-api", runState: .running, canRun: false, canStop: true, canRestart: true)
                ]
            let codingAgentRows =
                featureCodingAgentRows ?? [
                    SpacesDeviceWorkspaceCodingAgentRow(
                        id: "agent-codex", workspaceID: "workspace-feature", name: "Codex", command: "codex", agentID: "runtime-codex",
                        sessionID: "session-codex", isConfigured: true, runState: .running, activityState: .spinning, canRun: false, canStop: true,
                        canRestart: true)
                ]
            let feature = SpacesDeviceWorkspaceSummary(
                id: "workspace-feature", projectID: project.id, projectName: project.name, branch: "feature", baseBranch: "main",
                dir: "/repo/feature", isRunning: featureIsRunning, isArchived: false, isHidden: featureIsHidden, isDefault: false, sessionCount: 1,
                assignedPorts: featureAssignedPorts, config: featureConfig, processRows: processRows, codingAgentRows: codingAgentRows,
                terminalRows: featureTerminalRows)
            let docs = SpacesDeviceWorkspaceSummary(
                id: "workspace-docs", projectID: project.id, projectName: project.name, branch: "docs", baseBranch: "main", dir: "/repo/docs",
                isRunning: false, isArchived: false, isHidden: false, isDefault: false, sessionCount: 0, processRows: [], codingAgentRows: [],
                terminalRows: [
                    SpacesDeviceWorkspaceTerminalRow(
                        id: "terminal-shell", workspaceID: "workspace-docs", title: "shell", workingDirectory: "/repo/docs", sessionID: nil,
                        runState: .exited, canOpenTerminal: false)
                ])
            return SpacesDeviceOverviewPayload(projects: [project], workspaces: [feature, docs], sessions: sessions, daemonStatus: daemonStatus)
        }

        private func daemonStatus(protocolVersion: Int) -> TerminalServiceDaemonStatus {
            TerminalServiceDaemonStatus(
                version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0, protocolVersion: protocolVersion)
        }

        private func makeSession(
            id: String, state: TerminalSessionState = .running, isControlAvailable: Bool = true, isSubscriptionAvailable: Bool = true
        ) -> SpacesDeviceTerminalSessionSummary {
            SpacesDeviceTerminalSessionSummary(
                id: id, title: "api", workingDirectory: "/repo/feature", shell: "/bin/zsh", command: nil, state: state, backend: .ghosttyEmbedded,
                lifetimePolicy: .persistent, servicePID: 100, childPID: 101, workspaceID: "workspace-feature", workspaceTitle: "Feature",
                projectID: "project-1", projectName: "Project", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:01Z",
                isControlAvailable: isControlAvailable, isSubscriptionAvailable: isSubscriptionAvailable,
                attachmentSnapshot: TerminalSessionAttachmentSnapshot())
        }

        private func makeModel() -> SpacesMobileAppModel {
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in SpacesDeviceAPIResponse(ok: true, message: "ok") }
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
