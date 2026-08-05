import ArgumentParser
import Foundation
import XCTest
import spacesdevicecore
import spacesterminalcore
import workspacecore

@testable import spacescli

final class AgentOrchestrationCLITests: XCTestCase {
    // MARK: - Deep link render/parse

    func testTerminalDeepLinkRendersLocalAndDeviceQualified() {
        XCTAssertEqual(SpacesTerminalDeepLink(sessionID: "session-1").absoluteString, "spaces://terminal/session-1")
        XCTAssertEqual(
            SpacesTerminalDeepLink(sessionID: "session-1", deviceID: "device-9").absoluteString, "spaces://terminal/session-1?device=device-9")
    }

    func testTerminalDeepLinkParsesLocalAndDeviceQualified() {
        let local = SpacesTerminalDeepLink.parse("spaces://terminal/session-1")
        XCTAssertEqual(local?.sessionID, "session-1")
        XCTAssertNil(local?.deviceID)

        let remote = SpacesTerminalDeepLink.parse("spaces://terminal/session-1?device=device-9")
        XCTAssertEqual(remote?.sessionID, "session-1")
        XCTAssertEqual(remote?.deviceID, "device-9")
    }

    func testTerminalDeepLinkParseRejectsNonTerminalLinks() {
        XCTAssertNil(SpacesTerminalDeepLink.parse("https://terminal/session-1"))
        XCTAssertNil(SpacesTerminalDeepLink.parse("spaces://pair?code=abc"))
        XCTAssertNil(SpacesTerminalDeepLink.parse("spaces://terminal"))
        XCTAssertNil(SpacesTerminalDeepLink.parse("spaces://terminal/session-1/extra"))
    }

    func testTerminalDeepLinkRoundTrips() {
        let link = SpacesTerminalDeepLink(sessionID: "session-1", deviceID: "device-9")
        XCTAssertEqual(SpacesTerminalDeepLink.parse(link.absoluteString), link)
    }

    // MARK: - Row rendering

    func testAgentSessionRowRendersKeyValueColumns() {
        let row = agentSessionRow(
            TerminalServiceAgentSessionRow(
                id: "agent-1", terminalSessionID: "session-1", agent: "Claude Code CLI", label: "Claude Code CLI", status: "waiting",
                note: "review auth", projectID: "project-1", projectName: "Spaces", workspaceID: "workspace-1", workspaceName: "feature",
                workspaceDir: "/repo/workspaces/feature", branch: "feature", updatedAt: "2026-07-14T00:00:00Z", lastSignalAt: "2026-07-14T00:00:00Z"))
        XCTAssertTrue(row.hasPrefix("session-1\t"))
        XCTAssertTrue(row.contains("agent=Claude Code CLI"))
        XCTAssertTrue(row.contains("status=waiting"))
        XCTAssertTrue(row.contains("signaled=true"))
        XCTAssertTrue(row.contains("note=review auth"))
        XCTAssertTrue(row.contains("project=Spaces"))
        XCTAssertTrue(row.contains("workspace=feature"))
        XCTAssertTrue(row.contains("branch=feature"))
        XCTAssertTrue(row.contains("open=spaces://terminal/session-1"))
    }

    func testAgentSessionRowRendersDashesForMissingValuesAndUnready() {
        let row = agentSessionRow(
            TerminalServiceAgentSessionRow(
                id: "agent-2", terminalSessionID: "session-2", agent: nil, label: nil, status: "idle", note: nil, projectID: "project-1",
                projectName: "Spaces", workspaceID: "workspace-1", workspaceName: "feature", workspaceDir: "/repo/workspaces/feature", branch: nil,
                updatedAt: "2026-07-14T00:00:00Z", lastSignalAt: nil))
        XCTAssertTrue(row.contains("agent=-"))
        XCTAssertTrue(row.contains("note=-"))
        XCTAssertTrue(row.contains("branch=-"))
        XCTAssertTrue(row.contains("signaled=false"))
    }

    // MARK: - JSON presentation row

    func testAgentSessionRowJSONFromLocalRowCarriesUnqualifiedOpenLinkAndNilDeviceID() {
        let json = AgentSessionRowJSON(
            TerminalServiceAgentSessionRow(
                id: "agent-1", terminalSessionID: "session-1", agent: "Claude Code CLI", label: "Claude Code CLI", status: "waiting",
                note: "review auth", projectID: "project-1", projectName: "Spaces", workspaceID: "workspace-1", workspaceName: "feature",
                workspaceDir: "/repo/workspaces/feature", branch: "feature", updatedAt: "2026-07-14T00:00:00Z", lastSignalAt: "2026-07-14T00:00:00Z"))
        XCTAssertEqual(json.terminalSessionID, "session-1")
        XCTAssertNil(json.deviceID)
        XCTAssertEqual(json.open, "spaces://terminal/session-1")
    }

