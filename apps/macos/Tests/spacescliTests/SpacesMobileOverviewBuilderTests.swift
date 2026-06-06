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

    func testMetadataWorkspaceMatchBeatsNestedWorkingDirectoryPrefix() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let rootWorkspace = WorkspaceRecord(
            id: "workspace-root", projectID: project.id, title: "Root", dir: "/repo", dirname: nil, branch: "main", isDefault: true,
            isArchived: false, isRunning: true, lastLaunchedAt: nil)
        let nestedWorkspace = WorkspaceRecord(
            id: "workspace-nested", projectID: project.id, title: "Nested", dir: "/repo/apps/web", dirname: nil, branch: "feature", isDefault: false,
            isArchived: false, isRunning: true, lastLaunchedAt: nil)
        let session = makeSessionCatalogEntry(
            sessionID: "session-metadata", title: "shell", workingDirectory: "/repo/apps/web/src", workspaceID: rootWorkspace.id,
            attachmentSnapshot: .init())

        let overview = SpacesMobileOverviewBuilder.build(
            workspaces: [.init(project: project, workspace: rootWorkspace), .init(project: project, workspace: nestedWorkspace)], sessions: [session])

        XCTAssertEqual(overview.sessions.first?.workspaceID, rootWorkspace.id)
        XCTAssertEqual(overview.workspaces.first(where: { $0.id == rootWorkspace.id })?.sessionCount, 1)
        XCTAssertEqual(overview.workspaces.first(where: { $0.id == nestedWorkspace.id })?.sessionCount, 0)
    }

    func testMetadataWorkspaceMissingFromOverviewLeavesSessionUnassigned() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, title: "Feature", dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false,
            isArchived: false, isRunning: true, lastLaunchedAt: nil)
        let session = makeSessionCatalogEntry(
            sessionID: "session-missing-workspace", title: "shell", workingDirectory: workspace.dir, workspaceID: "workspace-archived",
            attachmentSnapshot: .init())

        let overview = SpacesMobileOverviewBuilder.build(workspaces: [.init(project: project, workspace: workspace)], sessions: [session])

        XCTAssertNil(overview.sessions.first?.workspaceID)
        XCTAssertEqual(overview.workspaces.first?.sessionCount, 0)
        XCTAssertTrue(overview.workspaces.first?.terminalRows.isEmpty ?? false)
    }

    func testNilMetadataUsesLongestWorkingDirectoryPrefixFallback() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let rootWorkspace = WorkspaceRecord(
            id: "workspace-root", projectID: project.id, title: "Root", dir: "/repo", dirname: nil, branch: "main", isDefault: true,
            isArchived: false, isRunning: true, lastLaunchedAt: nil)
        let nestedWorkspace = WorkspaceRecord(
            id: "workspace-nested", projectID: project.id, title: "Nested", dir: "/repo/apps/web", dirname: nil, branch: "feature", isDefault: false,
            isArchived: false, isRunning: true, lastLaunchedAt: nil)
        let session = makeSessionCatalogEntry(
            sessionID: "session-legacy", title: "shell", workingDirectory: "/repo/apps/web/src", attachmentSnapshot: .init())

        let overview = SpacesMobileOverviewBuilder.build(
            workspaces: [.init(project: project, workspace: rootWorkspace), .init(project: project, workspace: nestedWorkspace)], sessions: [session])

        XCTAssertEqual(overview.sessions.first?.workspaceID, nestedWorkspace.id)
        XCTAssertEqual(overview.workspaces.first(where: { $0.id == rootWorkspace.id })?.sessionCount, 0)
        XCTAssertEqual(overview.workspaces.first(where: { $0.id == nestedWorkspace.id })?.sessionCount, 1)
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
            workspaces: [.init(project: project, workspace: workspace)], sessions: [matchedSession, unmatchedSession])

        XCTAssertEqual(overview.workspaces.count, 1)
        XCTAssertEqual(overview.workspaces.first?.sessionCount, 1)
        XCTAssertEqual(overview.sessions.count, 2)
        XCTAssertEqual(overview.sessions.first(where: { $0.id == "session-1" })?.workspaceID, workspace.id)
        XCTAssertNil(overview.sessions.first(where: { $0.id == "session-2" })?.workspaceID)
    }

    func testBuildsConfiguredProcessRowsWithLiveAndExitedState() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, title: "Feature", dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false,
            isArchived: false, isRunning: true, lastLaunchedAt: nil)
        let runningSession = makeSessionCatalogEntry(
            sessionID: "session-api", title: "api", workingDirectory: workspace.dir, attachmentSnapshot: .init())
        let runningProcess = RunningProcessRecord(
            id: "process-api", workspaceID: workspace.id, templateName: "api", command: "npm run dev", terminalApp: "Spaces", windowID: nil,
            terminalTrackingID: "session-api", terminalNativeID: "session-api", pid: 123, status: .running, logPath: nil, lastOutputAt: nil,
            startedAt: "now", exitedAt: nil)
        let exitedProcess = RunningProcessRecord(
            id: "process-worker", workspaceID: workspace.id, templateName: "worker", command: "npm run worker", terminalApp: "Spaces", windowID: nil,
            terminalTrackingID: "session-worker", terminalNativeID: "session-worker", pid: nil, status: .exited, logPath: nil, lastOutputAt: nil,
            startedAt: "now", exitedAt: "later")

        let overview = SpacesMobileOverviewBuilder.build(
            projects: [project],
            workspaces: [
                .init(
                    project: project, workspace: workspace,
                    settings: WorkspaceSettings(processes: [
                        ProcessTemplate(id: "template-api", name: "api", command: "npm run dev"),
                        ProcessTemplate(id: "template-worker", name: "worker", command: "npm run worker"),
                        ProcessTemplate(id: "template-web", name: "web", command: "npm run web"),
                    ]), runningProcesses: [runningProcess, exitedProcess])
            ], sessions: [runningSession])

        let rows = overview.workspaces.first?.processRows ?? []
        XCTAssertEqual(rows.first(where: { $0.name == "api" })?.runState, .running)
        XCTAssertEqual(rows.first(where: { $0.name == "api" })?.sessionID, "session-api")
        XCTAssertEqual(rows.first(where: { $0.name == "worker" })?.runState, .exited)
        XCTAssertNil(rows.first(where: { $0.name == "worker" })?.sessionID)
        XCTAssertEqual(rows.first(where: { $0.name == "web" })?.runState, .notStarted)
    }

    func testMatchesRenamedConfiguredProcessByTemplateID() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, title: "Feature", dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false,
            isArchived: false, isRunning: true, lastLaunchedAt: nil)
        let processSession = makeSessionCatalogEntry(
            sessionID: "session-api", title: "old-api", workingDirectory: workspace.dir, attachmentSnapshot: .init())
        let runningProcess = RunningProcessRecord(
            id: "process-api", workspaceID: workspace.id, templateID: "template-api", templateName: "old-api", command: "npm run dev",
            terminalApp: "Spaces", windowID: nil, terminalTrackingID: "session-api", terminalNativeID: "session-api", pid: 123, status: .running,
            logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        let processWindow = WindowRecord(
            id: "window-api", workspaceID: workspace.id, app: "Spaces", name: "old-api", windowID: nil, terminalTrackingID: "session-api",
            terminalNativeID: "session-api", role: "terminal", orderIndex: 1, lastSeenAt: "now")

        let overview = SpacesMobileOverviewBuilder.build(
            projects: [project],
            workspaces: [
                .init(
                    project: project, workspace: workspace,
                    settings: WorkspaceSettings(processes: [ProcessTemplate(id: "template-api", name: "new-api", command: "npm run dev")]),
                    runningProcesses: [runningProcess], windows: [processWindow])
            ], sessions: [processSession])

        let workspaceOverview = overview.workspaces.first
        let processRow = workspaceOverview?.processRows.first
        XCTAssertEqual(processRow?.name, "new-api")
        XCTAssertEqual(processRow?.templateID, "template-api")
        XCTAssertEqual(processRow?.processID, "process-api")
        XCTAssertEqual(processRow?.sessionID, "session-api")
        XCTAssertEqual(workspaceOverview?.terminalRows.first(where: { $0.sessionID == "session-api" }), nil)
    }

    func testBuildsConfiguredAndAdHocCodingAgentRows() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, title: "Feature", dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false,
            isArchived: false, isRunning: true, lastLaunchedAt: nil)
        let codexSession = makeSessionCatalogEntry(
            sessionID: "session-codex", title: "Codex", workingDirectory: workspace.dir, attachmentSnapshot: .init())
        let configuredAgent = AgentWindowRecord(
            id: "agent-codex", workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "session-codex", codexThreadID: nil,
            windowID: nil, status: .spinning, createdAt: "now", updatedAt: "now")
        let adHocAgent = AgentWindowRecord(
            id: "agent-review", workspaceID: workspace.id, provider: .spaces, label: "reviewer", terminalTrackingID: "missing-session",
            codexThreadID: nil, windowID: nil, status: .waiting, createdAt: "now", updatedAt: "now")

        let overview = SpacesMobileOverviewBuilder.build(
            projects: [project],
            workspaces: [
                .init(
                    project: project, workspace: workspace,
                    settings: WorkspaceSettings(agentLaunchers: [AgentLauncher(name: "codex", command: "codex")]),
                    agentWindows: [configuredAgent, adHocAgent])
            ], sessions: [codexSession])

        let rows = overview.workspaces.first?.codingAgentRows ?? []
        XCTAssertEqual(rows.first(where: { $0.name == "codex" })?.runState, .running)
        XCTAssertEqual(rows.first(where: { $0.name == "codex" })?.activityState, .spinning)
        XCTAssertEqual(rows.first(where: { $0.name == "codex" })?.sessionID, "session-codex")
        XCTAssertEqual(rows.first(where: { $0.name == "reviewer" })?.runState, .exited)
        XCTAssertEqual(rows.first(where: { $0.name == "reviewer" })?.canStop, true)
        XCTAssertEqual(rows.first(where: { $0.name == "reviewer" })?.canRestart, false)
    }

    func testMatchesRenamedConfiguredAgentByLauncherID() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, title: "Feature", dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false,
            isArchived: false, isRunning: true, lastLaunchedAt: nil)
        let codexSession = makeSessionCatalogEntry(
            sessionID: "session-codex", title: "Old Codex", workingDirectory: workspace.dir, attachmentSnapshot: .init())
        let configuredAgent = AgentWindowRecord(
            id: "agent-codex", workspaceID: workspace.id, provider: .spaces, label: "Old Codex", terminalTrackingID: "session-codex",
            codexThreadID: nil, windowID: nil, status: .spinning, createdAt: "now", updatedAt: "now")
        let claimedAgent = AgentWindowRecord(
            id: configuredAgent.id, workspaceID: configuredAgent.workspaceID, provider: configuredAgent.provider, label: configuredAgent.label,
            runtimeTargetID: configuredAgent.runtimeTargetID, terminalTarget: configuredAgent.terminalTarget, sessionKey: configuredAgent.sessionKey,
            claimedLauncherID: "launcher-codex", claimedLauncherName: "Old Codex", status: configuredAgent.status,
            createdAt: configuredAgent.createdAt, updatedAt: configuredAgent.updatedAt)

        let overview = SpacesMobileOverviewBuilder.build(
            projects: [project],
            workspaces: [
                .init(
                    project: project, workspace: workspace,
                    settings: WorkspaceSettings(agentLaunchers: [AgentLauncher(id: "launcher-codex", name: "Codex", command: "codex")]),
                    agentWindows: [claimedAgent])
            ], sessions: [codexSession])

        let row = overview.workspaces.first?.codingAgentRows.first
        XCTAssertEqual(row?.name, "Codex")
        XCTAssertEqual(row?.launcherID, "launcher-codex")
        XCTAssertEqual(row?.agentID, "agent-codex")
        XCTAssertEqual(row?.sessionID, "session-codex")
    }

    func testBuildsWorkspaceTerminalRowsWithoutClaimedProcessAndAgentSessions() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, title: "Feature", dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false,
            isArchived: false, isRunning: true, lastLaunchedAt: nil)
        let shellSession = makeSessionCatalogEntry(
            sessionID: "session-shell", title: "Shell", workingDirectory: workspace.dir, attachmentSnapshot: .init())
        let processSession = makeSessionCatalogEntry(
            sessionID: "session-api", title: "api", workingDirectory: workspace.dir, attachmentSnapshot: .init())
        let process = RunningProcessRecord(
            id: "process-api", workspaceID: workspace.id, templateName: "api", command: "npm run dev", terminalApp: "Spaces", windowID: nil,
            terminalTrackingID: "session-api", terminalNativeID: "session-api", pid: 123, status: .running, logPath: nil, lastOutputAt: nil,
            startedAt: "now", exitedAt: nil)
        let terminalWindow = WindowRecord(
            id: "window-shell", workspaceID: workspace.id, app: "Spaces", name: "Shell", windowID: nil, terminalTrackingID: "session-shell",
            terminalNativeID: "session-shell", role: "terminal", orderIndex: 0, lastSeenAt: "now")
        let processWindow = WindowRecord(
            id: "window-api", workspaceID: workspace.id, app: "Spaces", name: "api", windowID: nil, terminalTrackingID: "session-api",
            terminalNativeID: "session-api", role: "terminal", orderIndex: 1, lastSeenAt: "now")

        let overview = SpacesMobileOverviewBuilder.build(
            projects: [project],
            workspaces: [.init(project: project, workspace: workspace, runningProcesses: [process], windows: [terminalWindow, processWindow])],
            sessions: [shellSession, processSession])

        let rows = overview.workspaces.first?.terminalRows ?? []
        XCTAssertEqual(rows.map(\.sessionID), ["session-shell"])
        XCTAssertEqual(rows.first?.runState, .running)
        XCTAssertEqual(rows.first?.canStop, true)
        XCTAssertEqual(overview.workspaces.first?.processRows.first?.id, "process-runtime:process-api")
        XCTAssertEqual(overview.workspaces.first?.processRows.first?.canRun, false)
    }

    func testTrackedWorkspaceTerminalRequiresLiveSessionIDBeforeStopIsAvailable() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, title: "Feature", dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false,
            isArchived: false, isRunning: true, lastLaunchedAt: nil)
        let terminalWindow = WindowRecord(
            id: "window-shell", workspaceID: workspace.id, app: "Spaces", name: "Shell", windowID: nil, terminalTrackingID: nil,
            terminalNativeID: nil, role: "terminal", orderIndex: 0, lastSeenAt: "now")

        let overview = SpacesMobileOverviewBuilder.build(
            projects: [project], workspaces: [.init(project: project, workspace: workspace, windows: [terminalWindow])], sessions: [])

        let row = overview.workspaces.first?.terminalRows.first
        XCTAssertEqual(row?.runState, .running)
        XCTAssertNil(row?.sessionID)
        XCTAssertEqual(row?.canStop, false)
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
        sessionID: String, title: String, workingDirectory: String, state: TerminalSessionState = .running, workspaceID: String? = nil,
        kind: TerminalSessionKind = .shell, attachmentSnapshot: TerminalSessionAttachmentSnapshot, isControlAvailable: Bool = true,
        isSubscriptionAvailable: Bool = true
    ) -> TerminalSessionCatalogEntry {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: title, workingDirectory: workingDirectory,
            shell: "/bin/zsh", command: nil, createdAt: "2026-05-18T08:00:00Z", workspaceID: workspaceID, kind: kind)
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 123, childPID: 456, state: state, updatedAt: "2026-05-18T08:00:05Z",
            title: title, workingDirectory: workingDirectory)
        return TerminalSessionCatalogEntry(
            launchConfiguration: launchConfiguration, runtimeState: runtimeState, attachmentSnapshot: attachmentSnapshot,
            paths: TerminalSessionPaths(rootDirectory: "/tmp/\(sessionID)"), isControlAvailable: isControlAvailable,
            isSubscriptionAvailable: isSubscriptionAvailable)
    }
}
