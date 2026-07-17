import Foundation

public struct WorktreeInfo: Sendable {
    public let path: String
    public let head: String?
    public let branch: String?
    public init(path: String, head: String?, branch: String?) {
        self.path = path
        self.head = head
        self.branch = branch
    }
    /// The branch name from the porcelain worktree ref. Strips only the `refs/heads/` prefix, so slashed
    /// branch names are preserved (`refs/heads/smoke/hello` → `smoke/hello`); a value already without the
    /// prefix is returned unchanged. Splitting on `/` would mangle slashed names to their last segment,
    /// which then overwrites the correct stored branch in `scanAndCreateWorkspacesFromWorktrees`.
    public var branchName: String? {
        guard let branch else { return nil }
        let prefix = "refs/heads/"
        if branch.hasPrefix(prefix) { return String(branch.dropFirst(prefix.count)) }
        return branch
    }
}
