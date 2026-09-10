import Dispatch
import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public enum SpacesRuntimeError: LocalizedError, Equatable {
    case gitCommandFailed(message: String)
    case invalidArgument(message: String)
    /// Thrown by `runGitAndCapture`'s bounded-capture mode when stdout reaches `maxOutputBytes` before the
    /// process finished writing. The process has already been terminated and reaped by the time this is
    /// thrown; callers map it to a truncated result rather than a hard failure.
    case outputExceededCap

    public var errorDescription: String? {
        switch self {
        case .gitCommandFailed(let message): "Git command failed: \(message)"
        case .invalidArgument(let message): "Invalid argument: \(message)"
        case .outputExceededCap: "Git command output exceeded its capture limit."
        }
    }
}

public enum RemoteWorkspaceRefreshBlockReason: String, Codable, Sendable, Equatable {
    case dirtyWorktree
    case untrackedOverwriteRisk
    case divergentHistory
    case missingBranch
    case fetchFailed
    case checkoutFailed
}

public struct RemoteWorkspaceRefreshResult: Codable, Sendable, Equatable {
    public let hostName: String
    public let path: String
    public let branch: String
    public let beforeRevision: String
    public let afterRevision: String
    public let fastForwarded: Bool

    public init(hostName: String, path: String, branch: String, beforeRevision: String, afterRevision: String, fastForwarded: Bool) {
        self.hostName = hostName
        self.path = path
        self.branch = branch
        self.beforeRevision = beforeRevision
        self.afterRevision = afterRevision
        self.fastForwarded = fastForwarded
    }
}

public struct RemoteWorkspaceRefreshBlock: LocalizedError, Sendable, Equatable {
    public let hostName: String
    public let path: String
    public let branch: String
    public let reason: RemoteWorkspaceRefreshBlockReason
    public let detail: String?

    public init(hostName: String, path: String, branch: String, reason: RemoteWorkspaceRefreshBlockReason, detail: String? = nil) {
        self.hostName = hostName
        self.path = path
        self.branch = branch
        self.reason = reason
        self.detail = detail
    }

    public var errorDescription: String? {
        var message = "Remote workspace sync blocked on \(hostName): \(path) at branch \(branch). \(guidance)"
        if let detail, !detail.isEmpty { message += " Detail: \(detail)" }
        return message
    }

    public var guidance: String {
        switch reason {
        case .dirtyWorktree: "Commit, discard, or move local changes on the device before launching."
        case .untrackedOverwriteRisk: "Move or remove untracked files that would be overwritten before launching."
        case .divergentHistory: "Reconcile the remote worktree branch history so it can fast-forward to the workspace branch tip."
        case .missingBranch: "Push the workspace branch or choose a workspace with a branch reachable from the device."
        case .fetchFailed: "Fix remote repository access from the device, then retry."
        case .checkoutFailed: "Fix the remote worktree checkout error on the device, then retry."
        }
    }
}

/// Immutable (only `let` stored properties of Sendable types) and free of shared mutable state — every
/// method spawns its own `git` subprocess — so it is safe to share across threads. `Sendable` lets the
/// daemon hold one instance as a `nonisolated let` and drive git off the main actor from the transport thread.
public final class RemoteWorkspaceGitClient: Sendable {
    public enum RemoteBranchLookupStatus {
        case exists
        case missing
    }

    private let gitExecutable: String
    private let environmentOverrides: [String: String]
    private let metadataCommandTimeout: TimeInterval

    /// The fixed grace every post-observation `PipeDrain.waitForData(timeout:)` call falls back to when
    /// there is no more useful bound to derive (the request had no deadline, or the outcome being reported
    /// — a timeout, a cap overflow — is already decided and the drain is only best-effort at that point).
    /// Long enough that an ordinary process's already-buffered output drains promptly; short enough that a
    /// straggler holding a pipe open cannot meaningfully add to a caller's wait.
    private static let drainGrace: TimeInterval = 2

    public init(gitExecutable: String? = nil, environmentOverrides: [String: String] = [:], metadataCommandTimeout: TimeInterval = 2) {
        self.gitExecutable = gitExecutable ?? Self.resolveGitExecutable(environment: ProcessInfo.processInfo.environment) ?? "git"
        self.environmentOverrides = environmentOverrides
        self.metadataCommandTimeout = metadataCommandTimeout
    }

    public func isRepo(path: String) -> Bool {
        (try? runGitAndCapture(["-C", path, "rev-parse", "--is-inside-work-tree"], timeout: metadataCommandTimeout)) != nil
    }

