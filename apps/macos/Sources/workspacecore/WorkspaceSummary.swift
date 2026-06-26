import Foundation

public struct WorkspaceSummary: Sendable {
    public let id: String
    public let branch: String?
    public let baseBranch: String?
    public let dir: String
    public let isRunning: Bool
    public let isArchived: Bool
    public let isHidden: Bool
    public let isDefault: Bool
    public let notes: String?
    public let deviceID: String

    public init(
        id: String, branch: String?, baseBranch: String? = nil, dir: String, isRunning: Bool, isArchived: Bool, isHidden: Bool = false,
        isDefault: Bool, notes: String? = nil, deviceID: String = SpacesDeviceRecord.localDeviceID
    ) {
        self.id = id
        self.branch = branch
        self.baseBranch = baseBranch
        self.dir = dir
        self.isRunning = isRunning
        self.isArchived = isArchived
        self.isHidden = isHidden
        self.isDefault = isDefault
        self.notes = notes
        self.deviceID = deviceID
    }

    /// Name shown in the sidebar, detail pane, and search. Git workspaces show their
    /// branch; non-git workspaces (whose `dir` is the project directory) show the folder name.
    public var displayName: String {
        if let branch, !branch.isEmpty { return branch }
        return (dir as NSString).lastPathComponent
    }
}
