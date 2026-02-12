import XCTest

@testable import streamctl

final class OrchestratorTests: XCTestCase {
    func testUpdateEditorPreferencePersistsToConfig() throws {
        let dir = try makeTempDirectory()
        let path = dir.appendingPathComponent("config.yaml").path
        let configStore = ConfigStore(path: path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(store: store, configStore: configStore)

        _ = try orchestrator.updateEditorPreference(.cursor)
        let reloaded = try configStore.load()
        XCTAssertEqual(reloaded.editor, .cursor)

        _ = try orchestrator.updateEditorPreference(nil)
        let cleared = try configStore.load()
        XCTAssertNil(cleared.editor)
    }

    func testNextWindowOrderIndexUsesRoleOffsetAndMax() {
        let windows = [
            WindowRecord(
                id: UUID().uuidString,
                workspaceID: "ws",
                app: "Chrome",
                title: "Browser",
                windowID: 10,
                role: "browser",
                orderIndex: 0,
                lastSeenAt: "now"
            ),
            WindowRecord(
                id: UUID().uuidString,
                workspaceID: "ws",
                app: "iTerm2",
                title: "Term 1",
                windowID: 11,
                role: "terminal",
                orderIndex: 200,
                lastSeenAt: "now"
            ),
            WindowRecord(
                id: UUID().uuidString,
                workspaceID: "ws",
                app: "iTerm2",
                title: "Term 2",
                windowID: 12,
                role: "terminal",
                orderIndex: 205,
                lastSeenAt: "now"
            ),
        ]

        let nextTerminal = AgentmuxOrchestrator.nextWindowOrderIndex(
            existing: windows,
            role: "terminal",
            orderOffset: 200
        )
        XCTAssertEqual(nextTerminal, 206)

        let nextEditor = AgentmuxOrchestrator.nextWindowOrderIndex(
            existing: windows,
            role: "editor",
            orderOffset: 100
        )
        XCTAssertEqual(nextEditor, 100)
    }

    func testAddProjectByCloningUsesProjectsRootAndRepoName() throws {
        let fixture = try makeTempGitRepo(name: "sample-repo")
        let root = try makeTempDirectory()
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(
            store: store,
            configStore: configStore,
            projectsRootDirectory: projectsRoot
        )

        let project = try orchestrator.addProject(gitURL: fixture.path)

        let expected = projectsRoot.appendingPathComponent("sample-repo", isDirectory: true).path
        XCTAssertEqual(project.dir, expected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(expected)/README.md"))
    }

    func testAddProjectByCloningStripsGitSuffixFromRepoName() throws {
        let fixture = try makeTempGitRepo(name: "source.git")
        let root = try makeTempDirectory()
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(
            store: store,
            configStore: configStore,
            projectsRootDirectory: projectsRoot
        )

        let project = try orchestrator.addProject(gitURL: fixture.path)

        let expected = projectsRoot.appendingPathComponent("source", isDirectory: true).path
        XCTAssertEqual(project.dir, expected)
        XCTAssertEqual(project.name, "source")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(expected)/README.md"))
    }

    func testRemoveProjectDeletesManagedGitProjectDirectory() throws {
        let fixture = try makeTempGitRepo(name: "managed")
        let root = try makeTempDirectory()
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(
            store: store,
            configStore: configStore,
            projectsRootDirectory: projectsRoot
        )

        let project = try orchestrator.addProject(gitURL: fixture.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.dir))

        try orchestrator.removeProject(dir: project.dir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: project.dir))
        XCTAssertNil(try store.project(dir: project.dir))
        XCTAssertTrue(try orchestrator.listProjects().isEmpty)
    }

    func testRemoveProjectDeletesManagedWorkspaceDirectoriesForManagedGitProject() throws {
        let fixture = try makeTempGitRepo(name: "managed-with-workspace")
        let root = try makeTempDirectory()
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(
            store: store,
            configStore: configStore,
            projectsRootDirectory: projectsRoot,
            workspacesRootDirectory: workspacesRoot
        )

        let project = try orchestrator.addProject(gitURL: fixture.path)
        let projectWorkspaceRoot = workspacesRoot.appendingPathComponent(project.name, isDirectory: true)
        let workspaceDir = projectWorkspaceRoot.appendingPathComponent("feature", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceDir.path))
        XCTAssertTrue(workspaceDir.path.hasPrefix(workspacesRoot.path))

        try orchestrator.removeProject(dir: project.dir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectWorkspaceRoot.path))
    }

    func testRemoveProjectDoesNotDeleteUnmanagedProjectDirectoryButDeletesManagedWorkspaceDirectories() throws {
        let projectDir = try makeTempDirectory()
        try runGit(["init"], cwd: projectDir.path)
        try "hello".write(to: projectDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], cwd: projectDir.path)
        try runGit(
            ["-c", "user.name=agentmux-test", "-c", "user.email=test@example.com", "commit", "-m", "init"],
            cwd: projectDir.path
        )

        let root = try makeTempDirectory()
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(
            store: store,
            configStore: configStore,
            projectsRootDirectory: projectsRoot,
            workspacesRootDirectory: workspacesRoot
        )

        let project = try orchestrator.addProject(dir: projectDir.path)
        let projectWorkspaceRoot = workspacesRoot.appendingPathComponent(project.name, isDirectory: true)
        let workspaceDir = projectWorkspaceRoot.appendingPathComponent("feature", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceDir.path))
        XCTAssertTrue(workspaceDir.path.hasPrefix(workspacesRoot.path))

        try orchestrator.removeProject(dir: project.dir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: project.dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectWorkspaceRoot.path))
    }

    func testArchiveWorkspaceDoesNotDeleteProjectDirectoryForNonGitProject() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let marker = projectDir.appendingPathComponent("marker.txt")
        try "marker".write(to: marker, atomically: true, encoding: .utf8)

        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = AgentmuxOrchestrator(store: store, configStore: configStore)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        try orchestrator.archiveWorkspace(workspaceID: workspace.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: project.dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let archivedWorkspace = try store.workspace(id: workspace.id)
        XCTAssertEqual(archivedWorkspace?.isArchived, true)
    }

    private func makeTempGitRepo(name: String) throws -> URL {
        let root = try makeTempDirectory()
        let repo = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init"], cwd: repo.path)
        try "hello".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], cwd: repo.path)
        try runGit(
            ["-c", "user.name=agentmux-test", "-c", "user.email=test@example.com", "commit", "-m", "init"],
            cwd: repo.path
        )
        return repo
    }

    private func runGit(_ arguments: [String], cwd: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "agentmux.tests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(message)"]
            )
        }
    }
}
