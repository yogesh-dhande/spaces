import XCTest
import spacesterminalcore

@testable import workspacecore

/// User-initiated project creation (`createProject(dir:)`/`createProject(gitURL:)`, and the Mac app's
/// preview and reviewed create): what it imports, which folders it refuses, and how each refusal names
/// the project or folder the user should use instead.
extension OrchestratorTests {
    func testCreateProjectFromRepositoryRootImportsSpacesYAML() throws {
        let repo = try makeTempGitRepo(name: "yaml-root")
        try spacesYAMLFixture(stopScript: "echo yaml-stop").write(to: repo.appendingPathComponent("spaces.yaml"), atomically: true, encoding: .utf8)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        let created = try orchestrator.createProject(dir: repo.path)

        XCTAssertTrue(created.spacesYAMLImported)
        XCTAssertTrue(created.project.isGitRepo)
        XCTAssertEqual(created.project.defaultBranch, "main")
        XCTAssertEqual(created.project.stopScript, "echo yaml-stop")
        let defaultWorkspace = try XCTUnwrap(try store.workspaces(projectID: created.project.id).first(where: \.isDefault))
        XCTAssertEqual(defaultWorkspace.dir, created.project.dir)
        XCTAssertFalse(defaultWorkspace.isRunning)
    }

    func testCreateProjectFromRepositoryRootWithoutSpacesYAMLReportsNoImport() throws {
        let repo = try makeTempGitRepo(name: "plain-root")
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        let created = try orchestrator.createProject(dir: repo.path)

        XCTAssertFalse(created.spacesYAMLImported)
        XCTAssertTrue(created.project.isGitRepo)
        XCTAssertEqual(try store.workspaces(projectID: created.project.id).filter(\.isDefault).count, 1)
    }

    func testCreateProjectAcceptsFolderOutsideGitWithAndWithoutSpacesYAML() throws {
        let root = try makeTempDirectory()
        let withYAML = root.appendingPathComponent("with-yaml", isDirectory: true)
        let withoutYAML = root.appendingPathComponent("without-yaml", isDirectory: true)
        try FileManager.default.createDirectory(at: withYAML, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: withoutYAML, withIntermediateDirectories: true)
        try spacesYAMLFixture(stopScript: "echo plain-stop").write(
            to: withYAML.appendingPathComponent("spaces.yaml"), atomically: true, encoding: .utf8)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        let imported = try orchestrator.createProject(dir: withYAML.path)
        let plain = try orchestrator.createProject(dir: withoutYAML.path)

        XCTAssertTrue(imported.spacesYAMLImported)
        XCTAssertFalse(imported.project.isGitRepo)
        XCTAssertEqual(imported.project.stopScript, "echo plain-stop")
        XCTAssertFalse(plain.spacesYAMLImported)
        XCTAssertFalse(plain.project.isGitRepo)
        XCTAssertEqual(try store.workspaces(projectID: plain.project.id).filter(\.isDefault).count, 1)
    }

    func testCreateProjectFromGitURLReportsWhetherSpacesYAMLWasImported() throws {
        let withYAML = try makeTempGitRepo(name: "url-with-yaml")
        try spacesYAMLFixture(stopScript: "echo url-yaml-stop").write(
            to: withYAML.appendingPathComponent("spaces.yaml"), atomically: true, encoding: .utf8)
        try runGit(["add", "spaces.yaml"], cwd: withYAML.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add spaces yaml"], cwd: withYAML.path)
        let withoutYAML = try makeTempGitRepo(name: "url-without-yaml")
        let root = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(
            store: store, projectsRootDirectory: root.appendingPathComponent("repos", isDirectory: true),
            workspacesRootDirectory: root.appendingPathComponent("workspaces", isDirectory: true))

        let imported = try orchestrator.createProject(gitURL: withYAML.path, replaceExistingManagedDirectories: false)
        let plain = try orchestrator.createProject(gitURL: withoutYAML.path, replaceExistingManagedDirectories: false)

        XCTAssertTrue(imported.spacesYAMLImported)
        XCTAssertEqual(imported.project.stopScript, "echo url-yaml-stop")
        XCTAssertFalse(plain.spacesYAMLImported)
        for project in [imported.project, plain.project] {
            let defaultWorkspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first(where: \.isDefault))
            XCTAssertFalse(defaultWorkspace.isRunning)
            XCTAssertTrue(FileManager.default.fileExists(atPath: defaultWorkspace.dir))
        }
    }

    /// A `~` path reaches the daemon unexpanded (the CLI on another machine, or MCP, cannot know this
    /// home) and the daemon creating the project expands it against its own home.
    func testCreateProjectExpandsTildeAgainstTheDaemonsHome() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let leaf = "spaces-test-missing-\(UUID().uuidString)"
        let expanded = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(leaf).resolvingSymlinksInPath().standardizedFileURL.path

