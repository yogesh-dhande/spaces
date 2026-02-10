import Foundation

public struct ProjectRecord: Codable, Sendable {
    public let id: String
    public let name: String
    public let dir: String
    public let isGitRepo: Bool
    public let defaultBranch: String?

    public init(id: String, name: String, dir: String, isGitRepo: Bool, defaultBranch: String?) {
        self.id = id
        self.name = name
        self.dir = dir
        self.isGitRepo = isGitRepo
        self.defaultBranch = defaultBranch
    }
}
