import AppKit
import spacesterminalcore
import systembridge

/// The panel's single chrome row: flat tabs (title + close, accent underline on the
/// selected tab) on the left, and the pane actions — split right, split down, new tab —
/// on the right. Splits act on the selected tab's focused pane, so panes carry no
/// header of their own until a tab actually holds more than one. Custom chrome instead
/// of NSTabView so tabs stay compact and support in-strip drag reordering.
@MainActor final class PanelTabBarView: NSView, NSDraggingSource {
    static let preferredHeight: CGFloat = 28
    private static let tabPasteboardType = NSPasteboard.PasteboardType("com.spaces.panel-tab")

    /// When this strip is shared chrome (the main window's titlebar accessory), the
    /// workspace panel currently driving it; background panels leave it alone.
    weak var hostingOwner: AnyObject?

    var onSelectTab: ((String) -> Void)?
    var onCloseTab: ((String) -> Void)?
    /// Move within this strip. The destination is an insertion index in the pre-move tab array.
    var onMoveTab: ((_ tabID: String, _ insertionIndex: Int) -> Void)?
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
    private var draggingTabID: String?
    private var proposedInsertionIndex: Int?
    private var dragAutoScrollTimer: Timer?
    private var dragPointerX: CGFloat?
    private let insertionIndicator = NSView()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        registerForDraggedTypes([Self.tabPasteboardType])

        insertionIndicator.wantsLayer = true
        insertionIndicator.layer?.cornerRadius = 1
        bindAppearanceReactiveLayer(insertionIndicator) { view in view.layer?.backgroundColor = Theme.accentStrong.cgColor }
        insertionIndicator.setAccessibilityIdentifier("tab-insertion-indicator")
        insertionIndicator.isHidden = true

