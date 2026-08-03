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
                SpacesDeviceAPIResponse(ok: false, message: "Default workspace cannot be deleted.")
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
            while !model.isMutating { await Task.yield() }

            XCTAssertTrue(model.isWorkspacePendingDeletion("workspace-feature"))
            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-docs"))

            await gate.open()
            await delete.value

            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-feature"))
        }

        /// A delete the daemon refused leaves the workspace where it was, so the mark is lifted and its
        /// band goes back to normal beside the error.
        func testFailedDeleteClearsThePendingDeletionMark() async {
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in
                SpacesDeviceAPIResponse(ok: false, message: "Default workspace cannot be deleted.")
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
            while !model.isMutating { await Task.yield() }
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
            while !model.isMutating { await Task.yield() }
            // A real connection change while the delete is still parked in its request: this rebuilds the
            // client and channel and bumps the overview identity, exactly as a device switch does.
            model.handleAuthenticationFailure(message: "Pair this device again.")

            await gate.open()
            await delete.value

            XCTAssertFalse(model.isWorkspacePendingDeletion("workspace-feature"), "the mark must not outlive a delete abandoned by a device switch")
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
            // Resetting authentication rebuilds the client from `settings`, so the refresh after it runs
            // against the real network transport rather than the fake. An empty candidate list makes that
            // refresh fail on the spot (`invalidEndpoint`) instead of dialing anything.
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

        /// A device that never comes back leaves the warning in place: the update gives up, re-enables the
        /// action, and reports nothing. Reconciling with a refresh here would do the opposite — against a
        /// device that is still down it clears the status the banner renders from and raises a connection
        /// error, and it cannot run under the expected-outage suppression because that keys off the flag
        /// this path has to release to re-enable the button.
        func testATimedOutUpdateLeavesTheWarningInPlaceWithoutAnError() async {
            let settings = SpacesMobileConnectionSettings()
            let overviewCounter = SpacesMobilePollCounter()
            let blockingStaged = daemonStatus(protocolVersion: SpacesWireProtocol.version - 1, installedVersion: "2.0.0")
            let overview = makeOverview(daemonStatus: blockingStaged)
            let client = SpacesDeviceAPIClient(settings: settings) { request in
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

            await model.refresh()
            XCTAssertTrue(model.isActiveDeviceBlocked, "precondition: the device is blocked with an update to apply")

            await model.requestDaemonUpdate()

            XCTAssertNotNil(model.daemonStatus, "the banner must survive a daemon that never came back")
            XCTAssertTrue(model.isActiveDeviceBlocked, "an unreturned daemon leaves the device blocked, not silently usable")
            XCTAssertNil(model.errorMessage, "a slow restart and a refused one look the same here; neither is a reported failure")
            XCTAssertNil(model.connectionNotice)
            XCTAssertFalse(model.isApplyingDaemonUpdate, "the action is usable again so the user can retry")
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

            await model.refresh()
            XCTAssertNotNil(model.daemonStatus, "precondition: the first read establishes the device's status")
            XCTAssertTrue(model.isActiveDeviceBlocked)

            let update = Task { await model.requestDaemonUpdate() }
            while !model.isApplyingDaemonUpdate { try? await Task.sleep(for: .milliseconds(5)) }

            await model.refresh()

            XCTAssertNotNil(model.daemonStatus, "the banner renders off the status; the expected outage must not erase it")
            XCTAssertTrue(model.isActiveDeviceBlocked, "the device must stay blocked while its daemon is mid-update")

            update.cancel()
            await update.value
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

        /// The banner renders straight off `DaemonUpdateRemedy` plus the status it came from: the action
        /// button only ever appears for `.applyStagedUpdate`, and that one remedy still reads differently
        /// depending on whether the daemon is also wire-incompatible (`isBlocking`).
        func testCompatibilityBannerViewRendersExpectedTitleAndSeverityPerRemedy() {
            let pendingStatus = daemonStatus(protocolVersion: SpacesWireProtocol.version, installedVersion: "2.0.0")
            let blockingStagedStatus = daemonStatus(protocolVersion: SpacesWireProtocol.version - 1, installedVersion: "2.0.0")
            let installOnDeviceStatus = daemonStatus(protocolVersion: SpacesWireProtocol.version - 1)
            let updateClientStatus = daemonStatus(protocolVersion: SpacesWireProtocol.version + 1)

            let pendingBanner = CompatibilityBannerView(
                remedy: .applyStagedUpdate(installedVersion: "2.0.0"), status: pendingStatus, isMutating: false, isApplyingUpdate: false, onUpdate: {}
            )
            XCTAssertFalse(pendingBanner.isBlocking)
            XCTAssertEqual(pendingBanner.title, "Daemon update pending")

            let blockingBanner = CompatibilityBannerView(
                remedy: .applyStagedUpdate(installedVersion: "2.0.0"), status: blockingStagedStatus, isMutating: false, isApplyingUpdate: false,
                onUpdate: {})
            XCTAssertTrue(blockingBanner.isBlocking)
            XCTAssertEqual(blockingBanner.title, "This device needs a daemon update")

            let installBanner = CompatibilityBannerView(
                remedy: .installUpdateOnDevice, status: installOnDeviceStatus, isMutating: false, isApplyingUpdate: false, onUpdate: {})
            XCTAssertTrue(installBanner.isBlocking)
            XCTAssertEqual(installBanner.title, "Install the update on this device")
            XCTAssertFalse(DaemonUpdateRemedy.installUpdateOnDevice.offersDaemonUpdateAction)

            let updateClientBanner = CompatibilityBannerView(
                remedy: .updateClient, status: updateClientStatus, isMutating: false, isApplyingUpdate: false, onUpdate: {})
            XCTAssertTrue(updateClientBanner.isBlocking)
            XCTAssertEqual(updateClientBanner.title, "Update Spaces to use this device")
            XCTAssertFalse(DaemonUpdateRemedy.updateClient.offersDaemonUpdateAction)

            XCTAssertTrue(
                DaemonUpdateRemedy.applyStagedUpdate(installedVersion: "2.0.0").offersDaemonUpdateAction,
                "the only remedy that offers the Update Daemon action")
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

        private func daemonStatus(protocolVersion: Int, version: String = "1.0.0", installedVersion: String? = nil) -> TerminalServiceDaemonStatus {
            TerminalServiceDaemonStatus(
                version: version, installedVersion: installedVersion, certificateFingerprint: nil, activeSessionCount: 0,
                protocolVersion: protocolVersion)
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
