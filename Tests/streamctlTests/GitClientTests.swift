import Foundation
import XCTest

@testable import streamctl

final class GitClientTests: XCTestCase {
    func testIsRepoDetectsRepositoryAndNonRepository() throws {
        let repo = try makeTempDirectory()
        try initializeGitRepository(at: repo, initialBranch: "main")
        let nonRepo = try makeTempDirectory()

        let client = GitClient()
        XCTAssertTrue(client.isRepo(path: repo.path))
        XCTAssertFalse(client.isRepo(path: nonRepo.path))
    }

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
        let branch = try runGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: worktree.path).trimmingCharacters(
            in: .whitespacesAndNewlines)
        XCTAssertEqual(branch, "feature")
    }

    func testCreateWorktreeWhenBranchExistsOnlyOnRemote() throws {
        let fixture = try makeRemoteFixture()
        let client = GitClient()
        XCTAssertFalse(client.branchExists(path: fixture.clone.path, branch: "remote-feature"))
        XCTAssertTrue(client.remoteBranchExists(path: fixture.clone.path, branch: "remote-feature"))

        let worktree = fixture.root.appendingPathComponent("remote-feature-worktree", isDirectory: true)
        try client.createWorktree(path: fixture.clone.path, worktreePath: worktree.path, branch: "remote-feature")

        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
        XCTAssertTrue(client.branchExists(path: fixture.clone.path, branch: "remote-feature"))
        let branch = try runGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: worktree.path).trimmingCharacters(
            in: .whitespacesAndNewlines)
        XCTAssertEqual(branch, "remote-feature")
    }

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

    func testCreateWorktreeForNewBranchUsesTargetBranchHead() throws {
        let root = try makeTempDirectory()
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try initializeGitRepository(at: repo, initialBranch: "main")
        try runGit(["checkout", "-b", "develop"], cwd: repo.path)
        try "target".write(to: repo.appendingPathComponent("TARGET.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "TARGET.txt"], cwd: repo.path)
        try runGit(
            ["-c", "user.name=agentmux-test", "-c", "user.email=test@example.com", "commit", "-m", "target"],
            cwd: repo.path
        )
        let expectedHead = try runGit(["rev-parse", "develop"], cwd: repo.path).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        try runGit(["checkout", "main"], cwd: repo.path)

        let worktree = root.appendingPathComponent("feature-worktree", isDirectory: true)
        let client = GitClient()
        try client.createWorktree(
            path: repo.path,
            worktreePath: worktree.path,
            branch: "feature",
            targetBranch: "develop"
        )

        let featureHead = try runGit(["rev-parse", "HEAD"], cwd: worktree.path).trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        XCTAssertEqual(featureHead, expectedHead)
    }

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

    func testBranchOptionsIncludeLiveRemoteHeadsWithoutFetch() throws {
        let fixture = try makeRemoteFixture()
        try runGit(["checkout", "-b", "new-remote-only"], cwd: fixture.source.path)
        try "new remote".write(
            to: fixture.source.appending(path: "NEW_REMOTE.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "NEW_REMOTE.md"], cwd: fixture.source.path)
        try runGit(
            ["-c", "user.name=agentmux-test", "-c", "user.email=test@example.com", "commit", "-m", "new remote"],
            cwd: fixture.source.path
        )
        try runGit(["push", fixture.remote.path, "new-remote-only"], cwd: fixture.source.path)
        XCTAssertFalse(
            GitClient().branchExists(path: fixture.clone.path, branch: "new-remote-only"),
            "Local branch should not exist before fetch."
        )

        let options = GitClient().branchOptions(path: fixture.clone.path)

        XCTAssertTrue(options.contains("new-remote-only"))
    }

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

        client.deleteBranch(path: destination.path, branch: "delete-me")
        XCTAssertFalse(client.branchExists(path: destination.path, branch: "delete-me"))
    }

    private func initializeGitRepository(at directory: URL, initialBranch: String) throws {
        try runGit(["init", "-b", initialBranch], cwd: directory.path)
        let readme = directory.appendingPathComponent("README.md")
        try "hello".write(to: readme, atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], cwd: directory.path)
        try runGit(
            ["-c", "user.name=agentmux-test", "-c", "user.email=test@example.com", "commit", "-m", "init"],
            cwd: directory.path
        )
    }

    private func makeRemoteFixture() throws -> (root: URL, source: URL, remote: URL, clone: URL) {
        let root = try makeTempDirectory()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try initializeGitRepository(at: source, initialBranch: "main")

        try runGit(["checkout", "-b", "remote-feature"], cwd: source.path)
        try "feature".write(
            to: source.appendingPathComponent("FEATURE.md"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "FEATURE.md"], cwd: source.path)
        try runGit(
            ["-c", "user.name=agentmux-test", "-c", "user.email=test@example.com", "commit", "-m", "feature"],
            cwd: source.path
        )
        try runGit(["checkout", "main"], cwd: source.path)

        let remote = root.appendingPathComponent("remote.git", isDirectory: true)
        try runGit(["clone", "--bare", source.path, remote.path], cwd: root.path)

        let clone = root.appendingPathComponent("clone", isDirectory: true)
        try runGit(["clone", remote.path, clone.path], cwd: root.path)
        return (root, source, remote, clone)
    }

    @discardableResult
    private func runGit(_ arguments: [String], cwd: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        // Commit hooks can export GIT_DIR/GIT_WORK_TREE for the repository being committed.
        // Tests create throwaway repositories and worktrees, so inheriting those values can
        // incorrectly redirect git operations away from the fixture under test.
        //
        // Remaining risk: this does not simulate callers that intentionally rely on these vars.
        // Those scenarios are still covered by integration behavior in real git environments.
        environment.removeValue(forKey: "GIT_DIR")
        environment.removeValue(forKey: "GIT_WORK_TREE")
        environment.removeValue(forKey: "GIT_INDEX_FILE")
        process.environment = environment
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()

        let outputText = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let errorText = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "agentmux.tests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errorText]
            )
        }
        return outputText
    }
}
