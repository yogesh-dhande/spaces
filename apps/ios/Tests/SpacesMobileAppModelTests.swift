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

    /// Counts calls across the fake bridge's `@Sendable` request closure, so a test can make the Nth
    /// `daemonStatus` poll behave differently from the ones before it (e.g. "unreachable twice, then
    /// reachable").
    private actor SpacesMobilePollCounter {
        private var count = 0
        func increment() -> Int {
            count += 1
            return count
        }
    }

    /// The status a fake device reports about itself, changeable mid-test from the `@Sendable` request
    /// closure's side, so a device can be made to finally come back on its staged build.
    private actor SpacesMobileDaemonStatusBox {
        private var status: TerminalServiceDaemonStatus

        init(_ status: TerminalServiceDaemonStatus) { self.status = status }
        func set(_ status: TerminalServiceDaemonStatus) { self.status = status }
        func current() -> TerminalServiceDaemonStatus { status }
    }

    /// A backend whose `currentResolvedHost()` returns a fixed value instead of the default `nil`, so a
    /// test can prove `SpacesMobileAppModel.updateBrowserRoutes` prefers the client's live-resolved host
    /// over a stale paired-device record without needing a real `SpacesDeviceEndpointResolver` handshake.
    /// Requests route through a closure exactly like `SpacesDeviceClosureBackend`; only the resolved-host
    /// reporting differs.
    private struct SpacesMobileFakeResolvedHostBackend: SpacesDeviceAPIBackend {
        let resolvedHost: String?
        let handler: @Sendable (SpacesDeviceAPIRequest) async throws -> SpacesDeviceAPIResponse

        func makeRequestTransport() -> any SpacesDeviceAPIRequestTransport { SpacesMobileFakeRequestTransport(handler: handler) }

        func openSessionStream(
            request: SpacesDeviceAPIRequest, onEvent: @escaping @MainActor (GhosttyRemoteSessionStatePayload) -> Void,
            onDisconnect: @escaping @MainActor (Error?) -> Void
        ) async throws -> SpacesDeviceAPIStreamHandle { throw SpacesDeviceAPIClientError.invalidEndpoint }

        func currentResolvedHost() async -> String? { resolvedHost }
    }

    private struct SpacesMobileFakeRequestTransport: SpacesDeviceAPIRequestTransport {
        let handler: @Sendable (SpacesDeviceAPIRequest) async throws -> SpacesDeviceAPIResponse
        func send(request: SpacesDeviceAPIRequest, timeout: Duration) async throws -> SpacesDeviceAPIResponse { try await handler(request) }
        func close() async {}
    }

    /// Lets the refresh-failure tests cross `refreshFailureAlertDelay` by advancing time rather than
    /// sleeping past it, so the assertions do not depend on how fast the machine runs them.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        var now: ContinuousClock.Instant {
            lock.lock()
            defer { lock.unlock() }
            return instant
        }
        func advance(by duration: Duration) {
            lock.lock()
            defer { lock.unlock() }
            instant = instant.advanced(by: duration)
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
            let agent = rows.first { $0.title == "Codex" }

            XCTAssertEqual(process?.canStop, true)
            XCTAssertEqual(process?.canRestart, true)
            XCTAssertEqual(process?.sessionID, "session-api")
            XCTAssertEqual(terminal?.canRun, false)
            XCTAssertEqual(terminal?.runState, .exited)
            // Stop is an agent's only lifecycle control: it exists only as a session someone started by
            // running its command in a terminal, so there is nothing to start or restart.
            XCTAssertEqual(agent?.canRun, false)
            XCTAssertEqual(agent?.canRestart, false)
            XCTAssertEqual(agent?.canRestartFromTerminalDetail, false)
            XCTAssertEqual(agent?.canStop, true)
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

        /// A shell is searchable by what its program is doing, not only by what it is called — the two
        /// halves of its row both match.
        func testSearchMatchesAShellsLiveTitle() {
            let model = makeModel()
            model.overview = makeOverview(featureTerminalRows: [
                SpacesDeviceWorkspaceTerminalRow(
                    id: "terminal-shell", workspaceID: "workspace-feature", title: "shell-1", workingDirectory: "/repo/feature",
                    sessionID: "session-shell", runState: .running, canOpenTerminal: true, canStop: true, liveTitle: "vim main.swift")
            ])

            model.searchText = "vim"
            let rows = model.workspaceGroups.first { $0.workspace.id == "workspace-feature" }?.rows ?? []
            XCTAssertEqual(rows.map(\.title), ["shell-1"])
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

            XCTAssertFalse(model.terminalGroups.contains { $0.workspaceID == "workspace-feature" })
        }

        /// Deleting a workspace drops its record from the overview while its ended sessions linger for a
        /// refresh or two. Those orphaned sessions must not re-home into a loose group named for a
        /// workspace the list no longer has.
        func testSessionsOfAWorkspaceMissingFromTheOverviewFormNoTerminalGroup() {
            let model = makeModel()
            let populated = makeOverview(sessions: [makeSession(id: "session-loose")])
            model.overview = SpacesDeviceOverviewPayload(
                projects: populated.projects, workspaces: populated.workspaces.filter { $0.id != "workspace-feature" }, sessions: populated.sessions,
                daemonStatus: populated.daemonStatus)

            XCTAssertFalse(model.terminalGroups.contains { $0.workspaceID == "workspace-feature" })
            XCTAssertTrue(model.terminalGroups.flatMap(\.sessions).isEmpty)
        }

        /// A workspace whose sessions are not all among its runtime rows is listed twice on the Spaces tab:
        /// once as its own band among the projects, once as a loose-session band after them. Those are two
        /// rows of one list, so they must not answer to the same identity — a list holding fewer distinct
        /// identities than it has rows miscounts every batch update it performs and crashes.
        func testLooseSessionGroupDoesNotShareItsWorkspaceBandIdentity() {
            let model = makeModel()
            model.overview = makeOverview(sessions: [makeSession(id: "session-loose")])

            let looseGroup = model.terminalGroups.first { $0.workspaceID == "workspace-feature" }

            XCTAssertNotNil(looseGroup, "Expected the unrepresented session to form a loose group.")
            XCTAssertTrue(model.workspaceGroups.contains { $0.id == "workspace-feature" })
            XCTAssertTrue(Set(model.terminalGroups.map(\.id)).isDisjoint(with: Set(model.workspaceGroups.map(\.id))))
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

        /// `hiddenWorkspaces` is the mirror image of the `workspaceGroups` exclusion above: a hidden
        /// workspace is absent from the filtered browse list but present in the recovery list.
        func testHiddenWorkspaceIsExcludedFromVisibleButPresentInHiddenWorkspaces() {
            let model = makeModel()
            model.overview = makeOverview(featureIsHidden: true)

            XCTAssertFalse(model.workspaceGroups.contains { $0.workspace.id == "workspace-feature" })
            XCTAssertEqual(model.hiddenWorkspaces.map(\.id), ["workspace-feature"])
        }

        /// With no hidden workspaces, the recovery list is empty regardless of what else the overview has.
        func testHiddenWorkspacesIsEmptyWhenNoneAreHidden() {
            let model = makeModel()
            model.overview = makeOverview()

            XCTAssertTrue(model.hiddenWorkspaces.isEmpty)
        }

        /// Unhiding sends `setWorkspaceHidden(isHidden: false)` and, unlike `hideWorkspace`, never checks
        /// or stops anything first — there is nothing running to stop on a workspace that is already hidden.
        func testUnhideWorkspaceSendsSetWorkspaceHiddenFalseAndPublishesRefreshedOverview() async {
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let refreshedOverview = makeOverview(featureIsHidden: false)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(
                    ok: true, message: "ok",
                    result: .mutation(SpacesDeviceMutationResult(overview: refreshedOverview, workspaceID: "workspace-feature")))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            let hiddenWorkspace = makeOverview(featureIsHidden: true).workspaces[0]

            await model.unhideWorkspace(hiddenWorkspace)

            let requests = await recorder.snapshot()
            XCTAssertEqual(requests.map(\.commandName), ["updateWorkspaceMetadata"])
            guard case .updateWorkspaceMetadata(let payload)? = requests.first?.command else {
                XCTFail("Expected an updateWorkspaceMetadata command.")
                return
            }
            XCTAssertEqual(payload.workspaceID, "workspace-feature")
            XCTAssertEqual(payload.isHidden, false)
            XCTAssertEqual(model.overview, refreshedOverview)
        }

        /// Delete sends one `archiveWorkspace` carrying the branch choices, and publishes the refreshed
        /// overview the daemon returns with it.
        func testDeleteWorkspaceSendsArchiveWithBranchChoicesAndPublishesRefreshedOverview() async {
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let refreshedOverview = makeOverview(featureIsRunning: false)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(
                    ok: true, message: "Deleted workspace.",
                    result: .mutation(SpacesDeviceMutationResult(overview: refreshedOverview, workspaceID: "workspace-feature")))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            let workspace = makeOverview().workspaces[0]

            await model.deleteWorkspace(workspace, deleteLocalBranch: true, deleteRemoteBranch: false)

            let requests = await recorder.snapshot()
            XCTAssertEqual(requests.map(\.commandName), ["archiveWorkspace"])
            guard case .archiveWorkspace(let payload)? = requests.first?.command else {
                XCTFail("Expected an archiveWorkspace command.")
                return
            }
            XCTAssertEqual(payload.workspaceID, "workspace-feature")
            XCTAssertTrue(payload.deleteLocalBranch)
            XCTAssertFalse(payload.deleteRemoteBranch)
            XCTAssertEqual(model.overview, refreshedOverview)
            XCTAssertNil(model.deletedWorkspaceNotice)
        }

        /// Branch deletion is the one part of a delete that can partly fail, so the notice it comes back
        /// with is surfaced; a delete with no branch to report stays silent (covered above).
        func testDeleteWorkspaceSurfacesBranchDeletionNotice() async {
            let settings = SpacesMobileConnectionSettings()
            let refreshedOverview = makeOverview(featureIsRunning: false)
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                SpacesDeviceAPIResponse(
                    ok: true, message: "Deleted workspace.",
                    result: .mutation(
                        SpacesDeviceMutationResult(
                            overview: refreshedOverview, workspaceID: "workspace-feature", notice: "Skipped protected branch \"main\".")))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)

            await model.deleteWorkspace(makeOverview().workspaces[0], deleteLocalBranch: true, deleteRemoteBranch: true)

            XCTAssertEqual(model.deletedWorkspaceNotice, "Skipped protected branch \"main\".")

            model.dismissDeletedWorkspaceNotice()

            XCTAssertNil(model.deletedWorkspaceNotice)
        }

        func testDeleteWorkspaceSurfacesFailure() async {
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                // The daemon codes every failure it reports; a refusal is what this models.
                SpacesDeviceAPIResponse(ok: false, message: "Default workspace cannot be deleted.", errorCode: .invalidArgument)
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)

            await model.deleteWorkspace(makeOverview().workspaces[0], deleteLocalBranch: false, deleteRemoteBranch: false)

            XCTAssertNotNil(model.errorMessage)
            XCTAssertNil(model.deletedWorkspaceNotice)
        }

        /// The daemon takes seconds to stop a workspace and remove its worktree, and it stays in every
        /// overview until then, so the workspace is marked as deleting for the whole mutation — that mark
        /// is the feedback the Spaces tab renders on the band.
        func testWorkspaceIsMarkedPendingDeletionWhileTheDeleteIsInFlight() async {
            let gate = SpacesMobileAsyncGate()
            let settings = SpacesMobileConnectionSettings()
            let refreshedOverview = makeOverview(featureIsRunning: false)
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                await gate.wait()
                return SpacesDeviceAPIResponse(
                    ok: true, message: "Deleted workspace.",
                    result: .mutation(SpacesDeviceMutationResult(overview: refreshedOverview, workspaceID: "workspace-feature")))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            let workspace = makeOverview().workspaces[0]

            let delete = Task { await model.deleteWorkspace(workspace, deleteLocalBranch: false, deleteRemoteBranch: false) }
            while !model.isWorkspacePendingDeletion("workspace-feature") { await Task.yield() }

            XCTAssertFalse(model.isMutating, "a delete never holds the app-wide mutation gate (#450)")
            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-docs"))

            await gate.open()
            await delete.value

            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-feature"))
        }

        /// Before #450 was fixed, `deleteWorkspace` held the app-wide `isMutating` flag for its whole
        /// duration, so a second workspace's delete — sent on its own private channel and with no bearing
        /// on the first — was rejected by the same guard, silently. Neither call is rejected now: both
        /// mark their own workspace immediately, and workspace-docs's delete is not dropped just because
        /// workspace-feature's is still unresolved — it queues behind it (`pendingDeleteChains`, review
        /// round 2 finding 1) and completes on its own once the queue reaches it. See
        /// `testConcurrentDeletesMarkBothWorkspacesButSerializeTheirRequests` for the queue's ordering
        /// guarantee itself; this test's focus is that queuing is not rejection.
        func testDeleteOfOneWorkspaceDoesNotRejectADeleteOfAnother() async {
            let featureGate = SpacesMobileAsyncGate()
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let refreshedOverview = makeOverview(featureIsRunning: false)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                guard case .archiveWorkspace(let payload) = request.command else {
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(refreshedOverview))
                }
                if payload.workspaceID == "workspace-feature" { await featureGate.wait() }
                return SpacesDeviceAPIResponse(
                    ok: true, message: "Deleted workspace.",
                    result: .mutation(SpacesDeviceMutationResult(overview: refreshedOverview, workspaceID: payload.workspaceID)))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            let overview = makeOverview()
            let featureWorkspace = overview.workspaces.first { $0.id == "workspace-feature" }!
            let docsWorkspace = overview.workspaces.first { $0.id == "workspace-docs" }!
            model.overview = overview

            let featureDelete = Task { await model.deleteWorkspace(featureWorkspace, deleteLocalBranch: false, deleteRemoteBranch: false) }
            while !model.isWorkspacePendingDeletion("workspace-feature") { await Task.yield() }

            // Deletes are chained now, so a call that would otherwise block until its predecessor resolves
            // has to run on its own task rather than be awaited directly here.
            let docsDelete = Task { await model.deleteWorkspace(docsWorkspace, deleteLocalBranch: false, deleteRemoteBranch: false) }
            while !model.isWorkspacePendingDeletion("workspace-docs") { await Task.yield() }

            // Neither call was refused: both rows read as deleting even though workspace-docs's request has
            // not been sent yet (it is queued behind workspace-feature's, still held open by the gate).
            XCTAssertTrue(model.isWorkspacePendingDeletion("workspace-feature"))
            XCTAssertTrue(model.isWorkspacePendingDeletion("workspace-docs"))

            await featureGate.open()
            await featureDelete.value
            await docsDelete.value

            // workspace-docs's delete reached the daemon and completed on its own once the queue got to
            // it, proving it was queued rather than dropped.
            let requests = await recorder.snapshot()
            XCTAssertEqual(requests.map(\.commandName), ["archiveWorkspace", "archiveWorkspace"])
            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-feature"))
            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-docs"))
        }

        /// The daemon runs every `archiveWorkspace`/`deleteProject` request off one serial per-daemon
        /// queue and only marks a workspace as tearing down once that request is dequeued. Two requests
        /// issued back to back from this client could therefore both sit on that queue at once; if the
        /// first is still occupying it past this client's 30s request timeout, the second — still queued,
        /// still unregistered — would time out too and reconcile to a false failure, even though the
        /// daemon goes on to delete it anyway (review round 2, finding 1). `pendingDeleteChains` closes the
        /// window by construction: this proves this client never has two `archiveWorkspace` requests on
        /// the same daemon's wire at once, regardless of which workspaces they target. Both deletes here
        /// target the same device (no identity change), so they share one chain key; see
        /// `testDeleteAgainstADifferentDeviceDoesNotWaitBehindAPriorDevicesDelete` for proof that a
        /// *different* device's delete gets its own key and is not serialized against this one.
        func testConcurrentDeletesMarkBothWorkspacesButSerializeTheirRequests() async {
            let gate = SpacesMobileAsyncGate()
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let refreshedOverview = makeOverview(featureIsRunning: false)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                guard case .archiveWorkspace(let payload) = request.command else {
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(refreshedOverview))
                }
                // Blocks every archiveWorkspace request, regardless of which workspace it targets, so the
                // recorder can prove the second is never even sent while the first is unresolved.
                await gate.wait()
                return SpacesDeviceAPIResponse(
                    ok: true, message: "Deleted workspace.",
                    result: .mutation(SpacesDeviceMutationResult(overview: refreshedOverview, workspaceID: payload.workspaceID)))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            let overview = makeOverview()
            let featureWorkspace = overview.workspaces.first { $0.id == "workspace-feature" }!
            let docsWorkspace = overview.workspaces.first { $0.id == "workspace-docs" }!
            model.overview = overview

            let featureDelete = Task { await model.deleteWorkspace(featureWorkspace, deleteLocalBranch: false, deleteRemoteBranch: false) }
            while !model.isWorkspacePendingDeletion("workspace-feature") { await Task.yield() }
            // The mark is set synchronously, before the chained task that actually sends the request even
            // starts running, so waiting for it is not enough to prove the request reached the daemon.
            // Wait for the recorder to see it directly.
            while await recorder.snapshot().isEmpty { await Task.yield() }

            let docsDelete = Task { await model.deleteWorkspace(docsWorkspace, deleteLocalBranch: false, deleteRemoteBranch: false) }
            while !model.isWorkspacePendingDeletion("workspace-docs") { await Task.yield() }

            // workspace-docs's request cannot appear here no matter how long this waits: `pendingDeleteChains`
            // makes it wait on workspace-feature's whole call (same device, same chain key), which is
            // parked on the still-closed gate.
            var requests = await recorder.snapshot()
            XCTAssertEqual(
                requests.map(\.commandName), ["archiveWorkspace"], "the second delete's request must not be sent while the first is still unresolved")

            await gate.open()
            await featureDelete.value
            await docsDelete.value

            requests = await recorder.snapshot()
            XCTAssertEqual(requests.map(\.commandName), ["archiveWorkspace", "archiveWorkspace"])
            guard case .archiveWorkspace(let firstPayload)? = requests.first?.command,
                case .archiveWorkspace(let secondPayload)? = requests.last?.command
            else {
                XCTFail("Expected two archiveWorkspace requests.")
                return
            }
            XCTAssertEqual(firstPayload.workspaceID, "workspace-feature", "the first request sent must be whichever delete was issued first")
            XCTAssertEqual(secondPayload.workspaceID, "workspace-docs")
            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-feature"))
            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-docs"))
        }

        /// `pendingDeleteChains` keys its tail by `overviewIdentity`, not one shared tail, because two
        /// different devices have two independent daemon teardown queues: a delete against device B has
        /// no business waiting out a delete against device A (review round 3, finding 1). There is no
        /// second real paired device/backend in this harness, so this reuses the same seam the earlier
        /// device-switch delete tests already rely on (`handleAuthenticationFailure`, which bumps
        /// `overviewIdentity` exactly as a real device switch does) rather than standing up a second
        /// `SpacesDeviceAPIClient`; that is enough to exercise the keying itself, since the chain keys on
        /// the identity value alone.
        func testDeleteAgainstADifferentDeviceDoesNotWaitBehindAPriorDevicesDelete() async {
            let featureGate = SpacesMobileAsyncGate()
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let refreshedOverview = makeOverview(featureIsRunning: false)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                guard case .archiveWorkspace(let payload) = request.command else {
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(refreshedOverview))
                }
                if payload.workspaceID == "workspace-feature" { await featureGate.wait() }
                return SpacesDeviceAPIResponse(
                    ok: true, message: "Deleted workspace.",
                    result: .mutation(SpacesDeviceMutationResult(overview: refreshedOverview, workspaceID: payload.workspaceID)))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            let overview = makeOverview()
            let featureWorkspace = overview.workspaces.first { $0.id == "workspace-feature" }!
            let docsWorkspace = overview.workspaces.first { $0.id == "workspace-docs" }!
            model.overview = overview

            let featureDelete = Task { await model.deleteWorkspace(featureWorkspace, deleteLocalBranch: false, deleteRemoteBranch: false) }
            while !model.isWorkspacePendingDeletion("workspace-feature") { await Task.yield() }
            // Confirms workspace-feature's request is actually parked on the gate (its chain entry is a
            // still-unresolved task) before switching, so the test proves independence rather than luck.
            while await recorder.snapshot().isEmpty { await Task.yield() }

            // Stands in for switching to a different paired device: bumps `overviewIdentity`, the value
            // `pendingDeleteChains` keys on, the same way `SpacesMobileAppModel.selectDevice` does.
            model.handleAuthenticationFailure(message: "Switched devices.")

            let docsDelete = Task { await model.deleteWorkspace(docsWorkspace, deleteLocalBranch: false, deleteRemoteBranch: false) }
            while !model.isWorkspacePendingDeletion("workspace-docs") { await Task.yield() }

            // workspace-docs's request reaches the daemon without waiting for workspace-feature's gate to
            // open: different `overviewIdentity` at call time means a different chain entry.
            while await recorder.snapshot().count < 2 { await Task.yield() }
            let requests = await recorder.snapshot()
            XCTAssertEqual(requests.map(\.commandName), ["archiveWorkspace", "archiveWorkspace"])
            XCTAssertTrue(model.isWorkspacePendingDeletion("workspace-feature"), "still unresolved, untouched by the device switch")

            await featureGate.open()
            await featureDelete.value
            await docsDelete.value
        }

        /// A delete still waiting in the per-daemon queue when the active device switches is cancelled,
        /// not carried out in the background against the device the app no longer shows (#450 review
        /// round 4, finding 1): `performDeleteWorkspace`'s identity guard clears the pending mark and now
        /// also surfaces `errorMessage` naming the workspace, since a confirmed destructive action the
        /// user asked for must not go silently unperformed. Driven with the same
        /// `handleAuthenticationFailure` identity-bump seam as the other device-switch tests: the switch
        /// has to land while workspace-docs's delete is still queued behind workspace-feature's (both
        /// issued against the same, still-current device), not after, or `pendingDeleteChains` would key
        /// workspace-docs's delete under the new identity instead and it would never reach this guard at
        /// all — see `testDeleteAgainstADifferentDeviceDoesNotWaitBehindAPriorDevicesDelete`.
        func testQueuedDeleteCancelledByADeviceSwitchSurfacesAnErrorAndClearsItsMark() async {
            let featureGate = SpacesMobileAsyncGate()
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let refreshedOverview = makeOverview(featureIsRunning: false)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                guard case .archiveWorkspace(let payload) = request.command else {
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(refreshedOverview))
                }
                if payload.workspaceID == "workspace-feature" { await featureGate.wait() }
                return SpacesDeviceAPIResponse(
                    ok: true, message: "Deleted workspace.",
                    result: .mutation(SpacesDeviceMutationResult(overview: refreshedOverview, workspaceID: payload.workspaceID)))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            let overview = makeOverview()
            let featureWorkspace = overview.workspaces.first { $0.id == "workspace-feature" }!
            let docsWorkspace = overview.workspaces.first { $0.id == "workspace-docs" }!
            model.overview = overview

            let featureDelete = Task { await model.deleteWorkspace(featureWorkspace, deleteLocalBranch: false, deleteRemoteBranch: false) }
            while !model.isWorkspacePendingDeletion("workspace-feature") { await Task.yield() }
            while await recorder.snapshot().isEmpty { await Task.yield() }

            // Queued behind workspace-feature's still-unresolved delete, on the same (still-current)
            // device, so it shares its chain key and has to wait its turn.
            let docsDelete = Task { await model.deleteWorkspace(docsWorkspace, deleteLocalBranch: false, deleteRemoteBranch: false) }
            while !model.isWorkspacePendingDeletion("workspace-docs") { await Task.yield() }
            XCTAssertNil(model.errorMessage, "not surfaced yet: workspace-docs's delete has not reached its guard")

            // The active device changes while workspace-docs's delete is still parked in the queue.
            model.handleAuthenticationFailure(message: "Switched devices.")

            // Releases workspace-feature's delete; workspace-docs's turn comes right after and finds the
            // identity it queued under no longer current.
            await featureGate.open()
            await featureDelete.value
            await docsDelete.value

            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-docs"), "cancelled, not left marked forever")
            XCTAssertEqual(
                model.errorMessage,
                "\"docs\" wasn't deleted: the active device changed before its delete could be sent. Delete it again from that device.")
            // Only one archiveWorkspace request was ever sent: workspace-docs's delete was cancelled
            // before it reached the network, not executed against the device it queued against.
            let requests = await recorder.snapshot()
            XCTAssertEqual(requests.map(\.commandName), ["archiveWorkspace"])
        }

        /// A delete the daemon refused leaves the workspace where it was, so the mark is lifted and its
        /// band goes back to normal beside the error.
        func testFailedDeleteClearsThePendingDeletionMark() async {
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                // The daemon codes every failure it reports; a refusal is what this models.
                SpacesDeviceAPIResponse(ok: false, message: "Default workspace cannot be deleted.", errorCode: .invalidArgument)
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.overview = makeOverview()

            await model.deleteWorkspace(makeOverview().workspaces[0], deleteLocalBranch: false, deleteRemoteBranch: false)

            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-feature"))
            XCTAssertNotNil(model.errorMessage)
            XCTAssertTrue(model.workspaceGroups.contains { $0.workspace.id == "workspace-feature" })
        }

        /// A timeout on `archiveWorkspace` does not mean the daemon rejected the delete -- it can still be
        /// tearing the workspace down on its own queue past the request's own timeout. When the very next
        /// reconciliation overview no longer lists the workspace, the delete is treated as complete: no
        /// error, the fresh overview is published, and the pending-deletion mark lifts silently.
        func testDeleteWorkspaceTimeoutReconcilesToSuccessWhenWorkspaceIsGone() async {
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let baseOverview = makeOverview()
            let overviewWithoutFeature = SpacesDeviceOverviewPayload(
                projects: baseOverview.projects, workspaces: baseOverview.workspaces.filter { $0.id != "workspace-feature" },
                sessions: baseOverview.sessions, daemonStatus: baseOverview.daemonStatus)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                if request.commandName == "archiveWorkspace" { throw SpacesDeviceAPIClientError.requestTimedOut }
                return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overviewWithoutFeature))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.overview = baseOverview

            await model.deleteWorkspace(baseOverview.workspaces[0], deleteLocalBranch: false, deleteRemoteBranch: false)

            let requests = await recorder.snapshot()
            XCTAssertEqual(
                requests.map(\.commandName), ["archiveWorkspace", "overview"],
                "reconciliation must stop as soon as the first refetch shows the workspace gone")
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(model.overview, overviewWithoutFeature)
            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-feature"))
            XCTAssertNil(model.deletedWorkspaceNotice, "no branch deletion was requested, so a reconciled delete stays silent")
        }

        /// Before #450 review round 5, `reconcileWorkspaceDeletionOutcome` captured its staleness snapshot
        /// after `fetchOverview` returned rather than before it was even sent, so a concurrent mutation
        /// that landed and published while this fetch was still in flight bumped `mutationGeneration`
        /// before the capture ever ran; the capture then trivially matched the already-bumped value and
        /// this now-stale fetch overwrote the fresher published overview. Gating reconciliation's own
        /// overview fetch and letting an unrelated mutation land and publish while it is still gated
        /// reproduces that ordering directly.
        func testReconciliationDoesNotOverwriteAFresherConcurrentMutationLandedDuringItsFetch() async {
            let overviewGate = SpacesMobileAsyncGate()
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let baseOverview = makeOverview()
            let overviewWithoutFeature = SpacesDeviceOverviewPayload(
                projects: baseOverview.projects, workspaces: baseOverview.workspaces.filter { $0.id != "workspace-feature" },
                sessions: baseOverview.sessions, daemonStatus: baseOverview.daemonStatus)
            // Distinct from both `baseOverview` (feature running) and `overviewWithoutFeature` (feature
            // absent), so the assertions below can tell which one ended up published.
            let concurrentMutationOverview = makeOverview(featureIsRunning: false)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                switch request.commandName {
                case "archiveWorkspace": throw SpacesDeviceAPIClientError.requestTimedOut
                case "overview":
                    await overviewGate.wait()
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overviewWithoutFeature))
                default:
                    return SpacesDeviceAPIResponse(
                        ok: true, message: "ok",
                        result: .mutation(SpacesDeviceMutationResult(overview: concurrentMutationOverview, workspaceID: "workspace-docs")))
                }
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.overview = baseOverview
            let docsWorkspace = baseOverview.workspaces.first { $0.id == "workspace-docs" }!

            let delete = Task { await model.deleteWorkspace(baseOverview.workspaces[0], deleteLocalBranch: false, deleteRemoteBranch: false) }
            // Waits for reconciliation's own overview fetch to actually be sent and gated, not merely for
            // the archiveWorkspace timeout: the mark alone does not prove the request reached the daemon.
            while (await recorder.snapshot()).map(\.commandName) != ["archiveWorkspace", "overview"] { await Task.yield() }

            // An unrelated mutation against a different workspace lands and publishes while reconciliation's
            // own fetch is still gated.
            await model.stopWorkspace(docsWorkspace)
            XCTAssertEqual(
                model.overview, concurrentMutationOverview, "the concurrent mutation's fresher overview must be showing before the gate opens")

            await overviewGate.open()
            await delete.value

            // The gated fetch resumes carrying pre-mutation data; it must not overwrite the fresher
            // overview the concurrent mutation already published.
            XCTAssertEqual(model.overview, concurrentMutationOverview)
        }

        /// The branch-deletion report exists only in the archive response, so when that response is lost
        /// and reconciliation proves only that the workspace is gone, a delete that asked for branch
        /// deletion says the result is unknown instead of silently succeeding.
        func testDeleteWorkspaceTimeoutReconciliationReportsUnknownBranchOutcome() async {
            let settings = SpacesMobileConnectionSettings()
            let baseOverview = makeOverview()
            let overviewWithoutFeature = SpacesDeviceOverviewPayload(
                projects: baseOverview.projects, workspaces: baseOverview.workspaces.filter { $0.id != "workspace-feature" },
                sessions: baseOverview.sessions, daemonStatus: baseOverview.daemonStatus)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                if request.commandName == "archiveWorkspace" { throw SpacesDeviceAPIClientError.requestTimedOut }
                return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overviewWithoutFeature))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.overview = baseOverview

            await model.deleteWorkspace(baseOverview.workspaces[0], deleteLocalBranch: true, deleteRemoteBranch: false)

            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-feature"))
            XCTAssertNotNil(model.deletedWorkspaceNotice, "a lost branch-deletion result must be reported, not silently dropped")
            XCTAssertTrue(model.deletedWorkspaceNotice?.contains("branch") == true)
        }

        /// An overview poll is a snapshot of the moment its fetch was issued. One that started before a
        /// mutation and lands after it still carries the pre-mutation world, so publishing it would put the
        /// deleted workspace back on screen as an ordinary actionable row until the next poll. It is
        /// discarded instead — the same rule `overviewIdentity` applies to a connection change.
        func testOverviewPollBegunBeforeAMutationIsDiscardedWhenItLandsAfterIt() async {
            let pollGate = SpacesMobileAsyncGate()
            let settings = SpacesMobileConnectionSettings()
            let staleOverview = makeOverview()
            let postDeleteOverview = SpacesDeviceOverviewPayload(
                projects: staleOverview.projects, workspaces: staleOverview.workspaces.filter { $0.id != "workspace-feature" },
                sessions: staleOverview.sessions, daemonStatus: staleOverview.daemonStatus)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                if request.commandName == "overview" {
                    // The poll's fetch is parked until the delete below has been applied.
                    await pollGate.wait()
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(staleOverview))
                }
                return SpacesDeviceAPIResponse(
                    ok: true, message: "Deleted workspace.",
                    result: .mutation(SpacesDeviceMutationResult(overview: postDeleteOverview, workspaceID: "workspace-feature")))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.overview = staleOverview

            let poll = Task { await model.refresh() }
            while !model.isLoading { await Task.yield() }

            await model.deleteWorkspace(staleOverview.workspaces[0], deleteLocalBranch: false, deleteRemoteBranch: false)
            XCTAssertEqual(model.overview, postDeleteOverview, "the delete publishes the post-delete overview")

            await pollGate.open()
            await poll.value

            XCTAssertEqual(model.overview, postDeleteOverview, "the stale poll must not republish the deleted workspace")
            XCTAssertFalse(model.workspaceGroups.contains { $0.workspace.id == "workspace-feature" })
        }

        /// The other half of the rule: a poll whose fetch begins after the mutation carries current state
        /// and publishes normally.
        func testOverviewPollBegunAfterAMutationPublishesNormally() async {
            let settings = SpacesMobileConnectionSettings()
            let baseOverview = makeOverview()
            let postDeleteOverview = SpacesDeviceOverviewPayload(
                projects: baseOverview.projects, workspaces: baseOverview.workspaces.filter { $0.id != "workspace-feature" },
                sessions: baseOverview.sessions, daemonStatus: baseOverview.daemonStatus)
            let laterOverview = SpacesDeviceOverviewPayload(
                projects: postDeleteOverview.projects, workspaces: postDeleteOverview.workspaces, sessions: [],
                daemonStatus: postDeleteOverview.daemonStatus)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                if request.commandName == "overview" { return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(laterOverview)) }
                return SpacesDeviceAPIResponse(
                    ok: true, message: "Deleted workspace.",
                    result: .mutation(SpacesDeviceMutationResult(overview: postDeleteOverview, workspaceID: "workspace-feature")))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.overview = baseOverview

            await model.deleteWorkspace(baseOverview.workspaces[0], deleteLocalBranch: false, deleteRemoteBranch: false)
            await model.refresh()

            XCTAssertEqual(model.overview, laterOverview, "a poll issued after the mutation is current and publishes")
        }

        /// The point of reconciling rather than reporting failure: the row stays marked for deletion for
        /// the whole reconciliation, so a workspace the daemon is still tearing down never goes back to
        /// looking normal — and offering Delete again — while it is doomed.
        func testDeleteWorkspaceTimeoutKeepsThePendingMarkWhileReconciling() async {
            let gate = SpacesMobileAsyncGate()
            let settings = SpacesMobileConnectionSettings()
            let baseOverview = makeOverview()
            let overviewWithoutFeature = SpacesDeviceOverviewPayload(
                projects: baseOverview.projects, workspaces: baseOverview.workspaces.filter { $0.id != "workspace-feature" },
                sessions: baseOverview.sessions, daemonStatus: baseOverview.daemonStatus)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                if request.commandName == "archiveWorkspace" { throw SpacesDeviceAPIClientError.requestTimedOut }
                await gate.wait()
                return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overviewWithoutFeature))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.overview = baseOverview

            let delete = Task { await model.deleteWorkspace(baseOverview.workspaces[0], deleteLocalBranch: false, deleteRemoteBranch: false) }
            while !model.isWorkspacePendingDeletion("workspace-feature") { await Task.yield() }
            // The archive has already failed with a timeout and the reconciliation refetch is parked here.
            XCTAssertTrue(model.isWorkspacePendingDeletion("workspace-feature"), "the timed-out delete keeps its mark while it reconciles")

            await gate.open()
            await delete.value

            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-feature"))
            XCTAssertNil(model.errorMessage)
        }

        /// If the workspace is still listed in every reconciliation overview once the retry budget runs
        /// out, the timeout is a genuine failure: the error surfaces and the pending-deletion mark lifts so
        /// the row looks normal -- and deletable again -- beside it.
        func testDeleteWorkspaceTimeoutSurfacesErrorWhenWorkspaceStillPresent() async {
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let overview = makeOverview()
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                if request.commandName == "archiveWorkspace" { throw SpacesDeviceAPIClientError.requestTimedOut }
                return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
            }
            // Zero interval so the loop runs its whole budget without sleeping through the production wait.
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client, workspaceDeletionReconciliationInterval: .zero)
            model.overview = overview

            await model.deleteWorkspace(overview.workspaces[0], deleteLocalBranch: false, deleteRemoteBranch: false)

            XCTAssertNotNil(model.errorMessage)
            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-feature"))
            let requests = await recorder.snapshot()
            XCTAssertEqual(
                requests.map(\.commandName), ["archiveWorkspace", "overview", "overview", "overview", "overview", "overview"],
                "reconciliation must give up after its fixed attempt budget")
        }

        /// A definitive rejection — the daemon answered and said no, which its error code is the proof of —
        /// needs no reconciliation: the mark lifts immediately and the error surfaces exactly like any
        /// other failed mutation.
        func testDeleteWorkspaceDefinitiveRejectionSkipsReconciliation() async {
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                return SpacesDeviceAPIResponse(ok: false, message: "Default workspace cannot be deleted.", errorCode: .invalidArgument)
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.overview = makeOverview()

            await model.deleteWorkspace(makeOverview().workspaces[0], deleteLocalBranch: false, deleteRemoteBranch: false)

            XCTAssertNotNil(model.errorMessage)
            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-feature"))
            let requests = await recorder.snapshot()
            XCTAssertEqual(requests.map(\.commandName), ["archiveWorkspace"], "a definitive rejection must not trigger reconciliation")
        }

        /// The app being backgrounded closes the transport's socket, which surfaces as a plain
        /// `requestFailed` carrying no daemon error code. That is not a verdict — the daemon may have
        /// received the delete and be finishing it — so it reconciles exactly like a timeout and resolves
        /// silently once the workspace stops being listed.
        func testDeleteWorkspacePostSendTransportFailureReconcilesToSuccessWhenWorkspaceIsGone() async {
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let baseOverview = makeOverview()
            let overviewWithoutFeature = SpacesDeviceOverviewPayload(
                projects: baseOverview.projects, workspaces: baseOverview.workspaces.filter { $0.id != "workspace-feature" },
                sessions: baseOverview.sessions, daemonStatus: baseOverview.daemonStatus)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                if request.commandName == "archiveWorkspace" {
                    throw SpacesDeviceAPIClientError.requestFailed("The Device API connection was cancelled.")
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overviewWithoutFeature))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client, workspaceDeletionReconciliationInterval: .zero)
            model.overview = baseOverview

            await model.deleteWorkspace(baseOverview.workspaces[0], deleteLocalBranch: false, deleteRemoteBranch: false)

            XCTAssertNil(model.errorMessage, "a delete the daemon finished must not report the dropped connection as a failure")
            XCTAssertEqual(model.overview, overviewWithoutFeature)
            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-feature"))
            let requests = await recorder.snapshot()
            XCTAssertEqual(requests.map(\.commandName), ["archiveWorkspace", "overview"])
        }

        /// The daemon answers with a coded `internalError` both for a failure part-way through the delete
        /// and for a delete that SUCCEEDED and then failed while building the refreshed overview it answers
        /// with. Only codes that are verdicts on the request are definitive, so this reconciles — and when
        /// the workspace turns out to be gone, the user is told nothing failed.
        func testDeleteWorkspaceCodedInternalErrorReconcilesToSuccessWhenWorkspaceIsGone() async {
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let baseOverview = makeOverview()
            let overviewWithoutFeature = SpacesDeviceOverviewPayload(
                projects: baseOverview.projects, workspaces: baseOverview.workspaces.filter { $0.id != "workspace-feature" },
                sessions: baseOverview.sessions, daemonStatus: baseOverview.daemonStatus)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                if request.commandName == "archiveWorkspace" {
                    return SpacesDeviceAPIResponse(ok: false, message: "Failed to build overview.", errorCode: .internalError)
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overviewWithoutFeature))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client, workspaceDeletionReconciliationInterval: .zero)
            model.overview = baseOverview

            await model.deleteWorkspace(baseOverview.workspaces[0], deleteLocalBranch: false, deleteRemoteBranch: false)

            XCTAssertNil(model.errorMessage, "a delete the daemon completed must not be reported as failed")
            XCTAssertEqual(model.overview, overviewWithoutFeature)
            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-feature"))
            let requests = await recorder.snapshot()
            XCTAssertEqual(requests.map(\.commandName), ["archiveWorkspace", "overview"])
        }

        /// The archive's response was lost AND every reconciliation refetch failed too — the device went
        /// unreachable exactly while the delete was in flight. Nothing has been observed, so reporting the
        /// delete as failed would be a verdict the client never reached. The marking stays and the error
        /// is held back until an overview can answer.
        func testDeleteWorkspaceWithNoReachableOverviewKeepsTheMarkAndHoldsTheError() async {
            let settings = SpacesMobileConnectionSettings()
            let overview = makeOverview()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                throw SpacesDeviceAPIClientError.requestFailed("The Device API connection was cancelled.")
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client, workspaceDeletionReconciliationInterval: .zero)
            model.overview = overview

            await model.deleteWorkspace(overview.workspaces[0], deleteLocalBranch: false, deleteRemoteBranch: false)

            XCTAssertTrue(model.isWorkspacePendingDeletion("workspace-feature"), "an unconfirmed delete keeps its row inert")
            XCTAssertNil(model.errorMessage, "no verdict was reached, so nothing is reported yet")
            XCTAssertFalse(model.isMutating, "only the row is inert — the model is not stuck mid-mutation")
        }

        /// While a delete's outcome is unresolved the mark is on but `isMutating` is false, so `isMutating`
        /// alone no longer keeps the row inert. A second delete of the same workspace must be refused at
        /// the model, not only suppressed in the view: the workspace is already on its way out, and the
        /// daemon may well have finished removing it.
        func testASecondDeleteOfAWorkspaceAlreadyPendingDeletionIsRefused() async {
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let overview = makeOverview()
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                throw SpacesDeviceAPIClientError.requestFailed("The Device API connection was cancelled.")
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client, workspaceDeletionReconciliationInterval: .zero)
            model.overview = overview

            await model.deleteWorkspace(overview.workspaces[0], deleteLocalBranch: false, deleteRemoteBranch: false)
            XCTAssertTrue(model.isWorkspacePendingDeletion("workspace-feature"))
            XCTAssertFalse(model.isMutating, "the mutation is over — only the mark keeps the row inert")
            let requestsAfterFirstDelete = await recorder.snapshot()

            await model.deleteWorkspace(overview.workspaces[0], deleteLocalBranch: false, deleteRemoteBranch: false)

            let requestsAfterSecondDelete = await recorder.snapshot()
            XCTAssertEqual(requestsAfterSecondDelete.count, requestsAfterFirstDelete.count, "the second delete must issue nothing")
            XCTAssertTrue(model.isWorkspacePendingDeletion("workspace-feature"), "and must not disturb the unresolved first delete")
        }

        /// The same rule for Hide: a workspace whose delete is unresolved is leaving, so hiding it would
        /// act on a row that is already going.
        func testHidingAWorkspaceAlreadyPendingDeletionIsRefused() async {
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let overview = makeOverview()
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                throw SpacesDeviceAPIClientError.requestFailed("The Device API connection was cancelled.")
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client, workspaceDeletionReconciliationInterval: .zero)
            model.overview = overview

            await model.deleteWorkspace(overview.workspaces[0], deleteLocalBranch: false, deleteRemoteBranch: false)
            let requestsAfterDelete = await recorder.snapshot()

            await model.hideWorkspace(overview.workspaces[0])

            let requestsAfterHide = await recorder.snapshot()
            XCTAssertEqual(requestsAfterHide.count, requestsAfterDelete.count, "the hide must issue nothing")
            XCTAssertTrue(model.isWorkspacePendingDeletion("workspace-feature"))
        }

        /// The deferred delete is settled by the next overview that publishes: the workspace is gone, so it
        /// landed. The marking clears silently, and because branch deletion had been requested the user is
        /// told the branch outcome is unknown.
        func testDeferredDeleteResolvesSilentlyWhenALaterOverviewNoLongerListsTheWorkspace() async {
            let settings = SpacesMobileConnectionSettings()
            let overview = makeOverview()
            let overviewWithoutFeature = SpacesDeviceOverviewPayload(
                projects: overview.projects, workspaces: overview.workspaces.filter { $0.id != "workspace-feature" }, sessions: overview.sessions,
                daemonStatus: overview.daemonStatus)
            let counter = SpacesMobilePollCounter()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                // Every request during the delete fails; the poll that follows it succeeds.
                guard await counter.increment() > SpacesMobileAppModel.workspaceDeletionReconciliationAttempts + 1 else {
                    throw SpacesDeviceAPIClientError.requestFailed("The Device API connection was cancelled.")
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overviewWithoutFeature))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client, workspaceDeletionReconciliationInterval: .zero)
            model.overview = overview

            await model.deleteWorkspace(overview.workspaces[0], deleteLocalBranch: true, deleteRemoteBranch: false)
            XCTAssertTrue(model.isWorkspacePendingDeletion("workspace-feature"))

            await model.refresh()

            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-feature"), "the overview settled it: the delete landed")
            XCTAssertNil(model.errorMessage)
            XCTAssertEqual(model.deletedWorkspaceNotice, SpacesMobileAppModel.unknownBranchOutcomeNotice)
        }

        /// The other side: the next overview still lists the workspace, so the delete really did fail and
        /// the error the client held back is surfaced then, against a row the user can act on again.
        func testDeferredDeleteSurfacesTheHeldErrorWhenALaterOverviewStillListsTheWorkspace() async {
            let settings = SpacesMobileConnectionSettings()
            let overview = makeOverview()
            let counter = SpacesMobilePollCounter()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                guard await counter.increment() > SpacesMobileAppModel.workspaceDeletionReconciliationAttempts + 1 else {
                    throw SpacesDeviceAPIClientError.requestFailed("The Device API connection was cancelled.")
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client, workspaceDeletionReconciliationInterval: .zero)
            model.overview = overview

            await model.deleteWorkspace(overview.workspaces[0], deleteLocalBranch: false, deleteRemoteBranch: false)
            XCTAssertTrue(model.isWorkspacePendingDeletion("workspace-feature"))

            await model.refresh()

            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-feature"))
            XCTAssertNotNil(model.errorMessage, "the workspace is still there, so the delete failed after all")
        }

        /// An unconfirmed delete belongs to the connection it was issued against: another device's overview
        /// cannot answer it. Switching devices drops the marking and the held error without reporting a
        /// verdict nobody can reach.
        func testDeviceSwitchDuringADeferredDeleteClearsItWithoutSurfacingAnError() async {
            let settings = SpacesMobileConnectionSettings()
            let overview = makeOverview()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                throw SpacesDeviceAPIClientError.requestFailed("The Device API connection was cancelled.")
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client, workspaceDeletionReconciliationInterval: .zero)
            model.overview = overview

            await model.deleteWorkspace(overview.workspaces[0], deleteLocalBranch: false, deleteRemoteBranch: false)
            XCTAssertTrue(model.isWorkspacePendingDeletion("workspace-feature"))

            // A real connection change: `applyConnectionSettings` is one of the chokepoints — with
            // `selectDevice`, `removeDevice`, and the Demo Mode toggles — that reload per-connection state.
            model.applyConnectionSettings(SpacesMobileConnectionSettings())

            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-feature"))
            XCTAssertNil(model.errorMessage)
        }

        /// The other half of the same rule: a codeless failure whose workspace is still listed once the
        /// budget is spent — including a failure that never reached the daemon — reports the error and
        /// puts the row back.
        func testDeleteWorkspacePostSendTransportFailureSurfacesErrorWhenWorkspaceStillPresent() async {
            let settings = SpacesMobileConnectionSettings()
            let overview = makeOverview()
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                if request.commandName == "archiveWorkspace" {
                    throw SpacesDeviceAPIClientError.requestFailed("The Device API connection was cancelled.")
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client, workspaceDeletionReconciliationInterval: .zero)
            model.overview = overview

            await model.deleteWorkspace(overview.workspaces[0], deleteLocalBranch: false, deleteRemoteBranch: false)

            XCTAssertNotNil(model.errorMessage)
            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-feature"))
        }

        /// A workspace still listed after a timed-out delete is not automatically a failed delete: the
        /// daemon reports which workspaces are still on its teardown queue via
        /// `workspaceIDsWithTeardownInFlight`, and while this workspace's id is in that set every attempt,
        /// its continued presence only means the daemon has not finished landing the delete yet.
        /// Reconciliation must spend its whole budget without ever counting the workspace as `.present`,
        /// landing on `.unknown` — the mark stays and no error is surfaced.
        func testDeleteWorkspaceTimeoutKeepsThePendingMarkAndSurfacesNoErrorWhileTeardownStaysInFlight() async {
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let overview = makeOverview()
            let overviewWithTeardownInFlight = SpacesDeviceOverviewPayload(
                projects: overview.projects, workspaces: overview.workspaces, sessions: overview.sessions,
                workspaceIDsWithTeardownInFlight: ["workspace-feature"], daemonStatus: overview.daemonStatus)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                if request.commandName == "archiveWorkspace" { throw SpacesDeviceAPIClientError.requestTimedOut }
                return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overviewWithTeardownInFlight))
            }
            // Zero interval so the loop runs its whole budget without sleeping through the production wait.
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client, workspaceDeletionReconciliationInterval: .zero)
            model.overview = overview

            await model.deleteWorkspace(overview.workspaces[0], deleteLocalBranch: false, deleteRemoteBranch: false)

            XCTAssertTrue(model.isWorkspacePendingDeletion("workspace-feature"), "the delete is still running behind the daemon's teardown queue")
            XCTAssertNil(model.errorMessage, "still being listed while its own teardown is in flight is not evidence the delete failed")
            XCTAssertFalse(model.isMutating, "only the row stays inert while it awaits a later overview, not the whole model")
            let requests = await recorder.snapshot()
            XCTAssertEqual(
                requests.map(\.commandName), ["archiveWorkspace", "overview", "overview", "overview", "overview", "overview"],
                "reconciliation must spend its whole budget when every refetch reports the teardown still in flight")
        }

        /// The other half of the same rule: the workspace being listed while some OTHER workspace's
        /// teardown is in flight is no excuse — this workspace's own delete really did fail, so
        /// reconciliation must still report it once the budget runs out.
        func testDeleteWorkspaceTimeoutSurfacesErrorWhenWorkspaceStillPresentAndItsOwnTeardownIsNotInFlight() async {
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let overview = makeOverview()
            let overviewWithUnrelatedTeardown = SpacesDeviceOverviewPayload(
                projects: overview.projects, workspaces: overview.workspaces, sessions: overview.sessions,
                workspaceIDsWithTeardownInFlight: ["workspace-docs"], daemonStatus: overview.daemonStatus)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                if request.commandName == "archiveWorkspace" { throw SpacesDeviceAPIClientError.requestTimedOut }
                return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overviewWithUnrelatedTeardown))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client, workspaceDeletionReconciliationInterval: .zero)
            model.overview = overview

            await model.deleteWorkspace(overview.workspaces[0], deleteLocalBranch: false, deleteRemoteBranch: false)

            XCTAssertNotNil(model.errorMessage, "the workspace is listed and its own teardown is not in flight, so the delete genuinely failed")
            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-feature"))
            let requests = await recorder.snapshot()
            XCTAssertEqual(requests.map(\.commandName), ["archiveWorkspace", "overview", "overview", "overview", "overview", "overview"])
        }

        /// A deferred delete (see `testDeleteWorkspaceWithNoReachableOverviewKeepsTheMarkAndHoldsTheError`)
        /// must not settle against an overview that lists the workspace with its teardown reported in
        /// flight — that overview is not a verdict, only a progress report. Once a later overview lists it
        /// with no teardown queued behind it, the deferral settles as a genuine failure.
        func testDeferredDeleteDoesNotSettleWhileTeardownIsInFlightAndSettlesAsFailedOnceItStops() async {
            let settings = SpacesMobileConnectionSettings()
            let overview = makeOverview()
            let overviewWithTeardownInFlight = SpacesDeviceOverviewPayload(
                projects: overview.projects, workspaces: overview.workspaces, sessions: overview.sessions,
                workspaceIDsWithTeardownInFlight: ["workspace-feature"], daemonStatus: overview.daemonStatus)
            let counter = SpacesMobilePollCounter()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                let call = await counter.increment()
                // The archive request and every reconciliation refetch fail, deferring the outcome.
                guard call > SpacesMobileAppModel.workspaceDeletionReconciliationAttempts + 1 else {
                    throw SpacesDeviceAPIClientError.requestFailed("The Device API connection was cancelled.")
                }
                // The next overview still lists the workspace but with its teardown in flight: not a
                // verdict. The one after that lists it with no teardown queued: a genuine failure.
                if call == SpacesMobileAppModel.workspaceDeletionReconciliationAttempts + 2 {
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overviewWithTeardownInFlight))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client, workspaceDeletionReconciliationInterval: .zero)
            model.overview = overview

            await model.deleteWorkspace(overview.workspaces[0], deleteLocalBranch: false, deleteRemoteBranch: false)
            XCTAssertTrue(model.isWorkspacePendingDeletion("workspace-feature"))

            await model.refresh()
            XCTAssertTrue(
                model.isWorkspacePendingDeletion("workspace-feature"),
                "still listed only because its teardown is in flight; the deferral must not settle")
            XCTAssertNil(model.errorMessage)

            await model.refresh()
            XCTAssertFalse(
                model.isWorkspacePendingDeletion("workspace-feature"), "teardown is no longer in flight and it is still listed: a genuine failure")
            XCTAssertNotNil(model.errorMessage)
        }

        /// Switching device mid-delete makes the model drop the failure (it belongs to the old connection),
        /// but the pending mark is keyed by workspace id, not by connection — leaving it set would dim that
        /// row for the rest of the run the moment the user switched back.
        func testDeleteWorkspaceLeavesNoStaleMarkWhenTheDeviceChangesMidDelete() async {
            let gate = SpacesMobileAsyncGate()
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                await gate.wait()
                throw SpacesDeviceAPIClientError.requestFailed("The Device API connection was cancelled.")
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client, workspaceDeletionReconciliationInterval: .zero)
            let workspace = makeOverview().workspaces[0]
            model.overview = makeOverview()

            let delete = Task { await model.deleteWorkspace(workspace, deleteLocalBranch: false, deleteRemoteBranch: false) }
            while !model.isWorkspacePendingDeletion("workspace-feature") { await Task.yield() }
            // A real connection change while the delete is still parked in its request: this resets the
            // connection and bumps the overview identity, exactly as a device switch does.
            model.handleAuthenticationFailure(message: "Pair this device again.")

            await gate.open()
            await delete.value

            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-feature"), "the mark must not outlive a delete abandoned by a device switch")
        }

        /// A delete does not have to have been issued here to matter: the daemon reports every teardown it
        /// is running, so a workspace deleted from the Mac (or taken by a project delete) marks its row on
        /// this device too — dimmed and inert for as long as the teardown is reported — and returns to an
        /// ordinary row the moment an overview stops reporting it.
        func testWorkspaceTornDownByAnotherClientIsMarkedFromTheOverviewAlone() {
            let model = makeModel()
            let overview = makeOverview()
            model.overview = SpacesDeviceOverviewPayload(
                projects: overview.projects, workspaces: overview.workspaces, sessions: overview.sessions,
                workspaceIDsWithTeardownInFlight: ["workspace-feature"], daemonStatus: overview.daemonStatus)

            XCTAssertTrue(model.isWorkspacePendingDeletion("workspace-feature"), "the daemon reports its teardown running, whoever started it")
            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-docs"), "only the workspace being torn down is marked")

            // The teardown finished (or failed): the workspace is listed with nothing queued behind it.
            model.overview = overview

            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-feature"), "no teardown reported and no local delete: an ordinary row")
        }

        /// A workspace's unrepresented sessions form a loose band further down the same list, so a delete
        /// running against that workspace has to mark those rows as well as its own band — they are rows
        /// of a workspace mid-teardown, and tapping one opens a terminal in a worktree being removed. The
        /// group stays listed for as long as the overview carries the workspace (sessions of a workspace
        /// already dropped form no group at all), and it reads the mark from that workspace.
        func testLooseTerminalGroupOfAWorkspaceBeingDeletedIsMarked() {
            let model = makeModel()
            let overview = makeOverview(sessions: [makeSession(id: "session-loose")])
            model.overview = SpacesDeviceOverviewPayload(
                projects: overview.projects, workspaces: overview.workspaces, sessions: overview.sessions,
                workspaceIDsWithTeardownInFlight: ["workspace-feature"], daemonStatus: overview.daemonStatus)

            let looseGroup = model.terminalGroups.first { $0.workspaceID == "workspace-feature" }

            XCTAssertNotNil(looseGroup, "the workspace is still listed, so its loose sessions still band under it")
            XCTAssertEqual(looseGroup?.sessions.map(\.id), ["session-loose"])
            XCTAssertTrue(model.isWorkspacePendingDeletion(looseGroup?.workspaceID ?? ""), "the loose band reads the same mark its workspace does")
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

        /// A shell row is named by the session and described by what its program reported — nothing until
        /// it reports something. A configured row says what it runs instead.
        func testRuntimeRowSecondaryTextIsTheShellsLiveTitle() {
            func terminalRow(liveTitle: String?) -> SpacesMobileWorkspaceRuntimeRow {
                SpacesMobileWorkspaceRuntimeRow(
                    source: .terminal(
                        SpacesDeviceWorkspaceTerminalRow(
                            id: "terminal-shell", workspaceID: "workspace-docs", title: "shell-1", workingDirectory: "/repo/docs",
                            sessionID: "session-shell", runState: .running, canOpenTerminal: true, canStop: true, liveTitle: liveTitle)))
            }

            XCTAssertEqual(terminalRow(liveTitle: nil).title, "shell-1")
            XCTAssertEqual(terminalRow(liveTitle: nil).detail, "")
            XCTAssertEqual(terminalRow(liveTitle: "vim main.swift").title, "shell-1", "what the program prints never renames the row")
            XCTAssertEqual(terminalRow(liveTitle: "vim main.swift").detail, "vim main.swift")

            let processRow = SpacesMobileWorkspaceRuntimeRow(
                source: .process(
                    SpacesDeviceWorkspaceProcessRow(
                        id: "template-api", workspaceID: "workspace-docs", name: "api", command: "npm run dev", templateID: "template-api",
                        processID: nil, sessionID: nil, runState: .notStarted, canRun: true, canStop: false, canRestart: false)))
            XCTAssertEqual(processRow.detail, "npm run dev")
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

        /// Before #450 review round 5, `reconciledSessionAfterMutationTimeout` published its refetched
        /// overview unconditionally — no generation check at all, only the identity guard. A concurrent
        /// mutation that landed and published a fresher overview while this recovery fetch was still in
        /// flight was silently overwritten by this now-stale one once it resumed. Gating the recovery
        /// fetch and letting an unrelated mutation land and publish while it is still gated reproduces
        /// that ordering directly, the same technique as
        /// `testReconciliationDoesNotOverwriteAFresherConcurrentMutationLandedDuringItsFetch`.
        func testMutationTimeoutRecoveryDoesNotOverwriteAFresherConcurrentMutationLandedDuringItsFetch() async {
            let overviewGate = SpacesMobileAsyncGate()
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let oldRow = SpacesDeviceWorkspaceProcessRow(
                id: "template-api", workspaceID: "workspace-feature", name: "api", command: "npm run dev", templateID: "template-api",
                processID: "runtime-api-old", sessionID: "session-api-old", runState: .exited, canRun: true, canStop: false, canRestart: false)
            let staleOverview = makeOverview(sessions: [makeSession(id: "session-api-stale")], featureProcessRows: [oldRow])
            // Distinct from `staleOverview`, so the assertions below can tell which one ended up published.
            let concurrentMutationOverview = makeOverview(featureIsRunning: false)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                switch request.commandName {
                case "runWorkspaceProcess": throw SpacesDeviceAPIClientError.requestTimedOut
                case "overview":
                    await overviewGate.wait()
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(staleOverview))
                default:
                    return SpacesDeviceAPIResponse(
                        ok: true, message: "ok",
                        result: .mutation(SpacesDeviceMutationResult(overview: concurrentMutationOverview, workspaceID: "workspace-docs")))
                }
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            let baseOverview = makeOverview(sessions: [makeSession(id: "session-api-old")], featureProcessRows: [oldRow])
            model.overview = baseOverview
            let docsWorkspace = baseOverview.workspaces.first { $0.id == "workspace-docs" }!

            let run = Task { await model.run(row: SpacesMobileWorkspaceRuntimeRow(source: .process(oldRow))) }
            // Waits for the recovery's own overview fetch to actually be sent and gated, not merely for
            // the runWorkspaceProcess timeout.
            while (await recorder.snapshot()).map(\.commandName) != ["runWorkspaceProcess", "overview"] { await Task.yield() }

            // An unrelated mutation against a different workspace lands and publishes while the recovery
            // fetch is still gated. Deletes, not a shared-channel action like Stop: `run` above is still
            // holding `isMutating` for its whole reconciliation, and a shared-channel mutation would be
            // silently refused by that same gate rather than actually racing this fetch.
            await model.deleteWorkspace(docsWorkspace, deleteLocalBranch: false, deleteRemoteBranch: false)
            XCTAssertEqual(
                model.overview, concurrentMutationOverview, "the concurrent mutation's fresher overview must be showing before the gate opens")

            await overviewGate.open()
            _ = await run.value

            // The gated fetch resumes carrying pre-mutation data; it must not overwrite the fresher
            // overview the concurrent mutation already published.
            XCTAssertEqual(model.overview, concurrentMutationOverview)
        }

        func testRefreshedSessionLookupIgnoresVisibleFilters() {
            let model = makeModel()
            model.overview = makeOverview(sessions: [makeSession(id: "session-api")])
            model.visibleRunStates = [.notStarted]

            XCTAssertTrue(model.workspaceGroups.flatMap(\.rows).isEmpty)
            XCTAssertEqual(model.refreshedSession(forRowID: "process:process-api")?.id, "session-api")
        }

        /// `terminalSession(for:in:)` and `refreshedSession(forRowID:in:)` are what
        /// `performMutationReturningSession` and `reconciledSessionAfterMutationTimeout` read from to
        /// answer whether their own action produced a session (#450 review round 7): both take the
        /// overview to search explicitly, defaulting to the model's published one for every other,
        /// UI-facing caller, so a caller instead holding a specific mutation response or reconciliation
        /// fetch reads that data's own verdict regardless of whether the same overview also won its
        /// publish race against a fresher, unrelated one.
        ///
        /// The genuine race this protects against has no test-reachable suspension point in this harness
        /// to reproduce deterministically: it requires another overview-derived operation to bump
        /// `mutationGeneration` between a response's own bump and its own publish check, and
        /// `updateBrowserRoutes` — the only await in between — returns before reaching any await of its
        /// own once `activeDeviceID` is nil (the same seam gap already reported for its internal
        /// generation guard in review round 5). This tests the mechanism the fix relies on directly
        /// instead: that the explicit overview wins over the published one, not that a race can be staged.
        func testTerminalSessionForRowReadsTheExplicitOverviewNotThePublishedOne() {
            let model = makeModel()
            let newRow = SpacesDeviceWorkspaceProcessRow(
                id: "template-api", workspaceID: "workspace-feature", name: "api", command: "npm run dev", templateID: "template-api",
                processID: "runtime-api-new", sessionID: "session-api-new", runState: .running, canRun: false, canStop: true, canRestart: true)
            let responseOverview = makeOverview(sessions: [makeSession(id: "session-api-new")], featureProcessRows: [newRow])
            // The model's published overview knows nothing about the new session yet — as it would not,
            // had this mutation's publish lost its ordering race against a fresher, unrelated one.
            model.overview = makeOverview()
            let row = SpacesMobileWorkspaceRuntimeRow(source: .process(newRow))

            XCTAssertNil(model.terminalSession(for: row), "the published overview has no matching session")
            XCTAssertEqual(model.terminalSession(for: row, in: responseOverview)?.id, "session-api-new")
        }

        func testRefreshedSessionForRowIDReadsTheExplicitOverviewNotThePublishedOne() {
            let model = makeModel()
            let newRow = SpacesDeviceWorkspaceProcessRow(
                id: "template-api", workspaceID: "workspace-feature", name: "api", command: "npm run dev", templateID: "template-api",
                processID: "runtime-api-new", sessionID: "session-api-new", runState: .running, canRun: false, canStop: true, canRestart: true)
            let responseOverview = makeOverview(sessions: [makeSession(id: "session-api-new")], featureProcessRows: [newRow])
            model.overview = makeOverview()

            XCTAssertNil(model.refreshedSession(forRowID: "process:template-api"), "the published overview has no matching row")
            XCTAssertEqual(model.refreshedSession(forRowID: "process:template-api", in: responseOverview)?.id, "session-api-new")
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
            let missingFields = URL(string: "spaces://pair?v=4")!

            XCTAssertEqual(SpacesIncomingLinkRoute.route(for: unsupportedVersion), .pairing(unsupportedVersion))
            XCTAssertEqual(SpacesIncomingLinkRoute.route(for: missingFields), .pairing(missingFields))
        }

        func testIncomingLinkRoutingClassifiesValidPairingURLAsPairing() {
            let link = SpacesDevicePairingLink(
                hosts: ["10.0.0.4"], port: 19000, nonce: "nonce", code: "code", certificateFingerprint: "fp", name: "Mac Studio", protocolVersion: 3,
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
                hosts: ["10.0.0.4"], port: 19000, nonce: "nonce", code: "code", certificateFingerprint: "fp", name: "Mac Studio", protocolVersion: 3,
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
            settings.hosts = ["127.0.0.1"]
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
                    id: "device-1", name: "Studio", hosts: settings.hosts, port: settings.port,
                    certificateFingerprint: settings.certificateFingerprint, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
                    lastSelectedAt: nil)
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

        /// The raw-byte service tunnel has to dial the address the command channel actually proved
        /// reachable, not a possibly-stale persisted record — see `updateBrowserRoutes`'s doc comment.
        /// The paired device record here still carries a stale LAN `activeHost`; the live client reports
        /// a different (Tailscale) resolved host, and the routing table must end up pointing at that one.
        func testMutationOverviewPrefersLiveResolvedHostOverStaleRecord() async {
            let refreshedOverview = makeOverview(
                featureAssignedPorts: [SpacesDeviceAssignedPort(name: "web", port: 3_000, url: "http://web.feature.localhost:3000")],
                featureConfig: SpacesDeviceWorkspaceConfig(resolvedBrowserSessions: [
                    SpacesDeviceBrowserSession(name: "Dashboard", url: "http://localhost:3000/dashboard")
                ]))
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["10.0.0.5", "100.64.0.5"]
            settings.port = 47_847
            settings.certificateFingerprint = "fp-1"
            let backend = SpacesMobileFakeResolvedHostBackend(resolvedHost: "100.64.0.5") { _ in
                SpacesDeviceAPIResponse(
                    ok: true, message: "Created workspace.",
                    result: .mutation(SpacesDeviceMutationResult(overview: refreshedOverview, workspaceID: "workspace-feature")))
            }
            let client = SpacesDeviceAPIClient(settings: settings, backend: backend)
            let proxy = SpacesMobileBrowserProxy(port: UInt16.random(in: 49_152...65_500), installationID: settings.installationID)
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client, browserProxy: proxy)
            model.activeDeviceID = "device-1"
            model.pairedDevices = [
                SpacesMobilePairedDeviceRecord(
                    id: "device-1", name: "Studio", hosts: settings.hosts, port: settings.port,
                    certificateFingerprint: settings.certificateFingerprint, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
                    lastSelectedAt: nil, activeHost: "10.0.0.5")
            ]

            await model.createWorkspace(
                projectID: "project-1", branch: "feature", baseBranch: "main", directoryName: nil, allowExistingBranchReuse: false)

            let target = await proxy.routeTarget(forHost: "web.feature.localhost")
            XCTAssertEqual(target?.host, "100.64.0.5")
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

        /// The "Local network"/"Tailscale" label `ConnectionSettingsView` renders reads
        /// `pairedDevices[...].activeHost`, but `recordActiveHost` (called by the resolver once it
        /// learns a new winner) writes straight to the persisted store — a separate copy from this
        /// in-memory snapshot. `performRefresh` must notice the live client's resolved host no longer
        /// matches what `pairedDevices` holds and reload from the store, or the label would keep
        /// showing the pre-failover address for the rest of the session.
        func testRefreshRepublishesPairedDevicesWhenResolvedHostDiffersFromStaleRecord() async throws {
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["10.0.0.5", "100.64.0.5"]
            settings.port = 47_847
            settings.certificateFingerprint = "SHA256:refresh-active-host-test"
            settings.authToken = "token"
            let upserted = SpacesMobileDeviceStore.upsert(settings: settings, name: "Studio")
            let deviceID = try XCTUnwrap(upserted.devices.first?.id)
            defer { _ = SpacesMobileDeviceStore.remove(deviceID: deviceID, fallbackSettings: SpacesMobileConnectionSettings()) }
            // The resolver has already persisted the failover to the tailnet address (this is what a
            // real `SpacesDeviceEndpointResolver.connect()` success does), but nothing has told this
            // model's in-memory `pairedDevices` snapshot yet — it still holds the pre-failover value.
            SpacesMobileDeviceStore.recordActiveHost("100.64.0.5", certificateFingerprint: "SHA256:refresh-active-host-test")

            let overview = makeOverview(daemonStatus: daemonStatus(protocolVersion: SpacesWireProtocol.version))
            let backend = SpacesMobileFakeResolvedHostBackend(resolvedHost: "100.64.0.5") { _ in
                SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
            }
            let client = SpacesDeviceAPIClient(settings: settings, backend: backend)
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.activeDeviceID = deviceID
            model.pairedDevices = [
                SpacesMobilePairedDeviceRecord(
                    id: deviceID, name: "Studio", hosts: settings.hosts, port: settings.port, certificateFingerprint: settings.certificateFingerprint,
                    createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", lastSelectedAt: nil, activeHost: "10.0.0.5")
            ]

            await model.refresh()

            XCTAssertEqual(model.pairedDevices.first(where: { $0.id == deviceID })?.activeHost, "100.64.0.5")
        }

        /// A refresh that observes no change between the live-resolved host and what `pairedDevices`
        /// already holds must not reload from the store — the common steady-state case stays cheap.
        func testRefreshDoesNotReloadPairedDevicesWhenResolvedHostMatchesRecord() async throws {
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["10.0.0.5", "100.64.0.5"]
            settings.port = 47_847
            settings.certificateFingerprint = "SHA256:refresh-active-host-unchanged"
            settings.authToken = "token"
            defer {
                // Safety net: if the assertion below ever fails because a reload *did* happen, `load()`
                // auto-pairs an unmatched-but-paired settings value into a brand-new persisted record —
                // clean that up too so a failing run here cannot leak state into later test runs.
                for device in SpacesMobileDeviceStore.load(fallbackSettings: SpacesMobileConnectionSettings()).devices
                where device.certificateFingerprint == settings.certificateFingerprint {
                    _ = SpacesMobileDeviceStore.remove(deviceID: device.id, fallbackSettings: SpacesMobileConnectionSettings())
                }
            }

            let overview = makeOverview(daemonStatus: daemonStatus(protocolVersion: SpacesWireProtocol.version))
            let backend = SpacesMobileFakeResolvedHostBackend(resolvedHost: "10.0.0.5") { _ in
                SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
            }
            let client = SpacesDeviceAPIClient(settings: settings, backend: backend)
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.activeDeviceID = "device-1"
            let unchangedRecord = SpacesMobilePairedDeviceRecord(
                id: "device-1", name: "Studio", hosts: settings.hosts, port: settings.port, certificateFingerprint: settings.certificateFingerprint,
                createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", lastSelectedAt: nil, activeHost: "10.0.0.5")
            model.pairedDevices = [unchangedRecord]

            await model.refresh()

            // Nothing paired under this fingerprint exists in the real store, so a reload would have
            // wiped `pairedDevices` down to whatever `SpacesMobileDeviceStore.load` actually persists —
            // proving no reload happened at all, not merely that the value looks the same.
            XCTAssertEqual(model.pairedDevices, [unchangedRecord])
        }

        // MARK: - Connection error tolerance

        /// The overview poll runs every two seconds and a failed round trip that throws immediately —
        /// most visibly when the app returns from the background onto a socket the OS dropped — routinely
        /// heals on the next one, so it must not raise the modal connection alert.
        func testFailureThatThrowsImmediatelyDoesNotSurfaceConnectionError() async {
            let model = makeModel(refreshFailure: SpacesDeviceAPIClientError.requestFailed("Socket is not connected"))

            await model.refresh()
            await model.refresh()

            XCTAssertNil(model.errorMessage)
        }

        /// A device that is genuinely unreachable keeps failing, and the alert must still arrive once the
        /// failures have gone on long enough to be more than a blip.
        func testFailuresThatPersistPastTheDelaySurfaceConnectionError() async {
            let clock = TestClock()
            let model = makeModel(
                refreshFailure: SpacesDeviceAPIClientError.requestFailed("Socket is not connected"), refreshFailureAlertDelay: .milliseconds(50),
                clock: clock)

            await model.refresh()
            XCTAssertNil(model.errorMessage, "the alert must not appear while the failures could still be a blip")
            clock.advance(by: .milliseconds(60))
            await model.refresh()

            XCTAssertEqual(model.errorMessage, "Socket is not connected")
        }

        /// An unreachable host does not refuse the connection, it swallows it: a single refresh burns the
        /// overview request's timeout and the compatibility handshake's before throwing once. Gating on
        /// elapsed time rather than a failure count is what keeps that case from waiting several more
        /// timeouts — the first failure has already been failing for longer than the delay.
        func testFailureThatBurnsTheDelayBeforeThrowingSurfacesImmediately() async {
            let clock = TestClock()
            let settings = SpacesMobileConnectionSettings()
            // Stands in for a request that burns the whole delay before throwing: advance the clock
            // instead of sleeping through it, so the request itself does not need to take any real time.
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                clock.advance(by: .milliseconds(60))
                throw SpacesDeviceAPIClientError.requestTimedOut
            }
            let model = SpacesMobileAppModel(
                settings: settings, bridgeClient: client, refreshFailureAlertDelay: .milliseconds(50), now: { clock.now })

            await model.refresh()

            XCTAssertNotNil(model.errorMessage)
        }

        /// Recovery ends the run: failures, a success, then one more immediate failure is not a run that
        /// has persisted, and must stay silent.
        func testSuccessfulRefreshEndsTheFailureRun() async {
            let clock = TestClock()
            let counter = SpacesMobilePollCounter()
            let settings = SpacesMobileConnectionSettings()
            let overview = makeOverview()
            // Counted per overview request, not per request: a failed refresh also issues the frozen-core
            // handshake, so "the second refresh" is not "the second request".
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                guard request.commandName == "overview" else { throw SpacesDeviceAPIClientError.requestFailed("Socket is not connected") }
                let attempt = await counter.increment()
                guard attempt == 2 else { throw SpacesDeviceAPIClientError.requestFailed("Socket is not connected") }
                return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
            }
            let model = SpacesMobileAppModel(
                settings: settings, bridgeClient: client, refreshFailureAlertDelay: .milliseconds(50), now: { clock.now })

            await model.refresh()
            await model.refresh()
            XCTAssertEqual(model.overview, overview)
            clock.advance(by: .milliseconds(60))
            await model.refresh()

            XCTAssertNil(model.errorMessage, "the run restarts at the failure after the success, so nothing has persisted yet")
        }

        /// Nothing polls while the app is backgrounded or the poll is paused behind a detail route, so
        /// that time is not evidence of a failing connection. A failure recorded before the pause and one
        /// recorded after must not read as one long outage, or the first blip on the way back raises the
        /// alert this gate exists to prevent.
        func testFailureRunEndsWhenConnectionMonitoringPauses() async {
            let clock = TestClock()
            let model = makeModel(
                refreshFailure: SpacesDeviceAPIClientError.requestFailed("Socket is not connected"), refreshFailureAlertDelay: .milliseconds(50),
                clock: clock)

            await model.refresh()
            clock.advance(by: .milliseconds(60))
            model.noteConnectionMonitoringPaused()
            await model.refresh()

            XCTAssertNil(model.errorMessage)
        }

        /// A refresh already in flight when monitoring pauses resumes with a start time from before the
        /// pause. Letting it record a failure would rebuild the run the pause just ended, dated before it
        /// — and the first failure after that alerts on time nothing was being watched.
        func testFailureFromARefreshThatSpannedAPauseIsNotTimed() async {
            let clock = TestClock()
            let gate = SpacesMobileAsyncGate()
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                await gate.wait()
                throw SpacesDeviceAPIClientError.requestFailed("Socket is not connected")
            }
            let model = SpacesMobileAppModel(
                settings: settings, bridgeClient: client, refreshFailureAlertDelay: .milliseconds(50), now: { clock.now })

            let refresh = Task { await model.refresh() }
            // Wait for the attempt to actually be in flight — past capturing its monitoring generation
            // and start time — before pausing. This is a task-scheduling wait, not a clock crossing: it
            // has to be an observable state change rather than an advance on the fake clock, because what
            // it is waiting for is the refresh Task getting scheduled at all.
            while !model.isLoading { try? await Task.sleep(for: .milliseconds(5)) }
            model.noteConnectionMonitoringPaused()
            // Stands in for the pause: by the time the interrupted attempt resumes, more than the alert
            // delay has passed on a clock that never stops.
            clock.advance(by: .milliseconds(60))
            await gate.open()
            await refresh.value

            XCTAssertNil(model.errorMessage)
        }

        /// A mutation's refreshed overview proves the device answered, so it ends the run exactly as a
        /// successful poll does — otherwise the next isolated failure inherits a start time from an outage
        /// that demonstrably ended.
        func testMutationOverviewEndsTheFailureRun() async {
            let settings = SpacesMobileConnectionSettings()
            let overview = makeOverview()
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                guard request.commandName == "runWorkspaceProcess" else { throw SpacesDeviceAPIClientError.requestFailed("Socket is not connected") }
                return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
            }
            let clock = TestClock()
            let model = SpacesMobileAppModel(
                settings: settings, bridgeClient: client, refreshFailureAlertDelay: .milliseconds(50), now: { clock.now })
            let row = SpacesDeviceWorkspaceProcessRow(
                id: "process-api", workspaceID: "workspace-feature", name: "api", command: "npm run dev", processID: "runtime-api",
                sessionID: "session-api", runState: .notStarted, canRun: true, canStop: false, canRestart: false)

            await model.refresh()
            clock.advance(by: .milliseconds(60))
            _ = await model.run(row: SpacesMobileWorkspaceRuntimeRow(source: .process(row)))
            XCTAssertEqual(model.overview, overview)
            await model.refresh()

            XCTAssertNil(model.errorMessage)
        }

        /// Failures gathered against one connection say nothing about the next one, so a connection change
        /// mid-run starts the clock over rather than letting the new connection inherit it.
        func testFailureRunDoesNotCarryAcrossAConnectionChange() async {
            // The failure run is keyed by connection identity, and raising the recovery surface bumps it,
            // so the refresh after it starts a fresh run rather than inheriting the one already past the
            // alert delay. An empty candidate list keeps the fake's own transport out of the picture.
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = []
            let client = SpacesDeviceAPIClient(settings: settings) { _ in throw SpacesDeviceAPIClientError.requestFailed("Socket is not connected") }
            let clock = TestClock()
            let model = SpacesMobileAppModel(
                settings: settings, bridgeClient: client, refreshFailureAlertDelay: .milliseconds(50), now: { clock.now })

            await model.refresh()
            clock.advance(by: .milliseconds(60))
            model.handleAuthenticationFailure(message: "Pair this device again.")
            await model.refresh()

            XCTAssertNil(model.errorMessage)
        }

        /// The tolerance covers unreachability, not a device that refuses this client: an authentication
        /// failure is not going to resolve itself, so it routes to the re-pair flow on the first failure.
        func testAuthenticationFailureIsReportedOnTheFirstRefresh() async {
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                SpacesDeviceAPIResponse(ok: false, message: "Invalid device auth token.", errorCode: .unauthorized)
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)

            await model.refresh()

            XCTAssertNotNil(model.connectionNotice)
            XCTAssertTrue(model.isShowingConnectionSettings)
            XCTAssertNil(model.errorMessage)
        }

        /// Raising the re-pair surface must not unpair the app. The token in `settings` is a copy of one
        /// the Keychain still holds, and the overview poll only runs while `settings.isPaired`, so
        /// clearing it in memory ended every retry that could have proven the failure transient: the app
        /// stayed on the pairing screen for the rest of the process even once the network recovered.
        func testAuthenticationFailureKeepsThePairingSoAPollCanStillRun() {
            let model = SpacesMobileAppModel(
                settings: pairedSettings(), bridgeClient: pairedClient { _ in SpacesDeviceAPIResponse(ok: true, message: "ok") })

            model.handleAuthenticationFailure(message: "Pair this device again.")

            XCTAssertEqual(model.settings.trimmedAuthToken, "paired-token", "the credential is still on disk; the in-memory copy must survive")
            XCTAssertTrue(model.settings.isPaired, "the poll is gated on isPaired, so unpairing here stops every retry")
            XCTAssertEqual(model.connectionNotice, "Pair this device again.", "the recovery notice is still the user-facing consequence")
            XCTAssertTrue(model.isShowingConnectionSettings)
        }

        /// What keeping the credential buys: a device that rejects one request and answers the next comes
        /// back on its own, with no re-pair and nothing for the user to tap.
        func testRefreshAfterATransientAuthenticationFailureRecoversOnItsOwn() async {
            let overview = makeOverview()
            let counter = SpacesMobilePollCounter()
            let model = SpacesMobileAppModel(
                settings: pairedSettings(),
                bridgeClient: pairedClient { _ in
                    if await counter.increment() == 1 {
                        return SpacesDeviceAPIResponse(ok: false, message: "Invalid device auth token.", errorCode: .unauthorized)
                    }
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
                })

            await model.refresh()
            XCTAssertNotNil(model.connectionNotice, "the rejected request raises the recovery notice")
            XCTAssertTrue(model.settings.isPaired)

            await model.refresh()

            XCTAssertNil(model.connectionNotice, "the device answered: the recovery episode is over")
            XCTAssertEqual(model.overview?.workspaces.map(\.id), overview.workspaces.map(\.id))
        }

        /// A genuinely revoked device rejects every poll, two seconds apart. The recovery surface is
        /// raised once for that episode, not re-raised on every rejection: a user who has navigated away
        /// from Paired Devices must not be pulled back to it every two seconds.
        func testRepeatedAuthenticationFailuresRaiseTheRecoverySurfaceOnlyOnce() async {
            let model = SpacesMobileAppModel(
                settings: pairedSettings(),
                bridgeClient: pairedClient { _ in SpacesDeviceAPIResponse(ok: false, message: "Invalid device auth token.", errorCode: .unauthorized)
                })

            await model.refresh()
            XCTAssertTrue(model.isShowingConnectionSettings)
            // The user read the notice and navigated away, which is what clears the request flag.
            model.isShowingConnectionSettings = false

            await model.refresh()

            XCTAssertFalse(model.isShowingConnectionSettings, "the same failing credential must not keep pulling the user back")
            XCTAssertNotNil(model.connectionNotice, "the notice stays: the device is still rejecting this device")
        }

        /// A mutation is something the user just asked for, so its failure is reported immediately rather
        /// than waiting for a run of failures the way a background poll does.
        func testMutationFailureSurfacesErrorImmediately() async {
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                if request.commandName == "runWorkspaceProcess" { throw SpacesDeviceAPIClientError.requestFailed("Process failed to start.") }
                return SpacesDeviceAPIResponse(ok: true, message: "ok")
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)
            model.overview = makeOverview()
            let row = SpacesDeviceWorkspaceProcessRow(
                id: "process-api", workspaceID: "workspace-feature", name: "api", command: "npm run dev", processID: "runtime-api",
                sessionID: "session-api", runState: .notStarted, canRun: true, canStop: false, canRestart: false)

            let session = await model.run(row: SpacesMobileWorkspaceRuntimeRow(source: .process(row)))

            XCTAssertNil(session)
            XCTAssertEqual(model.errorMessage, "Process failed to start.")
        }

        // MARK: - Daemon update

        /// Requesting the update fires the RPC, then polls until the device reports the staged update
        /// applied, at which point the fresh status is published, a full refresh runs, and the notice
        /// clears — leaving the device usable again.
        func testRequestDaemonUpdatePollsUntilAppliedThenClearsNotice() async {
            let recorder = SpacesMobileRequestRecorder()
            let counter = SpacesMobilePollCounter()
            let settings = SpacesMobileConnectionSettings()
            let pendingStatus = daemonStatus(protocolVersion: SpacesWireProtocol.version, installedVersion: "2.0.0")
            let appliedStatus = daemonStatus(protocolVersion: SpacesWireProtocol.version, version: "2.0.0")
            let overview = makeOverview(daemonStatus: appliedStatus)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                switch request.commandName {
                case "requestDaemonRestart": return SpacesDeviceAPIResponse(ok: true, message: "ok")
                case "daemonStatus":
                    let attempt = await counter.increment()
                    let status = attempt < 3 ? pendingStatus : appliedStatus
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .daemonStatus(status))
                case "overview": return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
                default: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
            }
            let model = SpacesMobileAppModel(
                settings: settings, bridgeClient: client, daemonUpdatePollInterval: .milliseconds(1), daemonUpdateTimeout: .milliseconds(200))

            await model.requestDaemonUpdate()

            XCTAssertNil(model.connectionNotice)
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.isApplyingDaemonUpdate)
            XCTAssertFalse(model.isActiveDeviceBlocked)
            XCTAssertFalse(model.daemonUpdatePending, "the applied status no longer reports a staged update")
            XCTAssertEqual(model.overview, overview)
            let daemonStatusAttempts = await recorder.snapshot().filter { $0.commandName == "daemonStatus" }.count
            XCTAssertEqual(daemonStatusAttempts, 3, "should stop polling as soon as the applied status is observed")
        }

        /// The daemon is expected to be briefly unreachable mid-handoff (it quiesces sessions and
        /// re-execs); a poll attempt that fails to reach it must not surface as a connection error, and
        /// polling must continue once it becomes reachable again.
        func testRequestDaemonUpdateSwallowsUnreachableAttemptsThenResolves() async {
            let recorder = SpacesMobileRequestRecorder()
            let counter = SpacesMobilePollCounter()
            let settings = SpacesMobileConnectionSettings()
            let appliedStatus = daemonStatus(protocolVersion: SpacesWireProtocol.version, version: "2.0.0")
            let overview = makeOverview(daemonStatus: appliedStatus)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                switch request.commandName {
                case "requestDaemonRestart": return SpacesDeviceAPIResponse(ok: true, message: "ok")
                case "daemonStatus":
                    let attempt = await counter.increment()
                    if attempt < 3 { throw SpacesDeviceAPIClientError.requestTimedOut }
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .daemonStatus(appliedStatus))
                case "overview": return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
                default: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
            }
            let model = SpacesMobileAppModel(
                settings: settings, bridgeClient: client, daemonUpdatePollInterval: .milliseconds(1), daemonUpdateTimeout: .milliseconds(200))

            await model.requestDaemonUpdate()

            XCTAssertNil(model.connectionNotice)
            XCTAssertNil(model.errorMessage, "fetch failures mid-poll must not surface as a connection error")
            XCTAssertEqual(model.overview, overview)
        }

        /// A device that never reports the update applied within the attempt budget clears the notice
        /// and lets a final refresh render whatever is actually true, instead of inventing a failure.
        func testRequestDaemonUpdateClearsNoticeWithoutErrorWhenBudgetRunsOut() async {
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let pendingStatus = daemonStatus(protocolVersion: SpacesWireProtocol.version, installedVersion: "2.0.0")
            let overview = makeOverview(daemonStatus: pendingStatus)
            // Each status probe is slow, standing in for the request timeout a genuinely unreachable
            // device burns. This is what separates a wall-clock budget from an attempt count: polling a
            // fixed number of times would cost attempts × probe duration, many times the stated budget.
            let probeDuration = Duration.milliseconds(100)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                switch request.commandName {
                case "requestDaemonRestart": return SpacesDeviceAPIResponse(ok: true, message: "ok")
                case "daemonStatus":
                    try? await Task.sleep(for: probeDuration)
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .daemonStatus(pendingStatus))
                case "overview": return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
                default: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
            }
            let budget = Duration.milliseconds(200)
            let model = SpacesMobileAppModel(
                settings: settings, bridgeClient: client, daemonUpdatePollInterval: .milliseconds(1), daemonUpdateTimeout: budget)

            // Establish the device's state first, the way a real session would before the user taps.
            await model.refresh()
            XCTAssertTrue(model.daemonUpdatePending, "precondition: the device reports a staged update")

            let elapsed = await ContinuousClock().measure { await model.requestDaemonUpdate() }

            XCTAssertNil(model.connectionNotice, "a timed-out poll must not invent a failure message")
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.isApplyingDaemonUpdate, "the action is usable again once the budget is spent")
            // The banner is left showing the last thing the device said, rather than being cleared or
            // replaced by a connection error, because a slow restart is indistinguishable from a refused
            // one from here.
            XCTAssertTrue(model.daemonUpdatePending)
            let daemonStatusAttempts = await recorder.snapshot().filter { $0.commandName == "daemonStatus" }.count
            XCTAssertGreaterThanOrEqual(daemonStatusAttempts, 1, "the poll must probe at least once before giving up")
            // The budget bounds the poll, plus at most one probe already in flight when it expires. The
            // generous slack keeps this from flaking on a loaded machine while still failing an
            // implementation that polls a fixed number of times (which would run several times longer).
            XCTAssertLessThan(elapsed, budget + probeDuration + .milliseconds(600), "the poll must stop on its time budget")
        }

        /// A blocked device that never answers again leaves the block in place and reports nothing: an
        /// unreachable device is the overview poll's story, not evidence about an update, and the verdict
        /// may only rest on what the device says about itself. Reconciling with a refresh here would do
        /// the opposite — against a device that is still down it clears the status the screen renders
        /// from and raises a connection error, and it cannot run under the expected-outage suppression
        /// because that keys off the flag this path has to release.
        func testAnAutomaticApplyReportsNothingWhenTheDeviceNeverAnswersAgain() async {
            let settings = SpacesMobileConnectionSettings()
            let recorder = SpacesMobileRequestRecorder()
            let overviewCounter = SpacesMobilePollCounter()
            let blockingStaged = daemonStatus(protocolVersion: SpacesWireProtocol.version - 1, installedVersion: "2.0.0")
            let overview = makeOverview(daemonStatus: blockingStaged)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                switch request.commandName {
                case "requestDaemonRestart": return SpacesDeviceAPIResponse(ok: true, message: "ok")
                case "overview":
                    // One good read to establish state; the device is unreachable from then on.
                    guard await overviewCounter.increment() == 1 else {
                        return SpacesDeviceAPIResponse(ok: false, message: "The device is unreachable.")
                    }
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
                default: return SpacesDeviceAPIResponse(ok: false, message: "The device is unreachable.")
                }
            }
            let model = SpacesMobileAppModel(
                settings: settings, bridgeClient: client, daemonUpdatePollInterval: .milliseconds(10), daemonUpdateTimeout: .milliseconds(50))

            // Establishing the state is all it takes: a blocked device with a build staged has its apply
            // requested without the user asking.
            await model.refresh()
            XCTAssertTrue(model.isActiveDeviceBlocked, "precondition: the device is blocked with an update to apply")
            // The request proves the apply started (the flag is claimed before it is sent), so waiting for
            // the flag to be clear afterwards is waiting for that run to be over, not for it to begin.
            await waitUntil("the automatic apply to finish") {
                await recorder.snapshot().contains { $0.commandName == "requestDaemonRestart" } && !model.isApplyingDaemonUpdate
            }

            XCTAssertNotNil(model.daemonStatus, "the block must survive a daemon that never came back")
            XCTAssertTrue(model.isActiveDeviceBlocked, "an unreturned daemon leaves the device blocked, not silently usable")
            XCTAssertNil(model.errorMessage, "a slow restart and a refused one look the same here; neither is a reported failure")
            XCTAssertNil(model.connectionNotice)
            XCTAssertNil(model.stagedApplyDidNotLandAlert, "a silent device is not the device reporting the apply did not land")
            XCTAssertEqual(model.daemonCompatibilityPresentation, .none, "with nothing reported there is nothing for the user to do yet")
        }

        /// An apply that ended with no verdict must not spend the once-per-build rule. The device went
        /// quiet for the whole poll — a daemon mid-handoff, a switched-away connection, and an
        /// unreachable device all look like this — so nothing was decided and no report was raised. If
        /// the attempt stayed consumed, the device coming back still blocked on that same staged build
        /// would find the automatic apply deduped away with nothing on screen, and the user would be
        /// stuck there until the app was relaunched.
        func testAnUndecidedAutomaticApplyIsRequestedAgainWhenTheDeviceComesBack() async {
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let blockingStaged = daemonStatus(protocolVersion: SpacesWireProtocol.version - 1, installedVersion: "2.0.0")
            let overview = makeOverview(daemonStatus: blockingStaged)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                switch request.commandName {
                case "requestDaemonRestart": return SpacesDeviceAPIResponse(ok: true, message: "ok")
                // The daemon says nothing for the whole poll, so the run ends with no evidence either way.
                case "daemonStatus": return SpacesDeviceAPIResponse(ok: false, message: "The device is unreachable.")
                // The overview keeps answering: this is the device reporting itself still blocked and
                // still waiting on the same staged build, which is what the app polls for anyway.
                default: return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
                }
            }
            let model = SpacesMobileAppModel(
                settings: settings, bridgeClient: client, daemonUpdatePollInterval: .milliseconds(5), daemonUpdateTimeout: .milliseconds(50))

            await model.refresh()
            XCTAssertTrue(model.isActiveDeviceBlocked, "precondition: the device is blocked with an update to apply")
            await waitUntil("the first automatic apply to finish") {
                await recorder.snapshot().contains { $0.commandName == "requestDaemonRestart" } && !model.isApplyingDaemonUpdate
            }
            XCTAssertNil(model.stagedApplyDidNotLandAlert, "a device that said nothing about itself reported no failed apply")

            // The overview poll goes on reporting the device blocked with that build staged, exactly as it
            // does in the app; that report has to be able to re-arm the apply.
            await waitUntil("the automatic apply to be requested again") {
                await model.refresh()
                return await recorder.snapshot().filter { $0.commandName == "requestDaemonRestart" }.count >= 2
            }
            XCTAssertTrue(model.isActiveDeviceBlocked, "the device is still blocked on the build it has staged")
        }

        /// A verdict may only rest on evidence that is still current. A device that answers early in the
        /// poll and then goes quiet — what a daemon mid-handoff replaying its sessions looks like — must
        /// not be judged from that first report once the budget runs out: the apply may well have landed
        /// while it was silent. The run ends undecided, so nothing is reported and the attempt re-arms.
        func testAStaleStatusFromEarlyInThePollDoesNotReportThatTheApplyDidNotLand() async {
            let recorder = SpacesMobileRequestRecorder()
            let statusPolls = SpacesMobilePollCounter()
            let settings = SpacesMobileConnectionSettings()
            let blockingStaged = daemonStatus(protocolVersion: SpacesWireProtocol.version - 1, installedVersion: "2.0.0")
            let overview = makeOverview(daemonStatus: blockingStaged)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                switch request.commandName {
                case "requestDaemonRestart": return SpacesDeviceAPIResponse(ok: true, message: "ok")
                case "daemonStatus":
                    // One answer at the start of the poll — the build still staged, the handoff not yet
                    // done — and silence from then on.
                    guard await statusPolls.increment() == 1 else { return SpacesDeviceAPIResponse(ok: false, message: "The device is unreachable.") }
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .daemonStatus(blockingStaged))
                default: return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
                }
            }
            let model = SpacesMobileAppModel(
                settings: settings, bridgeClient: client, daemonUpdatePollInterval: .milliseconds(5), daemonUpdateTimeout: .milliseconds(80))

            await model.refresh()
            await waitUntil("the automatic apply to finish") {
                await recorder.snapshot().contains { $0.commandName == "requestDaemonRestart" } && !model.isApplyingDaemonUpdate
            }

            XCTAssertNil(model.stagedApplyDidNotLandAlert, "a report the device stopped answering for cannot be a verdict about it")
            XCTAssertEqual(model.daemonCompatibilityPresentation, .none, "nothing was decided, so the block carries no failure and no Try Again yet")
            XCTAssertNil(model.errorMessage)
            // Undecided, so the once-per-build rule is handed back: the device's next report re-arms it.
            await waitUntil("the automatic apply to be requested again") {
                await model.refresh()
                return await recorder.snapshot().filter { $0.commandName == "requestDaemonRestart" }.count >= 2
            }
        }

        /// The whole automatic flow on a blocked device: Spaces asks it to apply the build already
        /// installed on it, without being told to and without asking; a device that keeps reporting that
        /// same build staged gets one report and the retry, and the request is never re-sent for a build
        /// already asked about, however many times the device repeats itself.
        func testABlockedDeviceAppliesItsStagedBuildOnItsOwnAndReportsOnlyWhenItDoesNotLand() async {
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let blockingStaged = daemonStatus(protocolVersion: SpacesWireProtocol.version - 1, installedVersion: "2.0.0")
            let overview = makeOverview(daemonStatus: blockingStaged)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                switch request.commandName {
                case "requestDaemonRestart": return SpacesDeviceAPIResponse(ok: true, message: "ok")
                // The device answers throughout and never applies the build: the apply did not land.
                case "daemonStatus": return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .daemonStatus(blockingStaged))
                default: return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
                }
            }
            let model = SpacesMobileAppModel(
                settings: settings, bridgeClient: client, daemonUpdatePollInterval: .milliseconds(5), daemonUpdateTimeout: .milliseconds(50))

            await model.refresh()
            await waitUntil("the report the apply did not land") { model.stagedApplyDidNotLandAlert != nil }

            let alert = model.stagedApplyDidNotLandAlert
            XCTAssertEqual(alert?.title, "Update didn't land")
            XCTAssertEqual(
                alert?.message,
                "Spaces 2.0.0 is installed on \(model.connectionSummary), but its daemon is still running 1.0.0. "
                    + "Nothing running on it was interrupted.")
            XCTAssertTrue(model.isActiveDeviceBlocked, "an apply that did not land leaves the device blocked")
            XCTAssertNil(model.errorMessage, "the report is the whole surface; nothing goes through the connection error")
            guard case .hero(let hero) = model.daemonCompatibilityPresentation else {
                return XCTFail("A blocked device whose apply did not land shows the hero.")
            }
            XCTAssertEqual(hero.actionTitle, "Update Daemon", "the blocked screen carries the retry once the report is dismissed")

            // The device goes on reporting the same staged build on every poll; none of that re-asks.
            await model.refresh()
            await model.refresh()
            let restarts = await recorder.snapshot().filter { $0.commandName == "requestDaemonRestart" }.count
            XCTAssertEqual(restarts, 1, "a repeated status report is not new information and must not re-request the apply")
        }

        /// Try Again is the user asking again, which is new information: it re-sends the request the
        /// once-per-build rule would otherwise suppress, and takes the report and the hero down while the
        /// device is applying an update again.
        func testTryAgainReAsksForAnApplyTheOnceOnlyRuleWouldSuppress() async {
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let blockingStaged = daemonStatus(protocolVersion: SpacesWireProtocol.version - 1, installedVersion: "2.0.0")
            let overview = makeOverview(daemonStatus: blockingStaged)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                switch request.commandName {
                case "requestDaemonRestart": return SpacesDeviceAPIResponse(ok: true, message: "ok")
                case "daemonStatus": return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .daemonStatus(blockingStaged))
                default: return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
                }
            }
            let model = SpacesMobileAppModel(
                settings: settings, bridgeClient: client, daemonUpdatePollInterval: .milliseconds(5), daemonUpdateTimeout: .milliseconds(50))

            await model.refresh()
            await waitUntil("the report the apply did not land") { model.stagedApplyDidNotLandAlert != nil }

            await model.retryStagedApply()

            let restarts = await recorder.snapshot().filter { $0.commandName == "requestDaemonRestart" }.count
            XCTAssertEqual(restarts, 2, "the user asking again re-sends the request")
            XCTAssertEqual(model.stagedApplyDidNotLandAlert?.stagedVersion, "2.0.0", "a retry that also went unanswered reports itself again")
        }

        /// Everything this flow left behind is retired by the device's own facts: once it comes back on
        /// the staged build there is nothing staged, so the report and the hero go with it — no dismissal
        /// and no separate cleanup path.
        func testTheStagedApplyReportRetiresWhenTheDeviceComesBackOnTheStagedBuild() async {
            let settings = SpacesMobileConnectionSettings()
            let blockingStaged = daemonStatus(protocolVersion: SpacesWireProtocol.version - 1, installedVersion: "2.0.0")
            let applied = daemonStatus(protocolVersion: SpacesWireProtocol.version, version: "2.0.0")
            let statusBox = SpacesMobileDaemonStatusBox(blockingStaged)
            let blockedOverview = makeOverview(daemonStatus: blockingStaged)
            let appliedOverview = makeOverview(daemonStatus: applied)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                switch request.commandName {
                case "requestDaemonRestart": return SpacesDeviceAPIResponse(ok: true, message: "ok")
                case "daemonStatus": return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .daemonStatus(await statusBox.current()))
                default:
                    let isApplied = await statusBox.current().version == applied.version
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(isApplied ? appliedOverview : blockedOverview))
                }
            }
            let model = SpacesMobileAppModel(
                settings: settings, bridgeClient: client, daemonUpdatePollInterval: .milliseconds(5), daemonUpdateTimeout: .milliseconds(50))

            await model.refresh()
            await waitUntil("the report the apply did not land") { model.stagedApplyDidNotLandAlert != nil }

            // The device finally comes back on the staged build.
            await statusBox.set(applied)
            await model.refresh()

            XCTAssertNil(model.stagedApplyDidNotLandAlert, "the state the report described is over")
            XCTAssertFalse(model.isActiveDeviceBlocked)
            XCTAssertEqual(model.daemonCompatibilityPresentation, .none, "an up-to-date device says nothing about its version")
            XCTAssertEqual(model.overview, appliedOverview, "the device is usable again")
        }

        /// The handshake fallback clears the daemon status when it cannot reach the device, which leaves
        /// compatibility unknown and the device unblocked. During a requested update that outage is
        /// expected, and clearing would drop the banner and flash stale workspace controls back while the
        /// update is still running — so the last known facts have to survive it.
        func testStatusSurvivesAFailedHandshakeDuringTheUpdate() async {
            let settings = SpacesMobileConnectionSettings()
            let overviewCounter = SpacesMobilePollCounter()
            // Blocking plus staged: the device is wire-incompatible and has an update to apply, which is
            // the state the banner and the blocked-device rule both read.
            let blockingStaged = daemonStatus(protocolVersion: SpacesWireProtocol.version - 1, installedVersion: "2.0.0")
            let overview = makeOverview(daemonStatus: blockingStaged)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                switch request.commandName {
                case "requestDaemonRestart": return SpacesDeviceAPIResponse(ok: true, message: "ok")
                case "overview":
                    // The first read establishes the state; everything after it is the handoff outage.
                    guard await overviewCounter.increment() == 1 else {
                        return SpacesDeviceAPIResponse(ok: false, message: "The device is unreachable.")
                    }
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
                // The frozen-core handshake cannot reach the device either, which is what triggers the
                // clearing path this test guards.
                default: return SpacesDeviceAPIResponse(ok: false, message: "The device is unreachable.")
                }
            }
            let model = SpacesMobileAppModel(
                settings: settings, bridgeClient: client, daemonUpdatePollInterval: .milliseconds(20), daemonUpdateTimeout: .seconds(5))

            // The first read establishes the state and, because the device is blocked with a build
            // staged, starts the automatic apply — the update this test runs its refresh underneath.
            await model.refresh()
            XCTAssertNotNil(model.daemonStatus, "precondition: the first read establishes the device's status")
            XCTAssertTrue(model.isActiveDeviceBlocked)
            await waitUntil("the automatic apply to claim the update") { model.isApplyingDaemonUpdate }

            await model.refresh()

            XCTAssertNotNil(model.daemonStatus, "the screen renders off the status; the expected outage must not erase it")
            XCTAssertTrue(model.isActiveDeviceBlocked, "the device must stay blocked while its daemon is mid-update")

            // Ends the in-flight apply deterministically instead of waiting out its budget: the poll
            // abandons a run whose connection identity moved, which is what a device switch does.
            model.handleAuthenticationFailure(message: "Switched devices.")
            await waitUntil("the abandoned apply to release the update") { !model.isApplyingDaemonUpdate }
        }

        /// The deadline is re-checked after each wait, not only before it. A probe launched once the
        /// budget has already passed would add its own request timeout on top of a wait that had itself
        /// overrun — the poll would run well past the bound it advertises.
        func testPollLaunchesNoProbeOnceTheBudgetHasPassed() async {
            let recorder = SpacesMobileRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let pendingStatus = daemonStatus(protocolVersion: SpacesWireProtocol.version, installedVersion: "2.0.0")
            let overview = makeOverview(daemonStatus: pendingStatus)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                switch request.commandName {
                case "requestDaemonRestart": return SpacesDeviceAPIResponse(ok: true, message: "ok")
                case "daemonStatus": return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .daemonStatus(pendingStatus))
                case "overview": return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
                default: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
            }
            // A budget shorter than one interval: the first wait alone carries the loop past the
            // deadline, so a correct poll gives up without ever probing.
            let model = SpacesMobileAppModel(
                settings: settings, bridgeClient: client, daemonUpdatePollInterval: .milliseconds(200), daemonUpdateTimeout: .milliseconds(50))

            await model.requestDaemonUpdate()

            let probes = await recorder.snapshot().filter { $0.commandName == "daemonStatus" }.count
            XCTAssertEqual(probes, 0, "a probe must not start after the budget has already run out")
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.isApplyingDaemonUpdate)
        }

        /// A timed-out update releases the in-flight flag before its reconciling refresh, so a retry can
        /// start while the previous invocation is still finishing that refresh. The slow predecessor must
        /// not clear the flag out from under the retry: doing so would re-enable the Update Daemon button
        /// and resume the overview poll in the middle of the retry's handoff.
        func testSlowPredecessorDoesNotClearARetrysInFlightState() async {
            let settings = SpacesMobileConnectionSettings()
            // Both waits are gates rather than sleeps, so each task parks exactly where the test needs it
            // regardless of machine load: the predecessor inside its post-timeout refresh, the retry
            // inside its poll. Timing-based staging flakes precisely when the box is busy.
            let overviewGate = SpacesMobileAsyncGate()
            let retryProbeGate = SpacesMobileAsyncGate()
            let probeCounter = SpacesMobilePollCounter()
            let pendingStatus = daemonStatus(protocolVersion: SpacesWireProtocol.version, installedVersion: "2.0.0")
            let overview = makeOverview(daemonStatus: pendingStatus)
            let budget = Duration.milliseconds(50)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                switch request.commandName {
                case "requestDaemonRestart": return SpacesDeviceAPIResponse(ok: true, message: "ok")
                case "daemonStatus":
                    // The predecessor's one probe outlasts its own budget so it times out; every later
                    // probe belongs to the retry and parks until the test releases it.
                    if await probeCounter.increment() == 1 { try? await Task.sleep(for: budget * 2) } else { await retryProbeGate.wait() }
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .daemonStatus(pendingStatus))
                case "overview":
                    // Holds the predecessor inside its post-timeout refresh until the test releases it.
                    await overviewGate.wait()
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
                default: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
            }
            let model = SpacesMobileAppModel(
                settings: settings, bridgeClient: client, daemonUpdatePollInterval: .milliseconds(1), daemonUpdateTimeout: budget)

            let predecessor = Task { await model.requestDaemonUpdate() }
            // Wait for the predecessor to actually claim ownership before waiting for it to let go —
            // checking only for the release would fall straight through while its task is still
            // unscheduled, and the two invocations would then claim generations in the wrong order.
            while !model.isApplyingDaemonUpdate { try? await Task.sleep(for: .milliseconds(5)) }
            // The predecessor times out, releases the flag, and parks in its gated refresh.
            while model.isApplyingDaemonUpdate { try? await Task.sleep(for: .milliseconds(5)) }

            let retry = Task { await model.requestDaemonUpdate() }
            while !model.isApplyingDaemonUpdate { try? await Task.sleep(for: .milliseconds(5)) }

            // The retry is parked in its probe, so releasing the predecessor cannot be raced by the retry
            // finishing early — the flag's value here is decided purely by whose generation owns it.
            await overviewGate.open()
            await predecessor.value

            XCTAssertTrue(model.isApplyingDaemonUpdate, "the retry still owns the update; its predecessor's exit must not release it")
            await retryProbeGate.open()
            await retry.value
            XCTAssertFalse(model.isApplyingDaemonUpdate, "the retry releases the flag when it finishes")
        }

        /// A daemon update takes its device offline deliberately, so an overview refresh that fails
        /// inside that window is expected rather than news. Pausing the poll cannot cover a refresh
        /// already in flight when the user taps Update, or a pull-to-refresh during the update, so the
        /// failure path itself stays quiet — but only for the duration of the update.
        func testOverviewFailureDuringDaemonUpdateStaysQuietButNotAfterward() async {
            let settings = SpacesMobileConnectionSettings()
            let unreachable = SpacesDeviceAPIResponse(ok: false, message: "The device is unreachable.")
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                switch request.commandName {
                case "requestDaemonRestart": return SpacesDeviceAPIResponse(ok: true, message: "ok")
                // Everything else fails: the daemon is mid-handoff and answering nothing.
                default: return unreachable
                }
            }
            // A budget long enough that the update is unambiguously still in flight for the refresh
            // below; the task is cancelled rather than waited out.
            // A zero alert delay isolates the update-scoped suppression from the failure-run gate below:
            // any refresh failure this test allows through reports on the spot.
            let model = SpacesMobileAppModel(
                settings: settings, bridgeClient: client, daemonUpdatePollInterval: .milliseconds(20), daemonUpdateTimeout: .seconds(5),
                refreshFailureAlertDelay: .zero)

            let update = Task { await model.requestDaemonUpdate() }
            while !model.isApplyingDaemonUpdate { try? await Task.sleep(for: .milliseconds(5)) }

            await model.refresh()
            XCTAssertNil(model.errorMessage, "an outage the update flow is already watching must not raise a connection error")

            update.cancel()
            await update.value
            XCTAssertFalse(model.isApplyingDaemonUpdate)

            // The same failure outside the update window is a genuine connection problem and must show.
            await model.refresh()
            XCTAssertNotNil(model.errorMessage, "suppression is scoped to the update; an ordinary unreachable device still reports")
        }

        /// Switching the active device mid-poll (modeled here the same way other identity-change tests
        /// do, via `handleAuthenticationFailure`) must not let a stale poll result publish onto the new
        /// device, nor clobber the notice the switch itself raised.
        func testRequestDaemonUpdateDeviceSwitchMidPollDoesNotPublishOntoNewDevice() async {
            let recorder = SpacesMobileRequestRecorder()
            let gate = SpacesMobileAsyncGate()
            let settings = SpacesMobileConnectionSettings()
            let appliedStatus = daemonStatus(protocolVersion: SpacesWireProtocol.version, version: "2.0.0")
            let overview = makeOverview(daemonStatus: appliedStatus)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                switch request.commandName {
                case "requestDaemonRestart": return SpacesDeviceAPIResponse(ok: true, message: "ok")
                case "daemonStatus":
                    await gate.wait()
                    return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .daemonStatus(appliedStatus))
                case "overview": return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .overview(overview))
                default: return SpacesDeviceAPIResponse(ok: true, message: "ok")
                }
            }
            let model = SpacesMobileAppModel(
                settings: settings, bridgeClient: client, daemonUpdatePollInterval: .milliseconds(1), daemonUpdateTimeout: .milliseconds(200))

            let updateTask = Task { await model.requestDaemonUpdate() }
            // Wait until the first poll attempt is gated on the device's daemonStatus fetch.
            while !(await recorder.snapshot()).contains(where: { $0.commandName == "daemonStatus" }) { await Task.yield() }
            model.handleAuthenticationFailure(message: "Switched devices.")
            await gate.open()
            await updateTask.value

            XCTAssertEqual(model.connectionNotice, "Switched devices.", "the device switch's own notice must survive the stale poll resolving")
            XCTAssertNil(model.daemonStatus, "a stale poll result must not publish onto the new identity")
            XCTAssertNil(model.overview)
        }

        // MARK: - What the device screen says about a daemon's version

        /// A device that still works keeps its explicit action: a quiet card stating the gap, and rows
        /// that stay usable underneath it. This phone may be the only client running, so this is the one
        /// staged-update state it does not apply on its own.
        func testACompatibleDeviceWithAStagedBuildGetsTheQuietPendingCard() {
            let status = daemonStatus(protocolVersion: SpacesWireProtocol.version, installedVersion: "2.0.0")

            let presentation = DaemonCompatibilityPresentation.presentation(
                remedy: DaemonUpdateRemedy.remedy(for: status), status: status, isBlocked: false, stagedApplyDidNotLand: false, deviceName: "Studio",
                clientVersion: "1.5.0")

            guard case .pendingUpdate(let card) = presentation else { return XCTFail("A compatible device with a build staged gets the card.") }
            XCTAssertEqual(card.title, "Update pending")
            XCTAssertEqual(card.versionPair, DaemonVersionPair(from: "1.0.0", to: "2.0.0"))
            XCTAssertEqual(card.body, "Spaces 2.0.0 is on Studio, ready to apply. Nothing it's running stops.")
            XCTAssertEqual(card.actionTitle, "Update Daemon")
        }

        /// The blocked device Spaces is already applying a staged build to shows nothing at all: the work
        /// is under way, and the device comes back on its own. Only once the apply has demonstrably not
        /// landed does that state own a surface, and then it carries the retry.
        func testABlockedStagedUpdateShowsNothingUntilTheApplyHasNotLanded() {
            let status = daemonStatus(protocolVersion: SpacesWireProtocol.version - 1, installedVersion: "2.0.0")
            let remedy = DaemonUpdateRemedy.remedy(for: status)

            XCTAssertEqual(
                DaemonCompatibilityPresentation.presentation(
                    remedy: remedy, status: status, isBlocked: true, stagedApplyDidNotLand: false, deviceName: "Studio", clientVersion: "1.5.0"),
                .none, "work already in flight is not something to look at")

            let presentation = DaemonCompatibilityPresentation.presentation(
                remedy: remedy, status: status, isBlocked: true, stagedApplyDidNotLand: true, deviceName: "Studio", clientVersion: "1.5.0")

            guard case .hero(let hero) = presentation else { return XCTFail("An apply that did not land owns the screen.") }
            XCTAssertEqual(hero.eyebrow, "CAN'T CONNECT — UPDATE READY TO APPLY")
            XCTAssertEqual(hero.versionPair, DaemonVersionPair(from: "1.0.0", to: "2.0.0"))
            XCTAssertEqual(hero.whoLine, "Spaces 2.0.0 is already on Studio")
            XCTAssertEqual(hero.body, "Its daemon didn't pick the update up, and nothing running on Studio was interrupted.")
            XCTAssertEqual(hero.actionTitle, "Update Daemon")
        }

        /// A blocked device with nothing staged cannot be fixed from here, so it gets no action — only
        /// the one instruction that fixes it, which differs by what kind of device it is. Neither states
        /// a target version: what lands is whatever gets installed there.
        func testABlockedDeviceWithNothingStagedPointsAtTheDeviceAndOffersNoAction() {
            let linux = daemonStatus(protocolVersion: SpacesWireProtocol.version - 1, operatingSystem: "Linux")
            let mac = daemonStatus(protocolVersion: SpacesWireProtocol.version - 1)

            guard
                case .hero(let linuxHero) = DaemonCompatibilityPresentation.presentation(
                    remedy: DaemonUpdateRemedy.remedy(for: linux), status: linux, isBlocked: true, stagedApplyDidNotLand: false,
                    deviceName: "builder", clientVersion: "1.5.0")
            else { return XCTFail("A blocked device owns the screen.") }
            XCTAssertEqual(linuxHero.eyebrow, "CAN'T CONNECT — UPDATE NEEDED")
            XCTAssertEqual(linuxHero.versionPair, DaemonVersionPair(from: "1.0.0", to: "?"), "no build is staged, so there is no target to name")
            XCTAssertEqual(linuxHero.whoLine, "nothing newer is installed on builder")
            XCTAssertEqual(
                linuxHero.body,
                "Update it from Spaces on your Mac — it installs over SSH, and everything on builder keeps running. This phone can't update a "
                    + "Linux daemon.")
            XCTAssertNil(linuxHero.actionTitle, "nothing this app does can update a Linux daemon")

            guard
                case .hero(let macHero) = DaemonCompatibilityPresentation.presentation(
                    remedy: DaemonUpdateRemedy.remedy(for: mac), status: mac, isBlocked: true, stagedApplyDidNotLand: false, deviceName: "Studio",
                    clientVersion: "1.5.0")
            else { return XCTFail("A blocked device owns the screen.") }
            XCTAssertEqual(macHero.body, "Open Spaces on Studio and install the update; its daemon applies it on its own, and nothing running stops.")
            XCTAssertNil(macHero.actionTitle, "the update has to be installed on that Mac")
        }

        /// When this app is the side that is behind, the pair names this app's build against the
        /// device's. That is a statement of the two builds in play, not a comparison: which one is behind
        /// came from the wire verdict, never from this app measuring itself against a daemon.
        func testAnAppTooOldForItsDeviceNamesItsOwnBuildAsTheSideThatMoves() {
            let status = daemonStatus(protocolVersion: SpacesWireProtocol.version + 1, version: "3.0.0")

            let presentation = DaemonCompatibilityPresentation.presentation(
                remedy: DaemonUpdateRemedy.remedy(for: status), status: status, isBlocked: true, stagedApplyDidNotLand: false, deviceName: "Studio",
                clientVersion: "1.5.0")

            guard case .hero(let hero) = presentation else { return XCTFail("A blocked device owns the screen.") }
            XCTAssertEqual(hero.eyebrow, "CAN'T CONNECT — THIS APP NEEDS AN UPDATE")
            XCTAssertEqual(hero.versionPair, DaemonVersionPair(from: "1.5.0", to: "3.0.0"))
            XCTAssertEqual(hero.whoLine, "this app · Studio")
            XCTAssertEqual(hero.body, "Studio speaks a newer connection protocol than this app. Update Spaces from the App Store to reconnect.")
            XCTAssertNil(hero.actionTitle, "only the App Store can update this app")
        }

        /// A compatible, up-to-date device says nothing about versions at all.
        func testAnUpToDateDeviceShowsNothing() {
            let status = daemonStatus(protocolVersion: SpacesWireProtocol.version)

            XCTAssertEqual(
                DaemonCompatibilityPresentation.presentation(
                    remedy: DaemonUpdateRemedy.remedy(for: status), status: status, isBlocked: false, stagedApplyDidNotLand: false,
                    deviceName: "Studio", clientVersion: "1.5.0"), .none)
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

        /// Submitting an empty name clears an ad hoc terminal's rename — the only way back to the live title
        /// once a row has been named — so the empty title travels to the daemon instead of being discarded.
        func testEmptyRenameOnAnAdHocTerminalRowClearsItsName() async throws {
            let (model, recorder) = makeRenamingModel(
                overview: makeOverview(featureTerminalRows: [
                    SpacesDeviceWorkspaceTerminalRow(
                        id: "terminal-shell", workspaceID: "workspace-feature", title: "build log", workingDirectory: "/repo/feature",
                        sessionID: "session-shell", runState: .running, canOpenTerminal: true, canStop: true)
                ]))
            let row = try XCTUnwrap(model.workspaceGroups.flatMap(\.rows).first { $0.title == "build log" })

            await model.rename(row: row, to: "   ")

            guard case .renameTerminalSession(let request)? = await recorder.snapshot().first?.command else {
                return XCTFail("Expected a renameTerminalSession command.")
            }
            XCTAssertEqual(request.sessionID, "session-shell")
            XCTAssertEqual(request.title, "")
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
            XCTAssertEqual(request.config.browserSessions.map(\.name), ["Dashboard"])
        }

        /// Nothing in the workspace config names a coding agent, so every agent row renames its own
        /// session; an empty submission clears that rename back to the label the agent reports.
        func testRenameCodingAgentRowRenamesItsSession() async throws {
            let (model, recorder) = makeRenamingModel(overview: makeOverview(featureConfig: config()))
            let row = try XCTUnwrap(model.workspaceGroups.flatMap(\.rows).first { $0.title == "Codex" })

            XCTAssertEqual(model.canRename(row: row), true)
            await model.rename(row: row, to: "Reviewer")
            await model.rename(row: row, to: "  ")

            let requests = await recorder.snapshot()
            XCTAssertEqual(requests.map(\.commandName), ["renameAgentSession", "renameAgentSession"])
            guard case .renameAgentSession(let request)? = requests.first?.command else { return XCTFail("Expected a renameAgentSession command.") }
            XCTAssertEqual(request.workspaceID, "workspace-feature")
            XCTAssertEqual(request.agentID, "runtime-codex")
            XCTAssertEqual(request.title, "Reviewer")
            guard case .renameAgentSession(let clearing)? = requests.last?.command else { return XCTFail("Expected a renameAgentSession command.") }
            XCTAssertEqual(clearing.title, "")
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
                ], browserSessions: [SpacesDeviceBrowserSession(name: "Docs", url: "http://localhost:4000")])
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

        /// A configured row renames its config entry, which must keep a name, so an empty submission there
        /// is discarded rather than clearing anything.
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

        /// The feature workspace's configuration, matching the configured process and browser session the
        /// rename tests target.
        private func config() -> SpacesDeviceWorkspaceConfig {
            SpacesDeviceWorkspaceConfig(
                stopScript: "npm stop", ports: [SpacesDeviceServiceDefinition(id: "port-web", name: "web")],
                processes: [SpacesDeviceProcessTemplate(id: "template-api", name: "api", command: "npm run dev")],
                browserSessions: [SpacesDeviceBrowserSession(name: "Dashboard", url: "http://localhost:${PORT_web}/dashboard")],
                resolvedBrowserSessions: [SpacesDeviceBrowserSession(name: "Dashboard", url: "http://localhost:3000/dashboard")])
        }

        private func configuredProcessRow() -> SpacesDeviceWorkspaceProcessRow {
            SpacesDeviceWorkspaceProcessRow(
                id: "template-api", workspaceID: "workspace-feature", name: "api", command: "npm run dev", templateID: "template-api",
                processID: "runtime-api", sessionID: "session-api", runState: .running, canRun: false, canStop: true, canRestart: true)
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
                        id: "agent:runtime-codex", workspaceID: "workspace-feature", name: "Codex", command: "codex", agentID: "runtime-codex",
                        sessionID: "session-codex", runState: .running, activityState: .spinning, canStop: true)
                ]
            let feature = SpacesDeviceWorkspaceSummary(
                id: "workspace-feature", projectID: project.id, projectName: project.name, branch: "feature", baseBranch: "main",
                dir: "/repo/feature", isRunning: featureIsRunning, isHidden: featureIsHidden, isDefault: false, sessionCount: 1,
                assignedPorts: featureAssignedPorts, config: featureConfig, processRows: processRows, codingAgentRows: codingAgentRows,
                terminalRows: featureTerminalRows)
            let docs = SpacesDeviceWorkspaceSummary(
                id: "workspace-docs", projectID: project.id, projectName: project.name, branch: "docs", baseBranch: "main", dir: "/repo/docs",
                isRunning: false, isHidden: false, isDefault: false, sessionCount: 0, processRows: [], codingAgentRows: [],
                terminalRows: [
                    SpacesDeviceWorkspaceTerminalRow(
                        id: "terminal-shell", workspaceID: "workspace-docs", title: "shell", workingDirectory: "/repo/docs", sessionID: nil,
                        runState: .exited, canOpenTerminal: false)
                ])
            return SpacesDeviceOverviewPayload(projects: [project], workspaces: [feature, docs], sessions: sessions, daemonStatus: daemonStatus)
        }

        private func daemonStatus(protocolVersion: Int, version: String = "1.0.0", installedVersion: String? = nil, operatingSystem: String = "macOS")
            -> TerminalServiceDaemonStatus
        {
            TerminalServiceDaemonStatus(
                version: version, installedVersion: installedVersion, certificateFingerprint: nil, activeSessionCount: 0,
                protocolVersion: protocolVersion, operatingSystem: operatingSystem)
        }

        /// Waits for work the app model runs on its own — an automatic staged apply and the report it may
        /// raise are not awaitable from a caller — instead of sleeping a fixed amount and hoping. Fails
        /// the test rather than hanging if the condition never holds.
        private func waitUntil(
            _ description: String, timeout: Duration = .seconds(10), file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool
        ) async {
            let deadline = ContinuousClock().now + timeout
            while ContinuousClock().now < deadline {
                if await condition() { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
            XCTFail("Timed out waiting for \(description).", file: file, line: line)
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

        /// Settings that actually read as paired (`isPaired`), which the default `SpacesMobileConnectionSettings()`
        /// does not: the authentication-recovery tests turn on whether the pairing survives a failure.
        private func pairedSettings() -> SpacesMobileConnectionSettings {
            var settings = SpacesMobileConnectionSettings()
            settings.hosts = ["127.0.0.1"]
            settings.authToken = "paired-token"
            settings.certificateFingerprint = "SHA256:" + String(repeating: "a", count: 64)
            return settings
        }

        private func pairedClient(_ handler: @escaping @Sendable (SpacesDeviceAPIRequest) async throws -> SpacesDeviceAPIResponse)
            -> SpacesDeviceAPIClient
        { SpacesDeviceAPIClient(settings: pairedSettings(), requestHandler: handler) }

        /// A model whose device is unreachable: every request — the overview fetch and the frozen-core
        /// handshake it falls back to — throws.
        private func makeModel(refreshFailure: any Error, refreshFailureAlertDelay: Duration = .seconds(5), clock: TestClock? = nil)
            -> SpacesMobileAppModel
        {
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in throw refreshFailure }
            if let clock {
                return SpacesMobileAppModel(
                    settings: settings, bridgeClient: client, refreshFailureAlertDelay: refreshFailureAlertDelay, now: { clock.now })
            }
            return SpacesMobileAppModel(settings: settings, bridgeClient: client, refreshFailureAlertDelay: refreshFailureAlertDelay)
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
