import AppKit
import spacesterminalcore

/// Underline tabs on the left of a row, with the pane's filters right-aligned in the same row and a
/// 1pt border line under the whole row. The selected tab is in the text color and medium weight with a
/// 2pt underline; the others are muted.
///
/// Each tab is a button with an accessibility selected state. Selecting a tab updates the row and
/// reports the index; what the pane shows for it is the caller's to switch.
@MainActor final class PaneTabsView: NSView {
    private static let tabHeight: CGFloat = 32

    var onSelect: (Int) -> Void = { _ in }

    private let tabButtons: [TabButton]

    init(titles: [String], selected: Int, filters: [NSView] = []) {
        tabButtons = titles.map { TabButton(title: $0) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let border = ColoredBackgroundView()
        border.fillColor = Theme.border
        border.translatesAutoresizingMaskIntoConstraints = false

        let tabs = NSStackView(views: tabButtons)
        tabs.orientation = .horizontal
        tabs.alignment = .centerY
        tabs.spacing = 20
        for (index, button) in tabButtons.enumerated() {
            button.tag = index
            button.target = self
            button.action = #selector(tabClicked(_:))
        }

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let filterStack = NSStackView(views: filters)
        filterStack.orientation = .horizontal
        filterStack.alignment = .centerY
        filterStack.spacing = 8

        let row = NSStackView(views: [tabs, spacer, filterStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        // The border goes in first so the selected tab's underline, which ends on the row's bottom edge,
        // draws over it.
        addSubview(border)
        addSubview(row)
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: leadingAnchor), border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor), border.heightAnchor.constraint(equalToConstant: 1),
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.tabHeight),
        ])
        select(selected)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }

    /// Marks one tab selected without reporting it, for a pane that changes its own selection.
    func select(_ index: Int) {
        for (tabIndex, button) in tabButtons.enumerated() { button.isSelectedTab = tabIndex == index }
    }

    @objc private func tabClicked(_ sender: NSButton) {
        select(sender.tag)
        onSelect(sender.tag)
    }

    private final class TabButton: NSButton {
        private let underline = ColoredBackgroundView()

        var isSelectedTab = false {
            didSet {
                underline.isHidden = !isSelectedTab
                setAccessibilitySelected(isSelectedTab)
                attributedTitle = NSAttributedString(
                    string: title,
                    attributes: [
                        .foregroundColor: isSelectedTab ? Theme.text : Theme.mutedSecondary,
                        .font: isSelectedTab ? Typography.textButtonLabel : Typography.secondaryButtonLabel,
                    ])
            }
        }

        init(title: String) {
            super.init(frame: .zero)
            self.title = title
            isBordered = false
            translatesAutoresizingMaskIntoConstraints = false
            setContentHuggingPriority(.required, for: .horizontal)
            underline.fillColor = Theme.text
            underline.translatesAutoresizingMaskIntoConstraints = false
            addSubview(underline)
            NSLayoutConstraint.activate([
                underline.leadingAnchor.constraint(equalTo: leadingAnchor), underline.trailingAnchor.constraint(equalTo: trailingAnchor),
                underline.bottomAnchor.constraint(equalTo: bottomAnchor), underline.heightAnchor.constraint(equalToConstant: 2),
            ])
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }

        override var intrinsicContentSize: NSSize { NSSize(width: super.intrinsicContentSize.width, height: PaneTabsView.tabHeight) }
    }
}
