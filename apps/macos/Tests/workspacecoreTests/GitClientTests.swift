import Foundation
import XCTest

@testable import workspacecore

final class GitClientTests: XCTestCase {
    // Tests is repo detects repository and non repository by arranging representative inputs and asserting the expected result.
    func testIsRepoDetectsRepositoryAndNonRepository() throws {
        let repo = try makeTempDirectory()
        try initializeGitRepository(at: repo, initialBranch: "main")
        let nonRepo = try makeTempDirectory()

        let client = GitClient()
        XCTAssertTrue(client.isRepo(path: repo.path))
        XCTAssertFalse(client.isRepo(path: nonRepo.path))
    }

    // Tests default branch uses remote head then fallbacks by arranging representative inputs and asserting the expected result.
    func testDefaultBranchUsesRemoteHeadThenFallbacks() throws {
        let fixture = try makeRemoteFixture()
        let client = GitClient()

        XCTAssertEqual(client.defaultBranch(path: fixture.clone.path), "main")

        let masterRepo = try makeTempDirectory()
        try initializeGitRepository(at: masterRepo, initialBranch: "master")
        XCTAssertEqual(client.defaultBranch(path: masterRepo.path), "master")

        let nonRepo = try makeTempDirectory()
        XCTAssertNil(client.defaultBranch(path: nonRepo.path))
    }

