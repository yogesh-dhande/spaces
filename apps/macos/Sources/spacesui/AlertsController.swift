import AppKit
import Carbon
import CoreImage
import Foundation
import spacesclientcore
import spacesdeviceapi
import spacesdevicecore
import spacesterminalcore
import spacesterminalghostty
import spacesterminalui
import systembridge
import workspacecore

/// Owns the Alerts pane's state and behavior. `AppKitController` holds a single
/// instance and delegates alerts interactions to it. The controller reaches back
/// into the host for shared window/model/orchestration services via `host`.
@MainActor final class AlertsController: NSObject {
    unowned let host: AppKitController

    init(host: AppKitController) {
        self.host = host
        super.init()
    }

    typealias AlertsGroup = AppKitController.AlertsGroup
    typealias AlertsAttentionEntry = AppKitController.AlertsAttentionEntry
    typealias WindowFocusRequest = AppKitController.WindowFocusRequest

    var dismissedAlertsAttentionItemIDs: Set<String> = []
    var alertsShortcutSpec: HotkeySpec?
    /// Maps sequential window shortcut numbers (1-10, shown as 1-0) to focus targets for the current Alerts view.
    private var alertsFocusRequestMap: [Int: WindowFocusRequest] = [:]

    func alertsFocusRequest(for index: Int) -> WindowFocusRequest? { alertsFocusRequestMap[index] }

    // MARK: - Alerts content

    private func buildAlertsGroups() -> [AlertsGroup] {
        host.alertsGroups.compactMap { group -> AlertsGroup? in
            let items = group.items.filter { !dismissedAlertsAttentionItemIDs.contains($0.attentionID) }
            guard !items.isEmpty else { return nil }
            return AlertsGroup(
                projectName: group.projectName, workspaceID: group.workspaceID, workspaceName: group.workspaceName,
                workspaceBranch: group.workspaceBranch, items: items)
        }
    }

    func alertsAttentionCount() -> Int { buildAlertsGroups().reduce(0) { total, group in total + group.items.filter(\.countsTowardBadge).count } }

    func loadAlertsDismissedAttentionItemIDs() { dismissedAlertsAttentionItemIDs = host.loadDismissedAlertsAttentionItemIDs() }

    func pruneDismissedAlertsAttentionItemIDsIfNeeded() {
        let activeIDs = Set(host.alertsGroups.flatMap { $0.items.map(\.attentionID) })
        let prunedIDs = dismissedAlertsAttentionItemIDs.intersection(activeIDs)
        guard prunedIDs != dismissedAlertsAttentionItemIDs else { return }
        dismissedAlertsAttentionItemIDs = prunedIDs
        do { try host.storeDismissedAlertsAttentionItemIDs(prunedIDs) } catch { host.showError(error) }
    }

    func dismissAlertsAttentionItem(_ attentionID: String) {
        guard !dismissedAlertsAttentionItemIDs.contains(attentionID) else { return }
        dismissedAlertsAttentionItemIDs.insert(attentionID)
        do {
            try host.storeDismissedAlertsAttentionItemIDs(dismissedAlertsAttentionItemIDs)
            host.updateAlertsSidebarBadge()
            if host.showingAlerts { showAlertsDetail() }
        } catch {
            dismissedAlertsAttentionItemIDs.remove(attentionID)
            host.showError(error)
        }
    }

