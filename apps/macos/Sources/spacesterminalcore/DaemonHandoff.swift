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

    public init(
        sessionID: String, masterFD: Int32, childPID: Int32, columns: Int, rows: Int, ownerEpoch: UInt64, screenStateRevision: UInt64,
        appearance: String?
    ) {
        self.sessionID = sessionID
        self.masterFD = masterFD
        self.childPID = childPID
        self.columns = columns
        self.rows = rows
        self.ownerEpoch = ownerEpoch
        self.screenStateRevision = screenStateRevision
        self.appearance = appearance
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
    /// Count of consecutive handoffs landing on the same `sourceVersion` without an
    /// intervening version bump. The daemon refuses to exec again once this crosses
    /// a small threshold, guarding against an exec loop between two bad builds.
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

/// Errors raised by the old-image side of the preflight check in
/// `DaemonHandoffPreflight.run`.
public enum DaemonHandoffPreflightError: Error, CustomStringConvertible {
    case launchFailed(String)
    case checkFailed(exitCode: Int32, output: String)

    public var description: String {
        switch self {
        case .launchFailed(let message): return "failed to launch the staged daemon for handoff preflight: \(message)."
        case .checkFailed(let exitCode, let output):
            return "staged daemon failed the handoff preflight (exit \(exitCode))\(output.isEmpty ? "" : ": \(output)")."
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
        /// waits for it to exit. Drains stdout/stderr before `waitUntilExit()` — a child
        /// that writes more than the kernel's pipe buffer would otherwise deadlock both
        /// processes if the parent waited first. Throws a descriptive error on launch
        /// failure or a nonzero exit; callers must treat either as "do not exec". Only
        /// the daemon platforms spawn the preflight child; iOS never runs spacesd.
        public static func run(executablePath: String, formatVersion: Int) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = [checkArgument, String(formatVersion)]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            do { try process.run() } catch { throw DaemonHandoffPreflightError.launchFailed(error.localizedDescription) }
            try? output.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw DaemonHandoffPreflightError.checkFailed(exitCode: process.terminationStatus, output: message)
            }
        }
    #endif
}
