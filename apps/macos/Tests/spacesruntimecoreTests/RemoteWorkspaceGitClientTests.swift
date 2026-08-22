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

    /// Regression coverage for `runGitAndCapture`'s bounded-capture mode (`maxOutputBytes`): a command
    /// whose stdout exceeds the cap must be terminated and reaped rather than left blocked writing into an
    /// undrained pipe. There is no clean way to assert "no leaked process" directly (per the fix spec, via
    /// `waitUntilExit` semantics rather than `pgrep`), so this asserts indirectly: the call throws
    /// `outputExceededCap` and returns well within a small timeout, which would not happen if the
    /// implementation were blocked waiting on the child (the metadata-command default timeout elsewhere in
    /// this client is 2s; a hang here would make this test itself hang past any such timeout instead of
    /// returning promptly).
    func testRunGitAndCaptureBoundedModeTruncatesOversizedOutputWithoutHangingOrLeakingTheProcess() throws {
        let fixture = try makeRemoteFixture()
        let bigContent = String(repeating: "x", count: 200_000)
        try bigContent.write(to: fixture.source.appendingPathComponent("BIG.md"), atomically: true, encoding: .utf8)
        try runGit(["add", "BIG.md"], cwd: fixture.source.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "big"], cwd: fixture.source.path)

        let client = RemoteWorkspaceGitClient()
        let start = Date()
        XCTAssertThrowsError(try client.runGitAndCapture(["-C", fixture.source.path, "show", "HEAD:BIG.md"], maxOutputBytes: 1024)) { error in
            XCTAssertEqual(error as? SpacesRuntimeError, .outputExceededCap)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "bounded capture must terminate the child promptly rather than hang")
    }

    /// Regression coverage for the deadline-enforcement bug: `runGitAndCapture` used to call
    /// `PipeDrain.waitForData()` (which only ever returns at pipe EOF) before enforcing `timeout`, so a
    /// subprocess that stops producing output without exiting — nothing to do with a large-output cap — could
    /// hang the caller forever regardless of the configured timeout. `gitExecutable` is already a test seam
    /// (used above for the destructive-command-recording wrapper), so this substitutes `/bin/sleep` for a
    /// long-running, output-silent, SIGTERM-killable child and asserts the real production method returns
    /// within its deadline plus a small margin rather than blocking for the sleep's full duration.
    func testRunGitAndCaptureEnforcesTheTimeoutEvenWhenTheProcessNeverProducesOutput() throws {
        let client = RemoteWorkspaceGitClient(gitExecutable: "/bin/sleep")
        // A distinctive duration so the post-call `pgrep` below cannot false-positive-match some unrelated
        // `sleep` invocation already running on the machine.
        let markerSeconds = "784512"
        let start = Date()
        XCTAssertThrowsError(try client.runGitAndCapture([markerSeconds], timeout: 1)) { error in
            guard case .gitCommandFailed(let message)? = error as? SpacesRuntimeError else {
                XCTFail("Expected a timeout failure, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("timed out"), "Expected a timeout message, got: \(message)")
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(start), 5, "the 1s deadline must be enforced without waiting for the child to produce output or exit on its own"
        )

        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "sleep \(markerSeconds)"]
        pgrep.standardOutput = Pipe()
        pgrep.standardError = Pipe()
        try pgrep.run()
        pgrep.waitUntilExit()
        XCTAssertNotEqual(pgrep.terminationStatus, 0, "the sleep child must be killed, not left running past the deadline")
    }

    /// Regression coverage for the `.exited`-vs-`.capExceeded` race: `awaitProcessExitOrCapOverflow`'s poll
    /// loop can observe the child has already exited a beat before the drain thread finishes appending its
    /// final chunk and records the overflow, so `.exited` can win even though the output truly exceeded the
    /// cap. `runGitAndCapture` must recheck `didExceedCap` after `waitForData()` returns (which is ordered
    /// after the drain thread's write by its semaphore) rather than trusting whichever branch the race
    /// resolved to. `/usr/bin/head -c 65536 /dev/zero` is a fast-exiting, no-shell, single-process command
    /// that reliably exceeds a small cap and exits almost immediately — a good candidate for hitting the
    /// exit-before-overflow-is-recorded ordering. Whichever way the race actually resolves on this machine,
    /// the call must throw `outputExceededCap`.
    func testRunGitAndCaptureThrowsCapExceededEvenWhenTheProcessExitsBeforeTheDrainRecordsTheOverflow() throws {
        let client = RemoteWorkspaceGitClient(gitExecutable: "/usr/bin/head")
        for _ in 0..<20 {
            XCTAssertThrowsError(try client.runGitAndCapture(["-c", "65536", "/dev/zero"], maxOutputBytes: 4096)) { error in
                XCTAssertEqual(error as? SpacesRuntimeError, .outputExceededCap)
            }
        }
    }

    /// Regression coverage for round-11's fix: `runGitAndCapture`'s post-observation drain waits
    /// (`.exited`, `.capExceeded`, `.timedOut`) used to call `PipeDrain.waitForData()` unconditionally,
    /// which only returns once every writer of the pipe has closed it. A descendant the git process spawns
    /// and detaches — the concrete real case is git's `fsmonitor--daemon`, launched by `git status` under
    /// `core.fsmonitor` — inherits the pipe's write end and can outlive git itself, so EOF never arrives and
    /// even the *timeout* path used to hang forever waiting on a straggler nobody was timing out anymore.
    ///
    /// `gitExecutable` is substituted with a stub script that backgrounds a long-lived, detached `sleep`
    /// (inheriting the pipes' write ends) and then exits immediately itself — the `.exited` branch, where
    /// the process genuinely finished but something it spawned kept the pipes open. The child's pid is
    /// written to a file (via an injected environment variable, `RemoteWorkspaceGitClient`'s existing
    /// `environmentOverrides` seam) so it can be killed in `defer` regardless of outcome; the sleep duration
    /// itself is also capped at 30s so a failed cleanup cannot leak a process past that ceiling.
    func testRunGitAndCaptureDoesNotHangOnADetachedDescendantHoldingThePipesOpenAfterTheProcessExits() throws {
        let root = try makeTempDirectory()
        let scriptURL = root.appendingPathComponent("stub-detaching-child.sh")
        let pidFileURL = root.appendingPathComponent("child.pid")
        let script = """
            #!/bin/sh
            sleep 30 &
            echo $! > "$SPACES_TEST_DRAIN_PIDFILE"
            exit 0
            """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let client = RemoteWorkspaceGitClient(
            gitExecutable: scriptURL.path, environmentOverrides: ["SPACES_TEST_DRAIN_PIDFILE": pidFileURL.path])
        defer { killLingeringChild(pidFileURL: pidFileURL) }

        let start = Date()
        XCTAssertThrowsError(try client.runGitAndCapture([], timeout: 3)) { error in
            guard case .gitCommandFailed(let message)? = error as? SpacesRuntimeError else {
                XCTFail("Expected a timeout failure, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("timed out"), "Expected a timeout message, got: \(message)")
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(start), 10,
            "a detached descendant holding the pipes open must not block the drain wait past its bounded grace"
        )
    }

    /// Kills the `sleep` this test's stub script detaches, using its pid file (written once the script has
    /// actually backgrounded the child). Best-effort: if the pid file was never written (the stub failed to
    /// run at all), there is nothing to clean up.
    private func killLingeringChild(pidFileURL: URL) {
        guard let pidString = try? String(contentsOf: pidFileURL, encoding: .utf8),
            let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/bin/kill")
        kill.arguments = ["-9", String(pid)]
        kill.standardOutput = Pipe()
        kill.standardError = Pipe()
        try? kill.run()
        kill.waitUntilExit()
    }

    func testRunGitAndCaptureBoundedModeReturnsOutputNormallyWhenUnderTheCap() throws {
        let fixture = try makeRemoteFixture()
        let client = RemoteWorkspaceGitClient()
        let output = try client.runGitAndCapture(["-C", fixture.source.path, "rev-parse", "HEAD"], maxOutputBytes: 4096)
        XCTAssertFalse(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
