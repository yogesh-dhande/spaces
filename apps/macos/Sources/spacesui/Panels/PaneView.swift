import AppKit

/// One pane's chrome and content host: a compact header (title, split-right,
/// split-down, close) above the content view. Start/stop/restart controls are part of
/// the terminal content's own runtime toolbar, not the pane chrome, so lifecycle
/// actions never touch the pane itself. The container view is stable per pane id —
/// `PaneTreeView` re-parents it across structural rebuilds so the hosted content (a
/// Ghostty surface) is never recreated by splits or closes elsewhere in the tree.
@MainActor final class PaneView: NSView {
    let paneID: String

    var onSplit: ((PaneSplitDirection) -> Void)?
    var onClose: (() -> Void)?
    /// Fired when the user clicks anywhere in the pane, so the coordinator can move
    /// pane focus before the click reaches the content.
    var onFocusRequest: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let headerView = NSView()
    private let contentContainer = NSView()
    private var contentController: (any PaneContentHosting)?

    var isFocusedPane: Bool = false {
        didSet { updateFocusChrome() }
    }

    init(paneID: String) {
        self.paneID = paneID
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        buildChrome()
        updateFocusChrome()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    private func buildChrome() {
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.wantsLayer = true

        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = Theme.muted
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let splitRightButton = headerButton(
            symbol: "rectangle.split.2x1", tooltip: "Split right", action: #selector(splitRightClicked))
        let splitDownButton = headerButton(
            symbol: "rectangle.split.1x2", tooltip: "Split down", action: #selector(splitDownClicked))
        let closeButton = headerButton(symbol: "xmark", tooltip: "Close pane", action: #selector(closeClicked))
        closeButton.setAccessibilityIdentifier("pane-close-\(paneID)")

        let headerStack = NSStackView(views: [titleLabel, NSView(), splitRightButton, splitDownButton, closeButton])
        headerStack.orientation = .horizontal
        headerStack.alignment = .centerY
        headerStack.spacing = 4
        headerStack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 6)
        headerStack.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(headerStack)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false

        addSubview(headerView)
        addSubview(contentContainer)
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 24),
            headerStack.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            headerStack.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            headerStack.topAnchor.constraint(equalTo: headerView.topAnchor),
            headerStack.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
            contentContainer.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func headerButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .medium)) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .inline
        button.isBordered = false
        button.toolTip = tooltip
        button.contentTintColor = Theme.mutedSecondary
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateTitle(_ title: String) { titleLabel.stringValue = title }

    /// Installs (or re-installs after re-parenting) the pane's content view. Title
    /// updates arrive through `updateTitle` — the coordinator owns the content's
    /// title-changed callback and fans it out to the pane header and tab label.
    func attachContent(_ controller: any PaneContentHosting) {
        contentController = controller
        titleLabel.stringValue = controller.displayTitle
        let view = controller.contentView
        guard view.superview !== contentContainer else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    /// Panes are flat — no card border or corner radius — so keyboard focus reads from
    /// the header tint alone.
    private func updateFocusChrome() {
        headerView.layer?.backgroundColor = isFocusedPane ? Theme.rowSelectedCard.cgColor : NSColor.clear.cgColor
        titleLabel.textColor = isFocusedPane ? Theme.text : Theme.muted
    }

    override func mouseDown(with event: NSEvent) {
        onFocusRequest?()
        super.mouseDown(with: event)
    }

    @objc private func splitRightClicked() { onSplit?(.right) }
    @objc private func splitDownClicked() { onSplit?(.down) }
    @objc private func closeClicked() { onClose?() }
}
