import XCTest

@testable import streamctl

final class ErrorsTests: XCTestCase {
    func testErrorDescriptionsCoverAllCases() {
        XCTAssertEqual(SpaceshipError.missingProject(dir: "/tmp/project").errorDescription, "Project not found: /tmp/project")
        XCTAssertEqual(SpaceshipError.projectAlreadyExists(dir: "/tmp/project").errorDescription, "Project already exists: /tmp/project")
        XCTAssertEqual(
            SpaceshipError.missingWorkspace(project: "App", workspace: "feature").errorDescription, "Workspace not found for project App: feature")
        XCTAssertEqual(
            SpaceshipError.workspaceAlreadyExists(project: "App", workspace: "feature").errorDescription,
            "Workspace already exists for project App: feature")
        XCTAssertEqual(SpaceshipError.invalidWorkspace(path: "/tmp/workspace").errorDescription, "Workspace path does not exist: /tmp/workspace")
        XCTAssertEqual(SpaceshipError.gitCommandFailed(message: "fatal").errorDescription, "Git command failed: fatal")
        XCTAssertEqual(SpaceshipError.invalidArgument(message: "bad").errorDescription, "Invalid argument: bad")
        XCTAssertEqual(SpaceshipError.yabaiUnavailable(message: "missing").errorDescription, "yabai not available: missing")
        XCTAssertEqual(SpaceshipError.dependencyMissing(message: "iTerm2").errorDescription, "Missing dependency: iTerm2")
        XCTAssertEqual(SpaceshipError.configError(message: "invalid").errorDescription, "Configuration error: invalid")
    }
}
