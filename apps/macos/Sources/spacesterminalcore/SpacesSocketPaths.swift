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
    /// The per-user root that holds every profile's sockets and lock files, created `0700` and
    /// owned by the current user. Because the `/tmp` path is predictable (short, fixed prefix +
    /// uid), another local user could race to pre-create it; `createDirectory` does not touch an
    /// existing directory's attributes, so this re-validates via `lstat` that the path is a real
    /// directory (not a symlink), is owned by us, and grants no group/other access. Anything else
    /// is a hijack attempt, so we refuse rather than bind into an attacker-controlled directory.
    ///
    /// `parentDirectory` defaults to `/tmp` (kept short for the 104-byte AF_UNIX cap); tests
    /// override it to validate the ownership/mode checks against an isolated temporary base.
    public static func secureSocketRoot(parentDirectory: URL = URL(fileURLWithPath: "/tmp", isDirectory: true)) throws -> URL {
        let uid = getuid()
        let root = parentDirectory.appendingPathComponent("spaces-sockets-\(uid)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var status = stat()
        guard lstat(root.path, &status) == 0 else { throw SpacesSocketPathsError.socketRootUntrusted(root.path) }
        let isDirectory = (status.st_mode & S_IFMT) == S_IFDIR
        let isOwnedByCurrentUser = status.st_uid == uid
        let deniesGroupAndOther = (status.st_mode & 0o077) == 0
        guard isDirectory, isOwnedByCurrentUser, deniesGroupAndOther else { throw SpacesSocketPathsError.socketRootUntrusted(root.path) }
        return root
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
