import XCTest

@testable import workspacecore

final class SpacesDeviceTests: XCTestCase {
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

    func testPlannerTargetsLocalDeviceDaemon() throws {
        let project = ProjectRecord(id: "project", name: "Project", dir: "/project", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace", projectID: project.id, title: "Feature", dir: "/project/.worktrees/feature",
            runtimePath: "/srv/spaces/project/feature", dirname: nil, branch: "feature", isDefault: false, isArchived: false, isRunning: false,
            lastLaunchedAt: nil)

        let selection = SpacesDevicePlanner.selectDevice(
            project: project, workspace: workspace, devicesByID: [SpacesDeviceRecord.localDeviceID: .local()])
        let daemonTarget = SpacesDevicePlanner.daemonTarget(selection: selection, localSocketPath: "/tmp/spacesd.sock")
        let manifest = SpacesDevicePlanner.runtimeManifest(
            project: project, workspace: workspace, selection: selection,
            namedPorts: [WorkspaceRuntimePortMapping(id: "web", name: "WEB_PORT", port: 3000)])

        XCTAssertEqual(selection, .local(SpacesDeviceRecord.local()))
        XCTAssertEqual(daemonTarget.deviceID, SpacesDeviceRecord.localDeviceID)
        XCTAssertEqual(daemonTarget.socketPath, "/tmp/spacesd.sock")
        XCTAssertEqual(manifest.deviceID, SpacesDeviceRecord.localDeviceID)
        XCTAssertEqual(manifest.localPath, workspace.runtimePath)
        XCTAssertEqual(manifest.processEnvironment["WEB_PORT"], "3000")
    }
}
