import Foundation

/// Locates the file a hook writer should actually write to.
///
/// Agent configs are commonly symlinked into a dotfiles repo (`~/.claude/settings.json` →
/// `~/dotfiles/claude/settings.json`). Every hook writer writes atomically — a temp file renamed over
/// the destination — which replaces the *symlink* with a regular file and silently detaches the user's
/// managed config. Following the link chain first keeps the dotfiles repo owning the file, and keeps
/// the write atomic with respect to the real target.
enum AgentHookConfigFile {
    /// Backstop on the hop count. Unreachable in practice — a link cycle already stops at the
    /// existence check below, because `stat` reports a cycle as nonexistent (`ELOOP`).
    private static let maximumSymlinkDepth = 8

    /// Follows `fileURL` through any chain of symlinks to the real file it points at. Regular files and
    /// missing files resolve to themselves, so a first install creates the file in place. Relative link
    /// destinations resolve against the link's own directory, as the filesystem does.
    ///
    /// A link is followed only when its destination exists. A dangling link — a dotfiles repo that is
    /// not cloned yet, an unmounted volume, a cycle — points at nothing worth preserving, so the write
    /// replaces the dead link itself. Following it instead would create directories at a destination
    /// the user never populated, or fail outright on an unwritable one and defer the install forever.
    static func writeTarget(for fileURL: URL, fileManager: FileManager) -> URL {
        var target = fileURL
        for _ in 0..<maximumSymlinkDepth {
            guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: target.path) else { return target }
            let next = URL(fileURLWithPath: destination, relativeTo: target.deletingLastPathComponent()).standardizedFileURL
            guard fileManager.fileExists(atPath: next.path) else { return target }
            target = next
        }
        return target
    }

    /// Writes `data` through to the real file behind `fileURL`, creating the parent directory.
    static func write(_ data: Data, to fileURL: URL, fileManager: FileManager) throws {
        let target = writeTarget(for: fileURL, fileManager: fileManager)
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }

    static func write(_ contents: String, to fileURL: URL, fileManager: FileManager) throws {
        try write(Data(contents.utf8), to: fileURL, fileManager: fileManager)
    }
}
