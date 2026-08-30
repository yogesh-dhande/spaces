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

    func testRunGitAndCaptureBoundedModeAcceptsOutputExactlyAtTheCap() throws {
        let fixture = try makeRemoteFixture()
        let expected = Data(repeating: 0x78, count: 1024)
        try expected.write(to: fixture.source.appendingPathComponent("EXACT.md"))
        try runGit(["add", "EXACT.md"], cwd: fixture.source.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "exact"], cwd: fixture.source.path)

        let output = try RemoteWorkspaceGitClient().runGitAndCaptureData(
            ["-C", fixture.source.path, "show", "HEAD:EXACT.md"], maxOutputBytes: expected.count)

        XCTAssertEqual(output, expected)
    }

    func testRunGitAndCaptureDataPreservesRawBlobBytes() throws {
        let fixture = try makeRemoteFixture()
        let expected = Data([0, 0xFF, 0xC3, 0x28])
        try expected.write(to: fixture.source.appendingPathComponent("binary.dat"))
        try runGit(["add", "binary.dat"], cwd: fixture.source.path)
        try runGit(["-c", "user.name=spaces-test", "-c", "user.email=test@example.com", "commit", "-m", "binary"], cwd: fixture.source.path)

        let data = try RemoteWorkspaceGitClient().runGitAndCaptureData(["-C", fixture.source.path, "show", "HEAD:binary.dat"], maxOutputBytes: 1024)

        XCTAssertEqual(data, expected)
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
        defer { Self.killLingeringChild(pidFileURL: pidFileURL) }

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
    private static func killLingeringChild(pidFileURL: URL) {
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

    /// Regression coverage for Fix 2: the `.exited` branch's stderr drain used to reuse `drainTimeout`,
    /// the value computed once *before* the stdout wait, instead of recomputing it from what remained of
    /// the deadline. When a stdout straggler ties up a meaningful chunk of the deadline before finally
    /// releasing, that bug let a stderr straggler add a second, nearly-full-length wait on top — up to
    /// ~2x the caller's remaining budget after the caller had already given up.
    ///
    /// The stub script here backgrounds two detached stragglers, one holding each pipe's write end (via
    /// `exec`-redirecting the *other* fd to `/dev/null` inside each subshell, then a second `exec` into
    /// `sleep` so the subshell process is replaced in place rather than forking a child that would hold
    /// the real fds out of reach of the pid captured via `$!` — so each straggler only keeps one pipe
    /// open, under the pid the test can actually kill) and exits immediately itself — the `.exited` branch,
    /// same as the sibling test above. Unlike that test, the stdout straggler here is killed by the test
    /// partway through the drain window (~2s into a 4s deadline) rather than only in cleanup, so the
    /// stdout wait consumes about half the deadline before returning — the scenario that distinguishes
    /// the fix (stderr gets only what remains, ~2s) from the bug (stderr would get a fresh ~4s on top,
    /// pushing total elapsed to ~6s). The stderr straggler is held for the whole run and only killed in
    /// `defer`, so the stderr wait genuinely times out rather than returning early on its own.
    ///
    /// Because the stdout drain does get EOF (the released straggler lets it complete) within its
    /// timeout, `runGitAndCapture` does not throw here — the stub's own exit code is 0 and stdout capture
    /// succeeds with empty output — so this asserts on the call's wall-clock duration rather than on an
    /// error, which is what actually distinguishes the fix from the bug (both paths return successfully;
    /// only the fixed path returns in bounded time).
    func testRunGitAndCaptureRecomputesTheStderrDrainTimeoutFromTheRemainingDeadlineAfterAStdoutStragglerReleasesPartway() throws {
        let root = try makeTempDirectory()
        let scriptURL = root.appendingPathComponent("stub-two-detaching-children.sh")
        let outPidFileURL = root.appendingPathComponent("stdout-holder.pid")
        let errPidFileURL = root.appendingPathComponent("stderr-holder.pid")
        let script = """
            #!/bin/sh
            ( exec 2>/dev/null; exec sleep 30 ) &
            echo $! > "$SPACES_TEST_STDOUT_PIDFILE"
            ( exec 1>/dev/null; exec sleep 30 ) &
            echo $! > "$SPACES_TEST_STDERR_PIDFILE"
            exit 0
            """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let client = RemoteWorkspaceGitClient(
            gitExecutable: scriptURL.path,
            environmentOverrides: [
                "SPACES_TEST_STDOUT_PIDFILE": outPidFileURL.path,
                "SPACES_TEST_STDERR_PIDFILE": errPidFileURL.path,
            ])
        defer {
            Self.killLingeringChild(pidFileURL: outPidFileURL)
            Self.killLingeringChild(pidFileURL: errPidFileURL)
        }

        // Releases the stdout straggler ~2s into a 4s deadline, well before its own budget would
        // otherwise expire, so the stdout wait consumes a meaningful but partial chunk of the deadline
        // before returning. The stderr straggler is left running (killed only in the `defer` above), so
        // whichever timeout the stderr wait actually gets is the one that determines how long this call
        // takes to return.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            Self.killLingeringChild(pidFileURL: outPidFileURL)
        }

        let start = Date()
        let output = try client.runGitAndCapture([], timeout: 4)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(output, "", "the stub produces no stdout, and the stdout drain must have reached EOF once its straggler was killed")
        XCTAssertGreaterThan(elapsed, 3.5, "the call should not return before the stderr straggler's wait has had a chance to run its course")
        XCTAssertLessThan(
            elapsed, 5.5,
            """
            the stderr drain must recompute its timeout from what remains of the deadline (~4s total, one drainGrace of slack) \
            rather than reusing the value computed before the stdout wait (which would add a second near-full timeout on top, ~6s total)
            """
        )
    }

    func testRunGitAndCaptureBoundedModeReturnsOutputNormallyWhenUnderTheCap() throws {
        let fixture = try makeRemoteFixture()
        let client = RemoteWorkspaceGitClient()
        let output = try client.runGitAndCapture(["-C", fixture.source.path, "rev-parse", "HEAD"], maxOutputBytes: 4096)
        XCTAssertFalse(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testRunGitWithFileOutputWritesGitDiffWithoutCapturingStdout() throws {
        let fixture = try makeRemoteFixture()
        let changedFile = fixture.source.appendingPathComponent("README.md")
        try "changed".write(to: changedFile, atomically: true, encoding: .utf8)
        let output = fixture.root.appendingPathComponent("diff.patch")
        let client = RemoteWorkspaceGitClient()

        try client.runGitWithFileOutput(
            ["-C", fixture.source.path, "diff", "--output=\(output.path)", "--no-color", "--", "README.md"], timeout: 5)

        let patch = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(patch.contains("-initial"))
        XCTAssertTrue(patch.contains("+changed"))
    }

    func testRunGitWithFileOutputAllowsGitNoIndexDifferenceExitCode() throws {
        let fixture = try makeRemoteFixture()
        let untracked = fixture.source.appendingPathComponent("UNTRACKED.md")
        try "untracked".write(to: untracked, atomically: true, encoding: .utf8)
        let output = fixture.root.appendingPathComponent("untracked.patch")

        try RemoteWorkspaceGitClient().runGitWithFileOutput(
            [
                "-C", fixture.source.path, "diff", "--no-index", "--output=\(output.path)", "--no-color", "--", "/dev/null", "UNTRACKED.md",
            ], timeout: 5, allowedExitCodes: [0, 1])

        XCTAssertTrue(try String(contentsOf: output, encoding: .utf8).contains("+untracked"))
    }

    func testRunGitWithFileOutputPreservesStderrForRejectedExitCodeAndEnvironmentOverrides() throws {
        let root = try makeTempDirectory()
        let output = root.appendingPathComponent("env.txt")
        let client = RemoteWorkspaceGitClient(gitExecutable: "/bin/sh")

        XCTAssertThrowsError(
            try client.runGitWithFileOutput(
                ["-c", "printf '%s' \"$SPACES_TEST_FILE_OUTPUT\" > \"$SPACES_TEST_OUTPUT_PATH\"; printf '%s' 'expected stderr' >&2; exit 7"],
                timeout: 5, environmentOverrides: ["SPACES_TEST_FILE_OUTPUT": "from environment", "SPACES_TEST_OUTPUT_PATH": output.path]))
        { error in
            guard case .gitCommandFailed(let message)? = error as? SpacesRuntimeError else {
                XCTFail("Expected a git command failure, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("expected stderr"), "Expected stderr in failure, got: \(message)")
        }

        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "from environment")
    }

    func testRunGitWithFileOutputEnforcesTimeoutAndReapsChild() throws {
        let client = RemoteWorkspaceGitClient(gitExecutable: "/bin/sleep")
        let markerSeconds = "784513"
        let start = Date()

        XCTAssertThrowsError(try client.runGitWithFileOutput([markerSeconds], timeout: 1)) { error in
            guard case .gitCommandFailed(let message)? = error as? SpacesRuntimeError else {
                XCTFail("Expected a timeout failure, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("timed out"), "Expected a timeout message, got: \(message)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "the timeout path must reap the child promptly")

        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "sleep \(markerSeconds)"]
        pgrep.standardOutput = Pipe()
        pgrep.standardError = Pipe()
        try pgrep.run()
        pgrep.waitUntilExit()
        XCTAssertNotEqual(pgrep.terminationStatus, 0, "the sleep child must not survive the timeout")
    }

    func testRunGitWithFileOutputDoesNotHangOnADetachedDescendantHoldingStderrOpen() throws {
        let root = try makeTempDirectory()
        let scriptURL = root.appendingPathComponent("stub-file-output-descendant.sh")
        let pidFileURL = root.appendingPathComponent("child.pid")
        let script = """
            #!/bin/sh
            sleep 30 >&2 &
            echo $! > "$SPACES_TEST_FILE_OUTPUT_DRAIN_PIDFILE"
            exit 0
            """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        defer { Self.killLingeringChild(pidFileURL: pidFileURL) }

        let start = Date()
        try RemoteWorkspaceGitClient(
            gitExecutable: scriptURL.path, environmentOverrides: ["SPACES_TEST_FILE_OUTPUT_DRAIN_PIDFILE": pidFileURL.path]
        ).runGitWithFileOutput([], timeout: 3)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "a detached stderr writer must not block file-output completion")
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
