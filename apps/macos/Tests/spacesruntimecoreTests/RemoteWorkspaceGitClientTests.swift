import Foundation
import XCTest
import spacesruntimecore

final class RemoteWorkspaceGitClientTests: XCTestCase {
    func testRefreshWorktreeFastForwardOnlyFetchesAndAdvancesBranchWithoutDestructiveCommands() throws {
        let fixture = try makeRemoteFixture()
        let worktree = fixture.root.appendingPathComponent("remote-feature-worktree", isDirectory: true)
        try runGit(["worktree", "add", "-b", "remote-feature", worktree.path, "origin/remote-feature"], cwd: fixture.clone.path)
        let beforeRevision = try runGit(["rev-parse", "HEAD"], cwd: worktree.path).trimmingCharacters(in: .whitespacesAndNewlines)
        try runGit(["checkout", "remote-feature"], cwd: fixture.source.path)
        try "next".write(to: fixture.source.appendingPathComponent("NEXT.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "NEXT.md"], cwd: fixture.source.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "next"], cwd: fixture.source.path)
        try runGit(["push", fixture.remote.path, "remote-feature"], cwd: fixture.source.path)
        let expectedRevision = try runGit(["rev-parse", "remote-feature"], cwd: fixture.source.path).trimmingCharacters(in: .whitespacesAndNewlines)
        let recordingGit = try makeRecordingGitWrapper(root: fixture.root)

        let result = try RemoteWorkspaceGitClient(gitExecutable: recordingGit.executable.path).refreshWorktreeFastForwardOnly(
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
        try runGit(["worktree", "add", "-b", "remote-feature", worktree.path, "origin/remote-feature"], cwd: fixture.clone.path)
        try "dirty".write(to: worktree.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        assertRefreshBlock(reason: .dirtyWorktree) {
            _ = try RemoteWorkspaceGitClient().refreshWorktreeFastForwardOnly(path: worktree.path, branch: "remote-feature", hostName: "Builder A")
        }
    }

    func testRefreshWorktreeFastForwardOnlyBlocksMissingBranch() throws {
        let fixture = try makeRemoteFixture()

        assertRefreshBlock(reason: .missingBranch) {
            _ = try RemoteWorkspaceGitClient().refreshWorktreeFastForwardOnly(
                path: fixture.clone.path, branch: "missing-branch", hostName: "Builder A")
        }
    }

    func testRefreshWorktreeFastForwardOnlyBlocksUntrackedOverwriteRisk() throws {
        let fixture = try makeRemoteFixture()
        let worktree = fixture.root.appendingPathComponent("remote-feature-worktree", isDirectory: true)
        try runGit(["worktree", "add", "-b", "remote-feature", worktree.path, "origin/remote-feature"], cwd: fixture.clone.path)
        let conflictFile = worktree.appendingPathComponent("CONFLICT.md")
        try "scratch".write(to: conflictFile, atomically: true, encoding: .utf8)
        try runGit(["checkout", "remote-feature"], cwd: fixture.source.path)
        try "remote".write(to: fixture.source.appendingPathComponent("CONFLICT.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "CONFLICT.md"], cwd: fixture.source.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "conflict"], cwd: fixture.source.path)
        try runGit(["push", fixture.remote.path, "remote-feature"], cwd: fixture.source.path)

        assertRefreshBlock(reason: .untrackedOverwriteRisk) {
            _ = try RemoteWorkspaceGitClient().refreshWorktreeFastForwardOnly(path: worktree.path, branch: "remote-feature", hostName: "Builder A")
        }
        XCTAssertEqual(try String(contentsOf: conflictFile, encoding: .utf8), "scratch")
    }

    private func makeRemoteFixture() throws -> (root: URL, source: URL, remote: URL, clone: URL) {
        let root = try makeTempDirectory()
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try initializeGitRepository(at: source)
        try runGit(["checkout", "-b", "remote-feature"], cwd: source.path)
        try "feature".write(to: source.appendingPathComponent("FEATURE.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "FEATURE.md"], cwd: source.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "feature"], cwd: source.path)
        try runGit(["checkout", "main"], cwd: source.path)

        let remote = root.appendingPathComponent("origin.git", isDirectory: true)
        try runGit(["clone", "--bare", source.path, remote.path], cwd: root.path)

        let clone = root.appendingPathComponent("clone", isDirectory: true)
        try runGit(["clone", remote.path, clone.path], cwd: root.path)
        return (root, source, remote, clone)
    }

    private func initializeGitRepository(at url: URL) throws {
        try runGit(["init", "--initial-branch", "main"], cwd: url.path)
        try "initial".write(to: url.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "README.md"], cwd: url.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "initial"], cwd: url.path)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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
        reason expectedReason: RemoteWorkspaceRefreshBlockReason, _ run: () throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try run(), file: file, line: line) { error in
            guard let block = error as? RemoteWorkspaceRefreshBlock else {
                XCTFail("Expected RemoteWorkspaceRefreshBlock, got \(error)", file: file, line: line)
                return
            }
            XCTAssertEqual(block.reason, expectedReason, file: file, line: line)
            XCTAssertTrue(block.localizedDescription.contains("Builder A"), file: file, line: line)
        }
    }

    @discardableResult private func runGit(_ arguments: [String], cwd: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "GIT_DIR")
        environment.removeValue(forKey: "GIT_WORK_TREE")
        environment.removeValue(forKey: "GIT_INDEX_FILE")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "RemoteWorkspaceGitClientTests", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed: \(text)"])
        }
        return text
    }
}
