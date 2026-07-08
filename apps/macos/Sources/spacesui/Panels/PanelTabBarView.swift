import AppKit
import systembridge

/// The panel's single chrome row: flat tabs (title + close, accent underline on the
/// selected tab) on the left, and the pane actions — split right, split down, new tab —
/// on the right. Splits act on the selected tab's focused pane, so panes carry no
/// header of their own until a tab actually holds more than one. Custom chrome instead
/// of NSTabView so tabs stay compact and the strip can later host drag-out.
@MainActor final class PanelTabBarView: NSView {
    /// When this strip is shared chrome (the main window's titlebar accessory), the
    /// workspace panel currently driving it; background panels leave it alone.
    weak var hostingOwner: AnyObject?

    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?
    var onNewTab: (() -> Void)?
    /// Rename commit from the tab's inline editor; nil title clears the custom
    /// name back to the derived one.
    var onRenameTab: ((_ tabID: String, _ title: String?) -> Void)?
    /// Split request for the selected tab's focused pane.
    var onSplitFocusedPane: ((PaneSplitDirection) -> Void)?

    private let tabsStack = NSStackView()
    private let scrollView = NSScrollView()
    /// Tabs are laid out wide by default and only shrink once too many compete for the
    /// strip's width: each tab takes an equal share of the visible width, clamped to
    /// this range. Below the floor the strip stops shrinking and overflows into a scroll.
    private let maxTabWidth: CGFloat = 200
    private let minTabWidth: CGFloat = 100
    private var titlesByTabID: [String: String] = [:]
    private var selectedTabID: String?
    private var tabIDs: [String] = []
    /// The tab whose title currently renders as an inline editor.
    private var renamingTabID: String?
    /// A rebuild requested while the rename editor was open, replayed when it ends.
    private var rebuildDeferredForRename = false

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
            heightAnchor.constraint(equalToConstant: 28), scrollView.heightAnchor.constraint(equalTo: row.heightAnchor, constant: -6),
            tabsStack.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// Tab widths depend on the strip's visible width, so recompute them once the
    /// scroll view has been sized. Constants only change when the target moves, so the
    /// constraint updates settle after one pass rather than looping.
    override func layout() {
        super.layout()
        applyTabWidths()
    }

    /// Give every tab an equal share of the visible width, clamped so a few tabs stay
    /// comfortably wide and a crowd shrinks to the floor before the strip scrolls.
    private func applyTabWidths() {
        let items = tabsStack.arrangedSubviews.compactMap { $0 as? PanelTabItemView }
        guard !items.isEmpty else { return }
        let available = scrollView.contentView.bounds.width
        guard available > 0 else { return }
        let spacingTotal = tabsStack.spacing * CGFloat(items.count - 1)
        let perTab = (available - spacingTotal) / CGFloat(items.count)
        let target = max(minTabWidth, min(maxTabWidth, perTab))
        for item in items { item.setPreferredWidth(target) }
    }

