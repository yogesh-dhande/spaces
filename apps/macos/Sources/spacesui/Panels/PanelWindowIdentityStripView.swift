import AppKit
import spacesterminalcore

/// A global window's identity-strip content: which workspace and pane the window's one tab
/// currently shows.
struct PanelWindowIdentity: Equatable {
    let workspaceLabel: String
    let paneTitle: String
    /// True when the identified pane is a code pane. Every code pane in a global window is
    /// unconditionally retargeted to track the sidebar's selected workspace
    /// (`PanelCoordinator.retargetGlobalWindowCodePanes`), so "follows sidebar" is that same fact
    /// surfaced in the chrome, not a separate, independently toggleable follow mode — a terminal
    /// pane never follows, so this is always false for one.
    let followsSidebar: Bool
}

/// A global window's chrome row (Option B, "identity strip" — see the approved mockup):
/// the same 28px row a `.workspace` panel's tab strip occupies, but showing identity instead of
/// tabs, since a global window carries no tabs (`WorkspacePanelView`'s docstring). Left to right:
/// the pane's workspace, its title, and — for a code pane only — a "follows sidebar" indicator;
/// split-right and split-down sit on the trailing edge, the only way to reach the split-target
/// picker from a global window.
@MainActor final class PanelWindowIdentityStripView: NSView {
    static let preferredHeight = PanelTabBarView.preferredHeight

    /// Split request for the window's one tab's focused (else first) pane — resolved by
    /// `WorkspacePanelView`, same as the tab strip's split buttons.
    var onSplitFocusedPane: ((PaneSplitDirection) -> Void)?
    /// Right-click "Open Selected Pane in New Window" — resolved by `WorkspacePanelView` against the
    /// window's one tab, the identity-strip counterpart of `PanelTabBarView`'s tab-header menu item of
    /// the same name. No tab id parameter: a global window carries exactly one tab
    /// (`WorkspacePanelView`'s docstring), so there is nothing for the strip itself to disambiguate.
    var onOpenSelectedPaneInNewWindow: (() -> Void)?

    private let workspaceChipLabel = NSTextField(labelWithString: "")
    private let paneTitleLabel = NSTextField(labelWithString: "")
    private let followsSidebarLabel = NSTextField(labelWithString: "follows sidebar")
    private var identity: PanelWindowIdentity?
    /// Whether the right-click menu's "Open Selected Pane in New Window" should be offered: the
    /// window's one tab must hold more than one pane (a lone pane has nothing to split off, the
    /// same gate `PanelTabBarView` applies to the tab-header menu's item of the same name), and the
    /// pane the strip displays must be a terminal session, not the Editor. The Editor's window IS
    /// its placement — moving it out would mean recreating it and losing its unsaved buffer — so
    /// the item stays offered only for terminal panes even when the Editor shares the window with
    /// other panes.
    private var canMoveFocusedPane = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        workspaceChipLabel.font = Typography.metadataTitle
        workspaceChipLabel.textColor = Theme.accentStrong
        workspaceChipLabel.lineBreakMode = .byTruncatingTail
        // `.defaultHigh`, not `.required`: the pane title truncates first (lowest resistance, below),
        // then this chip truncates next rather than staying whole and squeezing the trailing split
        // buttons — the window's only split controls — out of the row. See the split buttons' own
        // `.required` compression resistance below for the other end of that ordering.
        workspaceChipLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        workspaceChipLabel.translatesAutoresizingMaskIntoConstraints = false

