import AppKit
import systembridge

/// The panel's flat tab strip: one compact button per tab (title + hover close) plus a
/// trailing "+" that opens a new terminal tab — the same action as the New-terminal
/// shortcut. Custom chrome instead of NSTabView so tabs stay compact and the strip can
/// later host drag-out.
@MainActor final class PanelTabBarView: NSView {
    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?
    var onNewTab: (() -> Void)?

    private let tabsStack = NSStackView()
    private let scrollView = NSScrollView()
    private var titlesByTabID: [String: String] = [:]
    private var selectedTabID: String?
    private var tabIDs: [String] = []

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        tabsStack.orientation = .horizontal
        tabsStack.alignment = .centerY
        tabsStack.spacing = 4
        tabsStack.translatesAutoresizingMaskIntoConstraints = false

        let clipView = NSClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.documentView = tabsStack
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let newTabButton = NSButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New terminal tab")?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium)) ?? NSImage(), target: self, action: #selector(newTabClicked))
        newTabButton.bezelStyle = .inline
        newTabButton.isBordered = false
        newTabButton.toolTip = "New terminal tab"
        newTabButton.contentTintColor = Theme.mutedSecondary
        newTabButton.setContentHuggingPriority(.required, for: .horizontal)
        newTabButton.setAccessibilityIdentifier("panel-new-tab")

        let row = NSStackView(views: [scrollView, newTabButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor), row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 30),
            scrollView.heightAnchor.constraint(equalTo: row.heightAnchor, constant: -6),
            tabsStack.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func update(tabIDs: [String], titlesByTabID: [String: String], selectedTabID: String?) {
        self.tabIDs = tabIDs
        self.titlesByTabID = titlesByTabID
        self.selectedTabID = selectedTabID
        rebuildTabs()
    }

    func updateTitle(_ title: String, forTabID tabID: String) {
        guard titlesByTabID[tabID] != title else { return }
        titlesByTabID[tabID] = title
        rebuildTabs()
    }

    private func rebuildTabs() {
        for view in tabsStack.arrangedSubviews {
            tabsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for tabID in tabIDs {
            tabsStack.addArrangedSubview(
                PanelTabItemView(
                    tabID: tabID, title: titlesByTabID[tabID] ?? "Terminal", isSelected: tabID == selectedTabID,
                    onSelect: { [weak self] id in self?.onSelectTab?(id) }, onClose: { [weak self] id in self?.onCloseTab?(id) }))
        }
    }

    @objc private func newTabClicked() { onNewTab?() }
}

/// A single tab chip: title plus an always-available close glyph, highlighted when
/// selected.
@MainActor private final class PanelTabItemView: NSView {
    private let tabID: String
    private let onSelect: (String) -> Void
    private let onClose: (String) -> Void

    init(tabID: String, title: String, isSelected: Bool, onSelect: @escaping (String) -> Void, onClose: @escaping (String) -> Void) {
        self.tabID = tabID
        self.onSelect = onSelect
        self.onClose = onClose
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = UIRadius.regular
        layer?.backgroundColor = isSelected ? Theme.rowSelectedCard.cgColor : NSColor.clear.cgColor
        layer?.borderWidth = isSelected ? 1 : 0
        layer?.borderColor = Theme.rowSelectedCardBorder.cgColor
        setAccessibilityIdentifier("panel-tab-\(tabID)")

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: isSelected ? .semibold : .regular)
        titleLabel.textColor = isSelected ? Theme.text : Theme.muted
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 160).isActive = true

        let closeButton = NSButton(
            image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .medium)) ?? NSImage(), target: self, action: #selector(closeClicked))
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.toolTip = "Close tab"
        closeButton.contentTintColor = Theme.mutedSecondary
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.setAccessibilityIdentifier("panel-tab-close-\(tabID)")

        let stack = NSStackView(views: [titleLabel, closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 5)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func mouseDown(with event: NSEvent) { onSelect(tabID) }

    @objc private func closeClicked() { onClose(tabID) }
}
