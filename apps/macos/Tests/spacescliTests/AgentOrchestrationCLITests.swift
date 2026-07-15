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
        XCTAssertEqual(SpacesTerminalDeepLink(sessionID: "session-1", deviceID: "device-9").absoluteString, "spaces://terminal/session-1?device=device-9")
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
                branch: "feature", updatedAt: "2026-07-14T00:00:00Z", lastSignalAt: "2026-07-14T00:00:00Z"))
        XCTAssertTrue(row.hasPrefix("session-1\t"))
        XCTAssertTrue(row.contains("agent=Claude Code CLI"))
        XCTAssertTrue(row.contains("status=waiting"))
        XCTAssertTrue(row.contains("ready=true"))
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
                projectName: "Spaces", workspaceID: "workspace-1", workspaceName: "feature", branch: nil, updatedAt: "2026-07-14T00:00:00Z",
                lastSignalAt: nil))
        XCTAssertTrue(row.contains("agent=-"))
        XCTAssertTrue(row.contains("note=-"))
        XCTAssertTrue(row.contains("branch=-"))
        XCTAssertTrue(row.contains("ready=false"))
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
            "--command", "codex --yolo", "--workspace", "workspace-1", "--title", "Reviewer", "--prompt", "reply pong", "--timeout", "30", "--json",
        ])
        XCTAssertEqual(spawn.command, "codex --yolo")
        XCTAssertEqual(spawn.workspace, "workspace-1")
        XCTAssertEqual(spawn.title, "Reviewer")
        XCTAssertEqual(spawn.prompt, "reply pong")
        XCTAssertEqual(spawn.timeout, 30)
        XCTAssertTrue(spawn.json)
    }

    func testAgentSpawnRequiresCommandAndDefaultsTimeout() throws {
        XCTAssertThrowsError(try AgentSpawnCommand.parse([]))
        let spawn = try AgentSpawnCommand.parse(["--command", "claude"])
        XCTAssertEqual(spawn.timeout, 90)
        XCTAssertFalse(spawn.json)
    }

    func testAgentInterruptAndKillTakeRequiredPositionalSession() throws {
        XCTAssertEqual(try AgentInterruptCommand.parse(["session-1"]).session, "session-1")
        XCTAssertEqual(try AgentKillCommand.parse(["session-1"]).session, "session-1")
        XCTAssertThrowsError(try AgentInterruptCommand.parse([]))
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
        XCTAssertEqual(
            try AgentSpawnCommand.parse(["--command", "claude", "--workspace", "workspace-1", "--device", "phone"]).device, "phone")
        XCTAssertEqual(try AgentInterruptCommand.parse(["session-1", "--device", "phone"]).device, "phone")
        XCTAssertEqual(try AgentKillCommand.parse(["session-1", "--device", "phone"]).device, "phone")
    }

    func testAgentSpawnWithDeviceRequiresWorkspace() throws {
        // The workspace guard runs before device resolution, so it fails deterministically without a
        // paired device.
        let spawn = try AgentSpawnCommand.parse(["--command", "claude", "--device", "phone"])
        XCTAssertThrowsError(try spawn.run()) { error in
            XCTAssertTrue("\(error)".contains("--workspace is required"), "\(error)")
        }
    }

    func testAgentSubscribeAndUnsubscribeRejectDeviceLoudly() throws {
        let subscribe = try AgentSubscribeCommand.parse(["child-session", "--device", "phone"])
        XCTAssertThrowsError(try subscribe.run()) { error in XCTAssertTrue("\(error)".contains("per-device"), "\(error)") }

        let unsubscribe = try AgentUnsubscribeCommand.parse(["child-session", "--device", "phone"])
        XCTAssertThrowsError(try unsubscribe.run()) { error in XCTAssertTrue("\(error)".contains("per-device"), "\(error)") }
    }

    // MARK: - Subscriber resolution

    func testResolvedSubscriberSessionIDPrefersExplicitThenEnvironment() throws {
        XCTAssertEqual(
            try resolvedSubscriberSessionID("explicit", environment: [WorkspaceOrchestrator.terminalTrackingIDEnvVar: "env-session"]), "explicit")
        XCTAssertEqual(
            try resolvedSubscriberSessionID(nil, environment: [WorkspaceOrchestrator.terminalTrackingIDEnvVar: "env-session"]), "env-session")
        XCTAssertThrowsError(try resolvedSubscriberSessionID(nil, environment: [:]))
    }

    func testAgentSpawnReadinessTimeoutErrorMessagePointsAtHooksAndTail() {
        let message = AgentSpawnReadinessTimeoutError(sessionID: "session-1", timeoutSeconds: 90).errorDescription
        XCTAssertEqual(
            message,
            "Agent session session-1 produced no lifecycle signal within 90s. Verify coding-agent hooks are installed and inspect with: spaces terminal tail session-1"
        )
    }
}
