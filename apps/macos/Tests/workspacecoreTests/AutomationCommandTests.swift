import XCTest
import spacesterminalcore

@testable import workspacecore

/// Boundary coverage for the automation command surface both transports share: draft validation (empty
/// fields, bad/missing cron, manual-with-cron, non-positive timeout), create/update next-fire-time
/// handling, not-found errors, and the wire-summary mapping clients read (including the failed/timed-out
/// fields alerts are derived from). These are the rules the profile-socket and Device API paths both rely
/// on `AutomationService` to enforce once, so they never fork between local and remote callers.
@MainActor final class AutomationCommandTests: XCTestCase {
    private func makeService(now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }) throws -> (AutomationService, SQLiteStore) {
        let store = try makeTemporaryStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let project = makeProjectRecord(dir: directory)
        try store.upsert(project: project)
        try store.upsert(workspace: makeWorkspaceRecord(id: "ws-1", projectID: project.id, dir: directory))
        let service = AutomationService(
            store: store, orchestrator: WorkspaceOrchestrator(store: store), binaryDirectory: "/usr/bin", now: now, logError: { _ in })
        return (service, store)
    }

    private func draft(
        name: String = "Nightly", enabled: Bool = true, trigger: AutomationTriggerKind = .manual, cron: String? = nil, kind: AutomationKind = .script,
        script: String = "echo hi", agentCommand: String? = nil, agentPrompt: String? = nil, workspaceID: String = "ws-1", timeoutSeconds: Int? = nil,
        concurrency: AutomationConcurrencyPolicy = .allow, missedRun: AutomationMissedRunPolicy = .runOnce
    ) -> AutomationDraft {
        AutomationDraft(
            name: name, enabled: enabled, triggerKind: trigger, cronExpression: cron, kind: kind, script: script, agentCommand: agentCommand,
            agentPrompt: agentPrompt, workspaceID: workspaceID, timeoutSeconds: timeoutSeconds, concurrencyPolicy: concurrency,
            missedRunPolicy: missedRun)
    }

    // MARK: - Validation

    func testCreateRejectsEmptyName() throws {
        let (service, _) = try makeService()
        XCTAssertThrowsError(try service.createAutomation(draft(name: "   ")))
    }

    func testCreateRejectsEmptyScript() throws {
        let (service, _) = try makeService()
        XCTAssertThrowsError(try service.createAutomation(draft(script: "  ")))
    }

    func testCreateAgentKindRejectsMissingAgentCommand() throws {
        let (service, _) = try makeService()
        XCTAssertThrowsError(try service.createAutomation(draft(kind: .agent, agentCommand: nil, agentPrompt: "do the thing", workspaceID: "ws-1")))
    }

    func testCreateAgentKindRejectsMissingAgentPrompt() throws {
        let (service, _) = try makeService()
        XCTAssertThrowsError(try service.createAutomation(draft(kind: .agent, agentCommand: "claude", agentPrompt: nil, workspaceID: "ws-1")))
    }

    func testCreateAgentKindRejectsMissingWorkspaceID() throws {
        let (service, _) = try makeService()
        XCTAssertThrowsError(
            try service.createAutomation(draft(kind: .agent, agentCommand: "claude", agentPrompt: "do the thing", workspaceID: "  ")))
    }

    func testCreateAgentKindRejectsUnsupportedAgentCommand() throws {
        let (service, _) = try makeService()
        // A command that does not launch a supported coding agent (claude, codex, opencode) is rejected at
        // save time — the same gate the executor applies before spawning — so a typo like `bash` never
        // persists an automation whose every run would fail at launch.
        XCTAssertThrowsError(
            try service.createAutomation(draft(kind: .agent, agentCommand: "bash", agentPrompt: "do the thing", workspaceID: "ws-1"))
        ) { error in XCTAssertTrue(error is AutomationValidationError, "an unspawnable agent command is a validation error") }
    }

    func testCreateAgentKindAcceptsSupportedAgentCommand() throws {
        let (service, _) = try makeService()
        let automation = try service.createAutomation(
            draft(kind: .agent, script: "", agentCommand: "claude", agentPrompt: "do the thing", workspaceID: "ws-1"))
        XCTAssertEqual(automation.agentCommand, "claude", "a supported coding agent command validates")
    }

    func testCreateAgentKindAcceptsAllRequiredFields() throws {
        let (service, _) = try makeService()
        let automation = try service.createAutomation(
            draft(kind: .agent, script: "", agentCommand: "claude", agentPrompt: "do the thing", workspaceID: "ws-1"))
        XCTAssertEqual(automation.kind, .agent)
        XCTAssertEqual(automation.agentCommand, "claude")
        XCTAssertEqual(automation.agentPrompt, "do the thing")
        XCTAssertEqual(automation.workspaceID, "ws-1")
        XCTAssertEqual(automation.script, "", "an agent-kind automation's script is normalized to empty")
    }

    func testCreateRejectsNonPositiveTimeout() throws {
        let (service, _) = try makeService()
        XCTAssertThrowsError(try service.createAutomation(draft(timeoutSeconds: 0)))
    }

    func testCreateRejectsCronTriggerWithoutExpression() throws {
        let (service, _) = try makeService()
        XCTAssertThrowsError(try service.createAutomation(draft(trigger: .cron, cron: nil)))
    }

    func testCreateRejectsUnparseableCron() throws {
        let (service, _) = try makeService()
        XCTAssertThrowsError(try service.createAutomation(draft(trigger: .cron, cron: "not a cron"))) { error in
            XCTAssertTrue(error is AutomationValidationError || error is AutomationCronScheduleError)
        }
    }

    func testCreateRejectsManualTriggerCarryingCron() throws {
        let (service, _) = try makeService()
        XCTAssertThrowsError(try service.createAutomation(draft(trigger: .manual, cron: "* * * * *")))
    }

    func testCreateAcceptsValidCronAndComputesNextFireTime() throws {
        let (service, store) = try makeService()
        let automation = try service.createAutomation(draft(trigger: .cron, cron: "*/15 * * * *"))
        XCTAssertEqual(automation.triggerKind, .cron)
        XCTAssertNotNil(automation.nextFireTime, "an enabled cron automation gets an initial next fire time")
        XCTAssertEqual(try store.automation(id: automation.id)?.cronExpression, "*/15 * * * *")
    }

    func testCreateRejectsCronWithNoFutureOccurrence() throws {
        let (service, store) = try makeService()

        XCTAssertThrowsError(try service.createAutomation(draft(trigger: .cron, cron: "0 0 30 2 *"))) { error in
            XCTAssertTrue(error is AutomationValidationError)
        }
        XCTAssertTrue(try store.automations().isEmpty, "an enabled schedule that can never fire is not persisted")
    }

    func testCreateDisabledCronDoesNotComputeNextFireTime() throws {
        let (service, _) = try makeService()
        let automation = try service.createAutomation(draft(enabled: false, trigger: .cron, cron: "*/15 * * * *"))
        XCTAssertNil(automation.nextFireTime, "a disabled cron automation has no schedule anchor")
    }

    func testCreateManualHasNoNextFireTime() throws {
        let (service, _) = try makeService()
        let automation = try service.createAutomation(draft(trigger: .manual))
        XCTAssertNil(automation.nextFireTime)
    }

    // MARK: - Update

    func testUpdatePreservesIdentityAndCreationTime() throws {
        let (service, _) = try makeService()
        let created = try service.createAutomation(draft(name: "First"))
        let updated = try service.updateAutomation(id: created.id, draft: draft(name: "Renamed"))
        XCTAssertEqual(updated.id, created.id)
        XCTAssertEqual(updated.createdAt, created.createdAt)
        XCTAssertEqual(updated.name, "Renamed")
    }

    func testUpdateToDisabledClearsNextFireTime() throws {
        let (service, store) = try makeService()
        let created = try service.createAutomation(draft(trigger: .cron, cron: "*/15 * * * *"))
        XCTAssertNotNil(created.nextFireTime)
        _ = try service.updateAutomation(id: created.id, draft: draft(enabled: false, trigger: .cron, cron: "*/15 * * * *"))
        XCTAssertNil(try store.automation(id: created.id)?.nextFireTime, "disabling a cron automation drops its schedule anchor")
    }

    func testUpdateFromCronToManualClearsNextFireTime() throws {
        let (service, store) = try makeService()
        let created = try service.createAutomation(draft(trigger: .cron, cron: "*/15 * * * *"))
        _ = try service.updateAutomation(id: created.id, draft: draft(trigger: .manual))
        XCTAssertNil(try store.automation(id: created.id)?.nextFireTime)
    }

    func testUpdateMissingAutomationThrows() throws {
        let (service, _) = try makeService()
        XCTAssertThrowsError(try service.updateAutomation(id: "missing", draft: draft()))
    }

    // MARK: - Trigger / cancel / delete not-found

    func testTriggerMissingAutomationThrows() throws {
        let (service, _) = try makeService()
        XCTAssertThrowsError(try service.triggerAutomation(id: "missing"))
    }

    func testCancelMissingRunThrows() throws {
        let (service, _) = try makeService()
        XCTAssertThrowsError(try service.cancelAutomationRun(runID: "missing"))
    }

    func testDeleteMissingAutomationThrows() throws {
        let (service, _) = try makeService()
        XCTAssertThrowsError(try service.deleteAutomationCommand(id: "missing"))
    }

    // MARK: - Listing

    func testListAutomationsReturnsCreated() throws {
        let (service, _) = try makeService()
        _ = try service.createAutomation(draft(name: "A"))
        _ = try service.createAutomation(draft(name: "B"))
        XCTAssertEqual(Set(try service.listAutomations().map(\.name)), ["A", "B"])
    }

    // MARK: - Store roundtrip

    func testStoreRoundTripsScriptKindAutomation() throws {
        let (service, store) = try makeService()
        let created = try service.createAutomation(draft(name: "Nightly", script: "echo hi"))
        let reloaded = try XCTUnwrap(try store.automation(id: created.id))
        XCTAssertEqual(reloaded.kind, .script)
        XCTAssertEqual(reloaded.script, "echo hi")
        XCTAssertNil(reloaded.agentCommand)
        XCTAssertNil(reloaded.agentPrompt)
        XCTAssertEqual(reloaded.workspaceID, "ws-1")
    }

    func testStoreRoundTripsAgentKindAutomation() throws {
        let (service, store) = try makeService()
        let created = try service.createAutomation(
            draft(name: "Triage", kind: .agent, script: "", agentCommand: "claude", agentPrompt: "triage the inbox", workspaceID: "ws-1"))
        let reloaded = try XCTUnwrap(try store.automation(id: created.id))
        XCTAssertEqual(reloaded.kind, .agent)
        XCTAssertEqual(reloaded.script, "")
        XCTAssertEqual(reloaded.agentCommand, "claude")
        XCTAssertEqual(reloaded.agentPrompt, "triage the inbox")
        XCTAssertEqual(reloaded.workspaceID, "ws-1")
    }

    // MARK: - Wire summaries

    func testAutomationSummaryCarriesScheduleFields() throws {
        let (service, _) = try makeService()
        let automation = try service.createAutomation(
            draft(name: "Deploy", trigger: .cron, cron: "0 9 * * *", timeoutSeconds: 120, concurrency: .skip, missedRun: .skip))
        let summary = TerminalServiceAutomationSummary(automation)
        XCTAssertEqual(summary.name, "Deploy")
        XCTAssertEqual(summary.triggerKind, "cron")
        XCTAssertEqual(summary.cronExpression, "0 9 * * *")
        XCTAssertEqual(summary.timeoutSeconds, 120)
        XCTAssertEqual(summary.concurrencyPolicy, "skip")
        XCTAssertEqual(summary.missedRunPolicy, "skip")
        XCTAssertNotNil(summary.nextFireTime)
    }

    func testAutomationSummaryCarriesAgentKindFields() throws {
        let (service, _) = try makeService()
        let automation = try service.createAutomation(
            draft(name: "Triage", kind: .agent, script: "", agentCommand: "claude", agentPrompt: "triage the inbox", workspaceID: "ws-1"))
        let summary = TerminalServiceAutomationSummary(automation)
        XCTAssertEqual(summary.kind, "agent")
        XCTAssertEqual(summary.agentCommand, "claude")
        XCTAssertEqual(summary.agentPrompt, "triage the inbox")
        XCTAssertEqual(summary.workspaceID, "ws-1")
    }

    func testRunSummaryPreservesAlertRelevantFields() {
        let failed = AutomationRun(
            id: "run-1", automationID: "auto-1", kind: .script, status: .failed, skipReason: nil, trigger: .cron, exitCode: 3,
            terminalSessionID: "session-1", startedAt: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 105),
            createdAt: Date(timeIntervalSince1970: 99))
        let summary = TerminalServiceAutomationRunSummary(failed, automationName: "Deploy")
        XCTAssertEqual(summary.status, "failed")
        XCTAssertEqual(summary.kind, "script")
        XCTAssertEqual(summary.exitCode, 3)
        XCTAssertEqual(summary.automationName, "Deploy")
        XCTAssertEqual(summary.terminalSessionID, "session-1")

        let timedOut = AutomationRun(
            id: "run-2", automationID: "auto-1", kind: .agent, status: .timedOut, skipReason: nil, trigger: .manual, exitCode: nil,
            terminalSessionID: "session-2", startedAt: Date(timeIntervalSince1970: 200), endedAt: Date(timeIntervalSince1970: 260),
            createdAt: Date(timeIntervalSince1970: 199))
        XCTAssertEqual(TerminalServiceAutomationRunSummary(timedOut, automationName: "Deploy").kind, "agent")
        XCTAssertEqual(TerminalServiceAutomationRunSummary(timedOut, automationName: "Deploy").status, "timed_out")
    }

    func testRunSummaryWireTimestampPreservesFractionalOrdering() {
        let run = AutomationRun(
            id: "run-fractional", automationID: "auto-1", kind: .script, status: .failed, skipReason: nil, trigger: .manual, exitCode: 1,
            terminalSessionID: nil, startedAt: Date(timeIntervalSince1970: 200.125), endedAt: Date(timeIntervalSince1970: 200.875),
            createdAt: Date(timeIntervalSince1970: 199.125))

        let summary = TerminalServiceAutomationRunSummary(run, automationName: "Deploy")

        XCTAssertTrue(summary.endedAt?.contains(".875") == true)
        XCTAssertEqual(TerminalSessionTimestamp.date(from: summary.endedAt!), run.endedAt)
    }

    /// A run summary carrying attributed agents survives a JSON encode/decode round-trip unchanged — the
    /// contract every transport (profile response, Device API result, device overview) relies on.
    func testRunSummaryAttributedAgentsRoundTripThroughJSON() throws {
        let run = AutomationRun(
            id: "run-1", automationID: "auto-1", kind: .agent, status: .succeeded, skipReason: nil, trigger: .manual, exitCode: nil,
            terminalSessionID: "session-1", startedAt: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 105),
            createdAt: Date(timeIntervalSince1970: 99))
        let agents = [
            TerminalServiceAutomationAgentSummary(terminalSessionID: "session-1", status: "done", live: true, title: "Reviewer", workspaceID: "ws-1"),
            TerminalServiceAutomationAgentSummary(terminalSessionID: "session-2", status: "idle", live: true, title: nil, workspaceID: "ws-1"),
        ]
        let summary = TerminalServiceAutomationRunSummary(run, automationName: "Deploy", attributedAgents: agents)
        let decoded = try JSONDecoder().decode(TerminalServiceAutomationRunSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(decoded, summary)
        XCTAssertEqual(decoded.attributedAgents, agents)
    }
}
