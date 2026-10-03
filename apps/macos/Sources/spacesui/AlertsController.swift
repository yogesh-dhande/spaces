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
///
/// What alerts exist and which are dismissed is each device's call: the entries are derived from the
/// device overviews (`SpacesDeviceOverviewPayload.alertCandidates`) and every dismissal is a request to the
/// device that raised the alert. Nothing here hides an alert locally; the list changes when the device's
/// answer arrives.
@MainActor final class AlertsController: NSObject {
    unowned let host: AppKitController

    init(host: AppKitController) {
        self.host = host
        super.init()
    }

    typealias WindowFocusRequest = AppKitController.WindowFocusRequest

    struct AlertsAttentionEntry: Sendable {
        let attentionID: String
        let kind: SpacesDeviceAlertKind
        /// The device that raised the alert and the device-free candidate key it dismisses by.
        let deviceID: String
        let alertKey: String
        /// Whether the device has recorded a dismissal for this alert. A dismissed entry stays derived so
        /// the row it belongs to can still read it (an exited process whose alert was dismissed shows as
        /// not started); `visibleAlertsGroups` is what drops it from every list and count.
        let isDismissed: Bool
        let icon: String
        let iconTint: AppKitController.AlertsIconTint
        let label: String
        let detail: String?
        let shortcut: String
        let processStatus: RunningProcessState?
        let agentStatus: AgentWindowStatus?
        let countsTowardBadge: Bool
        let eventDate: Date?
        let focusRequest: WindowFocusRequest?
        /// Set for a failed/timed-out automation-run alert. Its card deep-links to the Runs tab rather than
        /// focusing the workspace runtime target, which may already be detached, so `focusRequest` stays nil.
        let automationRunTarget: AutomationRunAlertTarget?

        init(
            attentionID: String, kind: SpacesDeviceAlertKind, deviceID: String = "", alertKey: String = "", isDismissed: Bool = false, icon: String,
            iconTint: AppKitController.AlertsIconTint, label: String, detail: String?, shortcut: String, processStatus: RunningProcessState? = nil,
            agentStatus: AgentWindowStatus? = nil, countsTowardBadge: Bool, eventDate: Date?, focusRequest: WindowFocusRequest? = nil,
            automationRunTarget: AutomationRunAlertTarget? = nil
        ) {
            self.attentionID = attentionID
            self.kind = kind
            self.deviceID = deviceID
            self.alertKey = alertKey
            self.isDismissed = isDismissed
            self.icon = icon
            self.iconTint = iconTint
            self.label = label
            self.detail = detail
            self.shortcut = shortcut
            self.processStatus = processStatus
            self.agentStatus = agentStatus
            self.countsTowardBadge = countsTowardBadge
            self.eventDate = eventDate
            self.focusRequest = focusRequest
            self.automationRunTarget = automationRunTarget
        }
    }

    /// Names the automation run an alert card deep-links to.
    struct AutomationRunAlertTarget: Sendable, Equatable {
        let deviceID: String
        let runID: String
    }

    struct AlertsGroup: Sendable {
        let projectName: String
        let workspaceID: String
        let workspaceName: String
        let workspaceBranch: String?
        /// Whether the workspace this group was derived from is hidden, or belongs to a hidden project.
        ///
        /// Hidden workspaces still get their groups built, because a dismissal or Come Back Later mark
        /// made before the workspace was hidden must still be recognized when it is shown again. The
        /// display surfaces (the alerts pane, its badge, the command palette) filter on this flag instead.
        let isFromHiddenWorkspace: Bool
        let items: [AlertsAttentionEntry]
        /// The device this group's alerts were derived from, carried directly rather than resolved by
        /// parsing `workspaceID` at render time: the automation group's synthetic workspace id
        /// ("automations:<deviceID>") never walks back to a real workspace, so a lookup through it could
        /// never find the owning device, and its rows never dimmed when that device went offline.
        /// Defaults to "" for call sites (mostly tests) that build a group directly rather than through
        /// `buildOverviewAlertsGroups`.
        let deviceID: String
        var latestDate: Date? { items.compactMap(\.eventDate).max() }

        init(
            projectName: String, workspaceID: String, workspaceName: String, workspaceBranch: String?, isFromHiddenWorkspace: Bool,
            items: [AlertsAttentionEntry], deviceID: String = ""
        ) {
            self.projectName = projectName
            self.workspaceID = workspaceID
            self.workspaceName = workspaceName
            self.workspaceBranch = workspaceBranch
            self.isFromHiddenWorkspace = isFromHiddenWorkspace
            self.items = items
            self.deviceID = deviceID
        }
    }

    /// The Mac's identity for an alert: the device-free candidate key qualified by the device that raised
    /// it, so the same key on two devices stays two alerts in one merged list.
    nonisolated static func attentionID(deviceID: String, key: String) -> String { "alert:\(deviceID):\(key)" }

    /// The device id embedded in every attention id built by `attentionID(deviceID:key:)`, or nil for an
    /// id that does not carry one.
    nonisolated static func deviceID(fromAttentionID attentionID: String) -> String? {
        let components = attentionID.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard components.count >= 2, components[0] == "alert" else { return nil }
        return String(components[1])
    }