    /// Distinguishes "git ran and confirmed this isn't a repository" (exits nonzero — typically 128 — a
    /// durable, semantic negative) from "git could not run to completion" (spawn failure, timeout, a wedged
    /// process — transient daemon-side trouble that must not be misreported as the durable negative). Uses
    /// `runGit` (which reports its `Int32` termination status for any completed exit and throws only when
    /// the process could not run to completion) rather than `runGitAndCapture`, precisely because that is
    /// the one primitive in this class that already keeps those two outcomes apart without an `allowedExitCodes`
    /// widening — the same distinction `branchExists`/`hasRemote` already rely on, just without their own
    /// `try?`/`?? 1` collapse of it. `assertIsGitRepository` (SpacesDeviceWorkspaceGit.swift) calls this
    /// instead of `isRepo` so an execution failure surfaces as the existing retryable `gitCommandFailed` →
    /// `internalError` wire shape instead of misreporting a durable "not a repo" rejection (`invalidArgument`)
    /// for what might just be a daemon hiccup. `isRepo` itself is left untouched for its other callers.
    public func isRepoStrict(path: String) throws -> Bool {
        try runGit(["-C", path, "rev-parse", "--is-inside-work-tree"], timeout: metadataCommandTimeout) == 0
    }

    public func branchExists(path: String, branch: String) -> Bool {
        let status = (try? runGit(["-C", path, "show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], timeout: metadataCommandTimeout)) ?? 1
        return status == 0
    }

    public func hasRemote(path: String, name: String = "origin") -> Bool {
        let status = (try? runGit(["-C", path, "remote", "get-url", name], timeout: metadataCommandTimeout)) ?? 1
        return status == 0
    }

    public func remoteBranchLookupStatus(path: String, branch: String) throws -> RemoteBranchLookupStatus {
        guard hasRemote(path: path) else { return .missing }
        let arguments = ["-C", path, "ls-remote", "--exit-code", "--heads", "origin", branch]
        let process = makeGitProcess(arguments)
        process.standardOutput = Pipe()
        let err = Pipe()
        process.standardError = err
        let termination = try launch(process)
        defer { process.terminationHandler = nil }
        try waitForProcess(process, termination: termination, timeout: metadataCommandTimeout, arguments: arguments)
        switch process.terminationStatus {
        case 0: return .exists
        case 2: return .missing
        default:
            // `waitForProcess` has already returned (the process exited, or was killed on its own
            // `metadataCommandTimeout`), but a descendant it spawned and detached can still hold stderr's
            // write end open — the same exposure `runGitAndCapture`'s drains are bounded against above.
            // `readDataToEndOfFile()` has no timeout of its own, so it is replaced with a bounded
            // `PipeDrain` wait rather than left to block on a straggler indefinitely.
            let errData = PipeDrain(err).waitForData(timeout: Self.drainGrace) ?? Data()
            let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            throw SpacesRuntimeError.gitCommandFailed(message: message)
        }
    }

    public func refreshWorktreeFastForwardOnly(path worktreePath: String, branch: String, hostName: String) throws -> RemoteWorkspaceRefreshResult {
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty else { throw SpacesRuntimeError.invalidArgument(message: "Workspace branch is required.") }
        try blockIfDirtyWorktree(path: worktreePath, branch: trimmedBranch, hostName: hostName)
        let beforeRevision = try revision(path: worktreePath, ref: "HEAD")
        do {
            switch try remoteBranchLookupStatus(path: worktreePath, branch: trimmedBranch) {
            case .exists: break
            case .missing:
                throw RemoteWorkspaceRefreshBlock(
                    hostName: hostName, path: worktreePath, branch: trimmedBranch, reason: .missingBranch,
                    detail: "origin/\(trimmedBranch) does not exist.")
            }
        } catch let block as RemoteWorkspaceRefreshBlock { throw block } catch {
            throw remoteRefreshBlock(hostName: hostName, path: worktreePath, branch: trimmedBranch, reason: .fetchFailed, error: error)
        }
        do { try fetchRemoteBranch(path: worktreePath, branch: trimmedBranch) } catch {
            throw remoteRefreshBlock(hostName: hostName, path: worktreePath, branch: trimmedBranch, reason: .fetchFailed, error: error)
        }

        let remoteRef = "refs/remotes/origin/\(trimmedBranch)"
        let currentBranch = try currentBranchName(path: worktreePath)
        if currentBranch != trimmedBranch {
            try blockIfUntrackedFilesWouldBeOverwritten(path: worktreePath, branch: trimmedBranch, hostName: hostName, targetRef: remoteRef)
            try checkoutBranch(path: worktreePath, branch: trimmedBranch, hostName: hostName, remoteRef: remoteRef)
        }

        let remoteRevision = try revision(path: worktreePath, ref: remoteRef)
        let currentRevision = try revision(path: worktreePath, ref: "HEAD")
        if currentRevision == remoteRevision {
            return RemoteWorkspaceRefreshResult(
                hostName: hostName, path: worktreePath, branch: trimmedBranch, beforeRevision: beforeRevision, afterRevision: currentRevision,
                fastForwarded: beforeRevision != currentRevision)
        }
        guard try isAncestor(path: worktreePath, ancestor: "HEAD", descendant: remoteRef) else {
            throw RemoteWorkspaceRefreshBlock(
                hostName: hostName, path: worktreePath, branch: trimmedBranch, reason: .divergentHistory,
                detail: "HEAD is not an ancestor of origin/\(trimmedBranch).")
        }
        try blockIfUntrackedFilesWouldBeOverwritten(path: worktreePath, branch: trimmedBranch, hostName: hostName, targetRef: remoteRef)
        do { try runGitOrThrow(["-C", worktreePath, "merge", "--ff-only", remoteRef]) } catch {
            throw remoteRefreshBlock(hostName: hostName, path: worktreePath, branch: trimmedBranch, reason: .checkoutFailed, error: error)
        }
        let afterRevision = try revision(path: worktreePath, ref: "HEAD")
        return RemoteWorkspaceRefreshResult(
            hostName: hostName, path: worktreePath, branch: trimmedBranch, beforeRevision: beforeRevision, afterRevision: afterRevision,
            fastForwarded: beforeRevision != afterRevision)
    }

    /// `allowedExitCodes` exists for commands like `git diff --no-index`, whose exit-code contract is
    /// `--exit-code` semantics (0 = no difference, 1 = difference found, >1 = error) rather than the usual
    /// "0 = success" every other caller relies on; the default keeps every existing call site unchanged.
    ///
    /// `maxOutputBytes`, when set, bounds how much of stdout is captured: once more than that many bytes
    /// have been read, the capture closes its end of stdout and reports the overflow rather than reading to
    /// EOF. A process whose remaining output would exceed the cap is then writing into a pipe with no
    /// reader, so it is terminated and reaped here rather than risking a hang; the throw carries no exit
    /// code because the termination made one meaningless. Passing `nil` (the default) keeps the unbounded
    /// behavior every existing call site relies on.
    ///
    /// Both pipes are read on the calling thread by `readCapturedStreams`, one `poll(2)` loop over stdout,
    /// stderr, and the termination waiter's own descriptor. Nothing here sleeps, polls a process state, or
    /// hands a pipe to a background thread, because both of those cost a thread hop per command: a drain
    /// thread has to be scheduled before its first read, and a `Thread.sleep` loop watching
    /// `Process.isRunning` wakes late under load, which together made a captured command that finishes in
    /// about 13 ms take about 290 ms end to end while the same client's file-output path took 6 ms. Reading
    /// inline keeps both streams drained concurrently (which is what the pipe buffer requires: a child that
    /// writes more than 64 KiB to one pipe blocks until it is read, so waiting on either stream alone
    /// deadlocks against the child) and returns as soon as the kernel says the data is there.
    ///
    /// Every wait is bounded, because a descendant the process spawns and detaches (git's
    /// `fsmonitor--daemon`, which `git status` can launch under `core.fsmonitor`, is the observed case)
    /// inherits the pipes' write ends and can hold them open long after git itself exits, so EOF alone is
    /// not something a caller can be made to wait for. `timeout` bounds the whole capture; once the child's
    /// exit is observed, the loop allows at least `Self.drainGrace` past that point for output already in
    /// flight, which is what lets a command that exits at the deadline's edge still report what it wrote.
    /// `environmentOverrides` here (distinct from the per-instance `environmentOverrides` set at `init`) is
    /// a per-call addition, for the one caller (the workspace-diff engine's temp-index coalescing of a
    /// deleted-but-recreated-untracked path) that needs a scratch `GIT_INDEX_FILE` scoped to a single
    /// invocation rather than every command this shared, long-lived client instance ever runs. The
    /// per-instance overrides are applied first so a per-call value always wins if both set the same key.
    public func runGitAndCapture(
        _ arguments: [String], timeout: TimeInterval? = nil, allowedExitCodes: Set<Int32> = [0], maxOutputBytes: Int? = nil,
        environmentOverrides callEnvironmentOverrides: [String: String] = [:]
    ) throws -> String {
        String(decoding: try runGitAndCaptureData(
            arguments, timeout: timeout, allowedExitCodes: allowedExitCodes, maxOutputBytes: maxOutputBytes,
            environmentOverrides: callEnvironmentOverrides), as: UTF8.self)
    }

    /// Runs Git with the same bounded stdout capture and error semantics as `runGitAndCapture`, preserving
    /// stdout as raw bytes. Callers that read blob content must use this rather than a lossy text conversion.
    public func runGitAndCaptureData(
        _ arguments: [String], timeout: TimeInterval? = nil, allowedExitCodes: Set<Int32> = [0], maxOutputBytes: Int? = nil,
        environmentOverrides callEnvironmentOverrides: [String: String] = [:]
    ) throws -> Data {
        let process = makeGitProcess(arguments, environmentOverrides: callEnvironmentOverrides)
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let termination = try launch(process)
        defer { process.terminationHandler = nil }
        let commandDescription = ([gitExecutable] + arguments).joined(separator: " ")
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        var stdout = CapturedStream(out.fileHandleForReading)
        var stderr = CapturedStream(err.fileHandleForReading)

        switch try readCapturedStreams(
            stdout: &stdout, stderr: &stderr, termination: termination, deadline: deadline, maxOutputBytes: maxOutputBytes)
        {
        case .capExceeded:
            // Our end of stdout is closed, so the child's next write fails instead of blocking on a pipe with
            // no reader, and it is killed rather than waited on. Its stderr is deliberately not drained
            // first: the overflow is the outcome being reported and that text is never read by anyone.
            terminateThenKill(process)
            process.waitUntilExit()
            throw SpacesRuntimeError.outputExceededCap
        case .deadlineWhileRunning:
            terminateThenKill(process)
            process.waitUntilExit()
            throw SpacesRuntimeError.gitCommandFailed(message: "Git command timed out after \(timeout ?? 0)s: \(commandDescription)")
        case .stdoutHeldOpenAfterExit:
            // git exited but something it spawned still holds stdout open, so the output would be
            // indeterminate anyway (there is no way to tell how much more, if any, git itself had written
            // before exiting). Reported the same way an outright process timeout is.
            throw SpacesRuntimeError.gitCommandFailed(
                message:
                    "Git command timed out after \(timeout ?? 0)s: \(commandDescription) (a spawned descendant kept a pipe open after exit)")
        case .finished:
            break
        }

        // stdout reached EOF, which a child normally does by exiting, so this returns immediately. The
        // bound covers the child that closes its pipes and keeps running: it gets the rest of its deadline,
        // floored at one `drainGrace` so a command finishing at the deadline's edge is not killed for it.
        guard termination.wait(timeout: deadline.map { max(Self.drainGrace, $0.timeIntervalSinceNow) }) else {
            terminateThenKill(process)
            process.waitUntilExit()
            throw SpacesRuntimeError.gitCommandFailed(message: "Git command timed out after \(timeout ?? 0)s: \(commandDescription)")
        }
        process.waitUntilExit()
        guard allowedExitCodes.contains(process.terminationStatus) else {
            let message = String(data: stderr.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            throw SpacesRuntimeError.gitCommandFailed(message: message)
        }
        return stdout.data
    }

    /// How a capture's read loop ended. Each case is one of the outcomes `runGitAndCaptureData` reports; the
    /// loop itself never kills or reaps the process, so the decision and the cleanup stay in one place.
    private enum CaptureOutcome {
        /// Both streams reached EOF, or stdout did and the bounded window for stderr expired.
        case finished
        /// Stdout went past `maxOutputBytes`; the capture has already closed its end of it.
        case capExceeded
        /// The window expired while the child was still running.
        case deadlineWhileRunning
        /// The child exited, but stdout never reached EOF inside the window that followed.
        case stdoutHeldOpenAfterExit
    }

    /// Reads both pipes until they reach EOF, the byte cap trips, or the window runs out, waking on exactly
    /// three things: stdout readable, stderr readable, and the child's exit (the termination waiter's
    /// descriptor becomes readable, so no state has to be polled to notice it).
    ///
    /// The window is the caller's `deadline` until the exit is observed, and from then on whichever is later
    /// of the deadline and one `drainGrace` past the exit. Stdout and stderr are then treated differently
    /// when that window expires, which is the asymmetry the callers need: stdout is the command's result, so
    /// a stdout that never reaches EOF is reported rather than silently truncated, while stderr only
    /// decorates a rejected exit status, so a straggler holding it open leaves the message short instead of
    /// failing a command that otherwise succeeded.
    private func readCapturedStreams(
        stdout: inout CapturedStream, stderr: inout CapturedStream, termination: ProcessTerminationWaiter, deadline: Date?, maxOutputBytes: Int?
    ) throws -> CaptureOutcome {
        var postExitDeadline: Date?
        while !(stdout.isClosed && stderr.isClosed) {
            let now = Date()
            if let window = postExitDeadline ?? deadline, now >= window {
                guard termination.hasTerminated else { return .deadlineWhileRunning }
                return stdout.isClosed ? .finished : .stdoutHeldOpenAfterExit
            }
            var descriptors: [pollfd] = []
            if !stdout.isClosed { descriptors.append(pollfd(fd: stdout.descriptor, events: Int16(POLLIN), revents: 0)) }
            if !stderr.isClosed { descriptors.append(pollfd(fd: stderr.descriptor, events: Int16(POLLIN), revents: 0)) }
            // Dropped from the set once the exit has been observed: the byte it carries is never read, so a
            // descriptor left in the set would report readable forever and spin this loop.
            if postExitDeadline == nil { descriptors.append(pollfd(fd: termination.exitDescriptor, events: Int16(POLLIN), revents: 0)) }
            let milliseconds = (postExitDeadline ?? deadline).map { Int32(max(0, ($0.timeIntervalSince(now) * 1000).rounded(.up))) } ?? -1
            let ready = descriptors.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), milliseconds) }
            if ready < 0 {
                if errno == EINTR { continue }
                throw SpacesRuntimeError.gitCommandFailed(message: "Waiting for a git command's output failed: errno \(errno)")
            }
            for descriptor in descriptors where descriptor.revents != 0 {
                if descriptor.fd == stdout.descriptor {
                    try stdout.readAvailable()
                } else if descriptor.fd == stderr.descriptor {
                    try stderr.readAvailable()
                } else {
                    postExitDeadline = max(Date().addingTimeInterval(Self.drainGrace), deadline ?? .distantPast)
                }
            }
            if let maxOutputBytes, stdout.data.count > maxOutputBytes {
                stdout.close()
                return .capExceeded
            }
        }
        return .finished
    }

    /// Spawns `process` with a termination waiter already attached, which is how every path in this client
    /// learns a child exited: the handler must be installed before the process runs, or a child that exits
    /// immediately can finish before anything is listening.
    private func launch(_ process: Process) throws -> ProcessTerminationWaiter {
        let termination = try ProcessTerminationWaiter()
        process.terminationHandler = { _ in termination.signal() }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            throw error
        }
        return termination
    }

