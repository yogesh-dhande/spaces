import Foundation
import Testing
import spacesterminalcore

@testable import spacesui

/// Covers the cross-device merge, filter, running-run, and alert-derivation logic for the Automations pane.
struct AutomationsViewModelTests {
    private func automation(id: String, name: String, triggerKind: String = "manual", cron: String? = nil) -> TerminalServiceAutomationSummary {
        TerminalServiceAutomationSummary(
            id: id, name: name, enabled: true, triggerKind: triggerKind, cronExpression: cron, command: "echo hi", workingDirectory: "/tmp",
            timeoutSeconds: nil, concurrencyPolicy: "allow", missedRunPolicy: "run_once", nextFireTime: nil, createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z")
    }

    private func run(
        id: String, automationID: String, name: String?, status: String, exitCode: Int? = nil, trigger: String = "manual", skipReason: String? = nil,
        sessionID: String? = nil, startedAt: String?, endedAt: String? = nil, createdAt: String
    ) -> TerminalServiceAutomationRunSummary {
        TerminalServiceAutomationRunSummary(
            id: id, automationID: automationID, automationName: name, status: status, trigger: trigger, skipReason: skipReason, exitCode: exitCode,
            terminalSessionID: sessionID, startedAt: startedAt, endedAt: endedAt, createdAt: createdAt, liveAttributedSessionCount: 0)
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
}
