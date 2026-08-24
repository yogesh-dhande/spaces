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
        try process.run()
        try waitForProcess(process, timeout: metadataCommandTimeout, arguments: arguments)
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
    /// `maxOutputBytes`, when set, bounds how much of stdout is captured: once that many bytes have been
    /// read, `PipeDrain` stops draining and reports the overflow rather than reading to EOF. A process
    /// whose remaining output would exceed the cap is then still writing into a pipe nobody is draining, so
    /// it is terminated and reaped here rather than risking a hang; the throw carries no exit code because
    /// the termination made one meaningless. Passing `nil` (the default) keeps the unbounded behavior every
    /// existing call site relies on.
    ///
    /// The process deadline is enforced before anything blocks on the drains reaching EOF:
    /// `awaitProcessExitOrCapOverflow` polls `process.isRunning`, `outDrain.didExceedCap`, and `timeout`
    /// concurrently, so a subprocess that stops producing output without exiting or closing its pipes is
    /// still caught by `timeout` rather than hanging the caller waiting for `PipeDrain.waitForData(timeout:)`
    /// to reach EOF on its own — and every wait on a drain below is itself bounded for the same reason a
    /// straggler descendant of the process can hold a pipe's write end open past the process's own exit or
    /// kill (see `Self.drainGrace` and the per-branch comments below). The drains themselves start reading
    /// in the background the moment each
    /// `PipeDrain` is created, well before this wait begins, so this reordering does not reintroduce the
    /// large-output deadlock `PipeDrain` exists to avoid: a big `git diff` keeps draining concurrently while
    /// this method waits for the process (or the cap, or the deadline), and `waitForData()` is only called
    /// once the child is already dead or dying, at which point both pipes hit EOF promptly.
    /// `environmentOverrides` here (distinct from the per-instance `environmentOverrides` set at `init`) is
    /// a per-call addition, for the one caller (the workspace-diff engine's temp-index coalescing of a
    /// deleted-but-recreated-untracked path) that needs a scratch `GIT_INDEX_FILE` scoped to a single
    /// invocation rather than every command this shared, long-lived client instance ever runs. The
    /// per-instance overrides are applied first so a per-call value always wins if both set the same key.
    public func runGitAndCapture(
        _ arguments: [String], timeout: TimeInterval? = nil, allowedExitCodes: Set<Int32> = [0], maxOutputBytes: Int? = nil,
        environmentOverrides callEnvironmentOverrides: [String: String] = [:]
    ) throws -> String {
        let process = makeGitProcess(arguments, environmentOverrides: callEnvironmentOverrides)
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outDrain = PipeDrain(out, maxBytes: maxOutputBytes)
        let errDrain = PipeDrain(err)
        let commandDescription = ([gitExecutable] + arguments).joined(separator: " ")
        // Every post-observation drain wait below is bounded, never unconditional: a descendant the git
        // process spawns and detaches (the concrete case is `fsmonitor--daemon`, which `git status` can
        // launch under `core.fsmonitor`, and which does not exit when its parent does) inherits the pipes'
        // write ends and can hold them open indefinitely, so EOF never arrives on the read end `PipeDrain`
        // is blocked in. Before this fix `waitForData()` was unconditional, so a straggler like that made
        // even the *timeout* branch below hang forever waiting on a process nobody was timing out anymore.
        // `deadline` mirrors the same request-wide deadline `awaitProcessExitOrCapOverflow`'s poll loop
        // uses, so the `.exited` branch's drain wait cannot itself outlive the time budget the caller
        // already agreed to wait for this command.
        let deadline = timeout.map { Date().addingTimeInterval($0) }

        switch awaitProcessExitOrCapOverflow(process, outDrain: outDrain, timeout: timeout) {
        case .capExceeded:
            // Stdout drain stopped as soon as the cap was hit and closed its end; the child may still be
            // blocked mid-`write()`, so it must be killed rather than waited on. `errDrain` is safe to drain
            // fully here: a process this far over its stdout cap emits little stderr. Bounded to a short,
            // fixed grace regardless of the request's own timeout — the cap overflow is already a decided
            // outcome, so a straggler holding stderr open must not turn "report the overflow" into another
            // indefinite wait for stderr text nobody ends up reading anyway.
            terminateThenKill(process)
            _ = errDrain.waitForData(timeout: Self.drainGrace)
            process.waitUntilExit()
            throw SpacesRuntimeError.outputExceededCap
        case .timedOut:
            terminateThenKill(process)
            process.waitUntilExit()
            // The child is dead now, so both pipes hit EOF promptly *unless* a surviving descendant still
            // holds them — bounded to a short, fixed grace so that straggler cannot turn the timeout path
            // itself into a second, unbounded hang. Neither drain's content is used below (the timeout
            // message never quotes stderr), so an expired grace here changes nothing about what is thrown.
            _ = outDrain.waitForData(timeout: Self.drainGrace)
            _ = errDrain.waitForData(timeout: Self.drainGrace)
            throw SpacesRuntimeError.gitCommandFailed(message: "Git command timed out after \(timeout ?? 0)s: \(commandDescription)")
        case .exited:
            // This wait is not a latency floor on successful commands: `Process` closes the parent-side
            // copies of the child's pipe fds at spawn (the same behavior the canonical
            // `readDataToEndOfFile` pattern relies on), so once the child exits with no surviving writer,
            // EOF arrives immediately and this returns in the time it takes the drain thread to finish its
            // final read — measured at ~50-90ms per captured command end to end, spawn included. The bound
            // below is only ever *reached* when a straggler holds a pipe open.
            // The child has already exited, so both pipes have hit (or are about to hit) EOF *unless* a
            // surviving descendant inherited a write end (same `fsmonitor--daemon` case). Bound the wait to
            // whatever remains of the request's own deadline, floored at `Self.drainGrace` so a process that
            // exits right at the deadline's edge still gets a minimal chance to drain, and using
            // `Self.drainGrace` outright when the call has no deadline at all (`timeout == nil`): git itself
            // already finished either way, so a wait for its output outliving the caller's own budget is
            // waiting on nothing the caller still cares about.
            process.waitUntilExit()
            let drainTimeout = deadline.map { max(Self.drainGrace, $0.timeIntervalSinceNow) } ?? Self.drainGrace
            guard let outputData = outDrain.waitForData(timeout: drainTimeout) else {
                // git exited, but something it spawned still holds a pipe open; the output would be
                // indeterminate anyway (we cannot tell how much more, if any, git itself had written before
                // exiting), so this is reported the same way an outright process timeout is.
                throw SpacesRuntimeError.gitCommandFailed(
                    message:
                        "Git command timed out after \(timeout ?? 0)s: \(commandDescription) (a spawned descendant kept a pipe open after exit)")
            }
            let errData = errDrain.waitForData(timeout: drainTimeout) ?? Data()
            // `awaitProcessExitOrCapOverflow`'s poll loop can observe `!process.isRunning` a beat before the
            // drain thread finishes appending its final chunk and sets `didExceedCap` — the process exiting
            // and the drain thread noticing the cap is crossed are two independent, unsynchronized events,
            // so `.exited` can win that race even though the output truly did exceed the cap. `waitForData()`
            // above blocks until the drain thread finishes (EOF or cap), which happens after it sets
            // `didExceedCap`, so this read is guaranteed final: a bounded caller must not receive a silently
            // truncated (rather than reported) result just because the process happened to exit first.
            if outDrain.didExceedCap {
                throw SpacesRuntimeError.outputExceededCap
            }
            if !allowedExitCodes.contains(process.terminationStatus) {
                let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
                throw SpacesRuntimeError.gitCommandFailed(message: message)
            }
            // Lossy on purpose: git emits a patch's raw on-disk bytes verbatim, and a file that is not valid
            // UTF-8 (a Latin-1 text file, say) is still git's idea of "text" — its own binary sniff is on the
            // content, not the encoding. The strict `String(data:encoding:.utf8)` initializer returns nil for
            // any such byte sequence, and `?? ""` was silently turning that into an empty patch — the diff
            // then reports the file as an ordinary, unchanged-looking non-binary entry with nothing to show,
            // hiding a real change instead of surfacing it. `String(decoding:as:)` never fails: invalid bytes
            // become U+FFFD, so the rest of the patch (headers, hunk markers, unaffected lines) still renders.
            return String(decoding: outputData, as: UTF8.self)
        }
    }

    private func runGit(_ arguments: [String], timeout: TimeInterval? = nil) throws -> Int32 {
        let process = makeGitProcess(arguments)
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        try waitForProcess(process, timeout: timeout, arguments: arguments)
        return process.terminationStatus
    }

    private func runGitOrThrow(_ arguments: [String]) throws {
        let process = makeGitProcess(arguments)
        let err = Pipe()
        process.standardOutput = Pipe()
        process.standardError = err

        try process.run()
        try waitForProcess(process, timeout: nil, arguments: arguments)

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

    private func waitForProcess(_ process: Process, timeout: TimeInterval?, arguments: [String]) throws {
        guard let timeout else {
            process.waitUntilExit()
            return
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() >= deadline {
                terminateThenKill(process)
                process.waitUntilExit()
                let commandDescription = ([gitExecutable] + arguments).joined(separator: " ")
                throw SpacesRuntimeError.gitCommandFailed(message: "Git command timed out after \(timeout)s: \(commandDescription)")
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
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

/// Outcome of racing a process's exit against a capture-cap overflow and a deadline; see
/// `awaitProcessExitOrCapOverflow`.
private enum ProcessWaitOutcome {
    case exited
    case timedOut
    case capExceeded
}

/// Polls `process.isRunning`, `outDrain.didExceedCap`, and (when `timeout` is set) the deadline, returning as
/// soon as any one of them is satisfied. This is deliberately a genuine race rather than "wait for exit, then
/// check the cap" or "wait for the cap, then check for exit": a cap overflow can occur while the process is
/// still very much alive (blocked mid-`write()` into a pipe `PipeDrain` stopped draining), and a normal, fast
/// exit can occur well before any cap trips, so checking only one condition first can miss the other for an
/// arbitrarily long time — including forever, for a process that stops producing output without exiting.
private func awaitProcessExitOrCapOverflow(_ process: Process, outDrain: PipeDrain, timeout: TimeInterval?) -> ProcessWaitOutcome {
    let deadline = timeout.map { Date().addingTimeInterval($0) }
    while true {
        if outDrain.didExceedCap { return .capExceeded }
        if !process.isRunning { return .exited }
        if let deadline, Date() >= deadline { return .timedOut }
        Thread.sleep(forTimeInterval: 0.01)
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

/// Drains one `Pipe`'s read end on a background queue starting immediately after the process launches,
/// rather than after it exits. `Process.waitUntilExit()` blocks until the child closes its stdout/stderr
/// fds (normally at exit); a child that writes more than the pipe's kernel buffer (64 KiB on macOS) to a
/// pipe nobody is reading blocks on that `write()` until it is drained, so a caller that waits for exit
/// before reading deadlocks against its own child for any output past that size. A `git diff` of a large
/// file crosses it easily — `workspaceDiff` allows patches up to its 8 MiB total cap — so every
/// `RemoteWorkspaceGitClient` call reads concurrently with the wait instead of after it.
///
/// `@unchecked Sendable`: `data`/`didExceedCap` are only mutated inside the one background read and only
/// read after `waitForData(timeout:)` observes `finished`, which happens-after the drain thread's final
/// write to both by way of the same `condition` lock both sides take — that hand-off is the synchronization
/// the compiler cannot see.
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
    /// Guards `_didExceedCap`: `awaitProcessExitOrCapOverflow`'s poll loop reads `didExceedCap` from the
    /// caller's thread concurrently with the drain thread writing it below — an unsynchronized read/write
    /// race on a `Bool` without this lock. (The *value* read after `waitForData(timeout:)` observes
    /// `finished` is still safe without this lock too, by the same `condition`-lock ordering as `data`
    /// above; a separate lock exists for the concurrent poll, and is used uniformly by both readers for one
    /// obviously-correct access pattern rather than only where strictly required.)
    private let capLock = NSLock()
    private var _didExceedCap = false
    /// Set once `maxBytes` is exceeded, in bounded mode only. The caller (`runGitAndCapture`) is
    /// responsible for terminating and reaping the process when this is true — this class only stops
    /// reading, since draining a pipe has no way to make its writer stop.
    var didExceedCap: Bool {
        capLock.lock()
        defer { capLock.unlock() }
        return _didExceedCap
    }

    /// `maxBytes == nil` reads to EOF exactly as before. `maxBytes` set switches to an incremental
    /// `read(upToCount:)` loop that stops (and closes its end of the pipe) as soon as at least that many
    /// bytes have been read, rather than blocking until the writer closes the pipe — a writer producing
    /// more than the cap would otherwise never be observed to finish.
    ///
    /// The drain runs on a dedicated `Thread`, never a GCD queue: `waitForData(timeout:)` blocks its caller
    /// on a condition variable, and when many `runGitAndCapture` calls run concurrently those blocked
    /// callers occupy dispatch's worker threads, at which point GCD can stop granting threads to
    /// global-queue work items — including the drain closures whose signals would unblock them. That
    /// starvation deadlocked a parallel test run indefinitely (every worker parked waiting, both drain
    /// closures never scheduled). A dedicated thread is guaranteed to run regardless of dispatch pool
    /// pressure.
    init(_ pipe: Pipe, maxBytes: Int? = nil) {
        let handle = pipe.fileHandleForReading
        let thread = Thread { [self] in
            if let maxBytes {
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }  // EOF: writer closed its end without exceeding the cap.
                    data.append(chunk)
                    if data.count >= maxBytes {
                        capLock.lock()
                        _didExceedCap = true
                        capLock.unlock()
                        break
                    }
                }
                if didExceedCap {
                    // Stop draining and close our end so the writer's next `write()` fails fast instead of
                    // blocking forever; `runGitAndCapture` still terminates the process itself since closing
                    // the pipe does not guarantee the writer notices before its next write attempt.
                    handle.closeFile()
                }
            } else {
                data = handle.readDataToEndOfFile()
            }
            condition.lock()
            finished = true
            condition.signal()
            condition.unlock()
        }
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Waits until the drain thread finishes (EOF, or the cap was hit and this drain closed its own end) or
    /// `timeout` elapses, whichever comes first. Returns the captured data if the drain finished within the
    /// window, or `nil` on expiry.
    ///
    /// On expiry the drain thread is deliberately left running rather than torn down: it is blocked in a
    /// blocking read on the pipe's read end (`readDataToEndOfFile()` or `availableData`), and closing that
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
