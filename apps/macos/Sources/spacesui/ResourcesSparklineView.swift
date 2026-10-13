import AppKit
import spacesterminalcore

/// A small filled line chart of CPU samples, oldest on the left.
///
/// The vertical scale is the largest sample, never less than `minimumScale`, so a series that never
/// leaves the idle noise floor draws as a flat line instead of being stretched into spikes.
@MainActor final class ResourcesSparklineView: NSView {
    /// CPU percent that fills the chart's height at minimum.
    static let minimumScale = 10.0

    var values: [Double] = [] {
        didSet {
            guard values != oldValue else { return }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // Faint axes give the curve a frame of reference: the x-axis is zero CPU, so a series resting
        // on it reads as idle rather than as a line floating at an unknown level.
        let axes = CGMutablePath()
        axes.move(to: CGPoint(x: bounds.minX + 0.5, y: bounds.maxY))
        axes.addLine(to: CGPoint(x: bounds.minX + 0.5, y: bounds.minY + 0.5))
        axes.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY + 0.5))
        context.setStrokeColor(Theme.border.cgColor)
        context.setLineWidth(1)
        context.addPath(axes)
        context.strokePath()

        guard values.count > 1 else { return }
        let scale = max(values.max() ?? 0, Self.minimumScale)
        let inset: CGFloat = 1.5
        let plot = CGRect(x: bounds.minX + 1, y: bounds.minY + 1, width: bounds.width - 1, height: bounds.height - 1 - inset)
        let step = plot.width / CGFloat(values.count - 1)
        let points = values.enumerated().map { index, value in
            CGPoint(x: plot.minX + CGFloat(index) * step, y: plot.minY + CGFloat(min(value / scale, 1)) * plot.height)
        }

        let area = CGMutablePath()
        area.move(to: CGPoint(x: points[0].x, y: plot.minY))
        for point in points { area.addLine(to: point) }
        area.addLine(to: CGPoint(x: points[points.count - 1].x, y: plot.minY))
        area.closeSubpath()
        context.setFillColor(Theme.accent.withAlphaComponent(0.16).cgColor)
        context.addPath(area)
        context.fillPath()

        let line = CGMutablePath()
        line.addLines(between: points)
        context.setStrokeColor(Theme.accent.cgColor)
        context.setLineWidth(1.25)
        context.setLineJoin(.round)
        context.addPath(line)
        context.strokePath()
    }
}
