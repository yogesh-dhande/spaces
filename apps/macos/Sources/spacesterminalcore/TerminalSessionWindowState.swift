import Foundation

public struct TerminalSessionWindowFrame: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct TerminalSessionWindowState: Codable, Sendable, Equatable {
    public var ownerFrame: TerminalSessionWindowFrame?
    public var viewerFrame: TerminalSessionWindowFrame?

    public init(ownerFrame: TerminalSessionWindowFrame? = nil, viewerFrame: TerminalSessionWindowFrame? = nil) {
        self.ownerFrame = ownerFrame
        self.viewerFrame = viewerFrame
    }
}
