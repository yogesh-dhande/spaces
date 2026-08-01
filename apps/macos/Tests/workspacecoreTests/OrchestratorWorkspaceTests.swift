import CryptoKit
import XCTest
import spacesterminalcore
import systembridge

@testable import workspacecore

extension OrchestratorTests {

    func testRollbackFailedImportedProjectCreationRemovesManagedRepoAndWorktreeDirectories() throws {
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let managedDirname = managedProjectStorageDirname(
            namespace: "git", source: "12345678-1234-1234-1234-123456789ABC", preferredName: "sample-repo")

        let project = ProjectRecord(
            id: "12345678-1234-1234-1234-123456789ABC", name: "sample-repo",
            dir: reposRoot.appendingPathComponent(managedDirname, isDirectory: true).path, isGitRepo: true, defaultBranch: "main")
        let projectDir = project.dir
        let workspaceRoot = workspacesRoot.appendingPathComponent(managedDirname, isDirectory: true).path
        let workspaceDir = URL(fileURLWithPath: workspaceRoot).appendingPathComponent("main", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: workspaceDir, withIntermediateDirectories: true)

        try store.upsert(project: project)
        try store.upsert(
            workspace: WorkspaceRecord(
                id: UUID().uuidString, projectID: project.id, dir: workspaceDir, dirname: "main", branch: "main", baseBranch: "main", isDefault: true,
                isArchived: false, isRunning: false, lastLaunchedAt: nil))

        try orchestrator.rollbackFailedImportedProjectCreation(project: project, workspaceDirectory: workspaceDir)

        XCTAssertNil(try store.project(dir: projectDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceDir))
        let workspaceRootContents = try FileManager.default.contentsOfDirectory(atPath: workspaceRoot)
        XCTAssertTrue(workspaceRootContents.isEmpty)
    }

    // Tests create workspace for non git project allocates ports by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceForNonGitProjectAllocatesPorts() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id)

