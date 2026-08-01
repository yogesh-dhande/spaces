import XCTest

@testable import workspacecore

final class WorkspaceDisplayNameTests: XCTestCase {
    // Tests a git workspace shows its branch as the display name.
    func testGitWorkspaceDisplayNameIsBranch() {
        let record = WorkspaceRecord(
            id: "ws", projectID: "p", dir: "/repos/app/almond", dirname: "almond", branch: "feature/login", isDefault: false,
            isRunning: false, lastLaunchedAt: nil)
        XCTAssertEqual(record.displayName, "feature/login")
    }

    // Tests a non-git workspace shows its folder name as the display name.
    func testNonGitWorkspaceDisplayNameIsFolderName() {
        let record = WorkspaceRecord(
            id: "ws", projectID: "p", dir: "/Users/me/notes", dirname: nil, branch: nil, isDefault: true, isRunning: false,
            lastLaunchedAt: nil)
        XCTAssertEqual(record.displayName, "notes")
    }

    // Tests an empty branch falls back to the folder name.
    func testEmptyBranchFallsBackToFolderName() {
        let summary = WorkspaceSummary(id: "ws", branch: "", dir: "/Users/me/scratch", isRunning: false, isDefault: false)
        XCTAssertEqual(summary.displayName, "scratch")
    }
}
