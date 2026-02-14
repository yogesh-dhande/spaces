import Foundation

public struct WorkspaceSummary: Sendable {
    public let id: String
    public let name: String
    public let branch: String?
    public let dir: String
    public let isRunning: Bool
    public let isArchived: Bool
    public let isDefault: Bool

    public init(id: String, name: String, branch: String?, dir: String, isRunning: Bool, isArchived: Bool, isDefault: Bool) {
        self.id = id
        self.name = name
        self.branch = branch
        self.dir = dir
        self.isRunning = isRunning
        self.isArchived = isArchived
        self.isDefault = isDefault
    }
}
