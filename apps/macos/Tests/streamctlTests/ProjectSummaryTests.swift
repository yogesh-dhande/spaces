import XCTest

@testable import streamctl

final class ProjectSummaryTests: XCTestCase {
    // Tests init stores fields by arranging representative inputs and asserting the expected result.
    func testInitStoresFields() {
        let summary = ProjectSummary(id: "project-1", name: "Project", dir: "/tmp/project", isGitRepo: true, defaultBranch: "main")

        XCTAssertEqual(summary.id, "project-1")
        XCTAssertEqual(summary.name, "Project")
        XCTAssertEqual(summary.dir, "/tmp/project")
        XCTAssertEqual(summary.isGitRepo, true)
        XCTAssertEqual(summary.defaultBranch, "main")
    }
}
