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

    init(paneID: String) {
        self.paneID = paneID
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)
        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: topAnchor), contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor), contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

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
