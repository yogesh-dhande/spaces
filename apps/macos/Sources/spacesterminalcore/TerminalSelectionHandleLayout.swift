import Foundation

/// Where a touch client draws the two handles of its selection and where the Copy / Select All menu
/// points, in the points of the view that shows the frame.
///
/// A handle is a thin bar the height of its row with a dot at the outer end: above the start bar, below
/// the end bar. An end whose row is off screen has no handle, and the selection cannot be adjusted from
/// that end until it scrolls back.
public struct TerminalSelectionHandleLayout: Equatable, Sendable {
    public static let barWidth = 2.0
    public static let dotDiameter = 10.0

    public struct Handle: Equatable, Sendable {
        /// The bar's frame.
        public let barX: Double
        public let barY: Double
        public let barHeight: Double
        /// The dot's center, on the bar's axis.
        public let dotCenterX: Double
        public let dotCenterY: Double

        /// The point a finger grabs: the middle of the bar.
        public var grabX: Double { barX + TerminalSelectionHandleLayout.barWidth / 2 }
        public var grabY: Double { barY + barHeight / 2 }

        /// The distance from (`x`, `y`) to the nearest of the drawn bar and dot, or nil when the point is
        /// outside the target: the union of the two, grown by the touch outset.
        fileprivate func touchDistance(x: Double, y: Double) -> Double? {
            let radius = TerminalSelectionHandleLayout.dotDiameter / 2
            let barRight = barX + TerminalSelectionHandleLayout.barWidth
            let minX = min(barX, dotCenterX - radius) - TerminalSelectionHandleLayout.touchOutsetX
            let maxX = max(barRight, dotCenterX + radius) + TerminalSelectionHandleLayout.touchOutsetX
            let minY = min(barY, dotCenterY - radius) - TerminalSelectionHandleLayout.touchOutsetY
            let maxY = max(barY + barHeight, dotCenterY + radius) + TerminalSelectionHandleLayout.touchOutsetY
            guard x >= minX, x <= maxX, y >= minY, y <= maxY else { return nil }
            let barDistance = Self.distance(x: x, y: y, minX: barX, minY: barY, maxX: barRight, maxY: barY + barHeight)
            let dotDistance = Self.distance(
                x: x, y: y, minX: dotCenterX - radius, minY: dotCenterY - radius, maxX: dotCenterX + radius, maxY: dotCenterY + radius)
            return min(barDistance, dotDistance)
        }

        private static func distance(x: Double, y: Double, minX: Double, minY: Double, maxX: Double, maxY: Double) -> Double {
            let dx = max(minX - x, 0, x - maxX)
            let dy = max(minY - y, 0, y - maxY)
            return (dx * dx + dy * dy).squareRoot()
        }
    }

    /// How far past its drawing a handle accepts a touch, since a 2 pt bar is not something a finger can
    /// hit.
    public static let touchOutsetX = 22.0
    public static let touchOutsetY = 11.0

    public let start: Handle?
    public let end: Handle?

    /// The handle a touch at (`x`, `y`) grabs, or nil when it is within neither handle's target. A short
    /// selection puts the end handle's expanded target over the start handle's drawing, so a touch both
    /// targets contain goes to the handle whose drawn bar or dot is nearest, rather than to whichever
    /// view happens to be hit-tested first. A tie goes to the end handle.
    public func handle(atX x: Double, y: Double) -> TerminalSelectionHandle? {
        let startDistance = start.flatMap { $0.touchDistance(x: x, y: y) }
        let endDistance = end.flatMap { $0.touchDistance(x: x, y: y) }
        switch (startDistance, endDistance) {
        case (nil, nil): return nil
        case (.some, nil): return .start
        case (nil, .some): return .end
        case (.some(let s), .some(let e)): return s < e ? .start : .end
        }
    }
    /// The band of rows the selection covers on screen, which the menu points at.
    public let anchorMinX: Double
    public let anchorMinY: Double
    public let anchorWidth: Double
    public let anchorHeight: Double

    /// - Parameters:
    ///   - range: the selection projected onto the frame on screen.
    ///   - originX: the x of the grid's first column; `originY` is the y of its first row.
    ///   - columns: the grid's width in cells, so the menu can point at the full-width band of a
    ///     selection that spans lines.
    public init(range: GhosttyTerminalSelectionRange, originX: Double, originY: Double, cellWidth: Double, cellHeight: Double, columns: Int) {
        let radius = Self.dotDiameter / 2
        let startRowY = originY + Double(range.startRow) * cellHeight
        let endRowY = originY + Double(range.endRow) * cellHeight
        if range.extendsAbove {
            start = nil
        } else {
            let x = originX + Double(range.startColumn) * cellWidth
            start = Handle(barX: x - Self.barWidth / 2, barY: startRowY, barHeight: cellHeight, dotCenterX: x, dotCenterY: startRowY - radius)
        }
        if range.extendsBelow {
            end = nil
        } else {
            let x = originX + Double(Int(range.endColumn) + 1) * cellWidth
            end = Handle(barX: x - Self.barWidth / 2, barY: endRowY, barHeight: cellHeight, dotCenterX: x, dotCenterY: endRowY + cellHeight + radius)
        }
        if range.startRow == range.endRow {
            anchorMinX = originX + Double(range.startColumn) * cellWidth
            anchorWidth = Double(Int(range.endColumn) + 1 - Int(range.startColumn)) * cellWidth
        } else {
            anchorMinX = originX
            anchorWidth = Double(columns) * cellWidth
        }
        anchorMinY = startRowY
        anchorHeight = endRowY + cellHeight - startRowY
    }
}
