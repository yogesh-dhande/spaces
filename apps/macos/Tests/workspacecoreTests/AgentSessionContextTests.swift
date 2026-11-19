import Foundation
import XCTest
import spacesterminalcore

@testable import workspacecore

/// Where a conversation found in an agent's store resumes, decided from the device's projects.
final class AgentSessionContextTests: XCTestCase {
    private func context(_ orchestrator: WorkspaceOrchestrator, agent: CodingAgent = .codex, directory: String?) throws -> AgentSessionContext {
        try XCTUnwrap(
            try orchestrator.agentSessionContexts(for: [AgentSessionReference(agent: agent, sessionKey: "session-1", workingDirectory: directory)])
                .first)
    }

    func testAFolderUnderAProjectsWorktreeRootMapsToItsDefaultWorkspaceEvenWhenTheWorktreeIsGone() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let projectDir = try makeTempDirectory().appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let defaultWorkspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first(where: \.isDefault))
        let deletedWorktree = try orchestrator.worktreeRoot(project: project).appendingPathComponent("deleted-branch").path

        let mapped = try context(orchestrator, directory: deletedWorktree)

        XCTAssertEqual(mapped.destination.workspaceID, defaultWorkspace.id)
        XCTAssertEqual(mapped.destination.projectName, project.name)
        XCTAssertTrue(mapped.folderIsMissing)
    }

    func testAFolderInNoProjectMapsToTheHomeWorkspaceAndAnUnknownFolderDoes() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let home = try makeTempDirectory().appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let homeProject = try XCTUnwrap(orchestrator.ensureHomeProject(homeDirectory: home.path))
        let homeWorkspace = try XCTUnwrap(try store.workspaces(projectID: homeProject.id).first)
        let elsewhere = try makeTempDirectory()

        XCTAssertEqual(try context(orchestrator, directory: elsewhere.path).destination.workspaceID, homeWorkspace.id)
        let unknown = try context(orchestrator, directory: nil)
        XCTAssertEqual(unknown.destination.workspaceID, homeWorkspace.id)
        XCTAssertFalse(unknown.folderIsMissing, "A conversation with no recorded folder is not one whose folder is gone.")
    }

    func testOnlyAgentsThatResumeFromTheirOriginalFolderCannotResumeWithoutIt() {
        XCTAssertEqual(CodingAgent.allCases.filter(\.resumesOnlyFromOriginalFolder), [.claudeCode, .opencode])
    }
}
