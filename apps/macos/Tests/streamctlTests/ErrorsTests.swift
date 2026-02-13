import XCTest

@testable import streamctl

final class ErrorsTests: XCTestCase {
    func testErrorDescriptionsCoverAllCases() {
        XCTAssertEqual(
            AgentmuxError.missingProject(dir: "/tmp/project").errorDescription,
            "Project not found: /tmp/project"
        )
        XCTAssertEqual(
            AgentmuxError.projectAlreadyExists(dir: "/tmp/project").errorDescription,
            "Project already exists: /tmp/project"
        )
        XCTAssertEqual(
            AgentmuxError.missingWorkspace(project: "App", workspace: "feature").errorDescription,
            "Workspace not found for project App: feature"
        )
        XCTAssertEqual(
            AgentmuxError.workspaceAlreadyExists(project: "App", workspace: "feature").errorDescription,
            "Workspace already exists for project App: feature"
        )
        XCTAssertEqual(
            AgentmuxError.invalidWorkspace(path: "/tmp/workspace").errorDescription,
            "Workspace path does not exist: /tmp/workspace"
        )
        XCTAssertEqual(
            AgentmuxError.gitCommandFailed(message: "fatal").errorDescription,
            "Git command failed: fatal"
        )
        XCTAssertEqual(
            AgentmuxError.invalidArgument(message: "bad").errorDescription,
            "Invalid argument: bad"
        )
        XCTAssertEqual(
            AgentmuxError.yabaiUnavailable(message: "missing").errorDescription,
            "yabai not available: missing"
        )
        XCTAssertEqual(
            AgentmuxError.dependencyMissing(message: "iTerm2").errorDescription,
            "Missing dependency: iTerm2"
        )
        XCTAssertEqual(
            AgentmuxError.configError(message: "invalid").errorDescription,
            "Configuration error: invalid"
        )
    }
}
