#if canImport(AppKit)
    import AppKit
    import Foundation
    import spacesterminalcore

    /// The pill under a hovered terminal link that shows where the link goes. Hosted as a subview of
    /// `GhosttyMirrorTerminalView`, which positions it with `frame(paneBounds:rowRect:anchorX:tooltipSize:)`
    /// once per hovered link and hides it the moment the hover clears.
    ///
    /// It contrasts with the terminal (light pill on a dark terminal and the reverse), and it never takes
    /// mouse events: a view under the pointer would make the pane see the pointer leave, which clears
    /// the hover that is showing it.
    @MainActor final class TerminalLinkTooltipView: NSView {
        static let font = Typography.rowDetail
        static let horizontalPadding: CGFloat = 8
        static let verticalPadding: CGFloat = 4
        /// Space between the hovered row and the tooltip.
        nonisolated static let rowGap: CGFloat = 4
        /// Minimum space between the tooltip and the pane's edges.
        nonisolated static let edgeMargin: CGFloat = 8
        /// How far left of the pointer's cell the tooltip starts, so the pointer does not sit on its corner.
        nonisolated static let anchorLead: CGFloat = 4

        private let label = NSTextField(labelWithString: "")

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 6
            layer?.masksToBounds = false
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.45
            layer?.shadowRadius = 7
            layer?.shadowOffset = NSSize(width: 0, height: -4)
            label.font = Self.font
            label.maximumNumberOfLines = 1
            label.usesSingleLineMode = true
            label.lineBreakMode = .byTruncatingMiddle
            addSubview(label)
            isHidden = true
            setAccessibilityElement(false)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            label.frame = bounds.insetBy(dx: Self.horizontalPadding, dy: Self.verticalPadding)
        }

        /// The text shown, or nil while hidden.
        var shownText: String? { isHidden ? nil : label.stringValue }

        func show(text: String, frame: NSRect, onLightTerminal: Bool) {
            label.stringValue = text
            label.textColor = onLightTerminal ? Self.lightText : Self.darkText
            layer?.backgroundColor = (onLightTerminal ? Self.darkFill : Self.lightFill).cgColor
            self.frame = frame
            needsLayout = true
            isHidden = false
        }

        func hide() { isHidden = true }

        private static let lightFill = NSColor(srgbRed: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF4 / 255, alpha: 1)
        private static let darkFill = NSColor(srgbRed: 0x1C / 255, green: 0x1D / 255, blue: 0x21 / 255, alpha: 1)
        private static let lightText = lightFill
        private static let darkText = darkFill

        /// The size the tooltip wants for `text` on one line, before the pane caps its width.
        static func size(for text: String) -> NSSize {
            let textSize = (text as NSString).size(withAttributes: [.font: font])
            return NSSize(width: ceil(textSize.width) + 2 * horizontalPadding, height: ceil(textSize.height) + 2 * verticalPadding)
        }

        /// Where the tooltip goes, in the pane's own (unflipped, origin bottom-left) coordinates.
        ///
        /// It sits `rowGap` below the hovered row, or above it when the room below inside the pane is too
        /// small. It starts `anchorLead` left of `anchorX` (the pointer cell's left edge), then slides to
        /// stay `edgeMargin` inside the pane, and a target too long for the pane is narrowed to fit, which
        /// the label shows as a middle truncation.
        nonisolated static func frame(paneBounds: NSRect, rowRect: NSRect, anchorX: CGFloat, tooltipSize: NSSize) -> NSRect {
            let width = min(tooltipSize.width, max(paneBounds.width - 2 * edgeMargin, 0))
            let height = tooltipSize.height
            var x = anchorX - anchorLead
            x = min(x, paneBounds.maxX - edgeMargin - width)
            x = max(x, paneBounds.minX + edgeMargin)
            let belowY = rowRect.minY - rowGap - height
            let y = belowY >= paneBounds.minY ? belowY : rowRect.maxY + rowGap
            return NSRect(x: x, y: y, width: width, height: height)
        }
    }
#endif