        let workspaceChipBackground = NSView()
        workspaceChipBackground.translatesAutoresizingMaskIntoConstraints = false
        workspaceChipBackground.wantsLayer = true
        workspaceChipBackground.layer?.cornerRadius = 4
        bindAppearanceReactiveLayer(workspaceChipBackground) { view in view.layer?.backgroundColor = Theme.accentTint.cgColor }
        workspaceChipBackground.addSubview(workspaceChipLabel)
        NSLayoutConstraint.activate([
            workspaceChipLabel.topAnchor.constraint(equalTo: workspaceChipBackground.topAnchor, constant: 1),
            workspaceChipLabel.bottomAnchor.constraint(equalTo: workspaceChipBackground.bottomAnchor, constant: -1),
            workspaceChipLabel.leadingAnchor.constraint(equalTo: workspaceChipBackground.leadingAnchor, constant: 6),
            workspaceChipLabel.trailingAnchor.constraint(equalTo: workspaceChipBackground.trailingAnchor, constant: -6),
        ])

        paneTitleLabel.font = Typography.metadataTitle
        paneTitleLabel.textColor = Theme.text
        paneTitleLabel.lineBreakMode = .byTruncatingTail
        // Lowest compression resistance in the row: the pane title truncates before the workspace
        // chip (`.defaultHigh` above) or anything else gives up space.
        paneTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        paneTitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        followsSidebarLabel.font = Typography.rowDetail
        followsSidebarLabel.textColor = Theme.mutedSecondary
        followsSidebarLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        followsSidebarLabel.setContentHuggingPriority(.required, for: .horizontal)
        followsSidebarLabel.isHidden = true

        let splitRightButton = PanelTabBarView.actionButton(
            symbol: "rectangle.split.2x1", tooltip: "Split right", identifier: "panel-split-right", target: self,
            action: #selector(splitRightClicked))
        let splitDownButton = PanelTabBarView.actionButton(
            symbol: "rectangle.split.1x2", tooltip: "Split down", identifier: "panel-split-down", target: self,
            action: #selector(splitDownClicked))
        // `actionButton` only sets hugging (resist growing); compression resistance defaults to
        // `.defaultHigh`, which a `.required` label could still outrank. These buttons are the
        // window's only split controls (see this type's docstring), so they must never be the ones
        // that give up space to a long label — required on both ends of the row.
        for button in [splitRightButton, splitDownButton] { button.setContentCompressionResistancePriority(.required, for: .horizontal) }

        let identityStack = NSStackView(views: [workspaceChipBackground, paneTitleLabel, followsSidebarLabel])
        identityStack.orientation = .horizontal
        identityStack.alignment = .centerY
        identityStack.spacing = 7
        identityStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [identityStack, splitRightButton, splitDownButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 3, left: 12, bottom: 3, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor), row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.preferredHeight),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func update(identity: PanelWindowIdentity?, canMoveFocusedPane: Bool) {
        self.canMoveFocusedPane = canMoveFocusedPane
        guard identity != self.identity else { return }
        self.identity = identity
        workspaceChipLabel.stringValue = identity?.workspaceLabel ?? ""
        paneTitleLabel.stringValue = identity?.paneTitle ?? ""
        followsSidebarLabel.isHidden = identity?.followsSidebar != true
    }

    /// The strip's only context menu: "Open Selected Pane in New Window", offered exactly when
    /// `canMoveFocusedPane` is true. No other item, since a global window has no tab header of its
    /// own for "Open Tab in New Window" to apply to (see `docs/spec.md`).
    override func menu(for event: NSEvent) -> NSMenu? {
        guard canMoveFocusedPane else { return nil }
        let menu = NSMenu()
        let openPane = NSMenuItem(
            title: "Open Selected Pane in New Window", action: #selector(openSelectedPaneInNewWindowClicked), keyEquivalent: "")
        openPane.target = self
        openPane.image = NSImage(systemSymbolName: "macwindow.badge.plus", accessibilityDescription: nil)
        menu.addItem(openPane)
        return menu
    }

    @objc private func splitRightClicked() { onSplitFocusedPane?(.right) }

    @objc private func splitDownClicked() { onSplitFocusedPane?(.down) }

    @objc private func openSelectedPaneInNewWindowClicked() { onOpenSelectedPaneInNewWindow?() }
}