    /// Runs a Git command whose useful payload is written to a file by the command itself (for example,
    /// `git diff --output=...`). Stdout is redirected to `/dev/null`, so this path does not allocate a
    /// capture buffer or a drain thread for bytes the caller will never read. Stderr is still drained on
    /// one background thread: an error-producing command, or a descendant that inherits the descriptor,
    /// must not deadlock the process while the caller waits for termination.
    ///
    /// The termination handler replaces `runGitAndCapture`'s 10 ms process-state polling. Timeout cleanup
    /// retains the same terminate/escalate/reap sequence. The bounded stderr wait lets the caller return
    /// when a detached descendant keeps stderr open; the drain thread and pipe remain until that descendant
    /// closes its inherited descriptor, without making a successful file-output command pay for an unused
    /// stdout drain.
    public func runGitWithFileOutput(
        _ arguments: [String], timeout: TimeInterval? = nil, allowedExitCodes: Set<Int32> = [0],
        environmentOverrides callEnvironmentOverrides: [String: String] = [:]
    ) throws {
        let process = makeGitProcess(arguments, environmentOverrides: callEnvironmentOverrides)
        let err = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = err
        let termination = try launch(process)
        defer { process.terminationHandler = nil }
        let errDrain = PipeDrain(err)

        guard termination.wait(timeout: timeout) else {
            terminateThenKill(process)
            process.waitUntilExit()
            _ = errDrain.waitForData(timeout: Self.drainGrace)
            let commandDescription = ([gitExecutable] + arguments).joined(separator: " ")
            throw SpacesRuntimeError.gitCommandFailed(
                message: "Git command timed out after \(timeout ?? 0)s: \(commandDescription)")
        }

        process.waitUntilExit()
        let errData = errDrain.waitForData(timeout: Self.drainGrace) ?? Data()
        guard allowedExitCodes.contains(process.terminationStatus) else {
            let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            throw SpacesRuntimeError.gitCommandFailed(message: message)
        }
    }

