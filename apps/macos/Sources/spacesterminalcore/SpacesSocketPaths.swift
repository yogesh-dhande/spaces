import Foundation

#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Every Spaces Unix-domain socket and lock file (terminal service, per-session, device API
/// control, Caddy admin) lives under one shared per-user root rather than nested inside the
/// profile runtime directory: AF_UNIX socket paths are capped at 104 bytes on macOS, and a
/// worktree/branch-derived runtime directory (`~/.spaces-dev/profiles/spaces/<branch-slug>-<hash>/runtime/`)
/// can exceed that on its own for a long branch name, which fails the bind silently. Callers hash
/// their own profile-scoped identity into the filename (mirroring the profile's runtime directory)
/// so each profile still gets its own distinct socket under the shared root.
public enum SpacesSocketPaths {
    /// Whether this process is a test host, resolved once. A process never becomes a test host part way
    /// through its life, and this sits on the terminal-session path lookup, which is hot enough that
    /// re-reading the process environment on every call was not worth it.
    private static let isTestHost = SpacesTestHost.isRunningUnderXCTest()

    /// The socket root every real Spaces process shares, one per user.
    private static func sharedRootName(uid: uid_t) -> String { "spaces-sockets-\(uid)" }

    /// The socket root of one test process. Test hosts run on throwaway profiles that are deleted with
    /// the fixture, which erases the only thing that could ever name their socket entries again: a name
    /// is a hash of the profile root, so nothing can look at an entry in the shared root and say which
    /// profile it belongs to. Left in the shared root those entries accumulate without bound, in the very
    /// directory every real daemon on the machine binds into (#685). A root of the process's own is
    /// removable whole, at exit or by a later run that finds the pid gone.
    ///
    /// It is a sibling of the shared root rather than a directory inside it because the 104-byte cap
    /// leaves no room: the longest socket name Spaces builds is 70 bytes, which already spends 94 of the
    /// budget under the shared root. This name is deliberately shorter than the shared root's, so a test
    /// host's paths are shorter than production's and no suite can pass a bind the product would fail.
    private static func testProcessRootName(uid: uid_t, pid: pid_t) -> String { "\(testProcessRootPrefix(uid: uid))\(pid)" }

    private static func testProcessRootPrefix(uid: uid_t) -> String { "spaces-t\(uid)-" }

    /// How a test host hands the root it resolved to the Spaces processes it spawns.
    ///
    /// A test host that pins `SPACESD_EXECUTABLE` runs the real daemon rather than the in-process
    /// compatibility backend, and `ensureRunning` starts that daemon as a child. The child cannot derive
    /// the host's root: it is a plain daemon under `swift test` (so it would take the shared root) and a
    /// test host with a pid of its own under `xcodebuild`, which passes `XCTestConfigurationFilePath`
    /// down. Either way it binds a socket the suite never polls and the suite times out waiting for a
    /// daemon that is running perfectly well. The root therefore travels with the spawn.
    public static let socketRootEnvironmentVariable = "SPACES_TEST_SOCKET_ROOT"

    /// The inherited root, read once for the same reason `isTestHost` is resolved once.
    private static let inheritedSocketRootPath = ProcessInfo.processInfo.environment[socketRootEnvironmentVariable]

    /// Where a socket root sits in the ownership of the process using it, which is what decides whether
    /// this process may reclaim it and whether it has to be handed to children.
    enum SocketRootKind {
        /// The per-user root every real Spaces process shares.
        case shared
        /// This test process's own root, removed when it exits.
        case ownTestProcess
        /// The root of the test host that spawned this process, which owns the reclaim.
        case inheritedTestProcess
    }

    /// The socket root for this process: the shared per-user root, this test process's own, or the one a
    /// test host handed it.
    ///
    /// `parentDirectory` defaults to `/tmp` (kept short for the 104-byte cap); tests override it to
    /// drive the reclaim of abandoned test roots against an isolated temporary base.
    public static func secureSocketRoot(parentDirectory: URL = URL(fileURLWithPath: "/tmp", isDirectory: true)) throws -> URL {
        let uid = getuid()
        let resolved = resolveSocketRoot(
            parentDirectory: parentDirectory, inheritedSocketRootPath: inheritedSocketRootPath, isTestHost: isTestHost, uid: uid, pid: getpid())
        let root = try validatedRoot(named: resolved.url.lastPathComponent, in: resolved.url.deletingLastPathComponent())
        // Reclaim stays keyed on the pid that owns the root: an inherited root belongs to the test host
        // that created it and is swept when that host exits, so a spawned daemon must not register it.
        guard resolved.kind == .ownTestProcess else { return root }
        if TestProcessSocketRoots.shared.track(root.path) { reclaimAbandonedTestProcessRoots(in: parentDirectory, uid: uid) }
        return root
    }

