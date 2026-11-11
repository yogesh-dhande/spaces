import Foundation
import Testing
import spacesdevicecore
import workspacecore

@testable import spacesdeviceapi
@testable import spacesterminalcore
@testable import spacesui

/// Runs the real overview builder over a lost shell before and after the device replaces it, then feeds both
/// overviews to the client-side decisions. This is what a second Mac client sees: it never sent the
/// request, so the overview pair is its only signal.
@Suite struct LostShellOverviewFollowTests {
    private let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main", kind: .standard)
    private let workspace = WorkspaceRecord(
        id: "workspace-1", projectID: "project-1", dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false, isRunning: true,
        lastLaunchedAt: nil)

    private func entry(sessionID: String, state: TerminalSessionState, createdAt: String) -> TerminalSessionCatalogEntry {
        TerminalSessionCatalogEntry(
            launchConfiguration: TerminalSessionLaunchConfiguration(
                sessionID: sessionID, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: "Shell", workingDirectory: "/repo/feature",
                shell: "/bin/zsh", command: nil, createdAt: createdAt, workspaceID: "workspace-1", kind: .shell),
            runtimeState: TerminalSessionRuntimeState(
                sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 321, childPID: 654, state: state, updatedAt: createdAt, title: nil,
                workingDirectory: "/repo/feature"), attachmentSnapshot: TerminalSessionAttachmentSnapshot(),
            paths: TerminalSessionPaths(rootDirectory: "/tmp/\(sessionID)"), isControlAvailable: state == .running,
            isSubscriptionAvailable: state == .running)
    }

    /// The device's overview with the terminal window row naming `session`, as the daemon builds it.
    private func overview(naming session: TerminalSessionCatalogEntry) -> SpacesDeviceOverviewPayload {
        let window = WindowRecord(
            id: "window-shell", workspaceID: workspace.id, app: "Spaces", name: "Shell", terminalTrackingID: session.sessionID, role: "terminal",
            orderIndex: 0, lastSeenAt: "now")
        let descriptor = SpacesDeviceOverviewBuilder.WorkspaceDescriptor(project: project, workspace: workspace, windows: [window])
        let live = session.runtimeState.state == .running
        let rows = SpacesDeviceAPIServer.workspaceTerminalRows(
            workspaces: [descriptor], sessions: live ? [session] : [], sessionIDsWithFinalRender: [],
            catalogEntry: { $0 == session.sessionID ? session : nil }, endedWindowSessions: live ? [:] : [session.sessionID: session])
        return SpacesDeviceOverviewBuilder.build(
            projects: [project], workspaces: [descriptor], workspaceRows: rows, liveSessions: live ? [session] : [],
            daemonStatus: TerminalServiceDaemonStatus(version: "test", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0))
    }

    @Test func aSecondClientFollowsTheReplacementAndTheFirstShowOfTheLostPaneAsksOnce() {
        let before = overview(naming: entry(sessionID: "lost", state: .failed, createdAt: "2026-10-15T09:00:00.100Z"))
        let after = overview(naming: entry(sessionID: "fresh", state: .running, createdAt: "2026-10-15T21:24:05.200Z"))

        var requests = LostShellResumeRequests()
        let asked = requests.claim(sessionID: "lost", overview: before)
        #expect(asked, "the failed shell a terminal row names is asked about")
        #expect(
            TerminalSessionReplacementDiff.replacements(previous: before, current: after) == [
                .init(workspaceID: "workspace-1", replacedSessionID: "lost", replacementSessionID: "fresh")
            ])
    }
}