    /// Clicks on the strip's empty areas (not claimed by a tab, editor, or button)
    /// bubble here. In the main window the strip covers the titlebar's row as an
    /// accessory, so it forwards the titlebar's own gestures: drag moves the window
    /// and double-click zooms it.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.zoom(nil)
            return
        }
        window?.performDrag(with: event)
    }

    private func actionButton(symbol: String, tooltip: String, identifier: String, action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?.withSymbolConfiguration(
                .init(pointSize: 10, weight: .medium)) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .inline
        button.isBordered = false
        button.toolTip = tooltip
        button.contentTintColor = Theme.mutedSecondary
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    func update(tabIDs: [String], titlesByTabID: [String: String], selectedTabID: String?) {
        // Renders arrive on every layout pass (including overview ticks that changed
        // nothing); only a real change rebuilds the strip.
        guard tabIDs != self.tabIDs || titlesByTabID != self.titlesByTabID || selectedTabID != self.selectedTabID else { return }
        self.tabIDs = tabIDs
        self.titlesByTabID = titlesByTabID
        self.selectedTabID = selectedTabID
        requestRebuild()
    }

    func updateTitle(_ title: String, forTabID tabID: String) {
        guard titlesByTabID[tabID] != title else { return }
        titlesByTabID[tabID] = title
        requestRebuild()
    }

    /// Rebuilding while the rename editor is up would tear the editor out mid-edit;
    /// apply the pending state when the rename ends instead.
    private func requestRebuild() {
        if renamingTabID != nil {
            rebuildDeferredForRename = true
            return
        }
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
                    tabID: tabID, title: titlesByTabID[tabID] ?? "Terminal", isSelected: tabID == selectedTabID, isRenaming: tabID == renamingTabID,
                    showsTrailingSeparator: tabID != tabIDs.last,
                    onSelect: { [weak self] id in self?.onSelectTab?(id) }, onClose: { [weak self] id in self?.onCloseTab?(id) },
                    onRenameRequest: { [weak self] id in self?.beginRename(tabID: id) },
                    onRenameCommit: { [weak self] id, text in self?.endRename(tabID: id, committedTitle: text) },
                    onRenameCancel: { [weak self] _ in self?.endRename(tabID: nil, committedTitle: nil) }))
        }
    }

    /// Swaps the tab's title for an inline editor (the same in-place rename the
    /// sidebar rows use) and focuses it on the next runloop turn, after the context
    /// menu that invoked it has fully torn down.
    private func beginRename(tabID: String) {
        renamingTabID = tabID
        rebuildTabs()
        Task { @MainActor [weak self] in
            guard let self, let editor = self.renameEditorField() else { return }
            editor.window?.makeFirstResponder(editor)
            // Select via the field editor: `selectText(_:)` would end the editing
            // session it just started, which the commit-on-blur delegate treats as
            // a blur and instantly closes the editor.
            editor.currentEditor()?.selectAll(nil)
        }
    }

    /// Ends rename mode; a non-nil `tabID` commits `committedTitle` as the custom
    /// name (the engine clears it when the trimmed title is empty).
    private func endRename(tabID: String?, committedTitle: String?) {
        guard renamingTabID != nil else { return }
        renamingTabID = nil
        rebuildDeferredForRename = false
        if let tabID { onRenameTab?(tabID, committedTitle) }
        rebuildTabs()
    }

    private func renameEditorField() -> NSTextField? {
        for case let item as PanelTabItemView in tabsStack.arrangedSubviews { if let editor = item.renameEditor { return editor } }
        return nil
    }

    @objc private func newTabClicked() { onNewTab?() }

    @objc private func splitRightClicked() { onSplitFocusedPane?(.right) }

    @objc private func splitDownClicked() { onSplitFocusedPane?(.down) }
}

/// A single flat tab: title plus a close glyph; the selected tab reads from full-color
/// text and an accent underline instead of a filled chip. In rename mode the title is
/// an inline editor: Return or focus loss commits, Esc cancels.
@MainActor private final class PanelTabItemView: NSView, NSTextFieldDelegate {
    private let tabID: String
    private let onSelect: (String) -> Void
    private let onClose: (String) -> Void
    private let onRenameRequest: (String) -> Void
    private let onRenameCommit: (String, String) -> Void
    private let onRenameCancel: (String) -> Void
    /// One rename outcome per editor: Esc sets it before the blur that follows, and
    /// removal from the hierarchy can end editing a second time.
    private var renameResolved = false
    private(set) weak var renameEditor: NSTextField?
    private let closeButton = NSButton()
    private var isHovering = false
    private var hoverTrackingArea: NSTrackingArea?
    /// Width is driven by the strip (equal share of visible width); the parent updates
    /// this constant as the tab count or strip width changes.
    private var widthConstraint: NSLayoutConstraint?

    init(
        tabID: String, title: String, isSelected: Bool, isRenaming: Bool, showsTrailingSeparator: Bool, onSelect: @escaping (String) -> Void,
        onClose: @escaping (String) -> Void, onRenameRequest: @escaping (String) -> Void,
        onRenameCommit: @escaping (String, String) -> Void, onRenameCancel: @escaping (String) -> Void
    ) {
        self.tabID = tabID
        self.onSelect = onSelect
        self.onClose = onClose
        self.onRenameRequest = onRenameRequest
        self.onRenameCommit = onRenameCommit
        self.onRenameCancel = onRenameCancel
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("panel-tab-\(tabID)")

        let titleView: NSView
        if isRenaming {
            let editor = NSTextField(string: title)
            editor.placeholderString = "Tab name"
            editor.font = .systemFont(ofSize: 11)
            editor.delegate = self
            editor.setAccessibilityIdentifier("panel-tab-rename-input")
            // The tab's own width bounds the editor; let it fill and compress inside it.
            editor.setContentHuggingPriority(.defaultLow, for: .horizontal)
            editor.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            renameEditor = editor
            titleView = editor
        } else {
            let titleLabel = NSTextField(labelWithString: title)
            titleLabel.font = .systemFont(ofSize: 11, weight: isSelected ? .semibold : .regular)
            titleLabel.textColor = isSelected ? Theme.text : Theme.muted
            titleLabel.lineBreakMode = .byTruncatingTail
            // Fill the tab and truncate when it shrinks; the tab width is the only cap.
            titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleView = titleLabel
        }

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")?.withSymbolConfiguration(
            .init(pointSize: 8, weight: .medium)) ?? NSImage()
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.toolTip = "Close tab"
        closeButton.contentTintColor = Theme.mutedSecondary
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.setAccessibilityIdentifier("panel-tab-close-\(tabID)")
        updateCloseButtonVisibility()