    /// `environment` with this process's socket root added, for a Spaces process this one is about to
    /// spawn. Unchanged for every real Spaces process, which shares one root and needs nothing passed.
    public static func environmentPropagatingSocketRoot(_ environment: [String: String]) throws -> [String: String] {
        let resolved = resolveSocketRoot(
            parentDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true), inheritedSocketRootPath: inheritedSocketRootPath,
            isTestHost: isTestHost, uid: getuid(), pid: getpid())
        guard resolved.kind != .shared else { return environment }
        var propagated = environment
        propagated[socketRootEnvironmentVariable] = try secureSocketRoot().path
        return propagated
    }

    /// Decides which root a process of this identity binds in, without touching the filesystem.
    ///
    /// An inherited root is honored only when its name has the exact shape of a test root of this user
    /// (`spaces-t<uid>-<pid>`). That shape check is what keeps the variable away from production: nothing
    /// sets it but a test host, and a value that does not name one of this user's test roots is ignored
    /// rather than bound into, so no stray binding can move a real daemon's socket out of the shared root.
    static func resolveSocketRoot(parentDirectory: URL, inheritedSocketRootPath: String?, isTestHost: Bool, uid: uid_t, pid: pid_t) -> (
        url: URL, kind: SocketRootKind
    ) {
        if let inheritedSocketRootPath, !inheritedSocketRootPath.isEmpty {
            let inherited = URL(fileURLWithPath: inheritedSocketRootPath, isDirectory: true).standardizedFileURL
            if isTestProcessRootName(inherited.lastPathComponent, uid: uid) { return (inherited, .inheritedTestProcess) }
        }
        guard isTestHost else { return (parentDirectory.appendingPathComponent(sharedRootName(uid: uid), isDirectory: true), .shared) }
        return (parentDirectory.appendingPathComponent(testProcessRootName(uid: uid, pid: pid), isDirectory: true), .ownTestProcess)
    }

    private static func isTestProcessRootName(_ name: String, uid: uid_t) -> Bool { testProcessRootPID(name, uid: uid) != nil }

    /// The pid a test root of this user is named after, or `nil` for any other name.
    private static func testProcessRootPID(_ name: String, uid: uid_t) -> pid_t? {
        let prefix = testProcessRootPrefix(uid: uid)
        guard name.hasPrefix(prefix), let pid = pid_t(name.dropFirst(prefix.count)), pid > 0 else { return nil }
        return pid
    }

    /// Creates `name` under `parentDirectory` as a `0700` directory owned by the current user, and
    /// refuses anything else. Because the `/tmp` path is predictable (short, fixed prefix + uid), another
    /// local user could race to pre-create it; `createDirectory` does not touch an existing directory's
    /// attributes, so this re-validates via `lstat` that the path is a real directory (not a symlink), is
    /// owned by us, and grants no group/other access. Anything else is a hijack attempt, so we refuse
    /// rather than bind into an attacker-controlled directory.
    static func validatedRoot(named name: String, in parentDirectory: URL) throws -> URL {
        let root = parentDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var status = stat()
        guard lstat(root.path, &status) == 0 else { throw SpacesSocketPathsError.socketRootUntrusted(root.path) }
        let isDirectory = (status.st_mode & S_IFMT) == S_IFDIR
        let isOwnedByCurrentUser = status.st_uid == getuid()
        let deniesGroupAndOther = (status.st_mode & 0o077) == 0
        guard isDirectory, isOwnedByCurrentUser, deniesGroupAndOther else { throw SpacesSocketPathsError.socketRootUntrusted(root.path) }
        return root
    }

    /// Removes the test roots of this user whose pid is not a live process.
    ///
    /// Identity, never age: a root is reclaimed because the process named in it is gone, so a root
    /// belonging to a suite running concurrently is never touched however old it is, and a recycled pid
    /// that now belongs to some unrelated live process only defers the reclaim until that process exits.
    /// Only this user's `spaces-t<uid>-<pid>` roots are candidates, so the shared root and everything any
    /// daemon binds inside it can never be one, and neither can another user's directory.
    private static func reclaimAbandonedTestProcessRoots(in parentDirectory: URL, uid: uid_t) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: parentDirectory.path) else { return }
        for entry in entries {
            guard let pid = testProcessRootPID(entry, uid: uid), !isProcessAlive(pid) else { continue }
            try? FileManager.default.removeItem(atPath: parentDirectory.appendingPathComponent(entry, isDirectory: true).path)
        }
    }

    private static func isProcessAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        // EPERM means the process exists and belongs to someone else, which for a pid reclaim decision
        // reads the same as alive.
        return errno == EPERM
    }
}

/// The test roots this process created, removed when it exits.
///
/// A process-exit sweep rather than a test teardown block: `secureSocketRoot()` is reached from product
/// code far below any test's reach, from XCTest and Swift Testing suites alike, and the root has to
/// outlive every one of them in the process. `atexit` is process-global, so it covers all of them with no
/// call-site changes. It is a backstop, not the only reclaim: a process killed before its exit handlers
/// run leaves its root behind, and the next test process removes it by pid.
private final class TestProcessSocketRoots: @unchecked Sendable {
    static let shared = TestProcessSocketRoots()

    private let lock = NSLock()
    private var paths: Set<String> = []
    private var registered = false

    /// Registers `path` for removal at process exit. Returns whether this was its first registration,
    /// which is what makes the abandoned-root reclaim run once per parent directory rather than on every
    /// socket path lookup.
    func track(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard paths.insert(path).inserted else { return false }
        if !registered {
            registered = true
            atexit { TestProcessSocketRoots.shared.sweep() }
        }
        return true
    }

    private func sweep() {
        lock.lock()
        let toRemove = paths
        paths = []
        lock.unlock()
        for path in toRemove { try? FileManager.default.removeItem(atPath: path) }
    }
}

public enum SpacesSocketPathsError: LocalizedError {
    case socketRootUntrusted(String)

    public var errorDescription: String? {
        switch self {
        case .socketRootUntrusted(let path): "The Spaces socket directory \(path) is not a private directory owned by the current user."
        }
    }
}
