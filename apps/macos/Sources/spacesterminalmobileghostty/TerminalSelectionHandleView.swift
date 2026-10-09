#if canImport(UIKit)
    import UIKit
    import spacesterminalcore

    /// One end of the selection: a thin bar the height of its row with a dot at the outer end. The
    /// touch target is wider than the drawing (`TerminalSelectionHandleLayout.handle(atX:y:)`).
    @MainActor final class TerminalSelectionHandleView: UIView {
        let handle: TerminalSelectionHandle
        private let bar = UIView()
        private let dot = UIView()

        init(handle: TerminalSelectionHandle, color: UIColor) {
            self.handle = handle
            super.init(frame: .zero)
            bar.backgroundColor = color
            dot.backgroundColor = color
            dot.layer.cornerRadius = CGFloat(TerminalSelectionHandleLayout.dotDiameter) / 2
            addSubview(bar)
            addSubview(dot)
            bar.isUserInteractionEnabled = false
            dot.isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        func setColor(_ color: UIColor) {
            bar.backgroundColor = color
            dot.backgroundColor = color
        }

        @available(*, unavailable) required init?(coder: NSCoder) { nil }

        /// The bar's point the user holds, in the superview's space. A drag moves this point with the
        /// finger, so the cell under it is the cell the handle names.
        private(set) var grabPoint = CGPoint.zero

        func place(_ layout: TerminalSelectionHandleLayout.Handle) {
            let barRect = CGRect(x: layout.barX, y: layout.barY, width: CGFloat(TerminalSelectionHandleLayout.barWidth), height: layout.barHeight)
            let diameter = CGFloat(TerminalSelectionHandleLayout.dotDiameter)
            let dotRect = CGRect(x: layout.dotCenterX - diameter / 2, y: layout.dotCenterY - diameter / 2, width: diameter, height: diameter)
            frame = barRect.union(dotRect)
            bar.frame = convert(barRect, from: superview)
            dot.frame = convert(dotRect, from: superview)
            grabPoint = CGPoint(x: layout.grabX, y: layout.grabY)
        }

        /// Which handle a touch (in the superview's space) belongs to, decided across both handles because
        /// their targets overlap on a short selection.
        var owningHandle: ((CGPoint) -> TerminalSelectionHandle?)?

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            guard let owningHandle else { return false }
            return owningHandle(convert(point, to: superview)) == handle
        }
    }
#endif
