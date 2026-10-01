import Foundation

/// Where a directory sits inside a git repository, as `git rev-parse` reports it. Every path is absolute
/// and symlink-resolved.
public struct GitRepositoryLocation: Equatable, Sendable {
    /// The top-level directory of the work tree containing the directory; `nil` when the directory has no
    /// work tree (a bare repository, or a path inside a `.git` directory).
    public let topLevel: String?
    public let gitDirectory: String
    /// The git directory every worktree of the repository shares. It is `<main root>/.git` for a repository
    /// with a main checkout, and the repository itself for a bare one.
    public let commonDirectory: String

    public init(topLevel: String?, gitDirectory: String, commonDirectory: String) {
        self.topLevel = topLevel
        self.gitDirectory = gitDirectory
        self.commonDirectory = commonDirectory
    }

    /// A linked worktree keeps its own git directory under `<common>/worktrees/`; only the main worktree
    /// (or a bare repository) uses the common directory itself.
    public var isMainWorktree: Bool { gitDirectory == commonDirectory }
}
