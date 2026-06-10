import XCTest
import spacesterminalcore

@testable import workspacecore

final class ComputeHostTests: XCTestCase {
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
        let orchestrator = WorkspaceOrchestrator(store: store, remoteTerminalServiceClient: recorder.client)
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

        XCTAssertFalse(FileManager.default.fileExists(atPath: setupMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: processMarker.path))
        XCTAssertEqual(try store.workspaceSetupState(workspaceID: workspace.id)?.status, .succeeded)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
        let runningProcess = try XCTUnwrap(try store.runningProcesses(workspaceID: workspace.id).first)
        XCTAssertEqual(runningProcess.runtimeTargetID, host.id)
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
        let orchestrator = WorkspaceOrchestrator(store: store, remoteTerminalServiceClient: recorder.client)
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
            return TerminalServiceResponse(
                ok: true, message: "created",
                session: TerminalServiceSessionSummary(
                    id: launchConfiguration.sessionID, title: launchConfiguration.title, workingDirectory: launchConfiguration.workingDirectory,
                    backend: launchConfiguration.backend, lifetimePolicy: launchConfiguration.lifetimePolicy, state: .running, servicePID: 42,
                    childPID: 4242, controlSocketPath: "/tmp/\(launchConfiguration.sessionID).sock",
                    outputPath: "/tmp/\(launchConfiguration.sessionID).log"))
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
