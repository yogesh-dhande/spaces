import Foundation

public struct WorkspaceSummary: Sendable {
    public let id: String
    public let title: String
    public let branch: String?
    public let baseBranch: String?
    public let dir: String
    public let isRunning: Bool
    public let isArchived: Bool
    public let isHidden: Bool
    public let isDefault: Bool
    public let notes: String?

    public init(
        id: String, title: String, branch: String?, baseBranch: String? = nil, dir: String, isRunning: Bool, isArchived: Bool, isHidden: Bool = false,
        isDefault: Bool, notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.branch = branch
        self.baseBranch = baseBranch
        self.dir = dir
        self.isRunning = isRunning
        self.isArchived = isArchived
        self.isHidden = isHidden
        self.isDefault = isDefault
        self.notes = notes
    }
}
