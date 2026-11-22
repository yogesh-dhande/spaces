import AppKit
import spacesterminalcore

/// The accent-filled action at the right of a pane's title row ("New prompt", "New automation").
///
/// It draws its own content because `NSButton` offers no control over the gap between its image and
/// its title or over its insets, and the design fixes both. The real `title` stays set, so
/// accessibility and `NSButton` lookups still see the label.
@MainActor final class PanePrimaryButton: NSButton {
    private enum Metrics {
        static let height: CGFloat = 28
        static let leadingInset: CGFloat = 11
        static let iconGap: CGFloat = 6
        static let trailingInset: CGFloat = 14
        static let iconPointSize: CGFloat = 11
    }

    private let glyph: NSImage?
    private let label: NSAttributedString

    init(title: String, symbol: String, target: AnyObject?, action: Selector?) {
        let ink = Theme.primaryButtonText
        glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: Metrics.iconPointSize, weight: .semibold).applying(.init(paletteColors: [ink])))
        label = NSAttributedString(string: title, attributes: [.foregroundColor: ink, .font: Typography.primaryButtonLabel])
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = Theme.primaryButtonFill.cgColor
        layer?.cornerRadius = PaneLayout.controlRadius
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }

    override var isHighlighted: Bool {
        didSet { alphaValue = isHighlighted ? 0.85 : 1 }
    }

    override var intrinsicContentSize: NSSize {
        let iconWidth = glyph.map { $0.size.width + Metrics.iconGap } ?? 0
        return NSSize(
            width: ceil(Metrics.leadingInset + iconWidth + label.size().width + Metrics.trailingInset), height: Metrics.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        var x = Metrics.leadingInset
        if let glyph {
            let size = glyph.size
            glyph.draw(
                in: NSRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver,
                fraction: 1, respectFlipped: true, hints: nil)
            x += size.width + Metrics.iconGap
        }
        let textSize = label.size()
        label.draw(at: NSPoint(x: x, y: (bounds.height - textSize.height) / 2))
    }
}
