import Foundation

public enum TerminalScrollMomentumPhase: Int32, Sendable {
    case none = 0
    case changed = 3
    case ended = 4
    case cancelled = 5
    case mayBegin = 6
}

public enum TerminalScrollModifiers {
    public static let precisionMask: Int32 = 0b0000_0001

    public static func make(hasPreciseDeltas: Bool, momentumPhase: TerminalScrollMomentumPhase = .none) -> Int32 {
        var mods: Int32 = hasPreciseDeltas ? precisionMask : 0
        if momentumPhase != .none { mods |= momentumPhase.rawValue << 1 }
        return mods
    }

    public static func hasPreciseDeltas(_ mods: Int32) -> Bool { mods & precisionMask != 0 }
}

public struct TerminalScrollDeltaNormalizer: Sendable {
    public static let defaultCellHeight: Double = 18

    public var cellHeight: Double
    public var precisionMultiplier: Double
    public var discreteMultiplier: Double
    public private(set) var pendingVerticalDelta: Double = 0

    public init(cellHeight: Double = Self.defaultCellHeight, precisionMultiplier: Double = 1, discreteMultiplier: Double = 3) {
        self.cellHeight = max(cellHeight, 1)
        self.precisionMultiplier = precisionMultiplier
        self.discreteMultiplier = discreteMultiplier
    }

    public mutating func terminalViewportDeltaRows(vertical: Double, scrollMods: Int32) -> Int {
        guard vertical != 0 else { return 0 }

        let adjusted: Double
        if TerminalScrollModifiers.hasPreciseDeltas(scrollMods) {
            adjusted = vertical * precisionMultiplier
        } else {
            adjusted = Self.discreteWheelDelta(vertical) * cellHeight * discreteMultiplier
        }
        let pending = pendingVerticalDelta + adjusted
        guard abs(pending) >= cellHeight else {
            pendingVerticalDelta = pending
            return 0
        }

        let scrollRows = Int((pending / cellHeight).rounded(.towardZero))
        pendingVerticalDelta = pending - (Double(scrollRows) * cellHeight)
        return -scrollRows
    }

    private static func discreteWheelDelta(_ vertical: Double) -> Double {
        if vertical > 0 { return max(vertical, 1) }
        return min(vertical, -1)
    }
}
