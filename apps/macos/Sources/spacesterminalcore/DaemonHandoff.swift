import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// One row of the handoff table: everything the resuming daemon needs to adopt an
/// in-flight PTY session across an exec-in-place update without tearing it down.
public struct DaemonHandoffSessionRecord: Codable, Sendable {
    public let sessionID: String
    public let masterFD: Int32
    public let childPID: Int32
    public let columns: Int
    public let rows: Int
    public let ownerEpoch: UInt64
    public let screenStateRevision: UInt64
    public let appearance: String?
    /// Transcript byte count at quiesce: the boundary between output the pre-exec image's terminal
    /// already parsed — answering any queries it carried — and the handoff-window suffix the old
    /// image appended to `output.log` unparsed. The resuming Linux core replays that suffix with
    /// terminal events live so its unanswered queries still get replies. Optional because the
    /// table's evolution rule requires it (see `DaemonHandoffTable`).
    public let transcriptOffsetAtQuiesce: UInt64?

    public init(
        sessionID: String, masterFD: Int32, childPID: Int32, columns: Int, rows: Int, ownerEpoch: UInt64, screenStateRevision: UInt64,
        appearance: String?, transcriptOffsetAtQuiesce: UInt64?
    ) {
        self.sessionID = sessionID
        self.masterFD = masterFD
        self.childPID = childPID
        self.columns = columns
        self.rows = rows
        self.ownerEpoch = ownerEpoch
        self.screenStateRevision = screenStateRevision
        self.appearance = appearance
        self.transcriptOffsetAtQuiesce = transcriptOffsetAtQuiesce
    }
}

/// On-disk handoff table the old daemon image writes just before `execv`-ing the
/// staged binary at the same pid, and the new image consumes on startup to adopt
/// live sessions instead of tearing them down. This is a one-shot, one-directional
/// (new-reads-old) wire format, not an ongoing cross-version protocol: only a
/// resuming daemon ever reads a table, and only ever one written by itself moments
/// earlier. `currentFormatVersion` only ever increases; readers must keep accepting
/// every version `<= currentFormatVersion` and future fields must be optional so a
/// newer writer's table still decodes on a build that predates the new field. See
/// `DaemonHandoffStore` for the read/write/discard rules and the golden v1 fixture
/// test in `DaemonHandoffTests` for the regression gate on this discipline.
public struct DaemonHandoffTable: Codable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    /// Count of rapid consecutive handoffs landing on the same `sourceVersion`. The
    /// daemon refuses to exec again once this crosses a small threshold, guarding
    /// against a loop between two bad builds, and resets it after a stable interval.
    public let generation: Int
    /// pid of the process that wrote this table. `DaemonHandoffStore.consume`
    /// requires this to equal the current process's pid, which discriminates an
    /// exec-resume (execv keeps the pid) from a fresh supervisor respawn after a
    /// crash (a new pid, for which a leftover table must never be adopted).
    public let pid: Int32
    public let sourceVersion: String
    public let writtenAt: String
    public let sessions: [DaemonHandoffSessionRecord]

    public init(
        formatVersion: Int = DaemonHandoffTable.currentFormatVersion, generation: Int, pid: Int32, sourceVersion: String,
        writtenAt: String = GhosttyRemoteSessionStateTimestamp.string(from: Date()), sessions: [DaemonHandoffSessionRecord]
    ) {
        self.formatVersion = formatVersion
        self.generation = generation
        self.pid = pid
        self.sourceVersion = sourceVersion
        self.writtenAt = writtenAt
        self.sessions = sessions
    }
}

/// Errors raised by the low-level write path in `DaemonHandoffStore.write`. Kept
/// distinct from the generic `POSIXError` thrown by fcntl-style call sites in this
/// file because the failing step (fsync vs. the final rename) matters for callers
/// deciding whether the exec is still safe to attempt.
public enum DaemonHandoffStoreError: Error, CustomStringConvertible {
    case fsyncFailed(Int32)
    case renameFailed(Int32)

