import Foundation

public struct WorkspaceRecord: Codable, Sendable {
    public let id: String
    public let projectID: String
    public let deviceID: String
    public let title: String
    public let dir: String
    public let runtimePath: String
    public let dirname: String?
    public let branch: String?
    public let targetBranch: String?
    public let isDefault: Bool
    public let isArchived: Bool
    public let isHidden: Bool
    public let isRunning: Bool
    public let lastLaunchedAt: String?
    public let notes: String?

    public init(
        id: String, projectID: String, deviceID: String = SpacesDeviceRecord.localDeviceID, title: String, dir: String, runtimePath: String? = nil,
        dirname: String?, branch: String?, targetBranch: String? = nil, isDefault: Bool, isArchived: Bool, isHidden: Bool = false, isRunning: Bool,
        lastLaunchedAt: String?, notes: String? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.deviceID = deviceID
        self.title = title
        self.dir = dir
        self.runtimePath = runtimePath ?? dir
        self.dirname = dirname
        self.branch = branch
        self.targetBranch = targetBranch
        self.isDefault = isDefault
        self.isArchived = isArchived
        self.isHidden = isHidden
        self.isRunning = isRunning
        self.lastLaunchedAt = lastLaunchedAt
        self.notes = notes
    }
}
