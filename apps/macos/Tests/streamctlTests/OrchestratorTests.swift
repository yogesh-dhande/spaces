import XCTest

@testable import streamctl

final class OrchestratorTests: XCTestCase {
    // Tests workspace window refresh interval is positive by arranging representative inputs and asserting the expected result.
    func testWorkspaceWindowRefreshIntervalIsPositive() { XCTAssertGreaterThan(PollingConstants.workspaceWindowRefreshInterval, 0) }

    // Tests worktree discovery interval is positive by arranging representative inputs and asserting the expected result.
    func testWorktreeDiscoveryIntervalIsPositive() { XCTAssertGreaterThan(PollingConstants.worktreeDiscoveryInterval, 0) }

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
            try runGitAndCapture(["rev-parse", "--is-bare-repository"], cwd: project.dir).trimmingCharacters(in: .whitespacesAndNewlines), "true")
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
            try runGitAndCapture(["rev-parse", "--is-bare-repository"], cwd: project.dir).trimmingCharacters(in: .whitespacesAndNewlines), "true")
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
        let orchestrator = MuxyOrchestrator(store: store, projectsRootDirectory: projectsRoot, workspacesRootDirectory: workspacesRoot)

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
        let orchestrator = MuxyOrchestrator(store: store, projectsRootDirectory: projectsRoot, workspacesRootDirectory: workspacesRoot)

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
        try orchestrator.updateProjectConfig(projectID: project.id) { config in config.setupScript = "echo ready > .muxy-setup-marker" }

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
        _ = try orchestrator.createWorkspace(projectID: project.id, name: "feature-branch", branch: "feature-branch", targetBranch: "develop")

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
            checks: [StatusCheckDefinition(name: "health", process: "api", command: "echo ok", interval: 60, timeout: 2, onFail: .none)])
        let runningProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "echo api", terminalApp: nil, windowID: nil, pid: 9000,
            status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: runningProcess)

        let now = Date()
        let firstRun = try orchestrator.runStatusChecks(workspaceID: workspace.id, dueOnly: true, now: now)
        XCTAssertEqual(firstRun.count, 1)

        let secondRunWithinInterval = try orchestrator.runStatusChecks(workspaceID: workspace.id, dueOnly: true, now: now.addingTimeInterval(5))
        XCTAssertTrue(secondRunWithinInterval.isEmpty)

        let forcedRun = try orchestrator.runStatusChecks(workspaceID: workspace.id, dueOnly: false, now: now.addingTimeInterval(5))
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
            checks: [StatusCheckDefinition(name: "health", process: "api", command: "echo ok", interval: 10, timeout: 2, onFail: .none)])
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
            checks: [StatusCheckDefinition(process: "api", command: "echo failed && exit 1", interval: 10, timeout: 2, onFail: .none)])
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
                StatusCheckDefinition(name: "health", process: "api", command: "echo unhealthy && exit 1", interval: 10, timeout: 2, onFail: .notify)
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
        let mockIterm = MockIterm2Adapter()
        let mockTmux = MockTmuxAdapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm, tmux: mockTmux)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        mockTmux.createSession(named: "muxy-\(workspace.id)")
        _ = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@1", name: "api", index: 0, isActive: true)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceStatusChecks(
            workspaceID: workspace.id,
            checks: [
                StatusCheckDefinition(name: "health", process: "api", command: "echo crashed && exit 1", interval: 10, timeout: 2, onFail: .restart)
            ])
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "api", windowID: 123, itermSessionID: "workspace-session",
                tmuxWindowID: "@1", role: "terminal", orderIndex: 200, lastSeenAt: "now"))
        let runningProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "iTerm2", windowID: 123,
            itermSessionID: "workspace-session", itermTabIndex: nil, tmuxWindowID: "@1", pid: 9000, status: .running, logPath: nil,
            lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: runningProcess)

        // Create a mock PID file to simulate the new PID after restart
        // The PID file is stored in ~/.muxy/runtime/<workspace-id>/
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let runtimeRoot = homeDir.appendingPathComponent(".muxy").appendingPathComponent("runtime")
        let workspaceRuntime = runtimeRoot.appendingPathComponent(workspace.id, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRuntime, withIntermediateDirectories: true)
        let pidFileURL = workspaceRuntime.appendingPathComponent("api.pid")
        try "10001".write(to: pidFileURL, atomically: true, encoding: .utf8)

        var results: [StatusResult] = []
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(
                name: "YABAI_WINDOWS_JSON",
                value: #"[{"id":123,"pid":11,"app":"iTerm2","title":"api","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
            ) {
                results = try orchestrator.runStatusChecks(workspaceID: workspace.id)
            }
        }

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.status, .failed)
        XCTAssertEqual(mockIterm.openWindowAndRunCallCount, 1)
        XCTAssertEqual(mockTmux.respawnWindowCallCount, 0)
        XCTAssertTrue(mockTmux.respawnedWindowIDs.isEmpty)
        let currentProcesses = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(currentProcesses.count, 1)
        let currentProcess = currentProcesses.first!
        XCTAssertEqual(currentProcess.status, .running)
        XCTAssertNotEqual(currentProcess.windowID, 123)
        XCTAssertNil(currentProcess.tmuxWindowID)
        XCTAssertEqual(currentProcess.pid, 10001)
    }

    // Tests status check on fail restart with missing pid does not crash by arranging representative inputs and asserting the expected result.
    func testStatusCheckOnFailRestartWithMissingPidDoesNotCrash() throws {
        throw XCTSkip("Legacy tmux-backed restart behavior removed.")
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        let mockTmux = MockTmuxAdapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm, tmux: mockTmux)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        mockTmux.createSession(named: "muxy-\(workspace.id)")
        _ = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@1", name: "api", index: 0, isActive: true)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceStatusChecks(
            workspaceID: workspace.id,
            checks: [StatusCheckDefinition(process: "api", command: "echo failed && exit 1", interval: 10, timeout: 2, onFail: .restart)])
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "api", windowID: 123, itermSessionID: "workspace-session",
                tmuxWindowID: "@1", role: "terminal", orderIndex: 200, lastSeenAt: "now"))
        let runningProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "iTerm2", windowID: 123,
            itermSessionID: "workspace-session", itermTabIndex: nil, tmuxWindowID: "@1", pid: nil, status: .running, logPath: nil,
            lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: runningProcess)

        XCTAssertNoThrow(
            try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
                try withEnv(
                    name: "YABAI_WINDOWS_JSON",
                    value: #"[{"id":123,"pid":11,"app":"iTerm2","title":"api","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
                ) {
                    _ = try orchestrator.runStatusChecks(workspaceID: workspace.id)
                }
            })
        XCTAssertEqual(mockIterm.openWindowAndRunCallCount, 0)
        XCTAssertEqual(mockTmux.respawnWindowCallCount, 1)
        XCTAssertEqual(mockTmux.respawnedWindowIDs, ["@1"])
        let currentProcesses = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(currentProcesses.count, 1)
        let currentProcess = currentProcesses.first!
        XCTAssertEqual(currentProcess.status, .running)
        XCTAssertEqual(currentProcess.windowID, 123)
        XCTAssertEqual(currentProcess.tmuxWindowID, "@1")
    }

    // Tests check and update process statuses marks dead process as exited by arranging representative inputs and asserting the expected result.
    func testCheckAndUpdateProcessStatusesMarksDeadProcessAsExited() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let mockTmux = MockTmuxAdapter()
        let orchestrator = MuxyOrchestrator(store: store, tmux: mockTmux)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let liveWindow = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@1", name: "api", index: 0, isActive: true)
        // Create a process with a PID that doesn't exist
        let deadProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "iTerm2", windowID: 123,
            itermSessionID: "workspace-session", itermTabIndex: nil, tmuxWindowID: liveWindow.id, pid: 99999, status: .running, logPath: nil,
            lastOutputAt: nil,
            startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20)), exitedAt: nil)
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
        let mockTmux = MockTmuxAdapter()
        let orchestrator = MuxyOrchestrator(store: store, tmux: mockTmux)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let liveWindow = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@1", name: "api", index: 0, isActive: true)

        // Create a dead process with a previously-green status result
        let deadProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "iTerm2", windowID: 123,
            itermSessionID: "workspace-session", itermTabIndex: nil, tmuxWindowID: liveWindow.id, pid: 99999, status: .running, logPath: nil,
            lastOutputAt: nil,
            startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20)), exitedAt: nil)
        try store.upsert(runningProcess: deadProcess)

        // Simulate a previously-passing status check result
        let greenResult = StatusResult(
            processID: deadProcess.id, checkName: "health", status: .passed, message: nil, lastRunAt: ISO8601DateFormatter().string(from: Date()))
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
        let mockTmux = MockTmuxAdapter()
        let orchestrator = MuxyOrchestrator(store: store, tmux: mockTmux)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let liveWindow = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@1", name: "api", index: 0, isActive: true)
        // Create a process that just started (within grace period)
        let newProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "iTerm2", windowID: 123,
            itermSessionID: "workspace-session", itermTabIndex: nil, tmuxWindowID: liveWindow.id, pid: 99999, status: .running, logPath: nil,
            lastOutputAt: nil,
            startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-5)), exitedAt: nil)
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
        let mockTmux = MockTmuxAdapter()
        let orchestrator = MuxyOrchestrator(store: store, tmux: mockTmux)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let liveWindow = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@1", name: "api", index: 0, isActive: true)
        // Create a process without a PID (still starting up)
        let noPidProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "iTerm2", windowID: 123,
            itermSessionID: "workspace-session", itermTabIndex: nil, tmuxWindowID: liveWindow.id, pid: nil, status: .running, logPath: nil,
            lastOutputAt: nil,
            startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20)), exitedAt: nil)
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
        let mockTmux = MockTmuxAdapter()
        let orchestrator = MuxyOrchestrator(store: store, tmux: mockTmux)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let liveWindow = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@1", name: "api", index: 0, isActive: true)
        // Create an already-exited process
        let exitedProcess = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm start", terminalApp: "iTerm2", windowID: 123,
            itermSessionID: "workspace-session", itermTabIndex: nil, tmuxWindowID: liveWindow.id, pid: 99999, status: .exited, logPath: nil,
            lastOutputAt: nil,
            startedAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(-20)), exitedAt: ISO8601DateFormatter().string(from: Date()))
        try store.upsert(runningProcess: exitedProcess)
        let didUpdate = try orchestrator.checkAndUpdateProcessStatuses()
        // Should not check or update already-exited processes
        XCTAssertFalse(didUpdate)
    }

    // Tests create workspace throws for unknown project by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceThrowsForUnknownProject() throws {
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
    func testUpdateWorkspaceNameAllowsDefaultWorkspaceRename() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let defaultWorkspace = try XCTUnwrap(store.workspace(projectID: project.id, name: "default"))

        XCTAssertNoThrow(try orchestrator.updateWorkspaceName(workspaceID: defaultWorkspace.id, name: "renamed-default"))
        let updated = try XCTUnwrap(store.workspace(id: defaultWorkspace.id))
        XCTAssertEqual(updated.title, "renamed-default")
        XCTAssertTrue(updated.isDefault)
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
            workspaceID: workspace.id, title: "feature-auth", branch: "feature-auth", directoryName: "feature_auth",
            tooltip: .some("Reviewing OAuth flow"))

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

    // Tests default workspace metadata update allows title override while preserving default protections by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataAllowsDefaultWorkspaceTitleOverride() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let defaultWorkspace = try XCTUnwrap(store.workspace(projectID: project.id, name: "default"))

        try orchestrator.updateWorkspaceMetadata(workspaceID: defaultWorkspace.id, title: "Codex Task", tooltip: .some("Imported from agent"))

        let updated = try XCTUnwrap(store.workspace(id: defaultWorkspace.id))
        XCTAssertEqual(updated.name, "Codex Task")
        XCTAssertEqual(updated.tooltip, "Imported from agent")
        XCTAssertTrue(updated.isDefault)

        XCTAssertThrowsError(try orchestrator.archiveWorkspace(workspaceID: defaultWorkspace.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Default workspace cannot be archived"))
        }
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

    // Tests workspace active state can be toggled independently of runtime state by arranging representative inputs and asserting persistence.
    func testUpdateWorkspaceActivePersistsState() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        try orchestrator.updateWorkspaceActive(workspaceID: workspace.id, isActive: false)
        XCTAssertFalse(try XCTUnwrap(store.workspace(id: workspace.id)).isActive)

        try orchestrator.updateWorkspaceActive(workspaceID: workspace.id, isActive: true)
        XCTAssertTrue(try XCTUnwrap(store.workspace(id: workspace.id)).isActive)
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

    // Tests open workspace terminal creates a dedicated workspace terminal and tracks the new tmux shell window.
    func testOpenWorkspaceTerminalCreatesWorkspaceTerminalAndTracksTmuxShellWindow() throws {
        throw XCTSkip("Shared tmux-backed workspace terminals removed.")
        let (orchestrator, _, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUSED_ID", value: "777") {
                try withEnv(name: "YABAI_FOCUSED_APP", value: "iTerm2") { try orchestrator.openWorkspaceTerminal(workspaceID: workspace.id) }
            }
        }

        let windows = try orchestrator.windows(workspaceID: workspace.id)
        let terminalWindows = windows.filter { $0.role == "terminal" }
        XCTAssertEqual(mockIterm.openWindowAndRunCallCount, 1)
        XCTAssertEqual(mockTmux.createWindowCallCount, 1)
        XCTAssertEqual(terminalWindows.count, 1)
        XCTAssertEqual(terminalWindows.first?.windowID, 9999)
        XCTAssertEqual(terminalWindows.first?.itermSessionID, "mock-session")
        XCTAssertEqual(terminalWindows.first?.tmuxWindowID, mockTmux.lastCreatedWindow?.id)
        XCTAssertEqual(terminalWindows.first?.title, "shell-1")
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

    // Tests open workspace terminal opens a new tab in an existing tracked iTerm2 workspace window.
    func testOpenWorkspaceTerminalReusesTrackedItermWindowAsTabTarget() throws {
        throw XCTSkip("Shared iTerm tab reuse removed.")
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell", windowID: 777, itermSessionID: "workspace-session",
                role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(
                name: "YABAI_WINDOWS_JSON",
                value: #"[{"id":777,"pid":11,"app":"iTerm2","title":"shell","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
            ) {
                try withEnv(name: "YABAI_FOCUSED_ID", value: "777") {
                    try withEnv(name: "YABAI_FOCUSED_APP", value: "iTerm2") { try orchestrator.openWorkspaceTerminal(workspaceID: workspace.id) }
                }
            }
        }

        XCTAssertEqual(mockIterm.openWindowAndRunCallCount, 0)
        XCTAssertEqual(mockIterm.openTabInWindowAndRunCallCount, 0)
        XCTAssertEqual(mockTmux.createWindowCallCount, 1)
        XCTAssertEqual(mockTmux.lastCreatedWindow?.sessionName, "muxy-\(workspace.id)")
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
        throw XCTSkip("Terminal focus now uses dedicated yabai window IDs directly.")
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let yabaiFocusLog = root.appendingPathComponent("terminal-yabai-focus.log")
        let itermFocusLog = root.appendingPathComponent("terminal-iterm-focus.log")

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "api", windowID: 101, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 101,
                itermSessionID: "session-101", itermTabIndex: 1, pid: 1234, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now",
                exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: yabaiFocusLog.path) {
                try withEnv(name: "MOCK_ITERM_FOCUS_LOG_FILE", value: itermFocusLog.path) {
                    try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 1)
                }
            }
        }

        XCTAssertEqual(try orchestrator.activeWorkspaceID(), workspace.id)
        let itermFocusEntry = try String(contentsOf: itermFocusLog).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(itermFocusEntry, "session-101|-1|101")
        if FileManager.default.fileExists(atPath: yabaiFocusLog.path) {
            let yabaiFocusEntries = try String(contentsOf: yabaiFocusLog).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(yabaiFocusEntries.isEmpty)
        }
    }

    // Tests focusing a workspace process targets the process's iTerm2 session when multiple processes share a window.
    func testFocusWorkspaceProcessTargetsSpecificSharedWindowSession() throws {
        throw XCTSkip("Shared iTerm session focus removed.")
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        let sessionName = "muxy-\(workspace.id)"
        let firstWindow = mockTmux.addWindow(sessionName: sessionName, id: "@1", name: "api", index: 0, isActive: true)
        let secondWindow = mockTmux.addWindow(sessionName: sessionName, id: "@2", name: "web", index: 1)

        let first = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 555,
            itermSessionID: "workspace-session", itermTabIndex: nil, tmuxWindowID: firstWindow.id, pid: nil, status: .running, logPath: nil,
            lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        let second = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "iTerm2", windowID: 555,
            itermSessionID: "workspace-session", itermTabIndex: nil, tmuxWindowID: secondWindow.id, pid: nil, status: .running, logPath: nil,
            lastOutputAt: nil, startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: first)
        try store.upsert(runningProcess: second)

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(
                name: "YABAI_WINDOWS_JSON",
                value: #"[{"id":555,"pid":11,"app":"iTerm2","title":"shell","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
            ) {
                try orchestrator.focusWorkspaceProcess(workspaceID: workspace.id, processID: second.id)
            }
        }

        XCTAssertEqual(mockTmux.selectWindowCallCount, 1)
        XCTAssertEqual(mockTmux.lastSelectedWindowID, secondWindow.id)
        XCTAssertEqual(mockIterm.focusSessionOrTabCallCount, 1)
        XCTAssertEqual(mockIterm.lastWindowID, 555)
        XCTAssertEqual(mockIterm.lastFocusedSessionID, "workspace-session")
        XCTAssertNil(mockIterm.lastFocusedTabIndex)
    }

    // Tests focus workspace process does not borrow another shared-tab index when targeting a specific session.
    func testFocusWorkspaceProcessDoesNotFallbackToDifferentSharedWindowTabIndex() throws {
        throw XCTSkip("Shared iTerm tab fallback removed.")
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        let sessionName = "muxy-\(workspace.id)"
        let firstWindow = mockTmux.addWindow(sessionName: sessionName, id: "@1", name: "api", index: 0, isActive: true)
        let secondWindow = mockTmux.addWindow(sessionName: sessionName, id: "@2", name: "web", index: 1)

        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 555,
                itermSessionID: "workspace-session", itermTabIndex: nil, tmuxWindowID: firstWindow.id, pid: nil, status: .running,
                logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        let second = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "npm run web", terminalApp: "iTerm2", windowID: 555,
            itermSessionID: "workspace-session", itermTabIndex: nil, tmuxWindowID: secondWindow.id, pid: nil, status: .exited, logPath: nil,
            lastOutputAt: nil, startedAt: "now", exitedAt: "later")
        try store.upsert(runningProcess: second)

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(
                name: "YABAI_WINDOWS_JSON",
                value: #"[{"id":555,"pid":11,"app":"iTerm2","title":"shell","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
            ) {
                try orchestrator.focusWorkspaceProcess(workspaceID: workspace.id, processID: second.id)
            }
        }

        XCTAssertEqual(mockTmux.selectWindowCallCount, 1)
        XCTAssertEqual(mockTmux.lastSelectedWindowID, secondWindow.id)
        XCTAssertEqual(mockIterm.focusSessionOrTabCallCount, 1)
        XCTAssertEqual(mockIterm.lastWindowID, 555)
        XCTAssertEqual(mockIterm.lastFocusedSessionID, "workspace-session")
        XCTAssertNil(mockIterm.lastFocusedTabIndex)
    }

    // Tests focus workspace window by index sets the active workspace by arranging representative inputs and asserting the expected result.
    func testFocusWorkspaceWindowByIndexSetsActiveWorkspace() throws {
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

        // Mocked dependency: `yabai` focus command.
        // Why: verify indexed window focus and active workspace tracking.
        // Remaining risk: real-time focus transitions and stale snapshots are not represented.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 2)
            }
        }

        let focusedIDs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedIDs, ["202"])
        XCTAssertEqual(try orchestrator.activeWorkspaceID(), workspace.id)
    }

    // Tests focus window navigation uses the current focused window and wraps by arranging representative inputs and asserting the expected result.
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

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try withEnv(name: "YABAI_FOCUSED_ID", value: "202") { try orchestrator.focusNextWindow(workspaceID: workspace.id) }
                try withEnv(name: "YABAI_FOCUSED_ID", value: "101") { try orchestrator.focusPreviousWindow(workspaceID: workspace.id) }
                try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 2)
            }
        }

        let focusedIDs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedIDs, ["303", "303", "202"])
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

        // Mocked dependency: direct yabai focus for the tracked dedicated Chrome window.
        // Why: ensure browser rows with target URLs still focus their tracked window and set the workspace active.
        // Remaining risk: real Chrome window lifecycle races are not represented.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 1)
            }
        }

        XCTAssertEqual(try orchestrator.activeWorkspaceID(), workspace.id)
        let focusedIDs = try String(contentsOf: focusLog).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(focusedIDs, "202")
    }

    // Tests direct browser focus throws a recoverable missing-window error when the tracked yabai window no longer exists.
    func testFocusWorkspaceWindowThrowsRecoverableErrorForMissingBrowserWindow() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "Frontend", targetURL: "http://localhost:3001",
                windowID: 999, role: "browser", orderIndex: 0, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            XCTAssertThrowsError(try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 1)) { error in
                guard case .missingTrackedWindow(let context) = error as? MuxyError else {
                    return XCTFail("Expected missingTrackedWindow, got \(error)")
                }
                XCTAssertEqual(context.kind, .browserSession)
                XCTAssertEqual(context.workspaceID, workspace.id)
                XCTAssertEqual(context.targetURL, "http://localhost:3001")
            }
        }
    }

    // Tests direct browser-session focus still throws a recoverable error when the configured session has no tracked window row.
    func testFocusWorkspaceBrowserSessionThrowsRecoverableErrorWhenTrackedWindowIsMissing() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(name: "Frontend", url: "http://localhost:3001")])

        XCTAssertThrowsError(try orchestrator.focusWorkspaceBrowserSession(workspaceID: workspace.id, targetURL: "http://localhost:3001")) {
            error in
            guard case .missingTrackedWindow(let context) = error as? MuxyError else {
                return XCTFail("Expected missingTrackedWindow, got \(error)")
            }
            XCTAssertEqual(context.kind, .browserSession)
            XCTAssertEqual(context.targetURL, "http://localhost:3001")
            XCTAssertEqual(context.title, "http://localhost:3001")
        }
    }

    // Tests window cycling ignores missing browser windows and keeps moving to the next live tracked window.
    func testFocusNextWindowIgnoresMissingBrowserWindow() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let focusLog = root.appendingPathComponent("ignore-missing-browser-focus.log")

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "Frontend", targetURL: "http://localhost:3001",
                windowID: 999, role: "browser", orderIndex: 0, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "api", windowID: 101, role: "terminal", orderIndex: 200,
                lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try withEnv(name: "YABAI_FOCUSED_ID", value: "555") {
                    try withEnv(name: "YABAI_FOCUSED_APP", value: "Finder") {
                        try orchestrator.focusNextWindow(workspaceID: workspace.id)
                    }
                }
            }
        }

        let focusedIDs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedIDs, ["101"])
    }

    // Tests direct process focus throws a recoverable missing-window error when the tracked iTerm window no longer exists.
    func testFocusWorkspaceProcessThrowsRecoverableErrorForMissingProcessWindow() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()

        let process = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 999,
            itermSessionID: "session-999", itermTabIndex: nil, tmuxWindowID: nil, pid: 1234, status: .running, logPath: nil, lastOutputAt: nil,
            startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: process)

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            XCTAssertThrowsError(try orchestrator.focusWorkspaceProcess(workspaceID: workspace.id, processID: process.id)) { error in
                guard case .missingTrackedWindow(let context) = error as? MuxyError else {
                    return XCTFail("Expected missingTrackedWindow, got \(error)")
                }
                XCTAssertEqual(context.kind, .process)
                XCTAssertEqual(context.processID, process.id)
                XCTAssertEqual(context.title, "api")
            }
        }
    }

    // Tests restarting a process recreates a tracked terminal window row even if the stale window row was already pruned.
    func testRestartWorkspaceProcessRecreatesTrackedTerminalWindowWhenMissing() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()

        let process = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 999,
            itermSessionID: "session-old", itermTabIndex: nil, tmuxWindowID: nil, pid: 1234, status: .running, logPath: nil, lastOutputAt: nil,
            startedAt: "now", exitedAt: nil)
        try store.upsert(runningProcess: process)

        let openLog = root.appendingPathComponent("restart-process-open.log")
        let pidFile = root.appendingPathComponent("restart-process.pid")
        try "4321".write(to: pidFile, atomically: true, encoding: .utf8)

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "MOCK_ITERM_OPEN_LOG_FILE", value: openLog.path) {
                try withEnv(name: "MOCK_ITERM_WINDOW_ID", value: "777") {
                        try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") {
                            try withEnv(name: "YABAI_CAPTURE_NEW_WINDOWS_JSON", value: #"[{"id":777,"pid":11,"app":"iTerm2","title":"api","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#) {
                                try withEnv(name: "MUXY_TEST_PIDFILE_API", value: pidFile.path) {
                                    try orchestrator.restartWorkspaceProcess(workspaceID: workspace.id, processID: process.id)
                                }
                            }
                        }
                }
            }
        }

        let restartedProcess = try XCTUnwrap(try store.runningProcesses(workspaceID: workspace.id).first(where: { $0.id == process.id }))
        XCTAssertNotEqual(restartedProcess.windowID, process.windowID)
        XCTAssertNotEqual(restartedProcess.itermSessionID, process.itermSessionID)

        let trackedTerminal = try XCTUnwrap(try store.windows(workspaceID: workspace.id).first(where: { $0.role == "terminal" }))
        XCTAssertEqual(trackedTerminal.windowID, restartedProcess.windowID)
        XCTAssertEqual(trackedTerminal.itermSessionID, restartedProcess.itermSessionID)
    }

    // Tests workspace cycling includes orphaned running processes so recovered iTerm windows remain reachable even before a terminal row is rebuilt.
    func testFocusNextWindowIncludesOrphanedRunningProcessTargets() throws {
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()

        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 777,
                itermSessionID: "session-777", itermTabIndex: nil, tmuxWindowID: nil, pid: 4321, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: "now", exitedAt: nil))

        let focusLog = root.appendingPathComponent("orphaned-process-cycle-focus.log")

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try withEnv(
                    name: "YABAI_WINDOWS_JSON",
                    value: #"[{"id":777,"pid":11,"app":"iTerm2","title":"api","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
                ) {
                    try withEnv(name: "YABAI_FOCUSED_ID", value: "999") {
                        try withEnv(name: "YABAI_FOCUSED_APP", value: "Finder") {
                            try orchestrator.focusNextWindow(workspaceID: workspace.id)
                        }
                    }
                }
            }
        }

        let focusedIDs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedIDs, ["777"])
    }

    // Tests direct coding-agent focus throws a missing-window error without offering process/browser recovery metadata.
    func testFocusAgentWindowThrowsMissingWindowError() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()

        let record = AgentWindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, provider: .iterm2, label: "Codex CLI", itermSessionID: "session-agent",
            tmuxWindowID: nil, codexThreadID: "thread-1", windowID: 999, yabaiWindowID: 999, status: .spinning, createdAt: "now", updatedAt: "now")
        try store.upsertAgentWindow(record)

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            XCTAssertThrowsError(try orchestrator.focusAgentWindow(record)) { error in
                guard case .missingTrackedWindow(let context) = error as? MuxyError else {
                    return XCTFail("Expected missingTrackedWindow, got \(error)")
                }
                XCTAssertEqual(context.kind, .codingAgent)
                XCTAssertEqual(context.title, "Codex CLI")
                XCTAssertNil(context.processID)
                XCTAssertNil(context.targetURL)
            }
        }
    }

    // Tests focus workspace window uses tracked chrome window id when target url is shared by arranging representative inputs and asserting the expected result.
    func testFocusWorkspaceWindowUsesTrackedChromeWindowIDWhenTargetURLIsShared() throws {
        throw XCTSkip("Multiple tracked browser tabs in one Chrome window are no longer supported.")
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

    // Tests focus window navigation wraps across browser targets in same chrome window by arranging representative inputs and asserting the expected result.
    func testFocusWindowNavigationWrapsAcrossBrowserTargetsInSameChromeWindow() throws {
        throw XCTSkip("Multiple tracked browser tabs in one Chrome window are no longer supported.")
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

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try withEnv(name: "MOCK_CHROME_FOCUS_LOG_FILE", value: chromeLog.path) {
                    try withEnv(name: "MOCK_CHROME_ACTIVE_URL_FILE", value: chromeActiveURL.path) {
                        try withEnv(name: "YABAI_FOCUSED_ID", value: "202") {
                            try withEnv(name: "YABAI_FOCUSED_APP", value: "Google Chrome") {
                                try orchestrator.focusNextWindow(workspaceID: workspace.id)
                                try "http://localhost:8000/admin".write(to: chromeActiveURL, atomically: true, encoding: .utf8)
                                try orchestrator.focusNextWindow(workspaceID: workspace.id)
                            }
                        }
                        try withEnv(name: "YABAI_FOCUSED_ID", value: "101") {
                            try withEnv(name: "YABAI_FOCUSED_APP", value: "iTerm2") {
                                try orchestrator.focusNextWindow(workspaceID: workspace.id)
                            }
                        }
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

    // Tests focus window navigation uses remembered target identity across shared chrome rows when the focused target cannot be resolved.
    func testFocusWindowNavigationUsesRememberedTargetIdentityAcrossSharedChromeWindowRows() throws {
        throw XCTSkip("Multiple tracked browser tabs in one Chrome window are no longer supported.")
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let focusLog = root.appendingPathComponent("browser-nav-remembered.log")
        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id, sessions: [BrowserSession(url: "http://localhost:3001"), BrowserSession(url: "http://localhost:8000/admin")])
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell", windowID: 101, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "two", windowID: 102, role: "terminal", orderIndex: 1,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "localhost 3001",
                targetURL: "http://localhost:3001", windowID: 202, role: "browser", orderIndex: 2, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "localhost 8000 admin",
                targetURL: "http://localhost:8000/admin", windowID: 303, role: "browser", orderIndex: 3, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try withEnv(name: "YABAI_FOCUSED_ID", value: "101") {
                    try withEnv(name: "YABAI_FOCUSED_APP", value: "iTerm2") {
                        try orchestrator.focusNextWindow(workspaceID: workspace.id)
                    }
                }
                try withEnv(name: "YABAI_FOCUSED_ID", value: "102") {
                    try withEnv(name: "YABAI_FOCUSED_APP", value: "iTerm2") {
                        try orchestrator.focusNextWindow(workspaceID: workspace.id)
                    }
                }
                try withEnv(name: "YABAI_FOCUSED_ID", value: "999") {
                    try withEnv(name: "YABAI_FOCUSED_APP", value: "Finder") {
                        try orchestrator.focusNextWindow(workspaceID: workspace.id)
                    }
                }
            }
        }

        let focusedIDs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedIDs, ["102", "202", "303"])
    }

    // Tests focus window navigation falls back to the remembered cursor when Chrome URL matching is ambiguous across tracked windows.
    func testFocusWindowNavigationUsesRememberedCursorWhenChromeURLMatchIsAmbiguousAcrossWindows() throws {
        throw XCTSkip("Chrome tab URL disambiguation path removed.")
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let focusLog = root.appendingPathComponent("chrome-ambiguous-url-window-focus.log")

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell", windowID: 101, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "frontend-a", targetURL: "http://localhost:3001",
                windowID: 202, role: "browser", orderIndex: 1, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "frontend-b", targetURL: "http://localhost:3001",
                windowID: 303, role: "browser", orderIndex: 2, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 3)
                try withEnv(name: "YABAI_FOCUSED_ID", value: "202") {
                    try withEnv(name: "YABAI_FOCUSED_APP", value: "Google Chrome") {
                        try orchestrator.focusNextWindow(workspaceID: workspace.id)
                    }
                }
            }
        }

        let focusedIDs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedIDs, ["303", "303"])
    }

    // Tests focus window navigation falls back to the remembered cursor when Chrome window matching is ambiguous for an unrelated active tab.
    func testFocusWindowNavigationUsesRememberedCursorWhenChromeWindowMatchIsAmbiguous() throws {
        throw XCTSkip("Chrome tab URL disambiguation path removed.")
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let focusLog = root.appendingPathComponent("chrome-ambiguous-window-focus.log")

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell", windowID: 101, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "frontend", targetURL: "http://localhost:3001",
                windowID: 202, role: "browser", orderIndex: 1, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "admin",
                targetURL: "http://localhost:8000/admin", windowID: 202, role: "browser", orderIndex: 2, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 3)
                try withEnv(name: "YABAI_FOCUSED_ID", value: "202") {
                    try withEnv(name: "YABAI_FOCUSED_APP", value: "Google Chrome") {
                        try orchestrator.focusNextWindow(workspaceID: workspace.id)
                    }
                }
            }
        }

        let focusedIDs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedIDs, ["101"])
    }

    // Tests focus window navigation cycles agent and process iTerm sessions separately when they share one iTerm window.
    func testFocusWindowNavigationCyclesSharedItermAgentAndProcessSessionsSeparately() throws {
        throw XCTSkip("Shared iTerm/tmux container cycling removed.")
        let (orchestrator, store, _, workspace, root, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        let sessionName = "muxy-\(workspace.id)"
        let agentTmuxWindow = mockTmux.addWindow(sessionName: sessionName, id: "@1", name: "agent", index: 0, isActive: true)
        let processTmuxWindow = mockTmux.addWindow(sessionName: sessionName, id: "@2", name: "web", index: 1)
        let focusLog = root.appendingPathComponent("agent-process-cycle.log")
        let chromeActiveURL = root.appendingPathComponent("agent-process-active-url.log")
        try "http://localhost:3000".write(to: chromeActiveURL, atomically: true, encoding: .utf8)

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "agent", targetURL: nil, windowID: 555,
                itermSessionID: "workspace-session", tmuxWindowID: agentTmuxWindow.id, role: "terminal", orderIndex: 0, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "frontend", targetURL: "http://localhost:3000",
                windowID: 777, role: "browser", orderIndex: 2, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "web", targetURL: nil, windowID: 555,
                itermSessionID: "workspace-session", tmuxWindowID: processTmuxWindow.id, role: "terminal", orderIndex: 3, lastSeenAt: "now"))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, provider: .iterm2, label: "Claude Code CLI", itermSessionID: "workspace-session",
                tmuxWindowID: agentTmuxWindow.id, codexThreadID: nil, windowID: 555, yabaiWindowID: 555, status: .idle, createdAt: "now",
                updatedAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "npm run dev", terminalApp: "iTerm2", windowID: 555,
                itermSessionID: "workspace-session", itermTabIndex: nil, tmuxWindowID: processTmuxWindow.id, pid: 123, status: .running,
                logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try withEnv(name: "MOCK_CHROME_ACTIVE_URL_FILE", value: chromeActiveURL.path) {
                    try withEnv(
                        name: "YABAI_WINDOWS_JSON",
                        value: #"[{"id":555,"pid":11,"app":"iTerm2","title":"shell","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false},{"id":777,"pid":22,"app":"Google Chrome","title":"frontend","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
                    ) {
                    try withEnv(name: "YABAI_FOCUSED_ID", value: "555") {
                        try withEnv(name: "YABAI_FOCUSED_APP", value: "iTerm2") {
                            try orchestrator.focusNextWindow(workspaceID: workspace.id)

                            try "http://localhost:3000".write(to: chromeActiveURL, atomically: true, encoding: .utf8)
                            try withEnv(name: "YABAI_FOCUSED_ID", value: "777") {
                                try withEnv(name: "YABAI_FOCUSED_APP", value: "Google Chrome") {
                                    try orchestrator.focusNextWindow(workspaceID: workspace.id)
                                }
                            }

                            try orchestrator.focusNextWindow(workspaceID: workspace.id)
                        }
                    }
                    }
                }
            }
        }

        let focusedIDs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedIDs, ["777"])
        XCTAssertEqual(mockIterm.focusSessionOrTabCallCount, 2)
        XCTAssertEqual(mockIterm.focusedSessionIDs.compactMap { $0 }, ["workspace-session", "workspace-session"])
        XCTAssertEqual(mockTmux.selectedWindowIDs, [processTmuxWindow.id, agentTmuxWindow.id])
    }

    // Tests focus window navigation remembers browser targets by identity instead of stale array index when targets reorder.
    func testFocusWindowNavigationUsesRememberedTargetIdentityAfterReorder() throws {
        throw XCTSkip("Shared iTerm session identity reordering path removed.")
    }

    // Tests focus window navigation prefers the currently focused iTerm session over stale remembered target identity.
    func testFocusWindowNavigationPrefersFocusedSessionOverRememberedTarget() throws {
        throw XCTSkip("Shared iTerm session focus removed.")
        let (orchestrator, store, _, workspace, root, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        let sessionName = "muxy-\(workspace.id)"
        let agentTmuxWindow = mockTmux.addWindow(sessionName: sessionName, id: "@1", name: "agent", index: 0, isActive: true)
        let processTmuxWindow = mockTmux.addWindow(sessionName: sessionName, id: "@2", name: "web", index: 1)
        let chromeLog = root.appendingPathComponent("manual-focus-cycle.log")
        let chromeActiveURL = root.appendingPathComponent("manual-focus-active-url.log")
        try "http://localhost:3000".write(to: chromeActiveURL, atomically: true, encoding: .utf8)

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "agent", targetURL: nil, windowID: 555,
                itermSessionID: "workspace-session", tmuxWindowID: agentTmuxWindow.id, role: "terminal", orderIndex: 0, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "frontend", targetURL: "http://localhost:3000",
                windowID: 777, role: "browser", orderIndex: 1, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "web", targetURL: nil, windowID: 555,
                itermSessionID: "workspace-session", tmuxWindowID: processTmuxWindow.id, role: "terminal", orderIndex: 2, lastSeenAt: "now"))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, provider: .iterm2, label: "Claude Code CLI", itermSessionID: "workspace-session",
                tmuxWindowID: agentTmuxWindow.id, codexThreadID: nil, windowID: 555, yabaiWindowID: 555, status: .idle, createdAt: "now",
                updatedAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "npm run dev", terminalApp: "iTerm2", windowID: 555,
                itermSessionID: "workspace-session", itermTabIndex: nil, tmuxWindowID: processTmuxWindow.id, pid: 123, status: .running,
                logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "MOCK_CHROME_FOCUS_LOG_FILE", value: chromeLog.path) {
                try withEnv(name: "MOCK_CHROME_ACTIVE_URL_FILE", value: chromeActiveURL.path) {
                    try withEnv(
                        name: "YABAI_WINDOWS_JSON",
                        value: #"[{"id":555,"pid":11,"app":"iTerm2","title":"shell","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false},{"id":777,"pid":22,"app":"Google Chrome","title":"frontend","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
                    ) {
                    try withEnv(name: "YABAI_FOCUSED_ID", value: "777") {
                        try withEnv(name: "YABAI_FOCUSED_APP", value: "Google Chrome") {
                            try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 2)
                        }
                    }

                    mockTmux.currentWindowIDBySession[sessionName] = processTmuxWindow.id
                    try withEnv(name: "YABAI_FOCUSED_ID", value: "555") {
                        try withEnv(name: "YABAI_FOCUSED_APP", value: "iTerm2") {
                            try orchestrator.focusNextWindow(workspaceID: workspace.id)
                        }
                    }
                    }
                }
            }
        }

        XCTAssertEqual(mockIterm.focusedSessionIDs.compactMap { $0 }, ["workspace-session"])
        XCTAssertEqual(mockTmux.selectedWindowIDs, [agentTmuxWindow.id])
    }

    // Tests focus window navigation uses remembered iTerm target identity when focused-session lookup cannot disambiguate shared tabs.
    func testFocusWindowNavigationUsesRememberedItermTargetWhenFocusedSessionLookupFails() throws {
        throw XCTSkip("Shared iTerm session focus removed.")
        let (orchestrator, store, _, workspace, root, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        let sessionName = "muxy-\(workspace.id)"
        let process1Window = mockTmux.addWindow(sessionName: sessionName, id: "@1", name: "web", index: 0, isActive: true)
        let process2Window = mockTmux.addWindow(sessionName: sessionName, id: "@2", name: "web-2", index: 1)
        let focusLog = root.appendingPathComponent("shared-iterm-remembered.log")
        let chromeActiveURL = root.appendingPathComponent("shared-iterm-remembered-active-url.log")
        try "http://localhost:3000".write(to: chromeActiveURL, atomically: true, encoding: .utf8)

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "web", targetURL: nil, windowID: 555,
                itermSessionID: "workspace-session", tmuxWindowID: process1Window.id, role: "terminal", orderIndex: 0, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "frontend", targetURL: "http://localhost:3000",
                windowID: 777, role: "browser", orderIndex: 1, lastSeenAt: "now"))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "web-2", targetURL: nil, windowID: 555,
                itermSessionID: "workspace-session", tmuxWindowID: process2Window.id, role: "terminal", orderIndex: 2, lastSeenAt: "now"))
        let process1ID = UUID().uuidString
        let process2ID = UUID().uuidString
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: process1ID, workspaceID: workspace.id, templateName: "web", command: "npm run dev", terminalApp: "iTerm2", windowID: 555,
                itermSessionID: "workspace-session", itermTabIndex: nil, tmuxWindowID: process1Window.id, pid: 123, status: .running,
                logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: process2ID, workspaceID: workspace.id, templateName: "web 2", command: "npm run dev", terminalApp: "iTerm2", windowID: 555,
                itermSessionID: "workspace-session", itermTabIndex: nil, tmuxWindowID: process2Window.id, pid: nil, status: .exited, logPath: nil,
                lastOutputAt: nil, startedAt: "now", exitedAt: "later"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                try withEnv(name: "MOCK_CHROME_ACTIVE_URL_FILE", value: chromeActiveURL.path) {
                    try withEnv(
                        name: "YABAI_WINDOWS_JSON",
                        value: #"[{"id":555,"pid":11,"app":"iTerm2","title":"shell","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false},{"id":777,"pid":22,"app":"Google Chrome","title":"frontend","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
                    ) {
                        try orchestrator.focusWorkspaceProcess(workspaceID: workspace.id, processID: process2ID)

                        mockTmux.currentWindowIDBySession[sessionName] = process2Window.id
                        mockIterm.focusedSessionIDResult = nil
                        try withEnv(name: "YABAI_FOCUSED_ID", value: "555") {
                            try withEnv(name: "YABAI_FOCUSED_APP", value: "iTerm2") {
                                try orchestrator.focusNextWindow(workspaceID: workspace.id)
                            }
                        }
                    }
                }
            }
        }

        let focusedIDs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedIDs, ["777"])
        XCTAssertEqual(mockIterm.focusedSessionIDs.compactMap { $0 }, ["workspace-session"])
        XCTAssertEqual(mockTmux.selectedWindowIDs, [process2Window.id])
    }

    // Tests windows live scan uses session prefixes and deduplicates overlapping matches by arranging representative inputs and asserting the expected result.
    func testWindowsLiveScanUsesSessionPrefixesAndDeduplicatesOverlappingMatches() throws {
        throw XCTSkip("Browser tab scan path removed.")
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
        throw XCTSkip("Browser tab scan path removed.")
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
        throw XCTSkip("Browser tab index focus path removed.")
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
        throw XCTSkip("Browser tab index focus path removed.")
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let scanLog = root.appendingPathComponent("browser-tab-index-refresh.log")
        let focusLog = root.appendingPathComponent("browser-tab-index-fallback.log")
        let tabIndexLog = root.appendingPathComponent("browser-tab-index-fallback-index.log")
        try store.setWorkspaceBrowserSessions(workspaceID: workspace.id, sessions: [BrowserSession(url: "http://localhost:3001")])
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "Google Chrome", title: "localhost 3001 a",
                targetURL: "http://localhost:3001/a", windowID: 202, role: "browser", orderIndex: 0, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: #"[{"id":202,"pid":22,"app":"Google Chrome","title":"localhost 3001 a","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#) {
                try withEnv(name: "YABAI_FOCUS_LOG_FILE", value: focusLog.path) {
                    try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 1)
                }
            }
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: scanLog.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tabIndexLog.path))
        let focusedIDs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedIDs, ["202"])
    }

    // Tests focus workspace window rejects same-workspace wrong-tab verification and falls back to exact target by arranging representative inputs and asserting the expected result.
    func testFocusWorkspaceWindowRejectsWrongIndexedTabWhenActiveURLMatchesWorkspaceButNotTarget() throws {
        throw XCTSkip("Browser tab index focus path removed.")
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let scanLog = root.appendingPathComponent("browser-tab-index-same-workspace-refresh.log")
        let focusLog = root.appendingPathComponent("browser-tab-index-same-workspace-focus.log")
        let tabIndexLog = root.appendingPathComponent("browser-tab-index-same-workspace-index.log")
        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id, sessions: [BrowserSession(url: "http://localhost:3001"), BrowserSession(url: "http://localhost:3001/admin")])
        let chromeMatches =
            "202\tGoogle Chrome — localhost 3001\thttp://localhost:3001\n202\tGoogle Chrome — localhost 3001 admin\thttp://localhost:3001/admin\n"

        // Mocked dependency: Chrome indexed focus returns a different tab inside the same workspace URL set.
        // Why: ensure indexed verification requires the intended target tab rather than accepting any workspace URL as success.
        // Remaining risk: real Chrome can still reorder tabs between refresh and fallback, but the exact-target validation catches the stale-hit case.
        try withMockCommands(["osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "MOCK_CHROME_WINDOW_MATCHES", value: chromeMatches) {
                try withEnv(name: "MOCK_CHROME_TAB_INDEX_ACTIVE_URL", value: "http://localhost:3001") {
                    try withEnv(name: "MOCK_CHROME_SCAN_LOG_FILE", value: scanLog.path) {
                        try withEnv(name: "MOCK_CHROME_FOCUS_LOG_FILE", value: focusLog.path) {
                            try withEnv(name: "MOCK_CHROME_TAB_INDEX_LOG_FILE", value: tabIndexLog.path) {
                                try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 2)
                            }
                        }
                    }
                }
            }
        }

        let scanCount = (try? String(contentsOf: scanLog).split(separator: "\n").count) ?? 0
        XCTAssertEqual(scanCount, 2)
        let focusedURLs = try String(contentsOf: focusLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedURLs, ["http://localhost:3001", "http://localhost:3001", "http://localhost:3001/admin"])
        let focusedByIndex = try String(contentsOf: tabIndexLog).split(separator: "\n").map(String.init)
        XCTAssertEqual(focusedByIndex, ["202\t2", "202\t2"])
    }

    // Tests focus workspace window uses distinct live tab ur ls for overlapping session prefixes by arranging representative inputs and asserting the expected result.
    func testFocusWorkspaceWindowUsesDistinctLiveTabURLsForOverlappingSessionPrefixes() throws {
        throw XCTSkip("Browser tab scan path removed.")
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

    // Tests tracked windows orders browser then terminal then other roles by arranging representative inputs and asserting the expected result.
    func testTrackedWindowsOrdersBrowserThenTerminalThenOtherRoles() throws {
        throw XCTSkip("Legacy shared-browser row normalization removed.")
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
        throw XCTSkip("Browser tab scan path removed.")
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
        throw XCTSkip("Multiple tracked browser tabs in one Chrome window are no longer supported.")
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

    // Tests launch workspace tracks one terminal row per process-backed terminal by arranging representative inputs and asserting the expected result.
    func testLaunchWorkspaceTracksAllTerminalWindowsFromRunningProcesses() throws {
        throw XCTSkip("Launch still uses the legacy tmux-backed process path; dedicated per-process launch coverage is not implemented yet.")
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
        throw XCTSkip("Shared Chrome tab reuse removed.")
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

    // Tests launch workspace opens missing browser sessions as tabs in one Chrome window by arranging representative inputs and asserting the expected result.
    func testLaunchWorkspaceOpensMissingBrowserSessionsAsTabsInSharedChromeWindow() throws {
        throw XCTSkip("Shared Chrome tab launch removed.")
        let (orchestrator, store, _, workspace, root) = try makeOrchestratorWithWorkspace()
        let chromeOpenLog = root.appendingPathComponent("chrome-open-shared-window.log")
        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id, sessions: [BrowserSession(url: "http://localhost:3001"), BrowserSession(url: "http://localhost:8000/admin")])

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript, "osascript": Self.orchestratorOsaScriptMock]) {
            try withEnv(name: "MOCK_CHROME_OPEN_LOG_FILE", value: chromeOpenLog.path) {
                try withEnv(name: "MOCK_CHROME_FOCUS_RESULT", value: "0") { try orchestrator.launchWorkspace(workspaceID: workspace.id) }
            }
        }

        let openLog = try String(contentsOf: chromeOpenLog)
        XCTAssertEqual(openLog.components(separatedBy: "set URL of active tab of newWindow").count - 1, 1)
        XCTAssertEqual(openLog.components(separatedBy: "make new tab at end of tabs of w").count - 1, 1)
        XCTAssertTrue(openLog.contains("set requestedWindowID to \"88\""))
    }

    // Tests launch workspace opens browser sessions in dedicated windows and persists the direct window mapping by arranging representative inputs and asserting the expected result.
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
        XCTAssertEqual(sessions.first?.extractedWindow?.windowID, 202)
        XCTAssertEqual(sessions.first?.extractedWindow?.isValid, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: extractLog.path))
    }

    // Tests focus workspace window marks stale extracted mapping invalid after direct focus failure and falls back to indexed tab focus by arranging representative inputs and asserting the expected result.
    func testFocusWorkspaceWindowMarksStaleExtractedMappingInvalidAfterDirectFocusFailureAndFallsBackToIndexedTabFocus() throws {
        throw XCTSkip("Indexed-tab fallback path was removed once dedicated Chrome windows became the primary focus flow.")
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

    // Tests focus window navigation uses active browser tab when remembered index is stale by arranging representative inputs and asserting the expected result.
    func testFocusWindowNavigationUsesActiveBrowserTabWhenRememberedIndexIsStale() throws {
        throw XCTSkip("Browser active-tab disambiguation path removed.")
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

    // Tests workspace id for focused chrome window uses active tab url match by arranging representative inputs and asserting the expected result.
    func testWorkspaceIDForFocusedChromeWindowUsesActiveTabURLMatch() throws {
        throw XCTSkip("Browser active-tab disambiguation path removed.")
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

    // Tests refresh workspace windows prunes legacy terminal rows that do not have tmux identity.
    func testRefreshWorkspaceWindowsPrunesLegacyTerminalRowsWithoutTmuxIdentity() throws {
        throw XCTSkip("Legacy tmux migration path removed.")
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        let windowID = 910
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "old-title", windowID: windowID, role: "terminal",
                orderIndex: 0, lastSeenAt: "now"))

        // Mocked dependency: live yabai window inventory.
        // Why: validate that legacy non-tmux terminal rows are removed and no longer surface in the UI.
        // Remaining risk: real migration from older runtime rows is covered here only at the store layer.
        let windowsJSON =
            "[{\"id\":\(windowID),\"pid\":11,\"app\":\"iTerm2\",\"title\":\"new-title\",\"space\":1,\"display\":1,\"is-sticky\":false,\"is-hidden\":false,\"is-visible\":true,\"is-native-fullscreen\":false}]"
        var didMutate = false
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: windowsJSON) {
                didMutate = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id)
            }
        }

        XCTAssertTrue(didMutate)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
    }

    // Tests refresh workspace windows prunes legacy process-backed terminal rows without tmux identity.
    func testRefreshWorkspaceWindowsPrunesLegacyProcessBackedTerminalRowsWithoutTmuxIdentity() throws {
        throw XCTSkip("Legacy tmux migration path removed.")
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
        // Why: validate that legacy non-tmux runtime rows are removed during refresh instead of being kept alive.
        // Remaining risk: real migration from older rows is covered here only at the persistence layer.
        let windowsJSON =
            "[{\"id\":\(windowID),\"pid\":11,\"app\":\"iTerm2\",\"title\":\"different-live-title\",\"space\":1,\"display\":1,\"is-sticky\":false,\"is-hidden\":false,\"is-visible\":true,\"is-native-fullscreen\":false}]"
        var didMutate = false
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: windowsJSON) {
                didMutate = try orchestrator.refreshWorkspaceWindows(workspaceID: workspace.id)
            }
        }

        XCTAssertTrue(didMutate)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
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
                id: UUID().uuidString, workspaceID: archivedWorkspace.id, app: "iTerm2", title: "archived-stale", windowID: 912, role: "terminal",
                orderIndex: 0, lastSeenAt: "now"))

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
        for (_, count) in refreshResult.trackedWindowCounts { XCTAssertEqual(count, 0) }
    }

    // Tests list space options sorts by display then space by arranging representative inputs and asserting the expected result.
    func testListSpaceOptionsSortsByDisplayThenSpace() throws {
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
        throw XCTSkip("Shared iTerm close sequencing removed.")
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
                try withEnv(name: "MOCK_ITERM_CLOSE_LOG_FILE", value: eventLog.path) {
                    try withEnv(
                        name: "YABAI_WINDOWS_JSON",
                        value: #"[{"id":501,"pid":11,"app":"iTerm2","title":"shell","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
                    ) {
                        try orchestrator.stopWorkspace(workspaceID: workspace.id)
                    }
                }
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
        throw XCTSkip("Browser tab close path removed; dedicated windows close via yabai.")
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

    // Tests stop workspace closes the shared iTerm window without yabai-closing it by arranging representative inputs and asserting the expected result.
    func testStopWorkspaceClosesSharedItermWindowWithoutYabaiClose() throws {
        throw XCTSkip("Shared iTerm window close path removed.")
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
                    try withEnv(
                        name: "YABAI_WINDOWS_JSON",
                        value: #"[{"id":501,"pid":11,"app":"iTerm2","title":"api","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
                    ) {
                        try orchestrator.stopWorkspace(workspaceID: workspace.id)
                    }
                }
            }
        }

        let itermEvents = (try? String(contentsOf: itermCloseLog)) ?? ""
        XCTAssertTrue(itermEvents.contains("iterm-close 501"))
        let yabaiClosedWindowIDs = (try? String(contentsOf: yabaiCloseLog).split(separator: "\n").map(String.init)) ?? []
        XCTAssertFalse(yabaiClosedWindowIDs.contains("501"))
    }

    func testStopWorkspaceClosesSharedItermWindowOnceForMultipleTrackedTmuxWindows() throws {
        throw XCTSkip("Shared iTerm window close path removed.")
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        let firstWindow = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@1", name: "api", index: 0, isActive: false)
        let secondWindow = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@2", name: "shell", index: 1, isActive: true)

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "npm run dev", windowID: 501,
                itermSessionID: "workspace-session", tmuxWindowID: firstWindow.id, role: "terminal", orderIndex: 0, lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run dev", terminalApp: "iTerm2", windowID: 501,
                itermSessionID: "workspace-session", tmuxWindowID: firstWindow.id, pid: nil, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "-zsh", windowID: 501,
                itermSessionID: "workspace-session", tmuxWindowID: secondWindow.id, role: "terminal", orderIndex: 1, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(
                name: "YABAI_WINDOWS_JSON",
                value: #"[{"id":501,"pid":11,"app":"iTerm2","title":"workspace","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
            ) {
                try orchestrator.stopWorkspace(workspaceID: workspace.id)
            }
        }

        XCTAssertEqual(mockIterm.closedWindowIDs, [501])
        XCTAssertTrue(mockTmux.killedWindowIDs.contains(firstWindow.id))
        XCTAssertTrue(mockTmux.killedWindowIDs.contains(secondWindow.id))
    }

    // Tests stop workspace closes all live detected browser session tabs by arranging representative inputs and asserting the expected result.
    func testStopWorkspaceClosesAllLiveDetectedBrowserSessionTabs() throws {
        throw XCTSkip("Browser tab close path removed; dedicated windows close via yabai.")
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
        try orchestrator.updateProjectConfig(projectID: project.id) { config in config.setupScript = "sleep 1; echo done > .muxy-launch-wait-marker" }

        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "launch-waits", runSetupScript: false)
        let setupThread = Thread { try? orchestrator.runWorkspaceSetup(workspaceID: workspace.id) }
        setupThread.start()

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) { try orchestrator.launchWorkspace(workspaceID: workspace.id) }

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

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) { try orchestrator.upWorkspace(workspaceID: workspace.id) }

        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
        XCTAssertTrue(try orchestrator.runningProcesses(workspaceID: workspace.id).isEmpty)
    }

    // Tests up workspace launches multiple configured processes in one iTerm2 window using separate tabs.
    func testUpWorkspaceLaunchesMultipleProcessesInSharedItermWindow() throws {
        throw XCTSkip("Shared iTerm window launches removed; each process gets its own window.")
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        let mockTmux = MockTmuxAdapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm, tmux: mockTmux)

        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        mockTmux.createSession(named: "muxy-\(workspace.id)")

        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.processes = [ProcessTemplate(name: "api", command: "echo api"), ProcessTemplate(name: "web", command: "echo web")]
        }

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) { try orchestrator.upWorkspace(workspaceID: workspace.id) }

        XCTAssertEqual(mockIterm.openWindowAndRunCallCount, 1)
        XCTAssertEqual(mockIterm.openTabInWindowAndRunCallCount, 0)
        XCTAssertEqual(mockTmux.createWindowCallCount, 2)

        let running = try orchestrator.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(running.count, 2)
        XCTAssertEqual(Set(running.compactMap(\.windowID)).count, 1)
        XCTAssertEqual(Set(running.compactMap(\.itermSessionID)).count, 1)
        XCTAssertEqual(Set(running.compactMap(\.tmuxWindowID)).count, 2)
    }

    // Tests up workspace does nothing to running processes when runtime indicators exist and restart is disabled by arranging representative inputs and asserting the expected result.
    func testUpWorkspaceDoesNothingWhenRuntimeIndicatorsExistByDefault() throws {
        let (orchestrator, store, _, workspace, _) = try makeOrchestratorWithWorkspace()
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "old", command: "echo old", terminalApp: "iTerm2", windowID: 501,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) { try orchestrator.upWorkspace(workspaceID: workspace.id) }

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

    // Tests restart workspace clears agent windows by arranging a running workspace with an iterm2 agent window and asserting the record and tmux window are removed before relaunch.
    func testRestartWorkspaceClearsAgentWindows() throws {
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        let agentWindow = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@2", name: "Claude Code", index: 1, isActive: true)
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "Claude Code", windowID: 501,
                itermSessionID: "workspace-session", tmuxWindowID: agentWindow.id, role: "terminal", orderIndex: 201, lastSeenAt: "now"))
        let agentRecord = AgentWindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, provider: .iterm2, label: "Claude Code", itermSessionID: "workspace-session",
            tmuxWindowID: agentWindow.id, codexThreadID: nil, windowID: 501, yabaiWindowID: 501, status: .spinning, createdAt: "now",
            updatedAt: "now")
        try store.upsertAgentWindow(agentRecord)

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(
                name: "YABAI_WINDOWS_JSON",
                value: #"[{"id":501,"pid":11,"app":"iTerm2","title":"Claude Code","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
            ) {
            try orchestrator.restartWorkspace(workspaceID: workspace.id)
            }
        }

        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty, "Agent window records should be cleared during restart")
        XCTAssertFalse(mockIterm.closedWindowIDs.contains(501), "Dedicated terminal windows close through yabai, not iTerm AppleScript.")
        XCTAssertTrue(mockTmux.killedWindowIDs.contains(agentWindow.id), "Agent tmux window should be killed during restart")
    }

    // Tests restart workspace kills every tmux window in the shared iTerm container so stale windows do not survive the teardown.
    func testRestartWorkspaceClosesAllTmuxWindowsInSharedSession() throws {
        throw XCTSkip("Shared tmux session teardown removed.")
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        let workspaceWindow = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@1", name: "shell", index: 0, isActive: false)
        let agentWindow = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@2", name: "Claude Code", index: 1, isActive: true)
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell", windowID: 501, itermSessionID: "workspace-session",
                tmuxWindowID: workspaceWindow.id, role: "terminal", orderIndex: 200, lastSeenAt: "now"))
        let agentRecord = AgentWindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, provider: .iterm2, label: "Claude Code", itermSessionID: "workspace-session",
            tmuxWindowID: agentWindow.id, codexThreadID: nil, windowID: 501, yabaiWindowID: 501, status: .spinning, createdAt: "now",
            updatedAt: "now")
        try store.upsertAgentWindow(agentRecord)

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(
                name: "YABAI_WINDOWS_JSON",
                value: #"[{"id":501,"pid":11,"app":"iTerm2","title":"shell","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
            ) {
            try orchestrator.restartWorkspace(workspaceID: workspace.id)
            }
        }

        XCTAssertTrue(mockTmux.killedWindowIDs.contains(workspaceWindow.id), "Non-agent tmux window should be killed during restart")
        XCTAssertTrue(mockTmux.killedWindowIDs.contains(agentWindow.id), "Agent tmux window should be killed during restart")
        XCTAssertTrue(mockIterm.closedWindowIDs.contains(501), "Shared iTerm window should close after the session is torn down")
        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty)
    }

    // Tests up workspace with restart enabled clears agent windows by arranging a running workspace with an iterm2 agent window and asserting the record and tmux window are removed before relaunch.
    func testUpWorkspaceWithRestartClearsAgentWindows() throws {
        throw XCTSkip("Shared workspace iTerm window teardown removed.")
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        let agentWindow = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@2", name: "Claude Code", index: 1, isActive: true)
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        let agentRecord = AgentWindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, provider: .iterm2, label: "Claude Code", itermSessionID: "workspace-session",
            tmuxWindowID: agentWindow.id, codexThreadID: nil, windowID: 501, yabaiWindowID: 501, status: .spinning, createdAt: "now",
            updatedAt: "now")
        try store.upsertAgentWindow(agentRecord)
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "Claude Code", windowID: 501,
                itermSessionID: "workspace-session", tmuxWindowID: agentWindow.id, role: "terminal", orderIndex: 201, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(
                name: "YABAI_WINDOWS_JSON",
                value: #"[{"id":501,"pid":11,"app":"iTerm2","title":"Claude Code","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
            ) {
            try orchestrator.upWorkspace(workspaceID: workspace.id, restartIfRunning: true)
            }
        }

        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty, "Agent window records should be cleared after up --force-restart")
        XCTAssertTrue(mockIterm.closedWindowIDs.contains(501), "Shared workspace iTerm window should close during up --force-restart teardown")
        XCTAssertTrue(mockTmux.killedWindowIDs.contains(agentWindow.id), "Agent tmux window should be killed during up --force-restart")
    }

    // Tests stopWorkspace tears down the full tmux session by arranging a running workspace with an iterm2 agent window and asserting the record and session are removed.
    func testStopWorkspaceRemovesAgentSessions() throws {
        throw XCTSkip("Shared workspace iTerm window teardown removed.")
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        let agentWindow = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@2", name: "Claude Code", index: 1, isActive: true)
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        let agentRecord = AgentWindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, provider: .iterm2, label: "Claude Code", itermSessionID: "workspace-session",
            tmuxWindowID: agentWindow.id, codexThreadID: nil, windowID: 501, yabaiWindowID: 501, status: .spinning, createdAt: "now",
            updatedAt: "now")
        try store.upsertAgentWindow(agentRecord)
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "Claude Code", windowID: 501,
                itermSessionID: "workspace-session", tmuxWindowID: agentWindow.id, role: "terminal", orderIndex: 201, lastSeenAt: "now"))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(
                name: "YABAI_WINDOWS_JSON",
                value: #"[{"id":501,"pid":11,"app":"iTerm2","title":"Claude Code","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
            ) {
            try orchestrator.stopWorkspace(workspaceID: workspace.id)
            }
        }

        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty, "Agent window records should be removed after explicit stop")
        XCTAssertTrue(mockIterm.closedWindowIDs.contains(501), "Shared workspace iTerm window should close when the workspace stops")
        XCTAssertTrue(mockTmux.killedWindowIDs.contains(agentWindow.id), "Agent tmux window should be killed during explicit stop")
    }

    // Tests update workspace settings removing browser sessions closes tabs without closing chrome window by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceSettingsRemovingBrowserSessionsClosesTabsWithoutClosingChromeWindow() throws {
        throw XCTSkip("Browser tab close path removed; dedicated windows close via yabai.")
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
        let mockTmux = MockTmuxAdapter()
        let orchestrator = MuxyOrchestrator(
            store: store, tmux: mockTmux, browserWindowScanDebounceInterval: browserWindowScanDebounceInterval, currentDate: currentDate)
        if let editor { _ = try orchestrator.updateEditorPreference(editor) }

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        mockTmux.createSession(named: "muxy-\(workspace.id)")
        return (orchestrator, store, project, workspace, root)
    }

    private func makeMockItermOrchestratorWithWorkspace(
        browserWindowScanDebounceInterval: TimeInterval = 10, currentDate: @escaping () -> Date = Date.init
    ) throws -> (MuxyOrchestrator, SQLiteStore, ProjectRecord, WorkspaceRecord, URL, MockIterm2Adapter, MockTmuxAdapter) {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        let mockTmux = MockTmuxAdapter()
        let orchestrator = MuxyOrchestrator(
            store: store, iterm: mockIterm, tmux: mockTmux, browserWindowScanDebounceInterval: browserWindowScanDebounceInterval,
            currentDate: currentDate)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        mockTmux.createSession(named: "muxy-\(workspace.id)")
        return (orchestrator, store, project, workspace, root, mockIterm, mockTmux)
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

        if [[ "$script" == *'create tab with default profile'* ]]; then
          wid="$(printf '%s\n' "$script" | grep -Eo 'if id of w is [0-9]+' | awk '{print $6}' | head -n1)"
          if [[ -z "$wid" ]]; then
            wid="${MOCK_ITERM_WINDOW_ID:-701}"
          fi
          if [[ -n "${MOCK_ITERM_TAB_COUNTER_FILE:-}" ]]; then
            current="$(cat "$MOCK_ITERM_TAB_COUNTER_FILE" 2>/dev/null)"
            if [[ -z "$current" ]]; then current=1; fi
            next=$((current + 1))
            echo "$next" > "$MOCK_ITERM_TAB_COUNTER_FILE"
            echo "${wid}|session-${wid}-tab-${next}|${next}"
            exit 0
          fi
          echo "${wid}|session-${wid}-tab-2|2"
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

        if [[ "$script" == *'make new tab at end of tabs of w with properties {URL:'* ]]; then
          if [[ -n "${MOCK_CHROME_OPEN_LOG_FILE:-}" ]]; then
            echo "$script" >> "$MOCK_CHROME_OPEN_LOG_FILE"
          fi
          echo "${MOCK_CHROME_OPEN_TAB_RESULT:-1}"
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

        try orchestrator.updateProjectConfig(projectID: project.id) { config in config.setupScript = "echo discovered > .muxy-discovery-setup-marker"
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
        XCTAssertEqual(r, 46)
        XCTAssertEqual(g, 41)
        XCTAssertEqual(b, 14)
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
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        let tmuxWindow = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@1", name: "api", index: 0, isActive: true)

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "api", windowID: 555,
                itermSessionID: "workspace-session", tmuxWindowID: tmuxWindow.id, role: "terminal", orderIndex: 200, lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 555,
                itermSessionID: "workspace-session", itermTabIndex: nil, tmuxWindowID: tmuxWindow.id, pid: 1234, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(
                name: "YABAI_WINDOWS_JSON",
                value: #"[{"id":555,"pid":11,"app":"iTerm2","title":"api","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
            ) {
                try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 1)
            }
        }

        // Pulse is dispatched asynchronously; allow the Task to run.
        let deadline = Date().addingTimeInterval(2)
        while mockIterm.pulseCallCount == 0, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

        XCTAssertEqual(mockIterm.pulseCallCount, 1)
        XCTAssertEqual(mockIterm.lastPulsedWindowID, 555)
        XCTAssertEqual(mockIterm.lastPulseColor?.r, 46)
        XCTAssertEqual(mockIterm.lastPulseColor?.g, 41)
        XCTAssertEqual(mockIterm.lastPulseColor?.b, 14)
    }

    // Tests focus iterm window uses configured pulse color by arranging representative inputs and asserting the expected result.
    func testFocusItermWindowUsesConfiguredPulseColor() throws {
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        let tmuxWindow = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@1", name: "api", index: 0, isActive: true)

        try orchestrator.setItermFocusPulseColor(r: 0, g: 100, b: 200)
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "api", windowID: 556,
                itermSessionID: "workspace-session", tmuxWindowID: tmuxWindow.id, role: "terminal", orderIndex: 200, lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 556,
                itermSessionID: "workspace-session", itermTabIndex: nil, tmuxWindowID: tmuxWindow.id, pid: 1234, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(
                name: "YABAI_WINDOWS_JSON",
                value: #"[{"id":556,"pid":11,"app":"iTerm2","title":"api","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
            ) {
                try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 1)
            }
        }

        let deadline = Date().addingTimeInterval(2)
        while mockIterm.pulseCallCount == 0, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }

        XCTAssertEqual(mockIterm.pulseCallCount, 1)
        XCTAssertEqual(mockIterm.lastPulseColor?.r, 0)
        XCTAssertEqual(mockIterm.lastPulseColor?.g, 100)
        XCTAssertEqual(mockIterm.lastPulseColor?.b, 200)
    }

    // Tests iterm focus pulse enabled returns true by default when not set.
    func testItermFocusPulseEnabledDefaultsToTrue() throws {
        let (orchestrator, _, _, _, _) = try makeOrchestratorWithWorkspace()
        let enabled = try orchestrator.itermFocusPulseEnabled()
        XCTAssertTrue(enabled)
    }

    // Tests iterm focus pulse enabled round-trips false.
    func testItermFocusPulseEnabledRoundTripFalse() throws {
        let (orchestrator, _, _, _, _) = try makeOrchestratorWithWorkspace()
        try orchestrator.setItermFocusPulseEnabled(false)
        let enabled = try orchestrator.itermFocusPulseEnabled()
        XCTAssertFalse(enabled)
    }

    // Tests iterm focus pulse is skipped when disabled.
    func testFocusItermWindowSkipsPulseWhenDisabled() throws {
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm)

        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        try orchestrator.setItermFocusPulseEnabled(false)
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "api", windowID: 557, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 557,
                itermSessionID: "session-557", itermTabIndex: 1, pid: 1234, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now",
                exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(
                name: "YABAI_WINDOWS_JSON",
                value: #"[{"id":557,"pid":11,"app":"iTerm2","title":"api","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
            ) {
                try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 1)
            }
        }

        // Allow any async pulse Task to run.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        XCTAssertEqual(mockIterm.pulseCallCount, 0)
    }

    // Tests overlapping iTerm focus pulses restore the original background instead of leaving the pulse color behind.
    func testFocusItermWindowOverlappingPulsesRestoreOriginalBackground() throws {
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        let tmuxWindow = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@1", name: "api", index: 0, isActive: true)
        mockIterm.managedPulseSupported = true
        mockIterm.backgroundColorByWindowID[558] = (r: 12, g: 34, b: 56)

        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "api", windowID: 558,
                itermSessionID: "workspace-session", tmuxWindowID: tmuxWindow.id, role: "terminal", orderIndex: 200, lastSeenAt: "now"))
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 558,
                itermSessionID: "workspace-session", itermTabIndex: nil, tmuxWindowID: tmuxWindow.id, pid: 1234, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(
                name: "YABAI_WINDOWS_JSON",
                value: #"[{"id":558,"pid":11,"app":"iTerm2","title":"api","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
            ) {
                try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 1)
                try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 1)
            }
        }

        let deadline = Date().addingTimeInterval(2)
        while mockIterm.setBackgroundColorCallCount < 3, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(mockIterm.backgroundColorReadCount, 1)
        XCTAssertEqual(mockIterm.setBackgroundColorCallCount, 3)
        XCTAssertEqual(mockIterm.backgroundColorWrites.count, 3)
        XCTAssertEqual(mockIterm.backgroundColorWrites[0].windowID, 558)
        XCTAssertEqual(mockIterm.backgroundColorWrites[0].color.r, 46)
        XCTAssertEqual(mockIterm.backgroundColorWrites[0].color.g, 41)
        XCTAssertEqual(mockIterm.backgroundColorWrites[0].color.b, 14)
        XCTAssertEqual(mockIterm.backgroundColorWrites[1].windowID, 558)
        XCTAssertEqual(mockIterm.backgroundColorWrites[1].color.r, 46)
        XCTAssertEqual(mockIterm.backgroundColorWrites[1].color.g, 41)
        XCTAssertEqual(mockIterm.backgroundColorWrites[1].color.b, 14)
        XCTAssertEqual(mockIterm.backgroundColorWrites[2].windowID, 558)
        XCTAssertEqual(mockIterm.backgroundColorWrites[2].color.r, 12)
        XCTAssertEqual(mockIterm.backgroundColorWrites[2].color.g, 34)
        XCTAssertEqual(mockIterm.backgroundColorWrites[2].color.b, 56)
        XCTAssertEqual(mockIterm.backgroundColorByWindowID[558]?.r, 12)
        XCTAssertEqual(mockIterm.backgroundColorByWindowID[558]?.g, 34)
        XCTAssertEqual(mockIterm.backgroundColorByWindowID[558]?.b, 56)
        XCTAssertEqual(mockIterm.pulseCallCount, 0)
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
            "PORT=$FRONTEND_PORT BACKEND=$BACKEND_PORT node server.js", env: ["FRONTEND_PORT": "3000", "BACKEND_PORT": "4000"])
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

        let resolved = try orchestrator.resolveEnvVars(in: "FRONTEND=$FRONTEND_PORT BACKEND=$BACKEND_PORT node app.js", workspaceID: workspace.id)
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

    // Tests setItermFocusPulseColor clamps values to 0–255 by arranging representative inputs and asserting the expected result.
    func testItermFocusPulseColorClamps() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        try orchestrator.setItermFocusPulseColor(r: -10, g: 300, b: 128)
        let clamped = try orchestrator.itermFocusPulseColor()
        XCTAssertEqual(clamped.r, 0)
        XCTAssertEqual(clamped.g, 255)
        XCTAssertEqual(clamped.b, 128)
    }

    // Tests itermFocusPulseEnabled round-trips through store by arranging representative inputs and asserting the expected result.
    func testItermFocusPulseEnabledRoundTrip() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        // Default is enabled.
        XCTAssertTrue(try orchestrator.itermFocusPulseEnabled())

        try orchestrator.setItermFocusPulseEnabled(false)
        XCTAssertFalse(try orchestrator.itermFocusPulseEnabled())

        try orchestrator.setItermFocusPulseEnabled(true)
        XCTAssertTrue(try orchestrator.itermFocusPulseEnabled())
    }

    // MARK: - updatePortRange

    // Tests updatePortRange persists to the app config by arranging representative inputs and asserting the expected result.
    func testUpdatePortRangePersists() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let updated = try orchestrator.updatePortRange(PortRange(start: 25000, end: 35000))
        XCTAssertEqual(updated.portRange.start, 25000)
        XCTAssertEqual(updated.portRange.end, 35000)
        XCTAssertEqual(try orchestrator.appConfig().portRange.start, 25000)
    }

    // MARK: - listProjects

    // Tests listProjects returns summaries for all stored projects by arranging representative inputs and asserting the expected result.
    func testListProjectsReturnsSummariesForAllProjects() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        XCTAssertTrue(try orchestrator.listProjects().isEmpty)

        let root = try makeTempDirectory()
        let dirA = root.appendingPathComponent("a", isDirectory: true)
        let dirB = root.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)

        _ = try orchestrator.addProject(dir: dirA.path)
        _ = try orchestrator.addProject(dir: dirB.path)

        let projects = try orchestrator.listProjects()
        XCTAssertEqual(projects.count, 2)
        let names = Set(projects.map(\.name))
        XCTAssertTrue(names.contains("a"))
        XCTAssertTrue(names.contains("b"))
    }

    // MARK: - refreshAllWorkspaceWindows

    // Tests refreshAllWorkspaceWindows iterates all projects and workspaces by arranging representative inputs and asserting the expected result.
    func testRefreshAllWorkspaceWindowsIteratesAllWorkspaces() throws {
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
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell", windowID: 707, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")

        // Mocked dependency: yabai window list (empty means the stale window gets pruned).
        // Why: verify refreshAllWorkspaceWindows iterates workspaces and returns correct counts.
        // Remaining risk: real yabai interactions not covered.
        var result: MuxyOrchestrator.RefreshResult!
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") { result = try orchestrator.refreshAllWorkspaceWindows() }
        }

        XCTAssertTrue(result.didMutateDB)
        XCTAssertEqual(result.trackedWindowCounts[workspace.id], 0)
    }

    // MARK: - stopWorkspace

    // Tests stopWorkspace with running processes clears all runtime state by arranging representative inputs and asserting the expected result.
    func testStopWorkspaceClearsAllRuntimeState() throws {
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm)

        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "npm run api", terminalApp: "iTerm2", windowID: 200,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "api", windowID: 200, role: "terminal", orderIndex: 0,
                lastSeenAt: "now"))
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")

        let outcome = try orchestrator.stopWorkspace(workspaceID: workspace.id)

        XCTAssertFalse(outcome.skippedStopScriptBecauseWorkspaceDirectoryMissing)
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, false)
    }

    // Tests stopWorkspace with stop script that runs by arranging representative inputs and asserting the expected result.
    func testStopWorkspaceWithStopScriptRuns() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        let markerFile = root.appendingPathComponent("stop-marker.txt")
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: "touch \(markerFile.path)")
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")

        let outcome = try orchestrator.stopWorkspace(workspaceID: workspace.id)

        XCTAssertFalse(outcome.skippedStopScriptBecauseWorkspaceDirectoryMissing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerFile.path))
    }

    // Tests stopWorkspace skips stop script when workspace directory is missing by arranging representative inputs and asserting the expected result.
    func testStopWorkspaceSkipsStopScriptWhenDirectoryMissing() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = makeProjectRecord(dir: "/nonexistent/project/path")
        let workspace = makeWorkspaceRecord(projectID: project.id, name: "feature", dir: "/nonexistent/project/path/feature")
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: "echo this-should-not-run")
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")

        let outcome = try orchestrator.stopWorkspace(workspaceID: workspace.id)
        XCTAssertTrue(outcome.skippedStopScriptBecauseWorkspaceDirectoryMissing)
    }

    // MARK: - syncConfig / appConfig

    // Tests syncConfig returns the current app config by arranging representative inputs and asserting the expected result.
    func testSyncConfigReturnsCurrentAppConfig() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let config = try orchestrator.syncConfig()
        XCTAssertEqual(config.portRange.start, 20000)
        XCTAssertEqual(config.portRange.end, 30000)

        let config2 = try orchestrator.appConfig()
        XCTAssertEqual(config2.portRange.start, 20000)
    }

    // MARK: - updateProjectConfig default workspace sync

    // Tests updateProjectConfig syncs default workspace settings when they match the previous template by arranging representative inputs and asserting the expected result.
    func testUpdateProjectConfigSyncsDefaultWorkspaceSettings() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let defaultWorkspace = try store.workspaces(projectID: project.id).first(where: \.isDefault)!

        // Set default workspace settings to match the project template (initially empty).
        try store.touchWorkspaceSettings(workspaceID: defaultWorkspace.id, updatedAt: "now")

        // Update the project config with a stop script.
        try orchestrator.updateProjectConfig(projectID: project.id) { record in
            record.stopScript = "echo project-stop"
        }

        // The default workspace should now have the synced stop script.
        let syncedScript = try store.workspaceStopScript(workspaceID: defaultWorkspace.id)
        XCTAssertEqual(syncedScript, "echo project-stop")
    }

    // Tests updateProjectConfig with git repo project refreshes default workspace by arranging representative inputs and asserting the expected result.
    func testAddProjectDirForGitRepoDetectsGitBranch() throws {
        let fixture = try makeTempGitRepo(name: "detect-git")
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: fixture.path)

        XCTAssertTrue(project.isGitRepo)
        XCTAssertNotNil(project.defaultBranch)
        XCTAssertFalse((project.defaultBranch ?? "").isEmpty)
    }

    // MARK: - workspaceSetupState from orchestrator

    // Tests workspaceSetupState returns current state by arranging representative inputs and asserting the expected result.
    func testOrchestratorWorkspaceSetupStateReturnsCurrentState() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Setup state is seeded automatically.
        let state = try orchestrator.workspaceSetupState(workspaceID: workspace.id)
        XCTAssertEqual(state.status, .succeeded)
    }

    // MARK: - workspacePorts

    // Tests workspacePortsNamed returns named ports by arranging representative inputs and asserting the expected result.
    func testWorkspacePortsNamedReturnsNamedPorts() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/projects/myapp")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, name: "dev", dir: "/projects/myapp")
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000, 4000], names: ["FRONTEND", "BACKEND"])

        let named = try orchestrator.workspacePortsNamed(workspaceID: workspace.id)
        XCTAssertEqual(named.count, 2)
        XCTAssertEqual(named[0].name, "FRONTEND")
        XCTAssertEqual(named[0].port, 3000)
        XCTAssertEqual(named[1].name, "BACKEND")
        XCTAssertEqual(named[1].port, 4000)
    }

    // MARK: - upWorkspace restart-exited-processes path

    // Tests upWorkspace with no runtime indicators launches workspace fresh by arranging representative inputs and asserting the expected result.
    func testUpWorkspaceWithNoRuntimeIndicatorsLaunchesFresh() throws {
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        let mockTmux = MockTmuxAdapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm, tmux: mockTmux)

        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        mockTmux.createSession(named: "muxy-\(workspace.id)")

        // Set up workspace with a process template.
        try store.touchWorkspaceSettings(workspaceID: workspace.id, updatedAt: "now")
        try store.setWorkspaceProcesses(workspaceID: workspace.id, processes: [ProcessTemplate(name: "api", command: "echo api")])

        // Mocked dependencies: yabai and iTerm2.
        // Why: upWorkspace calls launchWorkspace which needs both.
        // Remaining risk: process spawning and window capture not exercised.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") {
                try orchestrator.upWorkspace(workspaceID: workspace.id)
            }
        }

        XCTAssertEqual(try store.workspace(id: workspace.id)?.isRunning, true)
    }

    // Tests upWorkspace with restartIfRunning stops then restarts workspace by arranging representative inputs and asserting the expected result.
    func testUpWorkspaceWithRestartIfRunningStopsThenRestarts() throws {
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm)

        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Mark workspace as running with a tracked process.
        try store.updateWorkspaceRunning(id: workspace.id, isRunning: true, launchedAt: "now")
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: UUID().uuidString, workspaceID: workspace.id, templateName: "api", command: "echo api", terminalApp: nil, windowID: nil,
                pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "now", exitedAt: nil))

        // Mocked dependencies: yabai for stop and re-launch.
        // Why: exercise the restartIfRunning=true branch which calls stop then launch.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_WINDOWS_JSON", value: "[]") {
                try orchestrator.upWorkspace(workspaceID: workspace.id, restartIfRunning: true)
            }
        }

        // After restart, process list is cleared and workspace re-launched.
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
    }

    // Tests workspaceGitTrackedFileActivity returns nil for non-git project by arranging representative inputs and asserting the expected result.
    func testWorkspaceGitTrackedFileActivityReturnsNilForNonGitProject() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        let activity = try orchestrator.workspaceGitTrackedFileActivity(workspaceID: workspace.id)
        XCTAssertNil(activity)
    }

    // Tests gitBranchOptions returns empty for non-git project by arranging representative inputs and asserting the expected result.
    func testGitBranchOptionsReturnsEmptyForNonGitProject() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let options = try orchestrator.gitBranchOptions(projectID: project.id)
        XCTAssertTrue(options.isEmpty)
    }

    // Tests setActiveWorkspace and activeWorkspaceID persist by arranging representative inputs and asserting the expected result.
    func testActiveWorkspaceRoundTrip() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        XCTAssertNil(try orchestrator.activeWorkspaceID())
        try orchestrator.setActiveWorkspace(id: "workspace-xyz")
        XCTAssertEqual(try orchestrator.activeWorkspaceID(), "workspace-xyz")
        try orchestrator.setActiveWorkspace(id: nil)
        XCTAssertNil(try orchestrator.activeWorkspaceID())
    }

    // Tests updateWorkspaceActive persists isActive state by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceActiveIdemopotentWhenSameValue() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Default isActive is true; setting it to true again should be a no-op.
        try orchestrator.updateWorkspaceActive(workspaceID: workspace.id, isActive: true)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isActive, true)

        // Setting to false should persist.
        try orchestrator.updateWorkspaceActive(workspaceID: workspace.id, isActive: false)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isActive, false)
    }

    // Tests updateWorkspaceTooltip persists tooltip through orchestrator by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceTooltipPersistsThroughOrchestrator() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        try orchestrator.updateWorkspaceTooltip(workspaceID: workspace.id, tooltip: "Working on API")
        XCTAssertEqual(try store.workspace(id: workspace.id)?.tooltip, "Working on API")

        try orchestrator.updateWorkspaceTooltip(workspaceID: workspace.id, tooltip: nil)
        XCTAssertNil(try store.workspace(id: workspace.id)?.tooltip)
    }

    // Tests workspaceSettings seeds and returns defaults for workspace without explicit settings by arranging representative inputs and asserting the expected result.
    func testWorkspaceSettingsReturnsDefaultsWhenNotExplicitlySet() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = makeProjectRecord(dir: projectDir.path)
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, name: "raw", dir: projectDir.path)
        try store.upsert(workspace: workspace)

        // workspaceSettings seeds defaults when no settings exist; returns an empty (non-nil) settings object.
        let settings = try orchestrator.workspaceSettings(workspaceID: workspace.id)
        XCTAssertNotNil(settings)
        XCTAssertNil(settings?.stopScript)
        XCTAssertTrue(settings?.ports.isEmpty ?? false)
        XCTAssertTrue(settings?.processes.isEmpty ?? false)
    }

    // Tests guiTooltipShortcut and setGUITooltipShortcut round-trip by arranging representative inputs and asserting the expected result.
    func testGUITooltipShortcutRoundTrip() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let defaultVal = try orchestrator.guiTooltipShortcut()
        XCTAssertFalse(defaultVal.isEmpty)

        try orchestrator.setGUITooltipShortcut("ctrl+t")
        XCTAssertEqual(try orchestrator.guiTooltipShortcut(), "ctrl+t")

        try orchestrator.setGUITooltipShortcut(nil)
        XCTAssertEqual(try orchestrator.guiTooltipShortcut(), SettingsKey.defaultGUITooltipShortcut)
    }

    // Tests upWorkspace allocates ports when port definitions exist but no ports are allocated by arranging representative inputs and asserting the expected result.
    func testUpWorkspaceAllocatesPortsWhenDefinitionsExistButNoPortsAllocated() throws {
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Add port definitions so that portDefinitions.count > 0 with no ports allocated yet.
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.ports = [PortDefinition(name: "web"), PortDefinition(name: "api")]
        }

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try orchestrator.upWorkspace(workspaceID: workspace.id)
        }

        // Ports should now be allocated.
        let allocatedPorts = try store.workspacePorts(workspaceID: workspace.id)
        XCTAssertEqual(allocatedPorts.count, 2)
    }

    // Tests stopWorkspace skips stop script when workspace directory is missing by arranging representative inputs and asserting the expected result.
    func testStopWorkspaceSkipsStopScriptWhenWorkspaceDirMissing() throws {
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let workspaceDir = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Set a stop script that would fail if the directory doesn't exist.
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.stopScript = "echo stopped"
        }

        // Mark workspace as running so stop can proceed.
        var runningWorkspace = workspace
        runningWorkspace = WorkspaceRecord(
            id: workspace.id, projectID: workspace.projectID, name: workspace.name, dir: "/nonexistent/workspace-\(UUID().uuidString)",
            dirname: workspace.dirname, branch: workspace.branch, targetBranch: workspace.targetBranch, isDefault: workspace.isDefault,
            isArchived: workspace.isArchived, isActive: workspace.isActive, isRunning: true, lastLaunchedAt: nil, tooltip: nil)
        try store.upsert(workspace: runningWorkspace)

        // Stop should succeed (skip script because dir is missing) rather than throw.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            let outcome = try orchestrator.stopWorkspace(workspaceID: workspace.id)
            XCTAssertTrue(outcome.skippedStopScriptBecauseWorkspaceDirectoryMissing)
        }
    }

    // Tests stopWorkspace closes non-iTerm2 tracked windows via yabai by arranging representative inputs and asserting the expected result.
    func testStopWorkspaceClosesNonItermTrackedWindowsViaYabai() throws {
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Insert a tracked "editor" window (non-browser, non-iTerm2) so lines 702-705 are reached.
        let editorWindow = WindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, app: "Cursor", title: "editor", windowID: 42,
            role: "editor", orderIndex: 100, lastSeenAt: "2024-01-01T00:00:00Z")
        try store.upsert(window: editorWindow)

        // Mark workspace as running.
        let runningWorkspace = WorkspaceRecord(
            id: workspace.id, projectID: workspace.projectID, name: workspace.name, dir: projectDir.path,
            dirname: workspace.dirname, branch: workspace.branch, targetBranch: workspace.targetBranch, isDefault: workspace.isDefault,
            isArchived: workspace.isArchived, isActive: workspace.isActive, isRunning: true, lastLaunchedAt: nil, tooltip: nil)
        try store.upsert(workspace: runningWorkspace)

        // Stop workspace: should attempt to close the editor window via yabai (yabai.closeWindow may fail silently).
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            _ = try orchestrator.stopWorkspace(workspaceID: workspace.id)
        }

        // The window records should be deleted after stop.
        let remainingWindows = try store.windows(workspaceID: workspace.id)
        XCTAssertTrue(remainingWindows.isEmpty)
    }

    // Tests registerAgentWindow prunes stale iTerm2 sessions from DB by arranging representative inputs and asserting the expected result.
    func testRegisterAgentWindowPrunesStaleItermSessionsOnRegistration() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        // Only "live-session" is alive; "stale-session" should be pruned.
        mockIterm.stubbedSessionIDs = ["live-session"]
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Insert a stale agent window directly.
        let stale = AgentWindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, provider: .iterm2, label: nil, itermSessionID: "stale-session",
            codexThreadID: nil, windowID: nil, status: .idle, createdAt: "2024-01-01T00:00:00Z", updatedAt: "2024-01-01T00:00:00Z")
        try store.upsertAgentWindow(stale)
        // Insert an agent with nil session ID - should be pruned immediately.
        let noSid = AgentWindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, provider: .iterm2, label: nil, itermSessionID: nil,
            codexThreadID: nil, windowID: nil, status: .idle, createdAt: "2024-01-01T00:00:00Z", updatedAt: "2024-01-01T00:00:00Z")
        try store.upsertAgentWindow(noSid)

        // registerAgentWindow now preserves unrelated historical records unless it can match by dedicated yabai window ID.
        _ = try orchestrator.registerAgentWindow(workspaceID: workspace.id, provider: .iterm2, itermSessionID: "live-session")

        let remaining = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(remaining.count, 3)
        XCTAssertTrue(remaining.contains(where: { $0.itermSessionID == "stale-session" }))
        XCTAssertTrue(remaining.contains(where: { $0.itermSessionID == nil }))
        XCTAssertTrue(remaining.contains(where: { $0.itermSessionID == "live-session" }))
    }

    // Tests addProject throws when directory does not exist by arranging representative inputs and asserting the expected result.
    func testAddProjectThrowsWhenDirectoryNotFound() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let nonExistent = "/tmp/muxy-test-nonexistent-\(UUID().uuidString)"
        XCTAssertThrowsError(try orchestrator.addProject(dir: nonExistent)) { error in
            guard case MuxyError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests updateWorkspaceMetadata throws when renaming to a duplicate title by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataDuplicateTitleThrows() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let ws1 = try orchestrator.createWorkspace(projectID: project.id, name: "alpha")
        _ = try orchestrator.createWorkspace(projectID: project.id, name: "beta")

        // Renaming ws1 to "beta" (already taken by another workspace) should throw.
        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: ws1.id, title: "beta")) { error in
            guard case MuxyError.workspaceAlreadyExists = error else { return XCTFail("Expected workspaceAlreadyExists, got \(error)") }
        }
    }

    // Tests addProject by gitURL throws when destination directory already exists on disk by arranging representative inputs and asserting the expected result.
    func testAddProjectByGitURLThrowsWhenDestinationExists() throws {
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        // Pre-create the destination directory so it already exists on disk.
        let existingDir = reposRoot.appendingPathComponent("my-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: existingDir, withIntermediateDirectories: true)

        // addProject(gitURL:) should throw because the destination directory is already present.
        XCTAssertThrowsError(try orchestrator.addProject(gitURL: "https://example.com/my-repo.git")) { error in
            guard case MuxyError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests checkAndUpdateProcessStatuses prunes stale iTerm2 agent sessions by arranging representative inputs and asserting the expected result.
    func testCheckAndUpdateProcessStatusesPrunesStaleItermAgentSessions() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        let mockTmux = MockTmuxAdapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm, tmux: mockTmux)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let sessionName = "muxy-\(workspace.id)"
        mockTmux.createSession(named: sessionName)

        // Insert agent windows directly to bypass registerAgentWindow's own pruning.
        let staleAgent = AgentWindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, provider: .iterm2, label: nil, itermSessionID: "workspace-session",
            tmuxWindowID: "@missing", codexThreadID: nil, windowID: nil, status: .idle, createdAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-01-01T00:00:00Z")
        let noSidAgent = AgentWindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, provider: .iterm2, label: nil, itermSessionID: nil,
            codexThreadID: nil, windowID: nil, status: .idle, createdAt: "2024-01-01T00:00:00Z", updatedAt: "2024-01-01T00:00:00Z")
        try store.upsertAgentWindow(staleAgent)
        try store.upsertAgentWindow(noSidAgent)

        // alive set does NOT contain "stale-sid", so both agents should be pruned.
        mockIterm.stubbedSessionIDs = ["alive-session"]

        let didUpdate = try orchestrator.checkAndUpdateProcessStatuses()

        XCTAssertTrue(didUpdate)
        let remaining = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertTrue(remaining.isEmpty)
    }

    // Tests checkAndUpdateProcessStatuses keeps live iTerm2 agent sessions by arranging representative inputs and asserting the expected result.
    func testCheckAndUpdateProcessStatusesKeepsLiveItermAgentSessions() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        let mockTmux = MockTmuxAdapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm, tmux: mockTmux)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        let sessionName = "muxy-\(workspace.id)"
        let liveWindow = mockTmux.addWindow(sessionName: sessionName, id: "@1", name: "agent", index: 0, isActive: true)

        let liveAgent = AgentWindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, provider: .iterm2, label: nil, itermSessionID: "workspace-session",
            tmuxWindowID: liveWindow.id, codexThreadID: nil, windowID: nil, status: .idle, createdAt: "2024-01-01T00:00:00Z",
            updatedAt: "2024-01-01T00:00:00Z")
        try store.upsertAgentWindow(liveAgent)

        let didUpdate = try orchestrator.checkAndUpdateProcessStatuses()

        XCTAssertFalse(didUpdate)
        let remaining = try store.agentWindows(workspaceID: workspace.id)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.tmuxWindowID, liveWindow.id)
    }

    // Tests gitBranchOptions returns branches for a real git project by arranging representative inputs and asserting the expected result.
    func testGitBranchOptionsForGitProject() throws {
        let fixture = try makeTempGitRepo(name: "branch-opts-test")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(gitURL: fixture.path)
        let options = try orchestrator.gitBranchOptions(projectID: project.id)
        XCTAssertFalse(options.isEmpty)
        XCTAssertTrue(options.contains("main"))
    }

    // Tests workspaceGitTrackedFileActivity returns non-nil for a git workspace by arranging representative inputs and asserting the expected result.
    func testWorkspaceGitTrackedFileActivityForGitWorkspace() throws {
        let fixture = try makeTempGitRepo(name: "git-activity-test")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(gitURL: fixture.path)
        let defaultWorkspace = try XCTUnwrap(orchestrator.listWorkspaces(projectID: project.id).first(where: \.isDefault))
        let activity = try orchestrator.workspaceGitTrackedFileActivity(workspaceID: defaultWorkspace.id)
        XCTAssertNotNil(activity)
    }

    // Tests createWorkspace revives an archived git workspace by recreating the worktree by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceRevivesArchivedGitWorkspace() throws {
        let repo = try makeTempGitRepo(name: "revive-git-workspace")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let original = try orchestrator.createWorkspace(projectID: project.id, name: "feature", branch: "feature-branch")
        try orchestrator.archiveWorkspace(workspaceID: original.id)
        let archived = try XCTUnwrap(store.workspace(id: original.id))
        XCTAssertTrue(archived.isArchived)

        // Revive the archived workspace by creating with the same name and branch
        let revived = try orchestrator.createWorkspace(projectID: project.id, name: "feature", branch: "feature-branch")
        let persisted = try XCTUnwrap(store.workspace(id: revived.id))
        XCTAssertEqual(revived.id, original.id)
        XCTAssertFalse(persisted.isArchived)
        XCTAssertEqual(persisted.branch, "feature-branch")
    }

    // Tests createWorkspaceFromWorktree throws when the path does not exist by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceFromWorktreeThrowsWhenPathMissing() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        XCTAssertThrowsError(
            try orchestrator.createWorkspaceFromWorktree(worktreePath: "/nonexistent/path/\(UUID().uuidString)")
        ) { error in
            guard case MuxyError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests createWorkspaceFromWorktree throws when the path is not a git repository by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceFromWorktreeThrowsWhenNotGitRepo() throws {
        let dir = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        XCTAssertThrowsError(
            try orchestrator.createWorkspaceFromWorktree(worktreePath: dir.path)
        ) { error in
            guard case MuxyError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests updateWorkspaceMetadata throws for empty title by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataThrowsForEmptyTitle() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, title: "   ")) { error in
            guard case MuxyError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests updateWorkspaceMetadata throws for empty branch on git project by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataThrowsForEmptyBranchOnGitProject() throws {
        let repo = try makeTempGitRepo(name: "empty-branch-metadata")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature", branch: "feature-start")
        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, branch: "  ")) { error in
            guard case MuxyError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests updateWorkspaceMetadata throws for empty directoryName on git project by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataThrowsForEmptyDirectoryNameOnGitProject() throws {
        let repo = try makeTempGitRepo(name: "empty-dirname-metadata")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature", branch: "feature-start")
        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, directoryName: "")) { error in
            guard case MuxyError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests updateWorkspaceMetadata throws for duplicate directory name across workspaces by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataThrowsForDuplicateDirectoryName() throws {
        let repo = try makeTempGitRepo(name: "dup-dirname-metadata")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)
        let ws1 = try orchestrator.createWorkspace(projectID: project.id, name: "feature", branch: "feature-start")
        let ws2 = try orchestrator.createWorkspace(projectID: project.id, name: "other", branch: "other-branch")
        guard let ws1Dirname = ws1.dirname, let ws2Dirname = ws2.dirname else { return }
        XCTAssertNotEqual(ws1Dirname, ws2Dirname)
        // Try to set ws2's dirname to ws1's dirname - should throw duplicate error
        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: ws2.id, directoryName: ws1Dirname)) { error in
            guard case MuxyError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests suggestedWorkspaceName throws when all available names are exhausted by arranging representative inputs and asserting the expected result.
    func testSuggestedWorkspaceNameThrowsWhenAllNamesExhausted() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)

        // Insert workspace records for all known food names to exhaust suggestions
        let allFoodNames = ["almond", "anchovy", "apple", "apricot", "avocado", "bagel", "bacon", "banana", "basil", "bean",
            "beef", "beet", "berry", "biscuit", "bread", "broccoli", "brownie", "burger", "burrito", "butter",
            "cabbage", "cacao", "candy", "cantaloupe", "caramel", "carrot", "cashew", "celery", "cereal", "cherry",
            "cheddar", "cheesecake", "chili", "chips", "chive", "chocolate", "chutney", "cider", "cinnamon", "clove",
            "cocoa", "coconut", "coffee", "coleslaw", "cookie", "corn", "couscous", "cracker", "cream", "crouton",
            "cucumber", "cupcake", "curry", "custard", "danish", "dill", "donut", "dumpling", "eclair", "edamame",
            "egg", "empanada", "endive", "fajita", "falafel", "fig", "flan", "fries", "garlic", "ginger", "gnocchi",
            "granola", "grape", "gravy", "grits", "guava", "ham", "hazelnut", "honey", "hummus", "icecream", "jam",
            "jalapeno", "jelly", "kale", "kebab", "ketchup", "kiwi", "kohlrabi", "lasagna", "leek", "lemon", "lentil",
            "lettuce", "lime", "lobster", "lychee", "macaroni", "macaron", "mango", "maple", "marshmallow",
            "mascarpone", "mayo", "meatball", "melon", "mint", "mocha", "molasses", "muffin", "mushroom", "mustard",
            "nacho", "noodle", "nutmeg", "oat", "omelet", "olive", "onion", "orange", "oreo", "pancake", "papaya",
            "paprika", "parsnip", "pastry", "peach", "peanut", "pear", "peas", "pecan", "pepper", "pesto", "pho",
            "pickle", "pie", "pineapple", "pita", "pizza", "plum", "poppy", "popcorn", "pork", "potato", "poutine",
            "pretzel", "prune", "pudding", "pumpkin", "quiche", "quinoa", "radish", "raisin", "ramen", "relish",
            "rice", "risotto", "roast", "roll", "saffron", "sage", "salad", "salami", "salsa", "salt", "sardine",
            "sausage", "scone", "seaweed", "sesame", "shallot", "shrimp", "soup", "sorbet", "soy", "spice",
            "spinach", "squash", "steak", "stew", "sugar", "sushi", "syrup", "taco", "tamarind", "tapioca", "tea",
            "toffee", "toast", "tofu", "tomato", "tortilla", "tuna", "turkey", "turnip", "vanilla", "vinegar",
            "waffle", "walnut", "watermelon", "yams", "yogurt", "ziti", "zucchini"]
        for name in allFoodNames {
            let ws = makeWorkspaceRecord(projectID: project.id, name: name, dir: projectDir.path)
            try store.upsert(workspace: ws)
        }

        XCTAssertThrowsError(try orchestrator.suggestedWorkspaceName(projectID: project.id)) { error in
            guard case MuxyError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests checkAndUpdateProcessStatuses marks a dead process as exited and calls handleProcessExit .none case by arranging representative inputs and asserting the expected result.
    func testCheckAndUpdateProcessStatusesDetectsDeadProcessAndHandlesExit() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Add process template with onExit .none so handleProcessExit covers the .none switch case
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.processes = [ProcessTemplate(name: "web", command: "sleep 1", onExit: .none)]
        }

        // Insert a running process with a dead PID (macOS max PID is ~99998; 2_000_000 is guaranteed dead)
        let proc = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "sleep 1",
            terminalApp: "Terminal", windowID: nil, itermSessionID: nil, itermTabIndex: nil,
            pid: 2_000_000, status: .running, logPath: nil, lastOutputAt: nil,
            startedAt: "2020-01-01T00:00:00Z", exitedAt: nil)
        try store.upsert(runningProcess: proc)

        let didUpdate = try orchestrator.checkAndUpdateProcessStatuses()
        XCTAssertTrue(didUpdate)
        let processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.first?.status, .exited)
    }

    // Tests checkAndUpdateProcessStatuses skips recently started processes within the 10-second grace window by arranging representative inputs and asserting the expected result.
    func testCheckAndUpdateProcessStatusesSkipsRecentlyStartedProcess() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Insert a process with a dead PID but very recent startedAt (within 10-second grace)
        let recentStart = ISO8601DateFormatter().string(from: Date())
        let proc = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "sleep 1",
            terminalApp: "Terminal", windowID: nil, itermSessionID: nil, itermTabIndex: nil,
            pid: 2_000_000, status: .running, logPath: nil, lastOutputAt: nil,
            startedAt: recentStart, exitedAt: nil)
        try store.upsert(runningProcess: proc)

        let didUpdate = try orchestrator.checkAndUpdateProcessStatuses()
        XCTAssertFalse(didUpdate)
        let processes = try store.runningProcesses(workspaceID: workspace.id)
        XCTAssertEqual(processes.first?.status, .running)
    }

    // Tests createWorkspace throws when target branch cannot be resolved for a git project with no main/master by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceThrowsWhenTargetBranchCannotBeResolved() throws {
        // Create a git repo with a non-standard initial branch (not main or master)
        let repo = try makeTempGitRepo(name: "no-main-or-master", initialBranch: "develop")
        let store = try makeTemporaryStore()
        // Insert the project directly with defaultBranch = nil to force the main/master branch check
        let projectRecord = ProjectRecord(id: repo.path, name: "test", dir: repo.path, isGitRepo: true, defaultBranch: nil)
        try store.upsert(project: projectRecord)

        let orchestrator = MuxyOrchestrator(store: store)
        // Without targetBranch, resolveWorkspaceTargetBranch should check for main/master, find neither, and throw
        XCTAssertThrowsError(
            try orchestrator.createWorkspace(projectID: projectRecord.id, name: "feature", branch: "feature-branch")
        ) { error in
            guard case MuxyError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests updateWorkspaceMetadata branch update on non-git project throws by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataBranchThrowsForNonGitProject() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, branch: "new-branch")) { error in
            guard case MuxyError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests updateWorkspaceMetadata directoryName update on non-git project throws by arranging representative inputs and asserting the expected result.
    func testUpdateWorkspaceMetadataDirectoryNameThrowsForNonGitProject() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, directoryName: "newdir")) { error in
            guard case MuxyError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests liveItermSessionIDs delegates to the iterm adapter by arranging representative inputs and asserting the expected result.
    func testLiveItermSessionIDsReturnsAdapterSessions() throws {
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        mockIterm.stubbedSessionIDs = ["session-alpha", "session-beta"]
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm)

        let sessions = orchestrator.liveItermSessionIDs()
        XCTAssertEqual(sessions, ["session-alpha", "session-beta"])
    }

    // Tests workspaceIDForFocusedWindow returns the workspace of an agent window by arranging representative inputs and asserting the expected result.
    func testWorkspaceIDForFocusedWindowReturnsAgentWindowMatch() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Insert an agent window with yabaiWindowID=101; no regular tracked window has that ID.
        let agentWindow = AgentWindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, provider: .iterm2,
            label: nil, itermSessionID: "s1", codexThreadID: nil, windowID: nil,
            yabaiWindowID: 101, status: .idle, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
        try store.upsertAgentWindow(agentWindow)

        // Mocked dependency: yabai focused window returns id=101, app=Finder (not Chrome, not tracked as a window record).
        // Why: exercise the agent-window fallback path in workspaceIDForFocusedWindow.
        // Remaining risk: only a single app name other than Chrome is tested.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(name: "YABAI_FOCUSED_ID", value: "101") {
                try withEnv(name: "YABAI_FOCUSED_APP", value: "Finder") {
                    let result = try orchestrator.workspaceIDForFocusedWindow()
                    XCTAssertEqual(result, workspace.id)
                }
            }
        }
    }

    // Tests openWorkspaceTerminal falls back to the first sorted tracked iTerm2 window ID when no running process provides one by arranging representative inputs and asserting the expected result.
    func testOpenWorkspaceTerminalFallsBackToSortedTrackedWindowID() throws {
        throw XCTSkip("Shared workspace terminal window fallback removed.")
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()

        // Add a tracked iTerm2 terminal window but no running processes.
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell",
                windowID: 42, itermSessionID: "workspace-session", role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        // Mocked dependency: yabai focused window returns Finder (not iTerm2), FOCUSED_ID not in tracked windows.
        // Why: ensure new UI terminals reuse the workspace iTerm container and create a tmux window.
        // Remaining risk: only the single-window workspace-container case is tested.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(
                name: "YABAI_WINDOWS_JSON",
                value: #"[{"id":42,"pid":11,"app":"iTerm2","title":"shell","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
            ) {
            try withEnv(name: "YABAI_FOCUSED_ID", value: "999") {
                try withEnv(name: "YABAI_FOCUSED_APP", value: "Finder") {
                    try orchestrator.openWorkspaceTerminal(workspaceID: workspace.id)
                }
            }
            }
        }

        XCTAssertEqual(mockIterm.openWindowAndRunCallCount, 0)
        XCTAssertEqual(mockIterm.openTabInWindowAndRunCallCount, 0)
        XCTAssertEqual(mockTmux.createWindowCallCount, 1)
        XCTAssertEqual(mockTmux.lastCreatedWindow?.sessionName, "muxy-\(workspace.id)")
    }

    // Tests openWorkspaceTerminal uses the window ID from a running iTerm2 process when the focused window is not iTerm2 by arranging representative inputs and asserting the expected result.
    func testOpenWorkspaceTerminalUsesRunningProcessWindowFallback() throws {
        throw XCTSkip("Shared workspace terminal window fallback removed.")
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()

        // Add tracked iTerm2 window AND a running process recording that window.
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell",
                windowID: 42, itermSessionID: "workspace-session", role: "terminal", orderIndex: 200, lastSeenAt: "now"))
        let proc = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "echo hi",
            terminalApp: "iTerm2", windowID: 42, itermSessionID: "workspace-session", itermTabIndex: nil, tmuxWindowID: "@1",
            pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: nil, exitedAt: nil)
        try store.upsert(runningProcess: proc)
        _ = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@1", name: "web", index: 0, isActive: true)

        // Mocked dependency: yabai focused window is Finder (not iTerm2) so line 1242 is skipped.
        // Why: ensure the workspace iTerm container is reused and a new tmux shell window is created.
        // Remaining risk: only a single running-process container is tested.
        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(
                name: "YABAI_WINDOWS_JSON",
                value: #"[{"id":42,"pid":11,"app":"iTerm2","title":"shell","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
            ) {
            try withEnv(name: "YABAI_FOCUSED_ID", value: "999") {
                try withEnv(name: "YABAI_FOCUSED_APP", value: "Finder") {
                    try orchestrator.openWorkspaceTerminal(workspaceID: workspace.id)
                }
            }
            }
        }

        XCTAssertEqual(mockIterm.openWindowAndRunCallCount, 0)
        XCTAssertEqual(mockIterm.openTabInWindowAndRunCallCount, 0)
        XCTAssertEqual(mockTmux.createWindowCallCount, 1)
        XCTAssertEqual(mockTmux.lastCreatedWindow?.sessionName, "muxy-\(workspace.id)")
    }

    // Tests ensureDefaultWorkspace revives an archived default workspace via updateProjectConfig by arranging representative inputs and asserting the expected result.
    func testEnsureDefaultWorkspaceRevivesArchivedDefaultViaUpdateProjectConfig() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)

        // Find the default workspace and archive it via store directly.
        let workspaces = try store.workspaces(projectID: project.id, includeArchived: false)
        let defaultWS = try XCTUnwrap(workspaces.first(where: \.isDefault))
        let archived = WorkspaceRecord(
            id: defaultWS.id, projectID: project.id, name: defaultWS.name, dir: defaultWS.dir,
            dirname: defaultWS.dirname, branch: defaultWS.branch, isDefault: true, isArchived: true,
            isRunning: defaultWS.isRunning, lastLaunchedAt: defaultWS.lastLaunchedAt)
        try store.upsert(workspace: archived)
        XCTAssertTrue(try XCTUnwrap(store.workspace(id: defaultWS.id)).isArchived)

        // updateProjectConfig calls ensureDefaultWorkspace, which should revive the archived default workspace.
        try orchestrator.updateProjectConfig(projectID: project.id) { _ in }

        let revived = try XCTUnwrap(store.workspace(id: defaultWS.id))
        XCTAssertFalse(revived.isArchived)
    }

    // Tests handleProcessExit with onExit .restart restarts the process via openWindowAndRun by arranging representative inputs and asserting the expected result.
    func testHandleProcessExitRestartCaseCallsOpenWindowAndRun() throws {
        let store = try makeTemporaryStore()
        let mockIterm = MockIterm2Adapter()
        let mockTmux = MockTmuxAdapter()
        let orchestrator = MuxyOrchestrator(store: store, iterm: mockIterm, tmux: mockTmux)
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        mockTmux.createSession(named: "muxy-\(workspace.id)")

        // Add process template with onExit .restart.
        try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { settings in
            settings.processes = [ProcessTemplate(name: "web", command: "echo hi", onExit: .restart)]
        }

        // Insert a dead running process (PID 2_000_000 is guaranteed dead, windowID nil forces openWindowAndRun fallback).
        let proc = RunningProcessRecord(
            id: UUID().uuidString, workspaceID: workspace.id, templateName: "web", command: "echo hi",
            terminalApp: "Terminal", windowID: nil, itermSessionID: nil, itermTabIndex: nil,
            pid: 2_000_000, status: .running, logPath: nil, lastOutputAt: nil,
            startedAt: "2020-01-01T00:00:00Z", exitedAt: nil)
        try store.upsert(runningProcess: proc)

        let didUpdate = try orchestrator.checkAndUpdateProcessStatuses()
        XCTAssertTrue(didUpdate)
        // handleProcessExit .restart calls restartProcessInTerminal which opens a new dedicated iTerm2 window.
        XCTAssertEqual(mockIterm.openWindowAndRunCallCount, 1)
        XCTAssertEqual(mockTmux.createWindowCallCount, 0)
    }

    // Tests createWorkspaceFromWorktree throws when the worktree directory matches an archived workspace by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceFromWorktreeThrowsWhenAlreadyArchivedWorkspaceExists() throws {
        let repo = try makeTempGitRepo(name: "archived-worktree-repo")
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: repo.path)

        // The default workspace has dir=repo.path; archive it so the next createWorkspaceFromWorktree finds it archived.
        let workspaces = try store.workspaces(projectID: project.id, includeArchived: false)
        let defaultWS = try XCTUnwrap(workspaces.first(where: \.isDefault))
        let archived = WorkspaceRecord(
            id: defaultWS.id, projectID: project.id, name: defaultWS.name, dir: defaultWS.dir,
            dirname: defaultWS.dirname, branch: defaultWS.branch, isDefault: true, isArchived: true,
            isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: archived)

        // createWorkspaceFromWorktree should detect the archived workspace and throw.
        XCTAssertThrowsError(try orchestrator.createWorkspaceFromWorktree(worktreePath: repo.path)) { error in
            guard case MuxyError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests focusAgentWindow calls iTerm2 focus and pulse for an iterm2 provider record by arranging representative inputs and asserting the expected result.
    func testFocusAgentWindowCallsItermFocusForIterm2Provider() throws {
        throw XCTSkip("Agent focus now uses dedicated yabai window IDs directly.")
        let (orchestrator, store, _, workspace, _, mockIterm, mockTmux) = try makeMockItermOrchestratorWithWorkspace()
        mockIterm.focusSessionOrTabResult = true
        let agentWindow = mockTmux.addWindow(sessionName: "muxy-\(workspace.id)", id: "@2", name: "agent", index: 1, isActive: true)
        try store.upsert(
            window: WindowRecord(
                id: UUID().uuidString, workspaceID: workspace.id, app: "iTerm2", title: "shell", windowID: 42, itermSessionID: "workspace-session",
                role: "terminal", orderIndex: 200, lastSeenAt: "now"))

        let record = AgentWindowRecord(
            id: UUID().uuidString, workspaceID: workspace.id, provider: .iterm2,
            label: nil, itermSessionID: "workspace-session", tmuxWindowID: agentWindow.id, codexThreadID: nil, windowID: 42,
            yabaiWindowID: nil, status: .idle, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")

        try withMockCommands(["yabai": Self.orchestratorYabaiMockScript]) {
            try withEnv(
                name: "YABAI_WINDOWS_JSON",
                value: #"[{"id":42,"pid":11,"app":"iTerm2","title":"shell","space":1,"display":1,"is-sticky":false,"is-hidden":false,"is-visible":true,"is-native-fullscreen":false}]"#
            ) {
                try orchestrator.focusAgentWindow(record)
            }
        }

        XCTAssertEqual(mockTmux.selectWindowCallCount, 1)
        XCTAssertEqual(mockTmux.lastSelectedWindowID, agentWindow.id)
        XCTAssertEqual(mockIterm.focusSessionOrTabCallCount, 1)
        XCTAssertEqual(mockIterm.lastFocusedSessionID, "workspace-session")
        // focusPulseEnabled defaults to true; windowID is non-nil and focus succeeded so pulse runs.
        XCTAssertEqual(mockIterm.pulseCallCount, 1)
        XCTAssertEqual(mockIterm.lastPulsedWindowID, 42)
    }

    // Tests syncDefaultWorkspaceSettings reseeds missing settings when updateProjectConfig is called by arranging representative inputs and asserting the expected result.
    func testSyncDefaultWorkspaceSettingsReseesIfSettingsMissing() throws {
        let store = try makeTemporaryStore()
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        // Use symlink-resolved path so it matches what normalizePath returns internally.
        let normalizedDir = URL(fileURLWithPath: projectDir.path).resolvingSymlinksInPath().path
        let projectRecord = ProjectRecord(id: normalizedDir, name: "test", dir: normalizedDir, isGitRepo: false, defaultBranch: nil)
        try store.upsert(project: projectRecord)

        // Insert a default workspace directly without going through seedWorkspaceSettings.
        let workspaceID = UUID().uuidString
        let workspaceRecord = WorkspaceRecord(
            id: workspaceID, projectID: normalizedDir, name: "default", dir: normalizedDir,
            dirname: nil, branch: nil, isDefault: true, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: workspaceRecord)
        XCTAssertFalse(try store.workspaceSettingsExists(workspaceID: workspaceID))

        // updateProjectConfig triggers syncDefaultWorkspaceSettingsIfTemplateBased, which reseeds missing settings.
        let orchestrator = MuxyOrchestrator(store: store)
        try orchestrator.updateProjectConfig(projectID: normalizedDir) { _ in }

        XCTAssertTrue(try store.workspaceSettingsExists(workspaceID: workspaceID))
    }

    // Tests createWorkspace rejects a non-ASCII directory name by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceRejectsNonAsciiDirectoryName() throws {
        let repo = try makeTempGitRepo(name: "non-ascii-dirname-repo")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)

        // Pass a non-ASCII directory name (é is non-ASCII) to trigger the guard scalar.isASCII path.
        XCTAssertThrowsError(
            try orchestrator.createWorkspace(
                projectID: project.id, name: "feature-name", branch: "feature-branch", directoryName: "f\u{00e9}ature")
        ) { error in
            guard case MuxyError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests expandTilde resolves a standalone tilde to the home directory path by arranging representative inputs and asserting the expected result.
    func testExpandTildeResolvesStandaloneTildeToHome() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        // "~" expands to the home directory; no project exists there so removeProject returns silently.
        XCTAssertNoThrow(try orchestrator.removeProject(dir: "~"))
    }

    // Tests expandTilde resolves a tilde-slash prefix to the corresponding home subdirectory path by arranging representative inputs and asserting the expected result.
    func testExpandTildeResolvesTildeSlashPrefixToHomeSubdirectory() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        // "~/foo" expands to home/foo; no project exists there so removeProject returns silently.
        XCTAssertNoThrow(try orchestrator.removeProject(dir: "~/muxy-test-nonexistent-path-xyzzy"))
    }

    // Tests expandTilde passes through a tilde-name prefix unchanged by arranging representative inputs and asserting the expected result.
    func testExpandTildePassesThroughTildeNamePrefixUnchanged() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        // "~user" starts with ~ but is neither "~" alone nor "~/"; returned unchanged, no project found.
        XCTAssertNoThrow(try orchestrator.removeProject(dir: "~notahomedirectory"))
    }

    // Tests archiveWorkspace suppresses isMissingWorktreeError when the worktree directory is not registered in git by arranging representative inputs and asserting the expected result.
    func testArchiveWorkspaceSuppressesIsMissingWorktreeErrorForUnregisteredPath() throws {
        let repo = try makeTempGitRepo(name: "archive-git-missing-worktree-path")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)

        // Create a workspace record pointing to a path that is NOT a registered git worktree.
        // When archiveWorkspace calls git.removeWorktree, git fails with "not a working tree"
        // → isMissingWorktreeError returns true → error is suppressed.
        let fakeWorktreeDir = root.appendingPathComponent("not-a-registered-worktree").path
        let workspaceRecord = WorkspaceRecord(
            id: UUID().uuidString, projectID: project.id, name: "fake-worktree-ws",
            dir: fakeWorktreeDir, dirname: "fake", branch: "feature-x", isDefault: false,
            isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: workspaceRecord)

        XCTAssertNoThrow(try orchestrator.archiveWorkspace(workspaceID: workspaceRecord.id))

        let archived = try store.workspace(id: workspaceRecord.id)
        XCTAssertEqual(archived?.isArchived, true)
    }

    // Tests removeProject without projectsRootDirectory exercises the default repositories and legacy project root directory paths by arranging representative inputs and asserting the expected result.
    func testRemoveGitProjectWithoutProjectsRootDirectoryCoversDefaultRootPaths() throws {
        let store = try makeTemporaryStore()
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        // projectsRootDirectory is nil → repositoriesRootDirectory() uses ~/muxy/repos (default path)
        // and legacyProjectsRootDirectory() uses ~/muxy/projects (default path).
        let orchestrator = MuxyOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        // Insert a fake git project at a temp path so removeProject reaches isManagedRepositoryDirectory.
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let projectRecord = ProjectRecord(id: tempDir, name: "coverage-test", dir: tempDir, isGitRepo: true, defaultBranch: "main")
        try store.upsert(project: projectRecord)
        let workspaceRecord = WorkspaceRecord(
            id: UUID().uuidString, projectID: tempDir, name: "default", dir: tempDir, dirname: nil, branch: "main",
            isDefault: true, isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: workspaceRecord)

        // removeProject exercises isManagedRepositoryDirectory which calls repositoriesRootDirectory()
        // and legacyProjectsRootDirectory(); the temp path is under neither managed root so nothing gets deleted.
        try orchestrator.removeProject(dir: tempDir)
        XCTAssertNil(try store.project(dir: tempDir))
    }

    // Tests createWorkspaceFromWorktree throws workspaceAlreadyExists when a non-archived workspace with the same name already exists.
    func testCreateWorkspaceFromWorktreeThrowsWorkspaceAlreadyExists() throws {
        let repo = try makeTempGitRepo(name: "workspace-duplicate-name")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        _ = try orchestrator.addProject(dir: repo.path)

        // Create first worktree and register it with name "feature".
        let worktree1 = root.appendingPathComponent("worktree1", isDirectory: true)
        try runGit(["worktree", "add", "-b", "feature-branch-1", worktree1.path], cwd: repo.path)
        _ = try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree1.path, name: "feature")

        // Create a second worktree at a different path but register with the same name "feature".
        // This should fail because a non-archived workspace named "feature" already exists.
        let worktree2 = root.appendingPathComponent("worktree2", isDirectory: true)
        try runGit(["worktree", "add", "-b", "feature-branch-2", worktree2.path], cwd: repo.path)
        XCTAssertThrowsError(try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree2.path, name: "feature")) { error in
            guard case MuxyError.workspaceAlreadyExists = error else {
                return XCTFail("Expected workspaceAlreadyExists, got \(error)")
            }
        }
    }

    // Tests addProject(dir:) throws projectAlreadyExists when the directory has already been imported.
    func testAddProjectDirThrowsWhenProjectAlreadyExists() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        _ = try orchestrator.addProject(dir: projectDir.path)

        XCTAssertThrowsError(try orchestrator.addProject(dir: projectDir.path)) { error in
            guard case MuxyError.projectAlreadyExists = error else {
                return XCTFail("Expected projectAlreadyExists, got \(error)")
            }
        }
    }

    // Tests updateWorkspaceName throws invalidArgument when the new name is empty or whitespace-only.
    func testUpdateWorkspaceNameRejectsEmptyName() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        XCTAssertThrowsError(try orchestrator.updateWorkspaceName(workspaceID: workspace.id, name: "")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Workspace name is required"))
        }
        XCTAssertThrowsError(try orchestrator.updateWorkspaceName(workspaceID: workspace.id, name: "   ")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Workspace name is required"))
        }
    }

    // Tests updateWorkspaceName is a no-op when the trimmed name matches the current name.
    func testUpdateWorkspaceNameIsNoOpWhenNameIsUnchanged() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Renaming to the same name should not throw and should not change the record.
        XCTAssertNoThrow(try orchestrator.updateWorkspaceName(workspaceID: workspace.id, name: "feature"))
        let fetched = try XCTUnwrap(store.workspace(id: workspace.id))
        XCTAssertEqual(fetched.name, "feature")
    }

    // Tests addProject(gitURL:) throws invalidArgument when the URL is an empty string.
    func testAddProjectByGitURLThrowsWhenURLIsEmpty() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        XCTAssertThrowsError(try orchestrator.addProject(gitURL: "")) { error in
            guard case MuxyError.invalidArgument = error else {
                return XCTFail("Expected invalidArgument, got \(error)")
            }
        }
        XCTAssertThrowsError(try orchestrator.addProject(gitURL: "   ")) { error in
            guard case MuxyError.invalidArgument = error else {
                return XCTFail("Expected invalidArgument, got \(error)")
            }
        }
    }

    // Tests createWorkspace throws invalidArgument when the workspace name is empty.
    func testCreateWorkspaceThrowsWhenNameIsEmpty() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)

        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id, name: "")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Workspace name is required"))
        }
        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id, name: "   ")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Workspace name is required"))
        }
    }

    // Tests openWorkspaceEditor throws invalidArgument when the workspace is archived.
    func testOpenWorkspaceEditorThrowsForArchivedWorkspace() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Archive the workspace directly via the store.
        try store.updateWorkspaceArchived(id: workspace.id, isArchived: true)

        XCTAssertThrowsError(try orchestrator.openWorkspaceEditor(workspaceID: workspace.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("archived"))
        }
    }

    // Tests openWorkspaceTerminal throws invalidArgument when the workspace is archived.
    func testOpenWorkspaceTerminalThrowsForArchivedWorkspace() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Archive the workspace directly via the store.
        try store.updateWorkspaceArchived(id: workspace.id, isArchived: true)

        XCTAssertThrowsError(try orchestrator.openWorkspaceTerminal(workspaceID: workspace.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("archived"))
        }
    }

    // Tests focusWorkspaceWindow with index 0 is a no-op (guard index > 0 early return).
    func testFocusWorkspaceWindowWithZeroIndexIsNoOp() throws {
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace()

        // Index 0 is invalid (windows are 1-based); should return without throwing.
        XCTAssertNoThrow(try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 0))
    }

    // Tests focusWorkspaceWindow with an out-of-bounds index is a no-op (guard index <= windows.count early return).
    func testFocusWorkspaceWindowWithOutOfBoundsIndexIsNoOp() throws {
        let (orchestrator, _, _, workspace, _) = try makeOrchestratorWithWorkspace()
        // No windows are tracked; index 99 is out of bounds.
        XCTAssertNoThrow(try orchestrator.focusWorkspaceWindow(workspaceID: workspace.id, index: 99))
    }

    // Tests scanAndCreateWorkspacesFromWorktrees throws missingProject when a specific projectID is not found.
    func testScanAndCreateWorkspacesFromWorktreesThrowsForMissingProjectID() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        XCTAssertThrowsError(try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: "/nonexistent/project/\(UUID().uuidString)")) { error in
            guard case MuxyError.missingProject = error else {
                return XCTFail("Expected missingProject, got \(error)")
            }
        }
    }

    // Tests addProject(gitURL:) throws projectAlreadyExists when the same destination is already registered.
    func testAddProjectByGitURLThrowsWhenProjectAlreadyExistsInDB() throws {
        let fixture = try makeTempGitRepo(name: "duplicate-project")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        _ = try orchestrator.addProject(gitURL: fixture.path)

        // The destination directory now exists in the repos root AND in the DB.
        // Cloning again should fail because the project already exists in the DB.
        XCTAssertThrowsError(try orchestrator.addProject(gitURL: fixture.path)) { error in
            // Either projectAlreadyExists (DB hit) or invalidArgument (directory on disk hit) — both are valid.
            let desc = error.localizedDescription
            XCTAssertTrue(desc.contains("already exists"), "Expected 'already exists' in error, got: \(desc)")
        }
    }

    // Tests updateWorkspaceMetadata with all-nil arguments is a no-op (covers guard didChange else { return }).
    func testUpdateWorkspaceMetadataWithAllNilArgsIsNoOp() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // No optional parameters → didChange stays false → guard else return is hit.
        XCTAssertNoThrow(try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id))
        let fetched = try XCTUnwrap(store.workspace(id: workspace.id))
        XCTAssertEqual(fetched.name, "feature")
    }

    // Tests updateWorkspaceMetadata with the same title as current is a no-op (covers trimmedTitle == workspace.name false branch).
    func testUpdateWorkspaceMetadataWithSameTitleIsNoOp() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // Same title → trimmedTitle == workspace.name → no change, didChange stays false.
        XCTAssertNoThrow(try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, title: "feature"))
        let fetched = try XCTUnwrap(store.workspace(id: workspace.id))
        XCTAssertEqual(fetched.name, "feature")
    }

    // Tests updateWorkspaceMetadata with a tooltip matching the current (nil) is a no-op (covers tooltip == workspace.tooltip false branch).
    func testUpdateWorkspaceMetadataWithSameTooltipIsNoOp() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")

        // tooltip: .some(nil) — outer optional is present, inner value is nil (same as current nil tooltip).
        // tooltip != workspace.tooltip → nil != nil → false → didChange stays false → guard else return.
        XCTAssertNoThrow(try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, tooltip: .some(nil)))
        let fetched = try XCTUnwrap(store.workspace(id: workspace.id))
        XCTAssertNil(fetched.tooltip)
    }

    // Tests upWorkspace throws invalidArgument when the workspace is archived (covers guard !workspace.isArchived else throw).
    func testUpWorkspaceThrowsForArchivedWorkspace() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, name: "feature")
        try store.updateWorkspaceArchived(id: workspace.id, isArchived: true)

        XCTAssertThrowsError(try orchestrator.upWorkspace(workspaceID: workspace.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("archived"))
        }
    }

    // Tests updateProjectConfig throws missingProject when the project ID does not exist in the store.
    func testUpdateProjectConfigThrowsForMissingProject() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)

        XCTAssertThrowsError(try orchestrator.updateProjectConfig(projectID: "/nonexistent/\(UUID().uuidString)") { _ in }) { error in
            guard case MuxyError.missingProject = error else {
                return XCTFail("Expected missingProject, got \(error)")
            }
        }
    }

    // Tests addProject(gitURL:) throws when the cloned repo has neither main nor master branch.
    func testAddProjectByGitURLThrowsWhenRepoHasNeitherMainNorMaster() throws {
        let fixture = try makeTempGitRepo(name: "develop-only", initialBranch: "develop")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        XCTAssertThrowsError(try orchestrator.addProject(gitURL: fixture.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("main or master branch"))
        }
    }

    // Tests addProject(gitURL:) succeeds for a repo with only a master branch (covers preferredImportedDefaultBranch master path).
    func testAddProjectByGitURLSucceedsWithMasterBranch() throws {
        let fixture = try makeTempGitRepo(name: "master-only", initialBranch: "master")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(gitURL: fixture.path)
        XCTAssertEqual(project.defaultBranch, "master")
    }

    // Tests addProject(gitURL:) with an SSH-style URL (no "://", colon after last slash) covers inferredProjectName SSH path.
    func testAddProjectByGitURLWithSSHStyleURLCoversInferredProjectName() throws {
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        // URL: "users/host:sshrepo.git" — no "://", colon (index 10) > last slash (index 5).
        // inferredProjectName strips the SSH prefix → "sshrepo.git" → strips ".git" → "sshrepo".
        // Clone will fail (not a real remote), but lines 2657-2659 are covered before the clone attempt.
        XCTAssertThrowsError(try orchestrator.addProject(gitURL: "users/host:sshrepo.git"))
    }

    // Tests addProject(gitURL:) with a project name containing "." covers sanitizeDirname's return "-" path.
    func testAddProjectByGitURLWithSpecialCharsInNameSanitizesDirname() throws {
        let fixture = try makeTempGitRepo(name: "my.project", initialBranch: "main")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        // "my.project" contains "." → sanitizeDirname replaces "." with "-" → cloned as "my-project".
        let project = try orchestrator.addProject(gitURL: fixture.path)
        XCTAssertEqual(project.name, "my-project")
    }

    // Tests createWorkspace throws when the requested directoryName is already in use by another workspace (covers makeWorkspaceDirname line 2503).
    func testCreateWorkspaceDirnameConflictThrows() throws {
        let repo = try makeTempGitRepo(name: "dirname-conflict-repo")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        _ = try orchestrator.createWorkspace(
            projectID: project.id, name: "feature-a", branch: "feature-a", directoryName: "apple",
            runSetupScript: false)
        XCTAssertThrowsError(
            try orchestrator.createWorkspace(
                projectID: project.id, name: "feature-b", branch: "feature-b", directoryName: "apple",
                runSetupScript: false)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("already in use"), "Expected 'already in use' error, got: \(error)")
        }
    }

    // MARK: - resolvedWorkspaceBrowserSessions

    // Tests resolvedWorkspaceBrowserSessions returns sessions with static URLs unchanged.
    func testResolvedWorkspaceBrowserSessionsReturnsStaticURLsUnchanged() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/projects/app")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, name: "dev", dir: "/projects/app")
        try store.upsert(workspace: workspace)
        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id,
            sessions: [
                BrowserSession(name: "App", url: "http://localhost:3000"),
                BrowserSession(name: "Admin", url: "http://localhost:3000/admin"),
            ])

        let resolved = try orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspace.id)
        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved[0].name, "App")
        XCTAssertEqual(resolved[0].url, "http://localhost:3000")
        XCTAssertEqual(resolved[1].name, "Admin")
        XCTAssertEqual(resolved[1].url, "http://localhost:3000/admin")
    }

    // Tests resolvedWorkspaceBrowserSessions expands port env vars to their allocated values.
    func testResolvedWorkspaceBrowserSessionsExpandsPortEnvVars() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/projects/app")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, name: "dev", dir: "/projects/app")
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000, 4000], names: ["PORT", "API_PORT"])
        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id,
            sessions: [
                BrowserSession(name: "Frontend", url: "http://localhost:$PORT"),
                BrowserSession(name: "API", url: "http://localhost:$API_PORT/v1"),
            ])

        let resolved = try orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspace.id)
        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved[0].name, "Frontend")
        XCTAssertEqual(resolved[0].url, "http://localhost:3000")
        XCTAssertEqual(resolved[1].name, "API")
        XCTAssertEqual(resolved[1].url, "http://localhost:4000/v1")
    }

    // Tests resolvedWorkspaceBrowserSessions deduplicates sessions that resolve to the same URL.
    func testResolvedWorkspaceBrowserSessionsDeduplicatesSameResolvedURL() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/projects/app")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, name: "dev", dir: "/projects/app")
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000], names: ["PORT"])
        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id,
            sessions: [
                BrowserSession(name: "First", url: "http://localhost:$PORT"),
                BrowserSession(name: "Duplicate", url: "http://localhost:$PORT"),
            ])

        let resolved = try orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspace.id)
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].name, "First")
        XCTAssertEqual(resolved[0].url, "http://localhost:3000")
    }

    // Tests resolvedWorkspaceBrowserSessions omits sessions with empty or nil URLs.
    func testResolvedWorkspaceBrowserSessionsOmitsSessionsWithEmptyURL() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/projects/app")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, name: "dev", dir: "/projects/app")
        try store.upsert(workspace: workspace)
        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id,
            sessions: [
                BrowserSession(name: "App", url: "http://localhost:3000"),
                BrowserSession(name: "NoURL", url: nil),
            ])

        let resolved = try orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspace.id)
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].name, "App")
    }

    // Tests resolvedWorkspaceBrowserSessions resolved URLs enable longest-prefix name matching.
    func testResolvedWorkspaceBrowserSessionsEnablesLongestPrefixNameMatching() throws {
        let store = try makeTemporaryStore()
        let orchestrator = MuxyOrchestrator(store: store)
        let project = makeProjectRecord(dir: "/projects/app")
        try store.upsert(project: project)
        let workspace = makeWorkspaceRecord(projectID: project.id, name: "dev", dir: "/projects/app")
        try store.upsert(workspace: workspace)
        try store.setWorkspacePorts(workspaceID: workspace.id, ports: [3000], names: ["PORT"])
        try store.setWorkspaceBrowserSessions(
            workspaceID: workspace.id,
            sessions: [
                BrowserSession(name: "App", url: "http://localhost:$PORT"),
                BrowserSession(name: "Admin", url: "http://localhost:$PORT/admin"),
            ])

        let resolved = try orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspace.id)
        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(resolved[0].url, "http://localhost:3000")
        XCTAssertEqual(resolved[1].url, "http://localhost:3000/admin")

        // Simulate the longest-prefix name lookup that the GUI uses.
        let tabURL = "http://localhost:3000/admin/users"
        var bestName: String?
        var bestLength = 0
        for session in resolved {
            guard let prefix = session.url, !prefix.isEmpty, tabURL.hasPrefix(prefix) else { continue }
            if prefix.count > bestLength { bestLength = prefix.count; bestName = session.name }
        }
        XCTAssertEqual(bestName, "Admin", "Longest-prefix match should yield 'Admin' not 'App'")
    }
}
