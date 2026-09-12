import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Path normalization that agrees with what the kernel reports.
public enum FilesystemPaths {
    /// `path` with every symlink resolved, as `realpath(3)` resolves it.
    ///
    /// Foundation's own `resolvingSymlinksInPath` cannot be used for this: it resolves the links and
    /// then strips a leading `/private`, so a canonical `/private/var/folders/...` comes back as
    /// `/var/folders/...`, which is the alias rather than the real path. Everything that reports a path
    /// from the kernel reports the canonical one: FSEvents callbacks, and Codex naming its own home in
    /// a `hooks.state` table. A comparison against a Foundation-resolved path silently misses them all.
    ///
    /// A path whose last component does not exist yet, a file about to be written or one just deleted,
    /// resolves through its directory, so a name is normalized before the file behind it exists. A path
    /// that resolves nowhere at all comes back standardized and otherwise unchanged.
    public static func realPath(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        if let resolved = realpath(standardized, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = (standardized as NSString).deletingLastPathComponent
        guard parent != standardized, let resolvedParent = realpath(parent, nil) else { return standardized }
        defer { free(resolvedParent) }
        return (String(cString: resolvedParent) as NSString).appendingPathComponent((standardized as NSString).lastPathComponent)
    }

    /// `url` with every symlink in it resolved.
    public static func realPath(_ url: URL) -> String { realPath(url.path) }
}