    func showAlertsDetail() {
        host.clearActiveAddFormStateAndCloseWindows()
        host.stopWorkspaceSetupDetailRefreshTimer()
        host.presentDetailPane(.alerts)
        host.showingSettings = false
        let previousProjectID = host.selectedProjectID
        let previousWorkspaceID = host.selectedWorkspaceID
        host.selectedProjectID = nil
        host.selectedWorkspaceID = nil
        alertsFocusRequestMap = [:]
        host.outlineView.deselectAll(nil)
        // Reload only the previously-selected workspace row to clear its selection styling;
        // avoid full reloadData() which would reset expand/collapse state.
        host.refreshSidebarSelectionRows(
            previousProjectID: previousProjectID, currentProjectID: nil, previousWorkspaceID: previousWorkspaceID, currentWorkspaceID: nil)
        host.updateAlertsRowAppearance()

        host.clearWorkspaceDetailFooter()
        for view in host.detailContainer.subviews { view.removeFromSuperview() }
        host.detailContainer.wantsLayer = true
        host.detailContainer.layer?.backgroundColor = host.sidebarPanelBackgroundColor().cgColor

        let groups = buildAlertsGroups()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Header
        let accentColor = host.sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
        let headerTitle = NSTextField(labelWithString: "Alerts")
        headerTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        headerTitle.textColor = host.sidebarPrimaryTextColor(isSelected: false, isArchived: false)

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.addArrangedSubview(headerTitle)

        stack.addArrangedSubview(headerRow)
        host.constrainFormFieldToFillWidth(headerRow, in: stack)

        if groups.isEmpty {
            let sep = NSView()
            sep.translatesAutoresizingMaskIntoConstraints = false
            sep.wantsLayer = true
            sep.layer?.backgroundColor = host.sidebarCardBorderColor(isSelected: false).cgColor
            sep.heightAnchor.constraint(equalToConstant: 1).isActive = true
            stack.addArrangedSubview(sep)
            host.constrainFormFieldToFillWidth(sep, in: stack)

            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "All clear")
            icon.contentTintColor = host.sidebarRunningIndicatorColor()
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28)])
            let emptyTitle = NSTextField(labelWithString: "No attention required")
            emptyTitle.font = .systemFont(ofSize: 13, weight: .medium)
            emptyTitle.textColor = .labelColor
            let emptyDetail = NSTextField(labelWithString: "All running workspaces are healthy.")
            emptyDetail.font = .systemFont(ofSize: 11)
            emptyDetail.textColor = .secondaryLabelColor
            let emptyStack = NSStackView()
            emptyStack.orientation = .vertical
            emptyStack.alignment = .centerX
            emptyStack.spacing = 6
            emptyStack.translatesAutoresizingMaskIntoConstraints = false
            emptyStack.addArrangedSubview(icon)
            emptyStack.addArrangedSubview(emptyTitle)
            emptyStack.addArrangedSubview(emptyDetail)
            stack.addArrangedSubview(emptyStack)
            host.constrainFormFieldToFillWidth(emptyStack, in: stack)
        } else {
            // Sequential window shortcut counter across all groups and items.
            var shortcutCounter = 1

            for group in groups {
                // Workspace group header
                let groupHeaderStack = NSStackView()
                groupHeaderStack.orientation = .horizontal
                groupHeaderStack.alignment = .centerY
                groupHeaderStack.spacing = 4
                groupHeaderStack.translatesAutoresizingMaskIntoConstraints = false

                let projectLabel = NSTextField(labelWithString: group.projectName)
                projectLabel.font = .systemFont(ofSize: 12, weight: .semibold)
                projectLabel.textColor = .secondaryLabelColor
                projectLabel.setContentHuggingPriority(.required, for: .horizontal)

                let slashLabel = NSTextField(labelWithString: "/")
                slashLabel.font = .systemFont(ofSize: 12)
                slashLabel.textColor = .tertiaryLabelColor
                slashLabel.setContentHuggingPriority(.required, for: .horizontal)

                let workspaceLabel = NSTextField(labelWithString: group.workspaceName)
                workspaceLabel.font = .systemFont(ofSize: 12, weight: .semibold)
                workspaceLabel.textColor = accentColor
                workspaceLabel.lineBreakMode = .byTruncatingTail
                workspaceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

                groupHeaderStack.addArrangedSubview(projectLabel)
                groupHeaderStack.addArrangedSubview(slashLabel)
                groupHeaderStack.addArrangedSubview(workspaceLabel)
                stack.addArrangedSubview(groupHeaderStack)
                host.constrainFormFieldToFillWidth(groupHeaderStack, in: stack)

                let itemsStack = NSStackView()
                itemsStack.orientation = .vertical
                itemsStack.spacing = 4
                itemsStack.translatesAutoresizingMaskIntoConstraints = false

                for entry in group.items {
                    let shortcut = shortcutCounter <= 10 ? host.windowShortcutBadgeText(index: shortcutCounter) : ""
                    if shortcutCounter <= 10, let focusRequest = entry.focusRequest { alertsFocusRequestMap[shortcutCounter] = focusRequest }
                    shortcutCounter += 1
                    let cardAction: (() async -> Void)?
                    if let focusRequest = entry.focusRequest {
                        cardAction = { [weak self] in
                            guard let self else { return }
                            await self.host.performWindowFocus(focusRequest)
                        }
                    } else {
                        cardAction = nil
                    }
                    let card = alertsWindowCard(entry: entry, shortcut: shortcut, action: cardAction)
                    itemsStack.addArrangedSubview(card)
                    host.constrainFormFieldToFillWidth(card, in: itemsStack)
                }

                stack.addArrangedSubview(itemsStack)
                host.constrainFormFieldToFillWidth(itemsStack, in: stack)
            }
        }

        host.showScrollableDetailStack(stack)
    }

    /// Builds an alerts card with focus and dismiss affordances while preserving the workspace Run tab rows.
    private func alertsWindowCard(entry: AlertsAttentionEntry, shortcut: String, action: (() async -> Void)? = nil) -> NSView {
        let dismissButton = NSButton()
        dismissButton.title = ""
        dismissButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        dismissButton.imagePosition = .imageOnly
        dismissButton.setButtonType(.momentaryPushIn)
        dismissButton.isBordered = false
        dismissButton.contentTintColor = .secondaryLabelColor
        dismissButton.bezelStyle = .regularSquare
        dismissButton.target = self
        dismissButton.action = #selector(dismissAlertsAttentionItemAction(_:))
        dismissButton.identifier = NSUserInterfaceItemIdentifier(entry.attentionID)
        dismissButton.toolTip = "Dismiss from alerts"

        let mainRow = host.windowRow(
            icon: entry.icon, iconColor: AppKitController.alertsIconColor(entry.iconTint), label: entry.label, detail: entry.detail,
            shortcut: shortcut, processStatus: entry.processStatus, agentStatus: entry.agentStatus,
            automationID: entry.agentStatus == nil ? nil : "alerts-agent-\(AppKitController.automationIdentifierSlug(entry.label))",
            trailingAccessory: dismissButton, action: action)

        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 4
        container.translatesAutoresizingMaskIntoConstraints = false

        container.addArrangedSubview(mainRow)
        host.constrainFormFieldToFillWidth(mainRow, in: container)

        return container
    }

    @objc private func dismissAlertsAttentionItemAction(_ sender: NSButton) {
        guard let attentionID = sender.identifier?.rawValue, !attentionID.isEmpty else { return }
        dismissAlertsAttentionItem(attentionID)
    }

    func handleAlertsShortcut(event: NSEvent) -> Bool {
        guard let alertsShortcutSpec, host.matches(event: event, spec: alertsShortcutSpec) else { return false }
        showAlertsDetail()
        return true
    }
}
