import AppKit
import Foundation
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import workspacecore

/// Owns the Automations detail pane's state and behavior. `AppKitController` holds a single instance and
/// delegates automations interactions to it, reaching back into the host for shared window/model/device
/// services via `host` (the unowned-host sub-controller pattern shared with `AlertsController`).
///
/// The pane merges every paired device's overview slice (local daemon included) into two tabs — the
/// automations table and the runs table — and refreshes on the app's existing overview cadence: the host
/// re-invokes `showAutomationsDetail()` whenever an overview update lands while this pane is visible.
@MainActor final class AutomationsController: NSObject {
    unowned let host: AppKitController

    init(host: AppKitController) {
        self.host = host
        super.init()
    }

    enum Tab: Int {
        case automations
        case runs
    }

    /// Which tab is shown. Persisted across re-renders so an overview refresh keeps the user's place.
    private var selectedTab: Tab = .automations
    /// Slow re-render beat keeping the visible pane's relative times fresh; see `armRelativeTimeRefresh`.
    private var relativeTimeRefreshTimer: Timer?
    /// The device filter, or nil for "All devices". Persisted across re-renders.
    private var deviceFilterID: String?

    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
    private let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()
    nonisolated(unsafe) private static let iso8601Formatter = ISO8601DateFormatter()

    // MARK: - Presentation

    /// Deep-links to the Runs tab, filtered to a device, and shows the pane — used by an automation alert
    /// card. `runID` is accepted for symmetry with the alert target but the runs table already surfaces every
    /// recent run, so no separate scroll-to is needed.
    func showRunsForAlert(deviceID: String, runID: String) {
        selectedTab = .runs
        deviceFilterID = deviceID
        showAutomationsDetail()
    }

    func showAutomationsDetail() {
        host.clearActiveAddFormStateAndCloseWindows()
        host.stopWorkspaceSetupDetailRefreshTimer()
        host.presentDetailPane(.automations)
        host.showingSettings = false
        let previousProjectID = host.selectedProjectID
        let previousWorkspaceID = host.selectedWorkspaceID
        host.selectedProjectID = nil
        host.selectedWorkspaceID = nil
        host.outlineView.deselectAll(nil)
        host.refreshSidebarSelectionRows(
            previousProjectID: previousProjectID, currentProjectID: nil, previousWorkspaceID: previousWorkspaceID, currentWorkspaceID: nil)
        host.updateAlertsRowAppearance()
        host.updateAutomationsSidebarRow()

        host.clearWorkspaceDetailFooter()
        for view in host.detailContainer.subviews { view.removeFromSuperview() }
        host.detailContainer.wantsLayer = true
        bindAppearanceReactiveLayer(host.detailContainer) { [unowned host] view in
            view.layer?.backgroundColor = host.sidebarPanelBackgroundColor().cgColor
        }

        let inputs = host.automationDeviceInputs()
        // A dropped device would otherwise vanish from the filter; keep "All devices" selected instead.
        if let filter = deviceFilterID, !inputs.contains(where: { $0.deviceID == filter }) { deviceFilterID = nil }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(makeHeaderRow(inputs: inputs))
        host.constrainFormFieldToFillWidth(stack.arrangedSubviews[0], in: stack)

        let tabControl = makeTabControl()
        stack.addArrangedSubview(tabControl)

        for device in AutomationsViewModel.unreachableDevices(from: inputs) {
            let marker = makeUnreachableMarker(device)
            stack.addArrangedSubview(marker)
            host.constrainFormFieldToFillWidth(marker, in: stack)
        }

        switch selectedTab {
        case .automations: appendAutomationsTab(to: stack, inputs: inputs)
        case .runs: appendRunsTab(to: stack, inputs: inputs)
        }

        host.showScrollableDetailStack(stack)
        armRelativeTimeRefresh()
    }

