import Foundation

public struct SpaceOption: Sendable {
    public let displayIndex: Int
    public let spaceIndex: Int

    public init(displayIndex: Int, spaceIndex: Int) {
        self.displayIndex = displayIndex
        self.spaceIndex = spaceIndex
    }
}
