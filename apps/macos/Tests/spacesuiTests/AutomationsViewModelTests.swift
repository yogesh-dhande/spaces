import Foundation
import Testing
import spacesterminalcore
import workspacecore

@testable import spacesui

/// Covers the cross-device merge, filter, running-run, and alert-derivation logic for the Automations pane.
struct AutomationsViewModelTests {
    private func automation(id: String, name: String, triggerKind: String = "manual", cron: String? = nil) -> TerminalServiceAutomationSummary {
        TerminalServiceAutomationSummary(
            id: id, name: name, enabled: true, triggerKind: triggerKind, cronExpression: cron, script: "echo hi", workingDirectory: "/tmp",
            timeoutSeconds: nil, concurrencyPolicy: "allow", missedRunPolicy: "run_once", nextFireTime: nil, createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z")
    }

    private func run(
        id: String, automationID: String, name: String?, status: String, exitCode: Int? = nil, trigger: String = "manual", skipReason: String? = nil,
        sessionID: String? = nil, startedAt: String?, endedAt: String? = nil, createdAt: String,
        attributedAgents: [TerminalServiceAutomationAgentSummary] = []
    ) -> TerminalServiceAutomationRunSummary {
        TerminalServiceAutomationRunSummary(
            id: id, automationID: automationID, automationName: name, status: status, trigger: trigger, skipReason: skipReason, exitCode: exitCode,
            terminalSessionID: sessionID, startedAt: startedAt, endedAt: endedAt, createdAt: createdAt, attributedAgents: attributedAgents)
    }

    private func agent(sessionID: String, status: AgentWindowStatus, live: Bool, title: String? = nil, workspaceID: String? = "ws-1")
        -> TerminalServiceAutomationAgentSummary
    {
        TerminalServiceAutomationAgentSummary(terminalSessionID: sessionID, status: status.rawValue, live: live, title: title, workspaceID: workspaceID)
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
            AutomationDeviceInput(deviceID: "mac", deviceName: "This Mac", isLocal: true, isReachable: true, automations: [automation(id: "a1", name: "A")]),
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
                    run(id: "r-old", automationID: "a", name: "A", status: "succeeded", startedAt: "2026-01-01T08:00:00Z", createdAt: "2026-01-01T08:00:00Z"),
                    run(id: "r-new", automationID: "a", name: "A", status: "succeeded", startedAt: "2026-01-01T12:00:00Z", createdAt: "2026-01-01T12:00:00Z"),
                ]),
            AutomationDeviceInput(
                deviceID: "srv", deviceName: "Server", isLocal: false, isReachable: true,
                runs: [run(id: "r-mid", automationID: "b", name: "B", status: "running", startedAt: "2026-01-01T10:00:00Z", createdAt: "2026-01-01T10:00:00Z")]),
        ]
        #expect(AutomationsViewModel.mergedRuns(from: inputs).map(\.run.id) == ["r-new", "r-mid", "r-old"])
    }

    @Test func queuedRunSortsByCreationWhenNotStarted() {
        let inputs = [
            AutomationDeviceInput(
                deviceID: "mac", deviceName: "This Mac", isLocal: true, isReachable: true,
                runs: [
                    run(id: "r-started", automationID: "a", name: "A", status: "running", startedAt: "2026-01-01T09:00:00Z", createdAt: "2026-01-01T09:00:00Z"),
                    run(id: "r-queued", automationID: "a", name: "A", status: "queued", startedAt: nil, createdAt: "2026-01-01T09:30:00Z"),
                ])
        ]
        // The queued run has no start time; its creation (09:30) is newer than the started run's 09:00.
        #expect(AutomationsViewModel.mergedRuns(from: inputs).map(\.run.id) == ["r-queued", "r-started"])
    }

    // MARK: - Running runs (sidebar children)

    @Test func runningRunsAreOnlyRunningStatus() {
        let inputs = [
            AutomationDeviceInput(
                deviceID: "mac", deviceName: "This Mac", isLocal: true, isReachable: true,
                runs: [
                    run(id: "r1", automationID: "a", name: "A", status: "running", startedAt: "2026-01-01T09:00:00Z", createdAt: "2026-01-01T09:00:00Z"),
                    run(id: "r2", automationID: "a", name: "A", status: "queued", startedAt: nil, createdAt: "2026-01-01T09:30:00Z"),
                    run(id: "r3", automationID: "a", name: "A", status: "succeeded", startedAt: "2026-01-01T08:00:00Z", createdAt: "2026-01-01T08:00:00Z"),
                ])
        ]
        #expect(AutomationsViewModel.runningRuns(from: inputs).map(\.run.id) == ["r1"])
    }

    // MARK: - Filter by device

    @Test func filterAutomationsByDevice() {
        let rows = AutomationsViewModel.mergedAutomations(from: [
            AutomationDeviceInput(deviceID: "mac", deviceName: "This Mac", isLocal: true, isReachable: true, automations: [automation(id: "a1", name: "A")]),
            AutomationDeviceInput(deviceID: "srv", deviceName: "Server", isLocal: false, isReachable: true, automations: [automation(id: "a2", name: "B")]),
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
            run(id: "r-fail", automationID: "a", name: "Nightly audit", status: "failed", exitCode: 3, startedAt: "2026-01-01T09:00:00Z", endedAt: "2026-01-01T09:05:00Z", createdAt: "2026-01-01T09:00:00Z"),
            run(id: "r-timeout", automationID: "b", name: "Backup", status: "timed_out", startedAt: "2026-01-01T10:00:00Z", endedAt: "2026-01-01T10:30:00Z", createdAt: "2026-01-01T10:00:00Z"),
            run(id: "r-ok", automationID: "c", name: "OK", status: "succeeded", startedAt: "2026-01-01T11:00:00Z", endedAt: "2026-01-01T11:01:00Z", createdAt: "2026-01-01T11:00:00Z"),
            run(id: "r-skip", automationID: "d", name: "Skipped", status: "skipped", skipReason: "concurrency", startedAt: nil, createdAt: "2026-01-01T12:00:00Z"),
        ]
        let entries = AutomationsViewModel.alertEntries(deviceID: "mac", deviceName: "This Mac", runs: runs)
        // Newest ended first: the timeout ended 10:30, the failure 09:05.
        #expect(entries.map(\.runID) == ["r-timeout", "r-fail"])
        #expect(entries.first(where: { $0.runID == "r-fail" })?.text == "Nightly audit failed (exit 3) on This Mac")
        #expect(entries.first(where: { $0.runID == "r-timeout" })?.text == "Backup timed out on This Mac")
        #expect(entries.first(where: { $0.runID == "r-fail" })?.attentionID == "alert:mac:automationrun:r-fail:failed")
    }

    @Test func alertEntriesFallBackWhenNoExitCode() {
        let runs = [run(id: "r", automationID: "a", name: nil, status: "failed", startedAt: "2026-01-01T09:00:00Z", endedAt: "2026-01-01T09:05:00Z", createdAt: "2026-01-01T09:00:00Z")]
        let entries = AutomationsViewModel.alertEntries(deviceID: "mac", deviceName: "This Mac", runs: runs)
        #expect(entries.first?.text == "Automation failed on This Mac")
    }

    // MARK: - Editor field building (kind round-trip + validation)

    @Test func buildAgentFieldsRoundTripsKindAndAgentFields() {
        let result = AutomationsViewModel.buildAutomationFields(
            name: "  Nightly agent  ", kind: .agent, enabled: true, triggerKind: .cron, cronExpression: "0 9 * * *", workspaceID: " ws-1 ",
            agentCommand: " claude --model opus ", agentPrompt: "  review the diff  ", script: "leftover script", workingDirectory: "/leftover",
            timeoutSeconds: 120, concurrencyPolicy: "queue", missedRunPolicy: "skip")
        guard case .success(let fields) = result else { Issue.record("expected success, got \(result)"); return }
        #expect(fields.name == "Nightly agent")
        #expect(fields.kind == AutomationKind.agent.rawValue)
        #expect(fields.workspaceID == "ws-1")
        #expect(fields.agentCommand == "claude --model opus")
        #expect(fields.agentPrompt == "review the diff")
        // Agent-kind fields never carry script/working-directory forward, even if the editor still held some.
        #expect(fields.script == "")
        #expect(fields.workingDirectory == "")
        #expect(fields.triggerKind == AutomationTriggerKind.cron.rawValue)
        #expect(fields.cronExpression == "0 9 * * *")
        #expect(fields.timeoutSeconds == 120)
        #expect(fields.concurrencyPolicy == "queue")
        #expect(fields.missedRunPolicy == "skip")
    }

    @Test func buildScriptFieldsRoundTripsKindAndScriptFields() {
        let result = AutomationsViewModel.buildAutomationFields(
            name: "Nightly script", kind: .script, enabled: false, triggerKind: .manual, cronExpression: nil, workspaceID: "ws-1",
            agentCommand: "claude", agentPrompt: "ignored", script: "echo hi", workingDirectory: " /tmp ", timeoutSeconds: nil,
            concurrencyPolicy: "allow", missedRunPolicy: "run_once")
        guard case .success(let fields) = result else { Issue.record("expected success, got \(result)"); return }
        #expect(fields.kind == AutomationKind.script.rawValue)
        #expect(fields.script == "echo hi")
        #expect(fields.workingDirectory == "/tmp")
        // Script-kind fields never carry agent config forward.
        #expect(fields.agentCommand == nil)
        #expect(fields.agentPrompt == nil)
        #expect(fields.workspaceID == nil)
        #expect(fields.enabled == false)
    }

    @Test func agentValidationRequiresWorkspaceCommandAndPrompt() {
        func failure(workspaceID: String?, command: String, prompt: String, name: String = "N") -> String? {
            let result = AutomationsViewModel.buildAutomationFields(
                name: name, kind: .agent, enabled: true, triggerKind: .manual, cronExpression: nil, workspaceID: workspaceID, agentCommand: command,
                agentPrompt: prompt, script: "", workingDirectory: "", timeoutSeconds: nil, concurrencyPolicy: "allow", missedRunPolicy: "run_once")
            if case .failure(let error) = result { return error.message }
            return nil
        }
        #expect(failure(workspaceID: nil, command: "claude", prompt: "go") == "Choose a workspace.")
        #expect(failure(workspaceID: "  ", command: "claude", prompt: "go") == "Choose a workspace.")
        #expect(failure(workspaceID: "ws-1", command: "  ", prompt: "go") == "Enter an agent command.")
        #expect(failure(workspaceID: "ws-1", command: "claude", prompt: "   ") == "Enter a prompt.")
        #expect(failure(workspaceID: "ws-1", command: "claude", prompt: "go", name: "  ") == "Enter a name.")
        // A fully specified agent form validates.
        #expect(failure(workspaceID: "ws-1", command: "claude", prompt: "go") == nil)
    }

    @Test func scriptValidationRequiresScriptAndWorkingDirectory() {
        func failure(script: String, workingDirectory: String) -> String? {
            let result = AutomationsViewModel.buildAutomationFields(
                name: "N", kind: .script, enabled: true, triggerKind: .manual, cronExpression: nil, workspaceID: nil, agentCommand: "claude",
                agentPrompt: "go", script: script, workingDirectory: workingDirectory, timeoutSeconds: nil, concurrencyPolicy: "allow",
                missedRunPolicy: "run_once")
            if case .failure(let error) = result { return error.message }
            return nil
        }
        #expect(failure(script: "   ", workingDirectory: "/tmp") == "Enter a script.")
        #expect(failure(script: "echo hi", workingDirectory: "  ") == "Enter a working directory.")
        #expect(failure(script: "echo hi", workingDirectory: "/tmp") == nil)
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
                        id: "r1", automationID: "a", name: "A", status: "running", startedAt: "2026-01-01T09:00:00Z", createdAt: "2026-01-01T09:00:00Z",
                        attributedAgents: agents)
                ])
        ]
        let rows = AutomationsViewModel.mergedRuns(from: inputs)
        #expect(rows.first?.run.attributedAgents == agents)
    }

    // MARK: - Kind-aware excerpt

    @Test func excerptIsPromptForAgentAndScriptForScriptKind() {
        let agentAutomation = TerminalServiceAutomationSummary(
            id: "a1", name: "Agent", enabled: true, triggerKind: "manual", cronExpression: nil, kind: AutomationKind.agent.rawValue, script: "",
            agentCommand: "claude", agentPrompt: "\n  first prompt line  \nsecond line", workspaceID: "ws-1", workingDirectory: "",
            timeoutSeconds: nil, concurrencyPolicy: "allow", missedRunPolicy: "run_once", nextFireTime: nil, createdAt: "", updatedAt: "")
        #expect(AutomationsViewModel.excerpt(for: agentAutomation) == "first prompt line")

        let scriptAutomation = automation(id: "s1", name: "Script")  // script "echo hi"
        #expect(AutomationsViewModel.excerpt(for: scriptAutomation) == "echo hi")
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
