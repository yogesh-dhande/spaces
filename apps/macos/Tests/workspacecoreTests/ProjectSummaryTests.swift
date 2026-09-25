import XCTest

@testable import workspacecore

final class ProjectSummaryTests: XCTestCase {
    func testInitStoresFields() {
        let summary = ProjectSummary(id: "project-1", name: "Project", dir: "/tmp/project", isGitRepo: true, defaultBranch: "main", isCollapsed: true)

        XCTAssertEqual(summary.id, "project-1")
        XCTAssertEqual(summary.name, "Project")
        XCTAssertEqual(summary.dir, "/tmp/project")
        XCTAssertEqual(summary.isGitRepo, true)
        XCTAssertEqual(summary.defaultBranch, "main")
        XCTAssertEqual(summary.isCollapsed, true)
    }
}
