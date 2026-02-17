import Foundation

public struct WorkspaceRecord: Codable, Sendable {
    public let id: String
    public let projectID: String
    public let name: String
    public let dir: String
    public let dirname: String?
    public let branch: String?
    public let isDefault: Bool
    public let isArchived: Bool
    public let isRunning: Bool
    public let lastLaunchedAt: String?
    public let tooltip: String?

    public init(
        id: String, projectID: String, name: String, dir: String, dirname: String?, branch: String?, isDefault: Bool, isArchived: Bool,
        isRunning: Bool, lastLaunchedAt: String?, tooltip: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.dir = dir
        self.dirname = dirname
        self.branch = branch
        self.isDefault = isDefault
        self.isArchived = isArchived
        self.isRunning = isRunning
        self.lastLaunchedAt = lastLaunchedAt
        self.tooltip = tooltip
    }
}
