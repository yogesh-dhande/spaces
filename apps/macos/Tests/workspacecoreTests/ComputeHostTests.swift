import XCTest
import spacesterminalcore

@testable import workspacecore

final class ComputeHostTests: XCTestCase {
    func testResolvedAuthTokenUsesHostSpecificEnvironmentKey() throws {
        let key = ComputeHostCredentialStore.authTokenEnvironmentKey(hostID: "Builder-A.1")
        XCTAssertEqual(key, "SPACESD_AUTH_TOKEN_BUILDER_A_1")
        XCTAssertEqual(
            try ComputeHostCredentialStore.resolvedAuthToken(hostID: "Builder-A.1", environment: [key: "  remote-secret  "]), "remote-secret")
    }

    func testFreshStoreIncludesLocalHost() throws {
        let store = try makeTemporaryStore()

        let localHost = try XCTUnwrap(try store.computeHost(id: ComputeHostRecord.localHostID))

        XCTAssertEqual(localHost, ComputeHostRecord.local())
        XCTAssertEqual(try store.computeHosts(), [localHost])
    }

    func testStoreRoundTripsWorkspaceHostAndRuntimePath() throws {
        let store = try makeTemporaryStore()
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")
        let project = makeProjectRecord(id: "project-12345678", dir: try makeTempDirectory().path)
        let workspace = WorkspaceRecord(
            id: "workspace-12345678", projectID: project.id, hostID: host.id, title: "Feature A", dir: try makeTempDirectory().path,
            runtimePath: "/srv/spaces/project/feature-a", dirname: "feature-a", branch: "feature/a", isDefault: false, isArchived: false,
            isRunning: false, lastLaunchedAt: nil)
        try store.upsert(computeHost: host)
        try store.upsert(project: project)

        try store.upsert(workspace: workspace)

        let storedWorkspace = try XCTUnwrap(try store.workspace(id: workspace.id))
        XCTAssertEqual(try store.computeHost(id: host.id), host)
        XCTAssertEqual(storedWorkspace.id, workspace.id)
        XCTAssertEqual(storedWorkspace.projectID, workspace.projectID)
        XCTAssertEqual(storedWorkspace.hostID, workspace.hostID)
        XCTAssertEqual(storedWorkspace.dir, workspace.dir)
        XCTAssertEqual(storedWorkspace.runtimePath, workspace.runtimePath)
        XCTAssertEqual(storedWorkspace.branch, workspace.branch)
    }

