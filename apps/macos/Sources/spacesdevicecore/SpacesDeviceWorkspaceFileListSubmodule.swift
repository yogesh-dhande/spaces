import Foundation

/// One checked-out submodule named by a workspace file listing.
///
/// The listing reports a submodule's own files under their full workspace-relative paths, indistinguishable
/// from the workspace's own; the gitlink path itself is a directory on disk and is never an openable entry.
/// This is therefore what tells a client that a directory in the tree is a submodule rather than a plain
/// folder, and which commit its checkout sits at, so the tree can label the folder with that pointer.
///
/// A submodule the user never initialized is absent: it has no repository to list files from and no commit
/// to name.
public struct SpacesDeviceWorkspaceFileListSubmodule: Codable, Equatable, Sendable {
    /// Workspace-relative path of the checkout directory. Nested submodules carry their full path.
    public let path: String
    /// Full object id of the commit the checkout currently has checked out (its resolved `HEAD`).
    public let commit: String

    public init(path: String, commit: String) {
        self.path = path
        self.commit = commit
    }
}