    public var description: String {
        switch self {
        case .fsyncFailed(let code): return "failed to fsync the daemon handoff table before install (errno \(code))."
        case .renameFailed(let code): return "failed to install the daemon handoff table (errno \(code))."
        }
    }
}

/// Reads and writes the handoff table at `TerminalServicePaths.daemonHandoffTablePath()`,
/// and the small descriptor-preparation helpers the exec seam needs around it.
public enum DaemonHandoffStore {
    /// Writes `table` atomically: encode to a sibling temp file, `fsync` it so the
    /// bytes are durable, then `rename` into place. A reader can only ever observe a
    /// fully-written table or none at all — never a partial one — which matters
    /// because the very next step after this call is `execv`.
    public static func write(_ table: DaemonHandoffTable, fileManager: FileManager = .default) throws {
        let path = try TerminalServicePaths.daemonHandoffTablePath(fileManager: fileManager)
        let url = URL(fileURLWithPath: path, isDirectory: false)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(table)

        let temporaryPath = "\(path).\(getpid()).\(UUID().uuidString).tmp"
        try data.write(to: URL(fileURLWithPath: temporaryPath, isDirectory: false), options: .withoutOverwriting)

        let fileDescriptor = open(temporaryPath, O_WRONLY)
        guard fileDescriptor >= 0 else {
            try? fileManager.removeItem(atPath: temporaryPath)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let syncResult = fsync(fileDescriptor)
        close(fileDescriptor)
        guard syncResult == 0 else {
            let code = errno
            try? fileManager.removeItem(atPath: temporaryPath)
            throw DaemonHandoffStoreError.fsyncFailed(code)
        }

        guard rename(temporaryPath, path) == 0 else {
            let code = errno
            try? fileManager.removeItem(atPath: temporaryPath)
            throw DaemonHandoffStoreError.renameFailed(code)
        }
    }

    /// Reads the handoff table and unconditionally deletes it — a table is consumed
    /// at most once, whether or not it turns out to be adoptable, so a discarded or
    /// stale table can never be picked up again by a later, unrelated startup.
    /// Returns nil (fresh boot, fall through to normal orphan recovery) when the
    /// file is absent, undecodable, from a format newer than this build knows, or
    /// written by a different pid than the one reading it now.
    public static func consume(fileManager: FileManager = .default) -> DaemonHandoffTable? {
        guard let path = try? TerminalServicePaths.daemonHandoffTablePath(fileManager: fileManager) else { return nil }
        guard fileManager.fileExists(atPath: path) else { return nil }
        defer { try? fileManager.removeItem(atPath: path) }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path, isDirectory: false)) else { return nil }
        guard let table = try? JSONDecoder().decode(DaemonHandoffTable.self, from: data) else { return nil }
        guard table.formatVersion <= DaemonHandoffTable.currentFormatVersion else {
            logHandoffTableDiscarded(
                "format version \(table.formatVersion) is newer than currentFormatVersion \(DaemonHandoffTable.currentFormatVersion)")
            return nil
        }
        // See the doc comment on `DaemonHandoffTable.pid`: only a table this same
        // process wrote (i.e. survived its own execv) is ever adoptable.
        guard table.pid == getpid() else {
            logHandoffTableDiscarded("table pid \(table.pid) does not match current pid \(getpid())")
            return nil
        }
        return table
    }

    /// Deletes the handoff table without reading it. Used on the failed-`execv`
    /// fallback: `execv` returned, so the just-written table describes a handoff that
    /// never happened and must not be adopted by any later startup of this same pid.
    /// `consume` deletes on read; this is the delete-only path for the write-then-abort case.
    public static func deleteTable(fileManager: FileManager = .default) {
        guard let path = try? TerminalServicePaths.daemonHandoffTablePath(fileManager: fileManager) else { return }
        try? fileManager.removeItem(atPath: path)
    }

    /// Clears `FD_CLOEXEC` on a descriptor so it survives the upcoming `execv` into
    /// the staged binary instead of being closed by the kernel at exec time.
    public static func prepareDescriptorForHandoff(_ fd: Int32) throws {
        let currentFlags = fcntl(fd, F_GETFD)
        guard currentFlags >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard fcntl(fd, F_SETFD, currentFlags & ~FD_CLOEXEC) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Sanity check the resuming daemon runs on every handoff-record descriptor
    /// before trusting it as a live PTY master: a fresh fstat must succeed and the
    /// descriptor must be a tty, guarding against adopting a closed or repurposed fd.
    public static func descriptorLooksLikePTYMaster(_ fd: Int32) -> Bool {
        guard fd >= 0 else { return false }
        var status = stat()
        guard fstat(fd, &status) == 0 else { return false }
        return isatty(fd) == 1
    }

    private static func logHandoffTableDiscarded(_ reason: String) {
        FileHandle.standardError.write(Data("daemon-handoff: discarding handoff table (\(reason)).\n".utf8))
    }
}

