import Foundation

public struct ProjectSummary: Sendable {
    public let id: String
    public let name: String
    public let dir: String
    public let isGitRepo: Bool
    public let defaultBranch: String?
    public let isCollapsed: Bool
    public let deviceID: String

    public init(
        id: String, name: String, dir: String, isGitRepo: Bool, defaultBranch: String?, isCollapsed: Bool = false,
        deviceID: String = SpacesDeviceRecord.localDeviceID
    ) {
        self.id = id
        self.name = name
        self.dir = dir
        self.isGitRepo = isGitRepo
        self.defaultBranch = defaultBranch
        self.isCollapsed = isCollapsed
        self.deviceID = deviceID
    }
}
