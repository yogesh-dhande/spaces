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

    func testStoreRoundTripsComputeHostAndWorkspaceBinding() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(id: "project-12345678", dir: try makeTempDirectory().path)
        let workspace = WorkspaceRecord(
            id: "workspace-12345678", projectID: project.id, title: "Feature A", dir: try makeTempDirectory().path, dirname: "feature-a",
            branch: "feature/a", isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")
        try store.upsert(computeHost: host)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.updateProjectDefaultComputeHost(id: project.id, hostID: host.id)
        try store.updateWorkspaceComputeHostOverride(id: workspace.id, hostID: host.id)
        let binding = WorkspaceComputeBinding(
            workspaceID: workspace.id, hostID: host.id, remotePath: "/srv/spaces/project/workspace", branch: "feature/a",
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")

        try store.upsert(workspaceComputeBinding: binding)

        XCTAssertEqual(try store.computeHost(id: host.id), host)
        XCTAssertEqual(try store.project(id: project.id)?.defaultComputeHostID, host.id)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.computeHostOverrideID, host.id)
        XCTAssertEqual(try store.workspaceComputeBinding(workspaceID: workspace.id, hostID: host.id), binding)
    }

    func testDeleteComputeHostClearsPreferencesAndBindings() throws {
        let store = try makeTemporaryStore()
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")
        let project = makeProjectRecord(id: "project-12345678", dir: try makeTempDirectory().path)
        let workspace = WorkspaceRecord(
            id: "workspace-12345678", projectID: project.id, title: "Feature A", dir: try makeTempDirectory().path, dirname: "feature-a",
            branch: "feature/a", isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        let binding = WorkspaceComputeBinding(
            workspaceID: workspace.id, hostID: host.id, remotePath: "/srv/spaces/project/workspace", branch: "feature/a",
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
        try store.upsert(computeHost: host)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.updateProjectDefaultComputeHost(id: project.id, hostID: host.id)
        try store.updateWorkspaceComputeHostOverride(id: workspace.id, hostID: host.id)
        try store.upsert(workspaceComputeBinding: binding)

        try store.deleteComputeHost(id: host.id)

        XCTAssertNil(try store.computeHost(id: host.id))
        XCTAssertNil(try store.project(id: project.id)?.defaultComputeHostID)
        XCTAssertNil(try store.workspace(id: workspace.id)?.computeHostOverrideID)
        XCTAssertNil(try store.workspaceComputeBinding(workspaceID: workspace.id, hostID: host.id))
    }

    func testComputeHostPrecedenceUsesWorkspaceOverrideThenProjectDefaultThenLocal() throws {
        let defaultHost = makeComputeHostRecord(id: "host-default", name: "Default")
        let overrideHost = makeComputeHostRecord(id: "host-override", name: "Override")
        let hosts = [defaultHost.id: defaultHost, overrideHost.id: overrideHost]
        let project = ProjectRecord(
            id: "project", name: "Project", dir: "/project", isGitRepo: true, defaultBranch: "main", defaultComputeHostID: defaultHost.id)
        let localProject = ProjectRecord(id: "local-project", name: "Local", dir: "/local", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace", projectID: project.id, title: "Workspace", dir: "/project", dirname: nil, branch: "feature", isDefault: false,
            isArchived: false, isRunning: false, lastLaunchedAt: nil)
        let overrideWorkspace = WorkspaceRecord(
            id: "workspace", projectID: project.id, title: "Workspace", dir: "/project", dirname: nil, branch: "feature", isDefault: false,
            isArchived: false, isRunning: false, lastLaunchedAt: nil, computeHostOverrideID: overrideHost.id)

        XCTAssertEqual(ComputeHostPlanner.selectHost(project: project, workspace: overrideWorkspace, hostsByID: hosts), .remote(overrideHost))
        XCTAssertEqual(ComputeHostPlanner.selectHost(project: project, workspace: workspace, hostsByID: hosts), .remote(defaultHost))
        XCTAssertEqual(ComputeHostPlanner.selectHost(project: localProject, workspace: workspace, hostsByID: hosts), .localMac)
    }

    func testDaemonEndpointSelectionUsesLocalSocketOrPinnedRemoteEndpoint() {
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")

        let local = ComputeHostPlanner.daemonTarget(selection: .localMac, localSocketPath: "/tmp/spacesd.sock")
        let remote = ComputeHostPlanner.daemonTarget(selection: .remote(host), localSocketPath: "/tmp/spacesd.sock")

        XCTAssertEqual(local.transport, .localUnixSocket)
        XCTAssertEqual(local.socketPath, "/tmp/spacesd.sock")
        XCTAssertNil(local.endpoint)
        XCTAssertEqual(remote.transport, .pinnedTLS)
        XCTAssertEqual(remote.computeHostID, host.id)
        XCTAssertEqual(remote.endpoint?.certificateFingerprint, "SHA256:abcdef")
    }

    func testOrchestratorCreatesStableBindingOncePerWorkspaceAndHost() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")
        let project = makeProjectRecord(id: "project-abcdef12", dir: try makeTempDirectory().path)
        let workspace = WorkspaceRecord(
            id: "workspace-fedcba98", projectID: project.id, title: "Feature One", dir: try makeTempDirectory().path, dirname: "feature-one",
            branch: "feature/one", isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try orchestrator.upsertComputeHost(host)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let first = try orchestrator.stableComputeBinding(workspaceID: workspace.id, hostID: host.id)
        try store.updateWorkspaceDirname(id: workspace.id, dirname: "renamed")
        let second = try orchestrator.stableComputeBinding(workspaceID: workspace.id, hostID: host.id)

        XCTAssertEqual(first.remotePath, "/srv/spaces/project-projecta/feature-one-workspac")
        XCTAssertEqual(second.remotePath, first.remotePath)
        XCTAssertEqual(try store.workspaceComputeBindings(workspaceID: workspace.id), [first])
    }

    func testRuntimeManifestUsesRemoteBindingPathPortsAndAllowedRoots() {
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")
        let project = ProjectRecord(id: "project", name: "Project", dir: "/local/project", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace", projectID: project.id, title: "Feature", dir: "/local/project/.worktrees/feature", dirname: nil, branch: "feature",
            targetBranch: "main", isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        let binding = WorkspaceComputeBinding(
            workspaceID: workspace.id, hostID: host.id, remotePath: "/srv/spaces/project/feature", branch: "feature",
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
        let ports = [WorkspaceRuntimePortMapping(id: "api", name: "API_PORT", port: 3001)]

        let manifest = ComputeHostPlanner.runtimeManifest(
            project: project, workspace: workspace, selection: .remote(host), binding: binding, namedPorts: ports)

        XCTAssertEqual(manifest.location, .remote)
        XCTAssertEqual(manifest.computeHostID, host.id)
        XCTAssertEqual(manifest.remotePath, binding.remotePath)
        XCTAssertEqual(manifest.allowedFileRoots, [binding.remotePath])
        XCTAssertEqual(manifest.processEnvironment["SPACES_COMPUTE_LOCATION"], "remote")
        XCTAssertEqual(manifest.processEnvironment["SPACES_COMPUTE_HOST_ID"], host.id)
        XCTAssertEqual(manifest.processEnvironment["SPACES_REMOTE_WORKSPACE_PATH"], binding.remotePath)
        XCTAssertEqual(manifest.processEnvironment["API_PORT"], "3001")
    }

    func testWorkspaceRuntimePlanCreatesStableRemoteBindingAndManifest() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")
        let api = PortDefinition(id: "api", name: "API_PORT")
        let project = ProjectRecord(
            id: "project-abcdef12", name: "Project", dir: try makeTempDirectory().path, isGitRepo: true, defaultBranch: "main", ports: [api],
            defaultComputeHostID: host.id)
        let workspace = WorkspaceRecord(
            id: "workspace-fedcba98", projectID: project.id, title: "Feature One", dir: try makeTempDirectory().path, dirname: "feature-one",
            branch: "feature/one", targetBranch: "main", isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try orchestrator.upsertComputeHost(host)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.setWorkspacePortDefinitions(workspaceID: workspace.id, definitions: [api])
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3001], names: [api.name], definitionIDs: [api.id])

        let plan = try orchestrator.workspaceRuntimePlan(workspaceID: workspace.id)
        let secondPlan = try orchestrator.workspaceRuntimePlan(workspaceID: workspace.id)

        guard case .remote(let selectedHost) = plan.selection else { return XCTFail("Expected remote compute host selection.") }
        let binding = try XCTUnwrap(plan.binding)
        XCTAssertEqual(selectedHost, host)
        XCTAssertEqual(binding.remotePath, ComputeHostPlanner.proposedRemoteWorkspacePath(host: host, project: project, workspace: workspace))
        XCTAssertEqual(secondPlan.binding?.remotePath, binding.remotePath)
        XCTAssertEqual(try store.workspaceComputeBindings(workspaceID: workspace.id).map(\.remotePath), [binding.remotePath])
        XCTAssertEqual(plan.daemonTarget.transport, .pinnedTLS)
        XCTAssertEqual(plan.daemonTarget.endpoint, host.daemonEndpoint)
        XCTAssertEqual(plan.remoteSSHURI, ComputeHostPlanner.remoteSSHURI(host: host, path: binding.remotePath))
        XCTAssertEqual(plan.manifest.location, .remote)
        XCTAssertEqual(plan.manifest.computeHostID, host.id)
        XCTAssertEqual(plan.manifest.remotePath, binding.remotePath)
        XCTAssertEqual(plan.manifest.namedPorts, [WorkspaceRuntimePortMapping(id: api.id, name: api.name, port: 3001)])
        XCTAssertEqual(plan.manifest.processEnvironment["API_PORT"], "3001")
    }

    func testBuildWorkspaceEnvIncludesLocalComputeMetadata() throws {
        let orchestrator = WorkspaceOrchestrator(store: try makeTemporaryStore())
        let project = makeProjectRecord(id: "project-a", dir: "/projects/app")
        let workspace = makeWorkspaceRecord(id: "workspace-a", projectID: project.id, title: "dev", dir: "/projects/app")

        let env = orchestrator.buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: [(port: 8080, name: "WEB_PORT")])

        XCTAssertEqual(env["WEB_PORT"], "8080")
        XCTAssertEqual(env["SPACES_WORKSPACE_ID"], workspace.id)
        XCTAssertEqual(env["SPACES_PROJECT_ID"], project.id)
        XCTAssertEqual(env["SPACES_WORKSPACE_DIR"], workspace.dir)
        XCTAssertEqual(env["SPACES_PROJECT_DIR"], project.dir)
        XCTAssertEqual(env["SPACES_COMPUTE_LOCATION"], "local")
        XCTAssertNil(env["SPACES_COMPUTE_HOST_ID"])
        XCTAssertNil(env["SPACES_REMOTE_WORKSPACE_PATH"])
    }

    func testWorkspaceLaunchRunsRemoteSetupAndProcessThroughSpacesd() throws {
        let store = try makeTemporaryStore()
        let recorder = RemoteTerminalServiceRecorder()
        let openedWindows = BuiltInTerminalWindowOpenRecorder()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowOpener: openedWindows.open, remoteTerminalServiceClient: recorder.client)
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")
        let projectDir = try makeTempDirectory()
        let setupMarker = projectDir.appendingPathComponent("setup.marker")
        let processMarker = projectDir.appendingPathComponent("process.marker")
        let project = ProjectRecord(
            id: "project-a", name: "Project", dir: projectDir.path, isGitRepo: true, defaultBranch: "main",
            setupScript: "printf setup > setup.marker", processes: [ProcessTemplate(name: "Server", command: "printf process > process.marker")],
            defaultComputeHostID: host.id)
        let workspace = WorkspaceRecord(
            id: "workspace-a", projectID: project.id, title: "dev", dir: projectDir.path, dirname: nil, branch: "feature", targetBranch: "main",
            isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try orchestrator.upsertComputeHost(host)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: project.processes)
        try store.setWorkspaceSetupState(workspaceID: workspace.id, status: .pending, errorMessage: nil, startedAt: nil, finishedAt: nil)

        try orchestrator.upWorkspace(workspaceID: workspace.id)

        let requests = recorder.requests()
        XCTAssertEqual(requests.map(\.command), ["runWorkspaceCommand", "create"])
        let setupRequest = try XCTUnwrap(requests.first)
        XCTAssertEqual(setupRequest.runtimeManifest?.location, .remote)
        XCTAssertEqual(setupRequest.runtimeManifest?.workspaceID, workspace.id)
        XCTAssertEqual(setupRequest.workspaceCommand?.workingDirectory, setupRequest.runtimeManifest?.remotePath)
        XCTAssertEqual(setupRequest.workspaceCommand?.environment["SPACES_WORKSPACE_DIR"], setupRequest.runtimeManifest?.remotePath)
        XCTAssertEqual(setupRequest.worktreeRefresh?.branch, "feature")

        let createRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(createRequest.launchConfiguration?.workingDirectory, createRequest.runtimeManifest?.remotePath)
        XCTAssertEqual(createRequest.launchConfiguration?.shell, "/bin/bash")
        XCTAssertEqual(createRequest.launchConfiguration?.kind, .process)
        XCTAssertEqual(createRequest.worktreeRefresh?.path, createRequest.runtimeManifest?.remotePath)
        let openedWindow = try XCTUnwrap(openedWindows.opened().first)
        XCTAssertEqual(openedWindows.opened().count, 1)
        XCTAssertEqual(openedWindow.sessionID, createRequest.launchConfiguration?.sessionID)
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
        XCTAssertEqual(runningProcess.terminalTrackingID, createRequest.launchConfiguration?.sessionID)
        XCTAssertEqual(runningProcess.logPath, "/tmp/\(createRequest.launchConfiguration?.sessionID ?? "missing").log")
        XCTAssertNotNil(try store.workspaceComputeBinding(workspaceID: workspace.id, hostID: host.id))

        _ = try orchestrator.stopWorkspace(workspaceID: workspace.id)

        let stopRequests = recorder.requests()
        XCTAssertEqual(stopRequests.map(\.command), ["runWorkspaceCommand", "create", "terminate"])
        XCTAssertEqual(stopRequests.last?.sessionID, createRequest.launchConfiguration?.sessionID)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
    }

    func testRunWorkspaceSetupRunsRemoteCommandThroughSpacesd() throws {
        let store = try makeTemporaryStore()
        let recorder = RemoteTerminalServiceRecorder()
        let orchestrator = WorkspaceOrchestrator(store: store, remoteTerminalServiceClient: recorder.client)
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")
        let projectDir = try makeTempDirectory()
        let setupMarker = projectDir.appendingPathComponent("setup.marker")
        let project = ProjectRecord(
            id: "project-a", name: "Project", dir: projectDir.path, isGitRepo: true, defaultBranch: "main",
            setupScript: "printf setup > setup.marker", defaultComputeHostID: host.id)
        let workspace = WorkspaceRecord(
            id: "workspace-a", projectID: project.id, title: "dev", dir: projectDir.path, dirname: nil, branch: "feature", targetBranch: "main",
            isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try orchestrator.upsertComputeHost(host)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        try orchestrator.runWorkspaceSetup(workspaceID: workspace.id)

        let request = try XCTUnwrap(recorder.requests().first)
        XCTAssertEqual(request.command, "runWorkspaceCommand")
        XCTAssertEqual(request.runtimeManifest?.location, .remote)
        XCTAssertEqual(request.workspaceCommand?.workingDirectory, request.runtimeManifest?.remotePath)
        XCTAssertEqual(request.workspaceCommand?.environment["SPACES_COMPUTE_HOST_ID"], host.id)
        XCTAssertEqual(request.worktreeRefresh?.branch, "feature")

        XCTAssertFalse(FileManager.default.fileExists(atPath: setupMarker.path))
        let setupState = try XCTUnwrap(try store.workspaceSetupState(workspaceID: workspace.id))
        XCTAssertEqual(setupState.status, .succeeded)
        XCTAssertEqual(setupState.exitCode, 0)
        XCTAssertEqual(setupState.logPath, "/tmp/workspace-command.log")
    }

    func testOpenWorkspaceTerminalRunsRemoteShellThroughSpacesd() throws {
        let store = try makeTemporaryStore()
        let recorder = RemoteTerminalServiceRecorder()
        let openedWindows = BuiltInTerminalWindowOpenRecorder()
        let orchestrator = WorkspaceOrchestrator(
            store: store, builtInTerminalWindowOpener: openedWindows.open, remoteTerminalServiceClient: recorder.client)
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")
        let projectDir = try makeTempDirectory()
        let project = ProjectRecord(
            id: "project-a", name: "Project", dir: projectDir.path, isGitRepo: true, defaultBranch: "main", defaultComputeHostID: host.id)
        let workspace = WorkspaceRecord(
            id: "workspace-a", projectID: project.id, title: "dev", dir: projectDir.path, dirname: nil, branch: "feature", targetBranch: "main",
            isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try orchestrator.upsertComputeHost(host)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)

        let sessionID = try orchestrator.openWorkspaceTerminal(workspaceID: workspace.id)

        let request = try XCTUnwrap(recorder.requests().first)
        XCTAssertEqual(request.command, "create")
        XCTAssertEqual(request.launchConfiguration?.sessionID, sessionID)
        XCTAssertEqual(request.launchConfiguration?.kind, .shell)
        XCTAssertEqual(request.launchConfiguration?.workingDirectory, request.runtimeManifest?.remotePath)
        XCTAssertEqual(request.launchConfiguration?.shell, "/bin/bash")
        XCTAssertEqual(request.worktreeRefresh?.branch, "feature")
        XCTAssertTrue(openedWindows.opened().isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
        XCTAssertEqual(try store.windows(workspaceID: workspace.id).first?.terminalTrackingID, sessionID)
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

    func testWorkspaceHostOverrideChangeBlocksWithPreservedSpacesSession() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")
        let project = makeProjectRecord(id: "project-a", dir: try makeTempDirectory().path)
        let workspace = makeWorkspaceRecord(id: "workspace-a", projectID: project.id, title: "Feature", dir: try makeTempDirectory().path)
        try orchestrator.upsertComputeHost(host)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try insertPreservedProcessSession(store: store, workspaceID: workspace.id)

        XCTAssertThrowsError(try orchestrator.setWorkspaceComputeHostOverride(workspaceID: workspace.id, hostID: host.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("live or preserved Spaces terminal sessions"))
        }
        XCTAssertNil(try store.workspace(id: workspace.id)?.computeHostOverrideID)
    }

    func testProjectDefaultHostChangeBlocksInheritingWorkspaceWithPreservedSpacesSession() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let hostA = makeComputeHostRecord(id: "host-a", name: "Builder A")
        let hostB = makeComputeHostRecord(id: "host-b", name: "Builder B")
        let project = ProjectRecord(
            id: "project-a", name: "Project", dir: try makeTempDirectory().path, isGitRepo: true, defaultBranch: "main",
            defaultComputeHostID: hostA.id)
        let workspace = makeWorkspaceRecord(id: "workspace-a", projectID: project.id, title: "Feature", dir: try makeTempDirectory().path)
        try orchestrator.upsertComputeHost(hostA)
        try orchestrator.upsertComputeHost(hostB)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try insertPreservedProcessSession(store: store, workspaceID: workspace.id)

        XCTAssertThrowsError(try orchestrator.setProjectDefaultComputeHost(projectID: project.id, hostID: hostB.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("live or preserved Spaces terminal sessions"))
        }
        XCTAssertEqual(try store.project(id: project.id)?.defaultComputeHostID, hostA.id)
    }

    func testDeleteComputeHostBlocksWhenResolvedWorkspaceHasPreservedSpacesSession() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let host = makeComputeHostRecord(id: "host-a", name: "Builder A")
        let project = ProjectRecord(
            id: "project-a", name: "Project", dir: try makeTempDirectory().path, isGitRepo: true, defaultBranch: "main", defaultComputeHostID: host.id
        )
        let workspace = makeWorkspaceRecord(id: "workspace-a", projectID: project.id, title: "Feature", dir: try makeTempDirectory().path)
        try orchestrator.upsertComputeHost(host)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try insertPreservedProcessSession(store: store, workspaceID: workspace.id)

        XCTAssertThrowsError(try orchestrator.deleteComputeHost(id: host.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("live or preserved Spaces terminal sessions"))
        }
        XCTAssertEqual(try store.computeHost(id: host.id), host)
        XCTAssertEqual(try store.project(id: project.id)?.defaultComputeHostID, host.id)
    }

    func testDeleteComputeHostClearsSelectionsBindingsAndReportsCleanup() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let host = makeComputeHostRecord(id: "test-host-\(UUID().uuidString)", name: "Builder A")
        let project = ProjectRecord(
            id: "project-a", name: "Project", dir: try makeTempDirectory().path, isGitRepo: true, defaultBranch: "main", defaultComputeHostID: host.id
        )
        let workspace = WorkspaceRecord(
            id: "workspace-a", projectID: project.id, title: "Feature", dir: try makeTempDirectory().path, dirname: nil, branch: "feature",
            isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil, computeHostOverrideID: host.id)
        let binding = WorkspaceComputeBinding(
            workspaceID: workspace.id, hostID: host.id, remotePath: "/srv/spaces/project/feature", branch: "feature",
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
        try orchestrator.upsertComputeHost(host)
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.upsert(workspaceComputeBinding: binding)

        let result = try orchestrator.deleteComputeHost(id: host.id)

        XCTAssertEqual(result.hostID, host.id)
        XCTAssertEqual(result.clearedProjectDefaultIDs, [project.id])
        XCTAssertEqual(result.clearedWorkspaceOverrideIDs, [workspace.id])
        XCTAssertEqual(result.clearedWorkspaceBindingIDs, [binding.id])
        XCTAssertFalse(result.credentialTokenDeleted)
        XCTAssertNil(try store.computeHost(id: host.id))
        XCTAssertNil(try store.project(id: project.id)?.defaultComputeHostID)
        XCTAssertNil(try store.workspace(id: workspace.id)?.computeHostOverrideID)
        XCTAssertNil(try store.workspaceComputeBinding(workspaceID: workspace.id, hostID: host.id))
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
        let plan = makeRuntimePlan(selection: .localMac, ports: [WorkspaceRuntimePortMapping(id: "web", name: "WEB_PORT", port: 3000)])

        let mapped = try BrowserSSHForwardResolver.resolvedURL("http://localhost:3000/status", runtimePlan: plan) { _ in
            XCTFail("Local runtime URLs should not open SSH forwards.")
            return 49_231
        }

        XCTAssertEqual(mapped, "http://localhost:3000/status")
    }

    private func insertPreservedProcessSession(store: SQLiteStore, workspaceID: String, sessionID: String = "session-preserved") throws {
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-\(sessionID)", workspaceID: workspaceID, templateName: "Server", command: "npm run dev",
                terminalApp: TerminalHost.spaces.appName, windowID: nil, terminalTrackingID: sessionID, terminalNativeID: sessionID, pid: nil,
                status: .exited, logPath: nil, lastOutputAt: nil, startedAt: "2026-01-01T00:00:00Z", exitedAt: "2026-01-01T00:00:01Z"))
    }

    private func makeRuntimePlan(selection: ComputeHostSelection, ports: [WorkspaceRuntimePortMapping]) -> WorkspaceRuntimePlan {
        let project = ProjectRecord(id: "project", name: "Project", dir: "/local/project", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace", projectID: project.id, title: "Feature", dir: "/local/project/workspace", dirname: nil, branch: "feature",
            isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        let binding: WorkspaceComputeBinding?
        if case .remote(let host) = selection {
            binding = WorkspaceComputeBinding(
                workspaceID: workspace.id, hostID: host.id, remotePath: "/srv/spaces/project/feature", branch: "feature",
                createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
        } else {
            binding = nil
        }
        let manifest = ComputeHostPlanner.runtimeManifest(
            project: project, workspace: workspace, selection: selection, binding: binding, namedPorts: ports)
        return WorkspaceRuntimePlan(
            project: project, workspace: workspace, selection: selection, binding: binding, manifest: manifest,
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
