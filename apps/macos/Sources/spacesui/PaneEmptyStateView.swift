import AppKit
import spacesterminalcore

/// The one empty state every home pane uses: a muted 24pt symbol, a title, an optional detail line,
/// and an optional text action in the accent color, centered horizontally with generous space above.
///
/// `update` rewrites the labels in place, so a pane that refreshes on a timer (Resources) can keep one
/// instance and swap its content without rebuilding.
@MainActor final class PaneEmptyStateView: NSStackView {
    /// Runs when the text action is clicked.
    var onAction: () -> Void = {}

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton()
    private var content: PaneEmptyStateContent?

    init(content: PaneEmptyStateContent) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = 6
        edgeInsets = NSEdgeInsets(top: 56, left: 0, bottom: 56, right: 0)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        iconView.contentTintColor = Theme.mutedSecondary
        titleLabel.font = Typography.emptyStateTitle
        titleLabel.textColor = Theme.text
        detailLabel.font = Typography.rowDetail
        detailLabel.textColor = Theme.muted
        actionButton.target = self
        actionButton.action = #selector(actionClicked)

        for view in [iconView, titleLabel, detailLabel, actionButton] { addArrangedSubview(view) }
        setCustomSpacing(10, after: iconView)
        update(content)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }

    func update(_ content: PaneEmptyStateContent) {
        guard content != self.content else { return }
        self.content = content
        iconView.image = NSImage(systemSymbolName: content.symbol, accessibilityDescription: content.title)
        titleLabel.stringValue = content.title
        detailLabel.stringValue = content.detail ?? ""
        detailLabel.isHidden = content.detail == nil
        actionButton.isHidden = content.actionTitle == nil
        if let actionTitle = content.actionTitle {
            actionButton.title = actionTitle
            Theme.applyTextStyle(to: actionButton, color: Theme.accent)
        }
    }

    @objc private func actionClicked() { onAction() }
}
