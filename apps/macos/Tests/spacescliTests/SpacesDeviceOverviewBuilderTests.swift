import XCTest
import spacesdevicecore
import spacesterminalcore
import workspacecore

@testable import spacescli
@testable import spacesdeviceapi

final class SpacesDeviceOverviewBuilderTests: XCTestCase {
    func testWorkspacesSortDefaultFirstThenByNameSoEveryClientMatches() {
        // The overview payload is the single ordering source every client renders. macOS pins each
        // project's default workspace to the top; iOS uses the payload order verbatim. Making the
        // builder sort default-first (then name) keeps the two clients from diverging.
        let alpha = ProjectRecord(id: "project-alpha", name: "Alpha", dir: "/alpha", isGitRepo: true, defaultBranch: "main")
        let beta = ProjectRecord(id: "project-beta", name: "Beta", dir: "/beta", isGitRepo: true, defaultBranch: "main")
        func workspace(id: String, project: ProjectRecord, branch: String, isDefault: Bool) -> SpacesDeviceOverviewBuilder.WorkspaceDescriptor {
            .init(
                project: project,
                workspace: WorkspaceRecord(
                    id: id, projectID: project.id, dir: "/\(project.name)/\(branch)", dirname: nil, branch: branch, isDefault: isDefault,
                    isArchived: false, isRunning: false, lastLaunchedAt: nil))
        }
        // Default branch name ("zzz-main") deliberately sorts last alphabetically to prove default-first wins.
        let alphaFeature = workspace(id: "alpha-feature", project: alpha, branch: "aaa-feature", isDefault: false)
        let alphaDefault = workspace(id: "alpha-default", project: alpha, branch: "zzz-main", isDefault: true)
        let betaDefault = workspace(id: "beta-default", project: beta, branch: "main", isDefault: true)

        let overview = SpacesDeviceOverviewBuilder.build(workspaces: [alphaFeature, betaDefault, alphaDefault], sessions: [])

        // Project order by name (Alpha before Beta); within Alpha the default sorts ahead of the earlier-named feature.
        XCTAssertEqual(overview.workspaces.map(\.id), ["alpha-default", "alpha-feature", "beta-default"])
    }

    func testMetadataWorkspaceMatchAssignsSessionToStampedWorkspace() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let rootWorkspace = WorkspaceRecord(
            id: "workspace-root", projectID: project.id, dir: "/repo", dirname: nil, branch: "main", isDefault: true, isArchived: false,
            isRunning: true, lastLaunchedAt: nil)
        let nestedWorkspace = WorkspaceRecord(
            id: "workspace-nested", projectID: project.id, dir: "/repo/apps/web", dirname: nil, branch: "feature", isDefault: false,
            isArchived: false, isRunning: true, lastLaunchedAt: nil)
        let session = makeSessionCatalogEntry(
            sessionID: "session-metadata", title: "shell", workingDirectory: "/repo/apps/web/src", workspaceID: rootWorkspace.id,
            attachmentSnapshot: .init())

        let overview = SpacesDeviceOverviewBuilder.build(
            workspaces: [.init(project: project, workspace: rootWorkspace), .init(project: project, workspace: nestedWorkspace)], sessions: [session])

