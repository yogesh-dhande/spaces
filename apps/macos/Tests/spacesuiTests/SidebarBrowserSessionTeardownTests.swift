import Testing
import workspacecore

@testable import spacesui

/// Covers the transition diff that drives browser-session teardown from a daemon-driven sidebar
/// reload, the channel through which stop/archive actions taken outside the GUI (CLI, MCP, the
/// Device API, or another device) reach the client.
struct SidebarBrowserSessionTeardownTests {
    private func status(_ id: String, isRunning: Bool) -> WorkspaceRuntimeStatus {
        WorkspaceRuntimeStatus(
            workspaceID: id, lifecycleState: WorkspaceLifecycleState(isRunning: isRunning), runtimeHealth: .healthy,
            hasTrackedRuntimeIndicators: false, runningProcessCount: 0, exitedProcessCount: 0, waitingAgentWindowCount: 0,
            missingConfiguredProcessCount: 0, missingConfiguredBrowserSessionCount: 0)
    }

    @Test func reportsWorkspaceThatStoppedSinceLastOverview() {
        let ids = SidebarController.workspaceIDsTransitionedToNotRunning(
            previous: ["ws-1": status("ws-1", isRunning: true)], current: ["ws-1": status("ws-1", isRunning: false)])
        #expect(ids == ["ws-1"])
    }

    @Test func reportsWorkspaceThatDisappearedFromRuntimeMap() {
        // Archive/delete drops the workspace out of the overview entirely; it still needs teardown.
        let ids = SidebarController.workspaceIDsTransitionedToNotRunning(previous: ["ws-1": status("ws-1", isRunning: true)], current: [:])
        #expect(ids == ["ws-1"])
    }

    @Test func ignoresWorkspaceStillRunning() {
        let ids = SidebarController.workspaceIDsTransitionedToNotRunning(
            previous: ["ws-1": status("ws-1", isRunning: true)], current: ["ws-1": status("ws-1", isRunning: true)])
        #expect(ids.isEmpty)
    }

    @Test func ignoresWorkspaceAlreadyStoppedBeforeAndAfter() {
        // A stopped workspace re-observed on a later reload must not re-trigger teardown.
        let ids = SidebarController.workspaceIDsTransitionedToNotRunning(
            previous: ["ws-1": status("ws-1", isRunning: false)], current: ["ws-1": status("ws-1", isRunning: false)])
        #expect(ids.isEmpty)
    }

    @Test func ignoresWorkspaceThatStartedRunning() {
        let ids = SidebarController.workspaceIDsTransitionedToNotRunning(
            previous: ["ws-1": status("ws-1", isRunning: false)], current: ["ws-1": status("ws-1", isRunning: true)])
        #expect(ids.isEmpty)
    }
}
