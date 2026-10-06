import Foundation

/// The `spaces` CLI every agent hook calls: the installed Spaces CLI, whichever build performs the
/// install or reads the status.
///
/// A CLI resolves its profile from where it sits, so a hook pointing at a development build's CLI would
/// make every agent in the installed app's terminals signal the development profile instead. Resolving
/// from the PATH, which a daemon seeds with its own executable directory, would do exactly that for a
/// repo-built daemon. The installed CLI is therefore located only through the stable link the installed
/// Spaces maintains at `~/.spaces/bin/spaces`.
enum AgentHookInstalledCLI {
    /// The installed CLI's path, or nil when no executable one is installed under `home`.
    static func path(home: URL, fileManager: FileManager) -> String? {
        guard let link = SpacesBinaryLayout.userHelperLinkURL(for: .spaces, homeDirectoryURL: home) else { return nil }
        let path = candidatePath(for: link)
        return fileManager.isExecutableFile(atPath: path) ? path : nil
    }

    #if os(macOS)
        /// On macOS the link points into the installed app bundle, and the bundle path is what the
        /// installed daemon has always written (it finds the CLI beside its own symlink-resolved
        /// executable), so the link is resolved to keep existing hooks current.
        private static func candidatePath(for link: URL) -> String { link.resolvingSymlinksInPath().path }
    #else
        /// On Linux the link points into a versioned release directory. Persisting that path would pin
        /// hooks to an old CLI after the daemon updates, so the stable link itself is the path.
        private static func candidatePath(for link: URL) -> String { link.standardizedFileURL.path }
    #endif
}
