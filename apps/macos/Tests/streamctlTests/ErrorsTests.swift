import XCTest

@testable import streamctl

final class ErrorsTests: XCTestCase {
    // Tests error descriptions cover all cases by arranging representative inputs and asserting the expected result.
    func testErrorDescriptionsCoverAllCases() {
        XCTAssertEqual(MuxyError.missingProject(dir: "/tmp/project").errorDescription, "Project not found: /tmp/project")
        XCTAssertEqual(MuxyError.projectAlreadyExists(dir: "/tmp/project").errorDescription, "Project already exists: /tmp/project")
        XCTAssertEqual(
            MuxyError.missingWorkspace(project: "App", workspace: "feature").errorDescription, "Workspace not found for project App: feature")
        XCTAssertEqual(
            MuxyError.workspaceAlreadyExists(project: "App", workspace: "feature").errorDescription,
            "Workspace already exists for project App: feature")
        XCTAssertEqual(MuxyError.invalidWorkspace(path: "/tmp/workspace").errorDescription, "Workspace path does not exist: /tmp/workspace")
        XCTAssertEqual(MuxyError.gitCommandFailed(message: "fatal").errorDescription, "Git command failed: fatal")
        XCTAssertEqual(MuxyError.invalidArgument(message: "bad").errorDescription, "Invalid argument: bad")
        XCTAssertEqual(MuxyError.yabaiUnavailable(message: "missing").errorDescription, "yabai not available: missing")
        XCTAssertEqual(MuxyError.dependencyMissing(message: "iTerm2").errorDescription, "Missing dependency: iTerm2")
        XCTAssertEqual(MuxyError.configError(message: "invalid").errorDescription, "Configuration error: invalid")
    }
}