    private func runGit(_ arguments: [String], timeout: TimeInterval? = nil) throws -> Int32 {
        let process = makeGitProcess(arguments)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        let termination = try launch(process)
        defer { process.terminationHandler = nil }
        try waitForProcess(process, termination: termination, timeout: timeout, arguments: arguments)
        return process.terminationStatus
    }

    private func runGitOrThrow(_ arguments: [String]) throws {
        let process = makeGitProcess(arguments)
        let err = Pipe()
        process.standardOutput = Pipe()
        process.standardError = err

        let termination = try launch(process)
        defer { process.terminationHandler = nil }
        try waitForProcess(process, termination: termination, timeout: nil, arguments: arguments)

        if process.terminationStatus != 0 {
            // Same exposure as `remoteBranchLookupStatus` above: the process has already exited by the time
            // this runs, but a descendant it spawned and detached can still hold stderr's write end open, so
            // an unbounded `readDataToEndOfFile()` here could block forever on a straggler even though git
            // itself is long gone. Bounded via `PipeDrain` instead.
            let errData = PipeDrain(err).waitForData(timeout: Self.drainGrace) ?? Data()
            let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
            throw SpacesRuntimeError.gitCommandFailed(message: message)
        }
    }

    private func fetchRemoteBranch(path: String, branch: String) throws {
        try runGitOrThrow(["-C", path, "fetch", "origin", "refs/heads/\(branch):refs/remotes/origin/\(branch)"])
    }

