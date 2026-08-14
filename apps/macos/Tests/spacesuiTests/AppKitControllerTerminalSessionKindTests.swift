import Testing
import spacesdevicecore
import spacesterminalcore

@testable import spacesui

/// Covers the pure kind resolution the ad-hoc-shell cleanup relies on: automation-run
/// sessions are workspace-less and never appear in `overview.sessions`, so resolution
/// must consult `automationRuns` before falling back to `.shell`. Otherwise closing a
/// live automation run's pane reaps the running scheduled command as if it were a stray
/// ad hoc shell.
@Suite struct AppKitControllerTerminalSessionKindTests {
    private func overview(runs: [TerminalServiceAutomationRunSummary]) -> SpacesDeviceOverviewPayload {
        SpacesDeviceOverviewPayload(workspaces: [], sessions: [], daemonStatus: .testStatus, automationRuns: runs)
    }

    private func run(
        terminalSessionID: String?, attributedAgents: [TerminalServiceAutomationAgentSummary] = []
    ) -> TerminalServiceAutomationRunSummary {
        TerminalServiceAutomationRunSummary(
            id: "run-1", automationID: "auto-1", automationName: "nightly", kind: "script", status: "running", trigger: "schedule",
            skipReason: nil, exitCode: nil, terminalSessionID: terminalSessionID, startedAt: nil, endedAt: nil, createdAt: "now",
            attributedAgents: attributedAgents)
    }

    @Test func runCommandSessionResolvesToAutomation() {
        let kind = AppKitController.terminalSessionKind(sessionID: "cmd-session", overviews: [overview(runs: [run(terminalSessionID: "cmd-session")])])
        #expect(kind == .automation)
    }

    @Test func attributedAgentSessionResolvesToAgent() {
        let agent = TerminalServiceAutomationAgentSummary(
            terminalSessionID: "agent-session", status: "idle", live: true, title: "claude", workspaceID: nil)
        let kind = AppKitController.terminalSessionKind(
            sessionID: "agent-session", overviews: [overview(runs: [run(terminalSessionID: "cmd-session", attributedAgents: [agent])])])
        #expect(kind == .agent)
    }

    @Test func unknownSessionFallsBackToShell() {
        let kind = AppKitController.terminalSessionKind(sessionID: "stray-shell", overviews: [overview(runs: [run(terminalSessionID: "cmd-session")])])
        #expect(kind == .shell)
    }
}