        let closeButtonContainer = NSView()
        closeButtonContainer.translatesAutoresizingMaskIntoConstraints = false
        closeButtonContainer.setContentHuggingPriority(.required, for: .horizontal)
        closeButtonContainer.setContentCompressionResistancePriority(.required, for: .horizontal)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButtonContainer.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButtonContainer.widthAnchor.constraint(equalToConstant: 14),
            closeButtonContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 14),
            closeButton.centerXAnchor.constraint(equalTo: closeButtonContainer.centerXAnchor),
            closeButton.centerYAnchor.constraint(equalTo: closeButtonContainer.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
            closeButton.heightAnchor.constraint(equalToConstant: 14),
        ])

        let stack = NSStackView(views: [titleView, closeButtonContainer])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 5, right: 5)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let underline = NSView()
        underline.translatesAutoresizingMaskIntoConstraints = false
        underline.wantsLayer = true
        bindAppearanceReactiveLayer(underline) { view in
            view.layer?.backgroundColor = isSelected ? Theme.accent.cgColor : NSColor.clear.cgColor
        }
        addSubview(underline)

        var constraints = [
            stack.topAnchor.constraint(equalTo: topAnchor), stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            underline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            underline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6), underline.bottomAnchor.constraint(equalTo: bottomAnchor),
            underline.heightAnchor.constraint(equalToConstant: 2),
        ]

        if showsTrailingSeparator {
            let separator = NSView()
            separator.translatesAutoresizingMaskIntoConstraints = false
            separator.wantsLayer = true
            separator.setAccessibilityIdentifier("tab-separator-\(tabID)")
            bindAppearanceReactiveLayer(separator) { view in
                view.layer?.backgroundColor = Theme.border.withAlphaComponent(0.55).cgColor
            }
            addSubview(separator)
            constraints.append(contentsOf: [
                separator.trailingAnchor.constraint(equalTo: trailingAnchor),
                separator.centerYAnchor.constraint(equalTo: centerYAnchor),
                separator.widthAnchor.constraint(equalToConstant: 1),
                separator.heightAnchor.constraint(equalToConstant: 14),
            ])
        }

        NSLayoutConstraint.activate(constraints)

        // Start at the default width; the strip narrows this as tabs accumulate.
        let width = widthAnchor.constraint(equalToConstant: 160)
        width.isActive = true
        widthConstraint = width
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateCloseButtonVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateCloseButtonVisibility()
    }

    private func updateCloseButtonVisibility() {
        closeButton.alphaValue = isHovering ? 1 : 0
        closeButton.isEnabled = isHovering
    }

    /// Set by the strip to give each tab an equal share of the visible width.
    func setPreferredWidth(_ width: CGFloat) {
        guard let widthConstraint, widthConstraint.constant != width else { return }
        widthConstraint.constant = width
    }

    /// The whole tab surface acts as one control: the title label would otherwise
    /// claim (and swallow) mouse events, leaving click-to-select and the context menu
    /// dead over the text. The close button and the inline rename editor (and its
    /// field-editor text view) keep their own hits.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === closeButton { return closeButton.isEnabled ? closeButton : self }
        if hit is NSButton || hit is NSTextView { return hit }
        if let field = hit as? NSTextField, field.isEditable { return field }
        return self
    }

    /// In the main window the tab strip lives in the titlebar row, where a
    /// non-opaque view defaults to acting as a window-drag area — clicks would move
    /// the window instead of reaching `mouseDown`. The strip's empty trailing space
    /// stays draggable; the tabs themselves must not be.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) { onSelect(tabID) }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let rename = NSMenuItem(title: "Rename Tab", action: #selector(renameClicked), keyEquivalent: "")
        rename.target = self
        rename.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        menu.addItem(rename)
        return menu
    }

    // MARK: - Rename editor delegate

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        guard !renameResolved else { return true }
        renameResolved = true
        onRenameCancel(tabID)
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard !renameResolved, let editor = notification.object as? NSTextField else { return }
        renameResolved = true
        onRenameCommit(tabID, editor.stringValue)
    }

    @objc private func renameClicked() { onRenameRequest(tabID) }

    @objc private func closeClicked() { onClose(tabID) }
}
