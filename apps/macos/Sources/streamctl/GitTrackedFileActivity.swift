import Foundation

public struct GitTrackedFileActivity: Sendable {
    public let latestTrackedFileModificationDate: Date?
    public let modifiedTrackedFileCount: Int
    public let aheadCount: Int
    public let behindCount: Int
    public let comparedBaseBranch: String?
    public let hasMergeConflicts: Bool

    public init(
        latestTrackedFileModificationDate: Date?, modifiedTrackedFileCount: Int, aheadCount: Int = 0, behindCount: Int = 0,
        comparedBaseBranch: String? = nil, hasMergeConflicts: Bool = false
    ) {
        self.latestTrackedFileModificationDate = latestTrackedFileModificationDate
        self.modifiedTrackedFileCount = modifiedTrackedFileCount
        self.aheadCount = aheadCount
        self.behindCount = behindCount
        self.comparedBaseBranch = comparedBaseBranch
        self.hasMergeConflicts = hasMergeConflicts
    }
}
