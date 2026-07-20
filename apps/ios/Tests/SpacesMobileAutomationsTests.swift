#if canImport(UIKit)
    import XCTest
    import spacesdevicecore
    import spacesterminalcore
    @testable import SpacesMobile

    private actor SpacesMobileAutomationsRequestRecorder {
        private var requests: [SpacesDeviceAPIRequest] = []

        func append(_ request: SpacesDeviceAPIRequest) { requests.append(request) }
        func snapshot() -> [SpacesDeviceAPIRequest] { requests }
    }

    @MainActor final class SpacesMobileAutomationsTests: XCTestCase {
        // MARK: - SpacesMobileAutomations.rows / lastRunStatus

        func testRowsSortByNameAndCarryLastRunStatus() {
            let automations = [makeAutomation(id: "automation-b", name: "Nightly backup"), makeAutomation(id: "automation-a", name: "Deploy")]
            let runs = [
                makeRun(id: "run-1", automationID: "automation-a", status: "succeeded", startedAt: "2026-01-01T00:00:00Z"),
                makeRun(id: "run-2", automationID: "automation-a", status: "failed", startedAt: "2026-01-01T01:00:00Z"),
            ]

            let rows = SpacesMobileAutomations.rows(automations: automations, runs: runs)

            XCTAssertEqual(rows.map(\.automation.id), ["automation-a", "automation-b"])
            XCTAssertEqual(rows.first?.lastRunStatus, "failed")
            XCTAssertNil(rows.last?.lastRunStatus)
        }

        func testLastRunStatusPicksNewestByStartedThenCreated() {
            let runs = [
                makeRun(id: "run-queued", automationID: "automation-a", status: "queued", startedAt: nil, createdAt: "2026-01-01T02:00:00Z"),
                makeRun(id: "run-old", automationID: "automation-a", status: "succeeded", startedAt: "2026-01-01T00:00:00Z"),
            ]

            // The queued run never started, so it sorts by createdAt — newer than the started-and-finished run.
            XCTAssertEqual(SpacesMobileAutomations.lastRunStatus(automationID: "automation-a", in: runs), "queued")
            XCTAssertNil(SpacesMobileAutomations.lastRunStatus(automationID: "automation-missing", in: runs))
        }

        // MARK: - SpacesMobileAutomations.runningCount

        func testRunningCountCountsOnlyRunningRunsAcrossAutomations() {
            let runs = [
                makeRun(id: "run-a-running", automationID: "automation-a", status: "running"),
                makeRun(id: "run-b-running", automationID: "automation-b", status: "running"),
                makeRun(id: "run-a-done", automationID: "automation-a", status: "succeeded"),
                makeRun(id: "run-b-queued", automationID: "automation-b", status: "queued"),
            ]

            XCTAssertEqual(SpacesMobileAutomations.runningCount(runs), 2)
            XCTAssertEqual(SpacesMobileAutomations.runningCount([]), 0)
        }

        // MARK: - SpacesMobileAutomations.runRows

        func testRunRowsFilterByAutomationAndSortNewestFirst() {
            let runs = [
                makeRun(id: "run-a-old", automationID: "automation-a", status: "succeeded", startedAt: "2026-01-01T00:00:00Z"),
                makeRun(id: "run-a-new", automationID: "automation-a", status: "running", startedAt: "2026-01-01T02:00:00Z"),
                makeRun(id: "run-b", automationID: "automation-b", status: "succeeded", startedAt: "2026-01-01T01:00:00Z"),
            ]

            XCTAssertEqual(SpacesMobileAutomations.runRows(runs, automationID: "automation-a").map(\.id), ["run-a-new", "run-a-old"])
            XCTAssertEqual(SpacesMobileAutomations.runRows(runs).map(\.id), ["run-a-new", "run-b", "run-a-old"])
        }

        func testRunRowIsRunningReflectsStatus() {
            let running = SpacesMobileAutomationRunRow(run: makeRun(id: "run-1", automationID: "automation-a", status: "running"))
            let queued = SpacesMobileAutomationRunRow(run: makeRun(id: "run-2", automationID: "automation-a", status: "queued"))

            XCTAssertTrue(running.isRunning)
            XCTAssertFalse(queued.isRunning)
        }

        // MARK: - Formatting helpers

        func testTriggerSummaryDistinguishesManualAndCron() {
            XCTAssertEqual(SpacesMobileAutomations.triggerSummary(makeAutomation(triggerKind: "manual")), "Manual")
            XCTAssertEqual(
                SpacesMobileAutomations.triggerSummary(makeAutomation(triggerKind: "cron", cronExpression: "*/5 * * * *")), "Cron: */5 * * * *")
        }

        func testNextFireDescriptionOnlyForEnabledCronWithFireTime() {
            let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
            let iso = ISO8601DateFormatter().string(from: now.addingTimeInterval(300))

            XCTAssertNil(SpacesMobileAutomations.nextFireDescription(makeAutomation(enabled: true, nextFireTime: nil), relativeTo: now))
            XCTAssertNil(SpacesMobileAutomations.nextFireDescription(makeAutomation(enabled: false, nextFireTime: iso), relativeTo: now))
            XCTAssertNotNil(SpacesMobileAutomations.nextFireDescription(makeAutomation(enabled: true, nextFireTime: iso), relativeTo: now))
        }

        func testRunTriggerLabelMapsKnownRawValues() {
            XCTAssertEqual(SpacesMobileAutomations.runTriggerLabel(makeRun(id: "r", automationID: "a", trigger: "manual")), "Manual")
            XCTAssertEqual(SpacesMobileAutomations.runTriggerLabel(makeRun(id: "r", automationID: "a", trigger: "cron")), "Cron")
            XCTAssertEqual(
                SpacesMobileAutomations.runTriggerLabel(makeRun(id: "r", automationID: "a", trigger: "missed_catch_up")), "Missed catch-up")
        }

        func testStartedAndDurationDescriptionsRequireAStartTime() {
            let now = Date(timeIntervalSinceReferenceDate: 2_000_000)
            let started = ISO8601DateFormatter().string(from: now.addingTimeInterval(-90))
            let queued = makeRun(id: "r", automationID: "a", status: "queued", startedAt: nil)
            let running = makeRun(id: "r", automationID: "a", status: "running", startedAt: started, endedAt: nil)

            XCTAssertNil(SpacesMobileAutomations.startedDescription(queued, relativeTo: now))
            XCTAssertNil(SpacesMobileAutomations.durationDescription(queued, relativeTo: now))
            XCTAssertNotNil(SpacesMobileAutomations.startedDescription(running, relativeTo: now))
            // Still running: duration measures against `now`, not an end time, so it keeps advancing. Compare
            // against a formatter built the same way rather than a hardcoded string, so the assertion does
            // not depend on the test host's locale.
            let expectedFormatter = DateComponentsFormatter()
            expectedFormatter.allowedUnits = [.hour, .minute, .second]
            expectedFormatter.unitsStyle = .abbreviated
            expectedFormatter.maximumUnitCount = 2
            XCTAssertEqual(SpacesMobileAutomations.durationDescription(running, relativeTo: now), expectedFormatter.string(from: 90))
        }

        func testSkipReasonLabelsAreHumanReadable() {
            XCTAssertEqual(SpacesMobileAutomations.skipReasonLabel("concurrency"), "already running")
            XCTAssertEqual(SpacesMobileAutomations.skipReasonLabel("missed"), "missed occurrence")
            XCTAssertEqual(SpacesMobileAutomations.skipReasonLabel("something-else"), "something-else")
        }

        // MARK: - StatusDot.Kind(automationRunStatus:)

        func testStatusDotKindMapsRunStatusToThreeWaySignal() {
            XCTAssertEqual(StatusDot.Kind(automationRunStatus: "running"), .running)
            XCTAssertEqual(StatusDot.Kind(automationRunStatus: "succeeded"), .done)
            XCTAssertEqual(StatusDot.Kind(automationRunStatus: "failed"), .exited)
            XCTAssertEqual(StatusDot.Kind(automationRunStatus: "timed_out"), .exited)
            XCTAssertEqual(StatusDot.Kind(automationRunStatus: "queued"), .idle)
            XCTAssertEqual(StatusDot.Kind(automationRunStatus: "canceled"), .idle)
            XCTAssertEqual(StatusDot.Kind(automationRunStatus: "skipped"), .idle)
            XCTAssertEqual(StatusDot.Kind(automationRunStatus: nil), .idle)
        }

        // MARK: - SpacesMobileAutomations.excerpt

        func testExcerptPicksPromptForAgentKindAndScriptForScriptKind() {
            let agentAutomation = makeAutomation(kind: "agent", script: "", agentPrompt: "\n  Fix the flaky test \n\nMore detail")
            let scriptAutomation = makeAutomation(kind: "script", script: "\n  echo hello \nmore lines")

            XCTAssertEqual(SpacesMobileAutomations.excerpt(agentAutomation), "Fix the flaky test")
            XCTAssertEqual(SpacesMobileAutomations.excerpt(scriptAutomation), "echo hello")
        }

        func testExcerptEmptyWhenSourceHasNoContent() {
            XCTAssertEqual(SpacesMobileAutomations.excerpt(makeAutomation(kind: "agent", script: "", agentPrompt: nil)), "")
            XCTAssertEqual(SpacesMobileAutomations.excerpt(makeAutomation(kind: "script", script: "")), "")
        }

        // MARK: - SpacesMobileAutomations.workspaceName

        func testWorkspaceNameResolvesFromOverviewOrOmits() {
            let workspaces = [makeWorkspace(id: "workspace-1", branch: "feature/x")]
            let agentAutomation = makeAutomation(kind: "agent", workspaceID: "workspace-1")
            let unresolvableAutomation = makeAutomation(kind: "agent", workspaceID: "workspace-missing")
            let scriptAutomation = makeAutomation(kind: "script", workspaceID: nil)

            XCTAssertEqual(SpacesMobileAutomations.workspaceName(for: agentAutomation, in: workspaces), "feature/x")
            XCTAssertNil(SpacesMobileAutomations.workspaceName(for: unresolvableAutomation, in: workspaces))
            XCTAssertNil(SpacesMobileAutomations.workspaceName(for: scriptAutomation, in: workspaces))
        }

        // MARK: - SpacesMobileAutomations.endAgentsAvailable

        func testEndAgentsAvailableRequiresTerminalStatusAndLiveAgent() {
            let liveAgent = makeAgentSummary(terminalSessionID: "agent-1", live: true)
            let settledAgent = makeAgentSummary(terminalSessionID: "agent-2", live: false)

            XCTAssertTrue(SpacesMobileAutomations.endAgentsAvailable(makeRun(id: "r", automationID: "a", status: "succeeded", attributedAgents: [liveAgent])))
            XCTAssertFalse(
                SpacesMobileAutomations.endAgentsAvailable(makeRun(id: "r", automationID: "a", status: "succeeded", attributedAgents: [settledAgent])))
            XCTAssertFalse(
                SpacesMobileAutomations.endAgentsAvailable(makeRun(id: "r", automationID: "a", status: "running", attributedAgents: [liveAgent])))
            XCTAssertFalse(
                SpacesMobileAutomations.endAgentsAvailable(makeRun(id: "r", automationID: "a", status: "queued", attributedAgents: [liveAgent])))
            XCTAssertFalse(SpacesMobileAutomations.endAgentsAvailable(makeRun(id: "r", automationID: "a", status: "failed", attributedAgents: [])))
        }

        // MARK: - StatusDot.Kind(agentStatus:live:)

        func testAgentStatusDotKindMapsAgentWindowStatusToDotSignal() {
            XCTAssertEqual(StatusDot.Kind(agentStatus: "waiting", live: true), .waiting)
            XCTAssertEqual(StatusDot.Kind(agentStatus: "done", live: true), .done)
            XCTAssertEqual(StatusDot.Kind(agentStatus: "spinning", live: true), .running)
            XCTAssertEqual(StatusDot.Kind(agentStatus: "exited", live: true), .exited)
            XCTAssertEqual(StatusDot.Kind(agentStatus: "exited", live: false), .exited)
            // Idle means no agent row yet (including the detection-pending phase of a starting run): a
            // still-live bare terminal reads as running, a settled one reads as idle.
            XCTAssertEqual(StatusDot.Kind(agentStatus: "idle", live: true), .running)
            XCTAssertEqual(StatusDot.Kind(agentStatus: "idle", live: false), .idle)
        }

        // MARK: - Attributed agents decode

        func testRunSummaryCarriesAttributedAgents() {
            let agent = makeAgentSummary(terminalSessionID: "agent-1", status: "spinning", live: true, title: "Fix flaky test", workspaceID: "workspace-1")
            let run = makeRun(id: "r", automationID: "a", status: "running", attributedAgents: [agent])

            XCTAssertEqual(run.attributedAgents.count, 1)
            XCTAssertEqual(run.attributedAgents.first?.terminalSessionID, "agent-1")
            XCTAssertEqual(run.attributedAgents.first?.status, "spinning")
            XCTAssertEqual(run.attributedAgents.first?.title, "Fix flaky test")
            XCTAssertEqual(run.attributedAgents.first?.workspaceID, "workspace-1")
        }

        // MARK: - SpacesMobileAutomationAlerts

        func testAlertEntriesOnlyIncludeFailedAndTimedOutNewestFirst() {
            let runs = [
                makeRun(id: "run-ok", automationID: "a", automationName: "Deploy", status: "succeeded", endedAt: "2026-01-01T03:00:00Z"),
                makeRun(
                    id: "run-failed", automationID: "a", automationName: "Deploy", status: "failed", exitCode: 3, endedAt: "2026-01-01T00:00:00Z"),
                makeRun(id: "run-timeout", automationID: "b", automationName: "Nightly", status: "timed_out", endedAt: "2026-01-01T01:00:00Z"),
            ]

            let entries = SpacesMobileAutomationAlerts.entries(runs: runs)

            XCTAssertEqual(entries.map(\.runID), ["run-timeout", "run-failed"])
            XCTAssertEqual(entries.first?.automationName, "Nightly")
            XCTAssertEqual(entries.first?.outcome, "Timed out")
            XCTAssertEqual(entries.last?.outcome, "Failed (exit 3)")
        }

        // MARK: - Model integration

        func testModelAutomationRowsReflectOverview() {
            let model = makeModel()
            model.overview = makeOverview(
                automations: [makeAutomation(id: "automation-a", name: "Deploy")],
                automationRuns: [makeRun(id: "run-1", automationID: "automation-a", status: "running")])

            XCTAssertEqual(model.automationRows.map(\.automation.id), ["automation-a"])
            XCTAssertEqual(model.automationRows.first?.lastRunStatus, "running")
        }

        func testModelAutomationRowsEmptyWhenNoAutomations() {
            let model = makeModel()
            model.overview = makeOverview()

            // Drives the Automations tab's empty state (`AutomationsListView.content`): no automations on
            // the active device means an empty `automationRows`, which the view reads to show the
            // feature-pitch `ContentUnavailableView` instead of the list.
            XCTAssertTrue(model.automationRows.isEmpty)
        }

        func testModelAutomationRunningRunCountReflectsOverview() {
            let model = makeModel()
            model.overview = makeOverview(
                automations: [makeAutomation(id: "automation-a", name: "Deploy"), makeAutomation(id: "automation-b", name: "Backup")],
                automationRuns: [
                    makeRun(id: "run-a", automationID: "automation-a", status: "running"),
                    makeRun(id: "run-b", automationID: "automation-b", status: "running"),
                    makeRun(id: "run-a-old", automationID: "automation-a", status: "succeeded"),
                ])

            // Drives the Automations tab's badge (`RootTabView`'s `.badge(model.automationRunningRunCount)`,
            // which SwiftUI hides automatically at 0): two automations both mid-run count as 2, regardless
            // of how many finished runs also exist.
            XCTAssertEqual(model.automationRunningRunCount, 2)

            model.overview = makeOverview()
            XCTAssertEqual(model.automationRunningRunCount, 0)
        }

        func testUndismissedAlertCountAndClearIncludeAutomationAlerts() {
            let model = makeModel()
            model.overview = makeOverview(automationRuns: [makeRun(id: "run-failed", automationID: "a", automationName: "Deploy", status: "failed")])

            XCTAssertEqual(model.automationAlerts.count, 1)
            XCTAssertEqual(model.undismissedAlertCount, 1)

            model.clearAlerts()

            XCTAssertEqual(model.automationAlerts.count, 0)
            XCTAssertEqual(model.undismissedAlertCount, 0)
        }

        func testTriggerAutomationSendsTriggerThenReloadsOverview() async {
            let recorder = SpacesMobileAutomationsRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let triggeredRun = makeRun(id: "run-new", automationID: "automation-a", status: "running")
            let refreshedOverview = makeOverview(automations: [makeAutomation(id: "automation-a", name: "Deploy")], automationRuns: [triggeredRun])
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                if request.commandName == "triggerAutomation" {
                    return SpacesDeviceAPIResponse(ok: true, message: "Triggered automation.", result: .automationRuns(.init(rows: [triggeredRun])))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "loaded", result: .overview(refreshedOverview))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)

            await model.triggerAutomation(id: "automation-a")

            let requests = await recorder.snapshot()
            XCTAssertEqual(requests.map(\.commandName), ["triggerAutomation", "overview"])
            guard case .triggerAutomation(let payload)? = requests.first?.command else {
                XCTFail("Expected triggerAutomation request.")
                return
            }
            XCTAssertEqual(payload.id, "automation-a")
            XCTAssertEqual(model.automationRows.first?.lastRunStatus, "running")
            XCTAssertFalse(model.isMutating)
            XCTAssertNil(model.errorMessage)
        }

        func testCancelAutomationRunSendsCancelThenReloadsOverview() async {
            let recorder = SpacesMobileAutomationsRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let canceledRun = makeRun(id: "run-1", automationID: "automation-a", status: "canceled")
            let refreshedOverview = makeOverview(automations: [makeAutomation(id: "automation-a", name: "Deploy")], automationRuns: [canceledRun])
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                if request.commandName == "cancelAutomationRun" {
                    return SpacesDeviceAPIResponse(ok: true, message: "Canceled automation run.", result: .automationRuns(.init(rows: [canceledRun])))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "loaded", result: .overview(refreshedOverview))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)

            await model.cancelAutomationRun(runID: "run-1")

            let requests = await recorder.snapshot()
            XCTAssertEqual(requests.map(\.commandName), ["cancelAutomationRun", "overview"])
            guard case .cancelAutomationRun(let payload)? = requests.first?.command else {
                XCTFail("Expected cancelAutomationRun request.")
                return
            }
            XCTAssertEqual(payload.runID, "run-1")
            XCTAssertEqual(model.automationRows.first?.lastRunStatus, "canceled")
            XCTAssertFalse(model.isMutating)
            XCTAssertNil(model.errorMessage)
        }

        func testEndAutomationAgentsSendsEndAgentsThenReloadsOverview() async {
            let recorder = SpacesMobileAutomationsRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let settledAgent = makeAgentSummary(terminalSessionID: "agent-1", status: "exited", live: false)
            let endedRun = makeRun(id: "run-1", automationID: "automation-a", status: "succeeded", attributedAgents: [settledAgent])
            let refreshedOverview = makeOverview(automations: [makeAutomation(id: "automation-a", name: "Deploy")], automationRuns: [endedRun])
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                if request.commandName == "endAutomationAgents" {
                    return SpacesDeviceAPIResponse(ok: true, message: "Ended automation agents.", result: .automationRuns(.init(rows: [endedRun])))
                }
                return SpacesDeviceAPIResponse(ok: true, message: "loaded", result: .overview(refreshedOverview))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)

            await model.endAutomationAgents(runID: "run-1")

            let requests = await recorder.snapshot()
            XCTAssertEqual(requests.map(\.commandName), ["endAutomationAgents", "overview"])
            guard case .endAutomationAgents(let payload)? = requests.first?.command else {
                XCTFail("Expected endAutomationAgents request.")
                return
            }
            XCTAssertEqual(payload.runID, "run-1")
            XCTAssertFalse(model.isMutating)
            XCTAssertNil(model.errorMessage)
        }

        // MARK: - Fixtures

        private func makeModel() -> SpacesMobileAppModel {
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in SpacesDeviceAPIResponse(ok: true, message: "ok") }
            return SpacesMobileAppModel(settings: settings, bridgeClient: client)
        }

        private func makeOverview(automations: [TerminalServiceAutomationSummary] = [], automationRuns: [TerminalServiceAutomationRunSummary] = [])
            -> SpacesDeviceOverviewPayload
        {
            SpacesDeviceOverviewPayload(
                workspaces: [], sessions: [],
                daemonStatus: TerminalServiceDaemonStatus(
                    version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0,
                    protocolVersion: SpacesWireProtocol.version), automations: automations, automationRuns: automationRuns)
        }

        private func makeWorkspace(id: String, branch: String?) -> SpacesDeviceWorkspaceSummary {
            SpacesDeviceWorkspaceSummary(
                id: id, projectID: "project-1", projectName: "Project", branch: branch, baseBranch: nil, dir: "/tmp/\(id)", isRunning: false,
                isArchived: false, isHidden: false, isDefault: false, sessionCount: 0)
        }

        private func makeAgentSummary(
            terminalSessionID: String, status: String = "idle", live: Bool = true, title: String? = "Agent", workspaceID: String? = "workspace-1"
        ) -> TerminalServiceAutomationAgentSummary {
            TerminalServiceAutomationAgentSummary(terminalSessionID: terminalSessionID, status: status, live: live, title: title, workspaceID: workspaceID)
        }

        private func makeAutomation(
            id: String = "automation-a", name: String = "Automation", enabled: Bool = true, triggerKind: String = "manual",
            cronExpression: String? = nil, kind: String = "script", script: String = "echo hi", agentPrompt: String? = nil,
            workspaceID: String? = nil, nextFireTime: String? = nil
        ) -> TerminalServiceAutomationSummary {
            TerminalServiceAutomationSummary(
                id: id, name: name, enabled: enabled, triggerKind: triggerKind, cronExpression: cronExpression, kind: kind, script: script,
                agentPrompt: agentPrompt, workspaceID: workspaceID,
                workingDirectory: "/tmp", timeoutSeconds: nil, concurrencyPolicy: "skip", missedRunPolicy: "skip", nextFireTime: nextFireTime,
                createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
        }

        private func makeRun(
            id: String, automationID: String, automationName: String? = nil, status: String = "queued", trigger: String = "manual",
            exitCode: Int? = nil, startedAt: String? = "2026-01-01T00:00:00Z", endedAt: String? = nil, createdAt: String = "2026-01-01T00:00:00Z",
            attributedAgents: [TerminalServiceAutomationAgentSummary] = []
        ) -> TerminalServiceAutomationRunSummary {
            TerminalServiceAutomationRunSummary(
                id: id, automationID: automationID, automationName: automationName, status: status, trigger: trigger, skipReason: nil,
                exitCode: exitCode, terminalSessionID: nil, startedAt: startedAt, endedAt: endedAt, createdAt: createdAt,
                attributedAgents: attributedAgents)
        }
    }
#endif
