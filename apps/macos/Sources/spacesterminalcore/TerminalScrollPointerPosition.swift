import Foundation

public struct TerminalScrollPointerPosition: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let mods: UInt32

    public init(x: Double, y: Double, mods: UInt32 = 0) {
        self.x = x
        self.y = y
        self.mods = mods
    }

    public var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }

    public static func normalized(x: Double, y: Double, width: Double, height: Double, mods: UInt32 = 0) -> Self? {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return Self(x: min(max(x / width, 0), 1), y: min(max(y / height, 0), 1), mods: mods)
    }
}
