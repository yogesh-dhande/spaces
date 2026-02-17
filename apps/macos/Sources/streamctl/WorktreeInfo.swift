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
    
    public var branchName: String? {
        guard let branch else { return nil }
        if let slash = branch.split(separator: "/").last {
            return String(slash)
        }
        return branch
    }
}
