import AppKit
import spacesterminalcore

/// The Resources pane's views: header, two summary cards, and the table. Built once when the pane
/// opens; `update` rewrites the cards and table rows in place on every sample, so a tick never
/// rebuilds the pane, flickers, or moves the scroll position.
///
/// The table is rebuilt only when its shape changes: the mode switch, or the Device column appearing
/// once a second device reports.
@MainActor final class ResourcesPaneView: NSObject {
    let stack = NSStackView()
    var onModeChange: ((ResourcesMode) -> Void)?
    var onSortChange: ((ResourcesSortColumn) -> Void)?
    var onJump: ((ResourcesRow) -> Void)?

    private let terminalsCard = ResourcesCardView(title: "Your terminals", caption: "agents, dev servers, tests")
    private let spacesCard = ResourcesCardView(title: "Spaces itself", caption: "not counted in your terminals")
    private let modeControl = NSSegmentedControl(labels: ["Terminals", "Workspaces"], trackingMode: .selectOne, target: nil, action: nil)
    private let tableStack = NSStackView()
    private let placeholder = NSTextField(labelWithString: "")
    private let cpuHeader = NSButton()
    private let memoryHeader = NSButton()

    private var tableShape: (mode: ResourcesMode, showsDevice: Bool)?
    private var tableRows: [String: ResourcesTableRow] = [:]
    private var rowsByID: [String: ResourcesRow] = [:]
    private var sort: ResourcesSortColumn

    init(mode: ResourcesMode, sort: ResourcesSortColumn) {
        self.sort = sort
        super.init()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        modeControl.selectedSegment = mode.rawValue
        modeControl.target = self
        modeControl.action = #selector(modeChanged)

        let header = makeHeader()
        let cards = makeCards()
        let caption = NSTextField(labelWithString: "YOUR TERMINALS")
        caption.font = Typography.metadataTitle
        caption.textColor = Theme.mutedSecondary
        let footnote = NSTextField(
            wrappingLabelWithString: "Processes that detach from a terminal, like Docker containers and background daemons, aren't counted.")
        footnote.font = Typography.caption
        footnote.textColor = Theme.muted

        tableStack.orientation = .vertical
        tableStack.alignment = .leading
        tableStack.spacing = 0
        tableStack.edgeInsets = NSEdgeInsets(top: 6, left: ResourcesTableLayout.sideInset, bottom: 6, right: ResourcesTableLayout.sideInset)
        tableStack.translatesAutoresizingMaskIntoConstraints = false
        placeholder.font = Typography.rowDetail
        placeholder.textColor = Theme.muted

        for view in [header, cards, caption, tableStack, footnote] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(18, after: cards)
        stack.setCustomSpacing(6, after: caption)
        for view in [header, cards, tableStack, footnote] { constrainFormFieldToFillWidth(view, in: stack) }
    }

    // MARK: - Building

    private func makeHeader() -> NSView {
        let title = NSTextField(labelWithString: "Resources")
        title.font = Typography.pageTitle
        title.textColor = Theme.text
        let subtitle = NSTextField(
            wrappingLabelWithString: "Updated every 2 seconds while this pane is open. CPU is a share of one core, so a busy process can pass 100%.")
        subtitle.font = Typography.metadata
        subtitle.textColor = Theme.muted
        subtitle.preferredMaxLayoutWidth = 520
        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        let row = NSStackView(views: [titles, NSView(), modeControl])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        return row
    }

    private func makeCards() -> NSView {
        // Stacked so each card gets the full pane width; beside each other, the cards truncate device names and details.
        let column = NSStackView(views: [terminalsCard, spacesCard])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        for card in [terminalsCard, spacesCard] { card.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        return column
    }

    private func makeTableHeader(mode: ResourcesMode, showsDevice: Bool) -> NSView {
        func title(_ text: String, alignment: NSTextAlignment = .left) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = Typography.metadataTitle
            label.textColor = Theme.mutedSecondary
            label.alignment = alignment
            return label
        }
        for (button, action) in [(cpuHeader, #selector(cpuHeaderTapped)), (memoryHeader, #selector(memoryHeaderTapped))] {
            button.isBordered = false
            button.imagePosition = .noImage
            button.alignment = .right
            button.target = self
            button.action = action
        }
        cpuHeader.toolTip = "Sort by CPU"
        memoryHeader.toolTip = "Sort by memory"
        updateSortHeaders()
        let line = ResourcesTableLayout.makeLine(
            identity: title(mode == .terminals ? "Terminal" : "Workspace"), device: showsDevice ? title("Device") : nil, cpu: cpuHeader,
            memory: memoryHeader, history: title("Since opened"), jump: NSView())
        return line
    }

    private func updateSortHeaders() {
        func attributed(_ text: String, isActive: Bool) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .right
            return NSAttributedString(
                string: isActive ? "\(text) ▾" : text,
                attributes: [
                    .font: Typography.metadataTitle, .foregroundColor: isActive ? Theme.text : Theme.mutedSecondary, .paragraphStyle: paragraph,
                ])
        }
        cpuHeader.attributedTitle = attributed("CPU", isActive: sort == .cpu)
        memoryHeader.attributedTitle = attributed("Memory", isActive: sort == .memory)
    }