/// What the resuming daemon should do with a single handoff record, decided purely from
/// whether its inherited descriptor still looks like a live PTY master and whether its child
/// process is still alive. Kept a pure function (no syscalls, no I/O) so the resume-selection
/// contract is unit-testable independent of a live PTY and GhosttyKit.
public enum DaemonHandoffResumeAction: Equatable, Sendable {
    /// The descriptor is a live PTY master and the child is alive: rebuild a core and adopt it.
    case adopt
    /// The descriptor is a live PTY master but the child has exited: close the fd and finalize the
    /// session as `.exited` (the normal dead-child teardown), then skip.
    case finalizeExited
    /// The descriptor is not a usable PTY master (closed/repurposed across the exec): finalize the
    /// session as `.exited` and skip. There is no live fd to close.
    case discardInvalidDescriptor
}

/// Pure decisions the daemon exec seam makes around a handoff, factored out of the private
/// `SpacesDaemonController` (an executable target's types are not importable by tests) so the
/// generation-guard and resume-selection contracts can be unit-tested directly.
public enum DaemonHandoffDecision {
    /// A generation chain only represents an exec loop while handoffs keep arriving within this
    /// interval. Stable daemons begin a fresh chain so later same-version development builds remain
    /// installable without a supervisor restart.
    public static let generationGuardResetInterval: TimeInterval = 60

    /// Returns the generation to write into the next handoff table, or nil when a rapid sequence of
    /// same-version handoffs has exhausted the loop guard. Version changes and a stable interval both
    /// begin a fresh chain at generation one.
    public static func nextHandoffGeneration(
        generation: Int, lastSourceVersion: String?, currentVersion: String, stagedVersion: String?, elapsedSinceLastHandoff: TimeInterval?
    ) -> Int? {
        let continuesSameVersionChain = lastSourceVersion == currentVersion && (stagedVersion == nil || stagedVersion == currentVersion)
        guard continuesSameVersionChain else { return 1 }
        if let elapsedSinceLastHandoff, elapsedSinceLastHandoff >= generationGuardResetInterval { return 1 }
        guard generation < 3 else { return nil }
        return generation + 1
    }

    /// Whether to refuse an exec-in-place handoff to guard against an exec loop between two builds.
    /// Refuses once `generation` reaches the threshold AND another exec would land on the version
    /// already involved in the loop. A genuinely different staged target always proceeds, even when
    /// repeated same-version handoffs have exhausted the current generation budget.
    public static func refusesExecByGenerationGuard(generation: Int, lastSourceVersion: String?, currentVersion: String, stagedVersion: String?)
        -> Bool
    {
        nextHandoffGeneration(
            generation: generation, lastSourceVersion: lastSourceVersion, currentVersion: currentVersion, stagedVersion: stagedVersion,
            elapsedSinceLastHandoff: nil) == nil
    }

