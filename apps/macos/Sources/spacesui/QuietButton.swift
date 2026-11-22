import AppKit

/// A low-emphasis button for actions repeated down a list (a row's Copy): the quiet control fill, no
/// border. The caller sets the title, or `attributedTitle` when it needs the label's color and font.
@MainActor final class QuietButton: NSButton {
    private static let height: CGFloat = 24
    private static let minimumWidth: CGFloat = 64
    private static let horizontalPadding: CGFloat = 24

    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        wantsLayer = true
        layer?.cornerRadius = PaneLayout.controlRadius
        layer?.masksToBounds = true
        bindAppearanceReactiveLayer(self) { view in view.layer?.backgroundColor = Theme.controlFill.cgColor }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(Self.minimumWidth, super.intrinsicContentSize.width + Self.horizontalPadding), height: Self.height)
    }
}
