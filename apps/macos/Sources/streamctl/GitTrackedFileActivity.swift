import Foundation

public struct GitTrackedFileActivity: Sendable {
    public let latestTrackedFileModificationDate: Date?
    public let modifiedTrackedFileCount: Int

    public init(latestTrackedFileModificationDate: Date?, modifiedTrackedFileCount: Int) {
        self.latestTrackedFileModificationDate = latestTrackedFileModificationDate
        self.modifiedTrackedFileCount = modifiedTrackedFileCount
    }
}
