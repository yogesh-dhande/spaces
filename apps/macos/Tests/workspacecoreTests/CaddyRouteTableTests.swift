import XCTest
import spacesterminalcore

@testable import workspacecore

final class CaddyRouteTableTests: XCTestCase {
    func testRouteTableHasRoutePerServiceWithDerivedHosts() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/projects/app")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: "/projects/app")
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [21001, 21002], names: ["web", "backend"])

        let routes = try orchestrator.caddyRouteTable()
        let slug = SpacesProfile.workspaceHostSlug(
            branch: workspace.branch, projectName: project.name, isGitRepo: project.isGitRepo, workspaceID: workspace.id)

        XCTAssertEqual(Set(routes.map(\.host)), ["web.\(slug).localhost", "backend.\(slug).localhost"])
        XCTAssertTrue(slug.hasPrefix("project-"))
        let webRoute = try XCTUnwrap(routes.first { $0.host == "web.\(slug).localhost" })
        XCTAssertEqual(webRoute.upstream, "localhost:21001")
        let backendRoute = try XCTUnwrap(routes.first { $0.host == "backend.\(slug).localhost" })
        XCTAssertEqual(backendRoute.upstream, "localhost:21002")
    }

    func testRouteTableIsEmptyWhenNoServicesAssigned() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/projects/app")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, dir: "/projects/app")
        try store.upsert(workspace: workspace)

        XCTAssertTrue(try orchestrator.caddyRouteTable().isEmpty)
    }

    func testRouteTableKeepsWorkspacesWithSameLongBranchPrefixDistinct() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let firstProject = makeProjectRecord(id: "project-one", dir: "/projects/app-one")
        let secondProject = makeProjectRecord(id: "project-two", dir: "/projects/app-two")
        try store.upsert(project: firstProject)
        try store.upsert(project: secondProject)
        let branch = String(repeating: "feature-", count: 12) + "workspace-router"
        let first = makeWorkspaceRecord(id: "workspace-one", projectID: firstProject.id, dir: "/projects/app-one/worktree", branch: branch)
        let second = makeWorkspaceRecord(id: "workspace-two", projectID: secondProject.id, dir: "/projects/app-two/worktree", branch: branch)
        try store.upsert(workspace: first)
        try store.upsert(workspace: second)
        try store.setWorkspacePorts(workspaceID: first.id, ports: [21001], names: ["web"])
        try store.setWorkspacePorts(workspaceID: second.id, ports: [21002], names: ["web"])

        let routes = try orchestrator.caddyRouteTable()
        let firstSlug = SpacesProfile.workspaceHostSlug(
            branch: first.branch, projectName: firstProject.name, isGitRepo: firstProject.isGitRepo, workspaceID: first.id)
        let secondSlug = SpacesProfile.workspaceHostSlug(
            branch: second.branch, projectName: secondProject.name, isGitRepo: secondProject.isGitRepo, workspaceID: second.id)

        XCTAssertNotEqual(firstSlug, secondSlug)
        XCTAssertEqual(Set(routes.map(\.host)), ["web.\(firstSlug).localhost", "web.\(secondSlug).localhost"])
        XCTAssertEqual(routes.count, 2)
    }
}