        tabsStack.orientation = .horizontal
        tabsStack.alignment = .centerY
        tabsStack.spacing = 0
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
        // No left inset: the first tab's chip sits flush to the panel's leading edge.
        row.edgeInsets = NSEdgeInsets(top: 3, left: 0, bottom: 3, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(insertionIndicator)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor), row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.preferredHeight),
            scrollView.heightAnchor.constraint(equalTo: row.heightAnchor, constant: -6),
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

    nonisolated static func insertionIndex(tabMidpoints: [CGFloat], pointerX: CGFloat) -> Int {
        tabMidpoints.firstIndex(where: { pointerX < $0 }) ?? tabMidpoints.count
    }

    nonisolated static func dragAutoScrollTargetOffset(
        currentOffset: CGFloat, contentWidth: CGFloat, viewportWidth: CGFloat, pointerX: CGFloat, viewportMinX: CGFloat, edgeWidth: CGFloat = 28,
        step: CGFloat = 24
    ) -> CGFloat {
        let maxOffset = max(0, contentWidth - viewportWidth)
        let clampedOffset = min(max(currentOffset, 0), maxOffset)
        guard maxOffset > 0, viewportWidth > 0, edgeWidth > 0, step > 0 else { return clampedOffset }
        let edgeZoneWidth = min(edgeWidth, viewportWidth / 2)
        if pointerX <= viewportMinX + edgeZoneWidth { return max(0, clampedOffset - step) }
        if pointerX >= viewportMinX + viewportWidth - edgeZoneWidth { return min(maxOffset, clampedOffset + step) }
        return clampedOffset
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

    /// Clears the strip immediately, bypassing rename-time rebuild deferral used for
    /// ordinary layout refreshes.
    func clear() {
        guard !tabIDs.isEmpty || !titlesByTabID.isEmpty || selectedTabID != nil || renamingTabID != nil || rebuildDeferredForRename else { return }
        renamingTabID = nil
        rebuildDeferredForRename = false
        tabIDs = []
        titlesByTabID = [:]
        selectedTabID = nil
        rebuildTabs()
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
                    onSelect: { [weak self] id in self?.onSelectTab?(id) }, onClose: { [weak self] id in self?.onCloseTab?(id) },
                    onBeginDrag: { [weak self] id, event in self?.beginDragging(tabID: id, event: event) },
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

    private func beginDragging(tabID: String, event: NSEvent) {
        guard renamingTabID == nil, draggingTabID == nil, let tabIndex = tabIDs.firstIndex(of: tabID) else { return }
        // Selecting an unselected tab rebuilds the strip during mouseDown. Resolve the replacement
        // item by id instead of snapshotting the detached view that received the original event.
        let tabItems = tabsStack.arrangedSubviews.compactMap { $0 as? PanelTabItemView }
        guard tabItems.indices.contains(tabIndex) else { return }
        let sourceView = tabItems[tabIndex]
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(tabID, forType: Self.tabPasteboardType)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let image = NSImage(size: sourceView.bounds.size)
        if let representation = sourceView.bitmapImageRepForCachingDisplay(in: sourceView.bounds) {
            sourceView.cacheDisplay(in: sourceView.bounds, to: representation)
            image.addRepresentation(representation)
        }
        draggingItem.setDraggingFrame(sourceView.convert(sourceView.bounds, to: self), contents: image)
        draggingTabID = tabID
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { updateDragDestination(sender) }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { updateDragDestination(sender) }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { hideInsertionIndicator() }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard updateDragDestination(sender) == .move, let tabID = draggingTabID, let proposedInsertionIndex else { return false }
        hideInsertionIndicator()
        onMoveTab?(tabID, proposedInsertionIndex)
        return true
    }

    private func updateDragDestination(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let draggingTabID, sender.draggingPasteboard.string(forType: Self.tabPasteboardType) == draggingTabID, tabIDs.contains(draggingTabID)
        else {
            hideInsertionIndicator()
            return []
        }
        let pointer = convert(sender.draggingLocation, from: nil)
        guard scrollView.frame.contains(pointer) else {
            hideInsertionIndicator()
            return []
        }
        let pointerX = pointer.x
        dragPointerX = pointerX
        _ = autoScrollDuringDrag(pointerX: pointerX)
        updateDragAutoScrollTimer()
        updateInsertionIndicator(pointerX: pointerX)
        return .move
    }

    private func updateInsertionIndicator(pointerX: CGFloat) {
        let items = tabsStack.arrangedSubviews.compactMap { $0 as? PanelTabItemView }
        let midpoints = items.map { $0.convert($0.bounds, to: self).midX }
        let insertionIndex = Self.insertionIndex(tabMidpoints: midpoints, pointerX: pointerX)
        proposedInsertionIndex = insertionIndex
        let boundaryX: CGFloat
        if insertionIndex < items.count {
            boundaryX = items[insertionIndex].convert(items[insertionIndex].bounds, to: self).minX
        } else if let last = items.last {
            boundaryX = last.convert(last.bounds, to: self).maxX
        } else {
            boundaryX = scrollView.frame.minX
        }
        insertionIndicator.frame = NSRect(x: boundaryX - 1, y: scrollView.frame.minY + 2, width: 2, height: max(0, scrollView.frame.height - 4))
        insertionIndicator.isHidden = false
    }

    /// Repeated drag updates at either visible edge advance the clip view, making every
    /// insertion boundary reachable without accepting a drag from another strip.
    @discardableResult private func autoScrollDuringDrag(pointerX: CGFloat) -> Bool {
        let clipView = scrollView.contentView
        let targetOffset = Self.dragAutoScrollTargetOffset(
            currentOffset: clipView.bounds.origin.x, contentWidth: scrollView.documentView?.bounds.width ?? 0, viewportWidth: clipView.bounds.width,
            pointerX: pointerX, viewportMinX: scrollView.frame.minX)
        guard targetOffset != clipView.bounds.origin.x else { return false }
        clipView.scroll(to: NSPoint(x: targetOffset, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)
        return true
    }

    /// A drag can remain stationary at an edge, so event-tracking updates alone are not enough.
    /// Continue advancing while the private in-strip drag stays in a scrollable edge zone.
    private func updateDragAutoScrollTimer() {
        guard let pointerX = dragPointerX else {
            stopDragAutoScrollTimer()
            return
        }
        let clipView = scrollView.contentView
        let nextOffset = Self.dragAutoScrollTargetOffset(
            currentOffset: clipView.bounds.origin.x, contentWidth: scrollView.documentView?.bounds.width ?? 0, viewportWidth: clipView.bounds.width,
            pointerX: pointerX, viewportMinX: scrollView.frame.minX)
        guard nextOffset != clipView.bounds.origin.x else {
            stopDragAutoScrollTimer()
            return
        }
        guard dragAutoScrollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.draggingTabID != nil, let pointerX = self.dragPointerX else {
                    self?.stopDragAutoScrollTimer()
                    return
                }
                guard self.autoScrollDuringDrag(pointerX: pointerX) else {
                    self.stopDragAutoScrollTimer()
                    return
                }
                self.updateInsertionIndicator(pointerX: pointerX)
            }
        }
        dragAutoScrollTimer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopDragAutoScrollTimer() {
        dragAutoScrollTimer?.invalidate()
        dragAutoScrollTimer = nil
    }

    private func hideInsertionIndicator() {
        dragPointerX = nil
        stopDragAutoScrollTimer()
        proposedInsertionIndex = nil
        insertionIndicator.isHidden = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggingTabID = nil
        hideInsertionIndicator()
    }
}

/// A single flat tab: title plus a trailing close glyph; the selected tab reads from full-color
/// text and a full-height neutral chip. In rename mode the title is an inline editor: Return or
/// focus loss commits, Esc cancels.
@MainActor private final class PanelTabItemView: NSView, NSTextFieldDelegate {
    private let tabID: String
    private let onSelect: (String) -> Void
    private let onClose: (String) -> Void
    private let onBeginDrag: (String, NSEvent) -> Void
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
        tabID: String, title: String, isSelected: Bool, isRenaming: Bool, onSelect: @escaping (String) -> Void, onClose: @escaping (String) -> Void,
        onBeginDrag: @escaping (String, NSEvent) -> Void, onRenameRequest: @escaping (String) -> Void,
        onRenameCommit: @escaping (String, String) -> Void, onRenameCancel: @escaping (String) -> Void
    ) {
        self.tabID = tabID
        self.onSelect = onSelect
        self.onClose = onClose
        self.onBeginDrag = onBeginDrag
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
            editor.font = Typography.metadata
            editor.delegate = self
            editor.setAccessibilityIdentifier("panel-tab-rename-input")
            // The tab's own width bounds the editor; let it fill and compress inside it.
            editor.setContentHuggingPriority(.defaultLow, for: .horizontal)
            editor.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            renameEditor = editor
            titleView = editor
        } else {
            let titleLabel = NSTextField(labelWithString: title)
            titleLabel.font = isSelected ? Typography.metadataTitle : Typography.metadata
            titleLabel.textColor = isSelected ? Theme.text : Theme.muted
            titleLabel.lineBreakMode = .byTruncatingTail
            // Fill the tab and truncate when it shrinks; the tab width is the only cap.
            titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleView = titleLabel
        }

        closeButton.image =
            NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")?.withSymbolConfiguration(.init(pointSize: 8, weight: .medium))
            ?? NSImage()
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
            closeButton.widthAnchor.constraint(equalToConstant: 14), closeButton.heightAnchor.constraint(equalToConstant: 14),
        ])

        let stack = NSStackView(views: [titleView, closeButtonContainer])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 5, right: 5)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The selected tab reads from a full-height neutral chip that fills the tab cell (no bottom accent
        // underline, which clashed with the focused-pane bar on the pane's top edge directly below). The chip
        // sits behind the title/close stack; tabs are flush (no separators) so it reads like a segmented control.
        let selectionChip = NSView()
        selectionChip.translatesAutoresizingMaskIntoConstraints = false
        selectionChip.wantsLayer = true
        selectionChip.layer?.cornerRadius = 4
        bindAppearanceReactiveLayer(selectionChip) { view in view.layer?.backgroundColor = isSelected ? Theme.chipBg.cgColor : NSColor.clear.cgColor }
        addSubview(selectionChip)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            selectionChip.topAnchor.constraint(equalTo: topAnchor), selectionChip.bottomAnchor.constraint(equalTo: bottomAnchor),
            selectionChip.leadingAnchor.constraint(equalTo: leadingAnchor), selectionChip.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Start at the default width; the strip narrows this as tabs accumulate.
        let width = widthAnchor.constraint(equalToConstant: 160)
        width.isActive = true
        widthConstraint = width
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
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

    override func mouseDragged(with event: NSEvent) { onBeginDrag(tabID, event) }

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