        XCTAssertThrowsError(try orchestrator.createProject(dir: "~/\(leaf)")) { error in
            XCTAssertEqual(error.localizedDescription, "Invalid argument: Project directory not found: \(expanded)")
        }
    }

    func testCreateProjectRefusesRegisteredFolderNamingTheProject() throws {
        let repo = try makeTempGitRepo(name: "already-added")
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let existing = try orchestrator.createProject(dir: repo.path).project

        let attempts: [() throws -> Void] = [
            { _ = try orchestrator.createProject(dir: repo.path) }, { _ = try orchestrator.previewProject(dir: repo.path) },
        ]
        for attempt in attempts {
            XCTAssertThrowsError(try attempt()) { error in
                guard case WorkspaceError.projectAlreadyExists(let name, let id, let dir) = error else {
                    return XCTFail("Expected projectAlreadyExists, got \(error)")
                }
                XCTAssertEqual(name, existing.name)
                XCTAssertEqual(id, existing.id)
                XCTAssertEqual(dir, existing.dir)
                XCTAssertTrue(error.localizedDescription.contains("\(existing.name) (\(existing.id))"), error.localizedDescription)
            }
        }
        XCTAssertEqual(try store.projects().count, 1)
    }

    func testCreateProjectRefusesRegisteredGitURLNamingTheProjectBeforeCloning() throws {
        let fixture = try makeTempGitRepo(name: "url-already-added")
        let root = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(
            store: store, projectsRootDirectory: root.appendingPathComponent("repos", isDirectory: true),
            workspacesRootDirectory: root.appendingPathComponent("workspaces", isDirectory: true))
        let existing = try orchestrator.createProject(gitURL: fixture.path, replaceExistingManagedDirectories: false).project
        let marker = URL(fileURLWithPath: existing.dir).appendingPathComponent("spaces-test-marker")
        try "kept".write(to: marker, atomically: true, encoding: .utf8)

        // Even a create allowed to replace leftover folders must not touch a folder a project owns.
        for replace in [false, true] {
            XCTAssertThrowsError(try orchestrator.createProject(gitURL: fixture.path, replaceExistingManagedDirectories: replace)) { error in
                guard case WorkspaceError.projectAlreadyExists(let name, let id, _) = error else {
                    return XCTFail("Expected projectAlreadyExists, got \(error)")
                }
                XCTAssertEqual(name, existing.name)
                XCTAssertEqual(id, existing.id)
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try store.projects().map(\.id), [existing.id])
    }

    func testCreateProjectRefusesUnregisteredRepositorySubfolderNamingTheRoot() throws {
        let repo = try makeTempGitRepo(name: "subfolder-root")
        let subfolder = repo.appendingPathComponent("packages/app", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let root = repo.resolvingSymlinksInPath().path

        XCTAssertThrowsError(try orchestrator.createProject(dir: subfolder.path)) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
            XCTAssertTrue(message.contains("inside the git repository at \(root)"), message)
            XCTAssertTrue(message.hasSuffix("add \(root) instead."), message)
        }
        XCTAssertTrue(try store.projects().isEmpty)
    }

    func testCreateProjectRefusesSubfolderOfRegisteredRepositoryNamingTheProject() throws {
        let repo = try makeTempGitRepo(name: "subfolder-owned")
        let subfolder = repo.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let owner = try orchestrator.createProject(dir: repo.path).project

        XCTAssertThrowsError(try orchestrator.createProject(dir: subfolder.path)) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
            XCTAssertTrue(message.contains("is inside project \(owner.name) (\(owner.id))"), message)
        }
    }

    func testCreateProjectRefusesSpacesWorkspaceWorktreeNamingTheProject() throws {
        let fixture = try makeTempGitRepo(name: "workspace-owned")
        let root = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(
            store: store, projectsRootDirectory: root.appendingPathComponent("repos", isDirectory: true),
            workspacesRootDirectory: root.appendingPathComponent("workspaces", isDirectory: true))
        let owner = try orchestrator.createProject(gitURL: fixture.path, replaceExistingManagedDirectories: false).project
        let workspace = try XCTUnwrap(try store.workspaces(projectID: owner.id).first(where: \.isDefault))
        let workspaceSubfolder = URL(fileURLWithPath: workspace.dir).appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceSubfolder, withIntermediateDirectories: true)

        XCTAssertThrowsError(try orchestrator.createProject(dir: workspace.dir)) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
            XCTAssertTrue(message.contains("is a worktree of project \(owner.name) (\(owner.id))"), message)
        }
        XCTAssertThrowsError(try orchestrator.createProject(dir: workspaceSubfolder.path)) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
            XCTAssertTrue(message.contains("is inside a worktree of project \(owner.name) (\(owner.id))"), message)
        }
        XCTAssertEqual(try store.projects().map(\.id), [owner.id])
    }

    func testCreateProjectRefusesUnregisteredLinkedWorktreeNamingTheMainRoot() throws {
        let repo = try makeTempGitRepo(name: "linked-main")
        let worktree = try makeTempDirectory().appendingPathComponent("linked-feature", isDirectory: true)
        try runGit(["worktree", "add", "-b", "feature", worktree.path], cwd: repo.path)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let root = repo.resolvingSymlinksInPath().path

        XCTAssertThrowsError(try orchestrator.createProject(dir: worktree.path)) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
            XCTAssertTrue(message.contains("is a worktree of the git repository at \(root)"), message)
            XCTAssertTrue(message.hasSuffix("add \(root) instead."), message)
        }

        let owner = try orchestrator.createProject(dir: repo.path).project
        XCTAssertThrowsError(try orchestrator.createProject(dir: worktree.path)) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
            XCTAssertTrue(message.contains("is a worktree of project \(owner.name) (\(owner.id))"), message)
        }
    }

    func testCreateProjectRefusesWorktreeOfUnregisteredBareRepositoryPointingAtGitURL() throws {
        let source = try makeTempGitRepo(name: "bare-source")
        let parent = try makeTempDirectory()
        let bare = parent.appendingPathComponent("bare.git", isDirectory: true)
        try runGit(["clone", "--bare", source.path, bare.path], cwd: parent.path)
        let worktree = parent.appendingPathComponent("bare-main", isDirectory: true)
        try runGit(["worktree", "add", worktree.path, "main"], cwd: bare.path)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let bareRoot = bare.resolvingSymlinksInPath().path

        XCTAssertThrowsError(try orchestrator.createProject(dir: worktree.path)) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
            XCTAssertTrue(message.contains("is a worktree of the bare repository at \(bareRoot)"), message)
            XCTAssertTrue(message.hasSuffix("Add the repository by its git URL instead."), message)
        }
        XCTAssertThrowsError(try orchestrator.createProject(dir: bare.path)) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
            XCTAssertTrue(message.contains("is a bare git repository"), message)
        }
        XCTAssertTrue(try store.projects().isEmpty)
    }

    /// A folder whose repository git cannot read is refused rather than added as a plain folder: the root
    /// rule cannot tell whether it belongs to a repository a project already covers.
    func testCreateProjectFailsWhenGitCannotReadTheFoldersRepository() throws {
        let folder = try makeTempDirectory()
        try "garbage\n".write(to: folder.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        XCTAssertThrowsError(try orchestrator.createProject(dir: folder.path)) { error in
            guard case WorkspaceError.gitCommandFailed = error else { return XCTFail("Expected gitCommandFailed, got \(error)") }
        }
        XCTAssertTrue(try store.projects().isEmpty)
    }

    /// The exact-duplicate check runs before the root rule, so a folder that is already a project
    /// (here one an internal caller registered inside another checkout) reports that project rather
    /// than the repository root.
    func testCreateProjectReportsExactDuplicateBeforeTheRootRule() throws {
        let repo = try makeTempGitRepo(name: "duplicate-first")
        let subfolder = repo.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let existing = try orchestrator.addProject(dir: subfolder.path)

        XCTAssertThrowsError(try orchestrator.createProject(dir: subfolder.path)) { error in
            guard case WorkspaceError.projectAlreadyExists(_, let id, _) = error else {
                return XCTFail("Expected projectAlreadyExists, got \(error)")
            }
            XCTAssertEqual(id, existing.id)
        }
    }

    /// The Mac app's add-project flow previews, then creates with the reviewed configuration; both
    /// steps hold the same root rule as `createProject(dir:)`. `addProject(dir:)`, used only by internal
    /// callers that register a folder inside another checkout, does not.
    func testRootRuleCoversPreviewAndReviewedCreateButNotInternalAdd() throws {
        let repo = try makeTempGitRepo(name: "mac-flow")
        let subfolder = repo.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        XCTAssertThrowsError(try orchestrator.previewProject(dir: subfolder.path)) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
        XCTAssertThrowsError(try orchestrator.addReviewedProject(dir: subfolder.path) { _ in }) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
        XCTAssertTrue(try store.projects().isEmpty)

        let internallyAdded = try orchestrator.addProject(dir: subfolder.path)
        XCTAssertEqual(internallyAdded.dir, subfolder.resolvingSymlinksInPath().path)
    }

    func testCreateProjectFromGitURLRefusesLeftoverFoldersUnlessReplacementWasConfirmed() throws {
        let fixture = try makeTempGitRepo(name: "leftover-repo")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let managedDirname = managedProjectStorageDirname(namespace: "git", source: fixture.path, preferredName: "leftover-repo")
        let leftoverRepository = reposRoot.appendingPathComponent(managedDirname, isDirectory: true)
        let leftoverWorkspaces = workspacesRoot.appendingPathComponent(managedDirname, isDirectory: true)
        try FileManager.default.createDirectory(at: leftoverRepository, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: leftoverWorkspaces, withIntermediateDirectories: true)
        let marker = leftoverRepository.appendingPathComponent("orphan.txt")
        try "orphan".write(to: marker, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try orchestrator.createProject(gitURL: fixture.path, replaceExistingManagedDirectories: false)) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
            XCTAssertTrue(message.contains(leftoverRepository.path), message)
            XCTAssertTrue(message.contains(leftoverWorkspaces.path), message)
            XCTAssertTrue(message.contains("Remove them, or add the project from the Spaces Mac app"), message)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(try store.projects().isEmpty)

        let created = try orchestrator.createProject(gitURL: fixture.path, replaceExistingManagedDirectories: true)

        XCTAssertEqual(created.project.dir, leftoverRepository.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}