    func testSameProjectBranchCanExistOnDifferentHosts() throws {
        let store = try makeTemporaryStore()
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")
        let project = makeProjectRecord(id: "project-12345678", dir: try makeTempDirectory().path)
        let localWorkspace = WorkspaceRecord(
            id: "workspace-local", projectID: project.id, title: "Local Feature", dir: try makeTempDirectory().path, dirname: "feature",
            branch: "feature/shared", isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        let remoteWorkspace = WorkspaceRecord(
            id: "workspace-remote", projectID: project.id, hostID: host.id, title: "Remote Feature", dir: localWorkspace.dir,
            runtimePath: "/srv/spaces/project/feature", dirname: "feature", branch: "feature/shared", isDefault: false, isArchived: false,
            isRunning: false, lastLaunchedAt: nil)
        try store.upsert(computeHost: host)
        try store.upsert(project: project)

        try store.upsert(workspace: localWorkspace)
        try store.upsert(workspace: remoteWorkspace)

        XCTAssertEqual(Set(try store.workspaces(projectID: project.id).map(\.id)), ["workspace-local", "workspace-remote"])
    }

    func testSameProjectBranchCannotExistTwiceOnSameHost() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(id: "project-12345678", dir: try makeTempDirectory().path)
        let first = WorkspaceRecord(
            id: "workspace-one", projectID: project.id, title: "One", dir: try makeTempDirectory().path, dirname: "one", branch: "feature/shared",
            isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        let second = WorkspaceRecord(
            id: "workspace-two", projectID: project.id, title: "Two", dir: try makeTempDirectory().path, dirname: "two", branch: "feature/shared",
            isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(project: project)
        try store.upsert(workspace: first)

        XCTAssertThrowsError(try store.upsert(workspace: second))
    }

    func testArchivedSameHostBranchCanCoexistWithActiveWorkspace() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(id: "project-12345678", dir: try makeTempDirectory().path)
        let archived = WorkspaceRecord(
            id: "workspace-archived", projectID: project.id, title: "Archived", dir: try makeTempDirectory().path, dirname: "archived",
            branch: "feature/shared", isDefault: false, isArchived: true, isRunning: false, lastLaunchedAt: nil)
        let active = WorkspaceRecord(
            id: "workspace-active", projectID: project.id, title: "Active", dir: try makeTempDirectory().path, dirname: "active",
            branch: "feature/shared", isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(project: project)

        try store.upsert(workspace: archived)
        try store.upsert(workspace: active)

        XCTAssertEqual(Set(try store.workspaces(projectID: project.id, includeArchived: true).map(\.id)), ["workspace-active", "workspace-archived"])
    }

    func testComputeHostSelectionUsesWorkspaceHostID() throws {
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")
        let hosts = [ComputeHostRecord.localHostID: ComputeHostRecord.local(), host.id: host]
        let project = ProjectRecord(id: "project", name: "Project", dir: "/project", isGitRepo: true, defaultBranch: "main")
        let localWorkspace = WorkspaceRecord(
            id: "workspace-local", projectID: project.id, title: "Local", dir: "/project", dirname: nil, branch: "feature", isDefault: false,
            isArchived: false, isRunning: false, lastLaunchedAt: nil)
        let remoteWorkspace = WorkspaceRecord(
            id: "workspace-remote", projectID: project.id, hostID: host.id, title: "Remote", dir: "/project/.worktrees/feature",
            runtimePath: "/srv/spaces/project/feature", dirname: nil, branch: "feature", isDefault: false, isArchived: false, isRunning: false,
            lastLaunchedAt: nil)

        XCTAssertEqual(
            ComputeHostPlanner.selectHost(project: project, workspace: localWorkspace, hostsByID: hosts), .local(ComputeHostRecord.local()))
        XCTAssertEqual(ComputeHostPlanner.selectHost(project: project, workspace: remoteWorkspace, hostsByID: hosts), .remote(host))
    }

    func testDaemonEndpointSelectionUsesLocalSocketOrPinnedRemoteEndpoint() {
        let localHost = ComputeHostRecord.local()
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")

        let local = ComputeHostPlanner.daemonTarget(selection: .local(localHost), localSocketPath: "/tmp/spacesd.sock")
        let remote = ComputeHostPlanner.daemonTarget(selection: .remote(host), localSocketPath: "/tmp/spacesd.sock")

        XCTAssertEqual(local.transport, .localUnixSocket)
        XCTAssertEqual(local.computeHostID, localHost.id)
        XCTAssertEqual(local.socketPath, "/tmp/spacesd.sock")
        XCTAssertNil(local.endpoint)
        XCTAssertEqual(remote.transport, .pinnedTLS)
        XCTAssertEqual(remote.computeHostID, host.id)
        XCTAssertEqual(remote.endpoint?.certificateFingerprint, "SHA256:abcdef")
    }

    func testRuntimeManifestUsesWorkspaceRuntimePathPortsAndAllowedRoots() {
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")
        let project = ProjectRecord(id: "project", name: "Project", dir: "/local/project", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace", projectID: project.id, hostID: host.id, title: "Feature", dir: "/local/project/.worktrees/feature",
            runtimePath: "/srv/spaces/project/feature", dirname: nil, branch: "feature", targetBranch: "main", isDefault: false, isArchived: false,
            isRunning: false, lastLaunchedAt: nil)
        let ports = [WorkspaceRuntimePortMapping(id: "api", name: "API_PORT", port: 3001)]

        let manifest = ComputeHostPlanner.runtimeManifest(project: project, workspace: workspace, selection: .remote(host), namedPorts: ports)

        XCTAssertEqual(manifest.location, .remote)
        XCTAssertEqual(manifest.computeHostID, host.id)
        XCTAssertEqual(manifest.remotePath, workspace.runtimePath)
        XCTAssertEqual(manifest.allowedFileRoots, [workspace.runtimePath])
        XCTAssertEqual(manifest.namedPorts, ports)
        XCTAssertEqual(manifest.processEnvironment["SPACES_WORKSPACE_ID"], workspace.id)
        XCTAssertEqual(manifest.processEnvironment["SPACES_PROJECT_ID"], project.id)
        XCTAssertEqual(manifest.processEnvironment["API_PORT"], "3001")
        XCTAssertNil(manifest.processEnvironment["SPACES_COMPUTE_LOCATION"])
        XCTAssertNil(manifest.processEnvironment["SPACES_COMPUTE_HOST_ID"])
        XCTAssertNil(manifest.processEnvironment["SPACES_REMOTE_WORKSPACE_PATH"])
    }

    func testWorkspaceRuntimePlanUsesRemoteWorkspaceHostAndRuntimePath() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")
        let api = PortDefinition(id: "api", name: "API_PORT")
        let project = ProjectRecord(
            id: "project-abcdef12", name: "Project", dir: try makeTempDirectory().path, isGitRepo: true, defaultBranch: "main", ports: [api])
        let workspace = WorkspaceRecord(
            id: "workspace-fedcba98", projectID: project.id, hostID: host.id, title: "Feature One", dir: try makeTempDirectory().path,
            runtimePath: "/srv/spaces/project/feature-one", dirname: "feature-one", branch: "feature/one", targetBranch: "main", isDefault: false,
            isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try orchestrator.upsertComputeHost(host)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.setWorkspacePortDefinitions(workspaceID: workspace.id, definitions: [api])
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3001], names: [api.name], definitionIDs: [api.id])

        let plan = try orchestrator.workspaceRuntimePlan(workspaceID: workspace.id)
        let secondPlan = try orchestrator.workspaceRuntimePlan(workspaceID: workspace.id)

        guard case .remote(let selectedHost) = plan.selection else { return XCTFail("Expected remote compute host selection.") }
        XCTAssertEqual(selectedHost, host)
        XCTAssertEqual(secondPlan.workspace.runtimePath, workspace.runtimePath)
        XCTAssertEqual(plan.daemonTarget.transport, .pinnedTLS)
        XCTAssertEqual(plan.daemonTarget.endpoint, host.daemonEndpoint)
        XCTAssertEqual(plan.remoteSSHURI, ComputeHostPlanner.remoteSSHURI(host: host, path: workspace.runtimePath))
        XCTAssertEqual(plan.manifest.location, .remote)
        XCTAssertEqual(plan.manifest.computeHostID, host.id)
        XCTAssertEqual(plan.manifest.remotePath, workspace.runtimePath)
        XCTAssertEqual(plan.manifest.namedPorts, [WorkspaceRuntimePortMapping(id: api.id, name: api.name, port: 3001)])
        XCTAssertEqual(plan.manifest.processEnvironment["API_PORT"], "3001")
    }

