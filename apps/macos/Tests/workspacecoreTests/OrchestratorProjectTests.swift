import CryptoKit
import XCTest
import spacesterminalcore
import systembridge

@testable import workspacecore

extension OrchestratorTests {

    // Tests add project by cloning uses repos root and repo name by arranging representative inputs and asserting the expected result.
    func testAddProjectByCloningUsesReposRootAndRepoName() throws {
        let fixture = try makeTempGitRepo(name: "sample-repo")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(gitURL: fixture.path)

        XCTAssertTrue(project.dir.hasPrefix(reposRoot.path))
        XCTAssertEqual(
            URL(fileURLWithPath: project.dir).lastPathComponent,
            managedProjectStorageDirname(namespace: "git", source: fixture.path, preferredName: "sample-repo"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.dir))
        XCTAssertEqual(
            try runGitAndCapture(["rev-parse", "--is-bare-repository"], cwd: project.dir).trimmingCharacters(in: .whitespacesAndNewlines), "true")
        let defaultWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first(where: \.isDefault))
        XCTAssertEqual(defaultWorkspace.displayName, "main")
        XCTAssertEqual(defaultWorkspace.branch, "main")
        XCTAssertTrue(defaultWorkspace.dir.hasPrefix(workspacesRoot.path))
        XCTAssertEqual(URL(fileURLWithPath: defaultWorkspace.dir).lastPathComponent, "main")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(defaultWorkspace.dir)/README.md"))
    }

    // Tests add project by cloning strips git suffix from repo name by arranging representative inputs and asserting the expected result.
    func testAddProjectByCloningStripsGitSuffixFromRepoName() throws {
        let fixture = try makeTempGitRepo(name: "source.git")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(gitURL: fixture.path)

        XCTAssertTrue(project.dir.hasPrefix(reposRoot.path))
        XCTAssertEqual(
            URL(fileURLWithPath: project.dir).lastPathComponent,
            managedProjectStorageDirname(namespace: "git", source: fixture.path, preferredName: "source"))
        XCTAssertEqual(project.name, "source")
        XCTAssertEqual(
            try runGitAndCapture(["rev-parse", "--is-bare-repository"], cwd: project.dir).trimmingCharacters(in: .whitespacesAndNewlines), "true")
    }

    // Tests add project by cloning follows a repository default branch named master.
    func testAddProjectByCloningUsesMasterWhenItIsRepositoryDefault() throws {
        let fixture = try makeTempGitRepo(name: "master-only", initialBranch: "master")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(gitURL: fixture.path)
        let defaultWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first(where: \.isDefault))

        XCTAssertEqual(project.defaultBranch, "master")
        XCTAssertEqual(defaultWorkspace.displayName, "master")
        XCTAssertEqual(defaultWorkspace.branch, "master")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(defaultWorkspace.dir)/README.md"))
    }

    // Tests remove project deletes managed git project directory by arranging representative inputs and asserting the expected result.
    func testRemoveProjectDeletesManagedGitProjectDirectory() throws {
        let fixture = try makeTempGitRepo(name: "managed")
        let root = try makeTempDirectory()
        let projectsRoot = root.appendingPathComponent("repos", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: projectsRoot)

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
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: projectsRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(gitURL: fixture.path)
        let projectWorkspaceRoot = URL(
            fileURLWithPath: try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first(where: \.isDefault)).dir
        ).deletingLastPathComponent()
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
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "init"], cwd: projectDir.path)

        let root = try makeTempDirectory()
        let projectsRoot = root.appendingPathComponent("projects", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: projectsRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "feature")
        let projectWorkspaceRoot = URL(fileURLWithPath: workspace.dir).deletingLastPathComponent()
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

    // Tests list projects returns sorted summaries by arranging representative inputs and asserting the expected result.
    func testListProjectsReturnsSortedSummaries() throws {
        let root = try makeTempDirectory()
        let aDir = root.appendingPathComponent("alpha", isDirectory: true)
        let bDir = root.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: aDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        _ = try orchestrator.addProject(dir: bDir.path)
        _ = try orchestrator.addProject(dir: aDir.path)
        let projects = try orchestrator.listProjects()

        XCTAssertEqual(projects.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(projects.map(\.isGitRepo), [false, false])
    }

    func testAddProjectDirImportsSpacesYAMLAsAuthoritativeCreateTimeConfig() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try spacesYAMLFixture(stopScript: "echo yaml-stop").write(
            to: projectDir.appendingPathComponent("spaces.yaml"), atomically: true, encoding: .utf8)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path) { config in
            config.stopScript = "echo ignored"
            config.agentLaunchers = [AgentLauncher(name: "Ignored", command: "ignored")]
        }

        XCTAssertEqual(project.stopScript, "echo yaml-stop")
        XCTAssertEqual(project.ports.map(\.name), ["api"])
        XCTAssertEqual(project.processes.first?.name, "api")
        XCTAssertEqual(project.browserSessions.first?.url, "http://localhost:3000")
        XCTAssertEqual(project.agentLaunchers.first?.command, "codex")
        let defaultWorkspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first(where: \.isDefault))
        let settings = try orchestrator.workspaceSettings(workspaceID: defaultWorkspace.id)
        XCTAssertEqual(settings?.stopScript, "echo yaml-stop")
        XCTAssertEqual(settings?.ports.map(\.name) ?? [], ["api"])
        XCTAssertEqual(settings?.processes.first?.name, "api")
    }

    func testAddProjectByGitURLImportsSpacesYAMLFromDefaultWorktree() throws {
        let fixture = try makeTempGitRepo(name: "yaml-git-import")
        try spacesYAMLFixture(stopScript: "echo git-yaml-stop").write(
            to: fixture.appendingPathComponent("spaces.yaml"), atomically: true, encoding: .utf8)
        try runGit(["add", "spaces.yaml"], cwd: fixture.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add spaces yaml"], cwd: fixture.path)
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(gitURL: fixture.path)

        XCTAssertEqual(project.stopScript, "echo git-yaml-stop")
        XCTAssertEqual(project.processes.first?.command, "npm run api")
        let configURL = try orchestrator.spacesYAMLConfigURL(projectID: project.id)
        XCTAssertTrue(configURL.path.hasPrefix(workspacesRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))
        let defaultWorkspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first(where: \.isDefault))
        let settings = try orchestrator.workspaceSettings(workspaceID: defaultWorkspace.id)
        XCTAssertEqual(settings?.stopScript, "echo git-yaml-stop")
        XCTAssertEqual(settings?.agentLaunchers.first?.name, "Codex")
    }

    func testGitProjectPreviewAndCreateUseRepositoryDefaultBranch() throws {
        let fixture = try makeTempGitRepo(name: "yaml-git-default-master", initialBranch: "master")
        try spacesYAMLFixture(stopScript: "echo master-stop").write(
            to: fixture.appendingPathComponent("spaces.yaml"), atomically: true, encoding: .utf8)
        try runGit(["add", "spaces.yaml"], cwd: fixture.path)
        try runGit(["commit", "-m", "add master spaces yaml"], cwd: fixture.path)
        try runGit(["checkout", "-b", "main"], cwd: fixture.path)
        try spacesYAMLFixture(stopScript: "echo main-stop").write(
            to: fixture.appendingPathComponent("spaces.yaml"), atomically: true, encoding: .utf8)
        try runGit(["add", "spaces.yaml"], cwd: fixture.path)
        try runGit(["commit", "-m", "add main spaces yaml"], cwd: fixture.path)
        try runGit(["checkout", "master"], cwd: fixture.path)
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let preview = try orchestrator.previewGitProject(gitURL: fixture.path)
        let prepared = try orchestrator.prepareGitProject(gitURL: fixture.path, replaceExistingManagedDirectories: true)
        defer { try? orchestrator.discardPreparedGitProject(prepared) }

        XCTAssertEqual(preview.project.defaultBranch, "master")
        XCTAssertEqual(preview.project.stopScript, "echo master-stop")
        XCTAssertEqual(prepared.project.defaultBranch, "master")
        XCTAssertEqual(prepared.defaultWorkspace.branch, "master")
        XCTAssertEqual(prepared.project.stopScript, "echo master-stop")
    }

    // The add-project preview loads spaces.yaml by fetching just that file — no clone is left in the
    // managed repositories directory, and no spaces.yaml means an empty (but present) config.
    func testPreviewGitProjectLoadsSpacesYAMLWithoutCloning() throws {
        let fixture = try makeTempGitRepo(name: "yaml-git-preview")
        try spacesYAMLFixture(stopScript: "echo preview-stop").write(
            to: fixture.appendingPathComponent("spaces.yaml"), atomically: true, encoding: .utf8)
        try runGit(["add", "spaces.yaml"], cwd: fixture.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add spaces yaml"], cwd: fixture.path)
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let preview = try orchestrator.previewGitProject(gitURL: fixture.path)

        XCTAssertEqual(preview.project.stopScript, "echo preview-stop")
        XCTAssertEqual(preview.project.processes.first?.command, "npm run api")
        XCTAssertTrue(preview.replacementCandidates.isEmpty)
        XCTAssertTrue(preview.spacesYAMLFound)
        // The preview must not clone into the managed repositories directory.
        let managedRepo = reposRoot.appendingPathComponent(
            managedProjectStorageDirname(namespace: "git", source: fixture.path, preferredName: "yaml-git-preview"), isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: managedRepo.path))

        // A repository without spaces.yaml still previews, reporting not-found with an empty config.
        let plain = try makeTempGitRepo(name: "plain-git-preview")
        let plainPreview = try orchestrator.previewGitProject(gitURL: plain.path)
        XCTAssertFalse(plainPreview.spacesYAMLFound)
        XCTAssertNil(plainPreview.project.stopScript)
        XCTAssertTrue(plainPreview.project.processes.isEmpty)
    }

    // At Create the daemon clones and then applies the user's reviewed config (via addPreparedGitProject)
    // rather than the repo's own spaces.yaml, so edits made in the form are preserved.
    func testAddPreparedGitProjectAppliesReviewedConfigOverRepoSpacesYAML() throws {
        let fixture = try makeTempGitRepo(name: "yaml-git-create-config")
        try spacesYAMLFixture(stopScript: "echo repo-stop").write(
            to: fixture.appendingPathComponent("spaces.yaml"), atomically: true, encoding: .utf8)
        try runGit(["add", "spaces.yaml"], cwd: fixture.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add spaces yaml"], cwd: fixture.path)
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let prepared = try orchestrator.prepareGitProject(gitURL: fixture.path, replaceExistingManagedDirectories: true)
        // Sanity: the repo's spaces.yaml was detected.
        XCTAssertEqual(prepared.project.processes.first?.command, "npm run api")

        let project = try orchestrator.addPreparedGitProject(prepared) { config in
            config.stopScript = "echo reviewed-stop"
            config.processes = [ProcessTemplate(name: "reviewed", command: "npm run reviewed")]
        }

        XCTAssertEqual(project.stopScript, "echo reviewed-stop")
        XCTAssertEqual(project.processes.map(\.name), ["reviewed"])
        let defaultWorkspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first(where: \.isDefault))
        let settings = try orchestrator.workspaceSettings(workspaceID: defaultWorkspace.id)
        XCTAssertEqual(settings?.processes.first?.command, "npm run reviewed")
    }

    func testAddReviewedProjectUsesEditedSettingsFromHydratedPreview() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("reviewed-project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try spacesYAMLFixture(stopScript: "echo yaml-stop").write(
            to: projectDir.appendingPathComponent("spaces.yaml"), atomically: true, encoding: .utf8)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addReviewedProject(dir: projectDir.path) { config in
            config.stopScript = "echo edited-stop"
            config.processes = [ProcessTemplate(name: "edited", command: "npm run edited")]
        }

        XCTAssertEqual(project.stopScript, "echo edited-stop")
        XCTAssertEqual(project.processes.first?.name, "edited")
        let defaultWorkspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first(where: \.isDefault))
        let settings = try orchestrator.workspaceSettings(workspaceID: defaultWorkspace.id)
        XCTAssertEqual(settings?.stopScript, "echo edited-stop")
        XCTAssertEqual(settings?.processes.first?.command, "npm run edited")
    }

    func testAddReviewedProjectDoesNotReloadLocalSpacesYAMLAtSaveTime() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("reviewed-project-invalid-yaml-after-preview", isDirectory: true)
        let configURL = projectDir.appendingPathComponent("spaces.yaml")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try spacesYAMLFixture(stopScript: "echo preview-stop").write(to: configURL, atomically: true, encoding: .utf8)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let preview = try orchestrator.previewProject(dir: projectDir.path)
        try "version: [".write(to: configURL, atomically: true, encoding: .utf8)

        let project = try orchestrator.addReviewedProject(dir: projectDir.path) { config in
            config.stopScript = preview.stopScript
            config.ports = preview.ports
            config.processes = preview.processes
            config.browserSessions = preview.browserSessions
            config.agentLaunchers = preview.agentLaunchers
        }

        XCTAssertEqual(project.stopScript, "echo preview-stop")
        XCTAssertEqual(project.processes.first?.command, "npm run api")
        let defaultWorkspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first(where: \.isDefault))
        let settings = try orchestrator.workspaceSettings(workspaceID: defaultWorkspace.id)
        XCTAssertEqual(settings?.stopScript, "echo preview-stop")
        XCTAssertEqual(settings?.processes.first?.command, "npm run api")
    }

    func testAddProjectByGitURLRollsBackManagedCloneWhenSpacesYAMLIsInvalid() throws {
        let fixture = try makeTempGitRepo(name: "invalid-yaml-git-import")
        try "version: 999\n".write(to: fixture.appendingPathComponent("spaces.yaml"), atomically: true, encoding: .utf8)
        try runGit(["add", "spaces.yaml"], cwd: fixture.path)
        try runGit(
            ["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add invalid spaces yaml"], cwd: fixture.path)
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let reservedBefore = PortReserver.shared.reservedWorkspaceIDs()
        defer {
            for workspaceID in PortReserver.shared.reservedWorkspaceIDs().subtracting(reservedBefore) {
                PortReserver.shared.releasePorts(workspaceID: workspaceID)
            }
        }

        XCTAssertThrowsError(try orchestrator.addProject(gitURL: fixture.path) { config in config.ports = [ServiceDefinition(name: "api")] }) {
            error in XCTAssertTrue(error.localizedDescription.contains("Unsupported spaces.yaml version 999"))
        }

        let managedDirname = managedProjectStorageDirname(namespace: "git", source: fixture.path, preferredName: "invalid-yaml-git-import")
        XCTAssertTrue(try store.projects().isEmpty)
        XCTAssertTrue(PortReserver.shared.reservedWorkspaceIDs().subtracting(reservedBefore).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reposRoot.appendingPathComponent(managedDirname, isDirectory: true).path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workspacesRoot.appendingPathComponent(managedDirname, isDirectory: true).appendingPathComponent("main", isDirectory: true)
                    .path))
    }

    func testAddProjectByGitURLRollsBackPreparedCloneWhenReviewedConfigIsInvalid() throws {
        let fixture = try makeTempGitRepo(name: "invalid-reviewed-git-import")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        XCTAssertThrowsError(try orchestrator.addProject(gitURL: fixture.path) { config in config.ports = [ServiceDefinition(name: "   ")] }) {
            error in XCTAssertTrue(error.localizedDescription.contains("service name"))
        }

        let managedDirname = managedProjectStorageDirname(namespace: "git", source: fixture.path, preferredName: "invalid-reviewed-git-import")
        XCTAssertTrue(try store.projects().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reposRoot.appendingPathComponent(managedDirname, isDirectory: true).path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workspacesRoot.appendingPathComponent(managedDirname, isDirectory: true).appendingPathComponent("main", isDirectory: true)
                    .path))
    }

    // Tests add project stores in db only by arranging representative inputs and asserting the expected result.
    func testAddProjectStoresInDBOnly() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("myproject", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let record = try orchestrator.addProject(dir: projectDir.path)

        // Project is in DB
        XCTAssertNotNil(try store.project(id: record.id))

        // Project count in DB is correct
        XCTAssertEqual(try store.projects().count, 1)
    }

    // Tests remove project deletes from db by arranging representative inputs and asserting the expected result.
    func testRemoveProjectDeletesFromDB() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        XCTAssertNotNil(try store.project(id: project.id))

        try orchestrator.removeProject(dir: projectDir.path)

        XCTAssertNil(try store.project(id: project.id))
    }

    // MARK: - listProjects

    // Tests listProjects returns summaries for all stored projects by arranging representative inputs and asserting the expected result.
    func testListProjectsReturnsSummariesForAllProjects() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

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

    // Tests updateProjectConfig with git repo project refreshes default workspace by arranging representative inputs and asserting the expected result.
    func testAddProjectDirForGitRepoDetectsGitBranch() throws {
        let fixture = try makeTempGitRepo(name: "detect-git")
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: fixture.path)

        XCTAssertTrue(project.isGitRepo)
        XCTAssertNotNil(project.defaultBranch)
        XCTAssertFalse((project.defaultBranch ?? "").isEmpty)
    }

    // Tests addProject throws when directory does not exist by arranging representative inputs and asserting the expected result.
    func testAddProjectThrowsWhenDirectoryNotFound() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        let nonExistent = "/tmp/spaces-test-nonexistent-\(UUID().uuidString)"
        XCTAssertThrowsError(try orchestrator.addProject(dir: nonExistent)) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests addProject by gitURL overwrites abandoned managed destination state by arranging representative inputs and asserting the expected result.
    func testAddProjectByGitURLOverwritesAbandonedDestination() throws {
        let fixture = try makeTempGitRepo(name: "my-repo")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let existingDir = reposRoot.appendingPathComponent(
            managedProjectStorageDirname(namespace: "git", source: fixture.path, preferredName: "my-repo"), isDirectory: true)
        try FileManager.default.createDirectory(at: existingDir, withIntermediateDirectories: true)
        let orphanMarker = existingDir.appendingPathComponent("orphan.txt")
        try "orphan".write(to: orphanMarker, atomically: true, encoding: .utf8)

        let project = try orchestrator.addProject(gitURL: fixture.path)

        XCTAssertEqual(project.dir, existingDir.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanMarker.path))
        XCTAssertEqual(try store.projects().map(\.id), [project.id])
    }

    func testManagedGitProjectImportReplacementCandidatesIncludeOrphanedManagedFolders() throws {
        let fixture = try makeTempGitRepo(name: "candidate-repo")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let managedDirname = managedProjectStorageDirname(namespace: "git", source: fixture.path, preferredName: "candidate-repo")
        let projectDir = reposRoot.appendingPathComponent(managedDirname, isDirectory: true)
        let workspaceRoot = workspacesRoot.appendingPathComponent(managedDirname, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)

        let candidates = try orchestrator.managedGitProjectImportReplacementCandidates(gitURL: fixture.path)

        XCTAssertEqual(Set(candidates.map(\.path)), Set([projectDir.path, workspaceRoot.path]))
        XCTAssertEqual(Set(candidates.map(\.kind)), Set([.projectRepository, .workspaceDirectory]))
    }

    func testManagedGitProjectImportRejectsDatabaseOwnedMissingProjectDirectory() throws {
        let fixture = try makeTempGitRepo(name: "missing-owned-repo")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let projectDir = reposRoot.appendingPathComponent(
            managedProjectStorageDirname(namespace: "git", source: fixture.path, preferredName: "missing-owned-repo"), isDirectory: true)
        try store.upsert(project: ProjectRecord(id: UUID().uuidString, name: "Owned", dir: projectDir.path, isGitRepo: true, defaultBranch: "main"))

        XCTAssertThrowsError(try orchestrator.managedGitProjectImportReplacementCandidates(gitURL: fixture.path)) { error in
            guard case WorkspaceError.projectAlreadyExists = error else { return XCTFail("Expected projectAlreadyExists, got \(error)") }
        }
        XCTAssertThrowsError(try orchestrator.prepareGitProject(gitURL: fixture.path, replaceExistingManagedDirectories: true)) { error in
            guard case WorkspaceError.projectAlreadyExists = error else { return XCTFail("Expected projectAlreadyExists, got \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectDir.path))
    }

    func testManagedGitProjectImportReplacementRemovesManagedSymlinkNotManagedTarget() throws {
        let fixture = try makeTempGitRepo(name: "symlink-managed-target-repo")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let projectDir = reposRoot.appendingPathComponent(
            managedProjectStorageDirname(namespace: "git", source: fixture.path, preferredName: "symlink-managed-target-repo"), isDirectory: true)
        let targetDir = reposRoot.appendingPathComponent("other-managed-folder", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let targetMarker = targetDir.appendingPathComponent("target.txt")
        try "target".write(to: targetMarker, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: projectDir, withDestinationURL: targetDir)

        let candidate = try XCTUnwrap(try orchestrator.managedGitProjectImportReplacementCandidates(gitURL: fixture.path).first)
        XCTAssertEqual(candidate.path, projectDir.path)

        let prepared = try orchestrator.prepareGitProject(gitURL: fixture.path, replaceExistingManagedDirectories: true)

        XCTAssertEqual(prepared.project.dir, projectDir.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetMarker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("HEAD").path))
        let attributes = try FileManager.default.attributesOfItem(atPath: projectDir.path)
        XCTAssertNotEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
    }

    func testManagedGitProjectImportReplacementUnlinksSymlinkToOutsideManagedRoot() throws {
        let fixture = try makeTempGitRepo(name: "symlink-outside-target-repo")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let outsideDir = root.appendingPathComponent("outside-target", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let projectDir = reposRoot.appendingPathComponent(
            managedProjectStorageDirname(namespace: "git", source: fixture.path, preferredName: "symlink-outside-target-repo"), isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: reposRoot, withIntermediateDirectories: true)
        let outsideMarker = outsideDir.appendingPathComponent("outside.txt")
        try "outside".write(to: outsideMarker, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: projectDir, withDestinationURL: outsideDir)

        let candidate = try XCTUnwrap(try orchestrator.managedGitProjectImportReplacementCandidates(gitURL: fixture.path).first)
        XCTAssertEqual(candidate.path, projectDir.path)

        let prepared = try orchestrator.prepareGitProject(gitURL: fixture.path, replaceExistingManagedDirectories: true)

        XCTAssertEqual(prepared.project.dir, projectDir.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outsideMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideDir.appendingPathComponent("HEAD").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("HEAD").path))
        let attributes = try FileManager.default.attributesOfItem(atPath: projectDir.path)
        XCTAssertNotEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
    }

    func testManagedProjectImportReplacementRevalidatesProjectOwnershipBeforeDeleting() throws {
        let fixture = try makeTempGitRepo(name: "owned-repo")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let projectDir = reposRoot.appendingPathComponent(
            managedProjectStorageDirname(namespace: "git", source: fixture.path, preferredName: "owned-repo"), isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let ownerMarker = projectDir.appendingPathComponent("owner.txt")
        try "owner".write(to: ownerMarker, atomically: true, encoding: .utf8)
        XCTAssertEqual(try orchestrator.managedGitProjectImportReplacementCandidates(gitURL: fixture.path).map(\.path), [projectDir.path])

        try store.upsert(project: ProjectRecord(id: UUID().uuidString, name: "Owned", dir: projectDir.path, isGitRepo: true, defaultBranch: "main"))

        XCTAssertThrowsError(try orchestrator.prepareGitProject(gitURL: fixture.path, replaceExistingManagedDirectories: true)) { error in
            guard case WorkspaceError.projectAlreadyExists = error else { return XCTFail("Expected projectAlreadyExists, got \(error)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownerMarker.path))
    }

    // Tests addProject(dir:) throws projectAlreadyExists when the directory has already been imported.
    func testAddProjectDirThrowsWhenProjectAlreadyExists() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)
        _ = try orchestrator.addProject(dir: projectDir.path)

        XCTAssertThrowsError(try orchestrator.addProject(dir: projectDir.path)) { error in
            guard case WorkspaceError.projectAlreadyExists = error else { return XCTFail("Expected projectAlreadyExists, got \(error)") }
        }
    }

    func testAddProjectDirWithInvalidConfigDoesNotPersistPartialProject() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        XCTAssertThrowsError(try orchestrator.addProject(dir: projectDir.path) { project in project.ports = [ServiceDefinition(name: "   ")] }) {
            error in XCTAssertTrue(error.localizedDescription.contains("service name"))
        }

        XCTAssertNil(try store.project(dir: projectDir.path))
        XCTAssertTrue(try store.projects().isEmpty)

        let project = try orchestrator.addProject(dir: projectDir.path) { project in project.ports = [ServiceDefinition(name: "api")] }

        let stored = try XCTUnwrap(store.project(id: project.id))
        XCTAssertEqual(stored.ports.map(\.name), ["api"])
        XCTAssertEqual(try store.workspaces(projectID: project.id).count, 1)
    }

    // Tests addProject(gitURL:) throws invalidArgument when the URL is an empty string.
    func testAddProjectByGitURLThrowsWhenURLIsEmpty() throws {
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store)

        XCTAssertThrowsError(try orchestrator.addProject(gitURL: "")) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
        XCTAssertThrowsError(try orchestrator.addProject(gitURL: "   ")) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests addProject(gitURL:) throws projectAlreadyExists when the same destination is already registered.
    func testAddProjectByGitURLThrowsWhenProjectAlreadyExistsInDB() throws {
        let fixture = try makeTempGitRepo(name: "duplicate-project")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        _ = try orchestrator.addProject(gitURL: fixture.path)

        // The destination directory now exists in the repos root AND in the DB.
        // Cloning again should fail because the project already exists in the DB.
        XCTAssertThrowsError(try orchestrator.addProject(gitURL: fixture.path)) { error in
            // Either projectAlreadyExists (DB hit) or invalidArgument (directory on disk hit) — both are valid.
            let desc = error.localizedDescription
            XCTAssertTrue(desc.contains("already exists"), "Expected 'already exists' in error, got: \(desc)")
        }
    }

    // Tests addProject(gitURL:) accepts a non-conventional branch name when it is the repository default.
    func testAddProjectByGitURLUsesRepositoryDefaultBranchWithNonStandardName() throws {
        let fixture = try makeTempGitRepo(name: "develop-only", initialBranch: "develop")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(gitURL: fixture.path)
        let defaultWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first(where: \.isDefault))

        XCTAssertEqual(project.defaultBranch, "develop")
        XCTAssertEqual(defaultWorkspace.branch, "develop")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(defaultWorkspace.dir)/README.md"))
    }

    // Tests addProject(gitURL:) succeeds for a repository whose default branch is master.
    func testAddProjectByGitURLSucceedsWithMasterBranch() throws {
        let fixture = try makeTempGitRepo(name: "master-only", initialBranch: "master")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(gitURL: fixture.path)
        XCTAssertEqual(project.defaultBranch, "master")
    }

    // Tests addProject(gitURL:) with an SSH-style URL (no "://", colon after last slash) covers inferredProjectName SSH path.
    func testAddProjectByGitURLWithSSHStyleURLCoversInferredProjectName() throws {
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

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
        let orchestrator = WorkspaceOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)

        // "my.project" contains "." → sanitizeDirname replaces "." with "-" → cloned as "my-project".
        let project = try orchestrator.addProject(gitURL: fixture.path)
        XCTAssertEqual(project.name, "my-project")
    }
}
