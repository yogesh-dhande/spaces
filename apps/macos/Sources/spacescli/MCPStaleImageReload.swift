import Foundation
import spacesterminalcore

/// Identity of the file backing an executable path: the `(device, inode)` pair `stat` reports.
///
/// It changes exactly when the file a path resolves to is replaced by a different file, which is what
/// a Spaces update does to the CLI binary inside `Spaces.app` and what a rebuild does to a development
/// build. Comparing it is what makes `MCPStaleImageReload` loop-proof: the identity of the image a
/// process is *running* is read once at startup, so a re-exec can only ever be triggered by a file that
/// arrived after this process did.
struct SpacesBinaryFileIdentity: Equatable {
    let deviceID: Int64
    let inode: Int64

    /// `stat` follows symlinks, so this reports the identity of the binary `path` currently resolves to.
    /// The fields are widened bit-preserving (`st_dev` is signed on Darwin and unsigned on Linux), which
    /// keeps equality exact without a platform-dependent trap on conversion.
    static func read(path: String) -> SpacesBinaryFileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return SpacesBinaryFileIdentity(deviceID: Int64(truncatingIfNeeded: info.st_dev), inode: Int64(truncatingIfNeeded: info.st_ino))
    }
}

/// Decides whether a failed MCP tool call means this server is running a stale binary image, and
/// replaces the process image in place when it is.
///
/// A `spaces mcp` server lives as long as the agent session that spawned it, which routinely spans a
/// Spaces update: the app updates, the daemon exec-applies its staged build and starts speaking a newer
/// wire protocol, and every server spawned before the update keeps executing the pre-update image. The
/// mismatch error's advice ("update Spaces, then retry") is unactionable there — the binary on disk is
/// already updated, only the running image is behind — so the server reloads itself instead. `execv`
/// preserves the process's descriptors, so stdin/stdout and the MCP stdio transport riding them survive
/// the swap, and the server holds no state across the MCP handshake, so the successor answers the
/// client's next request without a fresh `initialize`.
///
/// Two guards keep this to the one case it exists for:
///
/// - **Direction.** Only a daemon that is *ahead* of this image is fixed by loading a newer image. A
///   daemon that is behind needs the daemon restarted or its staged update applied, which is what the
///   existing error already says, so that direction is left untouched.
/// - **Same image.** `runningImage` is the identity of the binary this process was exec'd from, read at
///   construction — before any daemon call can have failed, so it can never already be the identity of a
///   replacement. A mismatch whose cause is not a stale image (a foreign daemon on this profile's
///   socket, say) leaves the on-disk identity equal to it and returns the existing error. Every exec
///   therefore requires a file that is genuinely different from the one this process is running, and the
///   successor re-reads its own identity at startup, so an exec loop needs an unbounded supply of new
///   on-disk binaries rather than a single unchanging one.
struct MCPStaleImageReload {
    /// Answer returned to the in-flight tool call before the exec. The call itself cannot be carried
    /// across the exec — the request lives only in this image's memory — and a request-handoff mechanism
    /// would buy nothing an immediate retry does not, so the caller is told to retry. Present tense
    /// because the exec has not happened yet when this is written, and `execv` can still fail.
    static let retryMessage = "Spaces was updated on this device, so this MCP server is reloading itself onto the updated build. Retry the call."

    /// POSIX `execv`, injectable so tests observe the exec target and argv instead of replacing the test
    /// process.
    typealias ExecutableReplacement = (_ path: String, _ arguments: [String]) -> Void

    /// The path this process was exec'd from, as the process itself reports it. It is re-resolved through
    /// `realpath` at every decision rather than once here, so a symlink an update repointed is followed
    /// afresh instead of pinning the bundle it named at launch.
    private let executablePath: String?
    /// Identity of the image this process is running (see the same-image guard above).
    private let runningImage: SpacesBinaryFileIdentity?
    private let identityReader: (String) -> SpacesBinaryFileIdentity?
    private let pathResolver: (String) -> String?
    private let replaceExecutable: ExecutableReplacement

    init(
        executablePath: String? = Bundle.main.executableURL?.path,
        identityReader: @escaping (String) -> SpacesBinaryFileIdentity? = SpacesBinaryFileIdentity.read(path:),
        pathResolver: @escaping (String) -> String? = MCPStaleImageReload.resolvedPath(of:),
        replaceExecutable: @escaping ExecutableReplacement = MCPStaleImageReload.replaceProcessImage(path:arguments:)
    ) {
        self.executablePath = executablePath
        self.runningImage = executablePath.flatMap(identityReader)
        self.identityReader = identityReader
        self.pathResolver = pathResolver
        self.replaceExecutable = replaceExecutable
    }

    /// The binary to exec, or nil when `error` is not a daemon-is-newer mismatch or the image on disk is
    /// the one already running.
    func execTarget(for error: Error) -> String? {
        guard Self.daemonSpeaksNewerProtocol(error) else { return nil }
        guard let executablePath, let runningImage else { return nil }
        guard let resolvedPath = pathResolver(executablePath), let onDiskImage = identityReader(resolvedPath) else { return nil }
        guard onDiskImage != runningImage else { return nil }
        return resolvedPath
    }

    /// Replaces this process with `path`. On success it never returns; on failure the server keeps
    /// serving the stale image and re-decides on the next mismatch.
    func reload(into path: String, arguments: [String] = CommandLine.arguments) { replaceExecutable(path, arguments) }

    /// Whether `error` is the protocol mismatch in the direction a newer image fixes. Reads the typed
    /// verdict the error already carries, never its message prose.
    static func daemonSpeaksNewerProtocol(_ error: Error) -> Bool {
        guard let error = error as? TerminalServiceError, case .daemonWireIncompatible(let incompatibility) = error else { return false }
        return incompatibility.daemonSpeaksNewerProtocol
    }

    /// `realpath`, so the public `spaces` symlink resolves to the binary in the bundle it currently
    /// points at.
    static func resolvedPath(of path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `execv`s `path` with this process's argv verbatim, so the successor is invoked exactly as this
    /// process was. Plain Swift is safe here, unlike the daemon's forked PTY children: this is an
    /// ordinary process context on the MCP read loop's own thread, not a `fork` child, and nothing in the
    /// CLI blocks signals, so there is no inherited signal mask to reset the way the daemon's handoff
    /// exec must (that one runs on a dispatch worker). `execv` returns only on failure, where the
    /// strdup'd argv is freed; leaking it on the success path is irrelevant because the image is gone.
    static func replaceProcessImage(path: String, arguments: [String]) {
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        path.withCString { pathPointer in _ = execv(pathPointer, &argv) }
        for pointer in argv where pointer != nil { free(pointer) }
    }
}
