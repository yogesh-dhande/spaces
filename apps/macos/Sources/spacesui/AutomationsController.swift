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
    }

    // MARK: - Header & tabs

    private func makeHeaderRow(inputs: [AutomationDeviceInput]) -> NSView {
        let title = NSTextField(labelWithString: "Automations")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = host.sidebarPrimaryTextColor(isSelected: false, isArchived: false)
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
        let segmented = NSSegmentedControl(labels: ["Automations", "Runs"], trackingMode: .selectOne, target: self, action: #selector(tabChanged(_:)))
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
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        row.wantsLayer = true
        row.layer?.cornerRadius = 8
        bindAppearanceReactiveLayer(row) { [unowned host] view in view.layer?.backgroundColor = host.sidebarCardBackgroundColor(isArchived: false).cgColor }
        return row
    }

    // MARK: - Automations tab

    private func appendAutomationsTab(to stack: NSStackView, inputs: [AutomationDeviceInput]) {
        let rows = AutomationsViewModel.filterAutomations(AutomationsViewModel.mergedAutomations(from: inputs), deviceID: deviceFilterID)
        guard !rows.isEmpty else {
            appendEmptyState(to: stack, icon: "clock.arrow.circlepath", title: "No automations", detail: "Create one to run a command on a schedule.")
            return
        }
        for row in rows {
            let card = makeAutomationCard(row)
            stack.addArrangedSubview(card)
            host.constrainFormFieldToFillWidth(card, in: stack)
        }
    }

    private func makeAutomationCard(_ row: AutomationTableRow) -> NSView {
        let automation = row.automation
        let statusIcon = statusImageView(forRunStatus: row.lastRunStatus)

        let name = NSTextField(labelWithString: automation.name)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = host.sidebarPrimaryTextColor(isSelected: false, isArchived: false)
        name.lineBreakMode = .byTruncatingTail

        let metaText = [row.deviceName, triggerDescription(automation), nextFireDescription(automation), policiesDescription(automation)]
            .filter { !$0.isEmpty }.joined(separator: "  •  ")
        let meta = NSTextField(labelWithString: metaText)
        meta.font = .systemFont(ofSize: 11)
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingTail

        var columnViews: [NSView] = [name]
        // A kind-appropriate one-line excerpt (an agent automation's prompt, a script automation's script) as
        // plain text — the type itself is not marked here; the user identifies it from the automation name.
        let excerpt = AutomationsViewModel.excerpt(for: automation)
        if !excerpt.isEmpty {
            let excerptLabel = NSTextField(labelWithString: excerpt)
            excerptLabel.font = .systemFont(ofSize: 11)
            excerptLabel.textColor = .secondaryLabelColor
            excerptLabel.lineBreakMode = .byTruncatingTail
            columnViews.append(excerptLabel)
        }
        columnViews.append(meta)

        let textColumn = NSStackView(views: columnViews)
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 2

        let enabledSwitch = NSSwitch()
        enabledSwitch.state = automation.enabled ? .on : .off
        enabledSwitch.target = self
        enabledSwitch.action = #selector(enabledToggled(_:))
        enabledSwitch.identifier = NSUserInterfaceItemIdentifier("\(row.deviceID)::\(automation.id)")
        enabledSwitch.toolTip = automation.enabled ? "Enabled" : "Disabled"

        let runButton = host.iconButton(symbol: "play.fill", tooltip: "Run now", action: #selector(runNowTapped(_:)))
        runButton.target = self
        runButton.identifier = NSUserInterfaceItemIdentifier("\(row.deviceID)::\(automation.id)")
        let editButton = host.iconButton(symbol: "pencil", tooltip: "Edit", action: #selector(editTapped(_:)))
        editButton.target = self
        editButton.identifier = NSUserInterfaceItemIdentifier("\(row.deviceID)::\(automation.id)")
        let deleteButton = host.iconButton(symbol: "trash", tooltip: "Delete", action: #selector(deleteTapped(_:)))
        deleteButton.target = self
        deleteButton.identifier = NSUserInterfaceItemIdentifier("\(row.deviceID)::\(automation.id)")

        let content = NSStackView(views: [statusIcon, textColumn, NSView(), enabledSwitch, runButton, editButton, deleteButton])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        return cardContainer(content)
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
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.textColor = host.sidebarPrimaryTextColor(isSelected: false, isArchived: false)
        name.lineBreakMode = .byTruncatingTail

        var metaParts = [row.deviceName, runTriggerDescription(run), startedDescription(run), durationDescription(run)]
        if let exitCode = run.exitCode { metaParts.append("exit \(exitCode)") }
        if status == .skipped, let reason = run.skipReason { metaParts.append("skipped: \(reason)") }
        // Count only live coding agents (attributedAgents already excludes a script run's own workspace-less
        // wrapper session), so a running script automation with no agent shows no "live agent" meta.
        let liveAgentCount = run.attributedAgents.filter(\.live).count
        if liveAgentCount > 0 {
            metaParts.append("\(liveAgentCount) live agent\(liveAgentCount == 1 ? "" : "s")")
        }
        let meta = NSTextField(labelWithString: metaParts.filter { !$0.isEmpty }.joined(separator: "  •  "))
        meta.font = .systemFont(ofSize: 11)
        meta.textColor = .secondaryLabelColor
        meta.lineBreakMode = .byTruncatingTail

        var columnViews: [NSView] = [name, meta]
        // Attributed coding agents (an agent-kind run's own agent, plus any a script-kind run's command
        // spawned): one clickable chip each, its status dot reusing the app's shared agent-state language.
        if !run.attributedAgents.isEmpty {
            let chips = run.attributedAgents.map { makeAgentChip(deviceID: row.deviceID, agent: $0) }
            let chipsRow = NSStackView(views: chips + [NSView()])
            chipsRow.orientation = .horizontal
            chipsRow.alignment = .centerY
            chipsRow.spacing = 6
            columnViews.append(chipsRow)
        }

        let textColumn = NSStackView(views: columnViews)
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 4

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

        let content = NSStackView(views: [statusIcon, textColumn, NSView()] + trailing)
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)

        let card = cardContainer(content)
        // A running run's live terminal, or an ended run's read-only transcript replay, opens on click; a
        // skipped/queued run that never had a session is inert.
        if run.terminalSessionID != nil, status != .skipped, status != .queued {
            attachRowClickAction(to: card) { [weak self] in
                self?.host.openAutomationRunTerminal(deviceID: row.deviceID, run: run)
            }
        }
        return card
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
        label.font = .systemFont(ofSize: 11)
        label.textColor = host.sidebarPrimaryTextColor(isSelected: false, isArchived: false)
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
        attachRowClickAction(to: chip) { [weak self] in
            self?.host.openAutomationAgentSession(deviceID: deviceID, agent: agent)
        }
        return chip
    }

    private func cardContainer(_ content: NSView) -> NSView {
        content.translatesAutoresizingMaskIntoConstraints = false
        let card = ColoredBackgroundView()
        card.cornerRadius = 10
        card.fillColor = host.sidebarCardBackgroundColor(isArchived: false)
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
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
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

    private func triggerDescription(_ automation: TerminalServiceAutomationSummary) -> String {
        switch AutomationTriggerKind(rawValue: automation.triggerKind) {
        case .cron: automation.cronExpression.map { "cron: \($0)" } ?? "cron"
        default: "manual"
        }
    }

    private func nextFireDescription(_ automation: TerminalServiceAutomationSummary) -> String {
        guard automation.enabled, let iso = automation.nextFireTime, let date = Self.iso8601Formatter.date(from: iso) else { return "" }
        return "next \(relativeFormatter.localizedString(for: date, relativeTo: Date()))"
    }

    private func policiesDescription(_ automation: TerminalServiceAutomationSummary) -> String {
        var parts = ["on overlap: \(automation.concurrencyPolicy)"]
        if let timeout = automation.timeoutSeconds { parts.append("timeout \(timeout)s") }
        return parts.joined(separator: ", ")
    }

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

    @objc private func editTapped(_ sender: NSButton) {
        guard let (deviceID, automationID) = Self.splitIdentifier(sender.identifier?.rawValue),
            let automation = host.automationSummary(deviceID: deviceID, automationID: automationID)
        else { return }
        host.automationEditor.presentEdit(deviceID: deviceID, automation: automation)
    }

    @objc private func runNowTapped(_ sender: NSButton) {
        guard let (deviceID, automationID) = Self.splitIdentifier(sender.identifier?.rawValue) else { return }
        performMutation(deviceID: deviceID) { device, clientApp in
            try SpacesDeviceClient.triggerAutomation(id: automationID, device: device, clientApp: clientApp)
        }
    }

    @objc private func deleteTapped(_ sender: NSButton) {
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
    private func performMutation(deviceID: String, _ operation: @escaping @Sendable (SpacesPairedDeviceRecord, SpacesDeviceClientApp) throws -> Void) {
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
            if let error {
                host.showError(error)
                return
            }
            host.requestSidebarReload(forceRemoteRefresh: forceRemoteRefresh)
        }
    }

    /// Splits a `"deviceID::rowID"` control identifier back into its parts.
    static func splitIdentifier(_ raw: String?) -> (String, String)? {
        guard let raw, let range = raw.range(of: "::") else { return nil }
        return (String(raw[raw.startIndex..<range.lowerBound]), String(raw[range.upperBound...]))
    }
}