    func testBuildWorkspaceEnvIncludesWorkspaceIdentityOnlyForLocalRuntime() throws {
        let orchestrator = WorkspaceOrchestrator(store: try makeTemporaryStore())
        let project = makeProjectRecord(id: "project-a", dir: "/projects/app")
        let workspace = makeWorkspaceRecord(id: "workspace-a", projectID: project.id, title: "dev", dir: "/projects/app")

        let env = orchestrator.buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: [(port: 8080, name: "WEB_PORT")])

        XCTAssertEqual(env["WEB_PORT"], "8080")
        XCTAssertEqual(env["SPACES_WORKSPACE_ID"], workspace.id)
        XCTAssertEqual(env["SPACES_PROJECT_ID"], project.id)
        XCTAssertEqual(env["SPACES_WORKSPACE_DIR"], workspace.runtimePath)
        XCTAssertEqual(env["SPACES_PROJECT_DIR"], project.dir)
        XCTAssertNil(env["SPACES_COMPUTE_LOCATION"])
        XCTAssertNil(env["SPACES_COMPUTE_HOST_ID"])
        XCTAssertNil(env["SPACES_REMOTE_WORKSPACE_PATH"])
    }

    func testWorkspaceLaunchRunsRemoteSetupAndProcessThroughSpacesd() throws {
        let (store, dbPath) = try makeTemporaryStoreWithPath()
        let recorder = RemoteTerminalServiceRecorder()
        let openedWindows = BuiltInTerminalWindowOpenRecorder()
        let closedWindows = BuiltInTerminalWindowCloseRecorder()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowOpener: openedWindows.open, builtInTerminalWindowCloser: closedWindows.close,
            remoteTerminalServiceClient: recorder.client)
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")
        let projectDir = try makeTempDirectory()
        let setupMarker = projectDir.appendingPathComponent("setup.marker")
        let processMarker = projectDir.appendingPathComponent("process.marker")
        let project = ProjectRecord(
            id: "project-a", name: "Project", dir: projectDir.path, isGitRepo: true, defaultBranch: "main",
            setupScript: "printf setup > setup.marker", processes: [ProcessTemplate(name: "Server", command: "printf process > process.marker")])
        let workspace = remoteWorkspace(projectID: project.id, hostID: host.id, localDir: projectDir.path)
        try orchestrator.upsertComputeHost(host)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: project.processes)
        try store.setWorkspaceSetupState(workspaceID: workspace.id, status: .pending, errorMessage: nil, startedAt: nil, finishedAt: nil)

        try withEnv(name: "SPACES_DB_PATH", value: dbPath) {
            try orchestrator.upWorkspace(workspaceID: workspace.id)

            let requests = recorder.requests()
            XCTAssertEqual(requests.map(\.command), ["runWorkspaceCommand", "create"])
            let setupRequest = try XCTUnwrap(requests.first)
            XCTAssertEqual(setupRequest.runtimeManifest?.location, .remote)
            XCTAssertEqual(setupRequest.runtimeManifest?.workspaceID, workspace.id)
            XCTAssertEqual(setupRequest.workspaceCommand?.workingDirectory, workspace.runtimePath)
            XCTAssertEqual(setupRequest.workspaceCommand?.environment["SPACES_WORKSPACE_DIR"], workspace.runtimePath)
            XCTAssertEqual(setupRequest.workspaceCommand?.environment["SPACES_PROJECT_DIR"], workspace.runtimePath)
            XCTAssertNil(setupRequest.workspaceCommand?.environment["SPACES_COMPUTE_HOST_ID"])
            XCTAssertEqual(setupRequest.worktreeRefresh?.branch, "feature")

            let createRequest = try XCTUnwrap(requests.last)
            XCTAssertEqual(createRequest.launchConfiguration?.workingDirectory, workspace.runtimePath)
            XCTAssertEqual(createRequest.launchConfiguration?.shell, "/bin/bash")
            XCTAssertEqual(createRequest.launchConfiguration?.kind, .process)
            XCTAssertEqual(createRequest.worktreeRefresh?.path, workspace.runtimePath)
            let remoteSessionID = try XCTUnwrap(createRequest.launchConfiguration?.sessionID)
            let openedWindow = try XCTUnwrap(openedWindows.opened().first)
            XCTAssertEqual(openedWindows.opened().count, 1)
            XCTAssertEqual(openedWindow.sessionID, remoteSessionID)
            XCTAssertEqual(openedWindow.mode, .owner)
            let mirroredPaths = try TerminalSessionPaths.forSession(id: openedWindow.sessionID)
            let mirroredLaunchConfiguration = try TerminalSessionPersistence.readLaunchConfiguration(paths: mirroredPaths)
            let mirroredRuntimeState = try TerminalSessionPersistence.readRuntimeState(paths: mirroredPaths)
            XCTAssertEqual(mirroredLaunchConfiguration.workspaceID, workspace.id)
            XCTAssertEqual(mirroredLaunchConfiguration.kind, .process)
            XCTAssertEqual(mirroredRuntimeState.servicePID, 42)
            XCTAssertEqual(mirroredRuntimeState.childPID, 4242)

            XCTAssertFalse(FileManager.default.fileExists(atPath: setupMarker.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: processMarker.path))
            XCTAssertEqual(try store.workspaceSetupState(workspaceID: workspace.id)?.status, .succeeded)
            XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
            let runningProcess = try XCTUnwrap(try store.runningProcesses(workspaceID: workspace.id).first)
            XCTAssertNotEqual(runningProcess.runtimeTargetID, host.id)
            XCTAssertEqual(runningProcess.runtimeTargetID, runningProcess.id)
            XCTAssertEqual(runningProcess.terminalTrackingID, remoteSessionID)
            XCTAssertEqual(runningProcess.logPath, "/tmp/\(remoteSessionID).log")

            _ = try orchestrator.stopWorkspace(workspaceID: workspace.id)

            let stopRequests = recorder.requests()
            XCTAssertEqual(stopRequests.map(\.command), ["runWorkspaceCommand", "create", "terminate"])
            XCTAssertEqual(stopRequests.last?.sessionID, remoteSessionID)
            XCTAssertEqual(closedWindows.closed(), [remoteSessionID])
            XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
            XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
        }
    }

    func testRunWorkspaceSetupRunsRemoteCommandThroughSpacesd() throws {
        let store = try makeTemporaryStore()
        let recorder = RemoteTerminalServiceRecorder()
        let orchestrator = WorkspaceOrchestrator(store: store, remoteTerminalServiceClient: recorder.client)
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")
        let projectDir = try makeTempDirectory()
        let setupMarker = projectDir.appendingPathComponent("setup.marker")
        let project = ProjectRecord(
            id: "project-a", name: "Project", dir: projectDir.path, isGitRepo: true, defaultBranch: "main", setupScript: "printf setup > setup.marker"
        )
        let workspace = remoteWorkspace(projectID: project.id, hostID: host.id, localDir: projectDir.path)
        try orchestrator.upsertComputeHost(host)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        try orchestrator.runWorkspaceSetup(workspaceID: workspace.id)

        let request = try XCTUnwrap(recorder.requests().first)
        XCTAssertEqual(request.command, "runWorkspaceCommand")
        XCTAssertEqual(request.runtimeManifest?.location, .remote)
        XCTAssertEqual(request.workspaceCommand?.workingDirectory, workspace.runtimePath)
        XCTAssertNil(request.workspaceCommand?.environment["SPACES_COMPUTE_HOST_ID"])
        XCTAssertEqual(request.worktreeRefresh?.branch, "feature")

        XCTAssertFalse(FileManager.default.fileExists(atPath: setupMarker.path))
        let setupState = try XCTUnwrap(try store.workspaceSetupState(workspaceID: workspace.id))
        XCTAssertEqual(setupState.status, .succeeded)
        XCTAssertEqual(setupState.exitCode, 0)
        XCTAssertEqual(setupState.logPath, "/tmp/workspace-command.log")
    }

    func testOpenWorkspaceTerminalRunsRemoteShellThroughSpacesd() throws {
        let (store, dbPath) = try makeTemporaryStoreWithPath()
        let recorder = RemoteTerminalServiceRecorder()
        let openedWindows = BuiltInTerminalWindowOpenRecorder()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowOpener: openedWindows.open, remoteTerminalServiceClient: recorder.client)
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")
        let projectDir = try makeTempDirectory()
        let project = ProjectRecord(id: "project-a", name: "Project", dir: projectDir.path, isGitRepo: true, defaultBranch: "main")
        let workspace = remoteWorkspace(projectID: project.id, hostID: host.id, localDir: projectDir.path)
        try orchestrator.upsertComputeHost(host)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let sessionID = try withEnv(name: "SPACES_DB_PATH", value: dbPath) { try orchestrator.openWorkspaceTerminal(workspaceID: workspace.id) }

        let request = try XCTUnwrap(recorder.requests().first)
        XCTAssertEqual(request.command, "create")
        XCTAssertEqual(request.launchConfiguration?.sessionID, sessionID)
        XCTAssertEqual(request.launchConfiguration?.kind, .shell)
        XCTAssertEqual(request.launchConfiguration?.workingDirectory, workspace.runtimePath)
        XCTAssertEqual(request.launchConfiguration?.shell, "/bin/bash")
        XCTAssertEqual(request.worktreeRefresh?.branch, "feature")
        XCTAssertTrue(openedWindows.opened().isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
        XCTAssertEqual(try store.windows(workspaceID: workspace.id).first?.terminalTrackingID, sessionID)
    }

    func testRemoteWorkspaceTerminalReservationPersistsWindowAfterLaunchCompletes() throws {
        let (store, dbPath) = try makeTemporaryStoreWithPath()
        let recorder = RemoteTerminalServiceRecorder()
        let orchestrator = WorkspaceOrchestrator(store: store, remoteTerminalServiceClient: recorder.client)
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")
        let projectDir = try makeTempDirectory()
        let project = ProjectRecord(id: "project-a", name: "Project", dir: projectDir.path, isGitRepo: true, defaultBranch: "main")
        let workspace = remoteWorkspace(projectID: project.id, hostID: host.id, localDir: projectDir.path)
        try orchestrator.upsertComputeHost(host)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let reservation = try orchestrator.reserveWorkspaceTerminalLaunch(workspaceID: workspace.id)

        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(recorder.requests().isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)

        let sessionID = try withEnv(name: "SPACES_DB_PATH", value: dbPath) { try orchestrator.finishReservedWorkspaceTerminalLaunch(reservation) }

        XCTAssertEqual(sessionID, reservation.sessionID)
        XCTAssertEqual(recorder.requests().first?.command, "create")
        let terminalWindow = try XCTUnwrap(try store.windows(workspaceID: workspace.id).first)
        XCTAssertEqual(terminalWindow.terminalTrackingID, sessionID)
        XCTAssertEqual(terminalWindow.name, "shell-1")
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
    }

    func testRemoteSSHURIIncludesUserHostPortAndPath() {
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")

        XCTAssertEqual(
            ComputeHostPlanner.remoteSSHURI(host: host, path: "/srv/spaces/project/feature"),
            "vscode-remote://ssh-remote+spaces@builder-a.internal/srv/spaces/project/feature?port=22")
    }

    func testRemoteWorktreeRefreshBlockMessageIncludesResolutionGuidance() {
        let block = RemoteWorktreeRefreshBlock(
            hostName: "Builder A", path: "/srv/spaces/project/feature", branch: "feature", reason: .divergentHistory,
            detail: "origin/feature is not an ancestor")

        XCTAssertTrue(block.localizedDescription.contains("Builder A"))
        XCTAssertTrue(block.localizedDescription.contains("/srv/spaces/project/feature"))
        XCTAssertTrue(block.localizedDescription.contains("feature"))
        XCTAssertTrue(block.localizedDescription.contains("fast-forward"))
        XCTAssertTrue(block.localizedDescription.contains("origin/feature is not an ancestor"))
    }

    func testDeleteComputeHostBlocksWhenWorkspaceIsAssignedToHost() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")
        let project = makeProjectRecord(id: "project-a", dir: try makeTempDirectory().path)
        let workspace = WorkspaceRecord(
            id: "workspace-a", projectID: project.id, hostID: host.id, title: "Feature", dir: try makeTempDirectory().path,
            runtimePath: "/srv/spaces/project/feature", dirname: nil, branch: "feature", isDefault: false, isArchived: false, isRunning: false,
            lastLaunchedAt: nil)
        try orchestrator.upsertComputeHost(host)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        XCTAssertThrowsError(try orchestrator.deleteComputeHost(id: host.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("assigned to that host"))
        }
        XCTAssertEqual(try store.computeHost(id: host.id), host)
    }

    func testDeleteComputeHostRejectsLocalHost() throws {
        let orchestrator = WorkspaceOrchestrator(store: try makeTemporaryStore())

        XCTAssertThrowsError(try orchestrator.deleteComputeHost(id: ComputeHostRecord.localHostID)) { error in
            XCTAssertTrue(error.localizedDescription.contains("local host record cannot be removed"))
        }
    }

    func testDeleteComputeHostDeletesUnassignedHostAndReportsCredentialCleanup() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let host = makeComputeHostRecord(id: "test-host-\(UUID().uuidString)", name: "Builder A")
        try orchestrator.upsertComputeHost(host)

        let result = try orchestrator.deleteComputeHost(id: host.id)

        XCTAssertEqual(result.hostID, host.id)
        XCTAssertFalse(result.credentialTokenDeleted)
        XCTAssertNil(try store.computeHost(id: host.id))
    }

    func testBrowserSSHForwardResolverMapsRemoteNamedLocalServicePort() throws {
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")
        let plan = makeRuntimePlan(selection: .remote(host), ports: [WorkspaceRuntimePortMapping(id: "web", name: "WEB_PORT", port: 3000)])
        let recorder = BrowserForwardRecorder(localPort: 49_231)

        let mapped = try BrowserSSHForwardResolver.resolvedURL("http://localhost:3000/status?ready=1", runtimePlan: plan, forwarder: recorder.forward)

        XCTAssertEqual(mapped, "http://127.0.0.1:49231/status?ready=1")
        XCTAssertEqual(recorder.requests.map(\.computeHostID), [host.id])
        XCTAssertEqual(recorder.requests.map(\.remotePort), [3000])
        XCTAssertEqual(recorder.requests.map(\.sshHost), [host.sshHost])
    }

    func testBrowserSSHForwardResolverReusesLivePersistedForward() throws {
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")
        let plan = makeRuntimePlan(selection: .remote(host), ports: [WorkspaceRuntimePortMapping(id: "web", name: "WEB_PORT", port: 3000)])
        let checker = BrowserLiveForwardCheckerRecorder(liveLocalPort: 49_230)

        let mapped = BrowserSSHForwardResolver.reusableResolvedURL(
            "http://127.0.0.1:49230/status?ready=1", for: "http://localhost:3000/status?ready=1", runtimePlan: plan
        ) { localPort, request in checker.check(localPort: localPort, request: request) }

        XCTAssertEqual(mapped, "http://127.0.0.1:49230/status?ready=1")
        XCTAssertEqual(checker.requests.map(\.computeHostID), [host.id])
        XCTAssertEqual(checker.requests.map(\.remotePort), [3000])
    }

    func testBrowserSSHForwardResolverRejectsPersistedForwardForDifferentURL() throws {
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")
        let plan = makeRuntimePlan(selection: .remote(host), ports: [WorkspaceRuntimePortMapping(id: "web", name: "WEB_PORT", port: 3000)])

        let mapped = BrowserSSHForwardResolver.reusableResolvedURL(
            "http://127.0.0.1:49230/admin", for: "http://localhost:3000/status", runtimePlan: plan
        ) { _, _ in
            XCTFail("Different paths should not probe SSH forwards.")
            return true
        }

        XCTAssertNil(mapped)
    }

    func testBrowserSSHForwardResolverLeavesUnrelatedRemoteURLsUnchanged() throws {
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")
        let plan = makeRuntimePlan(selection: .remote(host), ports: [WorkspaceRuntimePortMapping(id: "web", name: "WEB_PORT", port: 3000)])

        let external = try BrowserSSHForwardResolver.resolvedURL("https://example.com:3000/status", runtimePlan: plan) { _ in
            XCTFail("External URLs should not open SSH forwards.")
            return 49_231
        }
        let unnamedPort = try BrowserSSHForwardResolver.resolvedURL("http://127.0.0.1:9999/status", runtimePlan: plan) { _ in
            XCTFail("Unnamed local-service ports should not open SSH forwards.")
            return 49_231
        }

        XCTAssertEqual(external, "https://example.com:3000/status")
        XCTAssertEqual(unnamedPort, "http://127.0.0.1:9999/status")
    }

    func testBrowserSSHForwardResolverLeavesLocalRuntimeURLsUnchanged() throws {
        let plan = makeRuntimePlan(
            selection: .local(ComputeHostRecord.local()), ports: [WorkspaceRuntimePortMapping(id: "web", name: "WEB_PORT", port: 3000)])

        let mapped = try BrowserSSHForwardResolver.resolvedURL("http://localhost:3000/status", runtimePlan: plan) { _ in
            XCTFail("Local runtime URLs should not open SSH forwards.")
            return 49_231
        }

        XCTAssertEqual(mapped, "http://localhost:3000/status")
    }

    private func remoteWorkspace(projectID: String, hostID: String, localDir: String) -> WorkspaceRecord {
        WorkspaceRecord(
            id: "workspace-a", projectID: projectID, hostID: hostID, title: "dev", dir: localDir, runtimePath: "/srv/spaces/project/feature",
            dirname: nil, branch: "feature", targetBranch: "main", isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
    }

    private func makeTemporaryStoreWithPath() throws -> (SQLiteStore, String) {
        let dir = try makeTempDirectory()
        let dbURL = dir.appendingPathComponent("spaces-test.db")
        return (try SQLiteStore(path: dbURL.path), dbURL.path)
    }

    private func withEnv<T>(name: String, value: String, run: () throws -> T) throws -> T {
        let old = getenv(name).map { String(cString: $0) }
        setenv(name, value, 1)
        defer { if let old { setenv(name, old, 1) } else { unsetenv(name) } }
        return try run()
    }

    private func makeRuntimePlan(selection: ComputeHostSelection, ports: [WorkspaceRuntimePortMapping]) -> WorkspaceRuntimePlan {
        let project = ProjectRecord(id: "project", name: "Project", dir: "/local/project", isGitRepo: true, defaultBranch: "main")
        let workspaceHostID = selection.computeHostID ?? ComputeHostRecord.localHostID
        let runtimePath = selection.isRemote ? "/srv/spaces/project/feature" : "/local/project/workspace"
        let workspace = WorkspaceRecord(
            id: "workspace", projectID: project.id, hostID: workspaceHostID, title: "Feature", dir: "/local/project/workspace",
            runtimePath: runtimePath, dirname: nil, branch: "feature", isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        let manifest = ComputeHostPlanner.runtimeManifest(project: project, workspace: workspace, selection: selection, namedPorts: ports)
        return WorkspaceRuntimePlan(
            project: project, workspace: workspace, selection: selection, manifest: manifest,
            daemonTarget: ComputeHostPlanner.daemonTarget(selection: selection, localSocketPath: "/tmp/spacesd.sock"), remoteSSHURI: nil)
    }
}

private final class BrowserForwardRecorder: @unchecked Sendable {
    let localPort: Int
    private let lock = NSLock()
    private var recordedRequests: [BrowserSSHForwardRequest] = []

    init(localPort: Int) { self.localPort = localPort }

    var requests: [BrowserSSHForwardRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func forward(_ request: BrowserSSHForwardRequest) throws -> Int {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()
        return localPort
    }
}

private final class BrowserLiveForwardCheckerRecorder: @unchecked Sendable {
    let liveLocalPort: Int
    private let lock = NSLock()
    private var checkedRequests: [BrowserSSHForwardRequest] = []

    init(liveLocalPort: Int) { self.liveLocalPort = liveLocalPort }

    var requests: [BrowserSSHForwardRequest] {
        lock.lock()
        defer { lock.unlock() }
        return checkedRequests
    }

    func check(localPort: Int, request: BrowserSSHForwardRequest) -> Bool {
        lock.lock()
        checkedRequests.append(request)
        lock.unlock()
        return localPort == liveLocalPort
    }
}

private final class BuiltInTerminalWindowOpenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(sessionID: String, mode: TerminalAttachmentMode)] = []

    func open(sessionID: String, mode: TerminalAttachmentMode) {
        lock.lock()
        entries.append((sessionID: sessionID, mode: mode))
        lock.unlock()
    }

    func opened() -> [(sessionID: String, mode: TerminalAttachmentMode)] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

private final class BuiltInTerminalWindowCloseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var sessionIDs: [String] = []

    func close(sessionID: String) {
        lock.lock()
        sessionIDs.append(sessionID)
        lock.unlock()
    }

    func closed() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return sessionIDs
    }
}

