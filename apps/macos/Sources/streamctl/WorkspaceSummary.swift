import Foundation

public struct WorkspaceSummary: Sendable {
    public let id: String
    public let title: String
    public let branch: String?
    public let targetBranch: String?
    public let dir: String
    public let isRunning: Bool
    public let isArchived: Bool
    public let isDefault: Bool
    public let tooltip: String?

    public init(
        id: String, title: String, branch: String?, targetBranch: String? = nil, dir: String, isRunning: Bool, isArchived: Bool, isDefault: Bool,
        tooltip: String? = nil)
    {
        self.id = id
        self.title = title
        self.branch = branch
        self.targetBranch = targetBranch
        self.dir = dir
        self.isRunning = isRunning
        self.isArchived = isArchived
        self.isDefault = isDefault
        self.tooltip = tooltip
    }

    public var name: String { title }

    public init(
        id: String, name: String, branch: String?, targetBranch: String? = nil, dir: String, isRunning: Bool, isArchived: Bool, isDefault: Bool,
        tooltip: String? = nil)
    {
        self.init(
            id: id, title: name, branch: branch, targetBranch: targetBranch, dir: dir, isRunning: isRunning, isArchived: isArchived, isDefault: isDefault,
            tooltip: tooltip)
    }
}
