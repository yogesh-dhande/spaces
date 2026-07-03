import AppKit
import systembridge

/// The panel's single chrome row: flat tabs (title + close, accent underline on the
/// selected tab) on the left, and the pane actions — split right, split down, new tab —
/// on the right. Splits act on the selected tab's focused pane, so panes carry no
/// header of their own until a tab actually holds more than one. Custom chrome instead
/// of NSTabView so tabs stay compact and the strip can later host drag-out.
@MainActor final class PanelTabBarView: NSView {
    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?
    var onNewTab: (() -> Void)?
    /// Rename commit from the tab context menu's editor; nil title clears the custom
    /// name back to the derived one.
    var onRenameTab: ((_ tabID: String, _ title: String?) -> Void)?
    /// Split request for the selected tab's focused pane.
    var onSplitFocusedPane: ((PaneSplitDirection) -> Void)?

    private let tabsStack = NSStackView()
    private let scrollView = NSScrollView()
    private var titlesByTabID: [String: String] = [:]
    private var selectedTabID: String?
    private var tabIDs: [String] = []
    private var renamePopover: NSPopover?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        tabsStack.orientation = .horizontal
        tabsStack.alignment = .centerY
        tabsStack.spacing = 2
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

        let splitRightButton = actionButton(
            symbol: "rectangle.split.2x1", tooltip: "Split right", identifier: "panel-split-right", action: #selector(splitRightClicked))
        let splitDownButton = actionButton(
            symbol: "rectangle.split.1x2", tooltip: "Split down", identifier: "panel-split-down", action: #selector(splitDownClicked))
        let newTabButton = actionButton(symbol: "plus", tooltip: "New terminal tab", identifier: "panel-new-tab", action: #selector(newTabClicked))

        let row = NSStackView(views: [scrollView, splitRightButton, splitDownButton, newTabButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 10)
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

    private func actionButton(symbol: String, tooltip: String, identifier: String, action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .medium)) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .inline
        button.isBordered = false
        button.toolTip = tooltip
        button.contentTintColor = Theme.mutedSecondary
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setAccessibilityIdentifier(identifier)
        return button
    }

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
                    onSelect: { [weak self] id in self?.onSelectTab?(id) }, onClose: { [weak self] id in self?.onCloseTab?(id) },
                    onRenameRequest: { [weak self] id, anchor in self?.presentRenameEditor(tabID: id, anchor: anchor) }))
        }
    }

    /// A small transient popover with a single name field; Return commits, Esc or a
    /// click outside dismisses without saving. Clearing the field restores the tab's
    /// derived title.
    private func presentRenameEditor(tabID: String, anchor: NSView) {
        renamePopover?.close()
        let field = NSTextField(string: titlesByTabID[tabID] ?? "")
        field.placeholderString = "Tab name"
        field.font = .systemFont(ofSize: 12)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setAccessibilityIdentifier("panel-tab-rename-input")
        field.target = self
        field.action = #selector(renameFieldCommitted(_:))
        field.identifier = NSUserInterfaceItemIdentifier(tabID)

        let content = NSViewController()
        let container = NSView()
        container.addSubview(field)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            field.widthAnchor.constraint(equalToConstant: 200),
        ])
        content.view = container

        let popover = NSPopover()
        popover.contentViewController = content
        popover.behavior = .transient
        renamePopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        field.window?.makeFirstResponder(field)
    }

    @objc private func renameFieldCommitted(_ sender: NSTextField) {
        guard let tabID = sender.identifier?.rawValue else { return }
        renamePopover?.close()
        renamePopover = nil
        onRenameTab?(tabID, sender.stringValue)
    }

    @objc private func newTabClicked() { onNewTab?() }

    @objc private func splitRightClicked() { onSplitFocusedPane?(.right) }

    @objc private func splitDownClicked() { onSplitFocusedPane?(.down) }
}

/// A single flat tab: title plus a close glyph; the selected tab reads from full-color
/// text and an accent underline instead of a filled chip.
@MainActor private final class PanelTabItemView: NSView {
    private let tabID: String
    private let onSelect: (String) -> Void
    private let onClose: (String) -> Void
    private let onRenameRequest: (String, NSView) -> Void

    init(
        tabID: String, title: String, isSelected: Bool, onSelect: @escaping (String) -> Void, onClose: @escaping (String) -> Void,
        onRenameRequest: @escaping (String, NSView) -> Void
    ) {
        self.tabID = tabID
        self.onSelect = onSelect
        self.onClose = onClose
        self.onRenameRequest = onRenameRequest
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
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
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 5, right: 5)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let underline = NSView()
        underline.translatesAutoresizingMaskIntoConstraints = false
        underline.wantsLayer = true
        underline.layer?.backgroundColor = isSelected ? Theme.accent.cgColor : NSColor.clear.cgColor
        addSubview(underline)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            underline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            underline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            underline.bottomAnchor.constraint(equalTo: bottomAnchor), underline.heightAnchor.constraint(equalToConstant: 2),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// The whole tab surface acts as one control: the title label would otherwise
    /// claim (and swallow) mouse events, leaving click-to-select and the context menu
    /// dead over the text. Only the close button keeps its own hits.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }

    override func mouseDown(with event: NSEvent) { onSelect(tabID) }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let rename = NSMenuItem(title: "Rename Tab", action: #selector(renameClicked), keyEquivalent: "")
        rename.target = self
        rename.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        menu.addItem(rename)
        return menu
    }

    @objc private func renameClicked() { onRenameRequest(tabID, self) }

    @objc private func closeClicked() { onClose(tabID) }
}
