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
        let service = AutomationService(
            store: store, orchestrator: WorkspaceOrchestrator(store: store), binaryDirectory: "/usr/bin", now: now, logError: { _ in })
        return (service, store)
    }

    private func draft(
        name: String = "Nightly", enabled: Bool = true, trigger: AutomationTriggerKind = .manual, cron: String? = nil, command: String = "echo hi",
        workingDirectory: String = "/tmp", timeoutSeconds: Int? = nil, concurrency: AutomationConcurrencyPolicy = .allow,
        missedRun: AutomationMissedRunPolicy = .runOnce
    ) -> AutomationDraft {
        AutomationDraft(
            name: name, enabled: enabled, triggerKind: trigger, cronExpression: cron, command: command, workingDirectory: workingDirectory,
            timeoutSeconds: timeoutSeconds, concurrencyPolicy: concurrency, missedRunPolicy: missedRun)
    }

    // MARK: - Validation

    func testCreateRejectsEmptyName() throws {
        let (service, _) = try makeService()
        XCTAssertThrowsError(try service.createAutomation(draft(name: "   ")))
    }

    func testCreateRejectsEmptyCommand() throws {
        let (service, _) = try makeService()
        XCTAssertThrowsError(try service.createAutomation(draft(command: "  ")))
    }

    func testCreateRejectsEmptyWorkingDirectory() throws {
        let (service, _) = try makeService()
        XCTAssertThrowsError(try service.createAutomation(draft(workingDirectory: "")))
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

    func testRunSummaryPreservesAlertRelevantFields() {
        let failed = AutomationRun(
            id: "run-1", automationID: "auto-1", status: .failed, skipReason: nil, trigger: .cron, exitCode: 3,
            terminalSessionID: "session-1", startedAt: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 105),
            createdAt: Date(timeIntervalSince1970: 99))
        let summary = TerminalServiceAutomationRunSummary(failed, automationName: "Deploy", liveAttributedSessionCount: 0)
        XCTAssertEqual(summary.status, "failed")
        XCTAssertEqual(summary.exitCode, 3)
        XCTAssertEqual(summary.automationName, "Deploy")
        XCTAssertEqual(summary.terminalSessionID, "session-1")

        let timedOut = AutomationRun(
            id: "run-2", automationID: "auto-1", status: .timedOut, skipReason: nil, trigger: .manual, exitCode: nil, terminalSessionID: "session-2",
            startedAt: Date(timeIntervalSince1970: 200), endedAt: Date(timeIntervalSince1970: 260), createdAt: Date(timeIntervalSince1970: 199))
        XCTAssertEqual(TerminalServiceAutomationRunSummary(timedOut, automationName: "Deploy", liveAttributedSessionCount: 1).status, "timed_out")
    }
}
