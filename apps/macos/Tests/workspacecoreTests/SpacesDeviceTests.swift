import XCTest

@testable import workspacecore

final class SpacesDeviceTests: XCTestCase {
    func testFreshStoreReportsOnlyLocalDeviceHost() throws {
        let store = try makeTemporaryStore()

        let localDevice = try XCTUnwrap(try store.spacesDevice(id: SpacesDeviceRecord.localDeviceID))

        XCTAssertEqual(localDevice, SpacesDeviceRecord.local())
        XCTAssertEqual(try store.spacesDevices(), [localDevice])
        XCTAssertNil(try store.spacesDevice(id: "builder-a"))
    }

    func testStoreRejectsRemoteSpacesDeviceRecords() throws {
        let store = try makeTemporaryStore()

        XCTAssertThrowsError(try store.upsert(spacesDevice: makeSpacesDeviceRecord(id: "builder-a", name: "Builder A"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("Remote device records are not stored"))
        }
    }

    func testWorkspaceRoundTripStoresDeviceOwnedRuntimePathWithoutDeviceColumn() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(id: "project-12345678", dir: try makeTempDirectory().path)
        let workspace = WorkspaceRecord(
            id: "workspace-12345678", projectID: project.id, title: "Feature A", dir: try makeTempDirectory().path,
            runtimePath: "/tmp/spaces/project/feature-a", dirname: "feature-a", branch: "feature/a", isDefault: false, isArchived: false,
            isRunning: false, lastLaunchedAt: nil)
        try store.upsert(project: project)

        try store.upsert(workspace: workspace)

        let storedWorkspace = try XCTUnwrap(try store.workspace(id: workspace.id))
        XCTAssertEqual(storedWorkspace.deviceID, SpacesDeviceRecord.localDeviceID)
        XCTAssertEqual(storedWorkspace.runtimePath, workspace.runtimePath)
        XCTAssertEqual(storedWorkspace.branch, workspace.branch)
    }

    func testSameProjectBranchCannotExistTwiceOnDevice() throws {
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

    func testArchivedBranchCanCoexistWithActiveWorkspaceOnDevice() throws {
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

    func testPlannerAlwaysTargetsLocalDeviceDaemon() throws {
        let device = makeSpacesDeviceRecord(id: "builder-a", name: "Builder A")
        let project = ProjectRecord(id: "project", name: "Project", dir: "/project", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace", projectID: project.id, deviceID: device.id, title: "Feature", dir: "/project/.worktrees/feature",
            runtimePath: "/srv/spaces/project/feature", dirname: nil, branch: "feature", isDefault: false, isArchived: false, isRunning: false,
            lastLaunchedAt: nil)

        let selection = SpacesDevicePlanner.selectDevice(
            project: project, workspace: workspace, devicesByID: [SpacesDeviceRecord.localDeviceID: .local(), device.id: device])
        let daemonTarget = SpacesDevicePlanner.daemonTarget(selection: .remote(device), localSocketPath: "/tmp/spacesd.sock")
        let manifest = SpacesDevicePlanner.runtimeManifest(
            project: project, workspace: workspace, selection: .remote(device),
            namedPorts: [WorkspaceRuntimePortMapping(id: "web", name: "WEB_PORT", port: 3000)])

        XCTAssertEqual(selection, .local(SpacesDeviceRecord.local()))
        XCTAssertEqual(daemonTarget.transport, .localUnixSocket)
        XCTAssertEqual(daemonTarget.deviceID, SpacesDeviceRecord.localDeviceID)
        XCTAssertEqual(daemonTarget.socketPath, "/tmp/spacesd.sock")
        XCTAssertNil(daemonTarget.endpoint)
        XCTAssertEqual(manifest.location, .local)
        XCTAssertEqual(manifest.deviceID, SpacesDeviceRecord.localDeviceID)
        XCTAssertEqual(manifest.localPath, workspace.runtimePath)
        XCTAssertNil(manifest.remotePath)
        XCTAssertEqual(manifest.processEnvironment["WEB_PORT"], "3000")
    }

    func testOrchestratorRejectsRemoteSpacesDeviceStorageAndDeletion() throws {
        let orchestrator = WorkspaceOrchestrator(store: try makeTemporaryStore())
        let device = makeSpacesDeviceRecord(id: "builder-a", name: "Builder A")

        XCTAssertThrowsError(try orchestrator.upsertSpacesDevice(device)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Remote device records are not part"))
        }
        XCTAssertThrowsError(try orchestrator.validateSpacesDeviceDeletion(id: device.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Remote device records are not stored"))
        }
        XCTAssertThrowsError(try orchestrator.deleteSpacesDevice(id: SpacesDeviceRecord.localDeviceID)) { error in
            XCTAssertTrue(error.localizedDescription.contains("local device"))
        }
    }

    func testCreateWorkspaceOnDeviceRejectsRemoteDeviceID() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(id: "project", dir: try makeTempDirectory().path)
        try store.upsert(project: project)

        XCTAssertThrowsError(
            try orchestrator.createWorkspaceOnDevice(projectID: project.id, name: "Feature", branch: "feature/a", deviceID: "builder-a")
        ) { error in XCTAssertTrue(error.localizedDescription.contains("this device's daemon")) }
    }

    func testBrowserSSHForwardResolverMapsRemoteDeviceLocalServicePort() throws {
        let device = makeSpacesDeviceRecord(id: "device-a", name: "Studio Linux")
        let plan = makeRuntimePlan(selection: .remote(device), ports: [WorkspaceRuntimePortMapping(id: "web", name: "WEB_PORT", port: 3000)])
        let recorder = BrowserForwardRecorder(localPort: 49_231)

        let mapped = try BrowserSSHForwardResolver.resolvedURL("http://localhost:3000/status", runtimePlan: plan, forwarder: recorder.forward)

        XCTAssertEqual(mapped, "http://127.0.0.1:49231/status")
        XCTAssertEqual(recorder.requests.map(\.remotePort), [3000])
        XCTAssertEqual(recorder.requests.map(\.sshHost), [device.sshHost])
    }

    func testBrowserSSHForwardResolverLeavesLocalRuntimeURLsUnchanged() throws {
        let plan = makeRuntimePlan(
            selection: .local(SpacesDeviceRecord.local()), ports: [WorkspaceRuntimePortMapping(id: "web", name: "WEB_PORT", port: 3000)])

        let mapped = try BrowserSSHForwardResolver.resolvedURL("http://localhost:3000/status", runtimePlan: plan) { _ in
            XCTFail("Local runtime URLs should not open SSH forwards.")
            return 49_231
        }

        XCTAssertEqual(mapped, "http://localhost:3000/status")
    }

    private func makeRuntimePlan(selection: SpacesDeviceSelection, ports: [WorkspaceRuntimePortMapping]) -> WorkspaceRuntimePlan {
        let project = ProjectRecord(id: "project", name: "Project", dir: "/local/project", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace", projectID: project.id, title: "Feature", dir: "/local/project/workspace", runtimePath: "/local/project/workspace",
            dirname: nil, branch: "feature", isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        let manifest = SpacesDevicePlanner.runtimeManifest(project: project, workspace: workspace, selection: selection, namedPorts: ports)
        return WorkspaceRuntimePlan(
            project: project, workspace: workspace, selection: selection, manifest: manifest,
            daemonTarget: SpacesDevicePlanner.daemonTarget(selection: selection, localSocketPath: "/tmp/spacesd.sock"), remoteSSHURI: nil)
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