    /// See `DaemonHandoffResumeAction`. A record with a bad descriptor is discarded regardless of
    /// child liveness (there is nothing to adopt without a PTY master).
    public static func resumeAction(descriptorLooksLikePTYMaster: Bool, childIsAlive: Bool) -> DaemonHandoffResumeAction {
        guard descriptorLooksLikePTYMaster else { return .discardInvalidDescriptor }
        return childIsAlive ? .adopt : .finalizeExited
    }
}

/// Errors raised by the old-image side of the preflight check in
/// `DaemonHandoffPreflight.run`.
public enum DaemonHandoffPreflightError: Error, CustomStringConvertible {
    case launchFailed(String)
    case checkFailed(exitCode: Int32, output: String)
    case timedOut(seconds: Int)

    public var description: String {
        switch self {
        case .launchFailed(let message): return "failed to launch the staged daemon for handoff preflight: \(message)."
        case .checkFailed(let exitCode, let output):
            return "staged daemon failed the handoff preflight (exit \(exitCode))\(output.isEmpty ? "" : ": \(output)")."
        case .timedOut(let seconds): return "staged daemon did not answer the handoff preflight within \(seconds)s."
        }
    }
}

/// Before execing into a staged binary, the old daemon image runs it once as a
/// child process with `--handoff-check <formatVersion>` and only proceeds with the
/// real exec if that child exits 0 — i.e. the staged binary is new enough to speak
/// the table format about to be written. This never grows into an ongoing
/// version-negotiation protocol: it is a single yes/no gate around a single exec.
public enum DaemonHandoffPreflight {
    /// Invocation contract: `spacesd --handoff-check <formatVersion>`.
    public static let checkArgument = "--handoff-check"

    /// New-binary side: recognizes a `--handoff-check <formatVersion>` invocation
    /// from raw argv exactly as `main()` receives it. Returns nil when argv is not a
    /// check invocation at all, so the normal daemon-startup path is untouched;
    /// otherwise returns the process exit code — 0 when `formatVersion` parses and
    /// is within what this build's `DaemonHandoffTable.currentFormatVersion` knows
    /// how to read, nonzero otherwise.
    public static func respondsToCheck(arguments: [String]) -> Int32? {
        guard let argumentIndex = arguments.firstIndex(of: checkArgument) else { return nil }
        let versionIndex = argumentIndex + 1
        guard versionIndex < arguments.count, let formatVersion = Int(arguments[versionIndex]) else { return 1 }
        return formatVersion <= DaemonHandoffTable.currentFormatVersion ? 0 : 1
    }

    #if os(macOS) || os(Linux)
        /// Old-binary side: spawns `executablePath --handoff-check <formatVersion>` and
        /// waits for it to exit. Throws a descriptive error on launch failure, a nonzero
        /// exit, or a blown deadline; callers must treat all of them as "do not exec".
        /// Only the daemon platforms spawn the preflight child; iOS never runs spacesd.
        public static func run(executablePath: String, formatVersion: Int) throws {
            try run(executablePath: executablePath, formatVersion: formatVersion, deadlineSeconds: 10)
        }