    // Tests create worktree when branch exists locally by arranging representative inputs and asserting the expected result.
    func testCreateWorktreeWhenBranchExistsLocally() throws {
        let root = try makeTempDirectory()
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try initializeGitRepository(at: repo, initialBranch: "main")
        try runGit(["checkout", "-b", "feature"], cwd: repo.path)
        try runGit(["checkout", "main"], cwd: repo.path)

        let worktree = root.appendingPathComponent("feature-worktree", isDirectory: true)
        let client = GitClient()
        try client.createWorktree(path: repo.path, worktreePath: worktree.path, branch: "feature")

        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
        let branch = try runGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: worktree.path).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(branch, "feature")
    }

    // Tests create worktree when branch exists only on remote by arranging representative inputs and asserting the expected result.
    func testCreateWorktreeWhenBranchExistsOnlyOnRemote() throws {
        let fixture = try makeRemoteFixture()
        let client = GitClient()
        XCTAssertFalse(client.branchExists(path: fixture.clone.path, branch: "remote-feature"))
        XCTAssertTrue(client.remoteBranchExists(path: fixture.clone.path, branch: "remote-feature"))

        let worktree = fixture.root.appendingPathComponent("remote-feature-worktree", isDirectory: true)
        try client.createWorktree(path: fixture.clone.path, worktreePath: worktree.path, branch: "remote-feature")

        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
        XCTAssertTrue(client.branchExists(path: fixture.clone.path, branch: "remote-feature"))
        let branch = try runGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: worktree.path).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(branch, "remote-feature")
    }

    // Tests create worktree when branch exists only on remote without local tracking ref by arranging representative inputs and asserting the expected result.
    func testCreateWorktreeWhenBranchExistsOnlyOnRemoteWithoutLocalTrackingRef() throws {
        let fixture = try makeRemoteFixture()
        try runGit(["checkout", "-b", "new-remote-only"], cwd: fixture.source.path)
        try "new remote".write(to: fixture.source.appending(path: "NEW_REMOTE_FOR_WORKTREE.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "NEW_REMOTE_FOR_WORKTREE.md"], cwd: fixture.source.path)
        try runGit(
            ["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "new remote worktree"], cwd: fixture.source.path)
        try runGit(["push", fixture.remote.path, "new-remote-only"], cwd: fixture.source.path)

        let trackedBefore = try runGit(["for-each-ref", "--format=%(refname:short)", "refs/remotes/origin/new-remote-only"], cwd: fixture.clone.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trackedBefore.isEmpty)

        let client = GitClient()
        XCTAssertFalse(client.branchExists(path: fixture.clone.path, branch: "new-remote-only"))
        XCTAssertTrue(client.remoteBranchExists(path: fixture.clone.path, branch: "new-remote-only"))

        let worktree = fixture.root.appendingPathComponent("new-remote-only-worktree", isDirectory: true)
        try client.createWorktree(path: fixture.clone.path, worktreePath: worktree.path, branch: "new-remote-only")

        let trackedAfter = try runGit(["for-each-ref", "--format=%(refname:short)", "refs/remotes/origin/new-remote-only"], cwd: fixture.clone.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(trackedAfter, "origin/new-remote-only")
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
        XCTAssertTrue(client.branchExists(path: fixture.clone.path, branch: "new-remote-only"))
        let branch = try runGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: worktree.path).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(branch, "new-remote-only")
    }

    // Tests list worktrees returns all worktrees by arranging representative inputs and asserting the expected result.
    func testListWorktreesReturnsAllWorktrees() throws {
        let root = try makeTempDirectory()
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try initializeGitRepository(at: repo, initialBranch: "main")
        let client = GitClient()
        let worktree1 = root.appendingPathComponent("feature-1", isDirectory: true)
        let worktree2 = root.appendingPathComponent("feature-2", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: worktree1.path, branch: "feature-1")
        try client.createWorktree(path: repo.path, worktreePath: worktree2.path, branch: "feature-2")
        let worktrees = try client.listWorktrees(path: repo.path)
        XCTAssertEqual(worktrees.count, 3)
        let normalizedRepoPath = URL(fileURLWithPath: repo.path).resolvingSymlinksInPath().path
        let normalizedWorktree1Path = URL(fileURLWithPath: worktree1.path).resolvingSymlinksInPath().path
        let normalizedWorktree2Path = URL(fileURLWithPath: worktree2.path).resolvingSymlinksInPath().path
        let mainWorktree = try XCTUnwrap(
            worktrees.first(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == normalizedRepoPath }))
        XCTAssertEqual(mainWorktree.branchName, "main")
        let feature1 = try XCTUnwrap(
            worktrees.first(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == normalizedWorktree1Path }))
        XCTAssertEqual(feature1.branchName, "feature-1")
        let feature2 = try XCTUnwrap(
            worktrees.first(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == normalizedWorktree2Path }))
        XCTAssertEqual(feature2.branchName, "feature-2")
    }
    // Tests list worktrees returns empty for non git repo by arranging representative inputs and asserting the expected result.
    func testListWorktreesReturnsEmptyForNonGitRepo() throws {
        let nonRepo = try makeTempDirectory()
        let client = GitClient()
        XCTAssertThrowsError(try client.listWorktrees(path: nonRepo.path))
    }

    // Tests create and remove worktree for new branch by arranging representative inputs and asserting the expected result.
    func testCreateAndRemoveWorktreeForNewBranch() throws {
        let root = try makeTempDirectory()
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try initializeGitRepository(at: repo, initialBranch: "main")
        let client = GitClient()

        let worktree = root.appendingPathComponent("scratch-worktree", isDirectory: true)
        try client.createWorktree(path: repo.path, worktreePath: worktree.path, branch: "scratch")
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
        XCTAssertTrue(client.branchExists(path: repo.path, branch: "scratch"))

        try client.removeWorktree(path: repo.path, worktreePath: worktree.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path))
    }

    // Tests create worktree for new branch uses base branch head by arranging representative inputs and asserting the expected result.
    func testCreateWorktreeForNewBranchUsesBaseBranchHead() throws {
        let root = try makeTempDirectory()
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try initializeGitRepository(at: repo, initialBranch: "main")
        try runGit(["checkout", "-b", "develop"], cwd: repo.path)
        try "target".write(to: repo.appendingPathComponent("TARGET.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "TARGET.txt"], cwd: repo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "target"], cwd: repo.path)
        let expectedHead = try runGit(["rev-parse", "develop"], cwd: repo.path).trimmingCharacters(in: .whitespacesAndNewlines)
        try runGit(["checkout", "main"], cwd: repo.path)

        let worktree = root.appendingPathComponent("feature-worktree", isDirectory: true)
        let client = GitClient()
        try client.createWorktree(path: repo.path, worktreePath: worktree.path, branch: "feature", baseBranch: "develop")

        let featureHead = try runGit(["rev-parse", "HEAD"], cwd: worktree.path).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(featureHead, expectedHead)
    }

    // Tests create worktree for new branch uses remote base branch without local tracking ref by arranging representative inputs and asserting the expected result.
    func testCreateWorktreeForNewBranchUsesRemoteBaseBranchWithoutLocalTrackingRef() throws {
        let fixture = try makeRemoteFixture()
        try runGit(["checkout", "-b", "new-remote-target"], cwd: fixture.source.path)
        try "target".write(to: fixture.source.appending(path: "NEW_REMOTE_TARGET.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "NEW_REMOTE_TARGET.md"], cwd: fixture.source.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "remote target"], cwd: fixture.source.path)
        try runGit(["push", fixture.remote.path, "new-remote-target"], cwd: fixture.source.path)

        let expectedHead = try runGit(["rev-parse", "new-remote-target"], cwd: fixture.source.path).trimmingCharacters(in: .whitespacesAndNewlines)
        let trackedBefore = try runGit(
            ["for-each-ref", "--format=%(refname:short)", "refs/remotes/origin/new-remote-target"], cwd: fixture.clone.path
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trackedBefore.isEmpty)

        let worktree = fixture.root.appendingPathComponent("remote-target-worktree", isDirectory: true)
        try GitClient().createWorktree(
            path: fixture.clone.path, worktreePath: worktree.path, branch: "new-feature-from-remote-target", baseBranch: "new-remote-target")

        let trackedAfter = try runGit(
            ["for-each-ref", "--format=%(refname:short)", "refs/remotes/origin/new-remote-target"], cwd: fixture.clone.path
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(trackedAfter, "origin/new-remote-target")
        let featureHead = try runGit(["rev-parse", "HEAD"], cwd: worktree.path).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(featureHead, expectedHead)
    }

    func testRefreshWorktreeFastForwardOnlyFetchesAndAdvancesBranch() throws {
        let fixture = try makeRemoteFixture()
        let worktree = fixture.root.appendingPathComponent("remote-feature-worktree", isDirectory: true)
        try GitClient().createWorktree(path: fixture.clone.path, worktreePath: worktree.path, branch: "remote-feature")
        let beforeRevision = try runGit(["rev-parse", "HEAD"], cwd: worktree.path).trimmingCharacters(in: .whitespacesAndNewlines)
        try runGit(["checkout", "remote-feature"], cwd: fixture.source.path)
        try "next".write(to: fixture.source.appendingPathComponent("NEXT.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "NEXT.md"], cwd: fixture.source.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "next"], cwd: fixture.source.path)
        try runGit(["push", fixture.remote.path, "remote-feature"], cwd: fixture.source.path)
        let expectedRevision = try runGit(["rev-parse", "remote-feature"], cwd: fixture.source.path).trimmingCharacters(in: .whitespacesAndNewlines)
        let recordingGit = try makeRecordingGitWrapper(root: fixture.root)

        let result = try GitClient(gitExecutable: recordingGit.executable.path).refreshWorktreeFastForwardOnly(
            path: worktree.path, branch: "remote-feature", hostName: "Builder A")

        let afterRevision = try runGit(["rev-parse", "HEAD"], cwd: worktree.path).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(result.beforeRevision, beforeRevision)
        XCTAssertEqual(result.afterRevision, expectedRevision)
        XCTAssertEqual(afterRevision, expectedRevision)
        XCTAssertTrue(result.fastForwarded)
        let commands = try String(contentsOf: recordingGit.log, encoding: .utf8)
        XCTAssertFalse(commands.contains(" reset"))
        XCTAssertFalse(commands.contains(" stash"))
        XCTAssertFalse(commands.contains(" clean"))
        XCTAssertFalse(commands.contains("checkout -f"))
        XCTAssertFalse(commands.contains("checkout --force"))
    }

    func testRefreshWorktreeFastForwardOnlyBlocksDirtyWorktree() throws {
        let fixture = try makeRemoteFixture()
        let worktree = fixture.root.appendingPathComponent("remote-feature-worktree", isDirectory: true)
        try GitClient().createWorktree(path: fixture.clone.path, worktreePath: worktree.path, branch: "remote-feature")
        try "dirty".write(to: worktree.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        assertRefreshBlock(reason: .dirtyWorktree) {
            _ = try GitClient().refreshWorktreeFastForwardOnly(path: worktree.path, branch: "remote-feature", hostName: "Builder A")
        }
    }

    func testRefreshWorktreeFastForwardOnlyBlocksDivergentHistory() throws {
        let fixture = try makeRemoteFixture()
        let worktree = fixture.root.appendingPathComponent("remote-feature-worktree", isDirectory: true)
        try GitClient().createWorktree(path: fixture.clone.path, worktreePath: worktree.path, branch: "remote-feature")
        try "local".write(to: worktree.appendingPathComponent("LOCAL.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "LOCAL.md"], cwd: worktree.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "local"], cwd: worktree.path)
        try runGit(["checkout", "remote-feature"], cwd: fixture.source.path)
        try "remote".write(to: fixture.source.appendingPathComponent("REMOTE.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "REMOTE.md"], cwd: fixture.source.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "remote"], cwd: fixture.source.path)
        try runGit(["push", fixture.remote.path, "remote-feature"], cwd: fixture.source.path)

        assertRefreshBlock(reason: .divergentHistory) {
            _ = try GitClient().refreshWorktreeFastForwardOnly(path: worktree.path, branch: "remote-feature", hostName: "Builder A")
        }
    }

    func testRefreshWorktreeFastForwardOnlyBlocksUntrackedOverwriteRisk() throws {
        let fixture = try makeRemoteFixture()
        let worktree = fixture.root.appendingPathComponent("remote-feature-worktree", isDirectory: true)
        try GitClient().createWorktree(path: fixture.clone.path, worktreePath: worktree.path, branch: "remote-feature")
        let conflictFile = worktree.appendingPathComponent("CONFLICT.md")
        try "scratch".write(to: conflictFile, atomically: true, encoding: .utf8)
        try runGit(["checkout", "remote-feature"], cwd: fixture.source.path)
        try "remote".write(to: fixture.source.appendingPathComponent("CONFLICT.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "CONFLICT.md"], cwd: fixture.source.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "conflict"], cwd: fixture.source.path)
        try runGit(["push", fixture.remote.path, "remote-feature"], cwd: fixture.source.path)

        assertRefreshBlock(reason: .untrackedOverwriteRisk) {
            _ = try GitClient().refreshWorktreeFastForwardOnly(path: worktree.path, branch: "remote-feature", hostName: "Builder A")
        }
        XCTAssertEqual(try String(contentsOf: conflictFile, encoding: .utf8), "scratch")
    }

    func testRefreshWorktreeFastForwardOnlyBlocksMissingBranch() throws {
        let fixture = try makeRemoteFixture()

        assertRefreshBlock(reason: .missingBranch) {
            _ = try GitClient().refreshWorktreeFastForwardOnly(path: fixture.clone.path, branch: "missing-branch", hostName: "Builder A")
        }
    }

    func testRefreshWorktreeFastForwardOnlyBlocksFetchFailure() throws {
        let fixture = try makeRemoteFixture()
        try runGit(["remote", "set-url", "origin", fixture.root.appendingPathComponent("missing.git").path], cwd: fixture.clone.path)

        assertRefreshBlock(reason: .fetchFailed) {
            _ = try GitClient().refreshWorktreeFastForwardOnly(path: fixture.clone.path, branch: "remote-feature", hostName: "Builder A")
        }
    }

    // Tests branch options include local and remote branches by arranging representative inputs and asserting the expected result.
    func testBranchOptionsIncludeLocalAndRemoteBranches() throws {
        let fixture = try makeRemoteFixture()
        try runGit(["checkout", "-b", "local-only"], cwd: fixture.clone.path)
        try runGit(["checkout", "main"], cwd: fixture.clone.path)

        let client = GitClient()
        let options = client.branchOptions(path: fixture.clone.path)

        XCTAssertTrue(options.contains("main"))
        XCTAssertTrue(options.contains("remote-feature"))
        XCTAssertTrue(options.contains("local-only"))
    }

    // Tests branch options include live remote heads without fetch by arranging representative inputs and asserting the expected result.
    func testBranchOptionsIncludeLiveRemoteHeadsWithoutFetch() throws {
        let fixture = try makeRemoteFixture()
        try runGit(["checkout", "-b", "new-remote-only"], cwd: fixture.source.path)
        try "new remote".write(to: fixture.source.appending(path: "NEW_REMOTE.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "NEW_REMOTE.md"], cwd: fixture.source.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "new remote"], cwd: fixture.source.path)
        try runGit(["push", fixture.remote.path, "new-remote-only"], cwd: fixture.source.path)
        XCTAssertFalse(GitClient().branchExists(path: fixture.clone.path, branch: "new-remote-only"), "Local branch should not exist before fetch.")

        let options = GitClient().branchOptions(path: fixture.clone.path)

        XCTAssertTrue(options.contains("new-remote-only"))
    }

    // Tests tracked file activity uses tracked files for latest timestamp and count by arranging representative inputs and asserting the expected result.
    func testTrackedFileActivityUsesTrackedFilesForLatestTimestampAndCount() throws {
        let root = try makeTempDirectory()
        let repo = root.appending(path: "repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try initializeGitRepository(at: repo, initialBranch: "main")

        let trackedFile = repo.appending(path: "TRACKED.md")
        try "tracked".write(to: trackedFile, atomically: true, encoding: .utf8)
        try runGit(["add", "TRACKED.md"], cwd: repo.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "add tracked"], cwd: repo.path)

        let untrackedFile = repo.appending(path: "UNTRACKED.md")
        try "scratch".write(to: untrackedFile, atomically: true, encoding: .utf8)

    }

    // Tests clone and delete branch by arranging representative inputs and asserting the expected result.
    func testCloneAndDeleteBranch() throws {
        let source = try makeTempDirectory()
        try initializeGitRepository(at: source, initialBranch: "main")
        let destination = try makeTempDirectory().appendingPathComponent("cloned", isDirectory: true)

        let client = GitClient()
        try client.clone(url: source.path, destination: destination.path)
        XCTAssertTrue(client.isRepo(path: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("README.md").path))

        try runGit(["checkout", "-b", "delete-me"], cwd: destination.path)
        try runGit(["checkout", "main"], cwd: destination.path)
        XCTAssertTrue(client.branchExists(path: destination.path, branch: "delete-me"))

        XCTAssertTrue(try client.deleteBranch(path: destination.path, branch: "delete-me"))
        XCTAssertFalse(client.branchExists(path: destination.path, branch: "delete-me"))
    }

    func testDeleteRemoteBranchRemovesRemoteHead() throws {
        let fixture = try makeRemoteFixture()
        let client = GitClient()

        XCTAssertTrue(client.remoteBranchExists(path: fixture.clone.path, branch: "remote-feature"))
        XCTAssertTrue(try client.deleteRemoteBranch(path: fixture.clone.path, branch: "remote-feature"))
        XCTAssertFalse(client.remoteBranchExists(path: fixture.clone.path, branch: "remote-feature"))
    }

    // Tests createWorktree throws when base branch does not exist locally or remotely by arranging representative inputs and asserting the expected result.
    func testCreateWorktreeThrowsWhenBaseBranchNotFound() throws {
        let root = try makeTempDirectory()
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try initializeGitRepository(at: repo, initialBranch: "main")

        let worktree = root.appendingPathComponent("nonexistent-worktree", isDirectory: true)
        let client = GitClient()
        // "nonexistent-branch" does not exist locally or remotely.
        XCTAssertThrowsError(
            try client.createWorktree(
                path: repo.path, worktreePath: worktree.path, branch: "new-feature", baseBranch: "nonexistent-branch", allowRemoteBranchLookup: false)
        ) { error in guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") } }
    }

    private func makeRemoteFixture() throws -> (root: URL, source: URL, remote: URL, clone: URL) {
        let root = try makeTempDirectory()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try initializeGitRepository(at: source, initialBranch: "main")

        try runGit(["checkout", "-b", "remote-feature"], cwd: source.path)
        try "feature".write(to: source.appendingPathComponent("FEATURE.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "FEATURE.md"], cwd: source.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "feature"], cwd: source.path)
        try runGit(["checkout", "main"], cwd: source.path)

        let remote = root.appendingPathComponent("remote.git", isDirectory: true)
        try runGit(["clone", "--bare", source.path, remote.path], cwd: root.path)

        let clone = root.appendingPathComponent("clone", isDirectory: true)
        try runGit(["clone", remote.path, clone.path], cwd: root.path)
        return (root, source, remote, clone)
    }

    private func makeRecordingGitWrapper(root: URL) throws -> (executable: URL, log: URL) {
        let log = root.appendingPathComponent("git-commands.log")
        let wrapper = root.appendingPathComponent("record-git.sh")
        let script = """
            #!/bin/sh
            printf '%s\\n' "$*" >> '\(shellSingleQuoteContent(log.path))'
            previous=''
            for arg in "$@"; do
              case "$arg" in
                reset|stash|clean) exit 97 ;;
              esac
              if [ "$previous" = "checkout" ] && { [ "$arg" = "-f" ] || [ "$arg" = "--force" ]; }; then
                exit 97
              fi
              previous="$arg"
            done
            exec /usr/bin/env git "$@"
            """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return (wrapper, log)
    }

    private func shellSingleQuoteContent(_ value: String) -> String { value.replacingOccurrences(of: "'", with: "'\\''") }

    private func assertRefreshBlock(
        reason expectedReason: RemoteWorktreeRefreshBlockReason, _ run: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try run(), file: file, line: line) { error in
            guard let block = error as? RemoteWorktreeRefreshBlock else {
                XCTFail("Expected RemoteWorktreeRefreshBlock, got \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(block.reason, expectedReason, file: file, line: line)
            XCTAssertTrue(block.localizedDescription.contains("Builder A"), file: file, line: line)
        }
    }

    private func setModificationDate(_ date: Date, for fileURL: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fileURL.path)
    }

    private func modificationDate(for fileURL: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let date = attributes[.modificationDate] as? Date else {
            throw NSError(domain: "spaces.tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing modification date for \(fileURL.path)"])
        }
        return date
    }

    private func assertEqualDate(_ lhs: Date?, _ rhs: Date, tolerance: TimeInterval = 1, file: StaticString = #filePath, line: UInt = #line) {
        guard let lhs else {
            XCTFail("Expected date value.", file: file, line: line)
            return
        }
        XCTAssertLessThanOrEqual(abs(lhs.timeIntervalSince(rhs)), tolerance, file: file, line: line)
    }

    // Tests removeWorktree throws a gitCommandFailed error when the path does not exist by arranging representative inputs and asserting the expected result.
    func testRemoveWorktreeThrowsWhenPathIsInvalid() throws {
        let repo = try makeTempDirectory()
        try initializeGitRepository(at: repo, initialBranch: "main")
        let client = GitClient()

        // Attempt to remove a worktree path that was never created; git will fail with a non-zero exit code.
        XCTAssertThrowsError(try client.removeWorktree(path: repo.path, worktreePath: "/nonexistent/path/\(UUID().uuidString)")) { error in
            guard case WorkspaceError.gitCommandFailed = error else { return XCTFail("Expected gitCommandFailed, got \(error)") }
        }
    }

    // Tests WorktreeInfo.branchName returns nil when branch is nil by arranging representative inputs and asserting the expected result.
    func testWorktreeInfoBranchNameReturnsNilWhenBranchIsNil() {
        let info = WorktreeInfo(path: "/tmp/repo", head: "abc123", branch: nil)
        XCTAssertNil(info.branchName)
    }

    // Tests WorktreeInfo.branchName returns the raw branch string when it contains no slash separator by arranging representative inputs and asserting the expected result.
    func testWorktreeInfoBranchNameReturnsRawStringWhenNoSlashPresent() {
        let info = WorktreeInfo(path: "/tmp/repo", head: "abc123", branch: "")
        XCTAssertEqual(info.branchName, "")
    }

    // Tests renameCurrentBranch throws invalidArgument when an empty branch name is provided.
    func testRenameCurrentBranchThrowsForEmptyName() throws {
        let repo = try makeTempDirectory()
        try initializeGitRepository(at: repo, initialBranch: "main")
        let client = GitClient()

        XCTAssertThrowsError(try client.renameCurrentBranch(path: repo.path, to: "")) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
        XCTAssertThrowsError(try client.renameCurrentBranch(path: repo.path, to: "   ")) { error in
            guard case WorkspaceError.invalidArgument = error else { return XCTFail("Expected invalidArgument, got \(error)") }
        }
    }

    // Tests renameCurrentBranch is a no-op when the new name matches the current branch.
    func testRenameCurrentBranchIsNoOpWhenNameIsUnchanged() throws {
        let repo = try makeTempDirectory()
        try initializeGitRepository(at: repo, initialBranch: "main")
        let client = GitClient()

        // Renaming "main" to "main" should succeed without throwing.
        XCTAssertNoThrow(try client.renameCurrentBranch(path: repo.path, to: "main"))

        // Verify the branch name is still "main".
        let output = try runGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: repo.path)
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "main")
    }

}