    /// Builds attention alerts for a device from its overview payload, used for both the local and
    /// remote devices so alerts aggregate identically across the sidebar without the client ever
    /// opening `spaces.db`. What alerts exist is `alertCandidates()`'s answer, shared with the daemon and
    /// iOS; this maps each candidate to the Mac's presentation. Window-role styling (browser/editor icons,
    /// per-window focus) is intentionally absent: desktop windows are client-local and not part of the
    /// daemon overview, so an exited process shows as a process alert and clicking it focuses the process.
    nonisolated static func buildOverviewAlertsGroups(from overview: SpacesDeviceOverviewPayload, deviceID: String, deviceName: String = "")
        -> [AlertsGroup]
    {
        // First-wins matches the `first(where:)` scan this replaces.
        let sessionsByID = Dictionary(overview.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let workspacesByID = Dictionary(overview.workspaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let dismissedKeys = Set(overview.dismissedAlertKeys)
        var itemsByWorkspace: [String: [AlertsAttentionEntry]] = [:]
        var automationItems: [AlertsAttentionEntry] = []
        for candidate in overview.alertCandidates() {
            let isDismissed = dismissedKeys.contains(candidate.key)
            let attentionID = attentionID(deviceID: deviceID, key: candidate.key)
            func entry(
                icon: String, iconTint: AppKitController.AlertsIconTint, label: String, detail: String?, processStatus: RunningProcessState? = nil,
                agentStatus: AgentWindowStatus? = nil, focusRequest: WindowFocusRequest? = nil, automationRunTarget: AutomationRunAlertTarget? = nil
            ) -> AlertsAttentionEntry {
                AlertsAttentionEntry(
                    attentionID: attentionID, kind: candidate.kind, deviceID: deviceID, alertKey: candidate.key, isDismissed: isDismissed, icon: icon,
                    iconTint: iconTint, label: label, detail: detail, shortcut: "", processStatus: processStatus, agentStatus: agentStatus,
                    countsTowardBadge: true, eventDate: candidate.date, focusRequest: focusRequest, automationRunTarget: automationRunTarget)
            }
            switch candidate.kind {
            case .automationRunFailed, .automationRunTimedOut:
                // Failed/timed-out runs form their own synthetic group whose cards deep-link to the Runs tab
                // instead of focusing a live workspace target that may be detached.
                guard let run = overview.automationRuns.first(where: { $0.id == candidate.subjectID }),
                    let automation = AutomationsViewModel.alertEntries(deviceID: deviceID, deviceName: deviceName, runs: [run]).first
                else { continue }
                // The automation's name is the row's name segment and the run's outcome is its title
                // segment, matching every other alert row's name/title split (`alertsCombinedSegments`).
                automationItems.append(
                    entry(
                        icon: automation.status == "timed_out" ? "clock.badge.exclamationmark.fill" : "xmark.octagon.fill", iconTint: .warning,
                        label: automation.automationName, detail: automation.outcome,
                        automationRunTarget: AutomationRunAlertTarget(deviceID: automation.deviceID, runID: automation.runID)))
            case .agentWaiting, .agentDone:
                guard let workspaceID = candidate.workspaceID, let agent = workspacesByID[workspaceID]?.codingAgentRows.first(where: { $0.id == candidate.subjectID })
                else { continue }
                // Both states keep the cpu.fill agent identity; the tint alone carries the state:
                // `waiting` (blocked on the user) is amber and `done` is blue, the same colors the row wears
                // in the sidebar, so a finished agent doesn't read as still needing attention.
                itemsByWorkspace[workspaceID, default: []].append(
                    entry(
                        icon: "cpu.fill", iconTint: candidate.kind == .agentDone ? .done : .warning, label: agent.name,
                        detail: AppKitController.terminalPaletteSecondaryLabel(
                            liveTitle: agent.liveTitle, sessionID: agent.sessionID, sessionsByID: sessionsByID),
                        agentStatus: AgentWindowStatus(rawValue: agent.activityState.rawValue),
                        focusRequest: agentFocusRequest(agent, workspaceID: workspaceID)))
            case .processExited:
                guard let workspaceID = candidate.workspaceID, let process = workspacesByID[workspaceID]?.processRows.first(where: { $0.id == candidate.subjectID })
                else { continue }
                itemsByWorkspace[workspaceID, default: []].append(
                    entry(
                        icon: "terminal", iconTint: .terminal, label: process.name, detail: process.command, processStatus: .exited,
                        focusRequest: process.processID.map { .workspaceProcess(workspaceID: workspaceID, processID: $0) }))
            case .terminalExited, .terminalFailed:
                guard let workspaceID = candidate.workspaceID, let sessionID = candidate.sessionID else { continue }
                let terminalRow = workspacesByID[workspaceID]?.terminalRows.first(where: { $0.id == candidate.subjectID })
                let session = sessionsByID[sessionID]
                // A terminal that failed reads as a warning; one that simply exited reads like an exited process.
                itemsByWorkspace[workspaceID, default: []].append(
                    entry(
                        icon: "terminal", iconTint: candidate.kind == .terminalFailed ? .warning : .terminal,
                        label: terminalRow?.title ?? session?.title ?? sessionID,
                        detail: AppKitController.terminalPaletteSecondaryLabel(
                            liveTitle: terminalRow?.liveTitle ?? session?.liveTitle, sessionID: sessionID, sessionsByID: sessionsByID),
                        processStatus: .exited, focusRequest: .terminalSession(workspaceID: workspaceID, sessionID: sessionID)))
            case .bell:
                guard let workspaceID = candidate.workspaceID, let session = sessionsByID[candidate.subjectID] else { continue }
                // Every session with a bell gets an entry, including one the user is looking at right now:
                // suppressing the focused session's bell is a consumption, not a filter (see
                // `consumeFocusedSessionBellAlerts`), and consumption needs the entry to exist so it can be
                // dismissed on the device.
                itemsByWorkspace[workspaceID, default: []].append(
                    entry(
                        // The row reads exactly as the session's sidebar row does (name, then what the
                        // program is doing) because its presence under Alerts is what says the bell rang.
                        icon: "terminal", iconTint: .terminal, label: session.title,
                        detail: AppKitController.terminalPaletteSecondaryLabel(
                            liveTitle: session.liveTitle, sessionID: session.id, sessionsByID: sessionsByID),
                        focusRequest: .terminalSession(workspaceID: workspaceID, sessionID: session.id)))
            case .comeBackLater:
                guard let workspaceID = candidate.workspaceID, let workspace = workspacesByID[workspaceID],
                    let reference = SpacesDeviceComeBackLaterFlag.rowReference(fromAlertKey: candidate.key)
                else { continue }
                // The row keeps its own kind's icon. An agent's icon is tinted with its alert's status
                // color, as on its waiting and done alerts, so here it takes the mark's accent.
                let presentation: (label: String, detail: String?, focusRequest: WindowFocusRequest?)?
                let icon: (name: String, tint: AppKitController.AlertsIconTint)
                switch reference.rowKind {
                case .agent:
                    icon = ("cpu.fill", .accent)
                    presentation = workspace.codingAgentRows.first(where: { $0.id == reference.rowID }).map { agent in
                        (
                            agent.name,
                            AppKitController.terminalPaletteSecondaryLabel(
                                liveTitle: agent.liveTitle, sessionID: agent.sessionID, sessionsByID: sessionsByID),
                            agentFocusRequest(agent, workspaceID: workspaceID)
                        )
                    }
                case .process:
                    icon = ("terminal", .terminal)
                    presentation = workspace.processRows.first(where: { $0.id == reference.rowID }).map { process in
                        (process.name, process.command, process.processID.map { .workspaceProcess(workspaceID: workspaceID, processID: $0) })
                    }
                case .terminal:
                    icon = ("terminal", .terminal)
                    presentation = workspace.terminalRows.first(where: { $0.id == reference.rowID }).map { terminal in
                        (
                            terminal.title,
                            AppKitController.terminalPaletteSecondaryLabel(
                                liveTitle: terminal.liveTitle, sessionID: terminal.sessionID, sessionsByID: sessionsByID),
                            terminal.sessionID.map { .terminalSession(workspaceID: workspaceID, sessionID: $0) }
                        )
                    }
                }
                guard let presentation else { continue }
                itemsByWorkspace[workspaceID, default: []].append(
                    entry(
                        icon: icon.name, iconTint: icon.tint, label: presentation.label, detail: presentation.detail,
                        focusRequest: presentation.focusRequest))
            }
        }
        var groups: [AlertsGroup] = []
        for workspace in overview.workspaces {
            guard var items = itemsByWorkspace[workspace.id], !items.isEmpty else { continue }
            items.sort(by: newestFirst)
            groups.append(
                AlertsGroup(
                    projectName: workspace.projectName, workspaceID: workspace.id, workspaceName: workspace.displayName,
                    workspaceBranch: workspace.branch, isFromHiddenWorkspace: !overview.isWorkspaceVisible(workspace), items: items,
                    deviceID: deviceID))
        }
        if !automationItems.isEmpty {
            groups.append(
                AlertsGroup(
                    projectName: "Automations", workspaceID: "automations:\(deviceID)",
                    workspaceName: deviceName.isEmpty ? "This device" : deviceName, workspaceBranch: nil, isFromHiddenWorkspace: false,
                    items: automationItems.sorted(by: newestFirst), deviceID: deviceID))
        }
        groups.sort {
            switch ($0.latestDate, $1.latestDate) {
            case (let a?, let b?): return a > b
            case (nil, _): return false
            case (_, nil): return true
            }
        }
        return groups
    }

    /// Mirrors `agentWindows(from:)` so the `.agentWindow` resolution finds the row by `agentID`/`id` and
    /// opens its session.
    nonisolated private static func agentFocusRequest(_ agent: SpacesDeviceWorkspaceCodingAgentRow, workspaceID: String) -> WindowFocusRequest {
        .agentWindow(
            AgentWindowRecord(
                id: agent.agentID ?? agent.id, workspaceID: workspaceID, provider: .spaces, label: agent.name,
                terminalTarget: agent.sessionID.map { TerminalTargetRecord(trackingID: $0) },
                status: AppKitController.agentStatus(from: agent.activityState), createdAt: agent.updatedAt ?? "", updatedAt: agent.updatedAt ?? ""))
    }

    nonisolated private static func newestFirst(_ lhs: AlertsAttentionEntry, _ rhs: AlertsAttentionEntry) -> Bool {
        switch (lhs.eventDate, rhs.eventDate) {
        case (let a?, let b?): return a > b
        case (nil, _): return false
        case (_, nil): return true
        }
    }

    /// Alert entries `groups` carries for one runtime-target row, dismissed ones included, matched by
    /// focus-request identity: a process row's exit alert via `.workspaceProcess`, an agent row's
    /// waiting/done alert via `.agentWindow`, and a bell, ended-terminal, or Come Back Later alert via
    /// `.terminalSession` for any row carrying a live session (a process or agent row's own session, or an
    /// ad hoc terminal's). This is the single derivation for "which alerts does this row own": the sidebar's
    /// Dismiss Alert menu and the exited-process color downgrade (`isProcessExitAcknowledged`) both consume
    /// it instead of re-deriving alert identity at a second site.
    nonisolated static func rowAlertsAttentionEntries(
        in groups: [AlertsGroup], workspaceID: String, processID: String? = nil, agentID: String? = nil, sessionID: String? = nil
    ) -> [AlertsAttentionEntry] {
        guard processID != nil || agentID != nil || sessionID != nil, let group = groups.first(where: { $0.workspaceID == workspaceID }) else {
            return []
        }
        return group.items.filter { entry in
            switch entry.focusRequest {
            case .workspaceProcess(_, let entryProcessID): return entryProcessID == processID
            case .agentWindow(let record): return record.id == agentID
            case .terminalSession(_, let entrySessionID): return entrySessionID == sessionID
            default: return false
            }
        }
    }

    /// Whether a process's exit alert, if it has one, is dismissed on its device. This is the one fact that
    /// downgrades a row's color from failed (red) back to not started everywhere it renders (sidebar row,
    /// workspace roll-up, command palette, workspace-detail Processes row), on every client alike because
    /// the dismissal lives on the device; agent and bell dismissals never touch color. A later exit carries
    /// a new `exitedAt`, hence a new alert key, so the process reads as failed again until its new alert is
    /// dismissed too.
    nonisolated static func isProcessExitAcknowledged(processID: String, workspaceID: String, alertsGroups: [AlertsGroup]) -> Bool {
        rowAlertsAttentionEntries(in: alertsGroups, workspaceID: workspaceID, processID: processID).first { $0.kind == .processExited }?.isDismissed
            ?? false
    }

    /// The focused session and when it took focus, refreshed on every alerts rebuild (the rebuild funnel
    /// is where this client reads keyboard focus). Bounds which of that session's bells count as rung in
    /// front of the user — see `consumeFocusedSessionBellAlerts`.
    private var focusedBellWatch: FocusedBellWatch?
    /// Attention ids of bells whose dismissal has been sent and not yet answered, so the rebuilds that
    /// land while a request is in flight do not send it again.
    private var bellDismissalsInFlight: Set<String> = []
    var alertsShortcutSpec: HotkeySpec?
    /// Maps sequential window shortcut numbers (1-10, shown as 1-0) to the focus target for the current
    /// Alerts table's row, for every row whose click focuses a runtime target.
    private var alertsFocusRequestMap: [Int: WindowFocusRequest] = [:]
    /// Maps a numbered row to the automation-run deep link its click performs
    /// (`AutomationsController.showRunsForAlert`), so a failed/timed-out automation row's shortcut does
    /// the same thing clicking it does. Disjoint from `alertsFocusRequestMap`: an automation alert has no
    /// live workspace target to focus, only a Runs-tab deep link.
    private var alertsAutomationShortcutMap: [Int: AutomationRunAlertTarget] = [:]
    /// The alerts pane as it stands on screen: the signature it was rendered from and its row views keyed
    /// by attention id. Non-nil exactly while those views are the detail pane's content, so a refresh can
    /// be answered without rebuilding them (see `showAlertsDetail`).
    private var renderedAlerts: RenderedAlertsDetail?
    /// Keeps every row's Age cell current between overview refreshes; see `armAlertsAgeRefreshTimer`.
    private var alertsAgeRefreshTimer: Timer?

    func alertsFocusRequest(for index: Int) -> WindowFocusRequest? { alertsFocusRequestMap[index] }
    func alertsAutomationRunTarget(for index: Int) -> AutomationRunAlertTarget? { alertsAutomationShortcutMap[index] }

    private struct RenderedAlertsDetail {
        let signature: AlertsRenderSignature
        let rowsByAttentionID: [String: ClickableRowView]
        /// The Age cell for each row, held separately from `rowsByAttentionID`'s `ClickableRowView`
        /// because age is the one text value that changes on a pure time-based beat rather than as part
        /// of a `label`/`detail` content refresh.
        let ageFieldsByAttentionID: [String: NSTextField]
    }

    /// Forgets what the pane was rendered from, so the next `showAlertsDetail` builds it again. Called
    /// from `presentDetailPane` whenever other content takes over the detail container; also the one
    /// place that stops the age-refresh beat, since the pane no longer being shown implies its timer
    /// should not be either (see `armAlertsAgeRefreshTimer`).
    func invalidateRenderedAlertsDetail() {
        renderedAlerts = nil
        alertsAgeRefreshTimer?.invalidate()
        alertsAgeRefreshTimer = nil
    }

    // MARK: - Alerts content

    private func buildAlertsGroups() -> [AlertsGroup] {
        Self.visibleAlertsGroups(in: host.deviceModel.alertsGroups)
    }

    /// The groups the user sees: everything derived from the overviews minus what the owning device has
    /// recorded as dismissed (by a click, or by the user having watched the session a bell rang in) and
    /// minus everything a hidden workspace or hidden project owns, which the sidebar does not list either.
    nonisolated static func visibleAlertsGroups(in groups: [AlertsGroup]) -> [AlertsGroup] {
        groups.compactMap { group -> AlertsGroup? in
            guard !group.isFromHiddenWorkspace else { return nil }
            let items = group.items.filter { !$0.isDismissed }
            guard !items.isEmpty else { return nil }
            return AlertsGroup(
                projectName: group.projectName, workspaceID: group.workspaceID, workspaceName: group.workspaceName,
                workspaceBranch: group.workspaceBranch, isFromHiddenWorkspace: group.isFromHiddenWorkspace, items: items, deviceID: group.deviceID)
        }
    }

    func alertsAttentionCount() -> Int { buildAlertsGroups().reduce(0) { total, group in total + group.items.filter(\.countsTowardBadge).count } }

    // MARK: - Render plan and signature

    /// One paired device's display facts the Alerts table needs: the name shown in its Device column
    /// (the sidebar's own "Local"/stored-name rule, `DeviceModelStore.DeviceSection.displayName`) and
    /// whether its rows dim as unreachable. Keyed by device id and passed into `alertsTableRows` so that
    /// pure function never has to reach into `DeviceModelStore` itself.
    struct AlertsDeviceDisplay: Sendable, Equatable {
        let name: String
        let isOffline: Bool
        /// Whether the device can take a request, which gates the dismiss control: the device records the
        /// dismissal, so a device that is offline or still loading cannot.
        var acceptsActions: Bool = true
    }

    /// The alerts pane's content resolved for drawing: one flat, newest-first row per alert across every
    /// device, plus the sequential window shortcut each row carries. Built once per refresh so the pane's
    /// signature and the pane itself are derived from the same resolution and cannot drift apart.
    struct AlertsRenderPlan {
        struct Row {
            let entry: AlertsAttentionEntry
            let projectName: String
            /// True for a failed/timed-out automation-run alert, whose Project / Workspace cell reads
            /// just "Automations" rather than "project / workspace": the alert deep-links to the Runs
            /// tab, not the workspace the automation targets, so naming that workspace here would imply
            /// a focus target the row does not have.
            let isAutomationsRow: Bool
            let workspaceName: String
            /// nil when the Device column is hidden (`showsDeviceColumn` false).
            let deviceText: String?
            let isOffline: Bool
            let canDismiss: Bool
            let ageText: String
            /// The row's window shortcut number, or nil past the tenth row: those get no badge and no
            /// entry in the focus-request map.
            let shortcutIndex: Int?
        }

        let showsDeviceColumn: Bool
        let rows: [Row]
    }

    /// Flattens every visible group's alerts into one table: every device's rows merged and sorted
    /// newest first by `eventDate`, undated entries last. `Array.sorted` is a stable sort (guaranteed
    /// since Swift 5), so entries with equal or missing dates keep the order `groups` already handed in,
    /// since each group's own items are already newest-first, and the groups themselves are already
    /// newest-group-first (`buildOverviewAlertsGroups`, `mergedSidebarData`), rather than shuffling on
    /// every rebuild.
    ///
    /// Pure and internal (not private) so table ordering, shortcut numbering, and offline/device
    /// derivation are testable without building any view. `buildAlertsRenderPlan()` supplies
    /// `deviceDisplay` and `showsDeviceColumn` from live host state (`DeviceModelStore.deviceSections`,
    /// `AppKitController.sidebarShowsDeviceHeaders` via `SidebarController.showsDeviceHeaders`).
    nonisolated static func alertsTableRows(groups: [AlertsGroup], deviceDisplay: [String: AlertsDeviceDisplay], showsDeviceColumn: Bool, now: Date)
        -> [AlertsRenderPlan.Row]
    {
        let entries = groups.flatMap { group in group.items.map { (group: group, entry: $0) } }
        let ordered = entries.sorted { lhs, rhs in
            switch (lhs.entry.eventDate, rhs.entry.eventDate) {
            case (let a?, let b?): return a > b
            case (nil, _): return false
            case (_, nil): return true
            }
        }
        var shortcutCounter = 1
        return ordered.map { pair in
            let shortcutIndex = shortcutCounter <= 10 ? shortcutCounter : nil
            shortcutCounter += 1
            let display = deviceDisplay[pair.group.deviceID]
            return AlertsRenderPlan.Row(
                entry: pair.entry, projectName: pair.group.projectName, isAutomationsRow: pair.entry.automationRunTarget != nil,
                workspaceName: pair.group.workspaceName, deviceText: showsDeviceColumn ? (display?.name ?? "") : nil,
                isOffline: display?.isOffline ?? false, canDismiss: display?.acceptsActions ?? true,
                ageText: pair.entry.eventDate.map { AlertsAgeFormatting.abbreviatedAge(of: $0, relativeTo: now) } ?? "", shortcutIndex: shortcutIndex)
        }
    }

    /// Everything `showAlertsDetail` renders, split by how a change to it has to be answered.
    ///
    /// `rows` is what decides which views the pane builds: row identity and order, each row's icon,
    /// tint, status indicator, shortcut number, focus target, project/workspace, device text, offline
    /// dimming, and whether its combined Alert column shows a title segment at all (`hasTitle` decides
    /// whether the title field and its separator exist, so gaining or losing one is a change of shape,
    /// not of text). `text` is the three strings each row can display without changing shape: the label
    /// and detail (a bell alert renders its session's live title as its detail, which moves as often as
    /// the terminal's title does) and the age (moves purely from wall-clock time passing, on the
    /// age-refresh beat).
    struct AlertsRenderSignature: Equatable {
        struct Row: Equatable {
            let attentionID: String
            let icon: String
            let iconTint: AppKitController.AlertsIconTint
            let shortcutIndex: Int?
            let processStatus: RunningProcessState?
            let agentStatus: AgentWindowStatus?
            let focusRequestKey: String?
            let hasTitle: Bool
            let projectName: String
            let isAutomationsRow: Bool
            let workspaceName: String
            let deviceText: String?
            let isOffline: Bool
            let canDismiss: Bool
        }

        struct RowText: Equatable {
            let attentionID: String
            let label: String
            let detail: String
            let age: String
        }

        let showsDeviceColumn: Bool
        let rows: [Row]
        /// Flattened in render order, so an equal `rows` guarantees this lines up index for index with
        /// the previously rendered text.
        let text: [RowText]
    }

    /// How a refresh compares against the alerts pane already on screen.
    enum AlertsRenderVerdict: Equatable {
        /// Nothing the pane renders moved, so the views on screen are already correct.
        case unchanged
        /// Only row strings moved, which is written into the fields already built.
        case textOnly
        /// The pane's shape changed, so it is built again.
        case structural
    }

    nonisolated static func alertsRenderVerdict(rendered: AlertsRenderSignature?, refreshed: AlertsRenderSignature) -> AlertsRenderVerdict {
        guard let rendered else { return .structural }
        guard rendered.showsDeviceColumn == refreshed.showsDeviceColumn, rendered.rows == refreshed.rows else { return .structural }
        return rendered.text == refreshed.text ? .unchanged : .textOnly
    }

    private func buildAlertsRenderPlan() -> AlertsRenderPlan {
        let showsDeviceColumn = host.sidebar.showsDeviceHeaders
        let deviceDisplay = Dictionary(
            uniqueKeysWithValues: host.deviceModel.deviceSections.map {
                (
                    $0.deviceID,
                    AlertsDeviceDisplay(
                        name: $0.displayName, isOffline: $0.loadState.isOffline,
                        acceptsActions: AppKitController.deviceAcceptsDaemonActions(deviceID: $0.deviceID, loadState: $0.loadState))
                )
            })
        let rows = Self.alertsTableRows(groups: buildAlertsGroups(), deviceDisplay: deviceDisplay, showsDeviceColumn: showsDeviceColumn, now: Date())
        return AlertsRenderPlan(showsDeviceColumn: showsDeviceColumn, rows: rows)
    }

    private static func alertsRenderSignature(plan: AlertsRenderPlan) -> AlertsRenderSignature {
        var text: [AlertsRenderSignature.RowText] = []
        var rows: [AlertsRenderSignature.Row] = []
        for row in plan.rows {
            let entry = row.entry
            text.append(
                AlertsRenderSignature.RowText(attentionID: entry.attentionID, label: entry.label, detail: entry.detail ?? "", age: row.ageText))
            rows.append(
                AlertsRenderSignature.Row(
                    attentionID: entry.attentionID, icon: entry.icon, iconTint: entry.iconTint, shortcutIndex: row.shortcutIndex,
                    processStatus: entry.processStatus, agentStatus: entry.agentStatus, focusRequestKey: entry.focusRequest?.signatureKey,
                    hasTitle: Self.alertsRowHasTitle(entry: entry), projectName: row.projectName, isAutomationsRow: row.isAutomationsRow,
                    workspaceName: row.workspaceName, deviceText: row.deviceText, isOffline: row.isOffline,
                    canDismiss: row.canDismiss))
        }
        return AlertsRenderSignature(showsDeviceColumn: plan.showsDeviceColumn, rows: rows, text: text)
    }

    /// Dismisses the bell of the session the user is typing in, on the device that raised it, every time
    /// the alerts are rebuilt from a fresh overview.
    ///
    /// The daemon records a bell for every session because it cannot see which one has keyboard focus on
    /// a given client, so this client owns the decision, and it has to dismiss the alert rather than omit
    /// it from the derivation: `bellAt` stays on the session, so a bell merely filtered out would come
    /// back the moment focus moved to another pane or the app relaunched. The dismissal is the same
    /// request a click sends, so every client sees the bell as seen. A later bell in the same session
    /// carries a new `bellAt`, hence a new key, and alerts normally.
    ///
    /// Dismissing it is the whole response: the focused session's bell produces no alert, and no sound or
    /// flash either, because the terminal views render no bell feedback (see the `.ringBell` case in
    /// `GhosttyMirrorTerminalView`). That is the decided behavior — a bell you are watching happen needs
    /// no notification — not a missing piece to fill in.
    ///
    /// Only bells rung *since* focus arrived are consumed. Focusing a session is not a way to clear its
    /// alerts: a bell the session rang while the user was elsewhere stays an alert for them to dismiss,
    /// exactly as iOS's watch windows leave it. A failed request is dropped: the bell stays visible and
    /// the next rebuild asks again.
    func consumeFocusedSessionBellAlerts() {
        focusedBellWatch = Self.updatedFocusedBellWatch(focusedBellWatch, focusedSessionID: host.panelCoordinator.focusedSessionID(), now: Date())
        guard let focusedBellWatch else { return }
        let consumed = Self.bellAttentionIDs(in: host.deviceModel.alertsGroups, watch: focusedBellWatch)
        // An in-flight id whose bell is no longer a pending consumption was answered (or went away).
        bellDismissalsInFlight.formIntersection(consumed)
        let toSend = consumed.subtracting(bellDismissalsInFlight)
        guard !toSend.isEmpty else { return }
        bellDismissalsInFlight.formUnion(toSend)
        let requests = dismissalRequests(for: toSend)
        Task { @MainActor [weak self] in
            for (deviceID, keys) in requests { _ = await self?.host.dismissAlerts(keys: keys, deviceID: deviceID) }
            self?.bellDismissalsInFlight.subtract(toSend)
        }
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

    /// Identities of the focused session's undismissed bell alerts that rang at or after focus arrived. An
    /// entry whose timestamp did not parse carries no date to compare and is left alerting.
    nonisolated static func bellAttentionIDs(in groups: [AlertsGroup], watch: FocusedBellWatch) -> Set<String> {
        let boundary = watch.since.addingTimeInterval(-focusedBellSkewTolerance)
        return Set(
            groups.lazy.flatMap(\.items).filter { item in
                guard item.kind == .bell, !item.isDismissed, case .terminalSession(_, let itemSessionID) = item.focusRequest,
                    itemSessionID == watch.sessionID
                else { return false }
                guard let eventDate = item.eventDate else { return false }
                return eventDate >= boundary
            }.map(\.attentionID))
    }

    /// The device-free keys to dismiss, grouped by the device that raised each alert. Ids that no longer
    /// name a derived alert are skipped.
    private func dismissalRequests(for attentionIDs: Set<String>) -> [String: [String]] {
        var keysByDevice: [String: [String]] = [:]
        for entry in host.deviceModel.alertsGroups.lazy.flatMap(\.items) where attentionIDs.contains(entry.attentionID) {
            keysByDevice[entry.deviceID, default: []].append(entry.alertKey)
        }
        return keysByDevice
    }

    /// Asks each owning device to dismiss the alerts, then shows the list its answer produces. The row
    /// stays until that answer arrives; nothing is hidden ahead of it.
    func dismissAlertsAttentionItems(_ attentionIDs: [String]) {
        let requests = dismissalRequests(for: Set(attentionIDs))
        guard !requests.isEmpty else { return }
        Task { @MainActor [weak self] in
            for (deviceID, keys) in requests {
                guard let self else { return }
                switch await host.dismissAlerts(keys: keys, deviceID: deviceID) {
                case .success:
                    // The palette otherwise only re-derives on its next presentation; while it is already
                    // open, reload it so the dismissal is reflected without reopening it.
                    if host.commandPalette.commandPalettePanel?.isVisible == true { host.commandPalette.reloadCommandPaletteItems() }
                case .failure(let error): host.showError(error)
                }
            }
        }
    }

    func dismissAlertsAttentionItem(_ attentionID: String) { dismissAlertsAttentionItems([attentionID]) }

    /// Whether the device that raised an alert can take a request, which is what the dismiss controls
    /// follow: a dismissal is recorded by the device, so one that is offline cannot take it.
    func canDismissAlert(attentionID: String) -> Bool {
        AlertsController.deviceID(fromAttentionID: attentionID).map(host.deviceAcceptsDaemonActions(forDeviceID:)) ?? false
    }

    /// Renders the Alerts pane. Also the pane's re-render: every refresh that lands new device state
    /// calls this again while alerts is already the visible pane, so nothing here may discard state the
    /// user is in the middle of. `presentation` is what tells the two apart — it defaults to the
    /// refresh, and only the entry points the user actually reached for pass `.userNavigation`.
    ///
    /// The render itself replaces every view in the detail container, so a refresh that would draw the
    /// same pane must not run one: while a terminal streams, refreshes arrive many times a second and
    /// each rebuild destroys the card or dismiss button under the pointer between mouse-down and
    /// mouse-up, which is what makes clicks in this pane die. The pane's signature decides that, and a
    /// refresh that moved only row text is written into the fields already built.
    ///
    /// Appearance is deliberately not part of the signature: text is drawn in dynamic `NSColor`s and the
    /// layer colors are re-resolved by `bindAppearanceReactiveLayer`, so a light/dark switch recolors the
    /// views that are already on screen without any render.
    func showAlertsDetail(presentation: DetailPanePresentation = .backgroundRefresh) {
        host.stopWorkspaceSetupDetailRefreshTimer()
        host.presentDetailPane(.alerts, presentation: presentation)
        host.showingSettings = false
        let previousProjectID = host.selectedProjectID
        let previousWorkspaceID = host.selectedWorkspaceID
        host.selectedProjectID = nil
        host.selectedWorkspaceID = nil
        host.outlineView.deselectAll(nil)
        // Reload only the previously-selected workspace row to clear its selection styling;
        // avoid full reloadData() which would reset expand/collapse state.
        host.refreshSidebarSelectionRows(
            previousProjectID: previousProjectID, currentProjectID: nil, previousWorkspaceID: previousWorkspaceID, currentWorkspaceID: nil)
        host.updateAlertsRowAppearance()

        let plan = buildAlertsRenderPlan()
        let signature = Self.alertsRenderSignature(plan: plan)
        // `.userNavigation` always renders: the user reaching for this pane is how it gets built when
        // something else was showing.
        if presentation == .backgroundRefresh, let rendered = renderedAlerts {
            switch Self.alertsRenderVerdict(rendered: rendered.signature, refreshed: signature) {
            case .unchanged: return
            case .textOnly:
                // Only the rows whose strings moved are touched; an equal `rows` means the two text lists
                // line up index for index. `alertsFocusRequestMap`/`alertsAutomationShortcutMap` are
                // rebuilt by the render below, so skipping the render keeps the maps the previous one
                // left, which is still correct: an equal `rows` means the same entries in the same order
                // with the same focus targets.
                for (previous, current) in zip(rendered.signature.text, signature.text) where previous != current {
                    rendered.rowsByAttentionID[current.attentionID]?.updateText(label: current.label, detail: current.detail)
                    if previous.age != current.age { rendered.ageFieldsByAttentionID[current.attentionID]?.stringValue = current.age }
                }
                renderedAlerts = RenderedAlertsDetail(
                    signature: signature, rowsByAttentionID: rendered.rowsByAttentionID, ageFieldsByAttentionID: rendered.ageFieldsByAttentionID)
                return
            case .structural: break
            }
        }

        alertsFocusRequestMap = [:]
        alertsAutomationShortcutMap = [:]
        host.clearWorkspaceDetailFooter()
        for view in host.detailContainer.subviews { view.removeFromSuperview() }
        host.detailContainer.wantsLayer = true
        bindAppearanceReactiveLayer(host.detailContainer) { [unowned host] view in
            view.layer?.backgroundColor = host.sidebar.sidebarPanelBackgroundColor().cgColor
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let headerTitle = NSTextField(labelWithString: "Alerts")
        headerTitle.font = Typography.pageTitle
        headerTitle.textColor = host.sidebar.sidebarPrimaryTextColor(isSelected: false)

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.addArrangedSubview(headerTitle)

        stack.addArrangedSubview(headerRow)
        constrainFormFieldToFillWidth(headerRow, in: stack)

        if plan.rows.isEmpty {
            let sep = NSView()
            sep.translatesAutoresizingMaskIntoConstraints = false
            sep.wantsLayer = true
            bindAppearanceReactiveLayer(sep) { [unowned host] view in
                view.layer?.backgroundColor = host.sidebar.sidebarCardBorderColor(isSelected: false).cgColor
            }
            sep.heightAnchor.constraint(equalToConstant: 1).isActive = true
            stack.addArrangedSubview(sep)
            constrainFormFieldToFillWidth(sep, in: stack)

            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "All clear")
            icon.contentTintColor = host.sidebar.sidebarRunningIndicatorColor()
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28)])
            let emptyTitle = NSTextField(labelWithString: "No attention required")
            emptyTitle.font = Typography.rowLabel
            emptyTitle.textColor = .labelColor
            let emptyDetail = NSTextField(labelWithString: "All running workspaces are healthy.")
            emptyDetail.font = Typography.metadata
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
            constrainFormFieldToFillWidth(emptyStack, in: stack)

            showScrollableDetailStack(stack, in: host.detailContainer)
            renderedAlerts = RenderedAlertsDetail(signature: signature, rowsByAttentionID: [:], ageFieldsByAttentionID: [:])
            alertsAgeRefreshTimer?.invalidate()
            alertsAgeRefreshTimer = nil
            return
        }

        var rowsByAttentionID: [String: ClickableRowView] = [:]
        var ageFieldsByAttentionID: [String: NSTextField] = [:]
        let sideInset: CGFloat = 4
        let table = NSStackView()
        table.orientation = .vertical
        table.alignment = .leading
        table.spacing = 0
        table.edgeInsets = NSEdgeInsets(top: 6, left: sideInset, bottom: 6, right: sideInset)
        table.translatesAutoresizingMaskIntoConstraints = false

        let grid = TableGrid()
        let header = makeAlertsHeaderLine(grid: grid, showsDeviceColumn: plan.showsDeviceColumn)
        let divider = makeAlertsTableDivider()
        var lines: [NSView] = [header, divider]
        for row in plan.rows {
            let entry = row.entry
            if let shortcutIndex = row.shortcutIndex {
                if let focusRequest = entry.focusRequest {
                    alertsFocusRequestMap[shortcutIndex] = focusRequest
                } else if let automationRunTarget = entry.automationRunTarget {
                    alertsAutomationShortcutMap[shortcutIndex] = automationRunTarget
                }
            }
            let built = makeAlertsRowLine(row, grid: grid, showsDeviceColumn: plan.showsDeviceColumn)
            rowsByAttentionID[entry.attentionID] = built.row
            ageFieldsByAttentionID[entry.attentionID] = built.ageField
            lines.append(built.row)
        }
        for line in lines { table.addArrangedSubview(line) }
        table.setCustomSpacing(4, after: header)
        table.setCustomSpacing(4, after: divider)

        // Leading alignment gives arranged lines their intrinsic width, so pin each to the table's full
        // width (minus its edge insets) to keep the grid's trailing columns right-aligned.
        for line in lines { line.widthAnchor.constraint(equalTo: table.widthAnchor, constant: -sideInset * 2).isActive = true }
        // Every line now shares the table's view hierarchy, so the rows can be tied to the header's columns.
        grid.activateColumnAlignment()
        stack.addArrangedSubview(table)
        constrainFormFieldToFillWidth(table, in: stack)

        showScrollableDetailStack(stack, in: host.detailContainer)
        renderedAlerts = RenderedAlertsDetail(
            signature: signature, rowsByAttentionID: rowsByAttentionID, ageFieldsByAttentionID: ageFieldsByAttentionID)
        armAlertsAgeRefreshTimer()
    }

