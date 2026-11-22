import AppKit
import spacesterminalcore

/// A pane's title row: the page title on the left, the pane's actions on the right, centered on one
/// `PaneLayout.titleRowHeight` row. Actions are laid out left to right in the order given.
@MainActor final class PaneHeaderView: NSStackView {
    init(title: String, actions: [NSView] = []) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 12
        translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Typography.pageTitle
        titleLabel.textColor = Theme.text
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        for view in [titleLabel, spacer] + actions { addArrangedSubview(view) }
        heightAnchor.constraint(equalToConstant: PaneLayout.titleRowHeight).isActive = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }
}