    private func makeDivider() -> NSView {
        let divider = ColoredBackgroundView()
        divider.fillColor = Theme.border
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return divider
    }

    // MARK: - Updating

    func update(
        mode: ResourcesMode, sort: ResourcesSortColumn, terminals: [ResourcesCardLine], spaces: [ResourcesCardLine], rows: [ResourcesRow],
        hasMeasurement: Bool, showsDevice: Bool
    ) {
        terminalsCard.update(lines: terminals)
        spacesCard.update(lines: spaces)
        modeControl.selectedSegment = mode.rawValue
        if self.sort != sort {
            self.sort = sort
            updateSortHeaders()
        }
        if tableShape?.mode != mode || tableShape?.showsDevice != showsDevice { rebuildTable(mode: mode, showsDevice: showsDevice) }
        updateRows(rows, mode: mode, showsDevice: showsDevice)
        placeholder.stringValue = hasMeasurement ? "No terminals are running." : "Measuring…"
        placeholder.isHidden = !rows.isEmpty
    }

    private func rebuildTable(mode: ResourcesMode, showsDevice: Bool) {
        for view in tableStack.arrangedSubviews {
            tableStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        tableRows = [:]
        let header = makeTableHeader(mode: mode, showsDevice: showsDevice)
        let divider = makeDivider()
        for line in [header, divider, placeholder] { tableStack.addArrangedSubview(line) }
        tableStack.setCustomSpacing(4, after: header)
        tableStack.setCustomSpacing(4, after: divider)
        let inset = ResourcesTableLayout.sideInset * 2
        for line in [header, divider] { line.widthAnchor.constraint(equalTo: tableStack.widthAnchor, constant: -inset).isActive = true }
        tableShape = (mode, showsDevice)
    }

    private func updateRows(_ rows: [ResourcesRow], mode: ResourcesMode, showsDevice: Bool) {
        rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        for (id, tableRow) in tableRows where rowsByID[id] == nil {
            tableStack.removeArrangedSubview(tableRow.view)
            tableRow.view.removeFromSuperview()
            tableRows[id] = nil
        }
        var orderedViews: [NSView] = []
        for row in rows {
            let tableRow =
                tableRows[row.id]
                ?? {
                    let created = ResourcesTableRow(
                        id: row.id, showsDevice: showsDevice, jumpTooltip: mode == .terminals ? "Go to terminal" : "Go to workspace"
                    ) { [weak self] in
                        guard let self, let current = rowsByID[row.id], current.canJump else { return }
                        onJump?(current)
                    }
                    tableRows[row.id] = created
                    return created
                }()
            tableRow.update(row)
            orderedViews.append(tableRow.view)
        }
        // Rows sit after the header, divider, and placeholder. Rewriting the order only when it changed
        // keeps a steady tick from touching the stack at all.
        let fixedCount = 3
        let current = tableStack.arrangedSubviews.dropFirst(fixedCount)
        guard current.count != orderedViews.count || !zip(current, orderedViews).allSatisfy({ $0 === $1 }) else { return }
        let inset = ResourcesTableLayout.sideInset * 2
        // `removeArrangedSubview` throws for a view the stack does not hold, so only current rows are
        // detached; a detached row keeps its superview, which is how a new row is told apart.
        for view in current { tableStack.removeArrangedSubview(view) }
        for view in orderedViews {
            let isNew = view.superview == nil
            tableStack.addArrangedSubview(view)
            if isNew { view.widthAnchor.constraint(equalTo: tableStack.widthAnchor, constant: -inset).isActive = true }
        }
    }

    // MARK: - Actions

    @objc private func modeChanged() { onModeChange?(ResourcesMode(rawValue: modeControl.selectedSegment) ?? .terminals) }
    @objc private func cpuHeaderTapped() { onSortChange?(.cpu) }
    @objc private func memoryHeaderTapped() { onSortChange?(.memory) }
}
