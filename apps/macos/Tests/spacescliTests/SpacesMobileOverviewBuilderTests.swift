import XCTest
import spacesmobilecore
import spacesterminalcore
import workspacecore

@testable import spacescli
@testable import spacesmobilebridge

final class SpacesMobileOverviewBuilderTests: XCTestCase {
    func testMatchesNestedWorkspaceByLongestWorkingDirectoryPrefix() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let rootWorkspace = WorkspaceRecord(
            id: "workspace-root", projectID: project.id, title: "Root", dir: "/repo", dirname: nil, branch: "main", isDefault: true,
            isArchived: false, isRunning: true, lastLaunchedAt: nil)
        let nestedWorkspace = WorkspaceRecord(
            id: "workspace-nested", projectID: project.id, title: "Nested", dir: "/repo/apps/web", dirname: nil, branch: "feature", isDefault: false,
            isArchived: false, isRunning: true, lastLaunchedAt: nil)

        let matched = SpacesMobileOverviewBuilder.matchedWorkspace(
            for: "/repo/apps/web/src",
            workspaces: [.init(project: project, workspace: rootWorkspace), .init(project: project, workspace: nestedWorkspace)])

        XCTAssertEqual(matched?.workspace.id, nestedWorkspace.id)
    }

    func testBuildsWorkspaceCountsAndLeavesUnmatchedSessionsUngrouped() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, title: "Docs", dir: "/repo/apps/web", dirname: nil, branch: "feature/docs", isDefault: false,
            isArchived: false, isRunning: true, lastLaunchedAt: nil)
        let localClient = TerminalClient(
            id: "owner-1", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces"), connectedAt: "2026-05-18T08:00:00Z")
        let ownerAttachment = TerminalAttachment(
            id: "attachment-1", sessionID: "session-1", clientID: localClient.id, mode: .owner, attachedAt: "2026-05-18T08:00:00Z")
        let matchedSession = makeSessionCatalogEntry(
            sessionID: "session-1", title: "docs", workingDirectory: "/repo/apps/web",
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [localClient], attachments: [ownerAttachment]))
        let unmatchedSession = makeSessionCatalogEntry(
            sessionID: "session-2", title: "scratch", workingDirectory: "/tmp/scratch", attachmentSnapshot: .init())

        let overview = SpacesMobileOverviewBuilder.build(
            workspaces: [.init(project: project, workspace: workspace)], workspaceRows: [], liveSessions: [matchedSession, unmatchedSession])

        XCTAssertEqual(overview.workspaces.count, 1)
        XCTAssertEqual(overview.workspaces.first?.sessionCount, 1)
        XCTAssertEqual(overview.sessions.count, 2)
        XCTAssertEqual(overview.sessions.first(where: { $0.id == "session-1" })?.workspaceID, workspace.id)
        XCTAssertNil(overview.sessions.first(where: { $0.id == "session-2" })?.workspaceID)
    }

    func testBuildIncludesEndedWorkspaceProcessRowsWithoutLiveControl() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, title: "Docs", dir: "/repo/apps/web", dirname: nil, branch: "feature/docs", isDefault: false,
            isArchived: false, isRunning: true, lastLaunchedAt: nil)
        let descriptor = SpacesMobileOverviewBuilder.WorkspaceDescriptor(project: project, workspace: workspace)
        let endedSession = makeSessionCatalogEntry(
            sessionID: "session-ended", title: "docs-watch", workingDirectory: "/repo/apps/web", state: .exited, attachmentSnapshot: .init(),
            isControlAvailable: true, isSubscriptionAvailable: true)

        let overview = SpacesMobileOverviewBuilder.build(
            workspaces: [descriptor],
            workspaceRows: [
                .init(
                    entry: endedSession, workspace: descriptor, title: "docs-watch", rowKind: .process, rowSourceID: "process-1", hasFinalRender: true
                )
            ], liveSessions: [])

        XCTAssertEqual(overview.workspaces.first?.sessionCount, 1)
        let summary = overview.sessions.first
        XCTAssertEqual(summary?.id, "session-ended")
        XCTAssertEqual(summary?.rowKind, .process)
        XCTAssertEqual(summary?.rowSourceID, "process-1")
        XCTAssertEqual(summary?.hasFinalRender, true)
        XCTAssertEqual(summary?.state, .exited)
        XCTAssertEqual(summary?.isControlAvailable, false)
        XCTAssertEqual(summary?.isSubscriptionAvailable, false)
    }

    func testBuildIncludesEndedWorkspaceAgentRowsWithoutLiveControl() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, title: "Docs", dir: "/repo/apps/web", dirname: nil, branch: "feature/docs", isDefault: false,
            isArchived: false, isRunning: true, lastLaunchedAt: nil)
        let descriptor = SpacesMobileOverviewBuilder.WorkspaceDescriptor(project: project, workspace: workspace)
        let endedSession = makeSessionCatalogEntry(
            sessionID: "session-ended-agent", title: "review-agent", workingDirectory: "/repo/apps/web", state: .exited, attachmentSnapshot: .init(),
            isControlAvailable: true, isSubscriptionAvailable: true)

        let overview = SpacesMobileOverviewBuilder.build(
            workspaces: [descriptor],
            workspaceRows: [
                .init(
                    entry: endedSession, workspace: descriptor, title: "review-agent", rowKind: .agent, rowSourceID: "agent-1", hasFinalRender: true)
            ], liveSessions: [])

        XCTAssertEqual(overview.workspaces.first?.sessionCount, 1)
        let summary = overview.sessions.first
        XCTAssertEqual(summary?.id, "session-ended-agent")
        XCTAssertEqual(summary?.rowKind, .agent)
        XCTAssertEqual(summary?.rowSourceID, "agent-1")
        XCTAssertEqual(summary?.hasFinalRender, true)
        XCTAssertEqual(summary?.state, .exited)
        XCTAssertEqual(summary?.isControlAvailable, false)
        XCTAssertEqual(summary?.isSubscriptionAvailable, false)
    }

    func testBuildKeepsTitleMatchedAdHocLiveSessionWhenSessionIDIsDistinct() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, title: "Docs", dir: "/repo/apps/web", dirname: nil, branch: "feature/docs", isDefault: false,
            isArchived: false, isRunning: true, lastLaunchedAt: nil)
        let descriptor = SpacesMobileOverviewBuilder.WorkspaceDescriptor(project: project, workspace: workspace)
        let currentAgentSession = makeSessionCatalogEntry(
            sessionID: "agent-current", title: "review-agent", workingDirectory: "/repo/apps/web", attachmentSnapshot: .init())
        let orphanedAgentSession = makeSessionCatalogEntry(
            sessionID: "agent-orphan", title: "review-agent", workingDirectory: "/repo/apps/web", attachmentSnapshot: .init())

        let overview = SpacesMobileOverviewBuilder.build(
            workspaces: [descriptor],
            workspaceRows: [
                .init(
                    entry: currentAgentSession, workspace: descriptor, title: "review-agent", rowKind: .agent, rowSourceID: "agent-1",
                    hasFinalRender: false)
            ], liveSessions: [currentAgentSession, orphanedAgentSession])

        XCTAssertEqual(overview.sessions.map(\.id), ["agent-current", "agent-orphan"])
        XCTAssertEqual(overview.sessions.first(where: { $0.id == "agent-orphan" })?.rowKind, .liveSession)
        XCTAssertEqual(overview.sessions.first(where: { $0.id == "agent-orphan" })?.workspaceID, workspace.id)
        XCTAssertEqual(overview.workspaces.first?.sessionCount, 2)
    }

    private func makeSessionCatalogEntry(
        sessionID: String, title: String, workingDirectory: String, state: TerminalSessionState = .running,
        attachmentSnapshot: TerminalSessionAttachmentSnapshot, isControlAvailable: Bool = true, isSubscriptionAvailable: Bool = true
    ) -> TerminalSessionCatalogEntry {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: title, workingDirectory: workingDirectory,
            shell: "/bin/zsh", command: nil, createdAt: "2026-05-18T08:00:00Z")
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 123, childPID: 456, state: state, updatedAt: "2026-05-18T08:00:05Z",
            title: title, workingDirectory: workingDirectory)
        return TerminalSessionCatalogEntry(
            launchConfiguration: launchConfiguration, runtimeState: runtimeState, attachmentSnapshot: attachmentSnapshot,
            paths: TerminalSessionPaths(rootDirectory: "/tmp/\(sessionID)"), isControlAvailable: isControlAvailable,
            isSubscriptionAvailable: isSubscriptionAvailable)
    }
}