    func testAgentSessionRowJSONFromDeviceRowCarriesDeviceQualifiedOpenLinkAndDeviceID() {
        let json = AgentSessionRowJSON(
            SpacesDeviceAgentSessionRow(
                id: "agent-1", terminalSessionID: "session-1", agent: "Claude Code CLI", label: "Claude Code CLI", status: "waiting",
                note: "review auth", projectID: "project-1", projectName: "Spaces", workspaceID: "workspace-1", workspaceName: "feature",
                workspaceDir: "/repo/workspaces/feature", branch: "feature", updatedAt: "2026-07-14T00:00:00Z", lastSignalAt: "2026-07-14T00:00:00Z"),
            deviceID: "device-9")
        XCTAssertEqual(json.terminalSessionID, "session-1")
        XCTAssertEqual(json.deviceID, "device-9")
        XCTAssertEqual(json.open, "spaces://terminal/session-1?device=device-9")
    }

    func testAgentSessionRowJSONResolvesSessionIDMatchingTextPath() {
        // The text path resolves `row.terminalSessionID ?? row.id`; the JSON row must match exactly so
        // structured and text output never disagree on which session a row addresses.
        let row = TerminalServiceAgentSessionRow(
            id: "agent-1", terminalSessionID: nil, agent: nil, label: nil, status: "idle", note: nil, projectID: "project-1", projectName: "Spaces",
            workspaceID: "workspace-1", workspaceName: "feature", workspaceDir: "/repo/workspaces/feature", branch: nil,
            updatedAt: "2026-07-14T00:00:00Z", lastSignalAt: nil)
        let json = AgentSessionRowJSON(row)
        XCTAssertEqual(json.terminalSessionID, "agent-1")
        XCTAssertEqual(json.open, "spaces://terminal/agent-1")
    }