private final class RemoteTerminalServiceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequests: [TerminalServiceRequest] = []

    func client(target _: SpacesDaemonConnectionTarget, request: TerminalServiceRequest) throws -> TerminalServiceResponse {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()

        switch request.command {
        case "create":
            let launchConfiguration = try XCTUnwrap(request.launchConfiguration)
            let runtimeState = TerminalSessionRuntimeState(
                sessionID: launchConfiguration.sessionID, backend: launchConfiguration.backend, servicePID: 42, childPID: 4242, state: .running,
                updatedAt: "2026-06-10T00:00:00Z", title: launchConfiguration.title, workingDirectory: launchConfiguration.workingDirectory)
            return TerminalServiceResponse(
                ok: true, message: "created",
                session: TerminalServiceSessionSummary(
                    id: launchConfiguration.sessionID, title: launchConfiguration.title, workingDirectory: launchConfiguration.workingDirectory,
                    backend: launchConfiguration.backend, lifetimePolicy: launchConfiguration.lifetimePolicy, state: .running, servicePID: 42,
                    childPID: 4242, controlSocketPath: "/tmp/\(launchConfiguration.sessionID).sock",
                    outputPath: "/tmp/\(launchConfiguration.sessionID).log", launchConfiguration: launchConfiguration, runtimeState: runtimeState,
                    attachmentSnapshot: TerminalSessionAttachmentSnapshot()))
        case "runWorkspaceCommand":
            return TerminalServiceResponse(
                ok: true, message: "ran", commandResult: TerminalServiceCommandResult(exitCode: 0, logPath: "/tmp/workspace-command.log"))
        case "terminate": return TerminalServiceResponse(ok: true, message: "terminated")
        default: return TerminalServiceResponse(ok: true, message: "ok")
        }
    }

    func requests() -> [TerminalServiceRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }
}
