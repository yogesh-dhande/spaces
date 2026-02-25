import XCTest

@testable import streamctl

final class OrchestratorTests: XCTestCase {
    // Tests workspace window refresh interval is positive by arranging representative inputs and asserting the expected result.
    func testWorkspaceWindowRefreshIntervalIsPositive() {
        XCTAssertGreaterThan(PollingConstants.workspaceWindowRefreshInterval, 0)
    }

    // Tests worktree discovery interval is positive by arranging representative inputs and asserting the expected result.
    func testWorktreeDiscoveryIntervalIsPositive() {
        XCTAssertGreaterThan(PollingConstants.worktreeDiscoveryInterval, 0)
    }

    // Tests update editor preference persists to db by arranging representative inputs and asserting the expected result.
    func testUpdateEditorPreferencePersistsToDB() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        _ = try orchestrator.updateEditorPreference(.cursor)
        XCTAssertEqual(try store.appConfig().editor, .cursor)

        _ = try orchestrator.updateEditorPreference(nil)
        XCTAssertNil(try store.appConfig().editor)
    }

    // Tests next window order index uses role offset and max by arranging representative inputs and asserting the expected result.
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

        let nextTerminal = MuxyOrchestrator.nextWindowOrderIndex(existing: windows, role: "terminal", orderOffset: 200)
        XCTAssertEqual(nextTerminal, 206)

        let nextEditor = MuxyOrchestrator.nextWindowOrderIndex(existing: windows, role: "editor", orderOffset: 100)
        XCTAssertEqual(nextEditor, 100)
    }

    // Tests add project by cloning uses repos root and repo name by arranging representative inputs and asserting the expected result.
    func testAddProjectByCloningUsesReposRootAndRepoName() throws {
        let fixture = try makeTempGitRepo(name: "sample-repo")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(gitURL: fixture.path)

        let expected = reposRoot.appendingPathComponent("sample-repo", isDirectory: true).path
        XCTAssertEqual(project.dir, expected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected))
        XCTAssertEqual(
            try runGitAndCapture(["rev-parse", "--is-bare-repository"], cwd: project.dir).trimmingCharacters(in: .whitespacesAndNewlines),
            "true")
        let defaultWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first(where: \.isDefault))
        XCTAssertEqual(defaultWorkspace.name, "main")
        XCTAssertEqual(defaultWorkspace.branch, "main")
        XCTAssertEqual(defaultWorkspace.dir, workspacesRoot.appendingPathComponent("sample-repo/main", isDirectory: true).path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(defaultWorkspace.dir)/README.md"))
    }

    // Tests add project by cloning strips git suffix from repo name by arranging representative inputs and asserting the expected result.
    func testAddProjectByCloningStripsGitSuffixFromRepoName() throws {
        let fixture = try makeTempGitRepo(name: "source.git")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(gitURL: fixture.path)

        let expected = reposRoot.appendingPathComponent("source", isDirectory: true).path
        XCTAssertEqual(project.dir, expected)
        XCTAssertEqual(project.name, "source")
        XCTAssertEqual(
            try runGitAndCapture(["rev-parse", "--is-bare-repository"], cwd: project.dir).trimmingCharacters(in: .whitespacesAndNewlines),
            "true")
    }

    // Tests add project by cloning uses master branch when main is unavailable by arranging representative inputs and asserting the expected result.
    func testAddProjectByCloningUsesMasterWhenMainMissing() throws {
        let fixture = try makeTempGitRepo(name: "master-only", initialBranch: "master")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(gitURL: fixture.path)
        let defaultWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first(where: \.isDefault))

        XCTAssertEqual(project.defaultBranch, "master")
        XCTAssertEqual(defaultWorkspace.name, "master")
        XCTAssertEqual(defaultWorkspace.branch, "master")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(defaultWorkspace.dir)/README.md"))
    }

    // Tests remove project deletes managed git project directory by arranging representative inputs and asserting the expected result.
    func testRemoveProjectDeletesManagedGitProjectDirectory() throws {
        let fixture = try makeTempGitRepo(name: "managed")
        let root = try makeTempDirectory()
        let projectsRoot = root.appendingPathComponent("repos", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, projectsRootDirectory: projectsRoot)

        let project = try orchestrator.addProject(gitURL: fixture.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.dir))

        try orchestrator.removeProject(dir: project.dir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: project.dir))
        XCTAssertNil(try store.project(dir: project.dir))
        XCTAssertTrue(try orchestrator.listProjects().isEmpty)
    }

    // Tests remove project deletes managed workspace directories for managed git project by arranging representative inputs and asserting the expected result.
    func testRemoveProjectDeletesManagedWorkspaceDirectoriesForManagedGitProject() throws {
        let fixture = try makeTempGitRepo(name: "managed-with-workspace")
        let root = try makeTempDirectory()
        let projectsRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(
            store: store, projectsRootDirectory: projectsRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(gitURL: fixture.path)
        let projectWorkspaceRoot = workspacesRoot.appendingPathComponent(project.name, isDirectory: true)
        let workspaceDir = projectWorkspaceRoot.appendingPathComponent("main", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceDir.path))
        XCTAssertTrue(workspaceDir.path.hasPrefix(workspacesRoot.path))

        try orchestrator.removeProject(dir: project.dir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectWorkspaceRoot.path))
    }

    // Tests remove project does not delete unmanaged project directory but deletes managed workspace directories by arranging representative inputs and asserting the expected result.
    func testRemoveProjectDoesNotDeleteUnmanagedProjectDirectoryButDeletesManagedWorkspaceDirectories() throws {
        let projectDir = try makeTempDirectory()
        try runGit(["init"], cwd: projectDir.path)
        try "hello".write(to: projectDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], cwd: projectDir.path)
        try runGit(["-c", "user.name=muxy-test", "-c", "user.email=test@example.com", "commit", "-m", "init"], cwd: projectDir.path)

        let root = try makeTempDirectory()
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(
            store: store, projectsRootDirectory: projectsRoot, workspacesRootDirectory: workspacesRoot)

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

    // Tests archive workspace does not delete project directory for non git project by arranging representative inputs and asserting the expected result.
    func testArchiveWorkspaceDoesNotDeleteProjectDirectoryForNonGitProject() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let marker = projectDir.appendingPathComponent("marker.txt")
        try "marker".write(to: marker, atomically: true, encoding: .utf8)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        try orchestrator.archiveWorkspace(workspaceID: workspace.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: project.dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let archivedWorkspace = try store.workspace(id: workspace.id)
        XCTAssertEqual(archivedWorkspace?.isArchived, true)
    }

    // Tests create workspace for non git project allocates ports by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceForNonGitProjectAllocatesPorts() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        XCTAssertEqual(workspace.dir, projectDir.path)
        XCTAssertFalse(workspace.isArchived)
        XCTAssertEqual(try orchestrator.workspacePorts(workspaceID: workspace.id).count, 0)
    }

    // Tests create workspace rejects directory name override for non git project by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceRejectsDirectoryNameOverrideForNonGitProject() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id, name: "feature", directoryName: "feature_dir")) { error in
            XCTAssertTrue(error.localizedDescription.contains("only supported for git projects"))
        }
    }

    // Tests workspace stop script is seeded from project and can be overridden by arranging representative inputs and asserting the expected result.
    func testWorkspaceStopScriptIsSeededFromProjectAndCanBeOverridden() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

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

    // Tests suggested workspace name matches auto generated dirname by arranging representative inputs and asserting the expected result.
    func testSuggestedWorkspaceNameMatchesAutoGeneratedDirname() throws {
        let repo = try makeTempGitRepo(name: "workspace-name-default")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let suggested = try orchestrator.suggestedWorkspaceName(projectID: project.id)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: suggested, branch: suggested)

        XCTAssertEqual(workspace.name, suggested)
        XCTAssertEqual(workspace.dirname, suggested)
        XCTAssertEqual(workspace.branch, suggested)

        let nextSuggested = try orchestrator.suggestedWorkspaceName(projectID: project.id)
        XCTAssertNotEqual(nextSuggested, suggested)
    }

    // Tests static workspace name suggestion chooses first available food name by arranging representative inputs and asserting the expected result.
    func testSuggestWorkspaceNameUsesFirstAvailableCandidate() {
        XCTAssertEqual(MuxyOrchestrator.suggestWorkspaceName(existingNames: Set<String>()), "almond")
        XCTAssertEqual(MuxyOrchestrator.suggestWorkspaceName(existingNames: Set(["almond"])), "anchovy")
    }

    // Tests create workspace uses custom name with auto generated dirname by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceUsesCustomNameWithAutoGeneratedDirname() throws {
        let repo = try makeTempGitRepo(name: "workspace-name-custom")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let suggested = try orchestrator.suggestedWorkspaceName(projectID: project.id)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature-name", branch: "feature-branch")

        XCTAssertEqual(workspace.name, "feature-name")
        XCTAssertEqual(workspace.branch, "feature-branch")
        XCTAssertEqual(workspace.dirname, suggested)
    }

    // Tests create workspace uses provided directory name for git project by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceUsesProvidedDirectoryNameForGitProject() throws {
        let repo = try makeTempGitRepo(name: "workspace-name-override")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(
            projectID: project.id, name: "feature-name", branch: "feature-branch", directoryName: "feature_branch_1")

        XCTAssertEqual(workspace.dirname, "feature_branch_1")
        XCTAssertTrue(workspace.dir.hasSuffix("/feature_branch_1"))
    }

    // Tests create workspace rejects directory name with invalid characters by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceRejectsDirectoryNameWithInvalidCharacters() throws {
        let repo = try makeTempGitRepo(name: "workspace-name-invalid-dirname")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        XCTAssertThrowsError(
            try orchestrator.createWorkspace(projectID: project.id, name: "feature-name", branch: "feature-branch", directoryName: "feature/branch")
        ) { error in XCTAssertTrue(error.localizedDescription.contains("letters, numbers, '-', and '_'")) }
    }

    // Tests create workspace rejects directory name with spaces by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceRejectsDirectoryNameWithSpaces() throws {
        let repo = try makeTempGitRepo(name: "workspace-name-space-dirname")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        XCTAssertThrowsError(
            try orchestrator.createWorkspace(projectID: project.id, name: "feature-name", branch: "feature-branch", directoryName: "feature branch")
        ) { error in XCTAssertTrue(error.localizedDescription.contains("cannot contain spaces")) }
    }

    // Tests create workspace uses selected target branch as base for new branch by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceUsesSelectedTargetBranchAsBaseForNewBranch() throws {
        let repo = try makeTempGitRepo(name: "workspace-target-branch")
        try runGit(["checkout", "-b", "develop"], cwd: repo.path)
        try "target".write(to: repo.appendingPathComponent("TARGET.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "TARGET.txt"], cwd: repo.path)
        try runGit(["-c", "user.name=muxy-test", "-c", "user.email=test@example.com", "commit", "-m", "target"], cwd: repo.path)
        try runGit(["checkout", "main"], cwd: repo.path)

        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(
            projectID: project.id, name: "feature-workspace", branch: "feature-branch", targetBranch: "develop")

        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.dir + "/TARGET.txt"))
        XCTAssertEqual(workspace.targetBranch, "develop")
    }

    // Tests create workspace defaults target branch to project default when omitted by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceDefaultsTargetBranchToProjectDefaultBranch() throws {
        let repo = try makeTempGitRepo(name: "workspace-default-target")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let suggested = try orchestrator.suggestedWorkspaceName(projectID: project.id)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: suggested, branch: suggested)

        XCTAssertEqual(workspace.name, suggested)
        XCTAssertEqual(workspace.branch, suggested)
        XCTAssertEqual(workspace.targetBranch, project.defaultBranch)
    }

    // Tests deferred workspace setup updates state and runs setup script when requested by arranging representative inputs and asserting the expected result.
    func testDeferredWorkspaceSetupUpdatesStateAndRunsSetupScript() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.setupScript = "echo ready > .muxy-setup-marker"
        }

        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature", runSetupScript: false)
        let pendingState = try orchestrator.workspaceSetupState(workspaceID: workspace.id)
        XCTAssertEqual(pendingState.status, .pending)

        let markerURL = URL(fileURLWithPath: workspace.dir, isDirectory: true).appending(path: ".muxy-setup-marker")
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))

        try orchestrator.runWorkspaceSetup(workspaceID: workspace.id)
        let succeededState = try orchestrator.workspaceSetupState(workspaceID: workspace.id)
        XCTAssertEqual(succeededState.status, .succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    // Tests list workspaces includes branch metadata by arranging representative inputs and asserting the expected result.
    func testListWorkspacesIncludesBranchMetadata() throws {
        let repo = try makeTempGitRepo(name: "workspace-branch-list")
        try runGit(["checkout", "-b", "develop"], cwd: repo.path)
        try runGit(["checkout", "main"], cwd: repo.path)
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        _ = try orchestrator.createWorkspace(
            projectID: project.id, name: "feature-branch", branch: "feature-branch", targetBranch: "develop")

        let workspaces = try orchestrator.listWorkspaces(projectID: project.id, includeArchived: true)
        let feature = try XCTUnwrap(workspaces.first(where: { $0.name == "feature-branch" }))
        XCTAssertEqual(feature.branch, "feature-branch")
        XCTAssertEqual(feature.targetBranch, "develop")
    }

    // Tests create workspace revives archived workspace by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceRevivesArchivedWorkspace() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let created = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try orchestrator.archiveWorkspace(workspaceID: created.id)

        let revived = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let persisted = try store.workspace(id: revived.id)

        XCTAssertEqual(revived.id, created.id)
        XCTAssertEqual(persisted?.isArchived, false)
        XCTAssertEqual(try orchestrator.workspacePorts(workspaceID: revived.id).count, 0)
    }

    // Tests list workspaces honors include archived flag by arranging representative inputs and asserting the expected result.
    func testListWorkspacesHonorsIncludeArchivedFlag() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try orchestrator.archiveWorkspace(workspaceID: workspace.id)

        let activeOnly = try orchestrator.listWorkspaces(projectID: project.id, includeArchived: false)
        XCTAssertEqual(activeOnly.map(\.name), ["default"])

        let all = try orchestrator.listWorkspaces(projectID: project.id, includeArchived: true)
        XCTAssertEqual(Set(all.map(\.name)), Set(["default", "feature"]))
    }

    // Tests archive workspace removes git worktree registration by arranging representative inputs and asserting the expected result.
    func testArchiveWorkspaceRemovesGitWorktreeRegistration() throws {
        let repo = try makeTempGitRepo(name: "workspace-archive-git-worktree-remove")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

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

    // Tests archive workspace gracefully handles missing worktree directory by arranging representative inputs and asserting the expected result.
    func testArchiveWorkspaceGracefullyHandlesMissingWorktreeDirectory() throws {
        let repo = try makeTempGitRepo(name: "workspace-archive-missing-worktree")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let marker = root.appendingPathComponent("archive-stop-script-marker.txt")
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature-missing", branch: "feature-missing")
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: "echo ran > '\(marker.path)'")

        try FileManager.default.removeItem(atPath: workspace.dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.dir))

        try orchestrator.archiveWorkspace(workspaceID: workspace.id)

        let archivedWorkspace = try store.workspace(id: workspace.id)
        XCTAssertEqual(archivedWorkspace?.isArchived, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    // Tests gui shortcuts and active workspace round trip by arranging representative inputs and asserting the expected result.
    func testGUIShortcutsAndActiveWorkspaceRoundTrip() throws {
        let root = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

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

    // Tests run status checks persists results for matching processes by arranging representative inputs and asserting the expected result.
    func testRunStatusChecksPersistsResultsForMatchingProcesses() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

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
        XCTAssertEqual(byName["api"], .passed)
        XCTAssertEqual(byName["failing"], .failed)

        let persisted = try orchestrator.statusResults(processID: runningProcess.id)
        XCTAssertEqual(persisted.count, 2)
    }

    // Tests run status checks due only respects interval by arranging representative inputs and asserting the expected result.
    func testRunStatusChecksDueOnlyRespectsInterval() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceStatusChecks(
            workspaceID: workspace.id,
            checks: [
                StatusCheckDefinition(name: "health", process: "api", command: "echo ok", interval: 60, timeout: 2, onFail: .none),
            ])
        let runningProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "echo api", terminalApp: nil, windowID: nil, pid: 9000,
            status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: runningProcess)

        let now = Date()
        let firstRun = try orchestrator.runStatusChecks(workspaceID: workspace.id, dueOnly: true, now: now)
        XCTAssertEqual(firstRun.count, 1)

        let secondRunWithinInterval = try orchestrator.runStatusChecks(
            workspaceID: workspace.id, dueOnly: true, now: now.addingTimeInterval(5))
        XCTAssertTrue(secondRunWithinInterval.isEmpty)

        let forcedRun = try orchestrator.runStatusChecks(
            workspaceID: workspace.id, dueOnly: false, now: now.addingTimeInterval(5))
        XCTAssertEqual(forcedRun.count, 1)
    }

    // Tests run due status checks for running workspaces runs checks by arranging representative inputs and asserting the expected result.
    func testRunDueStatusChecksForRunningWorkspacesRunsChecks() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: ISO8601DateFormatter().string(from: Date()))
        try store.setWorkspaceStatusChecks(
            workspaceID: workspace.id,
            checks: [
                StatusCheckDefinition(name: "health", process: "api", command: "echo ok", interval: 10, timeout: 2, onFail: .none),
            ])
        let runningProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "echo api", terminalApp: nil, windowID: nil, pid: 9000,
            status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: runningProcess)

        let didRunChecks = try orchestrator.runDueStatusChecksForRunningWorkspaces(now: Date())
        XCTAssertTrue(didRunChecks)

        let persisted = try orchestrator.statusResults(processID: runningProcess.id)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.checkName, "health")
        XCTAssertEqual(persisted.first?.status, .passed)
    }

    // Tests status check on fail none does nothing by arranging representative inputs and asserting the expected result.
    func testStatusCheckOnFailNoneDoesNothing() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceStatusChecks(
            workspaceID: workspace.id,
            checks: [
                StatusCheckDefinition(process: "api", command: "echo failed && exit 1", interval: 10, timeout: 2, onFail: .none),
            ])
        let runningProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "echo api", terminalApp: nil, windowID: nil, pid: 9000,
            status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: runningProcess)

        let results = try orchestrator.runStatusChecks(workspaceID: workspace.id)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.status, .failed)
        
        // Process should still be running (no restart)
        let currentProcess = try store.runningProcesses(workspaceID: workspace.id).first!
        XCTAssertEqual(currentProcess.status, .running)
        XCTAssertEqual(currentProcess.pid, 9000)
    }

    // Tests status check on fail notify shows notification by arranging representative inputs and asserting the expected result.
    func testStatusCheckOnFailNotifyShowsNotification() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceStatusChecks(
            workspaceID: workspace.id,
            checks: [
                StatusCheckDefinition(name: "health", process: "api", command: "echo unhealthy && exit 1", interval: 10, timeout: 2, onFail: .notify),
            ])
        let runningProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "echo api", terminalApp: nil, windowID: nil, pid: 9000,
            status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: runningProcess)

        let results = try orchestrator.runStatusChecks(workspaceID: workspace.id)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.status, .failed)
        
        // Process should still be running (no restart)
        let currentProcess = try store.runningProcesses(workspaceID: workspace.id).first!
        XCTAssertEqual(currentProcess.status, .running)
        XCTAssertEqual(currentProcess.pid, 9000)
        
        // Note: We can't easily test the actual notification delivery without complex mocking
        // but we can verify the process wasn't restarted, which is the key behavior
    }

    // Tests status check on fail restart restarts process by arranging representative inputs and asserting the expected result.
    func testStatusCheckOnFailRestartRestartsProcess() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        
        // Use mock iTerm2 adapter to prevent actual terminal windows from opening
        let mockIterm = MockIterm2Adapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceStatusChecks(
            workspaceID: workspace.id,
            checks: [
                StatusCheckDefinition(name: "health", process: "api", command: "echo crashed && exit 1", interval: 10, timeout: 2, onFail: .restart),
            ])
        let runningProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "iTerm2", windowID: 123, pid: 9000,
            status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: runningProcess)

        // Create a mock PID file to simulate the new PID after restart
        // The PID file is stored in ~/.muxy/runtime/<workspace-id>/
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let runtimeRoot = homeDir.appendingPathComponent(".muxy").appendingPathComponent("runtime")
        let workspaceRuntime = runtimeRoot.appendingPathComponent(workspace.id, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRuntime, withIntermediateDirectories: true)
        let pidFileURL = workspaceRuntime.appendingPathComponent("api.pid")
        try "10001".write(to: pidFileURL, atomically: true, encoding: .utf8)

        let results = try orchestrator.runStatusChecks(workspaceID: workspace.id)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.status, .failed)
        
        // Verify iTerm2 was called to run in existing window (not create new one)
        XCTAssertEqual(mockIterm.openWindowAndRunCallCount, 0)
        XCTAssertEqual(mockIterm.runInWindowCallCount, 1)
        XCTAssertEqual(mockIterm.lastWindowID, 123)
        XCTAssertTrue(mockIterm.lastCommand!.contains("cd \"\(workspace.dir)\""))
        XCTAssertTrue(mockIterm.lastCommand!.contains("npm start"))
        
        // Verify process was restarted in the same window
        let currentProcesses = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(currentProcesses.count, 1)
        let currentProcess = currentProcesses.first!
        XCTAssertEqual(currentProcess.status, .running)
        XCTAssertEqual(currentProcess.windowID, 123) // Should have same window ID
        XCTAssertEqual(currentProcess.pid, 10001) // PID should be updated from PID file
    }

    // Tests status check on fail restart with missing pid does not crash by arranging representative inputs and asserting the expected result.
    func testStatusCheckOnFailRestartWithMissingPidDoesNotCrash() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        
        // Use mock iTerm2 adapter to prevent actual terminal windows from opening
        let mockIterm = MockIterm2Adapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceStatusChecks(
            workspaceID: workspace.id,
            checks: [
                StatusCheckDefinition(process: "api", command: "echo failed && exit 1", interval: 10, timeout: 2, onFail: .restart),
            ])
        let runningProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "iTerm2", windowID: 123, pid: nil,
            status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: runningProcess)

        // Should not crash even with missing PID
        XCTAssertNoThrow(try orchestrator.runStatusChecks(workspaceID: workspace.id))
        
        // Should still attempt to restart - verify iTerm2 was called
        XCTAssertEqual(mockIterm.openWindowAndRunCallCount, 0) // Should not create new window
        XCTAssertEqual(mockIterm.runInWindowCallCount, 1) // Should reuse existing window
        XCTAssertEqual(mockIterm.lastWindowID, 123) // Should use existing window
        XCTAssertTrue(mockIterm.lastCommand!.contains("cd \"\(workspace.dir)\""))
        XCTAssertTrue(mockIterm.lastCommand!.contains("npm start"))
        
        // When PID is missing, the restart logic should still attempt to restart
        // The process should have the same window ID because we reuse windows
        let currentProcesses = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(currentProcesses.count, 1)
        let currentProcess = currentProcesses.first!
        XCTAssertEqual(currentProcess.status, .running)
        // Should have same window ID because we reuse windows
        XCTAssertEqual(currentProcess.windowID, 123)
    }

    // Tests check and update process statuses marks dead process as exited by arranging representative inputs and asserting the expected result.
    func testCheckAndUpdateProcessStatusesMarksDeadProcessAsExited() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        
        // Create a process with a PID that doesn't exist
        let deadProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", 
            terminalApp: "iTerm2", windowID: 123, pid: 99999, status: .running, logPath: nil, 
            lastOutputAt: nil, startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20)), exitedAt: nil)
        try store.upsert(runningProcess: deadProcess)
        
        let didUpdate = try orchestrator.checkAndUpdateProcessStatuses()
        
        XCTAssertTrue(didUpdate)
        let updated = try store.runningProcesses(workspaceID: workspace.id).first
        XCTAssertEqual(updated?.status, .exited)
        XCTAssertNotNil(updated?.exitedAt)
    }

    // Tests that status check results are marked as red when a process exits, so they don't stay green.
    func testCheckAndUpdateProcessStatusesMarksStatusResultsAsFailedOnExit() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Create a dead process with a previously-green status result
        let deadProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start",
            terminalApp: "iTerm2", windowID: 123, pid: 99999, status: .running, logPath: nil,
            lastOutputAt: nil, startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20)), exitedAt: nil)
        try store.upsert(runningProcess: deadProcess)

        // Simulate a previously-passing status check result
        let greenResult = StatusResult(processID: deadProcess.id, checkName: "health", status: .passed, message: nil, lastRunAt: ISO8601DateFormatter().string(from: Date()))
        try store.upsert(statusResult: greenResult)

        let didUpdate = try orchestrator.checkAndUpdateProcessStatuses()

        XCTAssertTrue(didUpdate)
        let results = try store.statusResults(processID: deadProcess.id)
        XCTAssertEqual(results.count, 1)
        // Status result must be red after process exit — not stale green
        XCTAssertEqual(results.first?.status, .failed)
    }

    // Tests check and update process statuses skips newly started processes by arranging representative inputs and asserting the expected result.
    func testCheckAndUpdateProcessStatusesSkipsNewlyStartedProcesses() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        
        // Create a process that just started (within grace period)
        let newProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", 
            terminalApp: "iTerm2", windowID: 123, pid: 99999, status: .running, logPath: nil, 
            lastOutputAt: nil, startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5)), exitedAt: nil)
        try store.upsert(runningProcess: newProcess)
        
        let didUpdate = try orchestrator.checkAndUpdateProcessStatuses()
        
        // Should not update because process is within grace period
        XCTAssertFalse(didUpdate)
        let unchanged = try store.runningProcesses(workspaceID: workspace.id).first
        XCTAssertEqual(unchanged?.status, .running)
        XCTAssertNil(unchanged?.exitedAt)
    }
    
    // Tests check and update process statuses skips processes without pid by arranging representative inputs and asserting the expected result.
    func testCheckAndUpdateProcessStatusesSkipsProcessesWithoutPID() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        
        // Create a process without a PID (still starting up)
        let noPidProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", 
            terminalApp: "iTerm2", windowID: 123, pid: nil, status: .running, logPath: nil, 
            lastOutputAt: nil, startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20)), exitedAt: nil)
        try store.upsert(runningProcess: noPidProcess)
        
        let didUpdate = try orchestrator.checkAndUpdateProcessStatuses()
        
        // Should not update because process has no PID to check
        XCTAssertFalse(didUpdate)
        let unchanged = try store.runningProcesses(workspaceID: workspace.id).first
        XCTAssertEqual(unchanged?.status, .running)
    }
    
    // Tests check and update process statuses only checks running processes by arranging representative inputs and asserting the expected result.
    func testCheckAndUpdateProcessStatusesOnlyChecksRunningProcesses() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        
        // Create an already-exited process
        let exitedProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", 
            terminalApp: "iTerm2", windowID: 123, pid: 99999, status: .exited, logPath: nil, 
            lastOutputAt: nil, startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20)), 
            exitedAt: ISO8601DateFormatter().string(from: Date()))
        try store.upsert(runningProcess: exitedProcess)
        
        let didUpdate = try orchestrator.checkAndUpdateProcessStatuses()
        
        // Should not check or update already-exited processes
        XCTAssertFalse(didUpdate)
    }

    // Tests create workspace throws for unknown project by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceThrowsForUnknownProject() throws {
        let root = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: "missing", name: "feature"))
    }

    // Tests create workspace for git project requires branch by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceForGitProjectRequiresBranch() throws {
        let repo = try makeTempGitRepo(name: "workspace-requires-branch")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)

        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id, name: "workspace")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Branch name is required"))
        }
    }

    // Tests workspace name can be updated after creation by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceNameUpdatesWorkspaceRecord() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        try orchestrator.updateWorkspaceName(workspaceID: workspace.id, name: "feature-auth")

        let updated = try XCTUnwrap(store.workspace(id: workspace.id))
        XCTAssertEqual(updated.name, "feature-auth")
    }

    // Tests workspace name update rejects duplicates by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceNameRejectsDuplicateWorkspaceName() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let one = try orchestrator.createWorkspace(projectID: project.id, name: "feature-one")
        _ = try orchestrator.createWorkspace(projectID: project.id, name: "feature-two")

        XCTAssertThrowsError(try orchestrator.updateWorkspaceName(workspaceID: one.id, name: "feature-two")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Workspace already exists"))
        }
    }

    // Tests default workspace name cannot be changed by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceNameRejectsDefaultWorkspaceRename() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let defaultWorkspace = try XCTUnwrap(store.workspace(projectID: project.id, name: "default"))

        XCTAssertThrowsError(try orchestrator.updateWorkspaceName(workspaceID: defaultWorkspace.id, name: "renamed-default")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Default workspace name cannot be changed"))
        }
    }

    // Tests workspace metadata update can change title, branch, directory name, and tooltip by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataUpdatesTitleBranchDirectoryNameAndTooltip() throws {
        let repo = try makeTempGitRepo(name: "workspace-update-metadata")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature", branch: "feature-start")

        try orchestrator.updateWorkspaceMetadata(
            workspaceID: workspace.id, title: "feature-auth", branch: "feature-auth", directoryName: "feature_auth", tooltip: .some("Reviewing OAuth flow"))

        let updated = try XCTUnwrap(store.workspace(id: workspace.id))
        XCTAssertEqual(updated.name, "feature-auth")
        XCTAssertEqual(updated.branch, "feature-auth")
        XCTAssertEqual(updated.dirname, "feature_auth")
        XCTAssertEqual(updated.tooltip, "Reviewing OAuth flow")
        XCTAssertEqual(
            try runGitAndCapture(["rev-parse", "--abbrev-ref", "HEAD"], cwd: workspace.dir).trimmingCharacters(in: .whitespacesAndNewlines),
            "feature-auth")
        let branches = try runGitAndCapture(["branch", "--format=%(refname:short)"], cwd: project.dir)
        XCTAssertTrue(branches.split(separator: "\n").contains("feature-auth"))
        XCTAssertFalse(branches.split(separator: "\n").contains("feature-start"))
    }

    // Tests workspace metadata update can clear tooltip by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataClearsTooltip() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, tooltip: .some("Investigating timeout regression"))

        try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, tooltip: .some(nil))

        let updated = try XCTUnwrap(store.workspace(id: workspace.id))
        XCTAssertNil(updated.tooltip)
    }

    // Tests workspace metadata update rejects renaming protected main branch by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataRejectsRenamingProtectedMainBranch() throws {
        let repo = try makeTempGitRepo(name: "workspace-update-main-protected")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        let mainWorkspace = try XCTUnwrap(store.workspace(projectID: project.id, name: "default"))

        XCTAssertEqual(mainWorkspace.branch, "main")
        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: mainWorkspace.id, branch: "main-renamed")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Protected branches main/master cannot be renamed"))
        }

        let updated = try XCTUnwrap(store.workspace(id: mainWorkspace.id))
        XCTAssertEqual(updated.branch, "main")
        XCTAssertEqual(
            try runGitAndCapture(["rev-parse", "--abbrev-ref", "HEAD"], cwd: mainWorkspace.dir).trimmingCharacters(in: .whitespacesAndNewlines),
            "main")
    }

    // Tests workspace metadata update rejects renaming protected master branch by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataRejectsRenamingProtectedMasterBranch() throws {
        let repo = try makeTempGitRepo(name: "workspace-update-master-protected", initialBranch: "master")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        let masterWorkspace = try XCTUnwrap(store.workspace(projectID: project.id, name: "default"))

        XCTAssertEqual(masterWorkspace.branch, "master")
        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: masterWorkspace.id, branch: "master-renamed")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Protected branches main/master cannot be renamed"))
        }

        let updated = try XCTUnwrap(store.workspace(id: masterWorkspace.id))
        XCTAssertEqual(updated.branch, "master")
        XCTAssertEqual(
            try runGitAndCapture(["rev-parse", "--abbrev-ref", "HEAD"], cwd: masterWorkspace.dir).trimmingCharacters(in: .whitespacesAndNewlines),
            "master")
    }

    // Tests open workspace editor throws when editor is not configured by arranging representative inputs and asserting the expected result.
    func testOpenWorkspaceEditorThrowsWhenEditorIsNotConfigured() throws {
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace()

        XCTAssertThrowsError(try orchestrator.openWorkspaceEditor(workspaceID: workspace.id))
    }

    // Tests open workspace editor does not track editor windows by arranging representative inputs and asserting the expected result.
    func testOpenWorkspaceEditorDoesNotTrackEditorWindows() throws {
        let (orchestrator, _, _, workspace, root) = try makeOrchestratorWithWorkspace(editor: .vscode)
        let openLog = root.appendingPathComponent("open.log")

        // Mocked dependency: `open`.
        // Why: verify editor launch call without touching real GUI apps.
        // Remaining risk: real editor startup behavior is outside this unit test.
        try withMockCommands(["open": Self.openMockScript]) {
            try withEnv(name: "OPEN_LOG_FILE", value: openLog.path) { try orchestrator.openWorkspaceEditor(workspaceID: workspace.id) }
        }

        let windows = try orchestrator.windows(workspaceID: workspace.id)
        let editorWindows = windows.filter { $0.role == "editor" }
        XCTAssertEqual(editorWindows.count, 0)

        let openArgs = try String(contentsOf: openLog)
        XCTAssertTrue(openArgs.contains("-a Visual Studio Code"))
        XCTAssertTrue(openArgs.contains(workspace.dir))
    }

    // Tests open workspace editor does not require yabai by arranging representative inputs and asserting the expected result.
    func testOpenWorkspaceEditorDoesNotRequireYabai() throws {
        let (orchestrator, _, _, workspace, root) = try makeOrchestratorWithWorkspace(editor: .vscode)
        let openLog = root.appendingPathComponent("open-no-yabai.log")

        try withMockCommands(["open": Self.openMockScript]) {
            try withEnv(name: "OPEN_LOG_FILE", value: openLog.path) { try orchestrator.openWorkspaceEditor(workspaceID: workspace.id) }
        }

        let windows = try orchestrator.windows(workspaceID: workspace.id)
        let editorWindows = windows.filter { $0.role == "editor" }
        XCTAssertEqual(editorWindows.count, 0)

        let openArgs = try String(contentsOf: openLog)
        XCTAssertTrue(openArgs.contains("-a Visual Studio Code"))
    }

    // Tests open workspace terminal attaches focused terminal window by arranging representative inputs and asserting the expected result.
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

    // Tests that opening a terminal for a not-running workspace marks it as running so the UI shows Restart instead of Launch.
    func testOpenWorkspaceTerminalMarksWorkspaceAsRunning() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        XCTAssertEqual(workspace.isRunning, false)

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "YABAI_FOCUSED_ID", value: "777") {
                try withEnv(name: "YABAI_FOCUSED_APP", value: "iTerm2") { try orchestrator.openWorkspaceTerminal(workspaceID: workspace.id) }
            }
        }

        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
    }

    // Tests open workspace terminal throws when i term is unavailable by arranging representative inputs and asserting the expected result.
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

    // Tests focus workspace skips failed window and sets active workspace by arranging representative inputs and asserting the expected result.
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

    // Tests focus workspace window prefers i term session/tab focus for terminal windows by arranging representative inputs and asserting the expected result.
    func testFocusWorkspaceWindowPrefersItermSessionFocusForTerminal() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let yabaiFocusLog = root.appendingPathComponent("terminal-yabai-focus.log")
        let itermFocusLog = root.appendingPathComponent("terminal-iterm-focus.log")

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "api", windowID: 101, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2",
                windowID: 101, itermSessionID: "session-101", itermTabIndex: 1, pid: 1234, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: "now", exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: yabaiFocusLog.path) {
                try withEnv(name: "MOCK_ITERM_FOCUS_LOG_FILE", value: itermFocusLog.path) {
                    try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 1)
                }
            }
        }

        XCTAssertEqual(try orchestrator.activeWorkspaceID(), workspace.id)
        let itermFocusEntry = try String(contentsOf: itermFocusLog).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(itermFocusEntry, "session-101|1|101")
        if FileManager.default.fileExists(atPath: yabaiFocusLog.path) {
            let yabaiFocusEntries = try String(contentsOf: yabaiFocusLog).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(yabaiFocusEntries.isEmpty)
        }
    }

    // Tests focus window navigation uses relative order and wraps by arranging representative inputs and asserting the expected result.
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

    // Tests focus workspace window uses browser target url when present by arranging representative inputs and asserting the expected result.
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

    // Tests focus window navigation wraps across browser targets in same chrome window by arranging representative inputs and asserting the expected result.
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

    // Tests focus workspace window uses tracked chrome window id when target url is shared by arranging representative inputs and asserting the expected result.
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

    // Tests windows live scan uses session prefixes and deduplicates overlapping matches by arranging representative inputs and asserting the expected result.
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

    // Tests windows live scan debounces refresh for ten seconds by arranging representative inputs and asserting the expected result.
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

    // Tests focus workspace window uses tab index fast path when live scan is present by arranging representative inputs and asserting the expected result.
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

    // Tests focus workspace window auto corrects when focused indexed tab does not match workspace by arranging representative inputs and asserting the expected result.
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

    // Tests focus workspace window uses distinct live tab ur ls for overlapping session prefixes by arranging representative inputs and asserting the expected result.
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

    // Tests focus window navigation prefers remembered index across browser rows sharing window id by arranging representative inputs and asserting the expected result.
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

    // Tests tracked windows orders browser then terminal then other roles by arranging representative inputs and asserting the expected result.
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

    // Tests windows live scan orders browser rows by session prefix then url by arranging representative inputs and asserting the expected result.
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

    // Tests windows omits untargeted browser rows when targeted row shares window id by arranging representative inputs and asserting the expected result.
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

    // Tests focus window navigation uses active browser tab when remembered index is stale by arranging representative inputs and asserting the expected result.
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

    // Tests launch workspace tracks all terminal windows from running processes by arranging representative inputs and asserting the expected result.
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
            try withEnv(name: "MUXY_RUNTIME_DIR", value: runtimeDir.path) {
                try withEnv(name: "MOCK_ITERM_WINDOW_IDS_FILE", value: itermWindowIDsFile.path) {
                    try withEnv(name: "YABAI_WINDOWS_JSON", value: windowsJSON) { try orchestrator.launchWorkspace(workspaceID: workspace.id) }
                }
            }
        }

        let terminalWindows = try orchestrator.windows(workspaceID: workspace.id).filter { $0.role == "terminal" }
        XCTAssertEqual(terminalWindows.count, 2)
        XCTAssertEqual(Set(terminalWindows.compactMap(\.windowID)), Set([701, 702]))
    }

    // Tests launch workspace does not auto open editor by arranging representative inputs and asserting the expected result.
    func testLaunchWorkspaceDoesNotAutoOpenEditor() throws {
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace(editor: .vscode)
        let root = try makeTempDirectory()
        let openLog = root.appendingPathComponent("launch-open.log")

        let windowsJSON =
            "[{\"id\":101,\"pid\":11,\"app\":\"iTerm2\",\"title\":\"shell\",\"space\":1,\"display\":1,\"is-sticky\":false,\"is-hidden\":false,\"is-visible\":true,\"is-native-fullscreen\":false},{\"id\":202,\"pid\":22,\"app\":\"Google Chrome\",\"title\":\"docs\",\"space\":1,\"display\":1,\"is-sticky\":false,\"is-hidden\":false,\"is-visible\":true,\"is-native-fullscreen\":false}]"

        // Mocked dependencies: `yabai`, `osascript`, and `open`.
        // Why: verify launch behavior keeps editor unopened/untracked.
        // Remaining risk: real launch timing may still differ under heavy desktop churn.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock, "open": Self.openMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: windowsJSON) {
                try withEnv(name: "OPEN_LOG_FILE", value: openLog.path) { try orchestrator.launchWorkspace(workspaceID: workspace.id) }
            }
        }

        let editorWindows = try orchestrator.windows(workspaceID: workspace.id).filter { $0.role == "editor" }
        XCTAssertEqual(editorWindows.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: openLog.path))
    }

    // Tests launch workspace reuses existing browser matches and tracks all matching tabs by arranging representative inputs and asserting the expected result.
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

    // Tests launch workspace extracts browser session into dedicated window and persists mapping by arranging representative inputs and asserting the expected result.
    func testLaunchWorkspaceExtractsBrowserSessionIntoDedicatedWindowAndPersistsMapping() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let extractLog = root.appendingPathComponent("chrome-extract.log")
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(url: "http://localhost:3001")])
        let chromeMatches = "888\tGoogle Chrome — localhost 3001\thttp://localhost:3001\n"

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "MOCK_CHROME_WINDOW_MATCHES", value: chromeMatches) {
                try withEnv(name: "MOCK_CHROME_EXTRACT_WINDOW_ID", value: "888") {
                    try withEnv(name: "MOCK_CHROME_EXTRACT_LOG_FILE", value: extractLog.path) {
                        try orchestrator.launchWorkspace(workspaceID: workspace.id)
                    }
                }
            }
        }

        let sessions = try store.workspaceBrowserSessions(workspaceID: workspace.id)
        XCTAssertEqual(sessions.first?.extractedWindow?.windowID, 888)
        XCTAssertEqual(sessions.first?.extractedWindow?.isValid, true)
        let extractedEvents = try String(contentsOf: extractLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(extractedEvents, ["888\t1"])
    }

    // Tests focus workspace window marks stale extracted mapping invalid and falls back to indexed tab focus by arranging representative inputs and asserting the expected result.
    func testFocusWorkspaceWindowMarksStaleExtractedMappingInvalidAndFallsBackToIndexedTabFocus() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let chromeFocusLog = root.appendingPathComponent("chrome-stale-fallback.log")
        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id,
            sessions: [
                BrowserSession(
                    url: "http://localhost:3001",
                    extractedWindow: ExtractedBrowserWindowMapping(targetURL: "http://localhost:3001", windowID: 999, isValid: true)),
            ])
        let chromeMatches = "202\tGoogle Chrome — localhost 3001\thttp://localhost:3001\n"

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "MOCK_CHROME_WINDOW_MATCHES", value: chromeMatches) {
                try withEnv(name: "MOCK_CHROME_FOCUS_LOG_FILE", value: chromeFocusLog.path) {
                    try withEnv(name: "MOCK_CHROME_TAB_INDEX_ACTIVE_URL", value: "http://localhost:3001") {
                        try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 1)
                    }
                }
            }
        }

        let refreshedSessions = try store.workspaceBrowserSessions(workspaceID: workspace.id)
        XCTAssertEqual(refreshedSessions.first?.extractedWindow?.isValid, false)
        let focusURLs = try String(contentsOf: chromeFocusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusURLs.last, "http://localhost:3001")
    }

    // Tests workspace id for focused window maps from yabai by arranging representative inputs and asserting the expected result.
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

    // Tests workspace id for focused chrome window uses active tab url match by arranging representative inputs and asserting the expected result.
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

    // Tests refresh workspace windows prunes stale rows and clears running when no runtime indicators remain by arranging representative inputs and asserting the expected result.
    func testRefreshWorkspaceWindowsPrunesStaleRowsAndClearsRunningWhenNoRuntimeIndicatorsRemain() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "stale", windowID: 909, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))

        // Mocked dependency: live yabai window inventory.
        // Why: verify refresh prunes missing/stale tracked windows and recomputes running state from runtime indicators.
        // Remaining risk: rapid concurrent open/close events can still race with a single refresh snapshot.
        var didMutate = false
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { didMutate = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id) }
        }

        XCTAssertTrue(didMutate)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
    }

    // Tests refresh workspace windows returns false when nothing changed by arranging representative inputs and asserting the expected result.
    func testRefreshWorkspaceWindowsReturnsFalseWhenNothingChanged() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()

        // Workspace is not running and has no tracked windows — nothing to prune or update.
        var didMutate = true
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { didMutate = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id) }
        }

        XCTAssertFalse(didMutate)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
    }

    // Tests refresh workspace windows updates unmanaged terminal titles from live yabai by arranging representative inputs and asserting the expected result.
    func testRefreshWorkspaceWindowsUpdatesUnmanagedTerminalTitles() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        let windowID = 910
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "old-title", windowID: windowID, role: "terminal",
                orderIndex: 0, lastSeenAt: "now"))

        // Mocked dependency: live yabai window inventory.
        // Why: verify refresh updates fallback terminal labels for windows not represented by running process records.
        // Remaining risk: rapid title churn between snapshot calls may still produce transient stale labels.
        let windowsJSON =
            "[{\"id\":\(windowID),\"pid\":11,\"app\":\"iTerm2\",\"title\":\"new-title\",\"space\":1,\"display\":1,\"is-sticky\":false,\"is-hidden\":false,\"is-visible\":true,\"is-native-fullscreen\":false}]"
        var didMutate = false
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: windowsJSON) {
                didMutate = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id)
            }
        }

        XCTAssertTrue(didMutate)
        let refreshedWindow = try XCTUnwrap(try store.windows(workspaceID: workspace.id).first)
        XCTAssertEqual(refreshedWindow.title, "new-title")
    }

    // Tests refresh workspace windows keeps terminal titles unchanged when a running process owns the window by arranging representative inputs and asserting the expected result.
    func testRefreshWorkspaceWindowsDoesNotUpdateTerminalTitlesForRunningProcessWindows() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        let windowID = 911
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "process-title", windowID: windowID, role: "terminal",
                orderIndex: 0, lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2",
                windowID: windowID, pid: 4242, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        // Mocked dependency: live yabai window inventory.
        // Why: verify running-process command labels remain authoritative by skipping fallback-title refresh for owned terminals.
        // Remaining risk: inconsistent runtime process metadata could still cause fallback labels to appear unexpectedly.
        let windowsJSON =
            "[{\"id\":\(windowID),\"pid\":11,\"app\":\"iTerm2\",\"title\":\"different-live-title\",\"space\":1,\"display\":1,\"is-sticky\":false,\"is-hidden\":false,\"is-visible\":true,\"is-native-fullscreen\":false}]"
        var didMutate = true
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: windowsJSON) {
                didMutate = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id)
            }
        }

        XCTAssertFalse(didMutate)
        let unchangedWindow = try XCTUnwrap(try store.windows(workspaceID: workspace.id).first)
        XCTAssertEqual(unchangedWindow.title, "process-title")
    }

    // Tests refresh all workspace windows skips archived workspaces by arranging representative inputs and asserting the expected result.
    func testRefreshAllWorkspaceWindowsSkipsArchivedWorkspaces() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let defaultWorkspace = try XCTUnwrap(
            try orchestrator.listWorkspaces(projectID: project.id, includeArchived: false).first(where: { $0.isDefault }))
        let activeWorkspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let archivedWorkspace = try orchestrator.createWorkspace(projectID: project.id, name: "archived")
        try orchestrator.archiveWorkspace(workspaceID: archivedWorkspace.id)

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: defaultWorkspace.id, app: "iTerm2", title: "default-stale", windowID: 910, role: "terminal",
                orderIndex: 0, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: activeWorkspace.id, app: "iTerm2", title: "active-stale", windowID: 911, role: "terminal",
                orderIndex: 0, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: archivedWorkspace.id, app: "iTerm2", title: "archived-stale", windowID: 912,
                role: "terminal", orderIndex: 0, lastSeenAt: "now"))

        // Mocked dependency: live yabai window inventory.
        // Why: confirm bulk refresh reconciles active workspaces only and leaves archived workspace rows unchanged.
        // Remaining risk: archived rows are intentionally left untouched until explicit archive/cleanup paths run.
        var result: MuxyOrchestrator.RefreshResult?
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { result = try orchestrator.refreshAllWorkspaceWindows() }
        }

        let refreshResult = try XCTUnwrap(result)
        XCTAssertTrue(refreshResult.didMutateDB)
        // Archived workspace is excluded from refresh, so its ID should not appear in tracked counts.
        XCTAssertNil(refreshResult.trackedWindowCounts[archivedWorkspace.id])
        // Active workspaces had their stale windows pruned, leaving zero tracked windows each.
        XCTAssertEqual(refreshResult.trackedWindowCounts[defaultWorkspace.id], 0)
        XCTAssertEqual(refreshResult.trackedWindowCounts[activeWorkspace.id], 0)

        XCTAssertTrue(try store.windows(workspaceID: defaultWorkspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: activeWorkspace.id).isEmpty)
        XCTAssertEqual(try store.windows(workspaceID: archivedWorkspace.id).count, 1)
    }

    // Tests refresh all workspace windows reports no mutation when nothing changed by arranging representative inputs and asserting the expected result.
    func testRefreshAllWorkspaceWindowsReportsNoMutationWhenNothingChanged() throws {
        let (orchestrator, _, _, _, _) = try makeOrchestratorWithWorkspace()

        // No tracked windows and workspace is not running — refresh should report no DB mutation.
        var result: MuxyOrchestrator.RefreshResult?
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { result = try orchestrator.refreshAllWorkspaceWindows() }
        }

        let refreshResult = try XCTUnwrap(result)
        XCTAssertFalse(refreshResult.didMutateDB)
        // All non-archived workspaces should still appear in tracked counts (with zero windows).
        XCTAssertFalse(refreshResult.trackedWindowCounts.isEmpty)
        for (_, count) in refreshResult.trackedWindowCounts {
            XCTAssertEqual(count, 0)
        }
    }

    // Tests list space options sorts by display then space by arranging representative inputs and asserting the expected result.
    func testListSpaceOptionsSortsByDisplayThenSpace() throws {
        let root = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        // Mocked dependency: `yabai --spaces` payload ordering.
        // Why: guarantee sort assertions independently of host window-manager state.
        // Remaining risk: unexpected production fields or space metadata edge cases are not covered.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            let options = try orchestrator.listSpaceOptions()
            let values = options.map { "\($0.displayIndex):\($0.spaceIndex)" }
            XCTAssertEqual(values, ["1:1", "1:2", "2:3"])
        }
    }

    // Tests update workspace settings marks workspace running when runtime indicators exist by arranging representative inputs and asserting the expected result.
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

    // Tests list projects returns sorted summaries by arranging representative inputs and asserting the expected result.
    func testListProjectsReturnsSortedSummaries() throws {
        let root = try makeTempDirectory()
        let aDir = root.appendingPathComponent("alpha", isDirectory: true)
        let bDir = root.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: aDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        _ = try orchestrator.addProject(dir: bDir.path)
        _ = try orchestrator.addProject(dir: aDir.path)
        let projects = try orchestrator.listProjects()

        XCTAssertEqual(projects.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(projects.map(\.isGitRepo), [false, false])
    }

    // Tests update project config and read back project config by arranging representative inputs and asserting the expected result.
    func testUpdateProjectConfigAndReadBackProjectConfig() throws {
        let (orchestrator, _, project, _, _) = try makeOrchestratorWithWorkspace()

        try orchestrator.updateProjectConfig(projectID: project.id) { p in
            p.setupScript = "echo setup"
            p.stopScript = "echo stop"
            p.processes = [ProcessTemplate(name: "api", command: "npm run api")]
            p.statusChecks = [StatusCheckDefinition(name: "health", process: "api", command: "echo ok", interval: 10, timeout: 2, onFail: .notify)]
            p.browserSessions = [BrowserSession(url: "https://example.com")]
        }

        let loaded = try orchestrator.project(id: project.id)
        XCTAssertEqual(loaded?.setupScript, "echo setup")
        XCTAssertEqual(loaded?.stopScript, "echo stop")
        XCTAssertEqual(loaded?.processes.first?.name, "api")
        XCTAssertEqual(loaded?.statusChecks.first?.name, "health")
        XCTAssertEqual(loaded?.browserSessions.first?.url, "https://example.com")
    }

    // Tests update project config using closure persists changes by arranging representative inputs and asserting the expected result.
    func testUpdateProjectConfigUsingClosurePersistsChanges() throws {
        let (orchestrator, _, project, _, _) = try makeOrchestratorWithWorkspace()

        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.stopScript = "echo bye"
            config.processes = [ProcessTemplate(command: "echo process")]
        }

        let loaded = try orchestrator.project(id: project.id)
        XCTAssertEqual(loaded?.stopScript, "echo bye")
        XCTAssertEqual(loaded?.processes.first?.command, "echo process")
    }

    // Tests update project config seeds default workspace when settings match previous template by arranging representative inputs and asserting the expected result.
    func testUpdateProjectConfigSeedsDefaultWorkspaceWhenSettingsMatchPreviousTemplate() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
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

    // Tests update project config does not overwrite customized default workspace settings by arranging representative inputs and asserting the expected result.
    func testUpdateProjectConfigDoesNotOverwriteCustomizedDefaultWorkspaceSettings() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
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

    // Tests create workspace rejects duplicate active workspace by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceRejectsDuplicateActiveWorkspace() throws {
        let (orchestrator, _, project, _, _) = try makeOrchestratorWithWorkspace()
        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id, name: "feature"))
    }

    // Tests archive default workspace throws by arranging representative inputs and asserting the expected result.
    func testArchiveDefaultWorkspaceThrows() throws {
        let (orchestrator, _, project, _, _) = try makeOrchestratorWithWorkspace()
        let defaultWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first(where: { $0.isDefault }))
        XCTAssertThrowsError(try orchestrator.archiveWorkspace(workspaceID: defaultWorkspace.id))
    }

    // Tests stop workspace updates running state and cleans runtime records by arranging representative inputs and asserting the expected result.
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

    // Tests stop workspace handles missing workspace directory and returns outcome by arranging representative inputs and asserting the expected result.
    func testStopWorkspaceHandlesMissingWorkspaceDirectoryAndReturnsOutcome() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let marker = root.appendingPathComponent("stop-script-marker.txt")
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: "echo ran > '\(marker.path)'")

        try FileManager.default.removeItem(atPath: workspace.dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.dir))

        let outcome = try orchestrator.stopWorkspace(workspaceID: workspace.id)

        XCTAssertEqual(outcome.skippedStopScriptBecauseWorkspaceDirectoryMissing, true)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    // Tests stop workspace terminates process before closing tracked terminal window by arranging representative inputs and asserting the expected result.
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

    // Tests stop workspace resolves pid from runtime file when tracked pid is missing by arranging representative inputs and asserting the expected result.
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
            try withEnv(name: "MUXY_RUNTIME_DIR", value: runtimeDir.path) {
                try withEnv(name: "MOCK_KILL_LOG_FILE", value: eventLog.path) {
                    try withEnv(name: "MOCK_ITERM_CLOSE_LOG_FILE", value: eventLog.path) { try orchestrator.stopWorkspace(workspaceID: workspace.id) }
                }
            }
        }

        let events = (try? String(contentsOf: eventLog).split(separator: "\n").map(String.init)) ?? []
        XCTAssertTrue(events.contains("kill -INT -- -8765"))
    }

    // Tests stop workspace closes tracked browser tabs without closing chrome window by arranging representative inputs and asserting the expected result.
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
        XCTAssertFalse(closedWindowIDs.contains("501"))
        let closedTabs = try String(contentsOf: chromeCloseLog)
        XCTAssertTrue(closedTabs.contains("http://localhost:3001"))
    }

    // Tests stop workspace closes process-backed i term terminal by session/tab without yabai-closing the whole window by arranging representative inputs and asserting the expected result.
    func testStopWorkspaceDoesNotYabaiCloseProcessBackedItermWindow() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let yabaiCloseLog = root.appendingPathComponent("stop-yabai-close.log")
        let itermCloseLog = root.appendingPathComponent("stop-iterm-close.log")
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "api", windowID: 501, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 501,
                itermSessionID: "session-501", itermTabIndex: 1, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now",
                exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "YABAI_CLOSE_LOG_FILE", value: yabaiCloseLog.path) {
                try withEnv(name: "MOCK_ITERM_CLOSE_LOG_FILE", value: itermCloseLog.path) {
                    try orchestrator.stopWorkspace(workspaceID: workspace.id)
                }
            }
        }

        let itermEvents = (try? String(contentsOf: itermCloseLog)) ?? ""
        XCTAssertTrue(itermEvents.contains("iterm-close 501"))
        let yabaiClosedWindowIDs = (try? String(contentsOf: yabaiCloseLog).split(separator: "\n").map(String.init)) ?? []
        XCTAssertFalse(yabaiClosedWindowIDs.contains("501"))
    }

    func testStopWorkspaceDoesNotCallCloseWindowIfSingletonWhenSessionCloseSucceeds() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")

        // Process window (window 501) with session
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "npm run dev", windowID: 501,
                itermSessionID: "session-proc", itermTabIndex: 1, role: "terminal", orderIndex: 0, lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run dev", terminalApp: "iTerm2", windowID: 501,
                itermSessionID: "session-proc", itermTabIndex: 1, pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now",
                exitedAt: nil))

        // Tracked terminal window (window 502) opened via "Open Terminal" with a valid session
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "-zsh", windowID: 502,
                itermSessionID: "session-term", itermTabIndex: 1, role: "terminal", orderIndex: 1, lastSeenAt: "now"))

        try orchestrator.stopWorkspace(workspaceID: workspace.id)

        // closeSessionOrTab should have been called for both sessions
        XCTAssertTrue(mockIterm.closedSessionIDs.contains("session-proc"))
        XCTAssertTrue(mockIterm.closedSessionIDs.contains("session-term"))
    }

    // Tests stop workspace closes all live detected browser session tabs by arranging representative inputs and asserting the expected result.
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
        XCTAssertFalse(closedWindowIDs.contains("501"))
        let closedTabs = try String(contentsOf: chromeCloseLog)
        XCTAssertTrue(closedTabs.contains("http://localhost:3001/"))
        XCTAssertTrue(closedTabs.contains("http://localhost:3001/login?redirect=/account"))
        XCTAssertTrue(closedTabs.contains("http://localhost:3001/admin"))
        XCTAssertFalse(closedTabs.contains("https://calendar.google.com"))
    }

    // Tests launch workspace throws when runtime indicators exist by arranging representative inputs and asserting the expected result.
    func testLaunchWorkspaceThrowsWhenRuntimeIndicatorsExist() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 701,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        XCTAssertThrowsError(try orchestrator.launchWorkspace(workspaceID: workspace.id))
    }

    // Tests launch workspace without processes does not require i term by arranging representative inputs and asserting the expected result.
    func testLaunchWorkspaceWithoutProcessesDoesNotRequireITerm() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) { try orchestrator.launchWorkspace(workspaceID: workspace.id) }

        XCTAssertTrue(try orchestrator.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
    }

    // Tests launch workspace waits for pending setup to finish by arranging a deferred setup run and asserting launch completes afterwards.
    func testLaunchWorkspaceWaitsForPendingSetupToFinish() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.setupScript = "sleep 1; echo done > .muxy-launch-wait-marker"
        }

        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "launch-waits", runSetupScript: false)
        let setupThread = Thread {
            try? orchestrator.runWorkspaceSetup(workspaceID: workspace.id)
        }
        setupThread.start()

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try orchestrator.launchWorkspace(workspaceID: workspace.id)
        }

        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
        XCTAssertEqual(try orchestrator.workspaceSetupState(workspaceID: workspace.id).status, .succeeded)
    }

    // Tests restart workspace stops then launches by arranging representative inputs and asserting the expected result.
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

    // Tests up workspace launches when stopped by arranging representative inputs and asserting the expected result.
    func testUpWorkspaceLaunchesWhenStopped() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try orchestrator.upWorkspace(workspaceID: workspace.id)
        }

        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
        XCTAssertTrue(try orchestrator.runningProcesses(workspaceID: workspace.id).isEmpty)
    }

    // Tests up workspace does nothing to running processes when runtime indicators exist and restart is disabled by arranging representative inputs and asserting the expected result.
    func testUpWorkspaceDoesNothingWhenRuntimeIndicatorsExistByDefault() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "old", command: "echo old", terminalApp: "iTerm2", windowID: 501,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try orchestrator.upWorkspace(workspaceID: workspace.id)
        }

        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
        XCTAssertEqual(try orchestrator.runningProcesses(workspaceID: workspace.id).count, 1)
    }

    // Tests up workspace restarts exited processes when workspace is running by arranging representative inputs and asserting the expected result.
    func testUpWorkspaceRestartsExitedProcessesWhenRunning() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "echo web", terminalApp: "iTerm2", windowID: nil,
                pid: nil, status: .exited, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try orchestrator.upWorkspace(workspaceID: workspace.id)
        }

        let processes = try orchestrator.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.count, 1)
        XCTAssertEqual(processes.first?.status, .running)
        XCTAssertEqual(processes.first?.templateName, "web")
    }

    // Tests up workspace restarts when runtime indicators exist and restart is enabled by arranging representative inputs and asserting the expected result.
    func testUpWorkspaceRestartsWhenRuntimeIndicatorsExistWithRestartEnabled() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "old", command: "echo old", terminalApp: "iTerm2", windowID: 501,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try orchestrator.upWorkspace(workspaceID: workspace.id, restartIfRunning: true)
        }

        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
        XCTAssertTrue(try orchestrator.runningProcesses(workspaceID: workspace.id).isEmpty)
    }

    // Tests restart workspace preserves agent windows by arranging a running workspace with an iterm2 agent window and asserting the record and session survive the restart.
    func testRestartWorkspacePreservesAgentWindows() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        // Agent runs in the same iTerm2 session as the tracked workspace terminal window (common case:
        // user ran `claude` from within the workspace terminal tab).
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "claude",
                windowID: 501, itermSessionID: "agent-session-1", itermTabIndex: 1,
                role: "terminal", orderIndex: 0, lastSeenAt: "now"))
        let agentRecord = AgentWindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, provider: .iterm2, label: "Claude Code",
            itermSessionID: "agent-session-1", codexThreadID: nil, windowID: nil,
            yabaiWindowID: 501, status: .spinning, createdAt: "now", updatedAt: "now")
        try store.upsertAgentWindow(agentRecord)

        // Mocked dependencies: yabai and osascript for stop/launch phases.
        // Why: verify restart does not close the iTerm2 session that hosts the coding agent, even when
        // that session is also tracked as a workspace terminal window.
        // Remaining risk: the agent session itself is not verified live in iTerm2, only the DB record and mock call list.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try orchestrator.restartWorkspace(workspaceID: workspace.id)
        }

        let remaining = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(remaining.count, 1, "Agent window record should be preserved after restart")
        XCTAssertEqual(remaining.first?.id, agentRecord.id)
        XCTAssertFalse(mockIterm.closedSessionIDs.contains("agent-session-1"), "Agent iTerm2 session should not be closed during restart")
    }

    // Tests restart workspace closes non-agent sessions in the same window while preserving the agent session.
    func testRestartWorkspaceClosesNonAgentSessionInSameWindow() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        // Workspace terminal tab (session A) is a different tab in the same window as the agent (session B).
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell",
                windowID: 501, itermSessionID: "workspace-session-A", itermTabIndex: 0,
                role: "terminal", orderIndex: 0, lastSeenAt: "now"))
        let agentRecord = AgentWindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, provider: .iterm2, label: "Claude Code",
            itermSessionID: "agent-session-B", codexThreadID: nil, windowID: nil,
            yabaiWindowID: 501, status: .spinning, createdAt: "now", updatedAt: "now")
        try store.upsertAgentWindow(agentRecord)

        // Mocked dependencies: yabai and osascript for stop/launch phases.
        // Why: verify that only the workspace session is closed and not the agent session when they share the same window.
        // Remaining risk: iTerm2's actual per-session close behaviour is not exercised; only mock call recording is asserted.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try orchestrator.restartWorkspace(workspaceID: workspace.id)
        }

        XCTAssertTrue(mockIterm.closedSessionIDs.contains("workspace-session-A"), "Non-agent workspace session should be closed during restart")
        XCTAssertFalse(mockIterm.closedSessionIDs.contains("agent-session-B"), "Agent session should not be closed during restart")
        XCTAssertEqual(try store.agentWindows(workspaceID: workspace.id).count, 1)
    }

    // Tests up workspace with restart enabled preserves agent windows by arranging a running workspace with an iterm2 agent window and asserting the record and session survive the restart.
    func testUpWorkspaceWithRestartPreservesAgentWindows() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        let agentRecord = AgentWindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, provider: .iterm2, label: "Claude Code",
            itermSessionID: "agent-session-2", codexThreadID: nil, windowID: nil,
            status: .spinning, createdAt: "now", updatedAt: "now")
        try store.upsertAgentWindow(agentRecord)

        // Mocked dependencies: yabai and osascript for stop/launch phases.
        // Why: verify upWorkspace(restartIfRunning: true) does not close or delete iterm2 agent window records.
        // Remaining risk: the agent session itself is not verified live in iTerm2, only the DB record and mock call list.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try orchestrator.upWorkspace(workspaceID: workspace.id, restartIfRunning: true)
        }

        let remaining = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(remaining.count, 1, "Agent window record should be preserved after up --restart")
        XCTAssertEqual(remaining.first?.id, agentRecord.id)
        XCTAssertFalse(mockIterm.closedSessionIDs.contains("agent-session-2"), "Agent iTerm2 session should not be closed during up --restart")
    }

    // Tests update workspace settings removing browser sessions closes tabs without closing chrome window by arranging representative inputs and asserting the expected result.
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

    // Tests launch workspace rejects archived workspace by arranging representative inputs and asserting the expected result.
    func testLaunchWorkspaceRejectsArchivedWorkspace() throws {
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try orchestrator.archiveWorkspace(workspaceID: workspace.id)

        // Mocked dependencies are present only to satisfy adapter calls; launch should fail before launching anything.
        // Remaining risk: launch behavior when partially archived/misaligned runtime state exists is covered elsewhere.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            XCTAssertThrowsError(try orchestrator.launchWorkspace(workspaceID: workspace.id))
        }
    }

    // Tests workspace settings and accessors reflect store state by arranging representative inputs and asserting the expected result.
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
    ) throws -> (MuxyOrchestrator, SQLiteStore, ProjectRecord, WorkspaceRecord, URL) {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(
            store: store, browserWindowScanDebounceInterval: browserWindowScanDebounceInterval, currentDate: currentDate)
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

        sleep_ms() {
          local value="$1"
          if [[ -z "$value" || "$value" == "0" ]]; then
            return
          fi
          local cap="${MOCK_TEST_DELAY_CAP_MS:-25}"
          if [[ "$value" =~ ^[0-9]+$ && "$cap" =~ ^[0-9]+$ && "$value" -gt "$cap" ]]; then
            value="$cap"
          fi
          perl -e "select(undef, undef, undef, $value / 1000);"
        }

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
          sleep_ms "${MOCK_YABAI_FOCUS_DELAY_MS:-0}"
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

        sleep_ms() {
          local value="$1"
          if [[ -z "$value" || "$value" == "0" ]]; then
            return
          fi
          local cap="${MOCK_TEST_DELAY_CAP_MS:-25}"
          if [[ "$value" =~ ^[0-9]+$ && "$cap" =~ ^[0-9]+$ && "$value" -gt "$cap" ]]; then
            value="$cap"
          fi
          perl -e "select(undef, undef, undef, $value / 1000);"
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
            echo "${first}|session-${first}|1"
            exit 0
          fi
          wid="${MOCK_ITERM_WINDOW_ID:-701}"
          echo "${wid}|session-${wid}|1"
          exit 0
        fi

        if [[ "$script" == *'set targetSessionID to'* && "$script" == *'tell application "iTerm2"'* ]]; then
          if [[ "$script" != *'activate'* && "$script" != *'set current window to w'* ]]; then
            # closeSessionOrTab scripts are handled by the close logger branch below
            :
          else
          if [[ -n "${MOCK_ITERM_FOCUS_LOG_FILE:-}" ]]; then
            session_id="$(printf '%s\n' "$script" | awk -F'set targetSessionID to \"' 'NF>1 { sub(/\".*/, "", $2); print $2; exit }')"
            tab_index="$(printf '%s\n' "$script" | grep -Eo 'set targetTabIndex to -?[0-9]+' | awk '{print $4}' | head -n1)"
            window_id="$(printf '%s\n' "$script" | grep -Eo 'set targetWindowID to -?[0-9]+' | awk '{print $4}' | head -n1)"
            echo "${session_id}|${tab_index}|${window_id}" >> "$MOCK_ITERM_FOCUS_LOG_FILE"
          fi
          echo "${MOCK_ITERM_FOCUS_RESULT:-session}"
          exit 0
          fi
        fi

        if [[ "$script" == *'tell application "Google Chrome" to version'* ]]; then
          echo "122"
          exit 0
        fi

        if [[ "$script" == *'set output to ""'* ]]; then
          sleep_ms "${MOCK_CHROME_SCAN_DELAY_MS:-0}"
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

        if [[ "$script" == *'set targetTab to tab requestedTabIndex of w'* ]]; then
          sleep_ms "${MOCK_CHROME_EXTRACT_DELAY_MS:-0}"
          requested_tab_index="$(printf '%s\n' "$script" | grep -Eo 'set requestedTabIndex to [0-9]+' | awk '{print $4}' | head -n1)"
          focused_window_id="$(extract_window_id "$script")"
          if [[ -n "${MOCK_CHROME_EXTRACT_LOG_FILE:-}" ]]; then
            echo "${focused_window_id:-*}\t${requested_tab_index:-0}" >> "$MOCK_CHROME_EXTRACT_LOG_FILE"
          fi
          echo "${MOCK_CHROME_EXTRACT_WINDOW_ID:-888}"
          exit 0
        fi

        if [[ "$script" == *'set requestedTabIndex to'* ]]; then
          sleep_ms "${MOCK_CHROME_TAB_INDEX_DELAY_MS:-0}"
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
          sleep_ms "${MOCK_CHROME_ACTIVE_URL_DELAY_MS:-0}"
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

        if [[ "$script" == *'close s'* || "$script" == *'close t'* || "$script" == *'close w'* ]]; then
          close_window_id="$(printf '%s\n' "$script" | grep -Eo 'set targetWindowID to -?[0-9]+' | awk '{print $4}' | head -n1)"
          if [[ -z "$close_window_id" ]]; then
            close_window_id="$(printf '%s\n' "$script" | grep -Eo 'if id of w is [0-9]+ then' | awk '{print $6}' | head -n1)"
          fi
          close_kind="window"
          if [[ "$script" == *'close s'* ]]; then close_kind="session"; fi
          if [[ "$script" == *'close t'* ]]; then close_kind="tab"; fi
          if [[ -n "${MOCK_ITERM_CLOSE_LOG_FILE:-}" ]]; then
            echo "iterm-close ${close_window_id:-unknown} ${close_kind}" >> "$MOCK_ITERM_CLOSE_LOG_FILE"
          fi
          echo "${close_kind}"
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

    private func makeTempGitRepo(name: String, initialBranch: String = "main") throws -> URL {
        let root = try makeTempDirectory()
        let repo = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try runGit(["init", "-b", initialBranch], cwd: repo.path)
        try "hello".write(to: repo.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], cwd: repo.path)
        try runGit(["-c", "user.name=muxy-test", "-c", "user.email=test@example.com", "commit", "-m", "init"], cwd: repo.path)
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
                domain: "muxy.tests", code: Int(process.terminationStatus),
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
                domain: "muxy.tests", code: Int(process.terminationStatus),
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

    // MARK: - buildWorkspaceEnv

    // Tests build workspace env sets muxy workspace dir by arranging representative inputs and asserting the expected result.
    func testBuildWorkspaceEnvSetsMuxyWorkspaceDir() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/tmp/project")
        let workspace = makeWorkspaceRecord(projectID: project.id, name: "dev", dir: "/tmp/project/ws")
        let env = orchestrator.buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: [])
        XCTAssertEqual(env["MUXY_WORKSPACE_DIR"], "/tmp/project/ws")
    }

    // Tests build workspace env sets muxy project dir by arranging representative inputs and asserting the expected result.
    func testBuildWorkspaceEnvSetsMuxyProjectDir() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/tmp/project")
        let workspace = makeWorkspaceRecord(projectID: project.id, name: "dev", dir: "/tmp/project/ws")
        let env = orchestrator.buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: [])
        XCTAssertEqual(env["MUXY_PROJECT_DIR"], "/tmp/project")
    }

    // Tests build workspace env does not contain scoped key by arranging representative inputs and asserting the expected result.
    func testBuildWorkspaceEnvDoesNotContainScopedKey() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/tmp/project")
        let workspace = makeWorkspaceRecord(projectID: project.id, name: "dev", dir: "/tmp/project/ws")
        let env = orchestrator.buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: [])
        let scopedKeys = env.keys.filter { $0.hasPrefix("muxy_") || $0.hasPrefix("MUXY_PROJECT_") && $0.hasSuffix("_WORKSPACE_DIR") }
        XCTAssertTrue(scopedKeys.isEmpty, "Expected no scoped cross-project keys, found: \(scopedKeys)")
    }

    // Tests add project stores in db only by arranging representative inputs and asserting the expected result.
    func testAddProjectStoresInDBOnly() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("myproject", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let record = try orchestrator.addProject(dir: projectDir.path)

        // Project is in DB
        XCTAssertNotNil(try store.project(id: record.id))

        // Project count in DB is correct
        XCTAssertEqual(try store.projects().count, 1)
    }

    // Tests update project config persists templates to db by arranging representative inputs and asserting the expected result.
    func testUpdateProjectConfigPersistsTemplatesToDB() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        try orchestrator.updateProjectConfig(projectID: project.id) { p in
            p.setupScript = "echo setup"
            p.stopScript = "echo stop"
            p.ports = [PortDefinition(name: "API_PORT")]
            p.processes = [ProcessTemplate(name: "api", command: "npm start")]
        }

        let updated = try store.project(id: project.id)
        XCTAssertEqual(updated?.setupScript, "echo setup")
        XCTAssertEqual(updated?.stopScript, "echo stop")
        XCTAssertEqual(updated?.ports.count, 1)
        XCTAssertEqual(updated?.processes.count, 1)
    }

    // Tests remove project deletes from db by arranging representative inputs and asserting the expected result.
    func testRemoveProjectDeletesFromDB() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        XCTAssertNotNil(try store.project(id: project.id))

        try orchestrator.removeProject(dir: projectDir.path)

        XCTAssertNil(try store.project(id: project.id))
    }

    // Tests build workspace env includes named ports by arranging representative inputs and asserting the expected result.
    func testBuildWorkspaceEnvIncludesNamedPorts() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/tmp/project")
        let workspace = makeWorkspaceRecord(projectID: project.id, name: "dev", dir: "/tmp/project/ws")
        let ports: [(port: Int, name: String)] = [(port: 3000, name: "FRONTEND_PORT"), (port: 8080, name: "API_PORT")]
        let env = orchestrator.buildWorkspaceEnv(project: project, workspace: workspace, namedPorts: ports)
        XCTAssertEqual(env["FRONTEND_PORT"], "3000")
        XCTAssertEqual(env["API_PORT"], "8080")
        XCTAssertEqual(env["MUXY_WORKSPACE_DIR"], "/tmp/project/ws")
        XCTAssertEqual(env["MUXY_PROJECT_DIR"], "/tmp/project")
    }

    // Tests create workspace from worktree infers project and branch by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceFromWorktreeInfersProjectAndBranch() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: repo.path)
        
        let root = repo.deletingLastPathComponent()
        
        let worktree = root.appendingPathComponent("feature-branch", isDirectory: true)
        let client = GitClient()
        try client.createWorktree(path: repo.path, worktreePath: worktree.path, branch: "feature-branch")
        
        let workspace = try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree.path, name: nil)
        
        XCTAssertEqual(workspace.projectID, project.id)
        XCTAssertEqual(workspace.name, "feature-branch")
        XCTAssertEqual(workspace.branch, "feature-branch")
        XCTAssertEqual(workspace.dir, worktree.path)
        XCTAssertEqual(workspace.dirname, "feature-branch")
        XCTAssertFalse(workspace.isArchived)
        
        let stored = try store.workspace(id: workspace.id)
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.name, "feature-branch")
    }

    // Tests create workspace from worktree with custom name by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceFromWorktreeWithCustomName() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()
        
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        _ = try orchestrator.addProject(dir: repo.path)
        
        let worktree = root.appendingPathComponent("fix-bug", isDirectory: true)
        let client = GitClient()
        try client.createWorktree(path: repo.path, worktreePath: worktree.path, branch: "fix/bug-123")
        
        let workspace = try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree.path, name: "bug-fix")
        
        XCTAssertEqual(workspace.name, "bug-fix")
        XCTAssertEqual(workspace.branch, "fix/bug-123")
    }

    // Tests create workspace from worktree fails if project not registered by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceFromWorktreeFailsIfProjectNotRegistered() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()
        
        let worktree = root.appendingPathComponent("feature", isDirectory: true)
        let client = GitClient()
        try client.createWorktree(path: repo.path, worktreePath: worktree.path, branch: "feature")
        
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        
        XCTAssertThrowsError(try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree.path, name: nil)) { error in
            let nsError = error as NSError
            XCTAssertTrue(nsError.localizedDescription.contains("Project not found"))
            XCTAssertTrue(nsError.localizedDescription.contains("mx project add"))
        }
    }

    // Tests create workspace from worktree fails if already exists by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceFromWorktreeFailsIfAlreadyExists() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()
        
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        _ = try orchestrator.addProject(dir: repo.path)
        
        let worktree = root.appendingPathComponent("feature", isDirectory: true)
        let client = GitClient()
        try client.createWorktree(path: repo.path, worktreePath: worktree.path, branch: "feature")
        
        _ = try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree.path, name: nil)
        
        XCTAssertThrowsError(try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree.path, name: nil)) { error in
            let nsError = error as NSError
            XCTAssertTrue(nsError.localizedDescription.contains("already exists"))
        }
    }

    // Tests scan and create workspaces from worktrees finds all worktrees by arranging representative inputs and asserting the expected result.
    func testScanAndCreateWorkspacesFromWorktreesFindsAllWorktrees() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()
        
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: repo.path)
        
        let client = GitClient()
        let worktree1 = root.appendingPathComponent("feature-1", isDirectory: true)
        let worktree2 = root.appendingPathComponent("feature-2", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: worktree1.path, branch: "feature-1")
        try client.createWorktree(path: repo.path, worktreePath: worktree2.path, branch: "feature-2")
        
        let created = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: project.id)
        
        XCTAssertEqual(created.count, 2)
        
        let names = Set(created.map(\.name))
        XCTAssertTrue(names.contains("feature-1"))
        XCTAssertTrue(names.contains("feature-2"))
        
        let allWorkspaces = try store.workspaces(projectID: project.id, includeArchived: false)
        XCTAssertEqual(allWorkspaces.count, 3)
    }

    // Tests scan and create workspaces from worktrees skips existing workspaces by arranging representative inputs and asserting the expected result.
    func testScanAndCreateWorkspacesFromWorktreesSkipsExistingWorkspaces() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()
        
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: repo.path)
        
        let client = GitClient()
        let worktree1 = root.appendingPathComponent("feature-1", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: worktree1.path, branch: "feature-1")
        
        _ = try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree1.path, name: nil)
        
        let worktree2 = root.appendingPathComponent("feature-2", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: worktree2.path, branch: "feature-2")
        
        let created = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: project.id)
        
        XCTAssertEqual(created.count, 1)
        let names = Set(created.map(\.name))
        XCTAssertTrue(names.contains("feature-2"))
        XCTAssertFalse(names.contains("feature-1"))
        XCTAssertFalse(names.contains("main"))
    }

    // Tests scan and create workspaces from worktrees runs setup script for created workspace by arranging representative inputs and asserting the expected result.
    func testScanAndCreateWorkspacesFromWorktreesRunsSetupScriptForCreatedWorkspace() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()

        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: repo.path)

        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.setupScript = "echo discovered > .muxy-discovery-setup-marker"
        }

        let client = GitClient()
        let worktree = root.appendingPathComponent("feature-setup", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: worktree.path, branch: "feature-setup")

        let created = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: project.id)
        XCTAssertEqual(created.count, 1)

        let markerFile = worktree.appendingPathComponent(".muxy-discovery-setup-marker")
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerFile.path))
        let marker = try String(contentsOf: markerFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(marker, "discovered")
    }

    // Tests scan and create workspaces from worktrees skips deleted workspace paths marked ignored by arranging representative inputs and asserting the expected result.
    func testScanAndCreateWorkspacesFromWorktreesSkipsDeletedWorkspacePathsMarkedIgnored() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()

        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        _ = try orchestrator.addProject(dir: repo.path)

        let client = GitClient()
        let worktree = root.appendingPathComponent("feature-ignored", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: worktree.path, branch: "feature-ignored")
        let workspace = try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree.path)

        try store.deleteWorkspace(id: workspace.id)

        let created = try orchestrator.scanAndCreateWorkspacesFromWorktrees()
        XCTAssertTrue(created.isEmpty)
        XCTAssertNil(try store.workspace(dir: worktree.path))
        XCTAssertTrue(try store.isIgnoredWorktree(path: worktree.path))
    }

    // Tests scan and create workspaces from worktrees skips missing worktree directories by arranging representative inputs and asserting the expected result.
    func testScanAndCreateWorkspacesFromWorktreesSkipsMissingWorktreeDirectories() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()

        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: repo.path)

        let client = GitClient()
        let missingWorktree = root.appendingPathComponent("feature-missing", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: missingWorktree.path, branch: "feature-missing")
        try FileManager.default.removeItem(at: missingWorktree)

        let created = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: project.id)
        XCTAssertTrue(created.isEmpty)
        XCTAssertNil(try store.workspace(dir: missingWorktree.path))
    }

    // Tests scan and create workspaces from worktrees archives existing workspace when worktree is removed by arranging representative inputs and asserting the expected result.
    func testScanAndCreateWorkspacesFromWorktreesArchivesWorkspaceWhenWorktreeIsRemoved() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()

        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: repo.path)

        let client = GitClient()
        let removedWorktree = root.appendingPathComponent("feature-removed", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: removedWorktree.path, branch: "feature-removed")
        let workspace = try orchestrator.createWorkspaceFromWorktree(worktreePath: removedWorktree.path, name: nil)

        try client.removeWorktree(path: repo.path, worktreePath: removedWorktree.path)

        let created = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: project.id)
        XCTAssertTrue(created.isEmpty)

        let archivedWorkspace = try store.workspace(id: workspace.id)
        XCTAssertEqual(archivedWorkspace?.isArchived, true)
    }

    // Tests scan and create workspaces from worktrees refreshes stored branch names by arranging representative inputs and asserting the expected result.
    func testScanAndCreateWorkspacesFromWorktreesRefreshesBranchNamesFromDisk() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()

        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: repo.path)

        let client = GitClient()
        let worktree = root.appendingPathComponent("feature-renamed", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: worktree.path, branch: "feature-renamed")
        let workspace = try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree.path, name: nil)

        _ = try client.runGitAndCapture(["-C", worktree.path, "branch", "-m", "feature-renamed-on-disk"])
        _ = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: project.id)

        let refreshedWorkspace = try store.workspace(id: workspace.id)
        XCTAssertEqual(refreshedWorkspace?.branch, "feature-renamed-on-disk")
    }

    // Tests scan and create workspaces from worktrees scans all projects when no project id provided by arranging representative inputs and asserting the expected result.
    func testScanAndCreateWorkspacesFromWorktreesScansAllProjectsWhenNoProjectIDProvided() throws {
        let repo1 = try makeTempGitRepo(name: "repo1")
        let repo2 = try makeTempGitRepo(name: "repo2")
        let root = repo1.deletingLastPathComponent()
        
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project1 = try orchestrator.addProject(dir: repo1.path)
        let project2 = try orchestrator.addProject(dir: repo2.path)
        
        let client = GitClient()
        let worktree1 = root.appendingPathComponent("repo1-feature", isDirectory: true)
        try client.createWorktree(path: repo1.path, worktreePath: worktree1.path, branch: "feature")
        
        let worktree2 = root.appendingPathComponent("repo2-bugfix", isDirectory: true)
        try client.createWorktree(path: repo2.path, worktreePath: worktree2.path, branch: "bugfix")
        
        let created = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: nil)
        
        XCTAssertEqual(created.count, 2)
        
        let project1Workspaces = try store.workspaces(projectID: project1.id, includeArchived: false)
        XCTAssertEqual(project1Workspaces.count, 2)
        
        let project2Workspaces = try store.workspaces(projectID: project2.id, includeArchived: false)
        XCTAssertEqual(project2Workspaces.count, 2)
    }

    // Tests iterm focus pulse color returns default when not set by arranging representative inputs and asserting the expected result.
    func testItermFocusPulseColorReturnsDefaultWhenNotSet() throws {
        let (orchestrator, _, _, _, _) = try makeOrchestratorWithWorkspace()
        let (r, g, b) = try orchestrator.itermFocusPulseColor()
        XCTAssertEqual(r, 255)
        XCTAssertEqual(g, 195)
        XCTAssertEqual(b, 0)
    }

    // Tests iterm focus pulse color round trips by arranging representative inputs and asserting the expected result.
    func testItermFocusPulseColorRoundTrip() throws {
        let (orchestrator, _, _, _, _) = try makeOrchestratorWithWorkspace()
        try orchestrator.setItermFocusPulseColor(r: 10, g: 128, b: 200)
        let (r, g, b) = try orchestrator.itermFocusPulseColor()
        XCTAssertEqual(r, 10)
        XCTAssertEqual(g, 128)
        XCTAssertEqual(b, 200)
    }

    // Tests iterm focus pulse color clamps values to 0-255 by arranging representative inputs and asserting the expected result.
    func testItermFocusPulseColorClampsValues() throws {
        let (orchestrator, _, _, _, _) = try makeOrchestratorWithWorkspace()
        try orchestrator.setItermFocusPulseColor(r: -10, g: 300, b: 128)
        let (r, g, b) = try orchestrator.itermFocusPulseColor()
        XCTAssertEqual(r, 0)
        XCTAssertEqual(g, 255)
        XCTAssertEqual(b, 128)
    }

    // Tests focus iterm window triggers background pulse by arranging representative inputs and asserting the expected result.
    func testFocusItermWindowTriggersBackgroundPulse() throws {
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm)

        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "api", windowID: 555, role: "terminal",
                orderIndex: 0, lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api",
                terminalApp: "iTerm2", windowID: 555, itermSessionID: "session-555", itermTabIndex: 1,
                pid: 1234, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 1)

        // Pulse is dispatched asynchronously; allow the Task to run.
        let deadline = Date().addingTimeInterval(2)
        while mockIterm.pulseCallCount == 0, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(mockIterm.pulseCallCount, 1)
        XCTAssertEqual(mockIterm.lastPulsedWindowID, 555)
        XCTAssertEqual(mockIterm.lastPulseColor?.r, 255)
        XCTAssertEqual(mockIterm.lastPulseColor?.g, 195)
        XCTAssertEqual(mockIterm.lastPulseColor?.b, 0)
    }

    // Tests focus iterm window uses configured pulse color by arranging representative inputs and asserting the expected result.
    func testFocusItermWindowUsesConfiguredPulseColor() throws {
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm)

        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        try orchestrator.setItermFocusPulseColor(r: 0, g: 100, b: 200)
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "api", windowID: 556, role: "terminal",
                orderIndex: 0, lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api",
                terminalApp: "iTerm2", windowID: 556, itermSessionID: "session-556", itermTabIndex: 1,
                pid: 1234, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 1)

        let deadline = Date().addingTimeInterval(2)
        while mockIterm.pulseCallCount == 0, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(mockIterm.pulseCallCount, 1)
        XCTAssertEqual(mockIterm.lastPulseColor?.r, 0)
        XCTAssertEqual(mockIterm.lastPulseColor?.g, 100)
        XCTAssertEqual(mockIterm.lastPulseColor?.b, 200)
    }

    // MARK: - resolveEnvVars

    // Tests applyEnvVars substitutes a single named variable.
    func testApplyEnvVarsSubstitutesSingleVar() {
        let orchestrator = MuxyOrchestrator(store: try! makeTemporaryStore())
        let result = orchestrator.applyEnvVars("PORT=$FRONTEND_PORT npm run dev", env: ["FRONTEND_PORT": "20002"])
        XCTAssertEqual(result, "PORT=20002 npm run dev")
    }

    // Tests applyEnvVars substitutes multiple variables in one command.
    func testApplyEnvVarsSubstitutesMultipleVars() {
        let orchestrator = MuxyOrchestrator(store: try! makeTemporaryStore())
        let result = orchestrator.applyEnvVars(
            "PORT=$FRONTEND_PORT BACKEND=$BACKEND_PORT node server.js",
            env: ["FRONTEND_PORT": "3000", "BACKEND_PORT": "4000"])
        XCTAssertEqual(result, "PORT=3000 BACKEND=4000 node server.js")
    }

    // Tests applyEnvVars leaves unknown variables unchanged.
    func testApplyEnvVarsLeavesUnknownVarsUnchanged() {
        let orchestrator = MuxyOrchestrator(store: try! makeTemporaryStore())
        let result = orchestrator.applyEnvVars("PORT=$UNKNOWN npm start", env: ["FRONTEND_PORT": "3000"])
        XCTAssertEqual(result, "PORT=$UNKNOWN npm start")
    }

    // Tests applyEnvVars returns command unchanged when env is empty.
    func testApplyEnvVarsEmptyEnvReturnsCommandUnchanged() {
        let orchestrator = MuxyOrchestrator(store: try! makeTemporaryStore())
        let result = orchestrator.applyEnvVars("PORT=$FRONTEND_PORT npm run dev", env: [:])
        XCTAssertEqual(result, "PORT=$FRONTEND_PORT npm run dev")
    }

    // Tests resolveEnvVars replaces named port variable with allocated port number.
    func testResolveEnvVarsReplacesNamedPortVar() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = makeProjectRecord(dir: "/projects/myapp")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, name: "dev", dir: "/workspaces/myapp/dev")
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [20002], names: ["FRONTEND_PORT"])

        let resolved = try orchestrator.resolveEnvVars(in: "PORT=$FRONTEND_PORT npm run dev", workspaceID: workspace.id)
        XCTAssertEqual(resolved, "PORT=20002 npm run dev")
    }

    // Tests resolveEnvVars resolves multiple named ports.
    func testResolveEnvVarsResolvesMultipleNamedPorts() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = makeProjectRecord(dir: "/projects/myapp")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, name: "dev", dir: "/workspaces/myapp/dev")
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000, 4000], names: ["FRONTEND_PORT", "BACKEND_PORT"])

        let resolved = try orchestrator.resolveEnvVars(
            in: "FRONTEND=$FRONTEND_PORT BACKEND=$BACKEND_PORT node app.js",
            workspaceID: workspace.id)
        XCTAssertEqual(resolved, "FRONTEND=3000 BACKEND=4000 node app.js")
    }

    // Tests resolveEnvVars leaves command unchanged when no ports are allocated.
    func testResolveEnvVarsNoPorts() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = makeProjectRecord(dir: "/projects/myapp")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, name: "dev", dir: "/workspaces/myapp/dev")
        try store.upsert(workspace: workspace)

        let resolved = try orchestrator.resolveEnvVars(in: "npm start", workspaceID: workspace.id)
        XCTAssertEqual(resolved, "npm start")
    }

    // Tests resolveEnvVars injects MUXY_WORKSPACE_DIR into command.
    func testResolveEnvVarsInjectsWorkspaceDir() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = makeProjectRecord(dir: "/projects/myapp")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, name: "dev", dir: "/workspaces/myapp/dev")
        try store.upsert(workspace: workspace)

        let resolved = try orchestrator.resolveEnvVars(in: "cd $MUXY_WORKSPACE_DIR && npm start", workspaceID: workspace.id)
        XCTAssertEqual(resolved, "cd /workspaces/myapp/dev && npm start")
    }
}