    func testAgentSessionRowJSONEncodesOpenAndDeviceIDKeys() throws {
        let json = AgentSessionRowJSON(
            SpacesDeviceAgentSessionRow(
                id: "agent-1", terminalSessionID: "session-1", agent: "codex", label: "codex", status: "blocked", note: nil, projectID: "project-1",
                projectName: "Spaces", workspaceID: "workspace-1", workspaceName: "feature", workspaceDir: "/repo/workspaces/feature", branch: nil,
                updatedAt: "2026-07-14T00:00:00Z", lastSignalAt: nil), deviceID: "device-9")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(json)) as? [String: Any]
        XCTAssertEqual(encoded?["open"] as? String, "spaces://terminal/session-1?device=device-9")
        XCTAssertEqual(encoded?["deviceID"] as? String, "device-9")
        XCTAssertEqual(encoded?["terminalSessionID"] as? String, "session-1")
    }

    // MARK: - Session resolution

    func testResolvedAgentSessionIDPrefersExplicitOverEnvironment() throws {
        let resolved = try resolvedAgentSessionID("explicit-session", environment: [WorkspaceOrchestrator.terminalTrackingIDEnvVar: "env-session"])
        XCTAssertEqual(resolved, "explicit-session")
    }

    func testResolvedAgentSessionIDFallsBackToEnvironment() throws {
        let resolved = try resolvedAgentSessionID(nil, environment: [WorkspaceOrchestrator.terminalTrackingIDEnvVar: "env-session"])
        XCTAssertEqual(resolved, "env-session")
    }

    func testResolvedAgentSessionIDThrowsWhenNeitherPresent() {
        XCTAssertThrowsError(try resolvedAgentSessionID(nil, environment: [:]))
        XCTAssertThrowsError(try resolvedAgentSessionID("   ", environment: [:]))
    }

    // MARK: - Command parsing

    func testAgentListParsesWorkspaceAndJSON() throws {
        let command = try AgentListCommand.parse(["--workspace", "workspace-1", "--json"])
        XCTAssertEqual(command.workspace, "workspace-1")
        XCTAssertTrue(command.json)
    }

    func testAgentStatusAndAnnotateParseSessionDefaults() throws {
        let status = try AgentStatusCommand.parse(["--session", "session-1", "--json"])
        XCTAssertEqual(status.session, "session-1")
        XCTAssertTrue(status.json)

        let annotate = try AgentAnnotateCommand.parse(["review the auth flow", "--session", "session-1"])
        XCTAssertEqual(annotate.note, "review the auth flow")
        XCTAssertEqual(annotate.session, "session-1")
    }

    func testAgentSpawnParsesAllOptions() throws {
        let spawn = try AgentSpawnCommand.parse([
            "--command", "codex --yolo", "--workspace", "workspace-1", "--title", "Reviewer", "--timeout", "30", "--json",
        ])
        XCTAssertEqual(spawn.command, "codex --yolo")
        XCTAssertEqual(spawn.workspace, "workspace-1")
        XCTAssertEqual(spawn.title, "Reviewer")
        XCTAssertEqual(spawn.timeout, 30)
        XCTAssertTrue(spawn.json)
    }

    func testAgentSpawnRequiresCommandAndDefaultsTimeout() throws {
        XCTAssertThrowsError(try AgentSpawnCommand.parse([]))
        let spawn = try AgentSpawnCommand.parse(["--command", "claude"])
        XCTAssertEqual(spawn.timeout, 90)
        XCTAssertFalse(spawn.json)
    }

    func testAgentKillTakesRequiredPositionalSession() throws {
        XCTAssertEqual(try AgentKillCommand.parse(["session-1"]).session, "session-1")
        XCTAssertThrowsError(try AgentKillCommand.parse([]))
    }

    func testAgentSubscribeParsesSessionAndSubscriber() throws {
        let subscribe = try AgentSubscribeCommand.parse(["child-session", "--subscriber", "orchestrator-session"])
        XCTAssertEqual(subscribe.session, "child-session")
        XCTAssertEqual(subscribe.subscriber, "orchestrator-session")

        let unsubscribe = try AgentUnsubscribeCommand.parse(["child-session"])
        XCTAssertEqual(unsubscribe.session, "child-session")
        XCTAssertNil(unsubscribe.subscriber)
    }

    func testOrchestrationCommandsAcceptDeviceOption() throws {
        XCTAssertEqual(try AgentListCommand.parse(["--device", "phone"]).device, "phone")
        XCTAssertEqual(try AgentStatusCommand.parse(["--device", "phone"]).device, "phone")
        XCTAssertEqual(try AgentAnnotateCommand.parse(["note", "--device", "phone"]).device, "phone")
        XCTAssertEqual(try AgentSpawnCommand.parse(["--command", "claude", "--workspace", "workspace-1", "--device", "phone"]).device, "phone")
        XCTAssertEqual(try AgentKillCommand.parse(["session-1", "--device", "phone"]).device, "phone")
    }

    func testAgentSpawnWithDeviceRequiresWorkspace() throws {
        // The workspace guard runs before device resolution, so it fails deterministically without a
        // paired device.
        let spawn = try AgentSpawnCommand.parse(["--command", "claude", "--device", "phone"])
        XCTAssertThrowsError(try spawn.run()) { error in XCTAssertTrue("\(error)".contains("--workspace is required"), "\(error)") }
    }

    func testAgentSubscribeAndUnsubscribeAcceptDeviceForCrossDeviceWatch() throws {
        let subscribe = try AgentSubscribeCommand.parse(["child-session", "--subscriber", "orch-session", "--device", "phone"])
        XCTAssertEqual(subscribe.session, "child-session")
        XCTAssertEqual(subscribe.subscriber, "orch-session")
        XCTAssertEqual(subscribe.device, "phone")

        let unsubscribe = try AgentUnsubscribeCommand.parse(["child-session", "--device", "phone"])
        XCTAssertEqual(unsubscribe.session, "child-session")
        XCTAssertEqual(unsubscribe.device, "phone")
    }

    // MARK: - Subscriber resolution

    func testResolvedSubscriberSessionIDPrefersExplicitThenEnvironment() throws {
        XCTAssertEqual(
            try resolvedSubscriberSessionID("explicit", environment: [WorkspaceOrchestrator.terminalTrackingIDEnvVar: "env-session"]), "explicit")
        XCTAssertEqual(
            try resolvedSubscriberSessionID(nil, environment: [WorkspaceOrchestrator.terminalTrackingIDEnvVar: "env-session"]), "env-session")
        XCTAssertThrowsError(try resolvedSubscriberSessionID(nil, environment: [:]))
    }

    // MARK: - Automation run id resolution

    func testResolvedAutomationRunIDReturnsTrimmedEnvironmentValue() {
        XCTAssertEqual(resolvedAutomationRunID(environment: [WorkspaceOrchestrator.automationRunIDEnvVar: "  run-1  "]), "run-1")
    }

    func testResolvedAutomationRunIDIsNilWhenUnsetOrEmpty() {
        XCTAssertNil(resolvedAutomationRunID(environment: [:]))
        XCTAssertNil(resolvedAutomationRunID(environment: [WorkspaceOrchestrator.automationRunIDEnvVar: "   "]))
    }

    func testAgentSpawnDetectionTimeoutErrorNamesCommandAndTail() {
        let message = AgentSpawnDetectionTimeoutError(sessionID: "session-1", command: "codex", timeoutSeconds: 90).errorDescription
        XCTAssertEqual(
            message,
            "Agent session session-1 was not detected as a running coding agent within 90s (foreground classification never identified `codex`). The session is left running; inspect with: spaces terminal tail session-1"
        )
    }

    func testAgentSpawnRemoteDetectionTimeoutErrorNamesCommandAndRemoteTail() {
        let message = AgentSpawnRemoteDetectionTimeoutError(sessionID: "session-1", command: "codex", timeoutSeconds: 90).errorDescription
        XCTAssertEqual(
            message,
            "Remote agent session session-1 was not detected as a running coding agent within 90s (foreground classification never identified `codex`). The session is left running; inspect with: spaces terminal tail session-1 --device <name>"
        )
    }

    func testAgentSpawnResultLineLeadsWithSessionAndReportsDetection() {
        let line = agentSpawnResultLine(
            AgentSpawnResult(terminalSessionID: "session-1", workspaceID: "workspace-1", detectedAgent: "codex", deviceID: nil, subscribed: true))
        XCTAssertTrue(line.hasPrefix("session-1\t"))
        XCTAssertTrue(line.contains("detected=codex"))
        XCTAssertTrue(line.contains("workspace=workspace-1"))
        XCTAssertFalse(line.contains("prompt_submitted"))
        XCTAssertTrue(line.contains("subscribed=true"))
        XCTAssertTrue(line.contains("open=spaces://terminal/session-1"))
    }

    func testAgentSpawnResultLineRendersDashForMissingWorkspace() {
        let line = agentSpawnResultLine(
            AgentSpawnResult(terminalSessionID: "session-2", workspaceID: nil, detectedAgent: "claude", deviceID: nil, subscribed: false))
        XCTAssertTrue(line.contains("workspace=-"))
        XCTAssertTrue(line.contains("subscribed=false"))
    }

    func testAgentSpawnResultLineDeviceQualifiesDeepLinkForRemoteSpawn() {
        let line = agentSpawnResultLine(
            AgentSpawnResult(
                terminalSessionID: "session-3", workspaceID: "workspace-2", detectedAgent: "opencode", deviceID: "device-9", subscribed: false))
        XCTAssertTrue(line.contains("open=\(SpacesTerminalDeepLink(sessionID: "session-3", deviceID: "device-9").absoluteString)"))
    }

    func testAgentSpawnResultJSONCarriesUnqualifiedOpenLinkForLocalSpawn() throws {
        let result = AgentSpawnResult(
            terminalSessionID: "session-1", workspaceID: "workspace-1", detectedAgent: "codex", deviceID: nil, subscribed: true)
        XCTAssertEqual(result.open, "spaces://terminal/session-1")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any]
        XCTAssertEqual(encoded?["open"] as? String, "spaces://terminal/session-1")
        XCTAssertNil(encoded?["deviceID"] as? String)
    }

    func testAgentSpawnResultJSONCarriesDeviceQualifiedOpenLinkForRemoteSpawn() throws {
        let result = AgentSpawnResult(
            terminalSessionID: "session-3", workspaceID: "workspace-2", detectedAgent: "opencode", deviceID: "device-9", subscribed: false)
        XCTAssertEqual(result.open, SpacesTerminalDeepLink(sessionID: "session-3", deviceID: "device-9").absoluteString)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any]
        XCTAssertEqual(encoded?["open"] as? String, "spaces://terminal/session-3?device=device-9")
        XCTAssertEqual(encoded?["deviceID"] as? String, "device-9")
    }

    func testAgentSpawnResultJSONOpenMatchesTextLineOpenValue() {
        // Both the text row and --json render `open` from the same `AgentSpawnResult.open` field, so they
        // can never disagree on the deep link. Covers local and device-qualified spawns.
        for result in [
            AgentSpawnResult(terminalSessionID: "session-1", workspaceID: "workspace-1", detectedAgent: "codex", deviceID: nil, subscribed: true),
            AgentSpawnResult(
                terminalSessionID: "session-3", workspaceID: "workspace-2", detectedAgent: "opencode", deviceID: "device-9", subscribed: false),
        ] {
            let line = agentSpawnResultLine(result)
            XCTAssertTrue(line.hasSuffix("open=\(result.open)"))
        }
    }

    // MARK: - Readiness phases

    /// A deterministic clock: `now()` advances one `step` per read so bounded polls terminate without
    /// real time. Paired with a no-op sleep so tests never block.
    private final class FakeClock {
        private var current: Date
        private let step: TimeInterval
        init(start: Date = Date(timeIntervalSince1970: 0), step: TimeInterval = 0.5) {
            current = start
            self.step = step
        }
        func now() -> Date {
            defer { current = current.addingTimeInterval(step) }
            return current
        }
    }

    func testAwaitReadinessReturnsDetectedKindOncePresent() throws {
        let clock = FakeClock()
        var reads = 0
        let outcome = try AgentSpawnReadiness.awaitReadiness(
            deadline: Date(timeIntervalSince1970: 100), pollInterval: 0.5, now: clock.now, sleep: { _ in }
        ) {
            reads += 1
            return .init(detectedKind: reads >= 3 ? .codex : nil, state: .running)
        }
        XCTAssertEqual(outcome, .detected(.codex))
        XCTAssertEqual(reads, 3)
    }

    func testAwaitReadinessTimesOutWhileTheChildKeepsRunningUndetected() throws {
        let clock = FakeClock(step: 40)
        let outcome = try AgentSpawnReadiness.awaitReadiness(
            deadline: Date(timeIntervalSince1970: 90), pollInterval: 0.5, now: clock.now, sleep: { _ in }
        ) { .init(detectedKind: nil, state: .running) }
        XCTAssertEqual(outcome, .timedOut)
    }

    /// The fail-fast: a child that dies is reported on the very poll that sees it, instead of costing the
    /// whole detection budget (the failure `spaces agent spawn` hits for an unresolvable command).
    func testAwaitReadinessEndsAsSoonAsTheChildExitsWithoutWaitingOutTheDeadline() throws {
        let clock = FakeClock()
        var reads = 0
        let outcome = try AgentSpawnReadiness.awaitReadiness(
            deadline: Date(timeIntervalSince1970: 90), pollInterval: 0.5, now: clock.now, sleep: { _ in }
        ) {
            reads += 1
            return .init(detectedKind: nil, state: reads >= 2 ? .exited : .starting)
        }
        XCTAssertEqual(outcome, .ended(.exited))
        XCTAssertEqual(reads, 2)
    }

    func testAwaitReadinessReportsAFailedChildAsEnded() throws {
        let outcome = try AgentSpawnReadiness.awaitReadiness(
            deadline: Date(timeIntervalSince1970: 90), pollInterval: 0.5, now: FakeClock().now, sleep: { _ in }
        ) { .init(detectedKind: nil, state: .failed) }
        XCTAssertEqual(outcome, .ended(.failed))
    }

    /// A classification read in the same poll as an ended child is stale — the session cannot be
    /// prompted — so the exit wins and spawn fails rather than returning a dead session as ready.
    func testAwaitReadinessPrefersTheChildExitOverAStaleClassification() throws {
        let outcome = try AgentSpawnReadiness.awaitReadiness(
            deadline: Date(timeIntervalSince1970: 90), pollInterval: 0.5, now: FakeClock().now, sleep: { _ in }
        ) { .init(detectedKind: .claude, state: .exited) }
        XCTAssertEqual(outcome, .ended(.exited))
    }

    /// A session that is not reported at all keeps the wait polling: only a state that says the child
    /// ended ends it early.
    func testAwaitReadinessKeepsPollingWhileTheSessionReportsNoState() throws {
        let clock = FakeClock(step: 40)
        let outcome = try AgentSpawnReadiness.awaitReadiness(
            deadline: Date(timeIntervalSince1970: 90), pollInterval: 0.5, now: clock.now, sleep: { _ in }
        ) { .init(detectedKind: nil, state: nil) }
        XCTAssertEqual(outcome, .timedOut)
    }

    // MARK: - Absent runtime-state row (spawnedSessionSnapshot's unknown-session race)

    private struct UnexpectedSnapshotReadError: Error {}

    /// The daemon's session-start response can return before the `terminal_runtime_states` row's write
    /// commits, so the very first poll can see `TerminalSessionPersistenceError.unknownSession`. That must
    /// not fail the spawn: `snapshotOrPending` (the policy `spawnedSessionSnapshot` applies to its read)
    /// turns it into a pending snapshot, so the poll loop reads again and resolves once the row appears —
    /// no throw ever reaches `awaitReadiness`'s caller.
    func testAwaitReadinessResolvesDetectedAfterAnUnknownSessionReadOnTheFirstPoll() throws {
        var reads = 0
        let outcome = try AgentSpawnReadiness.awaitReadiness(
            deadline: Date(timeIntervalSince1970: 100), pollInterval: 0.5, now: FakeClock().now, sleep: { _ in }
        ) {
            reads += 1
            return try snapshotOrPending {
                if reads == 1 { throw TerminalSessionPersistenceError.unknownSession("session-race") }
                return .init(detectedKind: .codex, state: .running)
            }
        }
        XCTAssertEqual(outcome, .detected(.codex))
        XCTAssertEqual(reads, 2)
    }

    /// Only the specific unknown-session case is swallowed. A genuinely broken read (a corrupt profile
    /// database, for instance) must still fail loudly rather than being polled away forever.
    func testSnapshotOrPendingPropagatesAnyErrorOtherThanUnknownSession() {
        XCTAssertThrowsError(try snapshotOrPending { throw UnexpectedSnapshotReadError() }) { error in
            XCTAssertTrue(error is UnexpectedSnapshotReadError, "\(error)")
        }
    }

    // MARK: - Spawn failure reporting

    func testSpawnChildExitedErrorNamesTheChildExitAndItsLastOutput() {
        let message = AgentSpawnChildExitedError(
            sessionID: "session-1", command: "claude --model haiku", state: .exited, lastOutputLines: ["zsh:1: command not found: claude"],
            deviceName: nil
        ).errorDescription
        XCTAssertEqual(
            message,
            "Agent session session-1 exited before it was detected as a running coding agent: `claude --model haiku` did not stay running. Last output: zsh:1: command not found: claude. Inspect with: spaces terminal tail session-1"
        )
        // The cause is the child's exit, not the classifier that never got to see it.
        XCTAssertFalse(message?.contains("foreground classification") == true)
    }

    func testSpawnChildExitedErrorReportsNoOutputAndQualifiesARemoteInspectHint() {
        let message = AgentSpawnChildExitedError(sessionID: "session-2", command: "codex", state: .failed, lastOutputLines: [], deviceName: "studio")
            .errorDescription
        XCTAssertEqual(
            message,
            "Agent session session-2 failed before it was detected as a running coding agent: `codex` did not stay running. It produced no output. Inspect with: spaces terminal tail session-2 --device 'studio'"
        )
    }

    /// A device name containing a space (e.g. "Mac Studio") must not split into two shell arguments when
    /// the hint is pasted, and any shell metacharacters in the name must not be interpreted either.
    func testSpawnChildExitedErrorShellQuotesADeviceNameContainingASpace() {
        let message = AgentSpawnChildExitedError(
            sessionID: "session-4", command: "claude", state: .exited, lastOutputLines: [], deviceName: "Mac Studio"
        ).errorDescription
        XCTAssertEqual(
            message,
            "Agent session session-4 exited before it was detected as a running coding agent: `claude` did not stay running. It produced no output. Inspect with: spaces terminal tail session-4 --device 'Mac Studio'"
        )
    }

    func testLastNonBlankLinesDropsTheBlankPaddingOfARenderedTail() {
        let tail = "\n$ claude\nzsh:1: command not found: claude\n   \n\n"
        XCTAssertEqual(AgentSpawnReadiness.lastNonBlankLines(inTail: tail), ["$ claude", "zsh:1: command not found: claude"])
    }

    func testLastNonBlankLinesKeepsOnlyTheTrailingLinesUpToTheLimit() {
        let tail = (1...10).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(AgentSpawnReadiness.lastNonBlankLines(inTail: tail, limit: 2), ["line 9", "line 10"])
        XCTAssertEqual(AgentSpawnReadiness.lastNonBlankLines(inTail: ""), [])
    }
}
