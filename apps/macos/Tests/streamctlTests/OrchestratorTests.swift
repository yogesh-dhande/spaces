import XCTest

@testable import streamctl

final class OrchestratorTests: XCTestCase {
    func testUpdateEditorPreferencePersistsToConfig() throws {
        let dir = try makeTempDirectory()
        let path = dir.appendingPathComponent("config.yaml").path
        let configStore = ConfigStore(path: path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore)

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
                id: UUID().uuidString, workspaceID: "ws", app: "Chrome", title: "Browser", windowID: 10, role: "browser", orderIndex: 0,
                lastSeenAt: "now"),
            WindowRecord(
                id: UUID().uuidString, workspaceID: "ws", app: "iTerm2", title: "Term 1", windowID: 11, role: "terminal", orderIndex: 200,
                lastSeenAt: "now"),
            WindowRecord(
                id: UUID().uuidString, workspaceID: "ws", app: "iTerm2", title: "Term 2", windowID: 12, role: "terminal", orderIndex: 205,
                lastSeenAt: "now"),
        ]

        let nextTerminal = SpaceshipOrchestrator.nextWindowOrderIndex(existing: windows, role: "terminal", orderOffset: 200)
        XCTAssertEqual(nextTerminal, 206)

        let nextEditor = SpaceshipOrchestrator.nextWindowOrderIndex(existing: windows, role: "editor", orderOffset: 100)
        XCTAssertEqual(nextEditor, 100)
    }

    func testAddProjectByCloningUsesProjectsRootAndRepoName() throws {
        let fixture = try makeTempGitRepo(name: "sample-repo")
        let root = try makeTempDirectory()
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore, projectsRootDirectory: projectsRoot)

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
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore, projectsRootDirectory: projectsRoot)

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
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore, projectsRootDirectory: projectsRoot)

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
        let orchestrator = SpaceshipOrchestrator(
            store: store, configStore: configStore, projectsRootDirectory: projectsRoot, workspacesRootDirectory: workspacesRoot)

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
        try runGit(["-c", "user.name=spaceship-test", "-c", "user.email=test@example.com", "commit", "-m", "init"], cwd: projectDir.path)

        let root = try makeTempDirectory()
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(
            store: store, configStore: configStore, projectsRootDirectory: projectsRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature", branch: "feature")
        let projectWorkspaceRoot = workspacesRoot.appendingPathComponent(project.name, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.dir))
        XCTAssertTrue(workspace.dir.hasPrefix(workspacesRoot.path))

        let normalizedWorkspaceDir = normalizeTestPath(workspace.dir)
        let worktreesBefore = try runGitAndCapture(["worktree", "list", "--porcelain"], cwd: project.dir)
        XCTAssertTrue(parseWorktreePaths(worktreesBefore).contains(normalizedWorkspaceDir))

        try orchestrator.removeProject(dir: project.dir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: project.dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectWorkspaceRoot.path))
        let worktreesAfter = try runGitAndCapture(["worktree", "list", "--porcelain"], cwd: project.dir)
        XCTAssertFalse(parseWorktreePaths(worktreesAfter).contains(normalizedWorkspaceDir))
    }

    func testArchiveWorkspaceDoesNotDeleteProjectDirectoryForNonGitProject() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let marker = projectDir.appendingPathComponent("marker.txt")
        try "marker".write(to: marker, atomically: true, encoding: .utf8)

        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        try orchestrator.archiveWorkspace(workspaceID: workspace.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: project.dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let archivedWorkspace = try store.workspace(id: workspace.id)
        XCTAssertEqual(archivedWorkspace?.isArchived, true)
    }

    func testCreateWorkspaceForNonGitProjectAllocatesPorts() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        XCTAssertEqual(workspace.dir, projectDir.path)
        XCTAssertFalse(workspace.isArchived)
        XCTAssertEqual(try orchestrator.workspacePorts(workspaceID: workspace.id).count, 0)
    }

    func testCreateWorkspaceRejectsDirectoryNameOverrideForNonGitProject() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore)

        let project = try orchestrator.addProject(dir: projectDir.path)
        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id, name: "feature", directoryName: "feature_dir")) { error in
            XCTAssertTrue(error.localizedDescription.contains("only supported for git projects"))
        }
    }

    func testWorkspaceStopScriptIsSeededFromProjectAndCanBeOverridden() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore)

        let project = try orchestrator.addProject(dir: projectDir.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in config.stopScript = "echo project-stop" }

        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        XCTAssertEqual(try orchestrator.workspaceSettings(workspaceID: workspace.id)?.stopScript, "echo project-stop")

        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in settings.stopScript = "echo workspace-stop" }
        XCTAssertEqual(try orchestrator.workspaceSettings(workspaceID: workspace.id)?.stopScript, "echo workspace-stop")

        // Project-level changes do not overwrite workspace-level overrides.
        try orchestrator.updateProjectConfig(projectID: project.id) { config in config.stopScript = "echo project-stop-updated" }
        XCTAssertEqual(try orchestrator.workspaceSettings(workspaceID: workspace.id)?.stopScript, "echo workspace-stop")
    }

    func testSuggestedWorkspaceNameMatchesAutoGeneratedDirname() throws {
        let repo = try makeTempGitRepo(name: "workspace-name-default")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let suggested = try orchestrator.suggestedWorkspaceName(projectID: project.id)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: suggested, branch: suggested)

        XCTAssertEqual(workspace.name, suggested)
        XCTAssertEqual(workspace.dirname, suggested)
        XCTAssertEqual(workspace.branch, suggested)

        let nextSuggested = try orchestrator.suggestedWorkspaceName(projectID: project.id)
        XCTAssertNotEqual(nextSuggested, suggested)
    }

    func testCreateWorkspaceUsesCustomNameWithAutoGeneratedDirname() throws {
        let repo = try makeTempGitRepo(name: "workspace-name-custom")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let suggested = try orchestrator.suggestedWorkspaceName(projectID: project.id)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature-name", branch: "feature-branch")

        XCTAssertEqual(workspace.name, "feature-name")
        XCTAssertEqual(workspace.branch, "feature-branch")
        XCTAssertEqual(workspace.dirname, suggested)
    }

    func testCreateWorkspaceUsesProvidedDirectoryNameForGitProject() throws {
        let repo = try makeTempGitRepo(name: "workspace-name-override")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(
            projectID: project.id, name: "feature-name", branch: "feature-branch", directoryName: "feature_branch_1")

        XCTAssertEqual(workspace.dirname, "feature_branch_1")
        XCTAssertTrue(workspace.dir.hasSuffix("/feature_branch_1"))
    }

    func testCreateWorkspaceRejectsDirectoryNameWithInvalidCharacters() throws {
        let repo = try makeTempGitRepo(name: "workspace-name-invalid-dirname")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        XCTAssertThrowsError(
            try orchestrator.createWorkspace(projectID: project.id, name: "feature-name", branch: "feature-branch", directoryName: "feature/branch")
        ) { error in XCTAssertTrue(error.localizedDescription.contains("letters, numbers, '-', and '_'")) }
    }

    func testCreateWorkspaceRejectsDirectoryNameWithSpaces() throws {
        let repo = try makeTempGitRepo(name: "workspace-name-space-dirname")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        XCTAssertThrowsError(
            try orchestrator.createWorkspace(projectID: project.id, name: "feature-name", branch: "feature-branch", directoryName: "feature branch")
        ) { error in XCTAssertTrue(error.localizedDescription.contains("cannot contain spaces")) }
    }

    func testCreateWorkspaceUsesSelectedTargetBranchAsBaseForNewBranch() throws {
        let repo = try makeTempGitRepo(name: "workspace-target-branch")
        try runGit(["checkout", "-b", "develop"], cwd: repo.path)
        try "target".write(to: repo.appendingPathComponent("TARGET.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "TARGET.txt"], cwd: repo.path)
        try runGit(["-c", "user.name=spaceship-test", "-c", "user.email=test@example.com", "commit", "-m", "target"], cwd: repo.path)
        try runGit(["checkout", "main"], cwd: repo.path)

        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(
            projectID: project.id, name: "feature-workspace", branch: "feature-branch", targetBranch: "develop")

        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.dir + "/TARGET.txt"))
    }

    func testListWorkspacesIncludesBranchMetadata() throws {
        let repo = try makeTempGitRepo(name: "workspace-branch-list")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        _ = try orchestrator.createWorkspace(projectID: project.id, name: "feature-branch", branch: "feature-branch")

        let workspaces = try orchestrator.listWorkspaces(projectID: project.id, includeArchived: true)
        let feature = try XCTUnwrap(workspaces.first(where: { $0.name == "feature-branch" }))
        XCTAssertEqual(feature.branch, "feature-branch")
    }

    func testCreateWorkspaceRevivesArchivedWorkspace() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let created = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try orchestrator.archiveWorkspace(workspaceID: created.id)

        let revived = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let persisted = try store.workspace(id: revived.id)

        XCTAssertEqual(revived.id, created.id)
        XCTAssertEqual(persisted?.isArchived, false)
        XCTAssertEqual(try orchestrator.workspacePorts(workspaceID: revived.id).count, 0)
    }

    func testListWorkspacesHonorsIncludeArchivedFlag() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try orchestrator.archiveWorkspace(workspaceID: workspace.id)

        let activeOnly = try orchestrator.listWorkspaces(projectID: project.id, includeArchived: false)
        XCTAssertEqual(activeOnly.map(\.name), ["default"])

        let all = try orchestrator.listWorkspaces(projectID: project.id, includeArchived: true)
        XCTAssertEqual(Set(all.map(\.name)), Set(["default", "feature"]))
    }

    func testArchiveWorkspaceRemovesGitWorktreeRegistration() throws {
        let repo = try makeTempGitRepo(name: "workspace-archive-git-worktree-remove")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature-archive", branch: "feature-archive")

        let normalizedWorkspaceDir = normalizeTestPath(workspace.dir)
        let before = try runGitAndCapture(["worktree", "list", "--porcelain"], cwd: repo.path)
        XCTAssertTrue(parseWorktreePaths(before).contains(normalizedWorkspaceDir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.dir))

        try orchestrator.archiveWorkspace(workspaceID: workspace.id)

        let after = try runGitAndCapture(["worktree", "list", "--porcelain"], cwd: repo.path)
        XCTAssertFalse(parseWorktreePaths(after).contains(normalizedWorkspaceDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.dir))
    }

    func testGUIShortcutsAndActiveWorkspaceRoundTrip() throws {
        let root = try makeTempDirectory()
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore)

        XCTAssertEqual(try orchestrator.guiHotkey(), SettingsKey.defaultGUIHotkey)
        XCTAssertEqual(try orchestrator.guiNextShortcut(), SettingsKey.defaultGUINextShortcut)
        XCTAssertEqual(try orchestrator.guiPreviousShortcut(), SettingsKey.defaultGUIPreviousShortcut)
        XCTAssertEqual(try orchestrator.guiShowShortcut(), SettingsKey.defaultGUIShowShortcut)
        XCTAssertEqual(try orchestrator.guiAddProjectShortcut(), SettingsKey.defaultGUIAddProjectShortcut)
        XCTAssertEqual(try orchestrator.guiAddWorkspaceShortcut(), SettingsKey.defaultGUIAddWorkspaceShortcut)
        XCTAssertEqual(try orchestrator.guiReloadShortcut(), SettingsKey.defaultGUIReloadShortcut)
        XCTAssertEqual(try orchestrator.guiOpenEditorShortcut(), SettingsKey.defaultGUIOpenEditorShortcut)
        XCTAssertEqual(try orchestrator.guiOpenTerminalShortcut(), SettingsKey.defaultGUIOpenTerminalShortcut)
        XCTAssertEqual(try orchestrator.guiOpenFinderShortcut(), SettingsKey.defaultGUIOpenFinderShortcut)
        XCTAssertEqual(try orchestrator.guiOpenSettingsShortcut(), SettingsKey.defaultGUIOpenSettingsShortcut)

        try orchestrator.setGUIHotkey("ctrl+alt+h")
        try orchestrator.setGUINextShortcut("ctrl+alt+n")
        try orchestrator.setGUIPreviousShortcut("ctrl+alt+p")
        try orchestrator.setGUIShowShortcut("ctrl+alt+s")
        try orchestrator.setGUIAddProjectShortcut("ctrl+alt+shift+n")
        try orchestrator.setGUIAddWorkspaceShortcut("ctrl+alt+w")
        try orchestrator.setGUIReloadShortcut("ctrl+alt+r")
        try orchestrator.setGUIOpenEditorShortcut("ctrl+alt+e")
        try orchestrator.setGUIOpenTerminalShortcut("ctrl+alt+t")
        try orchestrator.setGUIOpenFinderShortcut("ctrl+alt+f")
        try orchestrator.setGUIOpenSettingsShortcut("ctrl+alt+,")
        try orchestrator.setActiveWorkspace(id: "workspace-123")

        XCTAssertEqual(try orchestrator.guiHotkey(), "ctrl+alt+h")
        XCTAssertEqual(try orchestrator.guiNextShortcut(), "ctrl+alt+n")
        XCTAssertEqual(try orchestrator.guiPreviousShortcut(), "ctrl+alt+p")
        XCTAssertEqual(try orchestrator.guiShowShortcut(), "ctrl+alt+s")
        XCTAssertEqual(try orchestrator.guiAddProjectShortcut(), "ctrl+alt+shift+n")
        XCTAssertEqual(try orchestrator.guiAddWorkspaceShortcut(), "ctrl+alt+w")
        XCTAssertEqual(try orchestrator.guiReloadShortcut(), "ctrl+alt+r")
        XCTAssertEqual(try orchestrator.guiOpenEditorShortcut(), "ctrl+alt+e")
        XCTAssertEqual(try orchestrator.guiOpenTerminalShortcut(), "ctrl+alt+t")
        XCTAssertEqual(try orchestrator.guiOpenFinderShortcut(), "ctrl+alt+f")
        XCTAssertEqual(try orchestrator.guiOpenSettingsShortcut(), "ctrl+alt+,")
        XCTAssertEqual(try orchestrator.activeWorkspaceID(), "workspace-123")

        try orchestrator.setActiveWorkspace(id: nil)
        XCTAssertNil(try orchestrator.activeWorkspaceID())
    }

    func testRunStatusChecksPersistsResultsForMatchingProcesses() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceStatusChecks(
            workspaceID: workspace.id,
            checks: [
                StatusCheckDefinition(process: "api", command: "echo green", interval: 10, timeout: 2),
                StatusCheckDefinition(name: "failing", process: "api", command: "echo red && exit 1", interval: 10, timeout: 2),
                StatusCheckDefinition(process: "missing", command: "echo skipped", interval: 10, timeout: 2),
            ])
        let runningProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "echo api", terminalApp: nil, windowID: nil, pid: 9000,
            status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: runningProcess)

        let results = try orchestrator.runStatusChecks(workspaceID: workspace.id)

        XCTAssertEqual(results.count, 2)
        let byName = Dictionary(uniqueKeysWithValues: results.map { ($0.checkName, $0.status) })
        XCTAssertEqual(byName["api"], "green")
        XCTAssertEqual(byName["failing"], "red")

        let persisted = try orchestrator.statusResults(processID: runningProcess.id)
        XCTAssertEqual(persisted.count, 2)
    }

    func testCreateWorkspaceThrowsForUnknownProject() throws {
        let root = try makeTempDirectory()
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore)

        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: "missing", name: "feature"))
    }

    func testCreateWorkspaceForGitProjectRequiresBranch() throws {
        let repo = try makeTempGitRepo(name: "workspace-requires-branch")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)

        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id, name: "workspace")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Branch name is required"))
        }
    }

    func testOpenWorkspaceEditorThrowsWhenEditorIsNotConfigured() throws {
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace()

        XCTAssertThrowsError(try orchestrator.openWorkspaceEditor(workspaceID: workspace.id))
    }

    func testOpenWorkspaceEditorAttachesFocusedEditorWindow() throws {
        let (orchestrator, _, _, workspace, root) = try makeOrchestratorWithWorkspace(editor: .vscode)
        let openLog = root.appendingPathComponent("open.log")

        // Mocked dependencies: `yabai`, `osascript`, and `open`.
        // Why: deterministically emulate window discovery/focus and editor launching without GUI side effects.
        // Remaining risk: real macOS focus timing, launch delays, and yabai window snapshots may diverge.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock, "open": Self.openMockScript]) {
            try withEnv(name: "YABAI_FOCUSED_ID", value: "555") {
                try withEnv(name: "YABAI_FOCUSED_APP", value: "Visual Studio Code") {
                    try withEnv(name: "OPEN_LOG_FILE", value: openLog.path) { try orchestrator.openWorkspaceEditor(workspaceID: workspace.id) }
                }
            }
        }

        let windows = try orchestrator.windows(workspaceID: workspace.id)
        let editorWindows = windows.filter { $0.role == "editor" }
        XCTAssertEqual(editorWindows.count, 1)
        XCTAssertEqual(editorWindows.first?.windowID, 555)

        let openArgs = try String(contentsOf: openLog)
        XCTAssertTrue(openArgs.contains("-a Visual Studio Code"))
        XCTAssertTrue(openArgs.contains(workspace.dir))
    }

    func testOpenWorkspaceTerminalAttachesFocusedTerminalWindow() throws {
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace()

        // Mocked dependencies: `yabai` and `osascript`.
        // Why: validate terminal attach logic without requiring iTerm2/yabai in CI.
        // Remaining risk: real AppleScript/iTerm runtime behavior and command timing are not covered.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "YABAI_FOCUSED_ID", value: "777") {
                try withEnv(name: "YABAI_FOCUSED_APP", value: "iTerm2") { try orchestrator.openWorkspaceTerminal(workspaceID: workspace.id) }
            }
        }

        let windows = try orchestrator.windows(workspaceID: workspace.id)
        let terminalWindows = windows.filter { $0.role == "terminal" }
        XCTAssertEqual(terminalWindows.count, 1)
        XCTAssertEqual(terminalWindows.first?.windowID, 777)
    }

    func testOpenWorkspaceTerminalThrowsWhenITermIsUnavailable() throws {
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace()

        // Mocked dependency: iTerm availability probe through `osascript`.
        // Why: force deterministic dependency-missing behavior.
        // Remaining risk: only one unavailability failure mode is simulated.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "MOCK_ITERM_UNAVAILABLE", value: "1") {
                XCTAssertThrowsError(try orchestrator.openWorkspaceTerminal(workspaceID: workspace.id))
            }
        }
    }

    func testFocusWorkspaceSkipsFailedWindowAndSetsActiveWorkspace() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let focusLog = root.appendingPathComponent("focus.log")

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "bad", windowID: 999, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "good", windowID: 101, role: "terminal", orderIndex: 1,
                lastSeenAt: "now"))

        // Mocked dependency: `yabai` focus command outcomes.
        // Why: control success/failure ordering and verify fallback focus behavior.
        // Remaining risk: actual focus behavior can vary with spaces/displays and concurrent window changes.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) { try orchestrator.focusWorkspace(workspaceID: workspace.id) }
        }

        XCTAssertEqual(try orchestrator.activeWorkspaceID(), workspace.id)
        let focusedIDs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedIDs, ["101"])
    }

    func testFocusWindowNavigationUsesRelativeOrderAndWraps() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let focusLog = root.appendingPathComponent("relative-focus.log")

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "one", windowID: 101, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "two", windowID: 202, role: "terminal", orderIndex: 1,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "three", windowID: 303, role: "terminal", orderIndex: 2,
                lastSeenAt: "now"))

        // Mocked dependency: `yabai` focused-window query and focus command.
        // Why: deterministically exercise relative navigation and wraparound.
        // Remaining risk: real-time focus transitions and stale snapshots are not represented.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try withEnv(name: "YABAI_FOCUSED_ID", value: "202") { try orchestrator.focusNextWindow(workspaceID: workspace.id) }
                try withEnv(name: "YABAI_FOCUSED_ID", value: "101") { try orchestrator.focusPreviousWindow(workspaceID: workspace.id) }
                try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 2)
            }
        }

        let focusedIDs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedIDs, ["303", "202", "202"])
        XCTAssertEqual(try orchestrator.activeWorkspaceID(), workspace.id)
    }

    func testFocusWorkspaceWindowUsesBrowserTargetURLWhenPresent() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let focusLog = root.appendingPathComponent("browser-focus.log")

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "Google Calendar", targetURL: "http://localhost:3001",
                windowID: 202, role: "browser", orderIndex: 0, lastSeenAt: "now"))

        // Mocked dependencies: Chrome tab activation and yabai fallback focus.
        // Why: ensure browser windows tracked with target URLs activate matching tabs instead of only focusing the window.
        // Remaining risk: real Chrome scripting latency and tab/window races are not represented.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 1)
            }
        }

        XCTAssertEqual(try orchestrator.activeWorkspaceID(), workspace.id)
        let focusLogExists = FileManager.default.fileExists(atPath: focusLog.path)
        if focusLogExists {
            let focusedIDs = try String(contentsOf: focusLog).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(focusedIDs.isEmpty)
        }
    }

    func testFocusWindowNavigationWrapsAcrossBrowserTargetsInSameChromeWindow() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let focusLog = root.appendingPathComponent("browser-nav-focus.log")
        let chromeLog = root.appendingPathComponent("browser-nav-chrome.log")
        let chromeActiveURL = root.appendingPathComponent("browser-nav-active-url.log")
        try "http://localhost:3001".write(to: chromeActiveURL, atomically: true, encoding: .utf8)

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell", windowID: 101, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "localhost-3001", targetURL: "http://localhost:3001",
                windowID: 202, role: "browser", orderIndex: 1, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "localhost-8000",
                targetURL: "http://localhost:8000/admin", windowID: 202, role: "browser", orderIndex: 2, lastSeenAt: "now"))

        // Mocked dependencies: Chrome active-tab focus/read + yabai fallback focus.
        // Why: verify deterministic next-window traversal when multiple tracked browser targets share one Chrome window.
        // Remaining risk: real-world browser/window races are not represented by this mock.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try withEnv(name: "MOCK_CHROME_FOCUS_LOG_FILE", value: chromeLog.path) {
                    try withEnv(name: "MOCK_CHROME_ACTIVE_URL_FILE", value: chromeActiveURL.path) {
                        try withEnv(name: "YABAI_FOCUSED_ID", value: "202") {
                            try orchestrator.focusNextWindow(workspaceID: workspace.id)
                            try orchestrator.focusNextWindow(workspaceID: workspace.id)
                        }
                        try withEnv(name: "YABAI_FOCUSED_ID", value: "101") { try orchestrator.focusNextWindow(workspaceID: workspace.id) }
                    }
                }
            }
        }

        let chromeURLs = try String(contentsOf: chromeLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(chromeURLs, ["http://localhost:8000/admin", "http://localhost:3001"])
        if FileManager.default.fileExists(atPath: focusLog.path) {
            let focusedIDs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
            XCTAssertEqual(focusedIDs, ["101"])
        }
    }

    func testFocusWorkspaceWindowUsesTrackedChromeWindowIDWhenTargetURLIsShared() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let focusLog = root.appendingPathComponent("browser-shared-url-focus.log")
        let chromeWindowLog = root.appendingPathComponent("browser-shared-url-window.log")

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "target-one", targetURL: "http://localhost:3001",
                windowID: 202, role: "browser", orderIndex: 0, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "target-two", targetURL: "http://localhost:3001",
                windowID: 303, role: "browser", orderIndex: 1, lastSeenAt: "now"))

        // Mocked dependencies: Chrome tab activation and yabai fallback focus.
        // Why: ensure browser focus respects tracked window ID when multiple windows share a URL prefix.
        // Remaining risk: real Chrome may reorder windows/tabs asynchronously under heavy activity.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try withEnv(name: "MOCK_CHROME_FOCUS_WINDOW_LOG_FILE", value: chromeWindowLog.path) {
                    try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 2)
                }
            }
        }

        let focusedWindowIDs = try String(contentsOf: chromeWindowLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedWindowIDs, ["303"])
        if FileManager.default.fileExists(atPath: focusLog.path) {
            let focusedIDs = try String(contentsOf: focusLog).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(focusedIDs.isEmpty)
        }
    }

    func testWindowsLiveScanUsesSessionPrefixesAndDeduplicatesOverlappingMatches() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id, sessions: [BrowserSession(url: "http://localhost:3001"), BrowserSession(url: "http://localhost:3001/admin")])
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell", windowID: 101, role: "terminal", orderIndex: 10,
                lastSeenAt: "now"))
        let chromeMatches =
            "202\tGoogle Chrome — localhost 3001\thttp://localhost:3001\n202\tGoogle Chrome — localhost 3001 admin\thttp://localhost:3001/admin\n202\tGoogle Chrome — localhost 3001 admin users\thttp://localhost:3001/admin/users\n303\tGoogle Chrome — calendar\thttps://calendar.google.com/\n"

        // Mocked dependencies: Chrome tab scan for live browser-row reconstruction.
        // Why: ensure windows list includes every tab whose URL starts with any session URL, without duplicate rows from overlapping prefixes.
        // Remaining risk: live Chrome tab ordering can vary across real profiles/extensions.
        try withMockCommands(["osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "MOCK_CHROME_WINDOW_MATCHES", value: chromeMatches) {
                let windows = try orchestrator.windows(workspaceID: workspace.id)
                let browserURLs = windows.filter { $0.role == "browser" }.compactMap(\.targetURL)
                XCTAssertEqual(browserURLs, ["http://localhost:3001", "http://localhost:3001/admin", "http://localhost:3001/admin/users"])
                XCTAssertEqual(Set(browserURLs).count, 3)
                XCTAssertEqual(windows.last?.role, "terminal")
            }
        }
    }

    func testWindowsLiveScanDebouncesRefreshForTenSeconds() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace(
            browserWindowScanDebounceInterval: 10, currentDate: { clock.now() })
        let scanLog = root.appendingPathComponent("chrome-scan.log")
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(url: "http://localhost:3001")])
        let chromeMatches = "202\tGoogle Chrome — localhost 3001\thttp://localhost:3001\n"

        // Mocked dependency: Chrome tab scan script entrypoint.
        // Why: assert repeated windows reads within 10 seconds reuse cached browser rows and skip re-scanning Chrome.
        // Remaining risk: real-world tab churn during the debounce window intentionally appears up to 10 seconds stale.
        try withMockCommands(["osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "MOCK_CHROME_WINDOW_MATCHES", value: chromeMatches) {
                try withEnv(name: "MOCK_CHROME_SCAN_LOG_FILE", value: scanLog.path) {
                    let first = try orchestrator.windows(workspaceID: workspace.id)
                    XCTAssertEqual(first.filter { $0.role == "browser" }.count, 1)

                    try store.upsert(
                        window: WindowRecord(
                            id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell", windowID: 101, role: "terminal",
                            orderIndex: 200, lastSeenAt: "now"))

                    let second = try orchestrator.windows(workspaceID: workspace.id)
                    XCTAssertEqual(second.filter { $0.role == "browser" }.count, 1)
                    XCTAssertEqual(second.filter { $0.role == "terminal" }.count, 1)

                    clock.advance(seconds: 11)
                    let third = try orchestrator.windows(workspaceID: workspace.id)
                    XCTAssertEqual(third.filter { $0.role == "browser" }.count, 1)
                }
            }
        }

        let scanCount = (try? String(contentsOf: scanLog).split(separator: "\n").count) ?? 0
        XCTAssertEqual(scanCount, 2)
    }

    func testFocusWorkspaceWindowUsesTabIndexFastPathWhenLiveScanIsPresent() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let tabIndexLog = root.appendingPathComponent("browser-tab-index-focus.log")
        let activeURL = root.appendingPathComponent("browser-tab-index-active-url.log")
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(url: "http://localhost:3001")])
        let chromeMatches =
            "202\tGoogle Chrome — localhost 3001 a\thttp://localhost:3001/a\n202\tGoogle Chrome — localhost 3001 b\thttp://localhost:3001/b\n"

        // Mocked dependency: Chrome tab scan + tab-index focus script path.
        // Why: ensure navigation uses direct tab index focus after live scan to avoid URL search loops across tabs.
        // Remaining risk: stale tab indices can still fall back to URL matching in real Chrome when tabs reorder between scan and focus.
        try withMockCommands(["osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "MOCK_CHROME_WINDOW_MATCHES", value: chromeMatches) {
                try withEnv(name: "MOCK_CHROME_TAB_INDEX_LOG_FILE", value: tabIndexLog.path) {
                    try withEnv(name: "MOCK_CHROME_ACTIVE_URL_FILE", value: activeURL.path) {
                        try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 2)
                    }
                }
            }
        }

        let focusedTabs = try String(contentsOf: tabIndexLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedTabs, ["202\t2"])
    }

    func testFocusWorkspaceWindowAutoCorrectsWhenFocusedIndexedTabDoesNotMatchWorkspace() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let scanLog = root.appendingPathComponent("browser-tab-index-refresh.log")
        let focusLog = root.appendingPathComponent("browser-tab-index-fallback.log")
        let tabIndexLog = root.appendingPathComponent("browser-tab-index-fallback-index.log")
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(url: "http://localhost:3001")])
        let chromeMatches = "202\tGoogle Chrome — localhost 3001 a\thttp://localhost:3001/a\n"

        // Mocked dependency: Chrome tab scan + tab-index focus + active-tab verification + URL focus fallback path.
        // Why: ensure fast indexed focus auto-corrects when the focused tab is outside workspace URLs.
        // Remaining risk: if Chrome mutates tabs continuously, one refresh may still miss a stable index and rely on URL fallback.
        try withMockCommands(["osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "MOCK_CHROME_WINDOW_MATCHES", value: chromeMatches) {
                try withEnv(name: "MOCK_CHROME_TAB_INDEX_ACTIVE_URL", value: "https://calendar.google.com/") {
                    try withEnv(name: "MOCK_CHROME_SCAN_LOG_FILE", value: scanLog.path) {
                        try withEnv(name: "MOCK_CHROME_FOCUS_LOG_FILE", value: focusLog.path) {
                            try withEnv(name: "MOCK_CHROME_TAB_INDEX_LOG_FILE", value: tabIndexLog.path) {
                                try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 1)
                            }
                        }
                    }
                }
            }
        }

        let scanCount = (try? String(contentsOf: scanLog).split(separator: "\n").count) ?? 0
        XCTAssertEqual(scanCount, 2)
        let focusedURLs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedURLs, ["https://calendar.google.com/", "https://calendar.google.com/", "http://localhost:3001/a"])
        let focusedByIndex = try String(contentsOf: tabIndexLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedByIndex, ["202\t1", "202\t1"])
    }

    func testFocusWorkspaceWindowUsesDistinctLiveTabURLsForOverlappingSessionPrefixes() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let chromeLog = root.appendingPathComponent("browser-overlap-focus.log")
        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id, sessions: [BrowserSession(url: "http://localhost:3001"), BrowserSession(url: "http://localhost:3001/admin")])
        let chromeMatches =
            "202\tGoogle Chrome — localhost 3001\thttp://localhost:3001\n202\tGoogle Chrome — localhost 3001 admin\thttp://localhost:3001/admin\n202\tGoogle Chrome — localhost 3001 admin users\thttp://localhost:3001/admin/users\n"

        // Mocked dependencies: Chrome tab scan + focus calls.
        // Why: verify cmd+number focus routes to different tabs when session prefixes overlap.
        // Remaining risk: real Chrome can reorder tabs while shortcuts are pressed rapidly.
        try withMockCommands(["osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "MOCK_CHROME_WINDOW_MATCHES", value: chromeMatches) {
                try withEnv(name: "MOCK_CHROME_FOCUS_LOG_FILE", value: chromeLog.path) {
                    try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 1)
                    try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 2)
                    try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 3)
                }
            }
        }

        let focusedURLs = try String(contentsOf: chromeLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedURLs, ["http://localhost:3001", "http://localhost:3001/admin", "http://localhost:3001/admin/users"])
    }

    func testFocusWindowNavigationPrefersRememberedIndexAcrossBrowserRowsSharingWindowID() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let chromeLog = root.appendingPathComponent("browser-nav-remembered.log")
        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id, sessions: [BrowserSession(url: "http://localhost:3001"), BrowserSession(url: "http://localhost:8000/admin")])
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell", windowID: 101, role: "terminal", orderIndex: 200,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "build", windowID: 102, role: "terminal", orderIndex: 201,
                lastSeenAt: "now"))
        let chromeMatches =
            "202\tGoogle Chrome — localhost 3001\thttp://localhost:3001\n202\tGoogle Chrome — localhost 8000\thttp://localhost:8000/admin\n"

        // Mocked dependencies: Chrome tab scan + focus calls and yabai focused-window query.
        // Why: ensure forward navigation continues from remembered cycle index instead of oscillating between browser rows that share one window ID.
        // Remaining risk: host-level focus races can still diverge under heavy desktop activity.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "MOCK_CHROME_WINDOW_MATCHES", value: chromeMatches) {
                try withEnv(name: "MOCK_CHROME_FOCUS_LOG_FILE", value: chromeLog.path) {
                    try withEnv(name: "YABAI_FOCUSED_ID", value: "101") {
                        try withEnv(name: "YABAI_FOCUSED_APP", value: "iTerm2") {
                            try orchestrator.focusNextWindow(workspaceID: workspace.id)  // terminal 102
                            try orchestrator.focusNextWindow(workspaceID: workspace.id)  // browser 3001
                            try orchestrator.focusNextWindow(workspaceID: workspace.id)  // browser 8000
                        }
                    }
                }
            }
        }

        let focusedURLs = try String(contentsOf: chromeLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedURLs, ["http://localhost:3001", "http://localhost:8000/admin"])
    }

    func testTrackedWindowsOrdersBrowserThenTerminalThenOtherRoles() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(url: "http://localhost:3001")])
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Finder", title: "finder", windowID: 301, role: "finder", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell", windowID: 101, role: "terminal", orderIndex: 200,
                lastSeenAt: "now"))
        let chromeMatches = "202\tGoogle Chrome — localhost 3001\thttp://localhost:3001\n"

        // Mocked dependency: Chrome tab scan for role-ordering behavior.
        // Why: enforce browser-first, terminal-second, then remaining roles for window cycling.
        // Remaining risk: none beyond scan ordering assumptions already covered elsewhere.
        try withMockCommands(["osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "MOCK_CHROME_WINDOW_MATCHES", value: chromeMatches) {
                let windows = try orchestrator.windows(workspaceID: workspace.id)
                XCTAssertEqual(windows.map(\.role), ["browser", "terminal", "finder"])
            }
        }
    }

    func testWindowsLiveScanOrdersBrowserRowsBySessionPrefixThenURL() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id, sessions: [BrowserSession(url: "http://localhost:3001"), BrowserSession(url: "http://localhost:8000/admin")])

        let chromeMatches =
            "303\tGoogle Chrome — localhost 8000 users\thttp://localhost:8000/admin/users\n202\tGoogle Chrome — localhost 3001 z\thttp://localhost:3001/z\n202\tGoogle Chrome — localhost 3001 a\thttp://localhost:3001/a\n404\tGoogle Chrome — localhost 8000 admin\thttp://localhost:8000/admin\n"

        // Mocked dependency: Chrome tab scan for deterministic browser-row ordering.
        // Why: ensure keyboard index shortcuts stay aligned with the rendered window list even when Chrome window order changes.
        // Remaining risk: none beyond deterministic URL sorting assumptions enforced here.
        try withMockCommands(["osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "MOCK_CHROME_WINDOW_MATCHES", value: chromeMatches) {
                let windows = try orchestrator.windows(workspaceID: workspace.id)
                let browserURLs = windows.filter { $0.role == "browser" }.compactMap(\.targetURL)
                XCTAssertEqual(
                    browserURLs,
                    ["http://localhost:3001/a", "http://localhost:3001/z", "http://localhost:8000/admin", "http://localhost:8000/admin/users"])
            }
        }
    }

    func testWindowsOmitsUntargetedBrowserRowsWhenTargetedRowSharesWindowID() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "localhost", targetURL: "http://localhost:3001",
                windowID: 202, role: "browser", orderIndex: 1, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "Unrelated Tab", windowID: 202, role: "browser",
                orderIndex: 2, lastSeenAt: "now"))

        let windows = try orchestrator.windows(workspaceID: workspace.id)
        XCTAssertEqual(windows.filter { $0.role == "browser" }.count, 1)
        XCTAssertEqual(windows.first(where: { $0.role == "browser" })?.targetURL, "http://localhost:3001")
    }

    func testFocusWindowNavigationUsesActiveBrowserTabWhenRememberedIndexIsStale() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let focusLog = root.appendingPathComponent("browser-nav-stale-focus.log")
        let chromeLog = root.appendingPathComponent("browser-nav-stale-chrome.log")
        let chromeActiveURL = root.appendingPathComponent("browser-nav-stale-active-url.log")
        try "http://localhost:3001".write(to: chromeActiveURL, atomically: true, encoding: .utf8)

        let terminalRowID = UUID().uuidString
        try store.upsert(
            window: WindowRecord(
                id: terminalRowID, workspaceID: workspace.id, app: "iTerm2", title: "shell", windowID: 101, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "localhost-3001", targetURL: "http://localhost:3001",
                windowID: 202, role: "browser", orderIndex: 1, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "localhost-8000",
                targetURL: "http://localhost:8000/admin", windowID: 202, role: "browser", orderIndex: 2, lastSeenAt: "now"))

        // Mocked dependencies: Chrome active-tab focus/read + yabai focused-window query.
        // Why: ensure next-window navigation uses the actual active tab URL when multiple tracked tabs share one window.
        // Remaining risk: live Chrome/yabai timing races can still diverge from this deterministic harness.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try withEnv(name: "MOCK_CHROME_FOCUS_LOG_FILE", value: chromeLog.path) {
                    try withEnv(name: "MOCK_CHROME_ACTIVE_URL_FILE", value: chromeActiveURL.path) {
                        try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 3)
                        try store.deleteWindow(id: terminalRowID)
                        try "http://localhost:3001".write(to: chromeActiveURL, atomically: true, encoding: .utf8)
                        try withEnv(name: "YABAI_FOCUSED_ID", value: "202") {
                            try withEnv(name: "YABAI_FOCUSED_APP", value: "Google Chrome") {
                                try orchestrator.focusNextWindow(workspaceID: workspace.id)
                            }
                        }
                    }
                }
            }
        }

        let chromeURLs = try String(contentsOf: chromeLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(chromeURLs, ["http://localhost:8000/admin", "http://localhost:8000/admin"])
        if FileManager.default.fileExists(atPath: focusLog.path) {
            let focusedIDs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
            XCTAssertTrue(focusedIDs.isEmpty)
        }
    }

    func testLaunchWorkspaceTracksAllTerminalWindowsFromRunningProcesses() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let itermWindowIDsFile = root.appendingPathComponent("iterm-window-ids.txt")
        let runtimeDir = root.appendingPathComponent("runtime", isDirectory: true)
        try "701,702".write(to: itermWindowIDsFile, atomically: true, encoding: .utf8)

        try store.setWorkspaceProcesses(
            workspaceID: workspace.id,
            processes: [ProcessTemplate(name: "one", command: "echo one"), ProcessTemplate(name: "two", command: "echo two")])

        let windowsJSON =
            "[{\"id\":701,\"pid\":71,\"app\":\"iTerm2\",\"title\":\"one\",\"space\":1,\"display\":1,\"is-sticky\":false,\"is-hidden\":false,\"is-visible\":true,\"is-native-fullscreen\":false},{\"id\":702,\"pid\":72,\"app\":\"iTerm2\",\"title\":\"two\",\"space\":1,\"display\":1,\"is-sticky\":false,\"is-hidden\":false,\"is-visible\":true,\"is-native-fullscreen\":false}]"

        // Mocked dependencies: iTerm window creation IDs and yabai window snapshots.
        // Why: ensure launch records all terminal windows even when snapshot-diff capture misses them.
        // Remaining risk: real timing differences between iTerm and yabai updates may still need tuning.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "SPACESHIP_RUNTIME_DIR", value: runtimeDir.path) {
                try withEnv(name: "MOCK_ITERM_WINDOW_IDS_FILE", value: itermWindowIDsFile.path) {
                    try withEnv(name: "YABAI_WINDOWS_JSON", value: windowsJSON) { try orchestrator.launchWorkspace(workspaceID: workspace.id) }
                }
            }
        }

        let terminalWindows = try orchestrator.windows(workspaceID: workspace.id).filter { $0.role == "terminal" }
        XCTAssertEqual(terminalWindows.count, 2)
        XCTAssertEqual(Set(terminalWindows.compactMap(\.windowID)), Set([701, 702]))
    }

    func testLaunchWorkspaceReusesExistingBrowserMatchesAndTracksAllMatchingTabs() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let chromeOpenLog = root.appendingPathComponent("chrome-open.log")

        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(url: "http://localhost:3001")])

        let chromeMatches =
            "202\tGoogle Chrome — localhost 3001\thttp://localhost:3001\n202\tGoogle Chrome — localhost 8000\thttp://localhost:8000/admin\n303\tGoogle Chrome — localhost 3001 docs\thttp://localhost:3001/docs\n"

        // Mocked dependencies: Chrome match discovery + launch path window capture.
        // Why: assert launch reuses existing matching tabs and tracks every match for cycling.
        // Remaining risk: real-world Chrome/yabai timing can differ from deterministic mock ordering.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "MOCK_CHROME_WINDOW_MATCHES", value: chromeMatches) {
                try withEnv(name: "MOCK_CHROME_OPEN_LOG_FILE", value: chromeOpenLog.path) {
                    try orchestrator.launchWorkspace(workspaceID: workspace.id)
                }
            }
        }

        let browserWindows = try store.windows(workspaceID: workspace.id).filter { $0.role == "browser" }
        XCTAssertEqual(browserWindows.count, 3)
        XCTAssertEqual(
            Set(browserWindows.compactMap(\.targetURL)), Set(["http://localhost:3001", "http://localhost:8000/admin", "http://localhost:3001/docs"]))
        if FileManager.default.fileExists(atPath: chromeOpenLog.path) {
            let openLog = try String(contentsOf: chromeOpenLog).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(openLog.isEmpty)
        }
    }

    func testWorkspaceIDForFocusedWindowMapsFromYabai() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell", windowID: 202, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))

        // Mocked dependency: focused-window query from `yabai`.
        // Why: explicitly cover both "focused window exists" and "no focused window" branches.
        // Remaining risk: malformed/partial focused-window payloads are not simulated.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUSED_ID", value: "202") { XCTAssertEqual(try orchestrator.workspaceIDForFocusedWindow(), workspace.id) }

            try withEnv(name: "YABAI_FOCUSED_NONE", value: "1") { XCTAssertNil(try orchestrator.workspaceIDForFocusedWindow()) }
        }
    }

    func testWorkspaceIDForFocusedChromeWindowUsesActiveTabURLMatch() throws {
        let (orchestrator, store, project, workspace, root) = try makeOrchestratorWithWorkspace()
        let otherWorkspace = try orchestrator.createWorkspace(projectID: project.id, name: "other")
        let chromeActiveURL = root.appendingPathComponent("workspace-focus-chrome-url.log")
        try "http://localhost:3001/docs".write(to: chromeActiveURL, atomically: true, encoding: .utf8)

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: otherWorkspace.id, app: "Google Chrome", title: "other", targetURL: "http://localhost:5000",
                windowID: 202, role: "browser", orderIndex: 0, lastSeenAt: "2026-02-12T00:00:00Z"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "feature", targetURL: "http://localhost:3001",
                windowID: 202, role: "browser", orderIndex: 0, lastSeenAt: "2026-02-12T00:00:01Z"))

        // Mocked dependencies: focused-window query from `yabai` and active-tab URL from Chrome AppleScript.
        // Why: ensure global next/previous resolves the correct workspace when one Chrome window is tracked by multiple workspaces.
        // Remaining risk: runtime races between yabai and Chrome focus events are not represented in this deterministic harness.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "YABAI_FOCUSED_ID", value: "202") {
                try withEnv(name: "YABAI_FOCUSED_APP", value: "Google Chrome") {
                    try withEnv(name: "MOCK_CHROME_ACTIVE_URL_FILE", value: chromeActiveURL.path) {
                        XCTAssertEqual(try orchestrator.workspaceIDForFocusedWindow(), workspace.id)
                    }
                }
            }
        }
    }

    func testListSpaceOptionsSortsByDisplayThenSpace() throws {
        let root = try makeTempDirectory()
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore)

        // Mocked dependency: `yabai --spaces` payload ordering.
        // Why: guarantee sort assertions independently of host window-manager state.
        // Remaining risk: unexpected production fields or space metadata edge cases are not covered.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            let options = try orchestrator.listSpaceOptions()
            let values = options.map { "\($0.displayIndex):\($0.spaceIndex)" }
            XCTAssertEqual(values, ["1:1", "1:2", "2:3"])
        }
    }

    func testUpdateWorkspaceSettingsMarksWorkspaceRunningWhenRuntimeIndicatorsExist() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: nil, windowID: nil,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        // Mocked dependency: `yabai` query path used during process/window reconciliation.
        // Why: isolate store-state transition coverage from real window manager availability.
        // Remaining risk: reconciliation against rapidly changing real windows remains untested here.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { _ in }
        }

        let updated = try store.workspace(id: workspace.id)
        XCTAssertEqual(updated?.isRunning, true)
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
    }

    func testListProjectsReturnsSortedSummaries() throws {
        let root = try makeTempDirectory()
        let aDir = root.appendingPathComponent("alpha", isDirectory: true)
        let bDir = root.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: aDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bDir, withIntermediateDirectories: true)

        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore)

        _ = try orchestrator.addProject(dir: bDir.path)
        _ = try orchestrator.addProject(dir: aDir.path)
        let projects = try orchestrator.listProjects()

        XCTAssertEqual(projects.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(projects.map(\.isGitRepo), [false, false])
    }

    func testSyncConfigDropsInvalidProjectAndSeedsDefaultWorkspace() throws {
        let root = try makeTempDirectory()
        let validDir = root.appendingPathComponent("valid", isDirectory: true)
        try FileManager.default.createDirectory(at: validDir, withIntermediateDirectories: true)
        let missingDir = root.appendingPathComponent("missing", isDirectory: true)

        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        try configStore.save(
            AppConfig(
                editor: nil, portRange: PortRange(start: 20000, end: 30000),
                projects: [ProjectConfig(dir: validDir.path), ProjectConfig(dir: missingDir.path)]))

        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore)
        let synced = try orchestrator.syncConfig()

        XCTAssertEqual(synced.projects.map(\.dir), [validDir.path])
        XCTAssertEqual(try store.projects().count, 1)
        XCTAssertNotNil(try store.workspace(projectID: validDir.path, name: "default"))
    }

    func testUpdateProjectConfigAndReadBackProjectConfig() throws {
        let (orchestrator, _, project, _, _) = try makeOrchestratorWithWorkspace()

        let updated = ProjectConfig(
            dir: project.dir, setupScript: "echo setup", stopScript: "echo stop", processes: [ProcessTemplate(name: "api", command: "npm run api")],
            statusChecks: [StatusCheckDefinition(name: "health", process: "api", command: "echo ok", interval: 10, timeout: 2, onExit: .notify)],
            browserSessions: [BrowserSession(url: "https://example.com")])
        try orchestrator.updateProjectConfig(updated)

        let loaded = try orchestrator.projectConfig(projectID: project.id)
        XCTAssertEqual(loaded?.setupScript, "echo setup")
        XCTAssertEqual(loaded?.stopScript, "echo stop")
        XCTAssertEqual(loaded?.processes.first?.name, "api")
        XCTAssertEqual(loaded?.statusChecks.first?.name, "health")
        XCTAssertEqual(loaded?.browserSessions.first?.url, "https://example.com")
    }

    func testUpdateProjectConfigUsingClosurePersistsChanges() throws {
        let (orchestrator, _, project, _, _) = try makeOrchestratorWithWorkspace()

        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.stopScript = "echo bye"
            config.processes = [ProcessTemplate(command: "echo process")]
        }

        let loaded = try orchestrator.projectConfig(projectID: project.id)
        XCTAssertEqual(loaded?.stopScript, "echo bye")
        XCTAssertEqual(loaded?.processes.first?.command, "echo process")
    }

    func testUpdateProjectConfigSeedsDefaultWorkspaceWhenSettingsMatchPreviousTemplate() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let defaultWorkspace = try XCTUnwrap(
            try orchestrator.listWorkspaces(projectID: project.id, includeArchived: true).first(where: { $0.isDefault }))

        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.stopScript = "echo stop"
            config.processes = [ProcessTemplate(name: "api", command: "npm run api")]
            config.statusChecks = [StatusCheckDefinition(name: "health", process: "api", command: "echo ok", interval: 30, timeout: 3)]
            config.browserSessions = [BrowserSession(url: "https://example.com")]
        }

        let settings = try orchestrator.workspaceSettings(workspaceID: defaultWorkspace.id)
        XCTAssertEqual(settings?.stopScript, "echo stop")
        XCTAssertEqual(settings?.processes.first?.name, "api")
        XCTAssertEqual(settings?.statusChecks.first?.name, "health")
        XCTAssertEqual(settings?.browserSessions.first?.url, "https://example.com")
    }

    func testUpdateProjectConfigDoesNotOverwriteCustomizedDefaultWorkspaceSettings() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(store: store, configStore: configStore)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let defaultWorkspace = try XCTUnwrap(
            try orchestrator.listWorkspaces(projectID: project.id, includeArchived: true).first(where: { $0.isDefault }))

        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.stopScript = "echo project-stop"
            config.processes = [ProcessTemplate(name: "api", command: "npm run api")]
            config.statusChecks = [StatusCheckDefinition(name: "health", process: "api", command: "echo ok", interval: 30, timeout: 3)]
            config.browserSessions = [BrowserSession(url: "https://example.com")]
        }

        try orchestrator.updateWorkspaceSettings(workspaceID: defaultWorkspace.id) { settings in
            settings.stopScript = "echo workspace-stop"
            settings.processes = [ProcessTemplate(name: "custom", command: "echo custom")]
            settings.statusChecks = []
            settings.browserSessions = [BrowserSession(url: "https://custom.example.com")]
        }

        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.stopScript = "echo project-stop-v2"
            config.processes = [ProcessTemplate(name: "api", command: "npm run api:v2")]
            config.statusChecks = [StatusCheckDefinition(name: "health-v2", process: "api", command: "echo ok v2", interval: 45, timeout: 5)]
            config.browserSessions = [BrowserSession(url: "https://example.com/v2")]
        }

        let settings = try orchestrator.workspaceSettings(workspaceID: defaultWorkspace.id)
        XCTAssertEqual(settings?.stopScript, "echo workspace-stop")
        XCTAssertEqual(settings?.processes.first?.name, "custom")
        XCTAssertEqual(settings?.processes.first?.command, "echo custom")
        XCTAssertTrue(settings?.statusChecks.isEmpty ?? false)
        XCTAssertEqual(settings?.browserSessions.first?.url, "https://custom.example.com")
    }

    func testCreateWorkspaceRejectsDuplicateActiveWorkspace() throws {
        let (orchestrator, _, project, _, _) = try makeOrchestratorWithWorkspace()
        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id, name: "feature"))
    }

    func testArchiveDefaultWorkspaceThrows() throws {
        let (orchestrator, _, project, _, _) = try makeOrchestratorWithWorkspace()
        let defaultWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first(where: { $0.isDefault }))
        XCTAssertThrowsError(try orchestrator.archiveWorkspace(workspaceID: defaultWorkspace.id))
    }

    func testStopWorkspaceUpdatesRunningStateAndCleansRuntimeRecords() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell", windowID: 501, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 501,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        // Mocked dependencies: window close via `yabai` and iTerm cleanup via `osascript`.
        // Why: verify cleanup semantics without touching real windows/processes.
        // Remaining risk: real process/window teardown can fail or race differently than this mocked path.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try orchestrator.stopWorkspace(workspaceID: workspace.id)
        }
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
        XCTAssertTrue(try orchestrator.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try orchestrator.runningProcesses(workspaceID: workspace.id).isEmpty)
    }

    func testStopWorkspaceTerminatesProcessBeforeClosingTrackedTerminalWindow() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let eventLog = root.appendingPathComponent("stop-workspace-events.log")
        let stopScript = "echo stop-script >> '\(eventLog.path)'"
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: stopScript)
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell", windowID: 501, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 501,
                pid: 4321, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock, "kill": Self.killMockScript]) {
            try withEnv(name: "MOCK_KILL_LOG_FILE", value: eventLog.path) {
                try withEnv(name: "MOCK_ITERM_CLOSE_LOG_FILE", value: eventLog.path) { try orchestrator.stopWorkspace(workspaceID: workspace.id) }
            }
        }

        let events = (try? String(contentsOf: eventLog).split(separator: "\n").map(String.init)) ?? []
        guard let killIndex = events.firstIndex(where: { $0.hasPrefix("kill ") }) else {
            return XCTFail("Expected process termination event before window close.")
        }
        guard let closeIndex = events.firstIndex(where: { $0.hasPrefix("iterm-close ") }) else {
            return XCTFail("Expected iTerm window close event for tracked process.")
        }
        guard let stopScriptIndex = events.firstIndex(of: "stop-script") else { return XCTFail("Expected workspace stop script execution event.") }
        XCTAssertTrue(events.contains("kill -INT -- -4321"))
        XCTAssertLessThan(killIndex, stopScriptIndex)
        XCTAssertLessThan(stopScriptIndex, closeIndex)
        XCTAssertLessThan(killIndex, closeIndex)
    }

    func testStopWorkspaceResolvesPIDFromRuntimeFileWhenTrackedPIDIsMissing() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let eventLog = root.appendingPathComponent("stop-workspace-runtime-events.log")
        let runtimeDir = root.appendingPathComponent("runtime", isDirectory: true)
        let workspaceRuntimeDir = runtimeDir.appendingPathComponent(workspace.id, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRuntimeDir, withIntermediateDirectories: true)
        try "8765".write(to: workspaceRuntimeDir.appendingPathComponent("api.pid"), atomically: true, encoding: .utf8)
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell", windowID: 501, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "docker compose up --build", terminalApp: "iTerm2",
                windowID: 501, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock, "kill": Self.killMockScript]) {
            try withEnv(name: "SPACESHIP_RUNTIME_DIR", value: runtimeDir.path) {
                try withEnv(name: "MOCK_KILL_LOG_FILE", value: eventLog.path) {
                    try withEnv(name: "MOCK_ITERM_CLOSE_LOG_FILE", value: eventLog.path) { try orchestrator.stopWorkspace(workspaceID: workspace.id) }
                }
            }
        }

        let events = (try? String(contentsOf: eventLog).split(separator: "\n").map(String.init)) ?? []
        XCTAssertTrue(events.contains("kill -INT -- -8765"))
    }

    func testStopWorkspaceClosesTrackedBrowserTabsWithoutClosingChromeWindow() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let closeLog = root.appendingPathComponent("yabai-close.log")
        let chromeCloseLog = root.appendingPathComponent("chrome-close.log")
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "localhost", targetURL: "http://localhost:3001",
                windowID: 202, role: "browser", orderIndex: 0, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell", windowID: 501, role: "terminal", orderIndex: 1,
                lastSeenAt: "now"))

        // Mocked dependencies: yabai close command and Chrome AppleScript tab-close command.
        // Why: enforce safety contract that stop/restart never closes full Chrome windows, only tracked tabs.
        // Remaining risk: real Chrome could refuse tab close (permissions/profile), but window-close safety still holds.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "YABAI_CLOSE_LOG_FILE", value: closeLog.path) {
                try withEnv(name: "MOCK_CHROME_CLOSE_LOG_FILE", value: chromeCloseLog.path) {
                    try withEnv(name: "MOCK_CHROME_CLOSE_REQUIRE_PREFIX", value: "1") { try orchestrator.stopWorkspace(workspaceID: workspace.id) }
                }
            }
        }

        let closedWindowIDs = (try? String(contentsOf: closeLog).split(separator: "\n").map(String.init)) ?? []
        XCTAssertFalse(closedWindowIDs.contains("202"))
        XCTAssertTrue(closedWindowIDs.contains("501"))
        let closedTabs = try String(contentsOf: chromeCloseLog)
        XCTAssertTrue(closedTabs.contains("http://localhost:3001"))
    }

    func testStopWorkspaceClosesAllLiveDetectedBrowserSessionTabs() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let closeLog = root.appendingPathComponent("yabai-close-live.log")
        let chromeCloseLog = root.appendingPathComponent("chrome-close-live.log")
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(url: "http://localhost:3001")])
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell", windowID: 501, role: "terminal", orderIndex: 1,
                lastSeenAt: "now"))
        let chromeMatches =
            "202\tGoogle Chrome — localhost root\thttp://localhost:3001/\n202\tGoogle Chrome — localhost login\thttp://localhost:3001/login?redirect=/account\n303\tGoogle Chrome — localhost admin\thttp://localhost:3001/admin\n404\tGoogle Chrome — calendar\thttps://calendar.google.com\n"

        // Mocked dependencies: live browser scan and Chrome tab-close commands.
        // Why: ensure stop closes every currently detected matching browser-session tab, not only stale stored rows.
        // Remaining risk: very broad user prefixes can intentionally match many tabs and all matches will be closed.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "YABAI_CLOSE_LOG_FILE", value: closeLog.path) {
                try withEnv(name: "MOCK_CHROME_CLOSE_LOG_FILE", value: chromeCloseLog.path) {
                    try withEnv(name: "MOCK_CHROME_WINDOW_MATCHES", value: chromeMatches) {
                        try orchestrator.stopWorkspace(workspaceID: workspace.id)
                    }
                }
            }
        }

        let closedWindowIDs = (try? String(contentsOf: closeLog).split(separator: "\n").map(String.init)) ?? []
        XCTAssertFalse(closedWindowIDs.contains("202"))
        XCTAssertFalse(closedWindowIDs.contains("303"))
        XCTAssertTrue(closedWindowIDs.contains("501"))
        let closedTabs = try String(contentsOf: chromeCloseLog)
        XCTAssertTrue(closedTabs.contains("http://localhost:3001/"))
        XCTAssertTrue(closedTabs.contains("http://localhost:3001/login?redirect=/account"))
        XCTAssertTrue(closedTabs.contains("http://localhost:3001/admin"))
        XCTAssertFalse(closedTabs.contains("https://calendar.google.com"))
    }

    func testLaunchWorkspaceThrowsWhenRuntimeIndicatorsExist() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 701,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        XCTAssertThrowsError(try orchestrator.launchWorkspace(workspaceID: workspace.id))
    }

    func testLaunchWorkspaceWithoutProcessesDoesNotRequireITerm() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) { try orchestrator.launchWorkspace(workspaceID: workspace.id) }

        XCTAssertTrue(try orchestrator.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
    }

    func testRestartWorkspaceStopsThenLaunches() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell", windowID: 501, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "old", command: "echo old", terminalApp: "iTerm2", windowID: 501,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try orchestrator.restartWorkspace(workspaceID: workspace.id)
        }

        let running = try orchestrator.runningProcesses(workspaceID: workspace.id)
        XCTAssertTrue(running.isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
    }

    func testUpdateWorkspaceSettingsRemovingBrowserSessionsClosesTabsWithoutClosingChromeWindow() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let closeLog = root.appendingPathComponent("browser-settings-yabai-close.log")
        let chromeCloseLog = root.appendingPathComponent("browser-settings-chrome-close.log")
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(url: "http://localhost:3001")])
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "localhost", targetURL: "http://localhost:3001",
                windowID: 202, role: "browser", orderIndex: 0, lastSeenAt: "now"))

        // Mocked dependencies: running-workspace browser reconciliation.
        // Why: ensure clearing browser sessions removes tracked tabs but never closes full Chrome windows.
        // Remaining risk: stale rows with no target URL are dropped from DB but cannot map to a safe tab close.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "YABAI_CLOSE_LOG_FILE", value: closeLog.path) {
                try withEnv(name: "MOCK_CHROME_CLOSE_LOG_FILE", value: chromeCloseLog.path) {
                    try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in settings.browserSessions = [] }
                }
            }
        }

        let closedWindowIDs = (try? String(contentsOf: closeLog).split(separator: "\n").map(String.init)) ?? []
        XCTAssertFalse(closedWindowIDs.contains("202"))
        let closedTabs = try String(contentsOf: chromeCloseLog)
        XCTAssertTrue(closedTabs.contains("http://localhost:3001"))
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).filter { $0.role == "browser" }.isEmpty)
    }

    func testLaunchWorkspaceRejectsArchivedWorkspace() throws {
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try orchestrator.archiveWorkspace(workspaceID: workspace.id)

        // Mocked dependencies are present only to satisfy adapter calls; launch should fail before launching anything.
        // Remaining risk: launch behavior when partially archived/misaligned runtime state exists is covered elsewhere.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            XCTAssertThrowsError(try orchestrator.launchWorkspace(workspaceID: workspace.id))
        }
    }

    func testWorkspaceSettingsAndAccessorsReflectStoreState() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [4100, 4101])
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "job", command: "echo job", terminalApp: nil, windowID: nil, pid: nil,
                status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        // Mocked dependency: `yabai` queries used by settings reconciliation.
        // Why: keep this test focused on persisted settings/accessor behavior.
        // Remaining risk: browser-session behavior with real Chrome is intentionally excluded in this unit.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
                settings.stopScript = "echo workspace-stop"
                settings.processes = [ProcessTemplate(name: "job", command: "echo job")]
                settings.statusChecks = [StatusCheckDefinition(process: "job", command: "echo ok", interval: 30, timeout: 3)]
                settings.browserSessions = []
            }
        }

        let settings = try orchestrator.workspaceSettings(workspaceID: workspace.id)
        XCTAssertEqual(settings?.stopScript, "echo workspace-stop")
        XCTAssertEqual(settings?.processes.first?.name, "job")
        XCTAssertEqual(settings?.statusChecks.first?.process, "job")
        XCTAssertTrue(settings?.browserSessions.isEmpty ?? false)
        XCTAssertEqual(try orchestrator.workspacePorts(workspaceID: workspace.id), [4100, 4101])
        XCTAssertEqual(try orchestrator.runningProcesses(workspaceID: workspace.id).count, 1)
    }

    private final class TestClock {
        private var current: Date

        init(now: Date) { current = now }

        func now() -> Date { current }

        func advance(seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
    }

    private func makeOrchestratorWithWorkspace(
        editor: EditorPreference? = nil, browserWindowScanDebounceInterval: TimeInterval = 10, currentDate: @escaping () -> Date = Date.init
    ) throws -> (SpaceshipOrchestrator, SQLiteStore, ProjectRecord, WorkspaceRecord, URL) {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let configStore = ConfigStore(path: root.appendingPathComponent("config.yaml").path)
        let store = try makeTemporaryStore()
        let orchestrator = SpaceshipOrchestrator(
            store: store, configStore: configStore, browserWindowScanDebounceInterval: browserWindowScanDebounceInterval, currentDate: currentDate)
        if let editor { _ = try orchestrator.updateEditorPreference(editor) }

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        return (orchestrator, store, project, workspace, root)
    }

    private func withMockCommands(_ commands: [String: String], run: () throws -> Void) throws {
        // Mock mechanism: inject command stubs at the front of PATH.
        // Why: emulate yabai/osascript/open behavior deterministically in unit tests.
        // Remaining risk: these tests do not prove interoperability with real binaries or OS-level side effects.
        let directory = try makeTempDirectory()
        for (name, script) in commands {
            let file = directory.appendingPathComponent(name)
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        sharedPathMutationLock.lock()
        defer { sharedPathMutationLock.unlock() }
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let updatedPath = originalPath.isEmpty ? directory.path : "\(directory.path):\(originalPath)"
        setenv("PATH", updatedPath, 1)
        defer { setenv("PATH", originalPath, 1) }

        try run()
    }

    private func withEnv(name: String, value: String, run: () throws -> Void) throws {
        let original = ProcessInfo.processInfo.environment[name]
        setenv(name, value, 1)
        defer { if let original { setenv(name, original, 1) } else { unsetenv(name) } }
        try run()
    }

    private static let orchestratorYabaiMockScript = """
        #!/bin/bash
        # Mock `yabai` CLI used by orchestrator tests.
        # Coverage intent:
        # - space/display/window query payloads
        # - focus success/failure and focused-window toggles via env vars
        # Residual risk: real yabai output and timing can differ significantly under live desktops.
        args="$*"

        focused_id="${YABAI_FOCUSED_ID:-101}"
        focused_app="${YABAI_FOCUSED_APP:-iTerm2}"
        focused_title="${YABAI_FOCUSED_TITLE:-focused}"
        focused_json="{\\"id\\":${focused_id},\\"pid\\":11,\\"app\\":\\"${focused_app}\\",\\"title\\":\\"${focused_title}\\",\\"space\\":1,\\"display\\":1,\\"is-sticky\\":false,\\"is-hidden\\":false,\\"is-visible\\":true,\\"is-native-fullscreen\\":false}"

        if [[ "$args" == *"query --displays"* ]]; then
          echo '[{"index":1},{"index":2}]'
          exit 0
        fi

        if [[ "$args" == *"query --spaces"* ]]; then
          echo '[{"index":3,"display":2},{"index":2,"display":1},{"index":1,"display":1}]'
          exit 0
        fi

        if [[ "$args" == *"query --windows --window"* ]]; then
          if [[ "${YABAI_FOCUSED_NONE:-}" == "1" ]]; then
            echo "no focused window" >&2
            exit 1
          fi
          echo "$focused_json"
          exit 0
        fi

        if [[ "$args" == *"query --windows"* ]]; then
          if [[ -n "${YABAI_WINDOWS_JSON:-}" ]]; then
            echo "$YABAI_WINDOWS_JSON"
          else
            echo '[{"id":101,"pid":11,"app":"iTerm2","title":"shell","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false},{"id":202,"pid":22,"app":"Google Chrome","title":"docs","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]'
          fi
          exit 0
        fi

        if [[ "$args" == *"window --focus"* ]]; then
          id="${@: -1}"
          if [[ "$id" == "999" || ",${YABAI_FOCUS_FAIL_IDS:-}," == *",${id},"* ]]; then
            echo "focus failed" >&2
            exit 1
          fi
          if [[ -n "${YABAI_FOCUS_LOG_FILE:-}" ]]; then
            echo "$id" >> "$YABAI_FOCUS_LOG_FILE"
          fi
          echo "ok"
          exit 0
        fi

        if [[ "$args" == *"window --close"* ]]; then
          id="${@: -1}"
          if [[ -n "${YABAI_CLOSE_LOG_FILE:-}" ]]; then
            echo "$id" >> "$YABAI_CLOSE_LOG_FILE"
          fi
          echo "ok"
          exit 0
        fi

        if [[ "$args" == *"window --minimize"* ]]; then
          echo "ok"
          exit 0
        fi

        echo "unhandled command: $args" >&2
        exit 1
        """

    private static let orchestratorOsaScriptMock = """
        #!/bin/bash
        # Mock `osascript` bridge for iTerm/Chrome paths used by orchestrator tests.
        # Coverage intent:
        # - iTerm availability and window-id responses
        # - Chrome availability/session stubs
        # Residual risk: no validation of true AppleScript syntax/runtime against installed applications.
        script="${*: -1}"
        chrome_active_url_file="${MOCK_CHROME_ACTIVE_URL_FILE:-}"
        if [[ -z "$chrome_active_url_file" && -n "${MOCK_CHROME_FOCUS_LOG_FILE:-}" ]]; then
          chrome_active_url_file="${MOCK_CHROME_FOCUS_LOG_FILE}.active"
        fi
        extract_window_id() {
          local source="$1"
          local extracted
          extracted="$(printf '%s\n' "$source" | awk -F'set requestedWindowID to \"' 'NF>1 { sub(/\".*/, "", $2); print $2; exit }')"
          if [[ -n "$extracted" ]]; then
            echo "$extracted"
            return
          fi
          printf '%s\n' "$source" | grep -Eo 'if id of w is [0-9]+ then' | awk '{print $6}' | head -n1
        }

        if [[ "$script" == *'tell application "iTerm2" to version'* ]]; then
          if [[ "${MOCK_ITERM_UNAVAILABLE:-}" == "1" ]]; then
            echo "iTerm2 unavailable" >&2
            exit 1
          fi
          echo "3.5.0"
          exit 0
        fi

        if [[ "$script" == *'create window with default profile'* ]]; then
          if [[ -n "${MOCK_ITERM_WINDOW_IDS_FILE:-}" ]]; then
            ids="$(cat "$MOCK_ITERM_WINDOW_IDS_FILE" 2>/dev/null)"
            if [[ -z "$ids" ]]; then
              ids="${MOCK_ITERM_WINDOW_ID:-701}"
            fi
            first="${ids%%,*}"
            if [[ "$ids" == *","* ]]; then
              rest="${ids#*,}"
            else
              rest="$first"
            fi
            echo "$rest" > "$MOCK_ITERM_WINDOW_IDS_FILE"
            echo "$first"
            exit 0
          fi
          echo "${MOCK_ITERM_WINDOW_ID:-701}"
          exit 0
        fi

        if [[ "$script" == *'tell application "Google Chrome" to version'* ]]; then
          echo "122"
          exit 0
        fi

        if [[ "$script" == *'set output to ""'* ]]; then
          if [[ -n "${MOCK_CHROME_SCAN_LOG_FILE:-}" ]]; then
            echo "scan" >> "$MOCK_CHROME_SCAN_LOG_FILE"
          fi
          if [[ -n "${MOCK_CHROME_WINDOW_MATCHES:-}" ]]; then
            printf "%b" "$MOCK_CHROME_WINDOW_MATCHES"
          else
            echo ""
          fi
          exit 0
        fi

        if [[ "$script" == *'set u to URL of tab requestedTabIndex of w'* ]]; then
          requested_tab_index="$(printf '%s\n' "$script" | grep -Eo 'set requestedTabIndex to [0-9]+' | awk '{print $4}' | head -n1)"
          focused_window_id="$(extract_window_id "$script")"
          if [[ -n "${MOCK_CHROME_TAB_INDEX_URL:-}" ]]; then
            echo "$MOCK_CHROME_TAB_INDEX_URL"
            exit 0
          fi
          indexed_url=""
          if [[ -n "${MOCK_CHROME_WINDOW_MATCHES:-}" && -n "$focused_window_id" && -n "$requested_tab_index" ]]; then
            indexed_url="$(printf "%b" "$MOCK_CHROME_WINDOW_MATCHES" | awk -F $'\t' -v wid="$focused_window_id" -v target="$requested_tab_index" '($1 == wid) { count += 1; if (count == target) { print $NF; exit } }')"
          fi
          echo "$indexed_url"
          exit 0
        fi

        if [[ "$script" == *'set requestedTabIndex to'* ]]; then
          requested_tab_index="$(printf '%s\n' "$script" | grep -Eo 'set requestedTabIndex to [0-9]+' | awk '{print $4}' | head -n1)"
          focused_window_id="$(extract_window_id "$script")"
          if [[ -n "${MOCK_CHROME_TAB_INDEX_LOG_FILE:-}" ]]; then
            echo "${focused_window_id:-*}\t${requested_tab_index:-0}" >> "$MOCK_CHROME_TAB_INDEX_LOG_FILE"
          fi
          focused_url=""
          if [[ -n "${MOCK_CHROME_WINDOW_MATCHES:-}" && -n "$focused_window_id" && -n "$requested_tab_index" ]]; then
            focused_url="$(printf "%b" "$MOCK_CHROME_WINDOW_MATCHES" | awk -F $'\t' -v wid="$focused_window_id" -v target="$requested_tab_index" '($1 == wid) { count += 1; if (count == target) { print $NF; exit } }')"
          fi
          focused_active_url="$focused_url"
          if [[ -n "${MOCK_CHROME_TAB_INDEX_ACTIVE_URL:-}" ]]; then
            focused_active_url="$MOCK_CHROME_TAB_INDEX_ACTIVE_URL"
          fi
          if [[ -n "$focused_active_url" ]]; then
            if [[ -n "${MOCK_CHROME_FOCUS_LOG_FILE:-}" ]]; then
              echo "$focused_active_url" >> "$MOCK_CHROME_FOCUS_LOG_FILE"
            fi
            if [[ -n "$chrome_active_url_file" ]]; then
              echo "$focused_active_url" > "$chrome_active_url_file"
            fi
          fi
          echo "${MOCK_CHROME_TAB_INDEX_FOCUS_RESULT:-1}"
          exit 0
        fi

        if [[ "$script" == *'set tabCount to count of tabs of w'* && "$script" == *'close tab i of w'* ]]; then
          if [[ "${MOCK_CHROME_CLOSE_REQUIRE_PREFIX:-}" == "1" && "$script" != *'u starts with \"'* ]]; then
            echo "0"
            exit 0
          fi
          close_url="$(printf '%s\n' "$script" | awk -F'u is \"' 'NF>1 { sub(/\".*/, "", $2); print $2; exit }')"
          if [[ -z "$close_url" ]]; then
            close_url="$(printf '%s\n' "$script" | awk -F'u starts with \"' 'NF>1 { sub(/\".*/, "", $2); print $2; exit }')"
          fi
          close_window_id="$(extract_window_id "$script")"
          if [[ -n "${MOCK_CHROME_CLOSE_LOG_FILE:-}" ]]; then
            echo "${close_window_id:-*}\t${close_url}" >> "$MOCK_CHROME_CLOSE_LOG_FILE"
          fi
          echo "${MOCK_CHROME_CLOSE_RESULT:-1}"
          exit 0
        fi

        if [[ "$script" == *'set tabCount to count of tabs of w'* ]]; then
          focused_url="$(printf '%s\n' "$script" | awk -F'starts with \"' 'NF>1 { sub(/\".*/, "", $2); print $2; exit }')"
          if [[ -z "$focused_url" ]]; then
            focused_url="$(printf '%s\n' "$script" | awk -F'u is \"' 'NF>1 { sub(/\".*/, "", $2); print $2; exit }')"
          fi
          focused_window_id="$(extract_window_id "$script")"
          if [[ -n "$focused_window_id" && -n "${MOCK_CHROME_FOCUS_WINDOW_LOG_FILE:-}" ]]; then
            echo "$focused_window_id" >> "$MOCK_CHROME_FOCUS_WINDOW_LOG_FILE"
          fi
          if [[ -n "$focused_url" ]]; then
            if [[ -n "${MOCK_CHROME_FOCUS_LOG_FILE:-}" ]]; then
              echo "$focused_url" >> "$MOCK_CHROME_FOCUS_LOG_FILE"
            fi
            if [[ -n "$chrome_active_url_file" ]]; then
              echo "$focused_url" > "$chrome_active_url_file"
            fi
          fi
          echo "${MOCK_CHROME_FOCUS_RESULT:-1}"
          exit 0
        fi

        if [[ "$script" == *'URL of active tab of front window'* ]]; then
          if [[ -n "$chrome_active_url_file" && -f "$chrome_active_url_file" ]]; then
            cat "$chrome_active_url_file"
          else
            echo "${MOCK_CHROME_ACTIVE_URL:-}"
          fi
          exit 0
        fi

        if [[ "$script" == *'set URL of active tab of newWindow'* ]]; then
          if [[ -n "${MOCK_CHROME_OPEN_LOG_FILE:-}" ]]; then
            echo "$script" >> "$MOCK_CHROME_OPEN_LOG_FILE"
          fi
          echo "88"
          exit 0
        fi

        if [[ "$script" == *'close w'* ]]; then
          close_window_id="$(printf '%s\n' "$script" | grep -Eo 'if id of w is [0-9]+ then' | awk '{print $6}' | head -n1)"
          if [[ -n "${MOCK_ITERM_CLOSE_LOG_FILE:-}" ]]; then
            echo "iterm-close ${close_window_id:-unknown}" >> "$MOCK_ITERM_CLOSE_LOG_FILE"
          fi
          echo ""
          exit 0
        fi

        if [[ "$script" == *'write text'* ]]; then
          echo ""
          exit 0
        fi

        echo ""
        exit 0
        """

    private static let killMockScript = """
        #!/bin/bash
        if [[ -n "${MOCK_KILL_LOG_FILE:-}" ]]; then
          echo "kill $*" >> "$MOCK_KILL_LOG_FILE"
        fi
        exit 0
        """

    private static let openMockScript = """
        #!/bin/bash
        # Mock `open` for editor-launch assertions.
        # Residual risk: launch service resolution and app startup behavior are not exercised.
        if [[ -n "${OPEN_LOG_FILE:-}" ]]; then
          echo "$*" >> "$OPEN_LOG_FILE"
        fi
        exit 0
        """

    private func makeTempGitRepo(name: String) throws -> URL {
        let root = try makeTempDirectory()
        let repo = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init"], cwd: repo.path)
        try "hello".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], cwd: repo.path)
        try runGit(["-c", "user.name=spaceship-test", "-c", "user.email=test@example.com", "commit", "-m", "init"], cwd: repo.path)
        return repo
    }

    private func runGit(_ arguments: [String], cwd: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "GIT_DIR")
        environment.removeValue(forKey: "GIT_WORK_TREE")
        environment.removeValue(forKey: "GIT_INDEX_FILE")
        process.environment = environment
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "spaceship.tests", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(message)"])
        }
    }

    private func runGitAndCapture(_ arguments: [String], cwd: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "GIT_DIR")
        environment.removeValue(forKey: "GIT_WORK_TREE")
        environment.removeValue(forKey: "GIT_INDEX_FILE")
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "spaceship.tests", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(message)"])
        }
        return String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func parseWorktreePaths(_ porcelainOutput: String) -> Set<String> {
        Set(
            porcelainOutput.split(separator: "\n").compactMap { rawLine -> String? in
                let line = String(rawLine)
                guard line.hasPrefix("worktree ") else { return nil }
                let path = String(line.dropFirst("worktree ".count))
                return normalizeTestPath(path)
            })
    }

    private func normalizeTestPath(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
}