        XCTAssertEqual(workspace.dir, projectDir.path)
        XCTAssertFalse(workspace.isArchived)
        XCTAssertEqual(try orchestrator.workspacePorts(workspaceID: workspace.id).count, 0)
    }

    func testStopWorkspaceSemanticsClearRunningRuntimeRowsAndAdHocTerminalWindows() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let project = makeProjectRecord(dir: projectDir.path)
        let workspace = WorkspaceRecord(
            id: "workspace-stop-all-quit", projectID: project.id, dir: projectDir.path, dirname: nil, branch: nil, isDefault: true, isArchived: false,
            isRunning: true, lastLaunchedAt: "2026-07-01T00:00:00Z")
        try store.upsert(project: project)
        try store.upsert(workspace: workspace)
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "process-web", workspaceID: workspace.id, templateName: "web", command: "npm run dev", terminalApp: TerminalHost.spaces.appName,
                terminalTrackingID: "session-process", pid: nil, status: .running, logPath: nil, lastOutputAt: nil, startedAt: "2026-07-01T00:00:01Z",
                exitedAt: nil))
        try store.upsertAgentWindow(
            AgentWindowRecord(
                id: "agent-codex", workspaceID: workspace.id, provider: .spaces, label: "Codex", terminalTrackingID: "session-agent", sessionKey: nil,
                status: .idle, createdAt: "2026-07-01T00:00:02Z", updatedAt: "2026-07-01T00:00:02Z"))
        try store.upsert(
            window: WindowRecord(
                id: "terminal-ad-hoc", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "Shell",
                terminalTrackingID: "session-shell", role: .terminal, orderIndex: 300, lastSeenAt: "2026-07-01T00:00:03Z"))
        let closed = TerminalCloseCapture()
        let terminated = TerminalTerminateCapture()
        let orchestrator = makeTestOrchestrator(
            store: store, builtInTerminalWindowCloser: { closed.sessionIDs.append($0) },
            builtInTerminalSessionTerminator: { terminated.sessionIDs.append($0) })

        try orchestrator.stopWorkspace(workspaceID: workspace.id)

        XCTAssertFalse(try XCTUnwrap(store.workspace(id: workspace.id)).isRunning)
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.agentWindows(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
        XCTAssertEqual(Set(closed.sessionIDs), ["session-process", "session-agent", "session-shell"])
        XCTAssertEqual(Set(terminated.sessionIDs), ["session-process", "session-agent", "session-shell"])
    }

    // Tests create workspace rejects directory name override for non git project by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceRejectsDirectoryNameOverrideForNonGitProject() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id, directoryName: "feature_dir")) { error in
            XCTAssertTrue(error.localizedDescription.contains("only supported for git projects"))
        }
    }

    // Tests create workspace uses provided directory name for git project by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceUsesProvidedDirectoryNameForGitProject() throws {
        let repo = try makeTempGitRepo(name: "workspace-name-override")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "feature-branch", directoryName: "feature_branch_1")

        XCTAssertEqual(workspace.dirname, "feature_branch_1")
        XCTAssertTrue(workspace.dir.hasSuffix("/feature_branch_1"))
    }

    // Tests create workspace rejects directory name with invalid characters by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceRejectsDirectoryNameWithInvalidCharacters() throws {
        let repo = try makeTempGitRepo(name: "workspace-name-invalid-dirname")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id, branch: "feature-branch", directoryName: "feature/branch")) {
            error in XCTAssertTrue(error.localizedDescription.contains("letters, numbers, '-', and '_'"))
        }
    }

    // Tests create workspace rejects directory name with spaces by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceRejectsDirectoryNameWithSpaces() throws {
        let repo = try makeTempGitRepo(name: "workspace-name-space-dirname")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id, branch: "feature-branch", directoryName: "feature branch")) {
            error in XCTAssertTrue(error.localizedDescription.contains("cannot contain spaces"))
        }
    }

    // Tests create workspace uses selected base branch as base for new branch by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceUsesSelectedBaseBranchAsBaseForNewBranch() throws {
        let repo = try makeTempGitRepo(name: "workspace-target-branch")
        try runGit(["checkout", "-b", "develop"], cwd: repo.path)
        try "target".write(to: repo.appendingPathComponent("TARGET.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "TARGET.txt"], cwd: repo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "target"], cwd: repo.path)
        try runGit(["checkout", "main"], cwd: repo.path)

        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "feature-branch", baseBranch: "develop")

        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.dir + "/TARGET.txt"))
        XCTAssertEqual(workspace.baseBranch, "develop")
    }

    // Tests create workspace defaults base branch to project default when omitted by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceDefaultsBaseBranchToProjectDefaultBranch() throws {
        let repo = try makeTempGitRepo(name: "workspace-default-target")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "feature")

        XCTAssertEqual(workspace.displayName, "feature")
        XCTAssertEqual(workspace.branch, "feature")
        XCTAssertEqual(workspace.baseBranch, project.defaultBranch)
    }

    // Tests archive workspace removes git worktree registration by arranging representative inputs and asserting the expected result.
    func testArchiveWorkspaceRemovesGitWorktreeRegistration() throws {
        let repo = try makeTempGitRepo(name: "workspace-archive-git-worktree-remove")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "feature-archive")

        let normalizedWorkspaceDir = normalizeTestPath(workspace.dir)
        let before = try runGitAndCapture(["worktree", "list", "--porcelain"], cwd: repo.path)
        XCTAssertTrue(parseWorktreePaths(before).contains(normalizedWorkspaceDir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.dir))

        _ = try orchestrator.archiveWorkspace(workspaceID: workspace.id)

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
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "feature-missing")
        try store.setWorkspaceStopScript(workspaceID: workspace.id, stopScript: "echo ran > '\(marker.path)'")

        try FileManager.default.removeItem(atPath: workspace.dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.dir))

        _ = try orchestrator.archiveWorkspace(workspaceID: workspace.id)

        let archivedWorkspace = try store.workspace(id: workspace.id)
        XCTAssertEqual(archivedWorkspace?.isArchived, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testArchiveWorkspaceCanDeleteLocalAndRemoteBranch() throws {
        let root = try makeTempDirectory()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try runGit(["init", "-b", "main"], cwd: source.path)
        try "hello".write(to: source.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], cwd: source.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "init"], cwd: source.path)
        try runGit(["checkout", "-b", "feature-cleanup"], cwd: source.path)
        try "cleanup".write(to: source.appendingPathComponent("CLEANUP.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "CLEANUP.md"], cwd: source.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "cleanup"], cwd: source.path)
        try runGit(["checkout", "main"], cwd: source.path)

        let remote = root.appendingPathComponent("remote.git", isDirectory: true)
        try runGit(["clone", "--bare", source.path, remote.path], cwd: root.path)

        let clone = root.appendingPathComponent("clone", isDirectory: true)
        try runGit(["clone", remote.path, clone.path], cwd: root.path)

        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let client = GitClient()

        let project = try orchestrator.addProject(dir: clone.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "feature-cleanup", allowExistingBranchReuse: true)
        XCTAssertTrue(client.branchExists(path: clone.path, branch: "feature-cleanup"))
        XCTAssertTrue(client.remoteBranchExists(path: clone.path, branch: "feature-cleanup"))

        let outcome = try orchestrator.archiveWorkspace(workspaceID: workspace.id, deleteLocalBranch: true, deleteRemoteBranch: true)

        XCTAssertFalse(client.branchExists(path: clone.path, branch: "feature-cleanup"))
        XCTAssertFalse(client.remoteBranchExists(path: clone.path, branch: "feature-cleanup"))
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isArchived, true)
        XCTAssertTrue(outcome.notice?.contains("Deleted remote branch 'feature-cleanup'.") == true)
        XCTAssertTrue(outcome.notice?.contains("Deleted local branch 'feature-cleanup'.") == true)
    }

    func testArchiveWorkspaceClearsArchivedBranchWhenDeletionRemovesBranchIdentity() throws {
        let repo = try makeTempGitRepo(name: "archive-clears-deleted-branch")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "feature")

        _ = try orchestrator.archiveWorkspace(workspaceID: workspace.id, deleteLocalBranch: true)

        let archived = try XCTUnwrap(store.workspace(id: workspace.id))
        XCTAssertTrue(archived.isArchived)
        XCTAssertNil(archived.branch)

        let recreated = try orchestrator.createWorkspace(projectID: project.id, branch: "feature")
        XCTAssertEqual(recreated.branch, "feature")
        XCTAssertNotEqual(recreated.id, workspace.id)
    }

    func testArchiveWorkspacePreservesBranchIdentityWhenRemoteLookupFails() throws {
        let fixture = try makeRemoteFixture()
        try runGit(["checkout", "-b", "remote-archive"], cwd: fixture.source.path)
        try "remote archive".write(to: fixture.source.appendingPathComponent("REMOTE_ARCHIVE.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "REMOTE_ARCHIVE.md"], cwd: fixture.source.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "remote archive"], cwd: fixture.source.path)
        try runGit(["push", fixture.remote.path, "remote-archive"], cwd: fixture.source.path)

        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let createOrchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try createOrchestrator.addProject(dir: fixture.clone.path)
        let workspace = try createOrchestrator.createWorkspace(projectID: project.id, branch: "remote-archive", allowExistingBranchReuse: true)

        let archiveOrchestrator = WorkspaceOrchestrator(
            store: store, workspacesRootDirectory: workspacesRoot, git: try makeLsRemoteFailingGitClient())
        let outcome = try archiveOrchestrator.archiveWorkspace(workspaceID: workspace.id, deleteLocalBranch: true, deleteRemoteBranch: true)

        let archived = try XCTUnwrap(store.workspace(id: workspace.id))
        XCTAssertTrue(archived.isArchived)
        XCTAssertEqual(archived.branch, "remote-archive")
        XCTAssertTrue(outcome.notice?.contains("Failed to delete remote branch 'remote-archive': Git command failed: remote lookup failed") == true)
    }

    /// Archiving with branch deletion keeps the archived record's branch when the archive could not confirm
    /// the branch is gone from the remote. The branch is still deleted, so the name has to stay usable for a
    /// new workspace instead of being reserved forever by that stale record.
    func testCreateWorkspaceReusesBranchNameArchivedRecordNoLongerOwns() throws {
        let fixture = try makeRemoteFixture()
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: fixture.clone.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "qa-reuse")
        try orchestrator.updateWorkspaceNotes(workspaceID: workspace.id, notes: "archived history")

        let archiveOrchestrator = WorkspaceOrchestrator(
            store: store, workspacesRootDirectory: workspacesRoot, git: try makeLsRemoteFailingGitClient())
        _ = try archiveOrchestrator.archiveWorkspace(workspaceID: workspace.id, deleteLocalBranch: true, deleteRemoteBranch: true)
        let archived = try XCTUnwrap(store.workspace(id: workspace.id))
        XCTAssertTrue(archived.isArchived)
        XCTAssertEqual(archived.branch, "qa-reuse")
        XCTAssertFalse(GitClient().branchExists(path: fixture.clone.path, branch: "qa-reuse"))

        let recreated = try orchestrator.createWorkspace(projectID: project.id, branch: "qa-reuse")

        XCTAssertEqual(recreated.branch, "qa-reuse")
        XCTAssertFalse(recreated.isArchived)
        XCTAssertNotEqual(recreated.id, workspace.id)
        let preserved = try XCTUnwrap(store.workspace(id: workspace.id))
        XCTAssertTrue(preserved.isArchived)
        XCTAssertNil(preserved.branch)
        XCTAssertEqual(preserved.notes, "archived history")
    }

    /// The same reservation has to be released when the branch disappears outside Spaces — the usual
    /// merge-and-delete flow after a workspace was archived without deleting its branch.
    func testCreateWorkspaceReusesBranchNameDeletedOutsideSpacesAfterArchive() throws {
        let fixture = try makeRemoteFixture()
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: fixture.clone.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "qa-merged")
        try runGit(["push", "-u", "origin", "qa-merged"], cwd: workspace.dir)

        _ = try orchestrator.archiveWorkspace(workspaceID: workspace.id)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.branch, "qa-merged")

        try runGit(["push", "origin", "--delete", "qa-merged"], cwd: fixture.clone.path)
        try runGit(["branch", "-D", "qa-merged"], cwd: fixture.clone.path)

        let recreated = try orchestrator.createWorkspace(projectID: project.id, branch: "qa-merged")

        XCTAssertEqual(recreated.branch, "qa-merged")
        XCTAssertNotEqual(recreated.id, workspace.id)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isArchived, true)
        XCTAssertNil(try store.workspace(id: workspace.id)?.branch)
    }

    /// Renaming a workspace's branch obeys the same rule as creating one: a branch name whose only claimant
    /// is an archived record that no longer owns it is free to take.
    func testUpdateWorkspaceMetadataRenamesBranchArchivedRecordNoLongerOwns() throws {
        let fixture = try makeRemoteFixture()
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: fixture.clone.path)
        let archivedWorkspace = try orchestrator.createWorkspace(projectID: project.id, branch: "qa-rename-target")
        try orchestrator.updateWorkspaceNotes(workspaceID: archivedWorkspace.id, notes: "archived history")
        _ = try orchestrator.archiveWorkspace(workspaceID: archivedWorkspace.id)
        XCTAssertEqual(try store.workspace(id: archivedWorkspace.id)?.branch, "qa-rename-target")
        try runGit(["branch", "-D", "qa-rename-target"], cwd: fixture.clone.path)

        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "qa-rename-source")
        try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, branch: "qa-rename-target")

        XCTAssertEqual(try store.workspace(id: workspace.id)?.branch, "qa-rename-target")
        let preserved = try XCTUnwrap(store.workspace(id: archivedWorkspace.id))
        XCTAssertTrue(preserved.isArchived)
        XCTAssertNil(preserved.branch)
        XCTAssertEqual(preserved.notes, "archived history")
    }

    /// The rename guard still holds while the archived record's branch exists, so a rename cannot quietly
    /// take a name another record can still be revived on.
    func testUpdateWorkspaceMetadataRejectsBranchStillOwnedByArchivedRecord() throws {
        let repo = try makeTempGitRepo(name: "rename-onto-archived-branch")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let archivedWorkspace = try orchestrator.createWorkspace(projectID: project.id, branch: "kept-rename-target")
        _ = try orchestrator.archiveWorkspace(workspaceID: archivedWorkspace.id)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "kept-rename-source")

        XCTAssertThrowsError(try orchestrator.updateWorkspaceMetadata(workspaceID: workspace.id, branch: "kept-rename-target")) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
            XCTAssertTrue(message.contains("Branch 'kept-rename-target' is already used by workspace"))
        }
        XCTAssertEqual(try store.workspace(id: archivedWorkspace.id)?.branch, "kept-rename-target")
        XCTAssertEqual(try store.workspace(id: workspace.id)?.branch, "kept-rename-source")
    }

    /// Importing a worktree can never meet a stale archived claim: the imported worktree has the branch
    /// checked out, so the name an archived record is holding is live again and that record stays a genuine
    /// conflict to resolve by unarchiving.
    func testCreateWorkspaceFromWorktreeRejectsArchivedBranchNameThatIsLiveAgain() throws {
        let fixture = try makeRemoteFixture()
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: fixture.clone.path)
        let archivedWorkspace = try orchestrator.createWorkspace(projectID: project.id, branch: "qa-import")
        _ = try orchestrator.archiveWorkspace(workspaceID: archivedWorkspace.id)
        try runGit(["branch", "-D", "qa-import"], cwd: fixture.clone.path)

        let importedWorktree = root.appendingPathComponent("imported-qa-import", isDirectory: true)
        try runGit(["worktree", "add", "-b", "qa-import", importedWorktree.path], cwd: fixture.clone.path)

        XCTAssertThrowsError(try orchestrator.createWorkspaceFromWorktree(worktreePath: importedWorktree.path)) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
            XCTAssertTrue(message.contains("Workspace already exists for archived branch 'qa-import'"))
        }
        XCTAssertEqual(try store.workspace(id: archivedWorkspace.id)?.branch, "qa-import")
    }

    /// An archived record whose branch still exists keeps owning that name: creating it as a new branch is
    /// refused, and reusing the existing branch revives the archived record rather than adding a second one.
    func testCreateWorkspaceKeepsArchivedRecordOwningBranchThatStillExists() throws {
        let repo = try makeTempGitRepo(name: "archived-branch-still-exists")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let workspace = try orchestrator.createWorkspace(projectID: project.id, branch: "kept-branch")
        _ = try orchestrator.archiveWorkspace(workspaceID: workspace.id)

        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id, branch: "kept-branch")) { error in
            guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
            XCTAssertTrue(message.contains("Branch 'kept-branch' already exists"))
        }
        XCTAssertEqual(try store.workspace(id: workspace.id)?.branch, "kept-branch")

        let revived = try orchestrator.createWorkspace(projectID: project.id, branch: "kept-branch", allowExistingBranchReuse: true)
        XCTAssertEqual(revived.id, workspace.id)
        XCTAssertFalse(revived.isArchived)
    }

    // Tests built-in terminal runtime sync revives an exited managed process when the tracked pane is still alive by arranging representative inputs and asserting the expected result.

    // Tests create workspace throws for unknown project by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceThrowsForUnknownProject() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: "missing"))
    }

    // Tests create workspace for git project requires branch by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceForGitProjectRequiresBranch() throws {
        let repo = try makeTempGitRepo(name: "workspace-requires-branch")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)

        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Branch name is required"))
        }
    }

    func testDiscardPreparedGitProjectRemovesManagedCloneAndDefaultWorktree() throws {
        let fixture = try makeTempGitRepo(name: "discard-prepared-git-import")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let prepared = try orchestrator.prepareGitProject(gitURL: fixture.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.project.dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.defaultWorkspace.dir))

        try orchestrator.discardPreparedGitProject(prepared)

        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.project.dir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.defaultWorkspace.dir))
        XCTAssertTrue(try store.projects().isEmpty)
    }

    // Tests create workspace allows duplicate active titles by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceAllowsDuplicateActiveWorkspaceTitles() throws {
        let (orchestrator, _, project, _, _) = try makeOrchestratorWithWorkspace()
        XCTAssertNoThrow(try orchestrator.createWorkspace(projectID: project.id))
    }

    // Tests create workspace from worktree infers project and branch by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceFromWorktreeInfersProjectAndBranch() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: repo.path)
        let root = repo.deletingLastPathComponent()
        let worktree = root.appendingPathComponent("feature-branch", isDirectory: true)
        let client = GitClient()
        try client.createWorktree(path: repo.path, worktreePath: worktree.path, branch: "feature-branch")
        let workspace = try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree.path)
        XCTAssertEqual(workspace.projectID, project.id)
        XCTAssertEqual(workspace.displayName, "feature-branch")
        XCTAssertEqual(workspace.branch, "feature-branch")
        XCTAssertEqual(workspace.dir, worktree.path)
        XCTAssertEqual(workspace.dirname, "feature-branch")
        XCTAssertFalse(workspace.isArchived)
        let stored = try store.workspace(id: workspace.id)
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.displayName, "feature-branch")
    }

    // Tests create workspace from worktree fails if project not registered by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceFromWorktreeFailsIfProjectNotRegistered() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()
        let worktree = root.appendingPathComponent("feature", isDirectory: true)
        let client = GitClient()
        try client.createWorktree(path: repo.path, worktreePath: worktree.path, branch: "feature")
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        XCTAssertThrowsError(try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree.path)) { error in
            let nsError = error as NSError
            XCTAssertTrue(nsError.localizedDescription.contains("Project not found"))
            XCTAssertTrue(nsError.localizedDescription.contains("Add the project in the app"))
        }
    }

    // Tests create workspace from worktree fails if already exists by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceFromWorktreeFailsIfAlreadyExists() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        _ = try orchestrator.addProject(dir: repo.path)
        let worktree = root.appendingPathComponent("feature", isDirectory: true)
        let client = GitClient()
        try client.createWorktree(path: repo.path, worktreePath: worktree.path, branch: "feature")
        _ = try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree.path)
        XCTAssertThrowsError(try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree.path)) { error in
            let nsError = error as NSError
            XCTAssertTrue(nsError.localizedDescription.contains("already exists"))
        }
    }

    // Tests scan and create workspaces from worktrees finds all worktrees by arranging representative inputs and asserting the expected result.
    func testScanAndCreateWorkspacesFromWorktreesFindsAllWorktrees() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: repo.path)
        let client = GitClient()
        let worktree1 = root.appendingPathComponent("feature-1", isDirectory: true)
        let worktree2 = root.appendingPathComponent("feature-2", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: worktree1.path, branch: "feature-1")
        try client.createWorktree(path: repo.path, worktreePath: worktree2.path, branch: "feature-2")
        let created = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: project.id)
        XCTAssertEqual(created.count, 2)
        let names = Set(created.map(\.displayName))
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
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: repo.path)
        let client = GitClient()
        let worktree1 = root.appendingPathComponent("feature-1", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: worktree1.path, branch: "feature-1")
        _ = try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree1.path)
        let worktree2 = root.appendingPathComponent("feature-2", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: worktree2.path, branch: "feature-2")
        let created = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: project.id)
        XCTAssertEqual(created.count, 1)
        let names = Set(created.map(\.displayName))
        XCTAssertTrue(names.contains("feature-2"))
        XCTAssertFalse(names.contains("feature-1"))
        XCTAssertFalse(names.contains("main"))
    }

    // Tests scan and create workspaces from worktrees runs setup script for created workspace by arranging representative inputs and asserting the expected result.
    func testScanAndCreateWorkspacesFromWorktreesRunsSetupScriptForCreatedWorkspace() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()

        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: repo.path)

        try orchestrator.updateProjectConfig(projectID: project.id) { config in
            config.setupScript = "echo discovered > .spaces-discovery-setup-marker"
        }

        let client = GitClient()
        let worktree = root.appendingPathComponent("feature-setup", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: worktree.path, branch: "feature-setup")

        let created = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: project.id)
        XCTAssertEqual(created.count, 1)

        let markerFile = worktree.appendingPathComponent(".spaces-discovery-setup-marker")
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerFile.path))
        let marker = try String(contentsOf: markerFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(marker, "discovered")
    }

    // Tests scan and create workspaces from worktrees skips deleted workspace paths marked ignored by arranging representative inputs and asserting the expected result.
    func testScanAndCreateWorkspacesFromWorktreesSkipsDeletedWorkspacePathsMarkedIgnored() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()

        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
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
        let orchestrator = makeTestOrchestrator(store: store)
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
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: repo.path)

        let client = GitClient()
        let removedWorktree = root.appendingPathComponent("feature-removed", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: removedWorktree.path, branch: "feature-removed")
        let workspace = try orchestrator.createWorkspaceFromWorktree(worktreePath: removedWorktree.path)

        try client.removeWorktree(path: repo.path, worktreePath: removedWorktree.path)

        let created = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: project.id)
        XCTAssertTrue(created.isEmpty)

        let archivedWorkspace = try store.workspace(id: workspace.id)
        XCTAssertEqual(archivedWorkspace?.isArchived, true)
    }

    // A daemon-side orchestrator built without an explicit handoff predicate — exactly how
    // `WorktreeDiscoveryService.scan` constructs one — must honor the process-wide
    // `daemonHandoffInProgress` override and refuse the removed-worktree archive during an exec-in-place
    // handoff. This guards the bug where every non-profile daemon orchestrator (discovery scans,
    // reconcilers, Device API handlers) got the `{ false }` default, letting the scan delete a still-live
    // session's workspace rows mid-handoff. The negative half asserts the pre-existing archive behavior is
    // untouched once the override is cleared.
    func testScanHonorsProcessWideDaemonHandoffOverrideAndRefusesArchive() throws {
        let repo = try makeTempGitRepo(name: "handoff-scan-repo")
        let root = repo.deletingLastPathComponent()

        let store = try makeTemporaryStore()
        // Fixture is built with the override unset, so setup calls behave normally.
        let setupOrchestrator = makeTestOrchestrator(store: store)
        let project = try setupOrchestrator.addProject(dir: repo.path)

        let client = GitClient()
        let removedWorktree = root.appendingPathComponent("feature-removed", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: removedWorktree.path, branch: "feature-removed")
        let workspace = try setupOrchestrator.createWorkspaceFromWorktree(worktreePath: removedWorktree.path)
        try client.removeWorktree(path: repo.path, worktreePath: removedWorktree.path)

        // Rows `stopWorkspaceUnlocked` would delete if it archived the now-invalid workspace.
        try store.upsert(
            runningProcess: RunningProcessRecord(
                id: "handoff-process", workspaceID: workspace.id, templateName: "web", command: "npm run dev",
                terminalApp: TerminalHost.spaces.appName, terminalTrackingID: "handoff-session", pid: nil, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: "2026-07-01T00:00:00Z", exitedAt: nil))
        try store.upsert(
            window: WindowRecord(
                id: "handoff-window", workspaceID: workspace.id, app: TerminalHost.spaces.appName, name: "Shell",
                terminalTrackingID: "handoff-session", role: .terminal, orderIndex: 100, lastSeenAt: "2026-07-01T00:00:00Z"))

        // Positive: install the process-wide override BEFORE constructing the scan orchestrator — the daemon
        // installs the hook at startup and builds a fresh orchestrator per scan (WorktreeDiscoveryService.scan),
        // and the init resolves the predicate at construction. A scan orchestrator built without an explicit
        // predicate must therefore pick up the override and abort at `stopWorkspaceUnlocked`'s entry guard:
        // nothing archived, no rows deleted, no session terminated, `daemonHandoffInProgress` surfaced. The
        // terminator is injected only to keep the negative archive path off the real TerminalService; it does
        // not affect which handoff predicate the init resolves.
        WorkspaceOrchestrator.setProcessWideDaemonHandoffInProgress { true }
        defer { WorkspaceOrchestrator.setProcessWideDaemonHandoffInProgress(nil) }
        let terminated = TerminalTerminateCapture()
        let handoffScanOrchestrator = makeTestOrchestrator(store: store, builtInTerminalSessionTerminator: { terminated.sessionIDs.append($0) })

        XCTAssertThrowsError(try handoffScanOrchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: project.id)) { error in
            guard case WorkspaceError.daemonHandoffInProgress = error else { return XCTFail("Expected daemonHandoffInProgress, got \(error)") }
        }
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isArchived, false)
        XCTAssertEqual(try store.runningProcesses(workspaceID: workspace.id).count, 1)
        XCTAssertEqual(try store.windows(workspaceID: workspace.id).count, 1)
        XCTAssertTrue(terminated.sessionIDs.isEmpty)

        // Negative: clear the override, then build a fresh scan orchestrator (again mirroring the per-scan
        // construction) so it resolves the `{ false }` default. The same scan now archives the workspace and
        // deletes its rows — the behavior this fix must leave intact when no handoff is active.
        WorkspaceOrchestrator.setProcessWideDaemonHandoffInProgress(nil)
        let normalScanOrchestrator = makeTestOrchestrator(store: store, builtInTerminalSessionTerminator: { terminated.sessionIDs.append($0) })
        let created = try normalScanOrchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: project.id)
        XCTAssertTrue(created.isEmpty)
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isArchived, true)
        XCTAssertTrue(try store.runningProcesses(workspaceID: workspace.id).isEmpty)
        XCTAssertTrue(try store.windows(workspaceID: workspace.id).isEmpty)
    }

    // Tests scan and create workspaces from worktrees refreshes stored branch names by arranging representative inputs and asserting the expected result.
    func testScanAndCreateWorkspacesFromWorktreesRefreshesBranchNamesFromDisk() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()

        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: repo.path)

        let client = GitClient()
        let worktree = root.appendingPathComponent("feature-renamed", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: worktree.path, branch: "feature-renamed")
        let workspace = try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree.path)

        _ = try client.runGitAndCapture(["-C", worktree.path, "branch", "-m", "feature-renamed-on-disk"])
        _ = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: project.id)

        let refreshedWorkspace = try store.workspace(id: workspace.id)
        XCTAssertEqual(refreshedWorkspace?.branch, "feature-renamed-on-disk")
    }

    /// A workspace created after an archive reuses the archived record's recycled directory, so a scan finds a
    /// worktree standing at the archived record's recorded path. That worktree belongs to the live workspace;
    /// the archived record must not adopt its branch and start competing for the same name.
    func testScanAndCreateWorkspacesFromWorktreesDoesNotAdoptBranchIntoArchivedRecord() throws {
        let repo = try makeTempGitRepo(name: "scan-archived-branch-adoption")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let archivedWorkspace = try orchestrator.createWorkspace(projectID: project.id, branch: "recycled-dir")
        _ = try orchestrator.archiveWorkspace(workspaceID: archivedWorkspace.id, deleteLocalBranch: true)
        let recreated = try orchestrator.createWorkspace(projectID: project.id, branch: "recycled-dir")
        XCTAssertEqual(recreated.dir, archivedWorkspace.dir, "The archived record's directory name should be recycled by the new workspace.")

        _ = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: project.id)

        XCTAssertNil(try store.workspace(id: archivedWorkspace.id)?.branch)
        XCTAssertEqual(try store.workspace(id: recreated.id)?.branch, "recycled-dir")
    }

    // Tests scan and create workspaces from worktrees scans all projects when no project id provided by arranging representative inputs and asserting the expected result.
    func testScanAndCreateWorkspacesFromWorktreesScansAllProjectsWhenNoProjectIDProvided() throws {
        let repo1 = try makeTempGitRepo(name: "repo1")
        let repo2 = try makeTempGitRepo(name: "repo2")
        let root = repo1.deletingLastPathComponent()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
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

    // Tests createWorkspace seeds per-workspace process IDs so multiple workspaces can inherit the same project template without collisions.
    func testCreateWorkspaceSeedsUniqueProcessIDsPerWorkspace() throws {
        let repo = try makeTempGitRepo(name: "unique-process-ids")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path) { config in
            config.processes = [.init(name: "frontend", command: "npm run dev"), .init(name: "backend", command: "npm run api")]
        }

        let defaultWorkspace = try XCTUnwrap(try store.workspaces(projectID: project.id).first(where: \.isDefault))
        let defaultSettings = try XCTUnwrap(orchestrator.workspaceSettings(workspaceID: defaultWorkspace.id))

        let createdWorkspace = try orchestrator.createWorkspace(projectID: project.id, branch: "feature")
        let createdSettings = try XCTUnwrap(orchestrator.workspaceSettings(workspaceID: createdWorkspace.id))

        XCTAssertEqual(defaultSettings.processes.map(\.name), createdSettings.processes.map(\.name))
        XCTAssertEqual(defaultSettings.processes.map(\.command), createdSettings.processes.map(\.command))
        XCTAssertTrue(Set(defaultSettings.processes.map(\.id)).isDisjoint(with: createdSettings.processes.map(\.id)))
    }

    func testCreateWorkspaceReplacesConfirmedOrphanedManagedWorkspaceDirectory() throws {
        let fixture = try makeTempGitRepo(name: "replace-workspace")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(gitURL: fixture.path)
        let defaultWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first(where: \.isDefault))
        let workspaceRoot = URL(fileURLWithPath: defaultWorkspace.dir, isDirectory: true).deletingLastPathComponent()
        let orphanDir = workspaceRoot.appendingPathComponent("feature", isDirectory: true)
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        let orphanMarker = orphanDir.appendingPathComponent("orphan.txt")
        try "orphan".write(to: orphanMarker, atomically: true, encoding: .utf8)

        let candidate = try XCTUnwrap(try orchestrator.managedWorkspaceReplacementCandidate(projectID: project.id, directoryName: "feature"))
        XCTAssertEqual(candidate.path, orphanDir.path)

        let workspace = try orchestrator.createWorkspace(
            projectID: project.id, branch: "feature", baseBranch: "main", directoryName: "feature", runSetupScript: false,
            replaceExistingManagedDirectory: true)

        XCTAssertEqual(workspace.dir, orphanDir.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanMarker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(workspace.dir)/README.md"))
    }

    func testCreateWorkspaceReplacementClearsOrphanedGitWorktreeRegistration() throws {
        let fixture = try makeTempGitRepo(name: "replace-stale-worktree")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(gitURL: fixture.path)
        let defaultWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first(where: \.isDefault))
        let workspaceRoot = URL(fileURLWithPath: defaultWorkspace.dir, isDirectory: true).deletingLastPathComponent()
        let orphanDir = workspaceRoot.appendingPathComponent("stale-feature", isDirectory: true)
        try runGit(["worktree", "add", "-b", "stale-feature", orphanDir.path, "main"], cwd: project.dir)
        let orphanMarker = orphanDir.appendingPathComponent("orphan.txt")
        try "orphan".write(to: orphanMarker, atomically: true, encoding: .utf8)
        let listedOrphanDir = normalizeTestPath(orphanDir.path)
        let beforeWorktrees = try runGitAndCapture(["worktree", "list", "--porcelain"], cwd: project.dir)
        XCTAssertTrue(parseWorktreePaths(beforeWorktrees).contains(listedOrphanDir), beforeWorktrees)

        let candidate = try XCTUnwrap(try orchestrator.managedWorkspaceReplacementCandidate(projectID: project.id, directoryName: "stale-feature"))
        XCTAssertEqual(candidate.path, orphanDir.path)
        let workspace = try orchestrator.createWorkspace(
            projectID: project.id, branch: "stale-feature", baseBranch: "main", directoryName: "stale-feature", runSetupScript: false,
            allowExistingBranchReuse: true, replaceExistingManagedDirectory: true)

        XCTAssertEqual(workspace.dir, orphanDir.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanMarker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(workspace.dir)/README.md"))
        let afterWorktrees = try runGitAndCapture(["worktree", "list", "--porcelain"], cwd: project.dir)
        XCTAssertEqual(parseWorktreePaths(afterWorktrees).filter { $0 == listedOrphanDir }.count, 1, afterWorktrees)
    }

    func testCreateWorkspaceReplacementPrunesCorruptOrphanedGitWorktreeRegistration() throws {
        let fixture = try makeTempGitRepo(name: "replace-corrupt-stale-worktree")
        let root = try makeTempDirectory()
        let reposRoot = root.appendingPathComponent("repos", isDirectory: true)
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, projectsRootDirectory: reposRoot, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(gitURL: fixture.path)
        let defaultWorkspace = try XCTUnwrap(try orchestrator.listWorkspaces(projectID: project.id).first(where: \.isDefault))
        let workspaceRoot = URL(fileURLWithPath: defaultWorkspace.dir, isDirectory: true).deletingLastPathComponent()
        let orphanDir = workspaceRoot.appendingPathComponent("corrupt-feature", isDirectory: true)
        try runGit(["worktree", "add", "-b", "corrupt-feature", orphanDir.path, "main"], cwd: project.dir)
        let orphanMarker = orphanDir.appendingPathComponent("orphan.txt")
        try "orphan".write(to: orphanMarker, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: orphanDir.appendingPathComponent(".git"))
        let listedOrphanDir = normalizeTestPath(orphanDir.path)
        let beforeWorktrees = try runGitAndCapture(["worktree", "list", "--porcelain"], cwd: project.dir)
        XCTAssertTrue(parseWorktreePaths(beforeWorktrees).contains(listedOrphanDir), beforeWorktrees)

        let workspace = try orchestrator.createWorkspace(
            projectID: project.id, branch: "corrupt-feature", baseBranch: "main", directoryName: "corrupt-feature", runSetupScript: false,
            allowExistingBranchReuse: true, replaceExistingManagedDirectory: true)

        XCTAssertEqual(workspace.dir, orphanDir.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanMarker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(workspace.dir)/README.md"))
        let afterWorktrees = try runGitAndCapture(["worktree", "list", "--porcelain"], cwd: project.dir)
        XCTAssertEqual(parseWorktreePaths(afterWorktrees).filter { $0 == listedOrphanDir }.count, 1, afterWorktrees)
    }

    // Tests createWorkspace revives an archived git workspace by branch and applies the requested title.
    func testCreateWorkspaceRevivesArchivedGitWorkspaceByBranch() throws {
        let repo = try makeTempGitRepo(name: "revive-git-workspace")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let original = try orchestrator.createWorkspace(projectID: project.id, branch: "feature-branch")
        _ = try orchestrator.archiveWorkspace(workspaceID: original.id)
        let archived = try XCTUnwrap(store.workspace(id: original.id))
        XCTAssertTrue(archived.isArchived)

        let revived = try orchestrator.createWorkspace(projectID: project.id, branch: "feature-branch", allowExistingBranchReuse: true)
        let persisted = try XCTUnwrap(store.workspace(id: revived.id))
        XCTAssertEqual(revived.id, original.id)
        XCTAssertFalse(persisted.isArchived)
        XCTAssertEqual(persisted.displayName, "feature-branch")
        XCTAssertEqual(persisted.branch, "feature-branch")
    }

    func testCreateWorkspaceAllowsReusingArchivedGitDirname() throws {
        let repo = try makeTempGitRepo(name: "reuse-archived-git-dirname")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let original = try orchestrator.createWorkspace(projectID: project.id, branch: "docs-old", directoryName: "docs")
        _ = try orchestrator.archiveWorkspace(workspaceID: original.id)

        let replacement = try orchestrator.createWorkspace(projectID: project.id, branch: "docs-new", directoryName: "docs")
        XCTAssertEqual(replacement.dirname, "docs")
        XCTAssertEqual(replacement.branch, "docs-new")
    }

    func testCreateWorkspaceRevivesArchivedGitWorkspaceWithFreshDirnameWhenOldDirnameIsTaken() throws {
        let repo = try makeTempGitRepo(name: "revive-git-fresh-dirname")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let archived = try orchestrator.createWorkspace(projectID: project.id, branch: "docs-old", directoryName: "docs")
        _ = try orchestrator.archiveWorkspace(workspaceID: archived.id)
        let replacement = try orchestrator.createWorkspace(projectID: project.id, branch: "docs-new", directoryName: "docs")

        let revived = try orchestrator.createWorkspace(projectID: project.id, branch: "docs-old", allowExistingBranchReuse: true)
        XCTAssertEqual(revived.id, archived.id)
        XCTAssertNotEqual(revived.dirname, "docs")
        XCTAssertNotEqual(revived.dirname, replacement.dirname)
    }

    func testCreateWorkspaceRevivesArchivedGitWorkspaceReplacingConfirmedOrphanedDirectory() throws {
        let repo = try makeTempGitRepo(name: "revive-replace-orphan-dir")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        let archived = try orchestrator.createWorkspace(projectID: project.id, branch: "feature-revive-replace", directoryName: "old-feature-dir")
        _ = try orchestrator.archiveWorkspace(workspaceID: archived.id)
        let workspaceRoot = URL(fileURLWithPath: archived.dir, isDirectory: true).deletingLastPathComponent()
        let orphanDir = workspaceRoot.appendingPathComponent("revived-feature-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        let orphanMarker = orphanDir.appendingPathComponent("orphan.txt")
        try "orphan".write(to: orphanMarker, atomically: true, encoding: .utf8)
        let candidate = try XCTUnwrap(
            try orchestrator.managedWorkspaceReplacementCandidate(projectID: project.id, directoryName: "revived-feature-dir"))
        XCTAssertEqual(candidate.path, orphanDir.path)

        let revived = try orchestrator.createWorkspace(
            projectID: project.id, branch: "feature-revive-replace", directoryName: "revived-feature-dir", allowExistingBranchReuse: true,
            replaceExistingManagedDirectory: true)

        XCTAssertEqual(revived.id, archived.id)
        XCTAssertEqual(revived.dir, orphanDir.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanMarker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(revived.dir)/README.md"))
    }

    func testCreateWorkspaceRejectsExistingBranchInCreateMode() throws {
        let repo = try makeTempGitRepo(name: "reject-existing-branch")
        try runGit(["checkout", "-b", "existing-branch"], cwd: repo.path)
        try runGit(["checkout", "main"], cwd: repo.path)
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id, branch: "existing-branch", allowExistingBranchReuse: false)) {
            error in
            guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
            XCTAssertTrue(message.contains("Branch 'existing-branch' already exists"))
        }
    }

    func testCreateWorkspaceRejectsMissingBranchInExistingMode() throws {
        let repo = try makeTempGitRepo(name: "reject-missing-existing-branch")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id, branch: "missing-branch", allowExistingBranchReuse: true)) {
            error in
            guard case WorkspaceError.invalidArgument(let message) = error else { return XCTFail("Expected invalidArgument, got \(error)") }
            XCTAssertTrue(message.contains("Branch 'missing-branch' was not found"))
        }
    }

    func testCreateWorkspaceRemoteLookupFailureDoesNotDecideBranchMode() throws {
        let fixture = try makeRemoteFixture()
        try runGit(["checkout", "-b", "remote-only"], cwd: fixture.source.path)
        try "remote only".write(to: fixture.source.appendingPathComponent("REMOTE_ONLY.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "REMOTE_ONLY.md"], cwd: fixture.source.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "remote only"], cwd: fixture.source.path)
        try runGit(["push", fixture.remote.path, "remote-only"], cwd: fixture.source.path)

        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot, git: try makeLsRemoteFailingGitClient())

        let project = try orchestrator.addProject(dir: fixture.clone.path)
        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id, branch: "remote-only", allowExistingBranchReuse: false)) {
            error in
            guard case WorkspaceError.gitCommandFailed(let message) = error else { return XCTFail("Expected gitCommandFailed, got \(error)") }
            XCTAssertTrue(message.contains("remote lookup failed"))
        }
        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id, branch: "remote-only", allowExistingBranchReuse: true)) {
            error in
            guard case WorkspaceError.gitCommandFailed(let message) = error else { return XCTFail("Expected gitCommandFailed, got \(error)") }
            XCTAssertTrue(message.contains("remote lookup failed"))
        }
    }

    func testCreateWorkspaceSkipsRemoteBranchLookupWhenDisabled() throws {
        let fixture = try makeRemoteFixture()
        try runGit(["checkout", "-b", "remote-only"], cwd: fixture.source.path)
        try "remote only".write(to: fixture.source.appendingPathComponent("REMOTE_ONLY_SKIP.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "REMOTE_ONLY_SKIP.md"], cwd: fixture.source.path)
        try runGit(
            ["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "remote only skip"], cwd: fixture.source.path)
        try runGit(["push", fixture.remote.path, "remote-only"], cwd: fixture.source.path)

        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = WorkspaceOrchestrator(store: store, workspacesRootDirectory: workspacesRoot, git: try makeLsRemoteFailingGitClient())

        let project = try orchestrator.addProject(dir: fixture.clone.path)
        let created = try orchestrator.createWorkspace(
            projectID: project.id, branch: "remote-only", allowRemoteBranchLookup: false, allowExistingBranchReuse: false)

        XCTAssertEqual(created.branch, "remote-only")
    }

    // Tests createWorkspaceFromWorktree throws when the path does not exist by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceFromWorktreeThrowsWhenPathMissing() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        XCTAssertThrowsError(try orchestrator.createWorkspaceFromWorktree(worktreePath: "/nonexistent/path/\(UUID().uuidString)")) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests createWorkspaceFromWorktree throws when the path is not a git repository by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceFromWorktreeThrowsWhenNotGitRepo() throws {
        let dir = try makeTempDirectory()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        XCTAssertThrowsError(try orchestrator.createWorkspaceFromWorktree(worktreePath: dir.path)) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests createWorkspace throws when base branch cannot be resolved for a git project with no main/master by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceThrowsWhenBaseBranchCannotBeResolved() throws {
        // Create a git repo with a non-standard initial branch (not main or master)
        let repo = try makeTempGitRepo(name: "no-main-or-master", initialBranch: "develop")
        let store = try makeTemporaryStore()
        // Insert the project directly with defaultBranch = nil to force the main/master branch check
        let projectRecord = ProjectRecord(id: repo.path, name: "test", dir: repo.path, isGitRepo: true, defaultBranch: nil)
        try store.upsert(project: projectRecord)

        let orchestrator = makeTestOrchestrator(store: store)
        // Without baseBranch, resolveWorkspaceBaseBranch should check for main/master, find neither, and throw
        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: projectRecord.id, branch: "feature-branch")) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests handleProcessExit with onExit .restart restarts the process via openWindowAndRun by arranging representative inputs and asserting the expected result.
    // Tests createWorkspaceFromWorktree throws when the worktree directory matches an archived workspace by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceFromWorktreeThrowsWhenAlreadyArchivedWorkspaceExists() throws {
        let repo = try makeTempGitRepo(name: "archived-worktree-repo")
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        let project = try orchestrator.addProject(dir: repo.path)

        // The default workspace has dir=repo.path; archive it so the next createWorkspaceFromWorktree finds it archived.
        let workspaces = try store.workspaces(projectID: project.id, includeArchived: false)
        let defaultWS = try XCTUnwrap(workspaces.first(where: \.isDefault))
        let archived = WorkspaceRecord(
            id: defaultWS.id, projectID: project.id, dir: defaultWS.dir, dirname: defaultWS.dirname, branch: defaultWS.branch, isDefault: true,
            isArchived: true, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: archived)

        // createWorkspaceFromWorktree should detect the archived workspace and throw.
        XCTAssertThrowsError(try orchestrator.createWorkspaceFromWorktree(worktreePath: repo.path)) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests createWorkspace rejects a non-ASCII directory name by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceRejectsNonAsciiDirectoryName() throws {
        let repo = try makeTempGitRepo(name: "non-ascii-dirname-repo")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)

        // Pass a non-ASCII directory name (é is non-ASCII) to trigger the guard scalar.isASCII path.
        XCTAssertThrowsError(try orchestrator.createWorkspace(projectID: project.id, branch: "feature-branch", directoryName: "f\u{00e9}ature")) {
            error in guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests archiveWorkspace suppresses isMissingWorktreeError when the worktree directory is not registered in git by arranging representative inputs and asserting the expected result.
    func testArchiveWorkspaceSuppressesIsMissingWorktreeErrorForUnregisteredPath() throws {
        let repo = try makeTempGitRepo(name: "archive-git-missing-worktree-path")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        let project = try orchestrator.addProject(dir: repo.path)

        // Create a workspace record pointing to a path that is NOT a registered git worktree.
        // When archiveWorkspace calls git.removeWorktree, git fails with "not a working tree"
        // → isMissingWorktreeError returns true → error is suppressed.
        let fakeWorktreeDir = root.appendingPathComponent("not-a-registered-worktree").path
        let workspaceRecord = WorkspaceRecord(
            id: UUID().uuidString, projectID: project.id, dir: fakeWorktreeDir, dirname: "fake", branch: "feature-x", isDefault: false,
            isArchived: false, isRunning: false, lastLaunchedAt: nil)
        try store.upsert(workspace: workspaceRecord)

        XCTAssertNoThrow(try orchestrator.archiveWorkspace(workspaceID: workspaceRecord.id))

        let archived = try store.workspace(id: workspaceRecord.id)
        XCTAssertEqual(archived?.isArchived, true)
    }

    // Tests scanAndCreateWorkspacesFromWorktrees throws missingProject when a specific projectID is not found.
    func testScanAndCreateWorkspacesFromWorktreesThrowsForMissingProjectID() throws {
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        XCTAssertThrowsError(try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: "/nonexistent/project/\(UUID().uuidString)")) { error in
            guard case WorkspaceError.missingProject = error else { return XCTFail("Expected missingProject, got \(error)") }
        }
    }

    // Tests createWorkspace throws when the requested directoryName is already in use by another workspace (covers makeWorkspaceDirname line 2503).
    func testCreateWorkspaceDirnameConflictThrows() throws {
        let repo = try makeTempGitRepo(name: "dirname-conflict-repo")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)

        let project = try orchestrator.addProject(dir: repo.path)
        _ = try orchestrator.createWorkspace(projectID: project.id, branch: "feature-a", directoryName: "apple", runSetupScript: false)
        XCTAssertThrowsError(
            try orchestrator.createWorkspace(projectID: project.id, branch: "feature-b", directoryName: "apple", runSetupScript: false)
        ) { error in XCTAssertTrue(error.localizedDescription.contains("already in use"), "Expected 'already in use' error, got: \(error)") }
    }

    // Tests archive workspace does not delete project directory for non git project by arranging representative inputs and asserting the expected result.
    func testNonGitProjectWorkspaceCannotBeArchivedAndProjectDirectoryIsPreserved() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let marker = projectDir.appendingPathComponent("marker.txt")
        try "marker".write(to: marker, atomically: true, encoding: .utf8)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        // A non-git project owns exactly one workspace, the default, which cannot be archived;
        // this keeps the shared project directory from ever being torn down.
        let workspace = try XCTUnwrap(orchestrator.listWorkspaces(projectID: project.id).first)
        XCTAssertTrue(workspace.isDefault)
        XCTAssertThrowsError(try orchestrator.archiveWorkspace(workspaceID: workspace.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Default workspace cannot be archived"))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: project.dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try store.workspace(id: workspace.id)?.isArchived, false)
    }

    // Tests create workspace from worktree derives its display name from the branch by arranging representative inputs and asserting the expected result.
    func testCreateWorkspaceFromWorktreeUsesBranchAsDisplayName() throws {
        let repo = try makeTempGitRepo(name: "test-repo")
        let root = repo.deletingLastPathComponent()
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)
        _ = try orchestrator.addProject(dir: repo.path)
        let worktree = root.appendingPathComponent("fix-bug", isDirectory: true)
        let client = GitClient()
        try client.createWorktree(path: repo.path, worktreePath: worktree.path, branch: "fix/bug-123")
        let workspace = try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree.path)
        XCTAssertEqual(workspace.displayName, "fix/bug-123")
        XCTAssertEqual(workspace.branch, "fix/bug-123")
    }

    // Tests createWorkspaceFromWorktree registers workspaces for distinct branches.
    func testCreateWorkspaceFromWorktreeRegistersDistinctBranches() throws {
        let repo = try makeTempGitRepo(name: "workspace-duplicate-name")
        let root = try makeTempDirectory()
        let workspacesRoot = root.appendingPathComponent("workspaces", isDirectory: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store, workspacesRootDirectory: workspacesRoot)
        _ = try orchestrator.addProject(dir: repo.path)

        let worktree1 = root.appendingPathComponent("worktree1", isDirectory: true)
        try runGit(["worktree", "add", "-b", "feature-branch-1", worktree1.path], cwd: repo.path)
        _ = try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree1.path)

        let worktree2 = root.appendingPathComponent("worktree2", isDirectory: true)
        try runGit(["worktree", "add", "-b", "feature-branch-2", worktree2.path], cwd: repo.path)
        let second = try orchestrator.createWorkspaceFromWorktree(worktreePath: worktree2.path)

        // The display name of a git workspace is its branch.
        XCTAssertEqual(second.displayName, "feature-branch-2")
        XCTAssertEqual(second.branch, "feature-branch-2")
    }

    // Tests creating a workspace in a non-git project returns the existing single workspace instead of inserting a duplicate.
    func testCreateWorkspaceForNonGitProjectReturnsExistingWorkspace() throws {
        let root = try makeTempDirectory()
        let projectDir = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let store = try makeTemporaryStore()
        let orchestrator = makeTestOrchestrator(store: store)

        let project = try orchestrator.addProject(dir: projectDir.path)
        let existing = try XCTUnwrap(orchestrator.listWorkspaces(projectID: project.id).first)

        // A non-git project owns exactly one workspace; a second create returns it, not a duplicate.
        let created = try orchestrator.createWorkspace(projectID: project.id)
        XCTAssertEqual(created.id, existing.id)
        XCTAssertEqual(try orchestrator.listWorkspaces(projectID: project.id, includeArchived: true).count, 1)
    }
}
