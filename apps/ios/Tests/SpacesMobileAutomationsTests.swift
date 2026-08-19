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

    /// Holds one automation request until the test changes the model's connection identity, making a
    /// response from the previous device deterministic.
    private actor SpacesMobileAutomationsAsyncGate {
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

        func testMergedRunRowsPrefersOverviewStatusAndKeepsHistoryTail() {
            // "run-live" is running in the retained history (as it was when the screen first fetched it)
            // but has since finished in the overview — the live overview snapshot must win so the row
            // reflects the real outcome instead of freezing on "running".
            let historyRuns = [
                makeRun(id: "run-live", automationID: "automation-a", status: "running", startedAt: "2026-01-01T02:00:00Z"),
                makeRun(id: "run-old", automationID: "automation-a", status: "succeeded", startedAt: "2026-01-01T00:00:00Z"),
            ]
            let overviewRuns = [
                makeRun(id: "run-live", automationID: "automation-a", status: "succeeded", startedAt: "2026-01-01T02:00:00Z"),
                // A brand-new run that fired after the initial fetch, so it only exists in the overview.
                makeRun(id: "run-new", automationID: "automation-a", status: "running", startedAt: "2026-01-01T03:00:00Z"),
            ]

            let rows = SpacesMobileAutomations.mergedRunRows(overviewRuns: overviewRuns, historyRuns: historyRuns, automationID: "automation-a")

            XCTAssertEqual(rows.map(\.id), ["run-new", "run-live", "run-old"])
            XCTAssertEqual(rows.first(where: { $0.id == "run-live" })?.run.status, "succeeded")
            XCTAssertFalse(rows.first(where: { $0.id == "run-live" })?.isRunning ?? true)
        }

        func testMergedRunRowsFiltersToRequestedAutomation() {
            let historyRuns = [makeRun(id: "run-other", automationID: "automation-b", status: "succeeded")]
            let overviewRuns = [makeRun(id: "run-mine", automationID: "automation-a", status: "running")]

            let rows = SpacesMobileAutomations.mergedRunRows(overviewRuns: overviewRuns, historyRuns: historyRuns, automationID: "automation-a")

            XCTAssertEqual(rows.map(\.id), ["run-mine"])
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

        func testNextRunChipValueFallsBackToNotScheduledPlaceholder() {
            let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
            let iso = ISO8601DateFormatter().string(from: now.addingTimeInterval(300))

            XCTAssertEqual(
                SpacesMobileAutomations.nextRunChipValue(makeAutomation(enabled: true, triggerKind: "cron", nextFireTime: iso), relativeTo: now),
                SpacesMobileAutomations.nextFireDescription(makeAutomation(enabled: true, triggerKind: "cron", nextFireTime: iso), relativeTo: now))
            XCTAssertEqual(
                SpacesMobileAutomations.nextRunChipValue(makeAutomation(enabled: true, nextFireTime: nil), relativeTo: now), "Not scheduled")
            XCTAssertEqual(
                SpacesMobileAutomations.nextRunChipValue(makeAutomation(enabled: false, triggerKind: "cron", nextFireTime: iso), relativeTo: now),
                "Not scheduled")
        }

        func testNextRunSummaryNamesScheduledNotScheduledAndManual() {
            let fireDate = Date(timeIntervalSinceReferenceDate: 1_000_000)
            let iso = ISO8601DateFormatter().string(from: fireDate)
            let expectedFormatter = DateFormatter()
            expectedFormatter.dateStyle = .medium
            expectedFormatter.timeStyle = .short

            XCTAssertEqual(
                SpacesMobileAutomations.nextRunSummary(makeAutomation(triggerKind: "cron", nextFireTime: iso)),
                "Scheduled: \(expectedFormatter.string(from: fireDate))")
            XCTAssertEqual(SpacesMobileAutomations.nextRunSummary(makeAutomation(triggerKind: "cron", nextFireTime: nil)), "Not scheduled")
            XCTAssertEqual(SpacesMobileAutomations.nextRunSummary(makeAutomation(triggerKind: "manual", nextFireTime: nil)), "Manual")
            // A one-time override on a manual automation arrives as a next fire time, so the sheet reports
            // the scheduled instant rather than calling the automation manual.
            XCTAssertEqual(
                SpacesMobileAutomations.nextRunSummary(makeAutomation(triggerKind: "manual", nextFireTime: iso)),
                "Scheduled: \(expectedFormatter.string(from: fireDate))")
        }

        func testNextRunValidationRejectsInstantsThatAreNotInTheFuture() {
            let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

            XCTAssertNil(SpacesMobileAutomations.nextRunValidationMessage(for: now.addingTimeInterval(60), relativeTo: now))
            XCTAssertNotNil(SpacesMobileAutomations.nextRunValidationMessage(for: now, relativeTo: now))
            XCTAssertNotNil(SpacesMobileAutomations.nextRunValidationMessage(for: now.addingTimeInterval(-1), relativeTo: now))
        }

        func testRunTriggerLabelMapsKnownRawValues() {
            XCTAssertEqual(SpacesMobileAutomations.runTriggerLabel(makeRun(id: "r", automationID: "a", trigger: "manual")), "Manual")
            XCTAssertEqual(SpacesMobileAutomations.runTriggerLabel(makeRun(id: "r", automationID: "a", trigger: "cron")), "Cron")
            XCTAssertEqual(SpacesMobileAutomations.runTriggerLabel(makeRun(id: "r", automationID: "a", trigger: "scheduled")), "Scheduled")
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

        // MARK: - SpacesMobileAutomations.statusTitle

        func testStatusTitleMapsKnownRawValuesWithFallbackForUnknown() {
            XCTAssertEqual(SpacesMobileAutomations.statusTitle(makeRun(id: "r", automationID: "a", status: "queued")), "Queued")
            XCTAssertEqual(SpacesMobileAutomations.statusTitle(makeRun(id: "r", automationID: "a", status: "running")), "Running")
            XCTAssertEqual(SpacesMobileAutomations.statusTitle(makeRun(id: "r", automationID: "a", status: "succeeded")), "Succeeded")
            XCTAssertEqual(SpacesMobileAutomations.statusTitle(makeRun(id: "r", automationID: "a", status: "failed")), "Failed")
            XCTAssertEqual(SpacesMobileAutomations.statusTitle(makeRun(id: "r", automationID: "a", status: "timed_out")), "Timed out")
            XCTAssertEqual(SpacesMobileAutomations.statusTitle(makeRun(id: "r", automationID: "a", status: "canceled")), "Canceled")
            XCTAssertEqual(SpacesMobileAutomations.statusTitle(makeRun(id: "r", automationID: "a", status: "skipped")), "Skipped")
            XCTAssertEqual(SpacesMobileAutomations.statusTitle(makeRun(id: "r", automationID: "a", status: "something-else")), "Something-Else")
        }

        func testSkipReasonLabelsAreHumanReadable() {
            XCTAssertEqual(SpacesMobileAutomations.skipReasonLabel("concurrency"), "already running")
            XCTAssertEqual(SpacesMobileAutomations.skipReasonLabel("missed"), "missed occurrence")
            XCTAssertEqual(SpacesMobileAutomations.skipReasonLabel("something-else"), "something-else")
        }

        // MARK: - StatusDot.Kind(automationRunStatus:)

        func testStatusDotKindMapsRunStatusToThreeWaySignal() {
            XCTAssertEqual(StatusDot.Kind(automationRunStatus: "running"), .running)
            XCTAssertEqual(StatusDot.Kind(automationRunStatus: "succeeded"), .succeeded)
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
            let scriptAutomation = makeAutomation(kind: "script", workspaceID: "workspace-missing")

            XCTAssertEqual(SpacesMobileAutomations.workspaceName(for: agentAutomation, in: workspaces), "feature/x")
            XCTAssertNil(SpacesMobileAutomations.workspaceName(for: unresolvableAutomation, in: workspaces))
            XCTAssertNil(SpacesMobileAutomations.workspaceName(for: scriptAutomation, in: workspaces))
        }

        // MARK: - SpacesMobileAutomations.endAgentsAvailable

        func testEndAgentsAvailableRequiresTerminalStatusAndLiveAgent() {
            let liveAgent = makeAgentSummary(terminalSessionID: "agent-1", live: true)
            let settledAgent = makeAgentSummary(terminalSessionID: "agent-2", live: false)

            XCTAssertTrue(
                SpacesMobileAutomations.endAgentsAvailable(makeRun(id: "r", automationID: "a", status: "succeeded", attributedAgents: [liveAgent])))
            XCTAssertFalse(
                SpacesMobileAutomations.endAgentsAvailable(makeRun(id: "r", automationID: "a", status: "succeeded", attributedAgents: [settledAgent]))
            )
            XCTAssertFalse(
                SpacesMobileAutomations.endAgentsAvailable(makeRun(id: "r", automationID: "a", status: "running", attributedAgents: [liveAgent])))
            XCTAssertFalse(
                SpacesMobileAutomations.endAgentsAvailable(makeRun(id: "r", automationID: "a", status: "queued", attributedAgents: [liveAgent])))
            XCTAssertFalse(SpacesMobileAutomations.endAgentsAvailable(makeRun(id: "r", automationID: "a", status: "failed", attributedAgents: [])))
        }

        // MARK: - SpacesMobileAutomations.runIsNavigable / runSession

        func testRunIsNavigableRequiresASessionAndExcludesSkippedAndQueued() {
            XCTAssertFalse(SpacesMobileAutomations.runIsNavigable(makeRun(id: "r", automationID: "a", status: "succeeded", terminalSessionID: nil)))
            XCTAssertFalse(SpacesMobileAutomations.runIsNavigable(makeRun(id: "r", automationID: "a", status: "skipped", terminalSessionID: "s")))
            XCTAssertFalse(SpacesMobileAutomations.runIsNavigable(makeRun(id: "r", automationID: "a", status: "queued", terminalSessionID: "s")))
            for status in ["failed", "succeeded", "running", "timed_out", "canceled"] {
                XCTAssertTrue(
                    SpacesMobileAutomations.runIsNavigable(makeRun(id: "r", automationID: "a", status: status, terminalSessionID: "s")),
                    "expected \(status) with a session to be navigable")
            }
        }

        func testRunSessionReturnsNilWhenNotNavigable() {
            let run = makeRun(id: "r", automationID: "a", status: "queued", terminalSessionID: "s")
            XCTAssertNil(SpacesMobileAutomations.runSession(for: run, overview: nil))
        }

        func testRunSessionPrefersTheOverviewSessionOverSynthesizing() {
            let overviewSession = makeSession(id: "session-1", title: "Live Title")
            let overview = makeOverview(sessions: [overviewSession])
            let run = makeRun(id: "r", automationID: "a", automationName: "Nightly", status: "succeeded", terminalSessionID: "session-1")

            let resolved = SpacesMobileAutomations.runSession(for: run, overview: overview)

            // The overview's own instance wins (its title), not a synthesized "Nightly" title.
            XCTAssertEqual(resolved?.title, "Live Title")
        }

        func testRunSessionSynthesizesRunningVersusEndedState() {
            let runningRun = makeRun(
                id: "r-running", automationID: "a", automationName: "Deploy", status: "running", terminalSessionID: "session-running",
                workspaceID: "workspace-1")
            let succeededRun = makeRun(
                id: "r-done", automationID: "a", automationName: "Deploy", status: "succeeded", terminalSessionID: "session-done",
                workspaceID: "workspace-1")

            let runningSession = SpacesMobileAutomations.runSession(for: runningRun, overview: nil)
            let doneSession = SpacesMobileAutomations.runSession(for: succeededRun, overview: nil)

            XCTAssertEqual(runningSession?.state, .running)
            XCTAssertEqual(runningSession?.isControlAvailable, true)
            XCTAssertEqual(runningSession?.isSubscriptionAvailable, true)
            XCTAssertEqual(runningSession?.title, "Deploy")
            XCTAssertEqual(runningSession?.workspaceID, "workspace-1")

            XCTAssertEqual(doneSession?.state, .exited)
            XCTAssertEqual(doneSession?.isControlAvailable, false)
            XCTAssertEqual(doneSession?.isSubscriptionAvailable, false)
        }

        // MARK: - SpacesMobileAutomations.agentSession

        func testAgentSessionPrefersOverviewSessionOverSynthesizing() {
            let overviewSession = makeSession(id: "agent-session-1", title: "Live Agent Title")
            let overview = makeOverview(sessions: [overviewSession])
            let agent = makeAgentSummary(terminalSessionID: "agent-session-1", live: true, title: "Synthesized Title")

            let resolved = SpacesMobileAutomations.agentSession(for: agent, overview: overview)

            XCTAssertEqual(resolved?.title, "Live Agent Title")
        }

        func testAgentSessionSynthesizesLiveVersusNotLiveState() {
            let liveAgent = makeAgentSummary(terminalSessionID: "agent-1", live: true, title: "Agent One", workspaceID: "workspace-1")
            let settledAgent = makeAgentSummary(terminalSessionID: "agent-2", live: false, title: "Agent Two", workspaceID: "workspace-1")

            let liveSession = SpacesMobileAutomations.agentSession(for: liveAgent, overview: nil)
            let settledSession = SpacesMobileAutomations.agentSession(for: settledAgent, overview: nil)

            XCTAssertEqual(liveSession?.state, .running)
            XCTAssertEqual(liveSession?.isControlAvailable, true)
            XCTAssertEqual(liveSession?.title, "Agent One")
            XCTAssertEqual(liveSession?.workspaceID, "workspace-1")

            XCTAssertEqual(settledSession?.state, .exited)
            XCTAssertEqual(settledSession?.isControlAvailable, false)
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
            let agent = makeAgentSummary(
                terminalSessionID: "agent-1", status: "spinning", live: true, title: "Fix flaky test", workspaceID: "workspace-1")
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

        func testAlertEntriesUseFractionalWireTimestampsForSameSecondRuns() {
            let runs = [
                makeRun(id: "older", automationID: "a", automationName: "Deploy", status: "failed", endedAt: "2026-01-01T00:00:00.125Z"),
                makeRun(id: "newer", automationID: "a", automationName: "Deploy", status: "failed", endedAt: "2026-01-01T00:00:00.875Z"),
            ]

            XCTAssertEqual(SpacesMobileAutomationAlerts.entries(runs: runs).map(\.runID), ["newer", "older"])
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

        func testDismissAutomationAlertRemovesOnlyThatRunAlert() {
            let model = makeModel()
            model.overview = makeOverview(automationRuns: [
                makeRun(id: "run-a", automationID: "a", automationName: "Deploy", status: "failed"),
                makeRun(id: "run-b", automationID: "b", automationName: "Backup", status: "timed_out"),
            ])
            let dismissed = model.automationAlerts.first { $0.runID == "run-a" }!

            model.dismissAutomationAlert(dismissed)

            XCTAssertEqual(model.automationAlerts.map(\.runID), ["run-b"])
            XCTAssertEqual(model.undismissedAlertCount, 1)
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

        func testSetAutomationNextRunSendsTheScheduleThenReloadsOverview() async {
            let recorder = SpacesMobileAutomationsRequestRecorder()
            let settings = SpacesMobileConnectionSettings()
            let nextRun = Date(timeIntervalSinceReferenceDate: 1_000_000)
            let scheduled = makeAutomation(
                id: "automation-a", name: "Deploy", triggerKind: "cron", nextFireTime: TerminalSessionTimestamp.fractionalString(from: nextRun))
            let refreshedOverview = makeOverview(automations: [scheduled])
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                await recorder.append(request)
                if request.commandName == "setAutomationNextRun" { return SpacesDeviceAPIResponse(ok: true, message: "Scheduled next run.") }
                return SpacesDeviceAPIResponse(ok: true, message: "loaded", result: .overview(refreshedOverview))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)

            let rejection = await model.setAutomationNextRun(id: "automation-a", nextRunTime: nextRun)

            XCTAssertNil(rejection)
            let requests = await recorder.snapshot()
            XCTAssertEqual(requests.map(\.commandName), ["setAutomationNextRun", "overview"])
            guard case .setAutomationNextRun(let payload)? = requests.first?.command else {
                XCTFail("Expected setAutomationNextRun request.")
                return
            }
            XCTAssertEqual(payload.id, "automation-a")
            XCTAssertEqual(payload.nextRunTime, TerminalSessionTimestamp.fractionalString(from: nextRun))
            XCTAssertEqual(model.automationRows.first?.automation.nextFireTime, scheduled.nextFireTime)
            XCTAssertFalse(model.isMutating)
            XCTAssertNil(model.errorMessage)
        }

        /// The sheet shows the daemon's refusal beside its picker, so the rejection comes back to the
        /// caller instead of raising the app-wide error banner behind the sheet.
        func testSetAutomationNextRunReturnsTheDaemonRefusalWithoutRaisingTheErrorBanner() async {
            let settings = SpacesMobileConnectionSettings()
            let overview = makeOverview()
            let client = SpacesDeviceAPIClient(settings: settings) { request in
                if request.commandName == "setAutomationNextRun" {
                    return SpacesDeviceAPIResponse(ok: false, message: "Enable the automation to schedule its next run.")
                }
                return SpacesDeviceAPIResponse(ok: true, message: "loaded", result: .overview(overview))
            }
            let model = SpacesMobileAppModel(settings: settings, bridgeClient: client)

            let rejection = await model.setAutomationNextRun(id: "automation-a", nextRunTime: Date(timeIntervalSinceReferenceDate: 1_000_000))

            XCTAssertEqual(rejection, "Enable the automation to schedule its next run.")
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.isMutating)
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

        func testTriggerAutomationDoesNotRefreshAfterConnectionChanges() async {
            let gate = SpacesMobileAutomationsAsyncGate()
            let staleOverview = makeOverview(
                automations: [makeAutomation(id: "old-automation", name: "Old device")],
                automationRuns: [makeRun(id: "old-run", automationID: "old-automation", status: "running")])
            let client = SpacesDeviceAPIClient(settings: SpacesMobileConnectionSettings()) { request in
                if request.commandName == "triggerAutomation" { await gate.wait() }
                return SpacesDeviceAPIResponse(ok: true, message: "ok", result: request.commandName == "overview" ? .overview(staleOverview) : nil)
            }
            let model = SpacesMobileAppModel(settings: SpacesMobileConnectionSettings(), bridgeClient: client)

            let task = Task { await model.triggerAutomation(id: "old-automation") }
            await Task.yield()
            model.handleAuthenticationFailure(message: "Switched devices.")
            await gate.open()
            await task.value

            XCTAssertNil(model.overview)
        }

        func testCancelAutomationRunDoesNotRefreshAfterConnectionChanges() async {
            let gate = SpacesMobileAutomationsAsyncGate()
            let staleOverview = makeOverview(automationRuns: [makeRun(id: "old-run", automationID: "old-automation", status: "canceled")])
            let client = SpacesDeviceAPIClient(settings: SpacesMobileConnectionSettings()) { request in
                if request.commandName == "cancelAutomationRun" { await gate.wait() }
                return SpacesDeviceAPIResponse(ok: true, message: "ok", result: request.commandName == "overview" ? .overview(staleOverview) : nil)
            }
            let model = SpacesMobileAppModel(settings: SpacesMobileConnectionSettings(), bridgeClient: client)

            let task = Task { await model.cancelAutomationRun(runID: "old-run") }
            await Task.yield()
            model.handleAuthenticationFailure(message: "Switched devices.")
            await gate.open()
            await task.value

            XCTAssertNil(model.overview)
        }

        func testEndAutomationAgentsDoesNotRefreshAfterConnectionChanges() async {
            let gate = SpacesMobileAutomationsAsyncGate()
            let staleOverview = makeOverview(automationRuns: [makeRun(id: "old-run", automationID: "old-automation", status: "succeeded")])
            let client = SpacesDeviceAPIClient(settings: SpacesMobileConnectionSettings()) { request in
                if request.commandName == "endAutomationAgents" { await gate.wait() }
                return SpacesDeviceAPIResponse(ok: true, message: "ok", result: request.commandName == "overview" ? .overview(staleOverview) : nil)
            }
            let model = SpacesMobileAppModel(settings: SpacesMobileConnectionSettings(), bridgeClient: client)

            let task = Task { await model.endAutomationAgents(runID: "old-run") }
            await Task.yield()
            model.handleAuthenticationFailure(message: "Switched devices.")
            await gate.open()
            await task.value

            XCTAssertNil(model.overview)
        }

        func testFetchAutomationRunsDiscardsResultAfterConnectionChanges() async {
            let gate = SpacesMobileAutomationsAsyncGate()
            let staleRuns = [makeRun(id: "old-run", automationID: "old-automation", status: "succeeded")]
            let client = SpacesDeviceAPIClient(settings: SpacesMobileConnectionSettings()) { request in
                if request.commandName == "listAutomationRuns" { await gate.wait() }
                return SpacesDeviceAPIResponse(ok: true, message: "ok", result: .automationRuns(.init(rows: staleRuns)))
            }
            let model = SpacesMobileAppModel(settings: SpacesMobileConnectionSettings(), bridgeClient: client)

            let task = Task { await model.fetchAutomationRuns(automationID: "old-automation") }
            await Task.yield()
            model.handleAuthenticationFailure(message: "Switched devices.")
            await gate.open()

            let result = await task.value
            XCTAssertNil(result)
        }

        // MARK: - Fixtures

        private func makeModel() -> SpacesMobileAppModel {
            let settings = SpacesMobileConnectionSettings()
            let client = SpacesDeviceAPIClient(settings: settings) { _ in SpacesDeviceAPIResponse(ok: true, message: "ok") }
            return SpacesMobileAppModel(settings: settings, bridgeClient: client)
        }

        private func makeOverview(
            sessions: [SpacesDeviceTerminalSessionSummary] = [], automations: [TerminalServiceAutomationSummary] = [],
            automationRuns: [TerminalServiceAutomationRunSummary] = []
        ) -> SpacesDeviceOverviewPayload {
            SpacesDeviceOverviewPayload(
                workspaces: [], sessions: sessions,
                daemonStatus: TerminalServiceDaemonStatus(
                    version: "1.0.0", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0,
                    protocolVersion: SpacesWireProtocol.version), automations: automations, automationRuns: automationRuns)
        }

        private func makeWorkspace(id: String, branch: String?) -> SpacesDeviceWorkspaceSummary {
            SpacesDeviceWorkspaceSummary(
                id: id, projectID: "project-1", projectName: "Project", branch: branch, baseBranch: nil, dir: "/tmp/\(id)", isRunning: false,
                isHidden: false, isDefault: false, sessionCount: 0)
        }

        private func makeAgentSummary(
            terminalSessionID: String, status: String = "idle", live: Bool = true, title: String? = "Agent", workspaceID: String? = "workspace-1"
        ) -> TerminalServiceAutomationAgentSummary {
            TerminalServiceAutomationAgentSummary(
                terminalSessionID: terminalSessionID, status: status, live: live, title: title, workspaceID: workspaceID)
        }

        private func makeAutomation(
            id: String = "automation-a", name: String = "Automation", enabled: Bool = true, triggerKind: String = "manual",
            cronExpression: String? = nil, kind: String = "script", script: String = "echo hi", agentPrompt: String? = nil,
            workspaceID: String = "workspace-1", nextFireTime: String? = nil
        ) -> TerminalServiceAutomationSummary {
            TerminalServiceAutomationSummary(
                id: id, name: name, enabled: enabled, triggerKind: triggerKind, cronExpression: cronExpression, kind: kind, script: script,
                agentPrompt: agentPrompt, workspaceID: workspaceID, timeoutSeconds: nil, concurrencyPolicy: "skip", missedRunPolicy: "skip",
                nextFireTime: nextFireTime, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
        }

        private func makeRun(
            id: String, automationID: String, automationName: String? = nil, kind: String = "script", status: String = "queued",
            trigger: String = "manual", exitCode: Int? = nil, terminalSessionID: String? = nil, workspaceID: String? = nil,
            startedAt: String? = "2026-01-01T00:00:00Z", endedAt: String? = nil, createdAt: String = "2026-01-01T00:00:00Z",
            attributedAgents: [TerminalServiceAutomationAgentSummary] = []
        ) -> TerminalServiceAutomationRunSummary {
            TerminalServiceAutomationRunSummary(
                id: id, automationID: automationID, automationName: automationName, kind: kind, status: status, trigger: trigger, skipReason: nil,
                exitCode: exitCode, terminalSessionID: terminalSessionID, workspaceID: workspaceID, startedAt: startedAt, endedAt: endedAt,
                createdAt: createdAt, attributedAgents: attributedAgents)
        }

        private func makeSession(
            id: String, title: String = "Session", state: TerminalSessionState = .running, workspaceID: String = "workspace-1"
        ) -> SpacesDeviceTerminalSessionSummary {
            SpacesDeviceTerminalSessionSummary(
                id: id, title: title, workingDirectory: "/tmp", shell: "zsh", command: nil, state: state, backend: .ghosttyEmbedded,
                lifetimePolicy: .persistent, servicePID: 0, childPID: nil, workspaceID: workspaceID, workspaceTitle: nil, projectID: nil,
                projectName: nil, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z", isControlAvailable: state == .running,
                isSubscriptionAvailable: state == .running, attachmentSnapshot: TerminalSessionAttachmentSnapshot())
        }
    }
#endif