    /// Re-renders the visible pane on a slow beat so its relative times (next-run countdowns, running
    /// durations) track the clock between overview refreshes; a single render's snapshot would otherwise
    /// read "in 4 m" indefinitely on an idle system. The timer rides the default run-loop mode, so an open
    /// context menu (which runs the tracking mode) pauses the rebuild instead of having its menu torn down.
    /// Self-invalidating: the pane's own rebuild re-arms it, and a switch to any other pane lets it lapse.
    private func armRelativeTimeRefresh() {
        relativeTimeRefreshTimer?.invalidate()
        relativeTimeRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, host.showingAutomations else { return }
                showAutomationsDetail()
            }
        }
    }

    // MARK: - Header & tabs

    private func makeHeaderRow(inputs: [AutomationDeviceInput]) -> NSView {
        let title = NSTextField(labelWithString: "Automations")
        title.font = Typography.pageTitle
        title.textColor = host.sidebarPrimaryTextColor(isSelected: false)
        title.setContentHuggingPriority(.required, for: .horizontal)

        let devicePopUp = NSPopUpButton()
        devicePopUp.addItem(withTitle: "All devices")
        devicePopUp.itemArray.last?.representedObject = nil
        for input in inputs {
            devicePopUp.addItem(withTitle: input.deviceName)
            devicePopUp.itemArray.last?.representedObject = input.deviceID
            if input.deviceID == deviceFilterID { devicePopUp.select(devicePopUp.itemArray.last) }
        }
        devicePopUp.target = self
        devicePopUp.action = #selector(deviceFilterChanged(_:))
        devicePopUp.setContentHuggingPriority(.required, for: .horizontal)

        let newButton = host.actionButton(
            title: "New automation", symbol: "plus", tooltip: "Create an automation", action: #selector(newAutomationTapped), primary: true)
        newButton.target = self

        let row = NSStackView(views: [title, NSView(), devicePopUp, newButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func makeTabControl() -> NSView {
        let segmented = NSSegmentedControl(
            labels: ["Automations", "Runs"], trackingMode: .selectOne, target: self, action: #selector(tabChanged(_:)))
        segmented.selectedSegment = selectedTab.rawValue
        segmented.translatesAutoresizingMaskIntoConstraints = false
        return segmented
    }

    private func makeUnreachableMarker(_ device: AutomationUnreachableDevice) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Unreachable")
        icon.contentTintColor = host.sidebarThemeColor(light: (180, 120, 0), dark: (230, 170, 40))
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let label = NSTextField(labelWithString: "\(device.deviceName) is unreachable\(device.message.map { " — \($0)" } ?? "")")
        label.font = Typography.metadata
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        row.wantsLayer = true
        row.layer?.cornerRadius = 8
        bindAppearanceReactiveLayer(row) { [unowned host] view in view.layer?.backgroundColor = host.sidebarCardBackgroundColor().cgColor }
        return row
    }

    // MARK: - Automations tab

    private func appendAutomationsTab(to stack: NSStackView, inputs: [AutomationDeviceInput]) {
        let rows = AutomationsViewModel.filterAutomations(AutomationsViewModel.mergedAutomations(from: inputs), deviceID: deviceFilterID)
        guard !rows.isEmpty else {
            appendEmptyState(to: stack, icon: "clock.arrow.circlepath", title: "No automations", detail: "Create one to run a command on a schedule.")
            return
        }
        // The device column earns its width only when the table actually spans devices; with one device
        // paired, or the filter narrowed to one, it would repeat the same name down every row.
        let showDevice = Set(rows.map(\.deviceID)).count > 1
        // One clock for the whole render so every relative time in the table is measured from the same
        // instant and the columns stay consistent with each other.
        let now = Date()

        let sideInset: CGFloat = 4
        let table = NSStackView()
        table.orientation = .vertical
        table.alignment = .leading
        table.spacing = 0
        table.edgeInsets = NSEdgeInsets(top: 6, left: sideInset, bottom: 6, right: sideInset)
        table.translatesAutoresizingMaskIntoConstraints = false

        let header = makeAutomationHeaderLine(showDevice: showDevice)
        let divider = makeTableDivider()
        let lines: [NSView] = [header, divider] + rows.map { makeAutomationRow($0, showDevice: showDevice, now: now) }
        for line in lines { table.addArrangedSubview(line) }
        table.setCustomSpacing(4, after: header)
        table.setCustomSpacing(4, after: divider)

        let card = cardContainer(table)
        // Leading alignment gives arranged lines their intrinsic width, so pin each to the table's full
        // width (minus its edge insets) to keep the grid's trailing columns right-aligned.
        for line in lines { line.widthAnchor.constraint(equalTo: table.widthAnchor, constant: -sideInset * 2).isActive = true }
        stack.addArrangedSubview(card)
        host.constrainFormFieldToFillWidth(card, in: stack)
    }

    private func makeAutomationHeaderLine(showDevice: Bool) -> NSView {
        func header(_ text: String, alignment: NSTextAlignment = .left) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = Typography.metadataTitle
            label.textColor = Theme.mutedSecondary
            label.alignment = alignment
            label.lineBreakMode = .byTruncatingTail
            return label
        }
        let line = AutomationTableColumns.layOut(
            status: RowPrimitives.statusSlot(), name: header("Name"), schedule: header("Schedule"), nextRun: header("Next run", alignment: .right),
            lastResult: header("Last result"), device: showDevice ? header("Device") : nil, toggle: header("On"),
            action: header("", alignment: .right))
        // The same inset each row applies between its own edges and its columns, so header and rows share
        // one grid origin.
        line.edgeInsets = NSEdgeInsets(top: 0, left: AutomationTableColumns.horizontalInset, bottom: 0, right: AutomationTableColumns.horizontalInset)
        return line
    }

    private func makeTableDivider() -> NSView {
        let divider = ColoredBackgroundView()
        divider.fillColor = Theme.border
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return divider
    }

    private func makeAutomationRow(_ row: AutomationTableRow, showDevice: Bool, now: Date) -> NSView {
        let automation = row.automation
        let identifier = NSUserInterfaceItemIdentifier("\(row.deviceID)::\(automation.id)")

        let rowView = AutomationsTableRowView { [weak self] in self?.presentEditor(deviceID: row.deviceID, automationID: automation.id) }
        rowView.menu = makeAutomationRowMenu(row)
        rowView.setAccessibilityIdentifier("automations.row.\(row.id)")
        // The table has no room for the one-line excerpt the card layout showed, so what an automation
        // actually does stays reachable as the row's tooltip.
        let excerpt = AutomationsViewModel.excerpt(for: automation)
        if !excerpt.isEmpty { rowView.toolTip = excerpt }
        // A disabled automation dims whole-row, the same 55% treatment that marks an unreachable device's
        // rows. Opacity does not block hit-testing, so its enable switch stays usable.
        if !automation.enabled { rowView.alphaValue = Self.disabledRowAlpha }

        let name = NSTextField(labelWithString: automation.name)
        name.font = Typography.rowLabel
        name.textColor = Theme.text
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let nameColumn = NSStackView(views: [name, makeKindChip(automation), NSView()])
        nameColumn.orientation = .horizontal
        nameColumn.alignment = .centerY
        nameColumn.spacing = 6

        let schedule = AutomationsViewModel.scheduleDescription(for: automation)
        var scheduleViews: [NSView] = [makeCellLabel(schedule.summary, font: Typography.rowDetail, color: Theme.text)]
        if let cron = schedule.cronDetail { scheduleViews.append(makeCellLabel(cron, font: Typography.monoMetadata, color: Theme.muted)) }
        let scheduleColumn = NSStackView(views: scheduleViews)
        scheduleColumn.orientation = .horizontal
        // Baseline alignment so the 12 pt summary and the 11 pt monospaced cron sit on one line. The last
        // label absorbs the column's leftover width, which keeps both left-aligned without a spacer view
        // (a plain spacer has no baseline to align to).
        scheduleColumn.alignment = .firstBaseline
        scheduleColumn.spacing = 6
        // The column is too narrow for a long weekly schedule plus its cron string, so the full text stays
        // available on hover rather than being lost to truncation.
        scheduleColumn.toolTip = schedule.cronDetail.map { "\(schedule.summary) (\($0))" } ?? schedule.summary

        let nextRun = makeCellLabel(
            AutomationsViewModel.nextRunDescription(for: automation, now: now), font: Self.tabularFigures(Typography.rowDetail), color: Theme.muted)
        nextRun.alignment = .right

        let result = AutomationsViewModel.lastResultDescription(for: row.latestRun, now: now)
        let lastResult = makeCellLabel(
            result.text, font: Self.tabularFigures(Typography.rowDetail), color: result.isFailure ? Theme.statusFailed : Theme.muted)

        let enabledSwitch = NSSwitch()
        enabledSwitch.controlSize = .small
        enabledSwitch.state = automation.enabled ? .on : .off
        enabledSwitch.target = self
        enabledSwitch.action = #selector(enabledToggled(_:))
        enabledSwitch.identifier = identifier
        enabledSwitch.toolTip = automation.enabled ? "Enabled" : "Disabled"
        let toggleColumn = NSStackView(views: [enabledSwitch, NSView()])
        toggleColumn.orientation = .horizontal
        toggleColumn.alignment = .centerY
        toggleColumn.spacing = 0

        let device = showDevice ? makeCellLabel(row.deviceName, font: Typography.rowDetail, color: Theme.muted) : nil
        let line = AutomationTableColumns.layOut(
            status: RowPrimitives.statusSlot(RowPrimitives.statusDot(Self.statusDotKind(for: row))), name: nameColumn, schedule: scheduleColumn,
            nextRun: nextRun, lastResult: lastResult, device: device, toggle: toggleColumn, action: makeRowActionButton(row, identifier: identifier))

        rowView.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: AutomationTableColumns.horizontalInset),
            line.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -AutomationTableColumns.horizontalInset),
            line.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            rowView.heightAnchor.constraint(equalToConstant: AutomationTableColumns.rowHeight),
        ])
        return rowView
    }

    /// The row's single contextual action: a running automation offers its live terminal, everything else
    /// offers the manual trigger. Both stay quiet text controls so the table reads as data, not buttons.
    private func makeRowActionButton(_ row: AutomationTableRow, identifier: NSUserInterfaceItemIdentifier) -> NSButton {
        guard let running = row.runningRun else {
            return makeTextActionButton(
                title: "Run now", tooltip: "Run this automation now", action: #selector(runNowTapped(_:)), identifier: identifier)
        }
        return makeTextActionButton(
            title: "Open terminal", tooltip: "Open this run's live terminal", action: #selector(openRunTerminalTapped(_:)),
            identifier: NSUserInterfaceItemIdentifier("\(row.deviceID)::\(running.id)"))
    }

    private func makeTextActionButton(title: String, tooltip: String, action: Selector, identifier: NSUserInterfaceItemIdentifier) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .inline
        button.isBordered = false
        button.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: Theme.muted, .font: Typography.metadataEmphasis])
        button.alignment = .right
        button.toolTip = tooltip
        button.identifier = identifier
        return button
    }

    /// The automation's kind as a small chip beside its name: accent-tinted for an agent automation,
    /// neutral for a script one.
    private func makeKindChip(_ automation: TerminalServiceAutomationSummary) -> NSView {
        let isAgent = AutomationKind(rawValue: automation.kind) == .agent
        let chip = ColoredBackgroundView()
        chip.fillColor = isAgent ? Theme.accentTint : Theme.chipBg
        chip.cornerRadius = 4
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.setContentHuggingPriority(.required, for: .horizontal)
        chip.setContentCompressionResistancePriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: AutomationsViewModel.kindLabel(for: automation))
        label.font = Typography.caption
        label.textColor = isAgent ? Theme.accentStrong : Theme.muted
        label.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: chip.topAnchor, constant: 1), label.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -1),
        ])
        return chip
    }

    private func makeCellLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    /// The row's right-click menu. The per-row Edit and Delete buttons the card layout carried are gone, so
    /// this menu is where they live; double-clicking the row repeats Edit.
    private func makeAutomationRowMenu(_ row: AutomationTableRow) -> NSMenu {
        let identifier = NSUserInterfaceItemIdentifier("\(row.deviceID)::\(row.automation.id)")
        let menu = NSMenu()
        func addItem(_ title: String, symbol: String, action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.identifier = identifier
            menu.addItem(item)
        }
        addItem("Run now", symbol: "play", action: #selector(runNowMenuItem(_:)))
        addItem("Edit…", symbol: "pencil", action: #selector(editMenuItem(_:)))
        menu.addItem(.separator())
        addItem("Delete…", symbol: "trash", action: #selector(deleteMenuItem(_:)))
        return menu
    }

    /// The same 55% dimming that marks an unreachable device's rows, reused for an automation that is
    /// switched off: the row stays listed and operable, but reads as inert.
    private static let disabledRowAlpha: CGFloat = 0.55

    private static func statusDotKind(for row: AutomationTableRow) -> RowPrimitives.StatusKind {
        switch AutomationsViewModel.rowStatus(for: row) {
        case .running: .running
        case .failed: .exited
        case .ready: .ready
        case .disabled: .idle
        }
    }

    /// The same role token with tabular (fixed-advance) figures, so the time columns' digits line up down
    /// the table. Derived from the token's own descriptor, so size and weight still come from `Typography`
    /// rather than a font literal at the call site.
    private static func tabularFigures(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.addingAttributes([
            .featureSettings: [
                [
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
                ]
            ]
        ])
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    // MARK: - Runs tab

    private func appendRunsTab(to stack: NSStackView, inputs: [AutomationDeviceInput]) {
        let rows = AutomationsViewModel.filterRuns(AutomationsViewModel.mergedRuns(from: inputs), deviceID: deviceFilterID)
        guard !rows.isEmpty else {
            appendEmptyState(to: stack, icon: "list.bullet.rectangle", title: "No runs yet", detail: "Runs appear here once an automation fires.")
            return
        }
        for row in rows {
            let card = makeRunCard(row)
            stack.addArrangedSubview(card)
            host.constrainFormFieldToFillWidth(card, in: stack)
        }
    }

    private func makeRunCard(_ row: AutomationRunTableRow) -> NSView {
        let run = row.run
        let status = AutomationRunStatus(rawValue: run.status)
        let statusIcon = statusImageView(forRunStatus: run.status)

        let name = NSTextField(labelWithString: run.automationName ?? "Automation")
        name.font = Typography.rowLabel
        name.textColor = host.sidebarPrimaryTextColor(isSelected: false)
        name.lineBreakMode = .byTruncatingTail

        var metaParts = [row.deviceName, runTriggerDescription(run), startedDescription(run), durationDescription(run)]
        if let exitCode = run.exitCode { metaParts.append("exit \(exitCode)") }
        if status == .skipped, let reason = run.skipReason { metaParts.append("skipped: \(reason)") }
        // Count only live coding agents (attributedAgents already excludes a script run's own workspace-less
        // wrapper session), so a running script automation with no agent shows no "live agent" meta.
        let liveAgentCount = run.attributedAgents.filter(\.live).count
        if liveAgentCount > 0 { metaParts.append("\(liveAgentCount) live agent\(liveAgentCount == 1 ? "" : "s")") }
        let meta = NSTextField(labelWithString: metaParts.filter { !$0.isEmpty }.joined(separator: "  •  "))
        meta.font = Typography.metadata
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingTail

        let textColumn = NSStackView(views: [name, meta])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 4

        // The status icon and name/meta labels form the clickable open-terminal region. The chips row and
        // the trailing buttons are interactive on their own, so they sit outside this gesture area (the
        // contentArea idiom used in ProcessesSection / AgentLaunchersSection) to stop an ancestor gesture
        // from also firing when those descendants are clicked. The trailing spacer keeps the clickable
        // region spanning the whole icon+text band, not just the label glyphs.
        let contentArea = NSStackView(views: [statusIcon, textColumn, NSView()])
        contentArea.orientation = .horizontal
        contentArea.alignment = .centerY
        contentArea.spacing = 8
        contentArea.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // A running run's live terminal, or an ended run's read-only transcript replay, opens on click; a
        // skipped/queued run that never had a session is inert.
        if run.terminalSessionID != nil, status != .skipped, status != .queued {
            attachRowClickAction(to: contentArea) { [weak self] in self?.host.openAutomationRunTerminal(deviceID: row.deviceID, run: run) }
        }

        var trailing: [NSView] = []
        if status == .running {
            let cancelButton = host.iconButton(symbol: "stop.fill", tooltip: "Cancel run", action: #selector(cancelRunTapped(_:)))
            cancelButton.target = self
            cancelButton.identifier = NSUserInterfaceItemIdentifier("\(row.deviceID)::\(run.id)")
            trailing.append(cancelButton)
        } else if AutomationsViewModel.endAgentsAvailable(for: run) {
            // A terminal-status run with a live attributed agent still lingering: offer to reap it. "End
            // agents" is a text label — ending someone's agent is not an obvious icon action.
            let endButton = host.actionButton(
                title: "End agents", symbol: nil, tooltip: "End this run's still-running coding agents", action: #selector(endAgentsTapped(_:)),
                primary: false)
            endButton.target = self
            endButton.identifier = NSUserInterfaceItemIdentifier("\(row.deviceID)::\(run.id)")
            trailing.append(endButton)
        }

        let topRow = NSStackView(views: [contentArea] + trailing)
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8

        let content: NSStackView
        // Attributed coding agents (an agent-kind run's own agent, plus any a script-kind run's command
        // spawned): one clickable chip each, its status dot reusing the app's shared agent-state language.
        // The chips stack below the top row so their own click actions stay clear of the row gesture.
        if !run.attributedAgents.isEmpty {
            let chips = run.attributedAgents.map { makeAgentChip(deviceID: row.deviceID, agent: $0) }
            let chipsRow = NSStackView(views: chips + [NSView()])
            chipsRow.orientation = .horizontal
            chipsRow.alignment = .centerY
            chipsRow.spacing = 6
            // Indent the chips to align under the name/meta text (status icon width + its spacing).
            chipsRow.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 0, right: 0)

            content = NSStackView(views: [topRow, chipsRow])
            content.orientation = .vertical
            content.alignment = .leading
            content.spacing = 6
            // Leading alignment gives arranged rows their intrinsic width, so pin the top row to the full
            // content width (minus the 10pt left/right edge insets applied below) to keep its trailing
            // buttons right-aligned.
            NSLayoutConstraint.activate([topRow.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -20)])
        } else {
            content = topRow
        }
        content.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        return cardContainer(content)
    }

    // MARK: - Shared row helpers

    /// A clickable chip for one attributed coding agent: its status dot (shared agent-state language) plus the
    /// agent's label. Clicking opens that agent's terminal session, device-qualified for a remote run.
    private func makeAgentChip(deviceID: String, agent: TerminalServiceAutomationAgentSummary) -> NSView {
        let status = AgentWindowStatus(rawValue: agent.status) ?? .idle
        let dot = AppKitController.agentStatusIndicator(status)
        dot.setContentHuggingPriority(.required, for: .horizontal)
        let title = agent.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Agent"
        let label = NSTextField(labelWithString: title)
        label.font = Typography.metadata
        label.textColor = host.sidebarPrimaryTextColor(isSelected: false)
        label.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [dot, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        row.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false

        let chip = ColoredBackgroundView()
        chip.cornerRadius = 6
        chip.fillColor = host.sidebarSelectedCardBackgroundColor()
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.toolTip = "Open agent terminal"
        chip.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: chip.leadingAnchor), row.trailingAnchor.constraint(equalTo: chip.trailingAnchor),
            row.topAnchor.constraint(equalTo: chip.topAnchor), row.bottomAnchor.constraint(equalTo: chip.bottomAnchor),
        ])
        attachRowClickAction(to: chip) { [weak self] in self?.host.openAutomationAgentSession(deviceID: deviceID, agent: agent) }
        return chip
    }

    private func cardContainer(_ content: NSView) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        let card = ColoredBackgroundView()
        card.cornerRadius = 10
        card.fillColor = host.sidebarCardBackgroundColor()
        card.translatesAutoresizingMaskIntoConstraints = false
        // ColoredBackgroundView tracks appearance for its fill; the border color still needs a per-appearance
        // cgColor snapshot, so bind it reactively.
        bindAppearanceReactiveLayer(card) { [unowned host] view in
            view.layer?.borderWidth = 1
            view.layer?.borderColor = host.sidebarCardBorderColor(isSelected: false).cgColor
        }
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor), content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.topAnchor.constraint(equalTo: card.topAnchor), content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
    }

    private func appendEmptyState(to stack: NSStackView, icon: String, title: String, detail: String) {
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
        iconView.contentTintColor = .tertiaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([iconView.widthAnchor.constraint(equalToConstant: 26), iconView.heightAnchor.constraint(equalToConstant: 26)])
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Typography.emptyStateTitle
        titleLabel.textColor = .labelColor
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = Typography.metadata
        detailLabel.textColor = .secondaryLabelColor
        let empty = NSStackView(views: [iconView, titleLabel, detailLabel])
        empty.orientation = .vertical
        empty.alignment = .centerX
        empty.spacing = 6
        empty.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(empty)
        host.constrainFormFieldToFillWidth(empty, in: stack)
    }

    private func statusImageView(forRunStatus rawStatus: String?) -> NSImageView {
        let icon = NSImageView()
        let (symbol, color) = Self.statusSymbol(forRunStatus: rawStatus, host: host)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: rawStatus ?? "no runs")
        icon.contentTintColor = color
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16)])
        return icon
    }

    /// The status glyph and tint for a run status raw value (nil = an automation that has never run). Icons
    /// carry status per the GUI rules; the tints match the sidebar running/failed/idle indicators.
    private static func statusSymbol(forRunStatus rawStatus: String?, host: AppKitController) -> (String, NSColor) {
        switch rawStatus.flatMap(AutomationRunStatus.init(rawValue:)) {
        case .running: ("play.circle.fill", host.sidebarRunningIndicatorColor())
        case .queued: ("clock", host.sidebarIdleIndicatorColor())
        case .succeeded: ("checkmark.circle.fill", host.sidebarRunningIndicatorColor())
        case .failed: ("xmark.octagon.fill", host.sidebarFailedIndicatorColor())
        case .timedOut: ("clock.badge.exclamationmark.fill", host.sidebarFailedIndicatorColor())
        case .canceled: ("stop.circle", host.sidebarIdleIndicatorColor())
        case .skipped: ("minus.circle", host.sidebarIdleIndicatorColor())
        case nil: ("circle.dashed", host.sidebarIdleIndicatorColor())
        }
    }

    // MARK: - Formatting

    private func runTriggerDescription(_ run: TerminalServiceAutomationRunSummary) -> String {
        switch AutomationRunTrigger(rawValue: run.trigger) {
        case .manual: "manual"
        case .cron: "cron"
        case .missedCatchUp: "missed catch-up"
        case nil: run.trigger
        }
    }

    private func startedDescription(_ run: TerminalServiceAutomationRunSummary) -> String {
        guard let iso = run.startedAt, let date = Self.iso8601Formatter.date(from: iso) else { return "" }
        return "started \(relativeFormatter.localizedString(for: date, relativeTo: Date()))"
    }

    private func durationDescription(_ run: TerminalServiceAutomationRunSummary) -> String {
        guard let startISO = run.startedAt, let start = Self.iso8601Formatter.date(from: startISO) else { return "" }
        let end = run.endedAt.flatMap { Self.iso8601Formatter.date(from: $0) } ?? Date()
        let interval = max(0, end.timeIntervalSince(start))
        return durationFormatter.string(from: interval).map { "took \($0)" } ?? ""
    }

    // MARK: - Actions

    @objc private func deviceFilterChanged(_ sender: NSPopUpButton) {
        deviceFilterID = sender.selectedItem?.representedObject as? String
        showAutomationsDetail()
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        selectedTab = Tab(rawValue: sender.selectedSegment) ?? .automations
        showAutomationsDetail()
    }

    @objc private func newAutomationTapped() { host.automationEditor.presentCreate(inputs: host.automationDeviceInputs()) }

    // The automations table reaches one automation from three places — the row's action button, its context
    // menu, and its double-click — so each action is a plain method and the `@objc` entry points only decode
    // the `deviceID::automationID` identifier their sender carries.

    @objc private func editMenuItem(_ sender: NSMenuItem) {
        guard let (deviceID, automationID) = Self.splitIdentifier(sender.identifier?.rawValue) else { return }
        presentEditor(deviceID: deviceID, automationID: automationID)
    }

    private func presentEditor(deviceID: String, automationID: String) {
        guard let automation = host.automationSummary(deviceID: deviceID, automationID: automationID) else { return }
        host.automationEditor.presentEdit(deviceID: deviceID, automation: automation)
    }

    @objc private func runNowTapped(_ sender: NSButton) {
        guard let (deviceID, automationID) = Self.splitIdentifier(sender.identifier?.rawValue) else { return }
        runNow(deviceID: deviceID, automationID: automationID)
    }

    @objc private func runNowMenuItem(_ sender: NSMenuItem) {
        guard let (deviceID, automationID) = Self.splitIdentifier(sender.identifier?.rawValue) else { return }
        runNow(deviceID: deviceID, automationID: automationID)
    }

    private func runNow(deviceID: String, automationID: String) {
        performMutation(deviceID: deviceID) { device, clientApp in
            try SpacesDeviceClient.triggerAutomation(id: automationID, device: device, clientApp: clientApp)
        }
    }

    /// Opens a running automation's live terminal. The run is re-resolved from the current device inputs
    /// rather than captured with the row, so a pane that re-rendered since still opens the daemon's run.
    @objc private func openRunTerminalTapped(_ sender: NSButton) {
        guard let (deviceID, runID) = Self.splitIdentifier(sender.identifier?.rawValue),
            let run = host.automationDeviceInputs().first(where: { $0.deviceID == deviceID })?.runs.first(where: { $0.id == runID })
        else { return }
        host.openAutomationRunTerminal(deviceID: deviceID, run: run)
    }

    @objc private func deleteMenuItem(_ sender: NSMenuItem) {
        guard let (deviceID, automationID) = Self.splitIdentifier(sender.identifier?.rawValue),
            let automation = host.automationSummary(deviceID: deviceID, automationID: automationID)
        else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete automation “\(automation.name)”?"
        alert.informativeText = "This cancels any running run and removes the automation and its run history."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performMutation(deviceID: deviceID) { device, clientApp in
            try SpacesDeviceClient.deleteAutomation(id: automationID, device: device, clientApp: clientApp)
        }
    }

    @objc private func enabledToggled(_ sender: NSSwitch) {
        guard let (deviceID, automationID) = Self.splitIdentifier(sender.identifier?.rawValue),
            let automation = host.automationSummary(deviceID: deviceID, automationID: automationID)
        else { return }
        let enabled = sender.state == .on
        let fields = AppKitController.automationFields(from: automation, enabled: enabled)
        performMutation(deviceID: deviceID) { device, clientApp in
            try SpacesDeviceClient.updateAutomation(id: automationID, fields: fields, device: device, clientApp: clientApp)
        }
    }

    @objc private func cancelRunTapped(_ sender: NSButton) {
        guard let (deviceID, runID) = Self.splitIdentifier(sender.identifier?.rawValue) else { return }
        performMutation(deviceID: deviceID) { device, clientApp in
            try SpacesDeviceClient.cancelAutomationRun(runID: runID, device: device, clientApp: clientApp)
        }
    }

    @objc private func endAgentsTapped(_ sender: NSButton) {
        guard let (deviceID, runID) = Self.splitIdentifier(sender.identifier?.rawValue) else { return }
        performMutation(deviceID: deviceID) { device, clientApp in
            try SpacesDeviceClient.endAutomationAgents(runID: runID, device: device, clientApp: clientApp)
        }
    }

    /// Runs a Device API automation mutation off the main actor, then reloads overviews so the pane
    /// re-renders with the daemon's authoritative state. Automation mutation responses do not carry an
    /// overview, so a reload (rather than an optimistic local merge) is the single refresh path.
    ///
    /// Failures reload too: mutation controls (e.g. the enable switch) flip their own AppKit state before
    /// the daemon confirms, so on rejection or an offline remote we must re-render from the daemon's truth
    /// to clear the stale flip rather than leave the UI asserting a change that never landed. For an
    /// offline remote this renders whatever cached overview exists, which is acceptable.
    private func performMutation(deviceID: String, _ operation: @escaping @Sendable (SpacesPairedDeviceRecord, SpacesDeviceClientApp) throws -> Void)
    {
        guard let device = host.automationDeviceRecord(deviceID: deviceID) else {
            host.showDeviceNotLoadedError()
            return
        }
        let forceRemoteRefresh = host.isRemoteAutomationDevice(deviceID: deviceID)
        Task { @MainActor [weak self] in
            let error = await Task.detached(priority: .userInitiated) { () -> Error? in
                do {
                    try operation(device, SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                    return nil
                } catch { return error }
            }.value
            guard let self else { return }
            if let error { host.showError(error) }
            host.requestSidebarReload(forceRemoteRefresh: forceRemoteRefresh)
        }
    }

    /// Splits a `"deviceID::rowID"` control identifier back into its parts.
    static func splitIdentifier(_ raw: String?) -> (String, String)? {
        guard let raw, let range = raw.range(of: "::") else { return nil }
        return (String(raw[raw.startIndex..<range.lowerBound]), String(raw[range.upperBound...]))
    }
}
