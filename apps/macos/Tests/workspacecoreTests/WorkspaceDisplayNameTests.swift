import XCTest

@testable import workspacecore

final class WorkspaceDisplayNameTests: XCTestCase {
    func testGitWorkspaceDisplayNameIsBranch() {
        let record = WorkspaceRecord(
            id: "ws", projectID: "p", dir: "/repos/app/almond", dirname: "almond", branch: "feature/login", isDefault: false, isRunning: false,
            lastLaunchedAt: nil)
        XCTAssertEqual(record.displayName, "feature/login")
    }

    func testNonGitWorkspaceDisplayNameIsFolderName() {
        let record = WorkspaceRecord(
            id: "ws", projectID: "p", dir: "/Users/me/notes", dirname: nil, branch: nil, isDefault: true, isRunning: false, lastLaunchedAt: nil)
        XCTAssertEqual(record.displayName, "notes")
    }

    func testEmptyBranchFallsBackToFolderName() {
        let summary = WorkspaceSummary(id: "ws", branch: "", dir: "/Users/me/scratch", isRunning: false, isDefault: false)
        XCTAssertEqual(summary.displayName, "scratch")
    }
}
