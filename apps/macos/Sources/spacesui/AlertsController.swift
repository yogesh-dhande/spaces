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
    /// The focused session and when it took focus, refreshed on every alerts rebuild (the rebuild funnel
    /// is where this client reads keyboard focus). Bounds which of that session's bells count as rung in
    /// front of the user — see `consumeFocusedSessionBellAlerts`.
    private var focusedBellWatch: FocusedBellWatch?
    var alertsShortcutSpec: HotkeySpec?
    /// Maps sequential window shortcut numbers (1-10, shown as 1-0) to focus targets for the current Alerts view.
    private var alertsFocusRequestMap: [Int: WindowFocusRequest] = [:]

    func alertsFocusRequest(for index: Int) -> WindowFocusRequest? { alertsFocusRequestMap[index] }

    // MARK: - Alerts content

    private func buildAlertsGroups() -> [AlertsGroup] {
        Self.visibleAlertsGroups(in: host.alertsGroups, dismissedAttentionItemIDs: dismissedAlertsAttentionItemIDs)
    }

    /// The groups the user sees: everything derived from the overviews minus what has been dismissed —
    /// by a click, or by the user having watched the session a bell rang in.
    nonisolated static func visibleAlertsGroups(in groups: [AlertsGroup], dismissedAttentionItemIDs: Set<String>) -> [AlertsGroup] {
        groups.compactMap { group -> AlertsGroup? in
            let items = group.items.filter { !dismissedAttentionItemIDs.contains($0.attentionID) }
            guard !items.isEmpty else { return nil }
            return AlertsGroup(
                projectName: group.projectName, workspaceID: group.workspaceID, workspaceName: group.workspaceName,
                workspaceBranch: group.workspaceBranch, items: items)
        }
    }

    func alertsAttentionCount() -> Int { buildAlertsGroups().reduce(0) { total, group in total + group.items.filter(\.countsTowardBadge).count } }

    func loadAlertsDismissedAttentionItemIDs() { dismissedAlertsAttentionItemIDs = host.loadDismissedAlertsAttentionItemIDs() }

    func pruneDismissedAlertsAttentionItemIDsIfNeeded() {
        let prunedIDs = Self.retainedDismissedAttentionItemIDs(dismissedAlertsAttentionItemIDs, in: host.alertsGroups)
        guard prunedIDs != dismissedAlertsAttentionItemIDs else { return }
        dismissedAlertsAttentionItemIDs = prunedIDs
        do { try host.storeDismissedAlertsAttentionItemIDs(prunedIDs) } catch { host.showError(error) }
    }

    /// Dismissals worth keeping: a dismissal is only meaningful while its alert is still derived, so the
    /// set is trimmed to the identities the current groups carry. A bell consumed because its session was
    /// focused survives this the same way a clicked-away one does — the entry stays derived for as long as
    /// the session reports that `bellAt`.
    nonisolated static func retainedDismissedAttentionItemIDs(_ dismissed: Set<String>, in groups: [AlertsGroup]) -> Set<String> {
        dismissed.intersection(Set(groups.flatMap { $0.items.map(\.attentionID) }))
    }

    /// Marks the bell of the session the user is typing in as already seen, every time the alerts are
    /// rebuilt from a fresh overview.
    ///
    /// The daemon records a bell for every session because it cannot see which one has keyboard focus on
    /// a given client, so this client owns the decision — and it has to consume the alert rather than
    /// omit it from the derivation: `bellAt` stays on the session, so a bell merely filtered out would
    /// come back the moment focus moved to another pane or the app relaunched. Consumption writes the
    /// bell's identity into the same persisted dismissal set a click writes to, which is also what keeps
    /// it alive: `pruneDismissedAlertsAttentionItemIDsIfNeeded` drops dismissals whose alert is no longer
    /// derived, and the entry stays derived for as long as `bellAt` holds that value. A later bell in the
    /// same session carries a new `bellAt`, hence a new identity, and alerts normally.
    ///
    /// Consuming it is the whole response: the focused session's bell produces no alert, and no sound or
    /// flash either, because the terminal views render no bell feedback (see the `.ringBell` case in
    /// `GhosttyMirrorTerminalView`). That is the decided behavior — a bell you are watching happen needs
    /// no notification — not a missing piece to fill in.
    ///
    /// Only bells rung *since* focus arrived are consumed. Focusing a session is not a way to clear its
    /// alerts — nothing else in the alerts model clears on focus — so a bell the session rang while the
    /// user was elsewhere stays an alert for them to dismiss, exactly as iOS's watch windows leave it.
    func consumeFocusedSessionBellAlerts() {
        focusedBellWatch = Self.updatedFocusedBellWatch(focusedBellWatch, focusedSessionID: host.panelCoordinator.focusedSessionID(), now: Date())
        guard let focusedBellWatch else { return }
        let consumed = Self.bellAttentionIDs(in: host.alertsGroups, watch: focusedBellWatch).subtracting(dismissedAlertsAttentionItemIDs)
        guard !consumed.isEmpty else { return }
        dismissedAlertsAttentionItemIDs.formUnion(consumed)
        do { try host.storeDismissedAlertsAttentionItemIDs(dismissedAlertsAttentionItemIDs) } catch { host.showError(error) }
    }

    /// The session that currently holds keyboard focus, and when this client first saw it take focus.
    struct FocusedBellWatch: Equatable {
        let sessionID: String
        let since: Date
    }

    /// Restarts the focus clock whenever the focused session changes, so every arrival at a session gets
    /// its own "bells from here on are yours" boundary; focus leaving every pane clears it.
    ///
    /// The boundary is observed at rebuild time, not at the pane-focus event, so it can trail actual
    /// focus by up to one refresh: a bell landing in that sliver alerts instead of being consumed.
    /// Accepted — the error direction is an extra visible alert, never a silently eaten one, and a
    /// pane-focus hook into this controller is plumbing a benign sliver does not justify.
    nonisolated static func updatedFocusedBellWatch(_ current: FocusedBellWatch?, focusedSessionID: String?, now: Date) -> FocusedBellWatch? {
        guard let focusedSessionID else { return nil }
        guard current?.sessionID == focusedSessionID else { return FocusedBellWatch(sessionID: focusedSessionID, since: now) }
        return current
    }

    /// Slack allowed around the focus boundary. `bellAt` is stamped by the daemon's clock (possibly a
    /// remote Linux one) while the focus time comes from this Mac's, so a bell rung just after focus
    /// arrived can carry a slightly earlier timestamp; without the tolerance it would alert for a session
    /// the user is already looking at. It matches iOS's `watchedBellSkewTolerance` for the same reason.
    nonisolated static let focusedBellSkewTolerance: TimeInterval = 2

    /// Identities of the focused session's bell alerts that rang at or after focus arrived. A bell is the
    /// only alert that focuses a terminal session directly — every other row focuses a process, an agent,
    /// or a window — so the focus request identifies it without matching on presentation text. An entry
    /// whose timestamp did not parse carries no date to compare and is left alerting.
    nonisolated static func bellAttentionIDs(in groups: [AlertsGroup], watch: FocusedBellWatch) -> Set<String> {
        let boundary = watch.since.addingTimeInterval(-focusedBellSkewTolerance)
        return Set(
            groups.lazy.flatMap(\.items).filter { item in
                guard case .terminalSession(_, let itemSessionID) = item.focusRequest, itemSessionID == watch.sessionID else { return false }
                guard let eventDate = item.eventDate else { return false }
                return eventDate >= boundary
            }.map(\.attentionID))
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

    /// Renders the Alerts pane. Also the pane's re-render: every refresh that lands new device state
    /// calls this again while alerts is already the visible pane, so nothing here may discard state the
    /// user is in the middle of. `presentation` is what tells the two apart — it defaults to the
    /// refresh, and only the entry points the user actually reached for pass `.userNavigation`.
    func showAlertsDetail(presentation: DetailPanePresentation = .backgroundRefresh) {
        host.stopWorkspaceSetupDetailRefreshTimer()
        host.presentDetailPane(.alerts, presentation: presentation)
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
        bindAppearanceReactiveLayer(host.detailContainer) { [unowned host] view in
            view.layer?.backgroundColor = host.sidebarPanelBackgroundColor().cgColor
        }

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
        headerTitle.textColor = host.sidebarPrimaryTextColor(isSelected: false)

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
            bindAppearanceReactiveLayer(sep) { [unowned host] view in
                view.layer?.backgroundColor = host.sidebarCardBorderColor(isSelected: false).cgColor
            }
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
                // An unreachable device keeps its alerts listed and attributed to the workspace that
                // raised them, marked stale by the same dimming its sidebar rows carry: they report what
                // the device last said, and nothing can be done about them until it answers again.
                let offlineDeviceName = unreachableDeviceName(workspaceID: group.workspaceID)

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
                if let offlineDeviceName {
                    groupHeaderStack.alphaValue = AppKitController.unreachableDeviceAlpha
                    groupHeaderStack.toolTip = "\(offlineDeviceName) is offline"
                }
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
                    } else if let automationRunTarget = entry.automationRunTarget {
                        cardAction = { [weak self] in
                            self?.host.automations.showRunsForAlert(deviceID: automationRunTarget.deviceID, runID: automationRunTarget.runID)
                        }
                    } else {
                        cardAction = nil
                    }
                    let card = alertsWindowCard(entry: entry, shortcut: shortcut, action: cardAction)
                    if let offlineDeviceName {
                        card.alphaValue = AppKitController.unreachableDeviceAlpha
                        card.toolTip = "\(offlineDeviceName) is offline"
                    }
                    itemsStack.addArrangedSubview(card)
                    host.constrainFormFieldToFillWidth(card, in: itemsStack)
                }

                stack.addArrangedSubview(itemsStack)
                host.constrainFormFieldToFillWidth(itemsStack, in: stack)
            }
        }

        host.showScrollableDetailStack(stack)
    }

    /// The display name of the device that raised this workspace's alerts when that device is
    /// unreachable, and nil while it is loaded — the alerts pane's only piece of device context, shown
    /// because a stale alert is otherwise indistinguishable from a live one.
    private func unreachableDeviceName(workspaceID: String) -> String? {
        guard let deviceID = host.deviceID(forWorkspaceID: workspaceID), let section = host.deviceSection(id: deviceID), section.loadState.isOffline
        else { return nil }
        return section.displayName
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
        showAlertsDetail(presentation: .userNavigation)
        return true
    }
}