    /// Keeps every row's Age cell current while the pane is open, without a structural rebuild: age is
    /// the only value on the pane that moves purely from wall-clock time passing, with no overview
    /// refresh to trigger a repaint. Mirrors `AutomationsController.armRelativeTimeRefresh`'s
    /// self-terminating 30 s beat (iOS uses the same 30 s cadence for its Alerts age labels). Ticking
    /// calls `showAlertsDetail()` itself (a background refresh), so a tick where nothing (not even age)
    /// changed correctly takes the `.unchanged` early return without disturbing this same `Timer`, which
    /// keeps firing on its own; the timer is only ever torn down by `invalidateRenderedAlertsDetail()`
    /// when the pane stops being shown, or here when it notices that has already happened.
    private func armAlertsAgeRefreshTimer() {
        alertsAgeRefreshTimer?.invalidate()
        alertsAgeRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, host.showingAlerts else {
                    self?.alertsAgeRefreshTimer?.invalidate()
                    self?.alertsAgeRefreshTimer = nil
                    return
                }
                showAlertsDetail()
            }
        }
    }

    // MARK: - Table

    /// Column widths for the Alerts pane's table, laid out on the shared `TableGrid`.
    private enum AlertsTableLayout {
        /// Wide enough for the widest shortcut badge text ("⌘0" plus a custom modifier glyph).
        static let shortcut: CGFloat = 34
        static let device: CGFloat = 96
        static let age: CGFloat = 40
        static let dismiss: CGFloat = 24
        /// Tall enough for the Alert column's icon + 12 pt name + 11 pt title on one line.
        static let rowHeight: CGFloat = 32
    }

    private func makeAlertsHeaderLine(grid: TableGrid, showsDeviceColumn: Bool) -> NSView {
        func header(_ text: String, alignment: NSTextAlignment = .left) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = Typography.metadataTitle
            label.textColor = Theme.mutedSecondary
            label.alignment = alignment
            label.lineBreakMode = .byTruncatingTail
            return label
        }
        var columns: [(view: NSView, width: TableGrid.ColumnWidth)] = [
            (RowPrimitives.statusSlot(), .asIs), (NSView(), .fixed(AlertsTableLayout.shortcut)),
            // The Alert column takes the table's leftover width: it is the only column with real content
            // that benefits from more room (a longer project/workspace/name/title line), where every
            // other column's content is short and fixed-shape.
            (header("Alert"), .growable(preferred: 340, minimum: 220)),
        ]
        if showsDeviceColumn { columns.append((header("Device"), .capped(preferred: AlertsTableLayout.device, minimum: 72))) }
        columns.append((header("Age", alignment: .right), .fixed(AlertsTableLayout.age)))
        columns.append((NSView(), .fixed(AlertsTableLayout.dismiss)))
        return grid.makeHeaderLine(columns)
    }

    private func makeAlertsTableDivider() -> NSView {
        let divider = ColoredBackgroundView()
        divider.fillColor = Theme.border
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return divider
    }

    /// Builds one alerts row on the shared grid: status, shortcut, the combined Alert column, device
    /// (when shown), age, and the dismiss button. Returns the row's Age field alongside its container so
    /// the age-refresh beat can rewrite it without a rebuild; the name/title fields are handed to
    /// `ClickableRowView` itself (`labelField`/`detailField`) for the same reason.
    private func makeAlertsRowLine(_ row: AlertsRenderPlan.Row, grid: TableGrid, showsDeviceColumn: Bool) -> (
        row: ClickableRowView, ageField: NSTextField
    ) {
        let entry = row.entry
        let shortcutText = row.shortcutIndex.map { host.windowShortcutBadgeText(index: $0) } ?? ""
        let automationID = entry.agentStatus == nil ? nil : "alerts-agent-\(AppKitController.automationIdentifierSlug(entry.label))"

        let cardAction: (() async -> Void)?
        if let focusRequest = entry.focusRequest {
            cardAction = { [weak self] in
                guard let self else { return }
                await self.host.windowFocus.performWindowFocus(focusRequest)
            }
        } else if let automationRunTarget = entry.automationRunTarget {
            cardAction = { [weak self] in
                self?.host.automations.showRunsForAlert(deviceID: automationRunTarget.deviceID, runID: automationRunTarget.runID)
            }
        } else {
            cardAction = nil
        }

        let container = ClickableRowView(isInteractive: cardAction != nil)
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityLabel(entry.label)
        if let detail = entry.detail, !detail.isEmpty { container.setAccessibilityValue(detail) }
        if let automationID { container.setAccessibilityIdentifier("\(automationID)-row") }

        let statusView = Self.alertsStatusIndicator(
            isComeBackLater: entry.kind == .comeBackLater, processStatus: entry.processStatus, agentStatus: entry.agentStatus, automationID: automationID)

        let shortcutLabel = NSTextField(labelWithString: shortcutText)
        shortcutLabel.font = Typography.monoBadge
        shortcutLabel.textColor = .secondaryLabelColor

        let (alertCell, labelField, detailField) = Self.alertsCombinedCell(row: row, automationID: automationID)
        container.labelField = labelField
        container.detailField = detailField

        let deviceCell = showsDeviceColumn ? alertsDeviceCell(text: row.deviceText ?? "", isOffline: row.isOffline) : nil

        let ageField = NSTextField(labelWithString: row.ageText)
        ageField.font = Typography.metadata
        ageField.textColor = .secondaryLabelColor
        ageField.alignment = .right
        ageField.lineBreakMode = .byClipping

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
        dismissButton.isEnabled = row.canDismiss

        var columns: [NSView] = [statusView, shortcutLabel, alertCell]
        if let deviceCell { columns.append(deviceCell) }
        columns.append(ageField)
        columns.append(dismissButton)
        let line = grid.makeRowLine(columns)

        container.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor), line.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            line.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.heightAnchor.constraint(equalToConstant: AlertsTableLayout.rowHeight),
        ])

        // The dismiss button is a column inside this same clickable line, not a separate sibling region,
        // so its click needs an explicit veto or it would also fire the row action: the same exclusion
        // `AutomationsTableRowView` gives its enable switch and next-run chip.
        if let cardAction { attachAlertsRowClickAction(to: container, action: cardAction) }

        if row.isOffline {
            container.alphaValue = AppKitController.unreachableDeviceAlpha
            container.toolTip = "\(row.deviceText?.isEmpty == false ? row.deviceText! : "This device") is offline"
        }

        return (row: container, ageField: ageField)
    }

    /// Whether the combined Alert column shows a title segment: a bell's live title, a process's
    /// command, an agent's detail, or an automation run's outcome. Omitted when there is none, or when
    /// it would only repeat the name (`entry.detail == entry.label`).
    nonisolated static func alertsRowHasTitle(entry: AlertsAttentionEntry) -> Bool {
        guard let detail = entry.detail, !detail.isEmpty else { return false }
        return detail != entry.label
    }

    /// One text run in the combined Alert column, in display order.
    struct AlertsCombinedSegment: Equatable {
        enum Kind: Equatable {
            case project, workspace
            /// The alert's name: a process/session/agent name for a workspace alert, or the automation's
            /// name for an automation-run alert.
            case name
            case separator
            /// The alert's live title: a bell's live terminal title, a process's command, an agent's
            /// detail, or an automation run's outcome text. The first segment to truncate under
            /// pressure (see `AlertsCombinedCompressionPriority`).
            case title
        }
        let kind: Kind
        let text: String
    }

    /// The combined Alert column's content, in order: `project / workspace / name / title` for a
    /// workspace alert, or `name / title` for an automation-run alert (which has no live workspace to
    /// name, since its click deep-links to the Runs tab instead). The title segment, and its leading
    /// separator, is left out when there is none or when it would only repeat the name.
    ///
    /// Pulled out as its own pure function, decoupled from `NSTextField` construction, so which segments
    /// appear and their order is a decision made once here rather than spread across view-building code;
    /// whether the name segment stays here at all is still an open product question, and keeping the
    /// decision in one function is what makes that a one-line change when it is settled.
    nonisolated static func alertsCombinedSegments(row: AlertsRenderPlan.Row) -> [AlertsCombinedSegment] {
        var segments: [AlertsCombinedSegment] = []
        if !row.isAutomationsRow {
            segments.append(AlertsCombinedSegment(kind: .project, text: row.projectName))
            segments.append(AlertsCombinedSegment(kind: .separator, text: "/"))
            segments.append(AlertsCombinedSegment(kind: .workspace, text: row.workspaceName))
            segments.append(AlertsCombinedSegment(kind: .separator, text: "/"))
        }
        segments.append(AlertsCombinedSegment(kind: .name, text: row.entry.label))
        if Self.alertsRowHasTitle(entry: row.entry) {
            segments.append(AlertsCombinedSegment(kind: .separator, text: "/"))
            segments.append(AlertsCombinedSegment(kind: .title, text: row.entry.detail ?? ""))
        }
        return segments
    }

    /// The combined Alert column's per-segment give-way order under horizontal pressure: title first
    /// (it is already secondary detail), then workspace, then project, and name last, since name is the
    /// row's identity and is typically short anyway. Every value stays below `.required` so the row's
    /// width, pinned equal to the header column by `TableGrid`, can always be satisfied by shrinking a
    /// segment instead of the grid clipping arbitrarily or breaking constraints. Separators keep
    /// `.required`: a bare "/" has nothing useful to truncate to, and it is never why a row cannot fit,
    /// since some segment ahead of it in this order always has room to give first.
    private enum AlertsCombinedCompressionPriority {
        static let title = NSLayoutConstraint.Priority(250)
        static let workspace = NSLayoutConstraint.Priority(400)
        static let project = NSLayoutConstraint.Priority(500)
        static let name = NSLayoutConstraint.Priority(600)
    }

    /// Builds the Alert column's cell from `alertsCombinedSegments`. Every non-separator segment truncates
    /// with a tail ellipsis under `AlertsCombinedCompressionPriority`'s order, so an overlong identity
    /// loses width from its least identifying segment first rather than clipping an arbitrary one.
    ///
    /// Static and not private (it touches no instance state) so a layout test can build and measure the
    /// cell directly, without constructing a host `AppKitController` just to reach it.
    static func alertsCombinedCell(row: AlertsRenderPlan.Row, automationID: String?) -> (
        view: NSView, labelField: NSTextField, detailField: NSTextField?
    ) {
        let entry = row.entry
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: entry.icon, accessibilityDescription: nil)
        iconView.contentTintColor = AppKitController.alertsIconColor(entry.iconTint)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        var views: [NSView] = [iconView]
        var labelField: NSTextField?
        var detailField: NSTextField?
        for segment in Self.alertsCombinedSegments(row: row) {
            let field = NSTextField(labelWithString: segment.text)
            switch segment.kind {
            case .separator:
                field.font = Typography.rowDetail
                field.textColor = .secondaryLabelColor
                field.setContentHuggingPriority(.required, for: .horizontal)
                field.setContentCompressionResistancePriority(.required, for: .horizontal)
            case .workspace:
                field.font = Typography.rowDetail
                field.textColor = .secondaryLabelColor
                field.lineBreakMode = .byTruncatingTail
                field.setContentHuggingPriority(.required, for: .horizontal)
                field.setContentCompressionResistancePriority(AlertsCombinedCompressionPriority.workspace, for: .horizontal)
            case .project:
                field.font = Typography.rowDetail
                field.textColor = .secondaryLabelColor
                field.lineBreakMode = .byTruncatingTail
                field.setContentHuggingPriority(.required, for: .horizontal)
                field.setContentCompressionResistancePriority(AlertsCombinedCompressionPriority.project, for: .horizontal)
            case .name:
                field.font = Typography.compactTitle
                field.textColor = .labelColor
                field.lineBreakMode = .byTruncatingTail
                field.setContentHuggingPriority(.required, for: .horizontal)
                field.setContentCompressionResistancePriority(AlertsCombinedCompressionPriority.name, for: .horizontal)
                if let automationID { field.setAccessibilityIdentifier("\(automationID)-label") }
                labelField = field
            case .title:
                field.font = Typography.metadata
                field.textColor = .secondaryLabelColor
                field.lineBreakMode = .byTruncatingTail
                field.setContentHuggingPriority(.defaultLow, for: .horizontal)
                field.setContentCompressionResistancePriority(AlertsCombinedCompressionPriority.title, for: .horizontal)
                if let automationID { field.setAccessibilityIdentifier("\(automationID)-detail") }
                detailField = field
            }
            views.append(field)
        }

        let cell = NSStackView(views: views)
        cell.orientation = .horizontal
        cell.alignment = .firstBaseline
        cell.spacing = 4
        // `alertsCombinedSegments` always emits exactly one `.name` segment, so this is never nil.
        return (cell, labelField!, detailField)
    }

    /// The Device column: the device's display name, with "offline" trailing it in the same red the
    /// sidebar's device headers use when that device is unreachable.
    private func alertsDeviceCell(text: String, isOffline: Bool) -> NSView {
        let nameLabel = NSTextField(labelWithString: text)
        nameLabel.font = Typography.rowDetail
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingTail

        let cell = NSStackView(views: [nameLabel])
        cell.orientation = .horizontal
        cell.alignment = .firstBaseline
        cell.spacing = 4
        guard isOffline else { return cell }

        let offlineLabel = NSTextField(labelWithString: "offline")
        offlineLabel.font = Typography.rowDetail
        offlineLabel.textColor = host.sidebar.sidebarFailedIndicatorColor()
        cell.addArrangedSubview(offlineLabel)
        return cell
    }

    /// The row's leading status indicator: an agent's spinner/dot, a process dot, or an empty slot that
    /// keeps every row's shortcut badge aligned regardless of whether it carries a status. Reuses
    /// `RowPrimitives.statusSlot` (the same 14 pt slot the Automations table's status column uses) rather
    /// than the former `windowRow`'s own hand-built slot, so both hand-rolled tables' status columns
    /// align on the same width.
    private static func alertsStatusIndicator(
        isComeBackLater: Bool, processStatus: RunningProcessState?, agentStatus: AgentWindowStatus?, automationID: String?
    ) -> NSView {
        // A Come Back Later row has no run status of its own to show; the status column carries the mark.
        if isComeBackLater {
            let mark = NSImageView()
            mark.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: "Come Back Later")
            mark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            mark.contentTintColor = Theme.accent
            mark.toolTip = "Come Back Later"
            return RowPrimitives.statusSlot(mark)
        }
        if let agentStatus {
            guard agentStatus != .spinning else {
                let spinner = NSProgressIndicator()
                if let automationID { spinner.setAccessibilityIdentifier("\(automationID)-status-spinning") }
                spinner.style = .spinning
                spinner.controlSize = .mini
                spinner.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    spinner.widthAnchor.constraint(equalToConstant: 10), spinner.heightAnchor.constraint(equalToConstant: 10),
                ])
                spinner.startAnimation(nil)
                return RowPrimitives.statusSlot(spinner)
            }
            let (statusIconName, statusColor) = AppKitController.agentStatusSymbolAndColor(agentStatus)
            let statusDot = NSImageView()
            if let automationID { statusDot.setAccessibilityIdentifier("\(automationID)-status-\(agentStatus.rawValue)") }
            statusDot.image = NSImage(systemSymbolName: statusIconName, accessibilityDescription: agentStatus.rawValue)
            statusDot.contentTintColor = statusColor
            statusDot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                statusDot.widthAnchor.constraint(equalToConstant: 10), statusDot.heightAnchor.constraint(equalToConstant: 10),
            ])
            return RowPrimitives.statusSlot(statusDot)
        }
        if let processStatus {
            let statusIconName: String
            let statusColor: NSColor
            switch processStatus {
            case .running:
                statusIconName = "circle.fill"
                statusColor = .systemGreen
            case .exited:
                statusIconName = "circle"
                statusColor = .systemRed
            case .idle:
                statusIconName = "circle"
                statusColor = .tertiaryLabelColor
            }
            let statusDot = NSImageView()
            statusDot.image = NSImage(systemSymbolName: statusIconName, accessibilityDescription: processStatus.rawValue)
            statusDot.contentTintColor = statusColor
            statusDot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([statusDot.widthAnchor.constraint(equalToConstant: 8), statusDot.heightAnchor.constraint(equalToConstant: 8)])
            return RowPrimitives.statusSlot(statusDot)
        }
        return RowPrimitives.statusSlot()
    }

    /// Attaches the row's click action to the whole table row. `attachAlertsRowGestureDelegate` refuses
    /// recognition where the dismiss button already owns the click, since that button lives inside this
    /// same clickable line rather than as a separate sibling region.
    private func attachAlertsRowClickAction(to view: NSView, action: @escaping () async -> Void) {
        let target = AppKitController.ClickTarget(action)
        let recognizer = NSClickGestureRecognizer(target: target, action: #selector(AppKitController.ClickTarget.clicked(_:)))
        recognizer.delegate = alertsRowGestureDelegate
        view.addGestureRecognizer(recognizer)
        objc_setAssociatedObject(view, &AppKitController.clickTargetAssocKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// One shared, stateless delegate reused by every row's click recognizer (see
    /// `attachAlertsRowClickAction`).
    private let alertsRowGestureDelegate = AlertsRowGestureDelegate()

    @objc private func dismissAlertsAttentionItemAction(_ sender: NSButton) {
        guard let attentionID = sender.identifier?.rawValue, !attentionID.isEmpty else { return }
        dismissAlertsAttentionItem(attentionID)
    }

    func handleAlertsShortcut(event: NSEvent) -> Bool {
        guard let alertsShortcutSpec, host.shortcuts.matches(event: event, spec: alertsShortcutSpec) else { return false }
        showAlertsDetail(presentation: .userNavigation)
        return true
    }
}

/// Refuses row-click recognition where the dismiss button already owns the click. The dismiss button is
/// a column inside the same clickable row line (not a separate sibling region, unlike the sidebar's
/// trailing accessories), so the row's own click gesture needs this veto or a dismiss click would also
/// fire the row action. Mirrors `AutomationsTableRowView.gestureRecognizer(_:shouldAttemptToRecognizeWith:)`.
@MainActor final class AlertsRowGestureDelegate: NSObject, NSGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard let view = gestureRecognizer.view else { return true }
        let location = view.convert(event.locationInWindow, from: nil)
        var hit = view.hitTest(location)
        while let candidate = hit, candidate !== view {
            if candidate is NSButton { return false }
            hit = candidate.superview
        }
        return true
    }
}
