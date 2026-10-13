import AppKit
import spacesterminalcore

/// Column geometry shared by the Resources table's header and rows.
///
/// Every column but the identity column has a fixed width and the identity column takes the rest, so a
/// header line and a row line of the same width lay out identically without constraints between them.
/// That independence is what lets rows be reordered and reused between ticks: a grid whose rows are tied
/// to the header (`TableGrid`) loses those ties when a row leaves the table.
enum ResourcesTableLayout {
    static let deviceWidth: CGFloat = 96
    static let cpuWidth: CGFloat = 64
    static let memoryWidth: CGFloat = 76
    static let historyWidth: CGFloat = 120
    static let jumpWidth: CGFloat = 28
    static let rowHeight: CGFloat = 30
    static let sideInset: CGFloat = 4

    /// A line of columns: `identity` first and flexible, then the fixed-width columns.
    @MainActor static func makeLine(identity: NSView, device: NSView?, cpu: NSView, memory: NSView, history: NSView, jump: NSView) -> NSStackView {
        identity.translatesAutoresizingMaskIntoConstraints = false
        identity.setContentHuggingPriority(NSLayoutConstraint.Priority(100), for: .horizontal)
        identity.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(100), for: .horizontal)
        var columns: [NSView] = [identity]
        if let device { columns.append(fixed(device, deviceWidth)) }
        columns += [fixed(cpu, cpuWidth), fixed(memory, memoryWidth), fixed(history, historyWidth), fixed(jump, jumpWidth)]
        let line = NSStackView(views: columns)
        line.orientation = .horizontal
        line.alignment = .centerY
        line.distribution = .fill
        line.spacing = TableGrid.spacing
        line.edgeInsets = NSEdgeInsets(top: 0, left: TableGrid.horizontalInset, bottom: 0, right: TableGrid.horizontalInset)
        line.translatesAutoresizingMaskIntoConstraints = false
        return line
    }

    @MainActor private static func fixed(_ view: NSView, _ width: CGFloat) -> NSView {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
        return view
    }
}

/// One row of the Resources table. The view is created once per row identity and `update` rewrites its
/// labels and sparkline in place, so a tick never rebuilds it.
///
/// The jump button and a double-click on the row both run `onJump`. A row that cannot jump hides the
/// button, and its owner ignores the double-click.
@MainActor final class ResourcesTableRow: NSObject {
    let view: AutomationsTableRowView
    private let onJump: () -> Void

    private let agentGlyph = NSImageView()
    private let projectLabel = ResourcesTableRow.label(font: Typography.rowLabel, color: Theme.muted)
    private let firstSeparator = ResourcesTableRow.label(font: Typography.rowLabel, color: Theme.muted, text: "/")
    private let workspaceLabel = ResourcesTableRow.label(font: Typography.rowLabel, color: Theme.muted)
    private let secondSeparator = ResourcesTableRow.label(font: Typography.rowLabel, color: Theme.muted, text: "/")
    private let terminalLabel = ResourcesTableRow.label(font: Typography.rowLabel, color: Theme.text)
    private let deviceLabel = ResourcesTableRow.label(font: Typography.rowDetail, color: Theme.muted)
    private let cpuLabel = ResourcesTableRow.label(font: Typography.tabularDigits(Typography.rowDetail), color: Theme.text)
    private let memoryLabel = ResourcesTableRow.label(font: Typography.tabularDigits(Typography.rowDetail), color: Theme.text)
    private let sparkline = ResourcesSparklineView()
    private let jumpButton = NSButton()

    init(id: String, showsDevice: Bool, jumpTooltip: String, onJump: @escaping () -> Void) {
        self.onJump = onJump
        view = AutomationsTableRowView(onDoubleClick: onJump)
        super.init()
        view.setAccessibilityIdentifier("resources.row.\(id)")

        agentGlyph.translatesAutoresizingMaskIntoConstraints = false
        agentGlyph.contentTintColor = Theme.muted
        NSLayoutConstraint.activate([agentGlyph.widthAnchor.constraint(equalToConstant: 14), agentGlyph.heightAnchor.constraint(equalToConstant: 14)])
        // The names give way in order: project first, workspace next, the terminal's own name last.
        projectLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(250), for: .horizontal)
        workspaceLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(300), for: .horizontal)
        terminalLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(750), for: .horizontal)
        for separator in [firstSeparator, secondSeparator] { separator.setContentCompressionResistancePriority(.required, for: .horizontal) }
        let identity = NSStackView(views: [agentGlyph, projectLabel, firstSeparator, workspaceLabel, secondSeparator, terminalLabel, NSView()])
        identity.orientation = .horizontal
        identity.alignment = .centerY
        identity.spacing = 4
        identity.setCustomSpacing(6, after: agentGlyph)

        cpuLabel.alignment = .right
        memoryLabel.alignment = .right
        sparkline.translatesAutoresizingMaskIntoConstraints = false
        sparkline.heightAnchor.constraint(equalToConstant: 18).isActive = true

        jumpButton.isBordered = false
        jumpButton.image = NSImage(systemSymbolName: "arrow.right.circle", accessibilityDescription: jumpTooltip)
        jumpButton.contentTintColor = Theme.muted
        jumpButton.toolTip = jumpTooltip
        jumpButton.target = self
        jumpButton.action = #selector(jumpTapped)

        let line = ResourcesTableLayout.makeLine(
            identity: identity, device: showsDevice ? deviceLabel : nil, cpu: cpuLabel, memory: memoryLabel, history: sparkline, jump: jumpButton)
        view.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: view.leadingAnchor), line.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            line.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            view.heightAnchor.constraint(equalToConstant: ResourcesTableLayout.rowHeight),
        ])
    }

    @objc private func jumpTapped() { onJump() }

    func update(_ row: ResourcesRow) {
        agentGlyph.image = row.runsAgent ? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Coding agent") : nil
        projectLabel.stringValue = row.projectName
        workspaceLabel.stringValue = row.workspaceName
        terminalLabel.stringValue = row.terminalName ?? ""
        // A workspace row ends at the workspace, which is then the row's own name.
        secondSeparator.isHidden = row.terminalName == nil
        terminalLabel.isHidden = row.terminalName == nil
        workspaceLabel.textColor = row.terminalName == nil ? Theme.text : Theme.muted
        deviceLabel.stringValue = row.deviceName
        cpuLabel.stringValue = ResourcesFormatting.cpu(row.cpuPercent)
        memoryLabel.stringValue = ResourcesFormatting.memory(row.memoryBytes)
        sparkline.values = row.history
        // Hiding the button would detach it from the row's stack and shift every column after it, so a
        // row with nowhere to jump keeps the slot and only makes the button invisible and inert.
        jumpButton.alphaValue = row.canJump ? 1 : 0
        jumpButton.isEnabled = row.canJump
    }

    private static func label(font: NSFont, color: NSColor, text: String = "") -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }
}
