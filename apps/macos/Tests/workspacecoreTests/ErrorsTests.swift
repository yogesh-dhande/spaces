import XCTest

@testable import workspacecore

final class ErrorsTests: XCTestCase {
    // Tests error descriptions cover all cases by arranging representative inputs and asserting the expected result.
    func testErrorDescriptionsCoverAllCases() {
        XCTAssertEqual(WorkspaceError.missingProject(dir: "/tmp/project").errorDescription, "Project not found: /tmp/project")
        XCTAssertEqual(WorkspaceError.projectAlreadyExists(dir: "/tmp/project").errorDescription, "Project already exists: /tmp/project")
        XCTAssertEqual(
            WorkspaceError.missingWorkspace(project: "App", workspace: "feature").errorDescription, "Workspace not found for project App: feature")
        XCTAssertEqual(
            WorkspaceError.workspaceAlreadyExists(project: "App", workspace: "feature").errorDescription,
            "Workspace already exists for project App: feature")
        XCTAssertEqual(WorkspaceError.invalidWorkspace(path: "/tmp/workspace").errorDescription, "Workspace path does not exist: /tmp/workspace")
        XCTAssertEqual(WorkspaceError.gitCommandFailed(message: "fatal").errorDescription, "Git command failed: fatal")
        XCTAssertEqual(WorkspaceError.invalidArgument(message: "bad").errorDescription, "Invalid argument: bad")
        XCTAssertEqual(WorkspaceError.dependencyMissing(message: "Spaces").errorDescription, "Missing dependency: Spaces")
        XCTAssertEqual(WorkspaceError.configError(message: "invalid").errorDescription, "Configuration error: invalid")
    }
}
