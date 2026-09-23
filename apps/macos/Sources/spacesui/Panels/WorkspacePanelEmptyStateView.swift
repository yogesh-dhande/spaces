import AppKit
import spacesterminalcore

/// Everything the workspace panel's empty state draws: the workspace's identity and which of its two
/// recovery actions apply right now. Computed by `AppKitController.workspacePanelEmptyState(scope:)`
/// and compared whole, so the overview ticks that arrive every few seconds rebuild nothing unless one
/// of these values actually moved (the block would otherwise be torn down under the pointer between
/// mouse-down and mouse-up, the same hazard the workspace footer's signature guards against).
struct WorkspacePanelEmptyState: Equatable {
    let workspaceName: String
    let directory: String
    /// Whether the workspace still owes a Start, from
    /// `AppKitController.workspaceLifecycleControlsOfferStart`.
    let offersStart: Bool
    let deviceAcceptsDaemonActions: Bool
    let unreachableDeviceTooltip: String?
    /// The `New terminal` leader shortcut as the hint line renders it.
    let newTerminalShortcutHint: String
}

/// The empty state's actions, in the order they are offered.
enum WorkspacePanelEmptyStateAction: Equatable {
    case start
    case newTerminal
}

extension WorkspacePanelEmptyState {
    /// Start is offered only while the workspace has something to start, the same rule the sidebar row
    /// menu, the workspace footer, and the iOS control bar follow: a running workspace with every
    /// configured process up has nothing left for Start to do, so its empty panel offers New terminal
    /// alone rather than a control that cannot fire.
    var offeredActions: [WorkspacePanelEmptyStateAction] { offersStart ? [.start, .newTerminal] : [.newTerminal] }

    /// Both actions write through the workspace's own daemon, so an unreachable device offers them
    /// disabled and dimmed with the device named in their tooltip — the treatment the workspace
    /// footer's controls and the sidebar's rows already use — rather than dropping them, which would
    /// leave the pane with no account of itself at all.
    var actionsAreEnabled: Bool { deviceAcceptsDaemonActions }
}

/// The centered block a workspace panel shows while it holds no tabs: the workspace's name and
/// directory over labeled pill buttons for the two actions that fill the pane, with the New terminal
/// shortcut spelled out beneath them.
///
/// A panel window (`.globalWindow`) never shows this — such a window closes when its last pane goes,
/// so it has no empty state to recover from — and the view stays hidden there.
@MainActor final class WorkspacePanelEmptyStateView: NSView {
    var onStartWorkspace: (() -> Void)?
    var onNewTerminal: (() -> Void)?

    private let nameLabel = NSTextField(labelWithString: "")
    private let directoryLabel = NSTextField(labelWithString: "")
    private let buttonRow = NSStackView()
    private let hintRow = NSStackView()
    private var renderedState: WorkspacePanelEmptyState?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = Typography.emptyStateTitle
        nameLabel.textColor = Theme.text
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setAccessibilityIdentifier("workspace-panel-empty-name")

        directoryLabel.font = Typography.monoCaption
        directoryLabel.textColor = Theme.mutedSecondary
        directoryLabel.alignment = .center
        directoryLabel.lineBreakMode = .byTruncatingMiddle
        // Both labels yield before the block's width cap below, so a long name or path truncates
        // instead of pushing the block past the pane's edges.
        directoryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        directoryLabel.setAccessibilityIdentifier("workspace-panel-empty-dir")

        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10

        hintRow.orientation = .horizontal
        hintRow.alignment = .centerY
        hintRow.spacing = 6

        let column = NSStackView(views: [nameLabel, directoryLabel, buttonRow, hintRow])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 0
        column.setCustomSpacing(3, after: nameLabel)
        column.setCustomSpacing(16, after: directoryLabel)
        column.setCustomSpacing(14, after: buttonRow)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor), column.centerYAnchor.constraint(equalTo: centerYAnchor),
            column.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    func update(state: WorkspacePanelEmptyState) {
        guard state != renderedState else { return }
        renderedState = state
        nameLabel.stringValue = state.workspaceName
        directoryLabel.stringValue = state.directory
        directoryLabel.toolTip = state.directory
        rebuildButtons(state: state)
        rebuildHint(state: state)
    }

    private func rebuildButtons(state: WorkspacePanelEmptyState) {
        clear(buttonRow)
        for action in state.offeredActions {
            let button: NSButton =
                switch action {
                case .start:
                    pillButton(
                        title: "Start workspace", symbol: "play.fill", tint: Theme.accent, identifier: "workspace-panel-empty-start",
                        action: #selector(startClicked))
                case .newTerminal:
                    pillButton(
                        title: "New terminal", symbol: "plus", tint: Theme.muted, identifier: "workspace-panel-empty-new-terminal",
                        action: #selector(newTerminalClicked))
                }
            if !state.actionsAreEnabled {
                button.isEnabled = false
                button.alphaValue = AppKitController.unreachableDeviceAlpha
                if let tooltip = state.unreachableDeviceTooltip { button.toolTip = tooltip }
            }
            buttonRow.addArrangedSubview(button)
        }
    }

    private func rebuildHint(state: WorkspacePanelEmptyState) {
        clear(hintRow)
        hintRow.addArrangedSubview(RowPrimitives.shortcutChip(state.newTerminalShortcutHint))
        let label = NSTextField(labelWithString: "new terminal")
        label.font = Typography.caption
        label.textColor = Theme.mutedSecondary
        hintRow.addArrangedSubview(label)
    }

    private func clear(_ row: NSStackView) {
        for view in row.arrangedSubviews {
            row.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    /// The compact labeled pill the iPhone's workspace control bar uses, drawn with AppKit: a glyph
    /// beside a text label on the secondary surface, because an icon alone cannot say what Start
    /// starts. The width is measured from the title rather than left to the button's intrinsic size,
    /// which a borderless `NSButton` derives from its bezel padding rather than from these insets.
    private func pillButton(title: String, symbol: String, tint: NSColor, identifier: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(
            .init(pointSize: 10, weight: .semibold))
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = tint
        button.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: tint, .font: Typography.controlLabel])
        button.setAccessibilityIdentifier(identifier)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.layer?.masksToBounds = true
        button.layer?.borderWidth = 1
        bindAppearanceReactiveLayer(button) { view in
            view.layer?.backgroundColor = Theme.surface2.cgColor
            view.layer?.borderColor = Theme.border.cgColor
        }
        let contentWidth = ceil(
            button.attributedTitle.size().width + (button.image?.size.width ?? 0) + Self.glyphSpacing + 2 * Self.horizontalPadding)
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: Self.pillHeight),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: contentWidth),
        ])
        return button
    }

    /// The iOS control bar's pill metrics: 9 pt of horizontal padding and 5 pt above and below a
    /// 12 pt label, which is this height.
    private static let pillHeight: CGFloat = 24
    private static let horizontalPadding: CGFloat = 9
    private static let glyphSpacing: CGFloat = 4

    @objc private func startClicked() { onStartWorkspace?() }

    @objc private func newTerminalClicked() { onNewTerminal?() }
}
