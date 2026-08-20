import Foundation
import Testing
import spacesterminalcore
import workspacecore

@testable import spacesui

/// Covers the cross-device merge, filter, running-run, and alert-derivation logic for the Automations pane.
struct AutomationsViewModelTests {
    private func automation(
        id: String, name: String, triggerKind: String = "manual", cron: String? = nil, enabled: Bool = true,
        kind: String = AutomationKind.script.rawValue, nextFireTime: String? = nil
    ) -> TerminalServiceAutomationSummary {
        TerminalServiceAutomationSummary(
            id: id, name: name, enabled: enabled, triggerKind: triggerKind, cronExpression: cron, kind: kind, script: "echo hi", workspaceID: "ws-1",
            timeoutSeconds: nil, concurrencyPolicy: "allow", missedRunPolicy: "run_once", nextFireTime: nextFireTime,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
    }

    private func run(
        id: String, automationID: String, name: String?, status: String, kind: String = "script", exitCode: Int? = nil, trigger: String = "manual",
        skipReason: String? = nil, sessionID: String? = nil, startedAt: String?, endedAt: String? = nil, createdAt: String,
        attributedAgents: [TerminalServiceAutomationAgentSummary] = []
    ) -> TerminalServiceAutomationRunSummary {
        TerminalServiceAutomationRunSummary(
            id: id, automationID: automationID, automationName: name, kind: kind, status: status, trigger: trigger, skipReason: skipReason,
            exitCode: exitCode, terminalSessionID: sessionID, startedAt: startedAt, endedAt: endedAt, createdAt: createdAt,
            attributedAgents: attributedAgents)
    }

    private func agent(sessionID: String, status: AgentWindowStatus, live: Bool, title: String? = nil, workspaceID: String? = "ws-1")
        -> TerminalServiceAutomationAgentSummary
    {
        TerminalServiceAutomationAgentSummary(
            terminalSessionID: sessionID, status: status.rawValue, live: live, title: title, workspaceID: workspaceID)
    }

    // MARK: - Merge & sort

    @Test func mergedAutomationsSortByNameThenDevice() {
        let inputs = [
            AutomationDeviceInput(
                deviceID: "mac", deviceName: "This Mac", isLocal: true, isReachable: true,
                automations: [automation(id: "a2", name: "Backup"), automation(id: "a1", name: "Audit")]),
            AutomationDeviceInput(
                deviceID: "srv", deviceName: "Server", isLocal: false, isReachable: true, automations: [automation(id: "a3", name: "Audit")]),
        ]
        let rows = AutomationsViewModel.mergedAutomations(from: inputs)
        // Name ascending, then device name ascending: "Audit" (Server) before "Audit" (This Mac), then "Backup".
        #expect(rows.map(\.id) == ["srv::a3", "mac::a1", "mac::a2"])
    }

    @Test func unreachableDeviceContributesNoAutomationRowsButIsMarked() {
        let inputs = [
            AutomationDeviceInput(
                deviceID: "mac", deviceName: "This Mac", isLocal: true, isReachable: true, automations: [automation(id: "a1", name: "A")]),
            AutomationDeviceInput(deviceID: "srv", deviceName: "Server", isLocal: false, isReachable: false, offlineMessage: "unreachable"),
        ]
        #expect(AutomationsViewModel.mergedAutomations(from: inputs).map(\.deviceID) == ["mac"])
        let unreachable = AutomationsViewModel.unreachableDevices(from: inputs)
        #expect(unreachable.map(\.deviceID) == ["srv"])
        #expect(unreachable.first?.message == "unreachable")
    }

    @Test func mergedRunsAreNewestFirstAcrossDevices() {
        let inputs = [
            AutomationDeviceInput(
                deviceID: "mac", deviceName: "This Mac", isLocal: true, isReachable: true,
                runs: [
                    run(
                        id: "r-old", automationID: "a", name: "A", status: "succeeded", startedAt: "2026-01-01T08:00:00Z",
                        createdAt: "2026-01-01T08:00:00Z"),
                    run(
                        id: "r-new", automationID: "a", name: "A", status: "succeeded", startedAt: "2026-01-01T12:00:00Z",
                        createdAt: "2026-01-01T12:00:00Z"),
                ]),
            AutomationDeviceInput(
                deviceID: "srv", deviceName: "Server", isLocal: false, isReachable: true,
                runs: [
                    run(
                        id: "r-mid", automationID: "b", name: "B", status: "running", startedAt: "2026-01-01T10:00:00Z",
                        createdAt: "2026-01-01T10:00:00Z")
                ]),
        ]
        #expect(AutomationsViewModel.mergedRuns(from: inputs).map(\.run.id) == ["r-new", "r-mid", "r-old"])
    }

    @Test func retainedRunHistoryAugmentsTheBoundedOverviewSliceForReachableDevices() {
        let overviewRun = run(
            id: "overview", automationID: "a", name: "A", status: "succeeded", startedAt: "2026-01-02T08:00:00Z", createdAt: "2026-01-02T08:00:00Z")
        let retainedRun = run(
            id: "retained", automationID: "a", name: "A", status: "succeeded", startedAt: "2026-01-01T08:00:00Z", createdAt: "2026-01-01T08:00:00Z")
        let offlineRun = run(
            id: "offline", automationID: "b", name: "B", status: "running", startedAt: "2026-01-02T09:00:00Z", createdAt: "2026-01-02T09:00:00Z")
        let inputs = [
            AutomationDeviceInput(deviceID: "mac", deviceName: "This Mac", isLocal: true, isReachable: true, runs: [overviewRun]),
            AutomationDeviceInput(
                deviceID: "offline", deviceName: "Server", isLocal: false, isReachable: false, offlineMessage: "unreachable", runs: [offlineRun]),
        ]

        let merged = AutomationsViewModel.mergingRetainedRuns(in: inputs, with: ["mac": [retainedRun], "offline": []])

        #expect(merged[0].runs.map(\.id).sorted() == ["overview", "retained"])
        // An unreachable section keeps its stale overview solely for the offline presentation; a failed
        // history request must not make that device look freshly loaded.
        #expect(merged[1].runs.map(\.id) == ["offline"])
    }

    @Test func retainedRunHistoryRefreshesAfterTheVisiblePaneCacheAgesOut() {
        let loadedAt = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(!AutomationsViewModel.retainedRunHistoryNeedsRefresh(lastLoadedAt: loadedAt, now: loadedAt.addingTimeInterval(29)))
        #expect(AutomationsViewModel.retainedRunHistoryNeedsRefresh(lastLoadedAt: loadedAt, now: loadedAt.addingTimeInterval(30)))
        #expect(AutomationsViewModel.retainedRunHistoryNeedsRefresh(lastLoadedAt: nil, now: loadedAt))
    }

    @Test func runningSidebarBadgeExcludesUnreachableDeviceSnapshots() {
        let inputs = [
            AutomationDeviceInput(
                deviceID: "mac", deviceName: "This Mac", isLocal: true, isReachable: true,
                runs: [
                    run(
                        id: "live-local", automationID: "a", name: "A", status: "running", startedAt: "2026-08-05T09:00:00Z",
                        createdAt: "2026-08-05T09:00:00Z")
                ]),
            // An offline device can retain its last overview in memory, but that snapshot cannot report
            // current live activity and must not inflate the sidebar badge.
            AutomationDeviceInput(
                deviceID: "offline", deviceName: "Offline Mac", isLocal: false, isReachable: false, offlineMessage: "unreachable",
                runs: [
                    run(
                        id: "stale-live", automationID: "b", name: "B", status: "running", startedAt: "2026-08-05T10:00:00Z",
                        createdAt: "2026-08-05T10:00:00Z")
                ]),
        ]

        #expect(AutomationsViewModel.runningRunCount(from: inputs) == 1)
    }

    @Test func queuedRunSortsByCreationWhenNotStarted() {
        let inputs = [
            AutomationDeviceInput(
                deviceID: "mac", deviceName: "This Mac", isLocal: true, isReachable: true,
                runs: [
                    run(
                        id: "r-started", automationID: "a", name: "A", status: "running", startedAt: "2026-01-01T09:00:00Z",
                        createdAt: "2026-01-01T09:00:00Z"),
                    run(id: "r-queued", automationID: "a", name: "A", status: "queued", startedAt: nil, createdAt: "2026-01-01T09:30:00Z"),
                ])
        ]
        // The queued run has no start time; its creation (09:30) is newer than the started run's 09:00.
        #expect(AutomationsViewModel.mergedRuns(from: inputs).map(\.run.id) == ["r-queued", "r-started"])
    }

    // MARK: - Filter by device

    @Test func filterAutomationsByDevice() {
        let rows = AutomationsViewModel.mergedAutomations(from: [
            AutomationDeviceInput(
                deviceID: "mac", deviceName: "This Mac", isLocal: true, isReachable: true, automations: [automation(id: "a1", name: "A")]),
            AutomationDeviceInput(
                deviceID: "srv", deviceName: "Server", isLocal: false, isReachable: true, automations: [automation(id: "a2", name: "B")]),
        ])
        #expect(AutomationsViewModel.filterAutomations(rows, deviceID: "srv").map(\.id) == ["srv::a2"])
        #expect(AutomationsViewModel.filterAutomations(rows, deviceID: nil).count == 2)
    }

    // MARK: - Last-run status

    @Test func lastRunStatusIsMostRecent() {
        let runs = [
            run(id: "r1", automationID: "a", name: "A", status: "succeeded", startedAt: "2026-01-01T08:00:00Z", createdAt: "2026-01-01T08:00:00Z"),
            run(id: "r2", automationID: "a", name: "A", status: "failed", startedAt: "2026-01-01T12:00:00Z", createdAt: "2026-01-01T12:00:00Z"),
            run(id: "r3", automationID: "b", name: "B", status: "running", startedAt: "2026-01-01T13:00:00Z", createdAt: "2026-01-01T13:00:00Z"),
        ]
        #expect(AutomationsViewModel.lastRunStatus(automationID: "a", in: runs) == "failed")
        #expect(AutomationsViewModel.lastRunStatus(automationID: "b", in: runs) == "running")
        #expect(AutomationsViewModel.lastRunStatus(automationID: "missing", in: runs) == nil)
    }

    // MARK: - Alert-entry derivation

    @Test func alertEntriesCoverFailedAndTimedOutWithText() {
        let runs = [
            run(
                id: "r-fail", automationID: "a", name: "Nightly audit", status: "failed", exitCode: 3, startedAt: "2026-01-01T09:00:00Z",
                endedAt: "2026-01-01T09:05:00Z", createdAt: "2026-01-01T09:00:00Z"),
            run(
                id: "r-timeout", automationID: "b", name: "Backup", status: "timed_out", startedAt: "2026-01-01T10:00:00Z",
                endedAt: "2026-01-01T10:30:00Z", createdAt: "2026-01-01T10:00:00Z"),
            run(
                id: "r-ok", automationID: "c", name: "OK", status: "succeeded", startedAt: "2026-01-01T11:00:00Z", endedAt: "2026-01-01T11:01:00Z",
                createdAt: "2026-01-01T11:00:00Z"),
            run(
                id: "r-skip", automationID: "d", name: "Skipped", status: "skipped", skipReason: "concurrency", startedAt: nil,
                createdAt: "2026-01-01T12:00:00Z"),
        ]
        let entries = AutomationsViewModel.alertEntries(deviceID: "mac", deviceName: "This Mac", runs: runs)
        // Newest ended first: the timeout ended 10:30, the failure 09:05.
        #expect(entries.map(\.runID) == ["r-timeout", "r-fail"])
        #expect(entries.first(where: { $0.runID == "r-fail" })?.text == "Nightly audit failed (exit 3) on This Mac")
        #expect(entries.first(where: { $0.runID == "r-timeout" })?.text == "Backup timed out on This Mac")
        #expect(entries.first(where: { $0.runID == "r-fail" })?.attentionID == "alert:mac:automationrun:r-fail:failed")
    }

    @Test func alertEntriesFallBackWhenNoExitCode() {
        let runs = [
            run(
                id: "r", automationID: "a", name: nil, status: "failed", startedAt: "2026-01-01T09:00:00Z", endedAt: "2026-01-01T09:05:00Z",
                createdAt: "2026-01-01T09:00:00Z")
        ]
        let entries = AutomationsViewModel.alertEntries(deviceID: "mac", deviceName: "This Mac", runs: runs)
        #expect(entries.first?.text == "Automation failed on This Mac")
    }

    // MARK: - Editor field building (kind round-trip + validation)

    @Test func scheduleIntegerFieldsRejectBlankNonnumericAndOutOfRangeValues() {
        #expect(AutomationScheduleFieldValidation.integer("", range: 0...59) == nil)
        #expect(AutomationScheduleFieldValidation.integer("noon", range: 0...23) == nil)
        #expect(AutomationScheduleFieldValidation.integer("60", range: 0...59) == nil)
        #expect(AutomationScheduleFieldValidation.integer(" 09 ", range: 0...23) == 9)
    }

    @Test func buildAgentFieldsRoundTripsKindAndAgentFields() {
        let result = AutomationsViewModel.buildAutomationFields(
            name: "  Nightly agent  ", kind: .agent, enabled: true, triggerKind: .cron, cronExpression: "0 9 * * *", workspaceID: " ws-1 ",
            agentCommand: " claude --model opus ", agentPrompt: "  review the diff  ", script: "leftover script", timeoutSeconds: 120,
            concurrencyPolicy: "queue", missedRunPolicy: "skip")
        guard case .success(let fields) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(fields.name == "Nightly agent")
        #expect(fields.kind == AutomationKind.agent.rawValue)
        #expect(fields.workspaceID == "ws-1")
        #expect(fields.agentCommand == "claude --model opus")
        #expect(fields.agentPrompt == "review the diff")
        // Agent-kind fields never carry script forward, even if the editor still held some.
        #expect(fields.script == "")
        #expect(fields.triggerKind == AutomationTriggerKind.cron.rawValue)
        #expect(fields.cronExpression == "0 9 * * *")
        #expect(fields.timeoutSeconds == 120)
        #expect(fields.concurrencyPolicy == "queue")
        #expect(fields.missedRunPolicy == "skip")
    }

    @Test func buildScriptFieldsRoundTripsKindAndScriptFields() {
        let result = AutomationsViewModel.buildAutomationFields(
            name: "Nightly script", kind: .script, enabled: false, triggerKind: .manual, cronExpression: nil, workspaceID: "ws-1",
            agentCommand: "claude", agentPrompt: "ignored", script: "echo hi", timeoutSeconds: nil, concurrencyPolicy: "allow",
            missedRunPolicy: "run_once")
        guard case .success(let fields) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(fields.kind == AutomationKind.script.rawValue)
        #expect(fields.script == "echo hi")
        // Script-kind fields never carry agent config forward.
        #expect(fields.agentCommand == nil)
        #expect(fields.agentPrompt == nil)
        #expect(fields.workspaceID == "ws-1")
        #expect(fields.enabled == false)
    }

    @Test func agentValidationRequiresWorkspaceCommandAndPrompt() {
        func failure(workspaceID: String, command: String, prompt: String, name: String = "N") -> String? {
            let result = AutomationsViewModel.buildAutomationFields(
                name: name, kind: .agent, enabled: true, triggerKind: .manual, cronExpression: nil, workspaceID: workspaceID, agentCommand: command,
                agentPrompt: prompt, script: "", timeoutSeconds: nil, concurrencyPolicy: "allow", missedRunPolicy: "run_once")
            if case .failure(let error) = result { return error.message }
            return nil
        }
        #expect(failure(workspaceID: "  ", command: "claude", prompt: "go") == "Choose a workspace.")
        #expect(failure(workspaceID: "ws-1", command: "  ", prompt: "go") == "Enter an agent command.")
        #expect(failure(workspaceID: "ws-1", command: "claude", prompt: "   ") == "Enter a prompt.")
        #expect(failure(workspaceID: "ws-1", command: "claude", prompt: "go", name: "  ") == "Enter a name.")
        // A fully specified agent form validates.
        #expect(failure(workspaceID: "ws-1", command: "claude", prompt: "go") == nil)
    }

    @Test func scriptValidationRequiresWorkspaceAndScript() {
        func failure(workspaceID: String, script: String) -> String? {
            let result = AutomationsViewModel.buildAutomationFields(
                name: "N", kind: .script, enabled: true, triggerKind: .manual, cronExpression: nil, workspaceID: workspaceID, agentCommand: "claude",
                agentPrompt: "go", script: script, timeoutSeconds: nil, concurrencyPolicy: "allow", missedRunPolicy: "run_once")
            if case .failure(let error) = result { return error.message }
            return nil
        }
        #expect(failure(workspaceID: "ws-1", script: "   ") == "Enter a script.")
        #expect(failure(workspaceID: "  ", script: "echo hi") == "Choose a workspace.")
        #expect(failure(workspaceID: "ws-1", script: "echo hi") == nil)
    }

    // MARK: - Agent → Script prefill generation

    @Test func agentEquivalentScriptMatchesCLIForm() {
        let script = AutomationsViewModel.agentEquivalentScript(workspaceID: "ws-1", command: "claude", prompt: "the prompt")
        #expect(
            script == """
                SESSION=$(spaces agent spawn --command 'claude' --workspace ws-1 | cut -f1)
                spaces terminal send text "$SESSION" 'the prompt' --submit
                """)
    }

