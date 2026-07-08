import XCTest

@testable import workspacecore

final class SpacesDeviceTests: XCTestCase {
    func testWorkspaceRoundTripStoresDeviceOwnedRuntimePathWithoutDeviceColumn() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(id: "project-12345678", dir: try makeTempDirectory().path)
        let workspace = WorkspaceRecord(
            id: "workspace-12345678", projectID: project.id, dir: try makeTempDirectory().path,
            dirname: "feature-a", branch: "feature/a", isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(project: project)

        try store.upsert(workspace: workspace)

        let storedWorkspace = try XCTUnwrap(try store.workspace(id: workspace.id))
        XCTAssertEqual(storedWorkspace.dir, workspace.dir)
        XCTAssertEqual(storedWorkspace.branch, workspace.branch)
    }

    func testSameProjectBranchCannotExistTwiceOnDevice() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(id: "project-12345678", dir: try makeTempDirectory().path)
        let first = WorkspaceRecord(
            id: "workspace-one", projectID: project.id, dir: try makeTempDirectory().path, dirname: "one", branch: "feature/shared", isDefault: false,
            isArchived: false, isRunning: false, lastLaunchedAt: nil)
        let second = WorkspaceRecord(
            id: "workspace-two", projectID: project.id, dir: try makeTempDirectory().path, dirname: "two", branch: "feature/shared", isDefault: false,
            isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(project: project)
        try store.upsert(workspace: first)

        XCTAssertThrowsError(try store.upsert(workspace: second))
    }

    func testArchivedBranchCanCoexistWithActiveWorkspaceOnDevice() throws {
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(id: "project-12345678", dir: try makeTempDirectory().path)
        let archived = WorkspaceRecord(
            id: "workspace-archived", projectID: project.id, dir: try makeTempDirectory().path, dirname: "archived", branch: "feature/shared",
            isDefault: false, isArchived: true, isRunning: false, lastLaunchedAt: nil)
        let active = WorkspaceRecord(
            id: "workspace-active", projectID: project.id, dir: try makeTempDirectory().path, dirname: "active", branch: "feature/shared",
            isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(project: project)

        try store.upsert(workspace: archived)
        try store.upsert(workspace: active)

        XCTAssertEqual(Set(try store.workspaces(projectID: project.id, includeArchived: true).map(\.id)), ["workspace-active", "workspace-archived"])
    }

    func testPlannerBuildsRuntimeManifest() throws {
        let project = ProjectRecord(id: "project", name: "Project", dir: "/project", isGitRepo: true, defaultBranch: "main")
        let workspace = WorkspaceRecord(
            id: "workspace", projectID: project.id, dir: "/project/.worktrees/feature", dirname: nil,
            branch: "feature", isDefault: false, isArchived: false, isRunning: false, lastLaunchedAt: nil)

        let manifest = SpacesDevicePlanner.runtimeManifest(
            project: project, workspace: workspace, namedPorts: [WorkspaceRuntimePortMapping(id: "web", name: "web", port: 3000)])

        XCTAssertEqual(manifest.localPath, workspace.dir)
        XCTAssertEqual(manifest.processEnvironment["SPACES_WEB_PORT"], "3000")
        let slug = try XCTUnwrap(manifest.processEnvironment["SPACES_WORKSPACE_SLUG"])
        XCTAssertEqual(manifest.processEnvironment["SPACES_WEB_HOST"], "web.\(slug).localhost")
    }
}
