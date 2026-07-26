import AppKit

/// One pane's content host. Panes carry no chrome of their own — the tab strip is the
/// chrome, and the focused pane's identity (title + close) shows in the right panel's
/// footer. The container view is stable per pane id — `PaneTreeView` re-parents it
/// across structural rebuilds so the hosted content (a Ghostty surface) is never
/// recreated by splits or closes elsewhere in the tree.
@MainActor final class PaneView: NSView {
    let paneID: String

    /// Fired when the user clicks anywhere in the pane, so the coordinator can move
    /// pane focus before the click reaches the content.
    var onFocusRequest: (() -> Void)?

    private let contentContainer = NSView()
    private var contentController: (any PaneContentHosting)?
    /// Accent bar along the pane's top edge shown only when this pane holds focus within a split.
    /// A single-pane tab hides it (there is no ambiguity to resolve). Drawn above the content so the
    /// Ghostty surface never paints over it.
    private let focusIndicator = NSView()
    private var isPaneFocused = false

    init(paneID: String) {
        self.paneID = paneID
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)
        focusIndicator.translatesAutoresizingMaskIntoConstraints = false
        focusIndicator.wantsLayer = true
        focusIndicator.isHidden = true
        bindAppearanceReactiveLayer(focusIndicator) { view in view.layer?.backgroundColor = Theme.accent.cgColor }
        addSubview(focusIndicator)
        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: topAnchor), contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor), contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            focusIndicator.topAnchor.constraint(equalTo: topAnchor), focusIndicator.leadingAnchor.constraint(equalTo: leadingAnchor),
            focusIndicator.trailingAnchor.constraint(equalTo: trailingAnchor), focusIndicator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    /// Toggles the top-edge focus bar. The tree passes `false` for a lone pane so the indicator only
    /// appears when there is more than one pane to disambiguate.
    func setPaneFocused(_ focused: Bool) {
        guard focused != isPaneFocused else { return }
        isPaneFocused = focused
        focusIndicator.isHidden = !focused
    }

    /// Installs (or re-installs after re-parenting) the pane's content view.
    func attachContent(_ controller: any PaneContentHosting) {
        let view = controller.contentView
        for subview in contentContainer.subviews where subview !== view { subview.removeFromSuperview() }
        contentController = controller
        guard view.superview !== contentContainer else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor), view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    override func mouseDown(with event: NSEvent) {
        onFocusRequest?()
        super.mouseDown(with: event)
    }
}