        XCTAssertEqual(overview.sessions.first?.workspaceID, rootWorkspace.id)
        XCTAssertEqual(overview.workspaces.first(where: { $0.id == rootWorkspace.id })?.sessionCount, 1)
        XCTAssertEqual(overview.workspaces.first(where: { $0.id == nestedWorkspace.id })?.sessionCount, 0)
    }

    func testWorkspaceEnvironmentFlowsThroughToSummary() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false, isArchived: false,
            isRunning: true, lastLaunchedAt: nil)
        let environment = ["SPACES_WORKSPACE_ID": workspace.id, "SPACES_WEB_PORT": "51023"]

        let overview = SpacesDeviceOverviewBuilder.build(
            workspaces: [.init(project: project, workspace: workspace, environment: environment)], sessions: [])

        XCTAssertEqual(overview.workspaces.first?.environment, environment)
    }

    func testMetadataWorkspaceMissingFromOverviewKeepsStampedWorkspaceIDButNoRow() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false, isArchived: false,
            isRunning: true, lastLaunchedAt: nil)
        let session = makeSessionCatalogEntry(
            sessionID: "session-missing-workspace", title: "shell", workingDirectory: workspace.dir, workspaceID: "workspace-archived",
            attachmentSnapshot: .init())

        let overview = SpacesDeviceOverviewBuilder.build(workspaces: [.init(project: project, workspace: workspace)], sessions: [session])

        XCTAssertEqual(overview.sessions.first?.workspaceID, "workspace-archived")
        XCTAssertEqual(overview.workspaces.first?.sessionCount, 0)
        XCTAssertTrue(overview.workspaces.first?.terminalRows.isEmpty ?? false)
    }

    func testBuildsWorkspaceCountsAndLeavesUnmatchedSessionsUngrouped() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, dir: "/repo/apps/web", dirname: nil, branch: "feature/docs", isDefault: false,
            isArchived: false, isRunning: true, lastLaunchedAt: nil)
        let localClient = TerminalClient(
            id: "owner-1", kind: .localWindow, identity: TerminalClientIdentity(label: "Spaces"), connectedAt: "2026-05-18T08:00:00Z")
        let ownerAttachment = TerminalAttachment(
            id: "attachment-1", sessionID: "session-1", clientID: localClient.id, mode: .owner, attachedAt: "2026-05-18T08:00:00Z")
        let matchedSession = makeSessionCatalogEntry(
            sessionID: "session-1", title: "docs", workingDirectory: "/repo/apps/web", workspaceID: workspace.id,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [localClient], attachments: [ownerAttachment]))
        let unmatchedSession = makeSessionCatalogEntry(
            sessionID: "session-2", title: "scratch", workingDirectory: "/tmp/scratch", workspaceID: "workspace-other", attachmentSnapshot: .init())

        let overview = SpacesDeviceOverviewBuilder.build(
            workspaces: [.init(project: project, workspace: workspace)], sessions: [matchedSession, unmatchedSession])

        XCTAssertEqual(overview.workspaces.count, 1)
        XCTAssertEqual(overview.workspaces.first?.sessionCount, 1)
        XCTAssertEqual(overview.sessions.count, 2)
        XCTAssertEqual(overview.sessions.first(where: { $0.id == "session-1" })?.workspaceID, workspace.id)
        XCTAssertEqual(overview.sessions.first(where: { $0.id == "session-2" })?.workspaceID, "workspace-other")
    }

    func testBuildsConfiguredProcessRowsWithLiveAndExitedState() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false, isArchived: false,
            isRunning: true, lastLaunchedAt: nil)
        let runningSession = makeSessionCatalogEntry(
            sessionID: "session-api", title: "api", workingDirectory: workspace.dir, workspaceID: workspace.id, attachmentSnapshot: .init())
        let runningProcess = RunningProcessRecord(
            id: "process-api", workspaceID: workspace.id, templateName: "api", command: "npm run dev", terminalApp: "Spaces",
            terminalTrackingID: "session-api", pid: 123, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        let exitedProcess = RunningProcessRecord(
            id: "process-worker", workspaceID: workspace.id, templateName: "worker", command: "npm run worker", terminalApp: "Spaces",
            terminalTrackingID: "session-worker", pid: nil, status: .exited, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: "later")

        let overview = SpacesDeviceOverviewBuilder.build(
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

    func testStartingTerminalSessionSummaryKeepsWorkspaceTerminalRowRunning() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false, isArchived: false,
            isRunning: true, lastLaunchedAt: nil)
        let session = makeSessionCatalogEntry(
            sessionID: "session-starting", title: "shell-1", workingDirectory: workspace.dir, state: .starting, workspaceID: workspace.id,
            attachmentSnapshot: .init(), isControlAvailable: false, isSubscriptionAvailable: false)

        let overview = SpacesDeviceOverviewBuilder.build(workspaces: [.init(project: project, workspace: workspace)], sessions: [session])

        let summary = overview.sessions.first
        XCTAssertEqual(summary?.id, "session-starting")
        XCTAssertEqual(summary?.state, .starting)
        XCTAssertEqual(summary?.isControlAvailable, false)
        XCTAssertEqual(summary?.isSubscriptionAvailable, false)
        let row = overview.workspaces.first?.terminalRows.first
        XCTAssertEqual(row?.sessionID, "session-starting")
        XCTAssertEqual(row?.runState, .running)
        XCTAssertEqual(row?.canOpenTerminal, true)
    }

    func testBuildIncludesProjectAndWorkspaceConfigForClientParity() {
        let project = ProjectRecord(
            id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main", setupScript: "make setup",
            stopScript: "make stop-project", ports: [ServiceDefinition(id: "project-web-port", name: "WEB")],
            processes: [ProcessTemplate(id: "project-web-process", name: "web", command: "npm run dev", kind: "server", onExit: .restart)],
            browserSessions: [BrowserSession(name: "web", url: "http://localhost:$WEB")],
            agentLaunchers: [AgentLauncher(id: "project-codex-agent", name: "Codex", command: "codex")])
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, dir: "/repo/feature", dirname: "feature", branch: "feature", baseBranch: "main",
            isDefault: false, isArchived: false, isRunning: true, lastLaunchedAt: nil, notes: "Use this payload for local and remote detail views.")
        let settings = WorkspaceSettings(
            stopScript: "make stop-workspace", ports: [ServiceDefinition(id: "workspace-api-port", name: "API")],
            processes: [ProcessTemplate(id: "workspace-api-process", name: "api", command: "npm run api", onExit: .none)],
            browserSessions: [BrowserSession(name: "api", url: "http://localhost:$API")],
            agentLaunchers: [AgentLauncher(id: "workspace-review-agent", name: "Review", command: "codex --review")])
        let setupState = WorkspaceSetupState(
            status: .failed, errorMessage: "missing dependency", startedAt: "2026-05-18T08:00:00Z", finishedAt: "2026-05-18T08:01:00Z", exitCode: 127,
            logPath: "/tmp/setup.log")

        let overview = SpacesDeviceOverviewBuilder.build(
            projects: [project],
            workspaces: [
                .init(
                    project: project, workspace: workspace, settings: settings, assignedPorts: [SpacesDeviceAssignedPort(name: "API", port: 4000)],
                    resolvedBrowserSessions: [BrowserSession(name: "api", url: "http://localhost:4000")], setupState: setupState)
            ], sessions: [])

        let projectSummary = overview.projects.first
        XCTAssertEqual(projectSummary?.id, project.id)
        XCTAssertEqual(projectSummary?.config.setupScript, "make setup")
        XCTAssertEqual(projectSummary?.config.stopScript, "make stop-project")
        XCTAssertEqual(projectSummary?.config.ports.first?.id, "project-web-port")
        XCTAssertEqual(projectSummary?.config.ports.first?.name, "WEB")
        XCTAssertEqual(projectSummary?.config.processes.first?.id, "project-web-process")
        XCTAssertEqual(projectSummary?.config.processes.first?.name, "web")
        XCTAssertEqual(projectSummary?.config.processes.first?.command, "npm run dev")
        XCTAssertEqual(projectSummary?.config.processes.first?.kind, "server")
        XCTAssertEqual(projectSummary?.config.processes.first?.onExit, "restart")
        XCTAssertEqual(projectSummary?.config.browserSessions.first?.name, "web")
        XCTAssertEqual(projectSummary?.config.browserSessions.first?.url, "http://localhost:$WEB")
        XCTAssertEqual(projectSummary?.config.agentLaunchers.first?.id, "project-codex-agent")
        XCTAssertEqual(projectSummary?.config.agentLaunchers.first?.name, "Codex")
        XCTAssertEqual(projectSummary?.config.agentLaunchers.first?.command, "codex")

        let workspaceSummary = overview.workspaces.first
        XCTAssertEqual(workspaceSummary?.id, workspace.id)
        XCTAssertEqual(workspaceSummary?.notes, "Use this payload for local and remote detail views.")
        XCTAssertEqual(workspaceSummary?.assignedPorts.first?.name, "API")
        XCTAssertEqual(workspaceSummary?.assignedPorts.first?.port, 4000)
        XCTAssertEqual(workspaceSummary?.setupState?.status, .failed)
        XCTAssertEqual(workspaceSummary?.setupState?.errorMessage, "missing dependency")
        XCTAssertEqual(workspaceSummary?.setupState?.startedAt, "2026-05-18T08:00:00Z")
        XCTAssertEqual(workspaceSummary?.setupState?.finishedAt, "2026-05-18T08:01:00Z")
        XCTAssertEqual(workspaceSummary?.setupState?.exitCode, 127)
        XCTAssertEqual(workspaceSummary?.setupState?.logPath, "/tmp/setup.log")
        XCTAssertEqual(workspaceSummary?.config.stopScript, "make stop-workspace")
        XCTAssertEqual(workspaceSummary?.config.ports.first?.id, "workspace-api-port")
        XCTAssertEqual(workspaceSummary?.config.ports.first?.name, "API")
        XCTAssertEqual(workspaceSummary?.config.processes.first?.id, "workspace-api-process")
        XCTAssertEqual(workspaceSummary?.config.processes.first?.name, "api")
        XCTAssertEqual(workspaceSummary?.config.processes.first?.command, "npm run api")
        XCTAssertEqual(workspaceSummary?.config.browserSessions.first?.name, "api")
        XCTAssertEqual(workspaceSummary?.config.browserSessions.first?.url, "http://localhost:$API")
        XCTAssertEqual(workspaceSummary?.config.resolvedBrowserSessions.first?.name, "api")
        XCTAssertEqual(workspaceSummary?.config.resolvedBrowserSessions.first?.url, "http://localhost:4000")
        XCTAssertEqual(workspaceSummary?.config.agentLaunchers.first?.id, "workspace-review-agent")
        XCTAssertEqual(workspaceSummary?.config.agentLaunchers.first?.name, "Review")
        XCTAssertEqual(workspaceSummary?.config.agentLaunchers.first?.command, "codex --review")
    }

    func testOverviewIncludesSetupLogTailWhileRunningSoRemoteClientsCanStreamProgress() throws {
        let logDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent(
            "setup-log-tail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: logDir) }
        let logURL = logDir.appendingPathComponent("setup.log", isDirectory: false)
        try "Cloning into 'vendor/ghostty'...\nBuilding artifacts...\n".write(to: logURL, atomically: true, encoding: .utf8)

        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, dir: "/repo/feature", dirname: "feature", branch: "feature", baseBranch: "main",
            isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)

        func setupState(status: WorkspaceSetupStatus) -> WorkspaceSetupState {
            WorkspaceSetupState(status: status, errorMessage: nil, startedAt: "2026-05-18T08:00:00Z", finishedAt: nil, logPath: logURL.path)
        }

        let running = SpacesDeviceOverviewBuilder.build(
            projects: [project], workspaces: [.init(project: project, workspace: workspace, setupState: setupState(status: .running))], sessions: [])
        let runningTail = running.workspaces.first?.setupState?.logTail
        XCTAssertEqual(running.workspaces.first?.setupState?.status, .running)
        XCTAssertTrue(runningTail?.contains("Building artifacts...") == true)

        // Succeeded shows the normal workspace detail rather than the setup screen, so its tail is
        // omitted to keep the overview snapshot small even when the log file still exists.
        let succeeded = SpacesDeviceOverviewBuilder.build(
            projects: [project], workspaces: [.init(project: project, workspace: workspace, setupState: setupState(status: .succeeded))], sessions: []
        )
        XCTAssertNil(succeeded.workspaces.first?.setupState?.logTail)
    }

    func testMatchesRenamedConfiguredProcessByTemplateID() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false, isArchived: false,
            isRunning: true, lastLaunchedAt: nil)
        let processSession = makeSessionCatalogEntry(
            sessionID: "session-api", title: "old-api", workingDirectory: workspace.dir, workspaceID: workspace.id, attachmentSnapshot: .init())
        let runningProcess = RunningProcessRecord(
            id: "process-api", workspaceID: workspace.id, templateID: "template-api", templateName: "old-api", command: "npm run dev",
            terminalApp: "Spaces", terminalTrackingID: "session-api", pid: 123, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now",
            exitedAt: nil)
        let processWindow = WindowRecord(
            id: "window-api", workspaceID: workspace.id, app: "Spaces", name: "old-api", terminalTrackingID: "session-api", role: "terminal",
            orderIndex: 1, lastSeenAt: "now")

        let overview = SpacesDeviceOverviewBuilder.build(
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
            id: "workspace-1", projectID: project.id, dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false, isArchived: false,
            isRunning: true, lastLaunchedAt: nil)
        let codexSession = makeSessionCatalogEntry(
            sessionID: "session-codex", title: "Codex", workingDirectory: workspace.dir, workspaceID: workspace.id, attachmentSnapshot: .init())
        let configuredAgent = AgentWindowRecord(
            id: "agent-codex", workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "session-codex", sessionKey: nil,
            status: .spinning, createdAt: "now", updatedAt: "now")
        let adHocAgent = AgentWindowRecord(
            id: "agent-review", workspaceID: workspace.id, provider: .spaces, label: "reviewer", terminalTrackingID: "missing-session",
            sessionKey: nil, status: .waiting, createdAt: "now", updatedAt: "now")

        let overview = SpacesDeviceOverviewBuilder.build(
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
            id: "workspace-1", projectID: project.id, dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false, isArchived: false,
            isRunning: true, lastLaunchedAt: nil)
        let codexSession = makeSessionCatalogEntry(
            sessionID: "session-codex", title: "Old Codex", workingDirectory: workspace.dir, workspaceID: workspace.id, attachmentSnapshot: .init())
        let configuredAgent = AgentWindowRecord(
            id: "agent-codex", workspaceID: workspace.id, provider: .spaces, label: "Old Codex", terminalTrackingID: "session-codex", sessionKey: nil,
            status: .spinning, createdAt: "now", updatedAt: "now")
        let claimedAgent = AgentWindowRecord(
            id: configuredAgent.id, workspaceID: configuredAgent.workspaceID, provider: configuredAgent.provider, label: configuredAgent.label,
            runtimeTargetID: configuredAgent.runtimeTargetID, terminalTarget: configuredAgent.terminalTarget, sessionKey: configuredAgent.sessionKey,
            claimedLauncherID: "launcher-codex", claimedLauncherName: "Old Codex", status: configuredAgent.status,
            createdAt: configuredAgent.createdAt, updatedAt: configuredAgent.updatedAt)

        let overview = SpacesDeviceOverviewBuilder.build(
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
            id: "workspace-1", projectID: project.id, dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false, isArchived: false,
            isRunning: true, lastLaunchedAt: nil)
        let shellSession = makeSessionCatalogEntry(
            sessionID: "session-shell", title: "Shell", workingDirectory: workspace.dir, workspaceID: workspace.id, attachmentSnapshot: .init())
        let processSession = makeSessionCatalogEntry(
            sessionID: "session-api", title: "api", workingDirectory: workspace.dir, workspaceID: workspace.id, attachmentSnapshot: .init())
        let process = RunningProcessRecord(
            id: "process-api", workspaceID: workspace.id, templateName: "api", command: "npm run dev", terminalApp: "Spaces",
            terminalTrackingID: "session-api", pid: 123, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        let terminalWindow = WindowRecord(
            id: "window-shell", workspaceID: workspace.id, app: "Spaces", name: "Shell", terminalTrackingID: "session-shell", role: "terminal",
            orderIndex: 0, lastSeenAt: "now")
        let processWindow = WindowRecord(
            id: "window-api", workspaceID: workspace.id, app: "Spaces", name: "api", terminalTrackingID: "session-api", role: "terminal",
            orderIndex: 1, lastSeenAt: "now")

        let overview = SpacesDeviceOverviewBuilder.build(
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

    func testRenamedSessionUserTitleWinsOverRuntimeTitleInSummariesAndTerminalRows() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false, isArchived: false,
            isRunning: true, lastLaunchedAt: nil)
        // The runtime title mimics a Ghostty set_title update that arrived after the manual rename.
        let session = makeSessionCatalogEntry(
            sessionID: "session-renamed", title: "shell-1", workingDirectory: workspace.dir, workspaceID: workspace.id, attachmentSnapshot: .init(),
            userTitle: "build watcher", runtimeTitle: "vim main.swift")

        let overview = SpacesDeviceOverviewBuilder.build(
            projects: [project], workspaces: [.init(project: project, workspace: workspace)], sessions: [session])

        XCTAssertEqual(overview.sessions.first?.title, "build watcher")
        XCTAssertEqual(overview.workspaces.first?.terminalRows.first?.title, "build watcher")
    }

    /// An ad hoc shell row is named by the session, not by what its program prints: the generic launch
    /// name stays put and the live title travels beside it as the row's secondary text, so a user
    /// scanning the sidebar reads `shell-1` and `vim main.swift` as two separate things.
    func testTrackedShellRowKeepsItsNameAndCarriesTheLiveTitleBeside() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false, isArchived: false,
            isRunning: true, lastLaunchedAt: nil)
        let session = makeSessionCatalogEntry(
            sessionID: "session-shell", title: "shell-1", workingDirectory: "/repo/feature/apps/web", workspaceID: workspace.id,
            attachmentSnapshot: .init(), runtimeTitle: "vim main.swift")
        let terminalWindow = WindowRecord(
            id: "window-shell", workspaceID: workspace.id, app: "Spaces", name: "shell-1", terminalTrackingID: "session-shell", role: "terminal",
            orderIndex: 0, lastSeenAt: "now")

        let overview = SpacesDeviceOverviewBuilder.build(
            projects: [project], workspaces: [.init(project: project, workspace: workspace, windows: [terminalWindow])], sessions: [session])

        let row = overview.workspaces.first?.terminalRows.first
        XCTAssertEqual(row?.title, "shell-1")
        XCTAssertEqual(row?.liveTitle, "vim main.swift")
    }

    /// A shell whose program has reported no title has no secondary text to show.
    func testShellRowWithoutAReportedTitleCarriesNoLiveTitle() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false, isArchived: false,
            isRunning: true, lastLaunchedAt: nil)
        let session = makeSessionCatalogEntry(
            sessionID: "session-shell", title: "shell-1", workingDirectory: workspace.dir, workspaceID: workspace.id, attachmentSnapshot: .init(),
            runtimeTitle: "   ")

        let overview = SpacesDeviceOverviewBuilder.build(
            projects: [project], workspaces: [.init(project: project, workspace: workspace)], sessions: [session])

        XCTAssertEqual(overview.workspaces.first?.terminalRows.first?.title, "shell-1")
        XCTAssertNil(overview.workspaces.first?.terminalRows.first?.liveTitle)
        XCTAssertNil(overview.sessions.first?.liveTitle)
    }

    /// A rename names the row; the live title keeps showing beside it rather than being displaced or
    /// displacing the new name.
    func testRenamedShellRowKeepsShowingItsLiveTitleBesideTheNewName() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false, isArchived: false,
            isRunning: true, lastLaunchedAt: nil)
        let session = makeSessionCatalogEntry(
            sessionID: "session-shell", title: "shell-1", workingDirectory: workspace.dir, workspaceID: workspace.id, attachmentSnapshot: .init(),
            userTitle: "build watcher", runtimeTitle: "vim main.swift")
        let terminalWindow = WindowRecord(
            id: "window-shell", workspaceID: workspace.id, app: "Spaces", name: "build watcher", terminalTrackingID: "session-shell",
            role: "terminal", orderIndex: 0, lastSeenAt: "now")

        let overview = SpacesDeviceOverviewBuilder.build(
            projects: [project], workspaces: [.init(project: project, workspace: workspace, windows: [terminalWindow])], sessions: [session])

        let row = overview.workspaces.first?.terminalRows.first
        XCTAssertEqual(row?.title, "build watcher")
        XCTAssertEqual(row?.liveTitle, "vim main.swift")
    }

    /// Rows are ordered by name, so a program retitling itself cannot reorder the list — palette and
    /// cycling requests reference these rows by list index against a later overview.
    func testTerminalRowOrderFollowsNamesNotLiveTitles() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false, isArchived: false,
            isRunning: true, lastLaunchedAt: nil)
        let windows = [
            WindowRecord(
                id: "window-1", workspaceID: workspace.id, app: "Spaces", name: "shell-1", terminalTrackingID: "session-1", role: "terminal",
                orderIndex: 0, lastSeenAt: "now"),
            WindowRecord(
                id: "window-2", workspaceID: workspace.id, app: "Spaces", name: "shell-2", terminalTrackingID: "session-2", role: "terminal",
                orderIndex: 1, lastSeenAt: "now"),
        ]
        func rows(secondTitle: String) -> [String?] {
            let sessions = [
                makeSessionCatalogEntry(
                    sessionID: "session-1", title: "shell-1", workingDirectory: workspace.dir, workspaceID: workspace.id, attachmentSnapshot: .init()),
                makeSessionCatalogEntry(
                    sessionID: "session-2", title: "shell-2", workingDirectory: workspace.dir, workspaceID: workspace.id, attachmentSnapshot: .init(),
                    runtimeTitle: secondTitle),
            ]
            let overview = SpacesDeviceOverviewBuilder.build(
                projects: [project], workspaces: [.init(project: project, workspace: workspace, windows: windows)], sessions: sessions)
            return overview.workspaces.first?.terminalRows.map(\.sessionID) ?? []
        }

        XCTAssertEqual(rows(secondTitle: "shell-2"), ["session-1", "session-2"])
        // "a build" sorts before "shell-1"; the row must stay in place anyway.
        XCTAssertEqual(rows(secondTitle: "a build"), ["session-1", "session-2"])
    }

    func testTrackedWorkspaceTerminalRequiresLiveSessionIDBeforeStopIsAvailable() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false, isArchived: false,
            isRunning: true, lastLaunchedAt: nil)
        let terminalWindow = WindowRecord(
            id: "window-shell", workspaceID: workspace.id, app: "Spaces", name: "Shell", terminalTrackingID: nil, role: "terminal", orderIndex: 0,
            lastSeenAt: "now")

        let overview = SpacesDeviceOverviewBuilder.build(
            projects: [project], workspaces: [.init(project: project, workspace: workspace, windows: [terminalWindow])], sessions: [])

        let row = overview.workspaces.first?.terminalRows.first
        XCTAssertEqual(row?.runState, .running)
        XCTAssertNil(row?.sessionID)
        XCTAssertEqual(row?.canStop, false)
    }

    func testBuildIncludesEndedWorkspaceProcessRowsWithoutLiveControl() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, dir: "/repo/apps/web", dirname: nil, branch: "feature/docs", isDefault: false,
            isArchived: false, isRunning: true, lastLaunchedAt: nil)
        let descriptor = SpacesDeviceOverviewBuilder.WorkspaceDescriptor(project: project, workspace: workspace)
        let endedSession = makeSessionCatalogEntry(
            sessionID: "session-ended", title: "docs-watch", workingDirectory: "/repo/apps/web", state: .exited, workspaceID: workspace.id,
            attachmentSnapshot: .init(), isControlAvailable: true, isSubscriptionAvailable: true)

        let overview = SpacesDeviceOverviewBuilder.build(
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
            id: "workspace-1", projectID: project.id, dir: "/repo/apps/web", dirname: nil, branch: "feature/docs", isDefault: false,
            isArchived: false, isRunning: true, lastLaunchedAt: nil)
        let descriptor = SpacesDeviceOverviewBuilder.WorkspaceDescriptor(project: project, workspace: workspace)
        let endedSession = makeSessionCatalogEntry(
            sessionID: "session-ended-agent", title: "review-agent", workingDirectory: "/repo/apps/web", state: .exited, workspaceID: workspace.id,
            attachmentSnapshot: .init(), isControlAvailable: true, isSubscriptionAvailable: true)

        let overview = SpacesDeviceOverviewBuilder.build(
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
            id: "workspace-1", projectID: project.id, dir: "/repo/apps/web", dirname: nil, branch: "feature/docs", isDefault: false,
            isArchived: false, isRunning: true, lastLaunchedAt: nil)
        let descriptor = SpacesDeviceOverviewBuilder.WorkspaceDescriptor(project: project, workspace: workspace)
        let currentAgentSession = makeSessionCatalogEntry(
            sessionID: "agent-current", title: "review-agent", workingDirectory: "/repo/apps/web", workspaceID: workspace.id,
            attachmentSnapshot: .init())
        let orphanedAgentSession = makeSessionCatalogEntry(
            sessionID: "agent-orphan", title: "review-agent", workingDirectory: "/repo/apps/web", workspaceID: workspace.id,
            attachmentSnapshot: .init())

        let overview = SpacesDeviceOverviewBuilder.build(
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

    // MARK: - retainedTerminalSessionIDs (the daemon-published pane keep-set)

    /// A live interactive session is retained (it also feeds `sessions`).
    func testRetainedIncludesLiveAdHocSession() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false, isArchived: false,
            isRunning: true, lastLaunchedAt: nil)
        let liveSession = makeSessionCatalogEntry(
            sessionID: "session-live", title: "Shell", workingDirectory: workspace.dir, workspaceID: workspace.id, attachmentSnapshot: .init())

        let overview = SpacesDeviceOverviewBuilder.build(
            projects: [project], workspaces: [.init(project: project, workspace: workspace)], sessions: [liveSession])

        XCTAssertTrue(overview.retainedTerminalSessionIDs.contains("session-live"))
    }

    /// The regression: an ended ad hoc shell is not live and has no process/agent row, but its
    /// `runtime_targets` (terminal window) row still holds its transcript, so the daemon must keep
    /// retaining it — even though the builder's live-map strips its id out of `sessions`. This is the
    /// failing-first case: against the pre-fix payload the id survived on no surface.
    func testRetainedIncludesEndedSessionReferencedOnlyByRuntimeTargetRow() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false, isArchived: false,
            isRunning: true, lastLaunchedAt: nil)
        let endedShellWindow = WindowRecord(
            id: "window-shell", workspaceID: workspace.id, app: "Spaces", name: "Shell", terminalTrackingID: "session-ended-shell", role: "terminal",
            orderIndex: 0, lastSeenAt: "now")

        let overview = SpacesDeviceOverviewBuilder.build(
            projects: [project], workspaces: [.init(project: project, workspace: workspace, windows: [endedShellWindow])], sessions: [])

        // The session left `sessions` the moment it exited, but the daemon still retains it.
        XCTAssertFalse(overview.sessions.contains { $0.id == "session-ended-shell" })
        XCTAssertTrue(overview.retainedTerminalSessionIDs.contains("session-ended-shell"))
    }

    /// An exited process/agent row keeps its session retained too, matching the collector's rule; a
    /// session with no live core and no product row is not retained.
    func testRetainedIncludesExitedProductRowsAndExcludesUnreferencedSession() {
        let project = ProjectRecord(id: "project-1", name: "Project", dir: "/repo", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace-1", projectID: project.id, dir: "/repo/feature", dirname: nil, branch: "feature", isDefault: false, isArchived: false,
            isRunning: true, lastLaunchedAt: nil)
        let exitedProcess = RunningProcessRecord(
            id: "process-api", workspaceID: workspace.id, templateName: "api", command: "npm run dev", terminalApp: "Spaces",
            terminalTrackingID: "session-process", pid: nil, status: .exited, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: "later")
        let exitedAgent = AgentWindowRecord(
            id: "agent-review", workspaceID: workspace.id, provider: .spaces, label: "reviewer", terminalTrackingID: "session-agent", sessionKey: nil,
            status: .exited, createdAt: "now", updatedAt: "now")

        let overview = SpacesDeviceOverviewBuilder.build(
            projects: [project],
            workspaces: [.init(project: project, workspace: workspace, runningProcesses: [exitedProcess], agentWindows: [exitedAgent])], sessions: [])

        XCTAssertEqual(overview.retainedTerminalSessionIDs, ["session-agent", "session-process"])
        XCTAssertFalse(overview.retainedTerminalSessionIDs.contains("session-never-existed"))
    }

    private func makeSessionCatalogEntry(
        sessionID: String, title: String, workingDirectory: String, state: TerminalSessionState = .running, workspaceID: String,
        kind: TerminalSessionKind = .shell, attachmentSnapshot: TerminalSessionAttachmentSnapshot, isControlAvailable: Bool = true,
        isSubscriptionAvailable: Bool = true, userTitle: String? = nil, runtimeTitle: String? = nil
    ) -> TerminalSessionCatalogEntry {
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: .ghosttyEmbedded, lifetimePolicy: .persistent, title: title, workingDirectory: workingDirectory,
            shell: "/bin/zsh", command: nil, createdAt: "2026-05-18T08:00:00Z", workspaceID: workspaceID, kind: kind, userTitle: userTitle)
        let runtimeState = TerminalSessionRuntimeState(
            sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: 123, childPID: 456, state: state, updatedAt: "2026-05-18T08:00:05Z",
            title: runtimeTitle ?? title, workingDirectory: workingDirectory)
        return TerminalSessionCatalogEntry(
            launchConfiguration: launchConfiguration, runtimeState: runtimeState, attachmentSnapshot: attachmentSnapshot,
            paths: TerminalSessionPaths(rootDirectory: "/tmp/\(sessionID)"), isControlAvailable: isControlAvailable,
            isSubscriptionAvailable: isSubscriptionAvailable)
    }
}