    @Test func agentEquivalentScriptEscapesSingleQuotes() {
        let script = AutomationsViewModel.agentEquivalentScript(workspaceID: "ws-1", command: "claude", prompt: "it's done")
        // The prompt's embedded single quote is escaped as the POSIX '\'' sequence so it stays one argument.
        #expect(script.contains(#"'it'\''s done'"#))
    }

    // MARK: - Attributed agents + End-agents visibility

    @Test func endAgentsAvailableOnlyForTerminalRunWithLiveAgent() {
        // Terminal status with a live agent lingering: eligible.
        #expect(
            AutomationsViewModel.endAgentsAvailable(
                for: run(
                    id: "r1", automationID: "a", name: "A", status: "succeeded", startedAt: "2026-01-01T09:00:00Z", createdAt: "2026-01-01T09:00:00Z",
                    attributedAgents: [agent(sessionID: "s1", status: .done, live: true)])))
        // Terminal status but no live agent: not eligible.
        #expect(
            !AutomationsViewModel.endAgentsAvailable(
                for: run(
                    id: "r2", automationID: "a", name: "A", status: "succeeded", startedAt: "2026-01-01T09:00:00Z", createdAt: "2026-01-01T09:00:00Z",
                    attributedAgents: [agent(sessionID: "s2", status: .exited, live: false)])))
        // Still running (non-terminal): keeps Cancel, not End agents.
        #expect(
            !AutomationsViewModel.endAgentsAvailable(
                for: run(
                    id: "r3", automationID: "a", name: "A", status: "running", startedAt: "2026-01-01T09:00:00Z", createdAt: "2026-01-01T09:00:00Z",
                    attributedAgents: [agent(sessionID: "s3", status: .spinning, live: true)])))
    }

    @Test func mergedRunsExposeAttributedAgents() {
        let agents = [agent(sessionID: "s1", status: .spinning, live: true), agent(sessionID: "s2", status: .exited, live: false)]
        let inputs = [
            AutomationDeviceInput(
                deviceID: "mac", deviceName: "This Mac", isLocal: true, isReachable: true,
                runs: [
                    run(
                        id: "r1", automationID: "a", name: "A", status: "running", startedAt: "2026-01-01T09:00:00Z",
                        createdAt: "2026-01-01T09:00:00Z", attributedAgents: agents)
                ])
        ]
        let rows = AutomationsViewModel.mergedRuns(from: inputs)
        #expect(rows.first?.run.attributedAgents == agents)
    }

    // MARK: - Kind-aware excerpt

    @Test func excerptIsPromptForAgentAndScriptForScriptKind() {
        let agentAutomation = TerminalServiceAutomationSummary(
            id: "a1", name: "Agent", enabled: true, triggerKind: "manual", cronExpression: nil, kind: AutomationKind.agent.rawValue, script: "",
            agentCommand: "claude", agentPrompt: "\n  first prompt line  \nsecond line", workspaceID: "ws-1", timeoutSeconds: nil,
            concurrencyPolicy: "allow", missedRunPolicy: "run_once", nextFireTime: nil, createdAt: "", updatedAt: "")
        #expect(AutomationsViewModel.excerpt(for: agentAutomation) == "first prompt line")

        let scriptAutomation = automation(id: "s1", name: "Script")  // script "echo hi"
        #expect(AutomationsViewModel.excerpt(for: scriptAutomation) == "echo hi")
    }

    // MARK: - Automations table columns

    private static let utc = TimeZone(identifier: "UTC")!
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    /// The fixed clock every table-column test measures against.
    private var now: Date { date("2026-08-05T14:00:00Z") }

    private func tableRow(
        automation: TerminalServiceAutomationSummary, latestRun: TerminalServiceAutomationRunSummary? = nil,
        runningRun: TerminalServiceAutomationRunSummary? = nil
    ) -> AutomationTableRow {
        AutomationTableRow(
            deviceID: "mac", deviceName: "This Mac", isLocal: true, automation: automation, latestRun: latestRun, runningRun: runningRun)
    }

    @Test func latestAndRunningRunAreResolvedPerAutomation() {
        let runs = [
            run(id: "r1", automationID: "a", name: "A", status: "succeeded", startedAt: "2026-08-05T09:00:00Z", createdAt: "2026-08-05T09:00:00Z"),
            run(id: "r2", automationID: "a", name: "A", status: "running", startedAt: "2026-08-05T13:00:00Z", createdAt: "2026-08-05T13:00:00Z"),
            run(id: "r3", automationID: "b", name: "B", status: "failed", startedAt: "2026-08-05T12:00:00Z", createdAt: "2026-08-05T12:00:00Z"),
        ]
        #expect(AutomationsViewModel.latestRun(automationID: "a", in: runs)?.id == "r2")
        #expect(AutomationsViewModel.runningRun(automationID: "a", in: runs)?.id == "r2")
        #expect(AutomationsViewModel.latestRun(automationID: "b", in: runs)?.id == "r3")
        // "b" has only a failed run, so it has nothing in flight.
        #expect(AutomationsViewModel.runningRun(automationID: "b", in: runs) == nil)
        #expect(AutomationsViewModel.latestRun(automationID: "missing", in: runs) == nil)
    }

    @Test func mergedAutomationRowsCarryLatestAndRunningRuns() {
        let inputs = [
            AutomationDeviceInput(
                deviceID: "mac", deviceName: "This Mac", isLocal: true, isReachable: true, automations: [automation(id: "a", name: "A")],
                runs: [
                    run(
                        id: "r1", automationID: "a", name: "A", status: "failed", startedAt: "2026-08-05T09:00:00Z", createdAt: "2026-08-05T09:00:00Z"
                    ),
                    run(
                        id: "r2", automationID: "a", name: "A", status: "running", startedAt: "2026-08-05T13:00:00Z",
                        createdAt: "2026-08-05T13:00:00Z"),
                ])
        ]
        let row = AutomationsViewModel.mergedAutomations(from: inputs).first
        #expect(row?.latestRun?.id == "r2")
        #expect(row?.runningRun?.id == "r2")
        #expect(row?.lastRunStatus == "running")
    }

    @Test func rowStatusPrefersRunningOverEverythingElse() {
        let running = run(
            id: "r", automationID: "a", name: "A", status: "running", startedAt: "2026-08-05T13:00:00Z", createdAt: "2026-08-05T13:00:00Z")
        // A run already in flight keeps the running dot even though the schedule is switched off.
        let disabledButRunning = tableRow(automation: automation(id: "a", name: "A", enabled: false), latestRun: running, runningRun: running)
        #expect(AutomationsViewModel.rowStatus(for: disabledButRunning) == .running)
    }

    @Test func rowStatusReportsDisabledFailedAndReady() {
        let failed = run(id: "r", automationID: "a", name: "A", status: "failed", exitCode: 1, startedAt: nil, createdAt: "2026-08-05T09:00:00Z")
        let timedOut = run(id: "r", automationID: "a", name: "A", status: "timed_out", startedAt: nil, createdAt: "2026-08-05T09:00:00Z")
        let succeeded = run(id: "r", automationID: "a", name: "A", status: "succeeded", startedAt: nil, createdAt: "2026-08-05T09:00:00Z")

        #expect(AutomationsViewModel.rowStatus(for: tableRow(automation: automation(id: "a", name: "A"), latestRun: failed)) == .failed)
        #expect(AutomationsViewModel.rowStatus(for: tableRow(automation: automation(id: "a", name: "A"), latestRun: timedOut)) == .failed)
        #expect(AutomationsViewModel.rowStatus(for: tableRow(automation: automation(id: "a", name: "A"), latestRun: succeeded)) == .ready)
        #expect(AutomationsViewModel.rowStatus(for: tableRow(automation: automation(id: "a", name: "A"))) == .ready)
        // Disabled outranks a failed history: the row's point is that it will not fire.
        #expect(
            AutomationsViewModel.rowStatus(for: tableRow(automation: automation(id: "a", name: "A", enabled: false), latestRun: failed)) == .disabled)
    }

    @Test func scheduleDescriptionHumanizesEveryPresetShape() {
        func summary(_ cron: String) -> String {
            AutomationsViewModel.scheduleDescription(for: automation(id: "a", name: "A", triggerKind: "cron", cron: cron)).summary
        }
        #expect(summary("*/15 * * * *") == "Every 15 min")
        #expect(summary("30 * * * *") == "Hourly at :30")
        #expect(summary("0 2 * * *") == "Daily at 02:00")
        #expect(summary("30 4 * * 0") == "Weekly Sun 04:30")
        #expect(summary("0 9 * * 1,3") == "Weekly Mon, Wed 09:00")
        // Anything the builder does not recognize reads as Custom and leans on the raw string beside it.
        #expect(summary("5 */2 * * *") == "Custom")
    }

    @Test func scheduleDescriptionKeepsRawCronAndHasNoneForManual() {
        let cron = AutomationsViewModel.scheduleDescription(for: automation(id: "a", name: "A", triggerKind: "cron", cron: "0 2 * * *"))
        #expect(cron.cronDetail == "0 2 * * *")

        let manual = AutomationsViewModel.scheduleDescription(for: automation(id: "a", name: "A"))
        #expect(manual == AutomationScheduleDescription(summary: "Manual", cronDetail: nil))

        // A cron automation whose expression never made it through still names its trigger.
        let empty = AutomationsViewModel.scheduleDescription(for: automation(id: "a", name: "A", triggerKind: "cron", cron: "  "))
        #expect(empty == AutomationScheduleDescription(summary: "Cron", cronDetail: nil))
    }

    @Test func nextRunCountsDownWhileNearAndTurnsAbsoluteBeyond() {
        func next(_ fireTime: String, from clock: Date? = nil) -> String {
            AutomationsViewModel.nextRunDescription(
                for: automation(id: "a", name: "A", triggerKind: "cron", cron: "0 2 * * *", nextFireTime: fireTime), now: clock ?? now,
                timeZone: Self.utc)
        }
        #expect(next("2026-08-05T14:04:00Z") == "in 4 m")
        #expect(next("2026-08-05T17:12:00Z") == "in 3 h 12 m")
        // Past the twelve-hour horizon the wall-clock time is the useful fact, with the day when it differs.
        #expect(next("2026-08-06T04:30:00Z") == "Aug 6 04:30")
        #expect(next("2026-08-05T13:00:00Z", from: date("2026-08-05T00:30:00Z")) == "13:00")
        // A fire time the daemon has not caught up to yet reads as due, never as a negative countdown.
        #expect(next("2026-08-05T13:59:00Z") == "due")
    }

    @Test func nextRunAcceptsFractionalWireTimestamp() {
        let description = AutomationsViewModel.nextRunDescription(
            for: automation(id: "a", name: "A", triggerKind: "cron", cron: "0 2 * * *", nextFireTime: "2026-08-05T14:04:00.875Z"), now: now,
            timeZone: Self.utc)
        #expect(description == "in 4 m")
    }

    @Test func nextRunIsBlankWithoutAScheduledFire() {
        let placeholder = "—"
        #expect(AutomationsViewModel.nextRunDescription(for: automation(id: "a", name: "A"), now: now, timeZone: Self.utc) == placeholder)
        let disabled = automation(id: "a", name: "A", triggerKind: "cron", cron: "0 2 * * *", enabled: false, nextFireTime: "2026-08-06T02:00:00Z")
        #expect(AutomationsViewModel.nextRunDescription(for: disabled, now: now, timeZone: Self.utc) == placeholder)
    }

    @Test func compactDurationKeepsAtMostTwoUnits() {
        #expect(AutomationsViewModel.compactDuration(45) == "45 s")
        #expect(AutomationsViewModel.compactDuration(60) == "1 m")
        #expect(AutomationsViewModel.compactDuration(47 * 60) == "47 m")
        #expect(AutomationsViewModel.compactDuration(3 * 3600) == "3 h")
        #expect(AutomationsViewModel.compactDuration(3 * 3600 + 12 * 60) == "3 h 12 m")
        #expect(AutomationsViewModel.compactDuration(26 * 3600) == "1 d 2 h")
        #expect(AutomationsViewModel.compactDuration(48 * 3600) == "2 d")
        #expect(AutomationsViewModel.compactDuration(-10) == "0 s")
    }

    // MARK: - Next-run popover

    @Test func nextRunSummaryLineNamesTheScheduledInstantOrWhyThereIsNone() {
        let scheduled = automation(id: "a", name: "A", triggerKind: "cron", cron: "0 2 * * *", nextFireTime: "2026-08-06T02:00:00Z")
        #expect(AutomationsViewModel.nextRunSummaryLine(for: scheduled, timeZone: Self.utc) == "Scheduled: Aug 6 2026 02:00")

        // A cron automation the daemon has no upcoming fire for reads as unscheduled rather than as manual.
        let unscheduled = automation(id: "a", name: "A", triggerKind: "cron", cron: "0 2 * * *")
        #expect(AutomationsViewModel.nextRunSummaryLine(for: unscheduled, timeZone: Self.utc) == "Not scheduled")

        #expect(AutomationsViewModel.nextRunSummaryLine(for: automation(id: "a", name: "A"), timeZone: Self.utc) == "Manual")

        // A one-time override on a manual automation arrives as its next fire time, so the line reports the
        // instant it will fire at rather than calling it manual.
        let overridden = automation(id: "a", name: "A", nextFireTime: "2026-08-06T09:15:00Z")
        #expect(AutomationsViewModel.nextRunSummaryLine(for: overridden, timeZone: Self.utc) == "Scheduled: Aug 6 2026 09:15")

        // A switched-off automation has no next fire whatever the daemon last computed.
        let disabled = automation(id: "a", name: "A", triggerKind: "cron", cron: "0 2 * * *", enabled: false, nextFireTime: "2026-08-06T02:00:00Z")
        #expect(AutomationsViewModel.nextRunSummaryLine(for: disabled, timeZone: Self.utc) == "Not scheduled")
    }

    @Test func nextRunInstantParsesInTheDeviceTimeZone() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let instant = AutomationsViewModel.parseNextRunInstant(dateText: "2026-08-06", hour: 9, minute: 30, timeZone: tokyo)
        // 09:30 in Tokyo (UTC+9) is 00:30 UTC on the same day.
        #expect(instant == date("2026-08-06T00:30:00Z"))
        // The same typed values in UTC name a different instant, so the zone is genuinely applied.
        #expect(
            AutomationsViewModel.parseNextRunInstant(dateText: "2026-08-06", hour: 9, minute: 30, timeZone: Self.utc) == date("2026-08-06T09:30:00Z"))
    }

    @Test func nextRunInstantRejectsMalformedInput() {
        #expect(AutomationsViewModel.parseNextRunInstant(dateText: "6 Aug 2026", hour: 9, minute: 30, timeZone: Self.utc) == nil)
        #expect(AutomationsViewModel.parseNextRunInstant(dateText: "2026-08", hour: 9, minute: 30, timeZone: Self.utc) == nil)
        #expect(AutomationsViewModel.parseNextRunInstant(dateText: "", hour: 9, minute: 30, timeZone: Self.utc) == nil)
        // A day its month does not have is malformed, not something to roll forward into the next month.
        #expect(AutomationsViewModel.parseNextRunInstant(dateText: "2026-02-31", hour: 9, minute: 30, timeZone: Self.utc) == nil)
        #expect(AutomationsViewModel.parseNextRunInstant(dateText: "2026-08-06", hour: 24, minute: 0, timeZone: Self.utc) == nil)
        #expect(AutomationsViewModel.parseNextRunInstant(dateText: "2026-08-06", hour: 9, minute: 60, timeZone: Self.utc) == nil)
    }

    @Test func nextRunInstantMustBeInTheFuture() {
        #expect(AutomationsViewModel.nextRunInstantIsAcceptable(date("2026-08-05T14:00:01Z"), now: now))
        #expect(!AutomationsViewModel.nextRunInstantIsAcceptable(date("2026-08-05T13:59:59Z"), now: now))
        // The current instant is not in the future either: the daemon would reject it.
        #expect(!AutomationsViewModel.nextRunInstantIsAcceptable(now, now: now))
    }

    // MARK: - Workspace choice preservation

    private typealias WorkspaceChoice = AutomationsViewModel.WorkspaceChoice

    @Test func workspaceChoicesLeaveVisibleUnchangedWhenStoredWorkspaceVisible() {
        let visible = [WorkspaceChoice(workspaceID: "ws-1", label: "P / A"), WorkspaceChoice(workspaceID: "ws-2", label: "P / B")]
        let result = AutomationsViewModel.workspaceChoices(visible: visible, preservingWorkspaceID: "ws-1") { _ in "unused" }
        #expect(result == visible)
    }

    @Test func workspaceChoicesAppendHiddenResolvableWorkspaceWithRealNameAndSuffix() {
        let visible = [WorkspaceChoice(workspaceID: "ws-1", label: "P / A")]
        let result = AutomationsViewModel.workspaceChoices(visible: visible, preservingWorkspaceID: "ws-hidden") { id in
            id == "ws-hidden" ? "P / Hidden" : nil
        }
        #expect(result == visible + [WorkspaceChoice(workspaceID: "ws-hidden", label: "P / Hidden (hidden)")])
    }

    @Test func workspaceChoicesAppendGoneWorkspaceWithRawIDFallback() {
        let visible = [WorkspaceChoice(workspaceID: "ws-1", label: "P / A")]
        let result = AutomationsViewModel.workspaceChoices(visible: visible, preservingWorkspaceID: "ws-gone") { _ in nil }
        #expect(result == visible + [WorkspaceChoice(workspaceID: "ws-gone", label: "ws-gone")])
    }

    @Test func workspaceChoicesLeaveVisibleUnchangedForNilStoredID() {
        let visible = [WorkspaceChoice(workspaceID: "ws-1", label: "P / A")]
        #expect(AutomationsViewModel.workspaceChoices(visible: visible, preservingWorkspaceID: nil) { _ in "unused" } == visible)
    }

    // MARK: - Schedule preview zone

    @Test func schedulePreviewZoneUsesCurrentForLocalDevice() {
        // The local device previews in the Mac's own zone, ignoring any reported identifier.
        #expect(AutomationsViewModel.schedulePreviewTimeZone(isLocalDevice: true, reportedTimeZoneIdentifier: "Asia/Tokyo") == .current)
    }

    @Test func schedulePreviewZoneUsesReportedIdentifierForRemoteDevice() {
        let zone = AutomationsViewModel.schedulePreviewTimeZone(isLocalDevice: false, reportedTimeZoneIdentifier: "Asia/Tokyo")
        #expect(zone == TimeZone(identifier: "Asia/Tokyo"))
    }

    @Test func schedulePreviewZoneFallsBackToCurrentForRemoteWithoutOrBadIdentifier() {
        #expect(AutomationsViewModel.schedulePreviewTimeZone(isLocalDevice: false, reportedTimeZoneIdentifier: nil) == .current)
        #expect(AutomationsViewModel.schedulePreviewTimeZone(isLocalDevice: false, reportedTimeZoneIdentifier: "   ") == .current)
        #expect(AutomationsViewModel.schedulePreviewTimeZone(isLocalDevice: false, reportedTimeZoneIdentifier: "Not/AZone") == .current)
    }

    @Test func schedulePreviewZoneSuffixShownOnlyWhenDifferentFromLocal() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let newYork = TimeZone(identifier: "America/New_York")!
        #expect(AutomationsViewModel.schedulePreviewZoneSuffix(previewTimeZone: tokyo, localTimeZone: newYork) == "Asia/Tokyo")
        #expect(AutomationsViewModel.schedulePreviewZoneSuffix(previewTimeZone: tokyo, localTimeZone: tokyo) == nil)
    }
}