        /// Deliberately raw `posix_spawn` + `poll` + `waitpid` (the `systembridge`
        /// spawn idiom) rather than Foundation `Process`: `waitUntilExit()` spins the
        /// caller's run loop until Foundation's monitor notices the child exit, and on
        /// Linux that notification can be missed inside the daemon, wedging the handoff
        /// on the main thread forever with the child long dead. Direct `waitpid` cannot
        /// miss. The pipe is drained (with `poll`) before reaping so a chatty child can
        /// never deadlock on a full pipe buffer, and the deadline kills the child so a
        /// pathological staged binary cannot stall the daemon mid-handoff — a preflight
        /// failure is the approved keep-running path; a hang is not.
        internal static func run(executablePath: String, formatVersion: Int, deadlineSeconds: Int) throws {
            var outputPipe: [Int32] = [-1, -1]
            guard pipe(&outputPipe) == 0 else { throw DaemonHandoffPreflightError.launchFailed("pipe failed (errno \(errno))") }
            let outputFlags = fcntl(outputPipe[0], F_GETFL)
            guard outputFlags >= 0, fcntl(outputPipe[0], F_SETFL, outputFlags | O_NONBLOCK) == 0 else {
                let code = errno
                close(outputPipe[0])
                close(outputPipe[1])
                throw DaemonHandoffPreflightError.launchFailed("failed to make output pipe nonblocking (errno \(code))")
            }

            let argumentStrings: [String] = [executablePath, checkArgument, String(formatVersion)]
            var cArguments: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { strdup($0) }
            cArguments.append(nil)
            defer { for argument in cArguments { if let argument { free(argument) } } }

            #if canImport(Darwin)
                var fileActions: posix_spawn_file_actions_t? = nil
            #else
                var fileActions = posix_spawn_file_actions_t()
            #endif
            guard posix_spawn_file_actions_init(&fileActions) == 0 else {
                close(outputPipe[0])
                close(outputPipe[1])
                throw DaemonHandoffPreflightError.launchFailed("posix_spawn_file_actions_init failed (errno \(errno))")
            }
            defer { posix_spawn_file_actions_destroy(&fileActions) }
            posix_spawn_file_actions_adddup2(&fileActions, outputPipe[1], STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(&fileActions, outputPipe[1], STDERR_FILENO)
            posix_spawn_file_actions_addclose(&fileActions, outputPipe[0])
            posix_spawn_file_actions_addclose(&fileActions, outputPipe[1])

            var pid: pid_t = 0
            let spawnResult = posix_spawn(&pid, executablePath, &fileActions, nil, &cArguments, environ)
            close(outputPipe[1])
            guard spawnResult == 0 else {
                close(outputPipe[0])
                throw DaemonHandoffPreflightError.launchFailed("posix_spawn failed (errno \(spawnResult))")
            }
            defer { close(outputPipe[0]) }

            let deadline = Date().addingTimeInterval(TimeInterval(deadlineSeconds))
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            drain: while true {
                let remainingMS = Int32((deadline.timeIntervalSinceNow * 1000).rounded(.up))
                guard remainingMS > 0 else {
                    kill(pid, SIGKILL)
                    _ = waitpid(pid, nil, 0)
                    throw DaemonHandoffPreflightError.timedOut(seconds: deadlineSeconds)
                }
                var pollDescriptor = pollfd(fd: outputPipe[0], events: Int16(POLLIN), revents: 0)
                let pollResult = poll(&pollDescriptor, 1, remainingMS)
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    kill(pid, SIGKILL)
                    _ = waitpid(pid, nil, 0)
                    throw DaemonHandoffPreflightError.launchFailed("poll failed (errno \(errno))")
                }
                if pollResult == 0 { continue }
                while true {
                    let count = read(outputPipe[0], &buffer, buffer.count)
                    if count > 0 {
                        data.append(buffer, count: count)
                        continue
                    }
                    if count == 0 { break drain }
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { break }
                    let code = errno
                    kill(pid, SIGKILL)
                    _ = waitpid(pid, nil, 0)
                    throw DaemonHandoffPreflightError.launchFailed("read failed (errno \(code))")
                }
            }

            var status: Int32 = 0
            reap: while true {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid { break reap }
                if result < 0 && errno != EINTR { throw DaemonHandoffPreflightError.launchFailed("waitpid failed (errno \(errno))") }
                // EOF arrived, so the child is exiting; give it until the deadline to be reapable.
                guard Date() < deadline else {
                    kill(pid, SIGKILL)
                    _ = waitpid(pid, nil, 0)
                    throw DaemonHandoffPreflightError.timedOut(seconds: deadlineSeconds)
                }
                usleep(10_000)
            }

            let exitedNormally = (status & 0x7F) == 0
            let exitCode = exitedNormally ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
            guard exitedNormally && exitCode == 0 else {
                let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw DaemonHandoffPreflightError.checkFailed(exitCode: exitCode, output: message)
            }
        }
    #endif
}