    private func blockIfDirtyWorktree(path: String, branch: String, hostName: String) throws {
        let status = try runGitAndCapture(["-C", path, "status", "--porcelain=v1", "--untracked-files=no"]).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard status.isEmpty else {
            throw RemoteWorkspaceRefreshBlock(hostName: hostName, path: path, branch: branch, reason: .dirtyWorktree, detail: status)
        }
    }

    private func blockIfUntrackedFilesWouldBeOverwritten(path: String, branch: String, hostName: String, targetRef: String) throws {
        let changedPaths = Set(
            try runGitAndCapture(["-C", path, "diff", "--name-only", "--diff-filter=ACDMRTUXB", "HEAD..\(targetRef)"]).split(separator: "\n").map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty })
        guard !changedPaths.isEmpty else { return }
        let untrackedPaths = Set(
            try runGitAndCapture(["-C", path, "ls-files", "--others", "--exclude-standard"]).split(separator: "\n").map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty })
        let conflicts = changedPaths.intersection(untrackedPaths).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard conflicts.isEmpty else {
            throw RemoteWorkspaceRefreshBlock(
                hostName: hostName, path: path, branch: branch, reason: .untrackedOverwriteRisk,
                detail: "Untracked files would be overwritten: \(conflicts.joined(separator: ", "))")
        }
    }

    private func checkoutBranch(path: String, branch: String, hostName: String, remoteRef: String) throws {
        let arguments =
            branchExists(path: path, branch: branch)
            ? ["-C", path, "checkout", branch] : ["-C", path, "checkout", "-b", branch, "--track", remoteRef]
        do { try runGitOrThrow(arguments) } catch {
            let reason =
                gitErrorMessage(error).contains("untracked working tree files would be overwritten")
                ? RemoteWorkspaceRefreshBlockReason.untrackedOverwriteRisk : .checkoutFailed
            throw remoteRefreshBlock(hostName: hostName, path: path, branch: branch, reason: reason, error: error)
        }
    }

    private func currentBranchName(path: String) throws -> String {
        try runGitAndCapture(["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func revision(path: String, ref: String) throws -> String {
        try runGitAndCapture(["-C", path, "rev-parse", "--verify", "\(ref)^{commit}"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isAncestor(path: String, ancestor: String, descendant: String) throws -> Bool {
        let status = try runGit(["-C", path, "merge-base", "--is-ancestor", ancestor, descendant])
        switch status {
        case 0: return true
        case 1: return false
        default: throw SpacesRuntimeError.gitCommandFailed(message: "merge-base exited with status \(status)")
        }
    }

    private func remoteRefreshBlock(hostName: String, path: String, branch: String, reason: RemoteWorkspaceRefreshBlockReason, error: any Error)
        -> RemoteWorkspaceRefreshBlock
    { RemoteWorkspaceRefreshBlock(hostName: hostName, path: path, branch: branch, reason: reason, detail: gitErrorMessage(error)) }

    private func gitErrorMessage(_ error: any Error) -> String {
        if case SpacesRuntimeError.gitCommandFailed(let message) = error { return message }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private func makeGitProcess(_ arguments: [String], environmentOverrides callEnvironmentOverrides: [String: String] = [:]) -> Process {
        let process = Process()
        if gitExecutable.contains("/") {
            process.executableURL = URL(fileURLWithPath: gitExecutable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [gitExecutable] + arguments
        }
        process.environment = gitEnvironment(callEnvironmentOverrides)
        return process
    }

    private func gitEnvironment(_ callEnvironmentOverrides: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "GIT_DIR")
        environment.removeValue(forKey: "GIT_WORK_TREE")
        environment.removeValue(forKey: "GIT_INDEX_FILE")
        for (key, value) in environmentOverrides { environment[key] = value }
        for (key, value) in callEnvironmentOverrides { environment[key] = value }
        return environment
    }

    /// Waits for a process whose stdout nobody captures (the status-only probes and the refresh commands).
    /// The wait is the termination waiter's condition variable rather than a `Thread.sleep` loop on
    /// `Process.isRunning`: a sleeping thread is woken late under load, which put roughly 0.15 s of pure
    /// scheduling wait on every one of these probes, and `isRepoStrict` runs one per file listing.
    private func waitForProcess(_ process: Process, termination: ProcessTerminationWaiter, timeout: TimeInterval?, arguments: [String]) throws {
        guard termination.wait(timeout: timeout) else {
            terminateThenKill(process)
            process.waitUntilExit()
            let commandDescription = ([gitExecutable] + arguments).joined(separator: " ")
            throw SpacesRuntimeError.gitCommandFailed(message: "Git command timed out after \(timeout ?? 0)s: \(commandDescription)")
        }
        process.waitUntilExit()
    }

    private static func resolveGitExecutable(environment: [String: String]) -> String? {
        let preferredAbsolutePaths = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git", "/opt/local/bin/git"]
        let defaultPATH = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin"
        let mergedPATH = [environment["PATH"], defaultPATH].compactMap { $0 }.joined(separator: ":")
        var candidates: [String] = []
        var seen = Set<String>()

        func append(_ path: String) {
            guard !path.isEmpty, seen.insert(path).inserted else { return }
            candidates.append(path)
        }

        for directory in mergedPATH.split(separator: ":").map(String.init) where !directory.isEmpty {
            append(URL(fileURLWithPath: directory).appending(path: "git").path)
        }
        for path in preferredAbsolutePaths { append(path) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// `Process.terminate()` sends SIGTERM, which a wedged or SIGTERM-ignoring child may never act on; escalating
/// to SIGKILL after a brief grace period guarantees the child is actually gone before a caller blocks on its
/// pipes reaching EOF, rather than trading one indefinite wait (the original deadline) for another
/// (`terminate` silently doing nothing).
private func terminateThenKill(_ process: Process, gracePeriod: TimeInterval = 0.5) {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(gracePeriod)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
    }
}

/// Receives `Process.terminationHandler` without polling or relying on a semaphore whose signal can race
/// the caller abandoning a timed wait. A condition variable permits a late termination signal after a
/// timeout without retaining a dispatch primitive in an unmatched state.
///
/// Termination is also published as a readable file descriptor, so `readCapturedStreams` can wait for the
/// child's exit in the same `poll(2)` call that waits for its output instead of checking a flag on a timer.
/// The descriptor is the read end of a pipe whose write end is written to and closed exactly once, by
/// `signal`; the byte is never read, so the descriptor stays readable from then on and a caller that has
/// already seen the exit simply stops asking about it.
private final class ProcessTerminationWaiter: @unchecked Sendable {
    private let condition = NSCondition()
    private var terminated = false
    private let notificationLock = NSLock()
    private let readDescriptor: Int32
    private var writeDescriptor: Int32

    /// Throws when the process cannot get its notification pipe, which means the daemon is out of file
    /// descriptors: a command that cannot observe its own child's exit has no honest way to run.
    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else {
            throw SpacesRuntimeError.gitCommandFailed(message: "Could not create a pipe to observe a git command's exit: errno \(errno)")
        }
        readDescriptor = descriptors[0]
        writeDescriptor = descriptors[1]
        // The child inherits open descriptors, and a copy of the write end in the child would keep the pipe
        // alive past the parent's own close; close-on-exec keeps both ends out of it entirely.
        _ = fcntl(readDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeDescriptor, F_SETFD, FD_CLOEXEC)
    }

    deinit {
        close(readDescriptor)
        notificationLock.lock()
        if writeDescriptor >= 0 { close(writeDescriptor) }
        notificationLock.unlock()
    }

    /// Readable once the process has terminated, for a `poll` set that is already waiting on its pipes.
    var exitDescriptor: Int32 { readDescriptor }

    var hasTerminated: Bool {
        condition.lock()
        defer { condition.unlock() }
        return terminated
    }

    func signal() {
        condition.lock()
        terminated = true
        condition.broadcast()
        condition.unlock()
        notificationLock.lock()
        if writeDescriptor >= 0 {
            var byte: UInt8 = 1
            _ = write(writeDescriptor, &byte, 1)
            close(writeDescriptor)
            writeDescriptor = -1
        }
        notificationLock.unlock()
    }

    func wait(timeout: TimeInterval?) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard let timeout else {
            while !terminated { condition.wait() }
            return true
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !terminated {
            // `wait(until:)` reacquires the condition lock before returning. A timeout and termination
            // signal can race at the deadline, so inspect the state again rather than treating a false
            // return as authoritative.
            if !condition.wait(until: deadline) {
                return terminated
            }
        }
        return true
    }
}

/// One of a captured command's two pipes, read on the calling thread. `poll` says when there is something
/// to read and this reads it, so nothing waits on a thread that has to be scheduled first.
///
/// The descriptor is switched to non-blocking: `poll` reporting readable is not a promise that a read of any
/// particular size can complete, and one blocking read on a pipe the child has gone quiet on would stall the
/// whole capture, deadline included. Exactly one read happens per readiness, so a stream with a lot to say
/// comes back through the loop rather than being drained in place while its sibling waits.
private struct CapturedStream {
    let descriptor: Int32
    private let handle: FileHandle
    private(set) var data = Data()
    /// Set when the writer closed its end (EOF) or this capture closed its own, which is the only reason the
    /// loop stops asking about a stream.
    private(set) var isClosed = false

    init(_ handle: FileHandle) {
        self.handle = handle
        descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }

    mutating func readAvailable() throws {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                buffer.withUnsafeBufferPointer { data.append($0.baseAddress!, count: count) }
                return
            }
            if count == 0 {
                isClosed = true
                return
            }
            if errno == EINTR { continue }
            // Nothing left for now, which is the normal end of a readiness: the loop waits again.
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            throw SpacesRuntimeError.gitCommandFailed(message: "Reading a git command's output failed: errno \(errno)")
        }
    }

    /// Closes this end so the child's next write fails rather than blocking on a pipe with no reader. Used by
    /// the byte cap, which is the one case where a capture stops reading a stream the child is still writing.
    mutating func close() {
        handle.closeFile()
        isClosed = true
    }
}

/// Drains one `Pipe`'s read end on a background thread starting immediately after the process launches,
/// rather than after it exits. `Process.waitUntilExit()` blocks until the child closes its stdout/stderr
/// fds (normally at exit); a child that writes more than the pipe's kernel buffer (64 KiB on macOS) to a
/// pipe nobody is reading blocks on that `write()` until it is drained, so a caller that waits for exit
/// before reading deadlocks against its own child for any output past that size.
///
/// This serves the paths whose payload is not captured, where stderr is read only to quote a failure: the
/// file-output command, the status-only probes, and the refresh commands. A capture reads its pipes inline
/// instead (see `CapturedStream`), since a thread that has to be scheduled before its first read costs more
/// than the commands themselves take.
///
/// `@unchecked Sendable`: `data` is only mutated inside the one background read and only read after
/// `waitForData(timeout:)` observes `finished`, which happens-after the drain thread's final write by way of
/// the same `condition` lock both sides take, and that hand-off is the synchronization the compiler cannot
/// see.
private final class PipeDrain: @unchecked Sendable {
    private var data = Data()
    /// Guards `finished`, and (by the happens-before edge any lock/unlock pair provides) orders the drain
    /// thread's final write to `data` before a caller's read of it in `waitForData(timeout:)`.
    ///
    /// This used to be a `DispatchSemaphore(value: 0)`, signaled once by the drain thread and waited on
    /// unconditionally by the caller. That shape cannot support a *bounded* wait safely: `DispatchSemaphore`
    /// requires every `signal()` to eventually be matched by a `wait()` before the semaphore is deallocated,
    /// or the runtime traps ("BUG IN CLIENT OF LIBDISPATCH: Semaphore object deallocated while in use"). A
    /// caller that gives up on `waitForData(timeout:)` after its deadline consumes nothing, so the drain
    /// thread's own later `signal()` — once the straggler holding the pipe finally lets it reach EOF — would
    /// be an unmatched signal against a semaphore whose last reference (via the drain `Thread`'s own capture
    /// of `self`) is about to go away with no further `wait()` ever coming. `NSCondition` has no such
    /// requirement: a `signal()` nobody is listening for is simply a no-op, so an abandoned drain thread can
    /// finish and let this object deinit normally with no special-casing required at the call site.
    private let condition = NSCondition()
    private var finished = false
    /// The drain runs on a dedicated `Thread`, never a GCD queue: `waitForData(timeout:)` blocks its caller
    /// on a condition variable, and when many of these run concurrently those blocked callers occupy
    /// dispatch's worker threads, at which point GCD can stop granting threads to global-queue work items,
    /// including the drain closures whose signals would unblock them. That starvation deadlocked a parallel
    /// test run indefinitely (every worker parked waiting, both drain closures never scheduled). A dedicated
    /// thread is guaranteed to run regardless of dispatch pool pressure.
    init(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        let thread = Thread { [self] in
            data = handle.readDataToEndOfFile()
            condition.lock()
            finished = true
            condition.signal()
            condition.unlock()
        }
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Waits until the drain thread reaches EOF or `timeout` elapses, whichever comes first. Returns the captured data if the drain finished within the
    /// window, or `nil` on expiry.
    ///
    /// On expiry the drain thread is deliberately left running rather than torn down: it is blocked in a
    /// blocking read on the pipe's read end (`readDataToEndOfFile()`), and closing that
    /// fd out from under a thread blocked reading it is the racy alternative this rejects — a closed fd
    /// number can be reused by an unrelated file or socket opened concurrently elsewhere in the process, so
    /// a `close()` from another thread while a `read()` on the same fd is in flight risks tearing down that
    /// unrelated resource instead. Abandoning the thread costs one thread and one held-open pipe fd for
    /// exactly as long as the straggler that inherited the write end (git's `fsmonitor--daemon`, a
    /// detaching helper `git status` can launch under `core.fsmonitor`, is the concrete case observed) keeps
    /// running — bounded by the straggler's own lifetime, not indefinite — which is judged an acceptable
    /// cost against the alternative of the caller's request never returning at all. Once the straggler
    /// finally exits or closes its copy of the fd, the abandoned thread's read returns EOF, `finished` is
    /// set, and it exits normally like any other drain.
    func waitForData(timeout: TimeInterval) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !finished {
            guard condition.wait(until: deadline) else { return nil }
        }
        return data
    }
}
