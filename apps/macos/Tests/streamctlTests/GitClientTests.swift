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
        let branch = try runGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: worktree.path).trimmingCharacters(in: .whitespacesAndNewlines)
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
        let branch = try runGit(["rev-parse", "--abbrev-ref", "HEAD"], cwd: worktree.path).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(branch, "remote-feature")
    }

    func testCreateWorktreeWhenBranchExistsOnlyOnRemoteWithoutLocalTrackingRef() throws {
        let fixture = try makeRemoteFixture()
        try runGit(["checkout", "-b", "new-remote-only"], cwd: fixture.source.path)
        try "new remote".write(to: fixture.source.appending(path: "NEW_REMOTE_FOR_WORKTREE.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "NEW_REMOTE_FOR_WORKTREE.md"], cwd: fixture.source.path)
        try runGit(
            ["-c", "user.name=muxy-test", "-c", "user.email=test@example.com", "commit", "-m", "new remote worktree"], cwd: fixture.source.path)
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
        try runGit(["-c", "user.name=muxy-test", "-c", "user.email=test@example.com", "commit", "-m", "target"], cwd: repo.path)
        let expectedHead = try runGit(["rev-parse", "develop"], cwd: repo.path).trimmingCharacters(in: .whitespacesAndNewlines)
        try runGit(["checkout", "main"], cwd: repo.path)

        let worktree = root.appendingPathComponent("feature-worktree", isDirectory: true)
        let client = GitClient()
        try client.createWorktree(path: repo.path, worktreePath: worktree.path, branch: "feature", targetBranch: "develop")

        let featureHead = try runGit(["rev-parse", "HEAD"], cwd: worktree.path).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(featureHead, expectedHead)
    }

    func testCreateWorktreeForNewBranchUsesRemoteTargetBranchWithoutLocalTrackingRef() throws {
        let fixture = try makeRemoteFixture()
        try runGit(["checkout", "-b", "new-remote-target"], cwd: fixture.source.path)
        try "target".write(to: fixture.source.appending(path: "NEW_REMOTE_TARGET.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "NEW_REMOTE_TARGET.md"], cwd: fixture.source.path)
        try runGit(
            ["-c", "user.name=muxy-test", "-c", "user.email=test@example.com", "commit", "-m", "remote target"], cwd: fixture.source.path)
        try runGit(["push", fixture.remote.path, "new-remote-target"], cwd: fixture.source.path)

        let expectedHead = try runGit(["rev-parse", "new-remote-target"], cwd: fixture.source.path).trimmingCharacters(in: .whitespacesAndNewlines)
        let trackedBefore = try runGit(
            ["for-each-ref", "--format=%(refname:short)", "refs/remotes/origin/new-remote-target"], cwd: fixture.clone.path
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(trackedBefore.isEmpty)

        let worktree = fixture.root.appendingPathComponent("remote-target-worktree", isDirectory: true)
        try GitClient().createWorktree(
            path: fixture.clone.path, worktreePath: worktree.path, branch: "new-feature-from-remote-target", targetBranch: "new-remote-target")

        let trackedAfter = try runGit(
            ["for-each-ref", "--format=%(refname:short)", "refs/remotes/origin/new-remote-target"], cwd: fixture.clone.path
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(trackedAfter, "origin/new-remote-target")
        let featureHead = try runGit(["rev-parse", "HEAD"], cwd: worktree.path).trimmingCharacters(in: .whitespacesAndNewlines)
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
        try "new remote".write(to: fixture.source.appending(path: "NEW_REMOTE.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "NEW_REMOTE.md"], cwd: fixture.source.path)
        try runGit(["-c", "user.name=muxy-test", "-c", "user.email=test@example.com", "commit", "-m", "new remote"], cwd: fixture.source.path)
        try runGit(["push", fixture.remote.path, "new-remote-only"], cwd: fixture.source.path)
        XCTAssertFalse(GitClient().branchExists(path: fixture.clone.path, branch: "new-remote-only"), "Local branch should not exist before fetch.")

        let options = GitClient().branchOptions(path: fixture.clone.path)

        XCTAssertTrue(options.contains("new-remote-only"))
    }

    func testTrackedFileActivityUsesTrackedFilesForLatestTimestampAndCount() throws {
        let root = try makeTempDirectory()
        let repo = root.appending(path: "repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try initializeGitRepository(at: repo, initialBranch: "main")

        let trackedFile = repo.appending(path: "TRACKED.md")
        try "tracked".write(to: trackedFile, atomically: true, encoding: .utf8)
        try runGit(["add", "TRACKED.md"], cwd: repo.path)
        try runGit(["-c", "user.name=muxy-test", "-c", "user.email=test@example.com", "commit", "-m", "add tracked"], cwd: repo.path)

        let readmeFile = repo.appending(path: "README.md")
        let oldDate = Date(timeIntervalSinceNow: -600)
        let newerTrackedDate = Date(timeIntervalSinceNow: -300)
        try setModificationDate(oldDate, for: readmeFile)
        try setModificationDate(newerTrackedDate, for: trackedFile)

        let untrackedFile = repo.appending(path: "UNTRACKED.md")
        try "scratch".write(to: untrackedFile, atomically: true, encoding: .utf8)
        try setModificationDate(Date(), for: untrackedFile)

        let client = GitClient()
        let initialActivity = client.trackedFileActivity(path: repo.path)
        XCTAssertEqual(initialActivity.modifiedTrackedFileCount, 0)
        assertEqualDate(initialActivity.latestTrackedFileModificationDate, newerTrackedDate)

        try "updated readme".write(to: readmeFile, atomically: true, encoding: .utf8)
        let expectedLatestDate = try modificationDate(for: readmeFile)
        let updatedActivity = client.trackedFileActivity(path: repo.path)

        XCTAssertEqual(updatedActivity.modifiedTrackedFileCount, 1)
        assertEqualDate(updatedActivity.latestTrackedFileModificationDate, expectedLatestDate)
    }

    func testTrackedFileActivityReturnsEmptySnapshotForNonRepository() throws {
        let directory = try makeTempDirectory()
        let activity = GitClient().trackedFileActivity(path: directory.path)
        XCTAssertNil(activity.latestTrackedFileModificationDate)
        XCTAssertEqual(activity.modifiedTrackedFileCount, 0)
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
        try runGit(["-c", "user.name=muxy-test", "-c", "user.email=test@example.com", "commit", "-m", "init"], cwd: directory.path)
    }

    private func makeRemoteFixture() throws -> (root: URL, source: URL, remote: URL, clone: URL) {
        let root = try makeTempDirectory()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try initializeGitRepository(at: source, initialBranch: "main")

        try runGit(["checkout", "-b", "remote-feature"], cwd: source.path)
        try "feature".write(to: source.appendingPathComponent("FEATURE.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "FEATURE.md"], cwd: source.path)
        try runGit(["-c", "user.name=muxy-test", "-c", "user.email=test@example.com", "commit", "-m", "feature"], cwd: source.path)
        try runGit(["checkout", "main"], cwd: source.path)

        let remote = root.appendingPathComponent("remote.git", isDirectory: true)
        try runGit(["clone", "--bare", source.path, remote.path], cwd: root.path)

        let clone = root.appendingPathComponent("clone", isDirectory: true)
        try runGit(["clone", remote.path, clone.path], cwd: root.path)
        return (root, source, remote, clone)
    }

    @discardableResult private func runGit(_ arguments: [String], cwd: String) throws -> String {
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
            throw NSError(domain: "muxy.tests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errorText])
        }
        return outputText
    }

    private func setModificationDate(_ date: Date, for fileURL: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: fileURL.path)
    }

    private func modificationDate(for fileURL: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let date = attributes[.modificationDate] as? Date else {
            throw NSError(domain: "muxy.tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing modification date for \(fileURL.path)"])
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
}
