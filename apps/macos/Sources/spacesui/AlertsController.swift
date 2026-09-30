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
    /// Opens the per-client desktop-state database dismissed-alert ids are persisted to. Injected rather
    /// than reaching through `host.clientDatabase()` so this controller owns its persistence dependency
    /// directly and a test can substitute a throwaway database.
    private let database: () throws -> SpacesClientDatabase

    init(host: AppKitController, database: @escaping () throws -> SpacesClientDatabase) {
        self.host = host
        self.database = database
        super.init()
    }

    typealias WindowFocusRequest = AppKitController.WindowFocusRequest

    struct AlertsAttentionEntry: Sendable {
        let attentionID: String
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
            attentionID: String, icon: String, iconTint: AppKitController.AlertsIconTint, label: String, detail: String?, shortcut: String,
            processStatus: RunningProcessState? = nil, agentStatus: AgentWindowStatus? = nil, countsTowardBadge: Bool, eventDate: Date?,
            focusRequest: WindowFocusRequest? = nil, automationRunTarget: AutomationRunAlertTarget? = nil
        ) {
            self.attentionID = attentionID
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
        /// Hidden workspaces still get their groups built, because the persisted dismissal set is pruned
        /// against the derived identities (`AlertsController.retainedDismissedAttentionItemIDs`) — dropping
        /// the group would forget the dismissals and resurrect cleared alerts on unhide. The display
        /// surfaces (the alerts pane, its badge, the command palette) filter on this flag instead.
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

    // ISO8601DateFormatter construction is expensive and this is shared by the `nonisolated`
    // overview-mapping helper below (buildOverviewAlertsGroups), which runs off the main actor.
    // ISO8601DateFormatter is documented thread-safe, so a single nonisolated instance is safe to
    // reuse instead of allocating a fresh formatter per call.
    nonisolated(unsafe) private static let staticISO8601Formatter = ISO8601DateFormatter()

    /// Builds attention alerts for a device from its overview payload — used for both the local and
    /// remote devices so alerts aggregate identically across the sidebar without the client ever
    /// opening `spaces.db`. Window-role styling (browser/editor icons, per-window focus) is
    /// intentionally absent: desktop windows are client-local and not part of the daemon overview,
    /// so an exited process shows as a process alert and clicking it focuses the process. Recency
    /// (and dismissal identity) come from the daemon-supplied `exitedAt`/`updatedAt` timestamps.
    nonisolated static func buildOverviewAlertsGroups(from overview: SpacesDeviceOverviewPayload, deviceID: String, deviceName: String = "")
        -> [AlertsGroup]
    {
        let iso8601Formatter = staticISO8601Formatter
        // First-wins matches the `first(where:)` scan this replaces.
        let sessionsByID = Dictionary(overview.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sessionsByWorkspace = Dictionary(grouping: overview.sessions, by: \.workspaceID)
        var groups: [AlertsGroup] = []
        for workspace in overview.workspaces {
            var items: [AlertsAttentionEntry] = []
            if workspace.isRunning {
                for process in workspace.processRows where process.runState == .exited {
                    let eventDate = process.exitedAt.flatMap { iso8601Formatter.date(from: $0) }
                    items.append(
                        AlertsAttentionEntry(
                            attentionID: "alert:\(deviceID):process:\(process.processID ?? process.id):\(process.exitedAt ?? "unknown")",
                            icon: "terminal", iconTint: .terminal, label: process.name, detail: process.command, shortcut: "", processStatus: .exited,
                            agentStatus: nil, countsTowardBadge: true, eventDate: eventDate,
                            focusRequest: process.processID.map { .workspaceProcess(workspaceID: workspace.id, processID: $0) }))
                }
            }
            for agent in workspace.codingAgentRows where agent.activityState == .waiting || agent.activityState == .done {
                let eventDate = agent.updatedAt.flatMap { iso8601Formatter.date(from: $0) }
                // Both states keep the cpu.fill agent identity; the tint alone carries the state —
                // `waiting` (blocked on the user) is amber and `done` is blue, the same colors the row wears
                // in the sidebar — so a finished agent doesn't read as still needing attention.
                let iconTint: AppKitController.AlertsIconTint = agent.activityState == .done ? .done : .warning
                items.append(
                    AlertsAttentionEntry(
                        attentionID: "alert:\(deviceID):agent:\(agent.agentID ?? agent.id):\(agent.activityState.rawValue):\(agent.updatedAt ?? "")",
                        icon: "cpu.fill", iconTint: iconTint, label: agent.name,
                        detail: AppKitController.terminalPaletteSecondaryLabel(
                            liveTitle: agent.liveTitle, sessionID: agent.sessionID, sessionsByID: sessionsByID), shortcut: "", processStatus: nil,
                        agentStatus: AgentWindowStatus(rawValue: agent.activityState.rawValue), countsTowardBadge: true, eventDate: eventDate,
                        // Mirror `agentWindows(from:)` so the `.agentWindow` resolution finds the row by
                        // `agentID`/`id` and opens its session.
                        focusRequest: .agentWindow(
                            AgentWindowRecord(
                                id: agent.agentID ?? agent.id, workspaceID: workspace.id, provider: .spaces, label: agent.name,
                                terminalTarget: agent.sessionID.map { TerminalTargetRecord(trackingID: $0) },
                                status: AppKitController.agentStatus(from: agent.activityState), createdAt: agent.updatedAt ?? "",
                                updatedAt: agent.updatedAt ?? ""))))
            }
            // Every session with a bell gets an entry, including one the user is looking at right now:
            // suppressing the focused session's bell is a consumption, not a filter (see
            // `AlertsController.consumeFocusedSessionBellAlerts`), and consumption needs the entry to
            // exist so its identity can be recorded and kept alive by the dismissal pruning rule.
            for session in sessionsByWorkspace[workspace.id] ?? [] {
                guard let bellAt = session.bellAt else { continue }
                // Not `iso8601Formatter`: a Linux daemon stamps runtime state with fractional seconds,
                // which the framework's default format rejects, and the age is the only recency this row
                // carries.
                let eventDate = GhosttyRemoteSessionStateTimestamp.date(from: bellAt)
                items.append(
                    AlertsAttentionEntry(
                        attentionID: "alert:\(deviceID):session:\(session.id):bell:\(bellAt)", icon: "terminal", iconTint: .terminal,
                        // The row reads exactly as the session's sidebar row does — name, then what the
                        // program is doing — because its presence under Alerts is what says the bell rang.
                        label: session.title,
                        detail: AppKitController.terminalPaletteSecondaryLabel(
                            liveTitle: session.liveTitle, sessionID: session.id, sessionsByID: sessionsByID), shortcut: "", processStatus: nil,
                        agentStatus: nil, countsTowardBadge: true, eventDate: eventDate,
                        focusRequest: .terminalSession(workspaceID: workspace.id, sessionID: session.id)))
            }
            guard !items.isEmpty else { continue }
            items.sort {
                switch ($0.eventDate, $1.eventDate) {
                case (let a?, let b?): return a > b
                case (nil, _): return false
                case (_, nil): return true
                }
            }
            groups.append(
                AlertsGroup(
                    projectName: workspace.projectName, workspaceID: workspace.id, workspaceName: workspace.displayName,
                    workspaceBranch: workspace.branch, isFromHiddenWorkspace: !overview.isWorkspaceVisible(workspace), items: items,
                    deviceID: deviceID))
        }
        // Failed/timed-out automation runs form their own synthetic group ("Automations / <device>") whose
        // cards deep-link to the Runs tab instead of focusing a live workspace target that may be detached.
        let automationEntries = AutomationsViewModel.alertEntries(deviceID: deviceID, deviceName: deviceName, runs: overview.automationRuns)
        if !automationEntries.isEmpty {
            let items = automationEntries.map { entry in
                AlertsAttentionEntry(
                    attentionID: entry.attentionID, icon: entry.status == "timed_out" ? "clock.badge.exclamationmark.fill" : "xmark.octagon.fill",
                    // The automation's name is the row's name segment and the run's outcome is its title
                    // segment, matching every other alert row's name/title split (`alertsCombinedSegments`).
                    iconTint: .warning, label: entry.automationName, detail: entry.outcome, shortcut: "", countsTowardBadge: true,
                    eventDate: entry.eventDate, automationRunTarget: AutomationRunAlertTarget(deviceID: entry.deviceID, runID: entry.runID))
            }
            groups.append(
                AlertsGroup(
                    projectName: "Automations", workspaceID: "automations:\(deviceID)",
                    workspaceName: deviceName.isEmpty ? "This device" : deviceName, workspaceBranch: nil, isFromHiddenWorkspace: false, items: items,
                    deviceID: deviceID))
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

    /// Alert entries `groups` carries for one runtime-target row, matched by focus-request identity: a
    /// process row's exit alert via `.workspaceProcess`, an agent row's waiting/done alert via
    /// `.agentWindow`, and a bell alert via `.terminalSession` for any row carrying a live session (a
    /// process or agent row's own session, or an ad hoc terminal's). This is the single derivation for
    /// "which alerts does this row own": the sidebar's Dismiss Alert menu and the exited-process color
    /// downgrade (`isProcessExitAcknowledged`) both consume it instead of re-deriving alert identity —
    /// the `alert:...` id format built in `buildOverviewAlertsGroups` — at a second site.
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

    /// Whether a process's currently derived exit alert — if it has one — is in the dismissed set. This
    /// is the one fact that downgrades a row's color from failed (red) back to inactive everywhere it
    /// renders (sidebar row, workspace roll-up, command palette, workspace-detail Processes row); agent
    /// and bell dismissals never touch color. A later exit carries a new `exitedAt`, hence a new alert
    /// identity, so the process reads as failed again until its new alert is dismissed too.
    nonisolated static func isProcessExitAcknowledged(
        processID: String, workspaceID: String, alertsGroups: [AlertsGroup], dismissedAttentionItemIDs: Set<String>
    ) -> Bool {
        guard let entry = rowAlertsAttentionEntries(in: alertsGroups, workspaceID: workspaceID, processID: processID).first else { return false }
        return dismissedAttentionItemIDs.contains(entry.attentionID)
    }

    var dismissedAlertsAttentionItemIDs: Set<String> = []
    /// The focused session and when it took focus, refreshed on every alerts rebuild (the rebuild funnel
    /// is where this client reads keyboard focus). Bounds which of that session's bells count as rung in
    /// front of the user — see `consumeFocusedSessionBellAlerts`.
    private var focusedBellWatch: FocusedBellWatch?
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
        Self.visibleAlertsGroups(in: host.deviceModel.alertsGroups, dismissedAttentionItemIDs: dismissedAlertsAttentionItemIDs)
    }

    /// The groups the user sees: everything derived from the overviews minus what has been dismissed —
    /// by a click, or by the user having watched the session a bell rang in — and minus everything a
    /// hidden workspace or hidden project owns, which the sidebar does not list either.
    nonisolated static func visibleAlertsGroups(in groups: [AlertsGroup], dismissedAttentionItemIDs: Set<String>) -> [AlertsGroup] {
        groups.compactMap { group -> AlertsGroup? in
            guard !group.isFromHiddenWorkspace else { return nil }
            let items = group.items.filter { !dismissedAttentionItemIDs.contains($0.attentionID) }
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
                isOffline: display?.isOffline ?? false,
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
                ($0.deviceID, AlertsDeviceDisplay(name: $0.displayName, isOffline: $0.loadState.isOffline))
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
                    workspaceName: row.workspaceName, deviceText: row.deviceText, isOffline: row.isOffline))
        }
        return AlertsRenderSignature(showsDeviceColumn: plan.showsDeviceColumn, rows: rows, text: text)
    }

    /// Attention-item dismissals are per-client desktop state, so they live in the client
    /// database rather than the daemon's settings.
    private func loadDismissedAlertsAttentionItemIDs() -> Set<String> {
        guard let raw = (try? database().setting(key: ClientSettingsKey.alertsDismissedAttentionItems)) ?? nil, !raw.isEmpty,
            let data = raw.data(using: .utf8), let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(decoded)
    }

    private func storeDismissedAlertsAttentionItemIDs(_ ids: Set<String>) throws {
        guard !ids.isEmpty else {
            try database().setSetting(key: ClientSettingsKey.alertsDismissedAttentionItems, value: nil)
            return
        }
        let encoded = try JSONEncoder().encode(ids.sorted())
        try database().setSetting(key: ClientSettingsKey.alertsDismissedAttentionItems, value: String(decoding: encoded, as: UTF8.self))
    }

    func loadAlertsDismissedAttentionItemIDs() { dismissedAlertsAttentionItemIDs = loadDismissedAlertsAttentionItemIDs() }

    func pruneDismissedAlertsAttentionItemIDsIfNeeded() {
        // Read through the same injected `database` closure dismissals persist through (never
        // `host.clientDatabase()`), so a test's throwaway database is the one this reads back, same as
        // load/store above. Includes the local device row: `retainedDismissedAttentionItemIDs` does not
        // special-case it, since a local-device attention id with no matching section is exactly as stale
        // as a remote one would be.
        //
        // A failed read is unknown pairing state, not evidence that nothing is paired; pruning against
        // an empty set here would erase every not-yet-loaded device's dismissals. Abort this pass
        // instead: the set is untouched, and the next sidebar refresh prunes again. No modal, unlike the
        // store path below, because pruning is refresh-cadence hygiene, not a user action that failed.
        guard let pairedDevices = try? database().pairedDevices() else { return }
        let pairedDeviceIDs = Set(pairedDevices.map(\.id))
        let prunedIDs = Self.retainedDismissedAttentionItemIDs(
            dismissedAlertsAttentionItemIDs, sections: host.deviceModel.deviceSections, pairedDeviceIDs: pairedDeviceIDs)
        guard prunedIDs != dismissedAlertsAttentionItemIDs else { return }
        dismissedAlertsAttentionItemIDs = prunedIDs
        do { try storeDismissedAlertsAttentionItemIDs(prunedIDs) } catch { host.showError(error) }
    }

    /// Dismissals worth keeping: a dismissal is only meaningful while its alert is still derived, so the
    /// set is trimmed to the identities the current groups carry. A bell consumed because its session was
    /// focused survives this the same way a clicked-away one does — the entry stays derived for as long as
    /// the session reports that `bellAt`. `groups` is deliberately the complete derivation, hidden
    /// workspaces included, so dismissals made before a workspace or its project was hidden are retained
    /// and unhiding it does not resurrect them (iOS keeps them the same way, via
    /// `includingHiddenWorkspaces` in its attention-event derivation).
    nonisolated static func retainedDismissedAttentionItemIDs(_ dismissed: Set<String>, in groups: [AlertsGroup]) -> Set<String> {
        dismissed.intersection(Set(groups.flatMap { $0.items.map(\.attentionID) }))
    }

    /// The device id embedded in every attention id built by `buildOverviewAlertsGroups`
    /// (`alert:<deviceID>:...`), or nil for an id that does not carry one (a stale/legacy identity).
    nonisolated static func deviceID(fromAttentionID attentionID: String) -> String? {
        let components = attentionID.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard components.count >= 2, components[0] == "alert" else { return nil }
        return String(components[1])
    }

    /// Per-device retention, called once per refresh across every paired device's dismissals at once
    /// (the persisted set is a single flat store, not one bucket per device the way iOS's
    /// `SpacesMobileDismissedAlertsStore` is). A dismissal is pruned against its owning device's
    /// derived alerts only once that device has actually reported an overview; a device whose section
    /// has not loaded yet, or that has no section at all yet, contributes no evidence either way, so
    /// its dismissals are left untouched rather than read as "no longer derived" (mirroring the iOS
    /// store, whose bucket for a device is pruned only when that device's own overview refreshes, never
    /// by another device's).
    ///
    /// "No section at all" is not a corner case: on a cold launch the local snapshot installs its
    /// section and triggers this prune (`SidebarController.applyLocalDeviceSidebarSnapshot`) before
    /// `loadRemoteDeviceSections` has run even once, so every paired remote device is missing from
    /// `sections` at that moment, not merely `.loading`. Treating "missing" the same as "not yet loaded"
    /// there is what `pairedDeviceIDs` is for: a bucket for a device with no section keeps its dismissals
    /// when the device is still paired, and drops them only when it is not (unpaired since the dismissal
    /// was recorded) or the id has no parseable device at all. That keeps the set bounded rather than
    /// growing for the life of the install, without depending on section-array ordering or on every
    /// paired device having already gotten a `.loading` placeholder.
    nonisolated static func retainedDismissedAttentionItemIDs(
        _ dismissed: Set<String>, sections: [DeviceModelStore.DeviceSection], pairedDeviceIDs: Set<String>
    ) -> Set<String> {
        let sectionsByDeviceID = Dictionary(uniqueKeysWithValues: sections.map { ($0.deviceID, $0) })
        let dismissedByDevice = Dictionary(grouping: dismissed, by: { deviceID(fromAttentionID: $0) })
        var retained: Set<String> = []
        for (deviceID, bucket) in dismissedByDevice {
            guard let deviceID else { continue }
            if let section = sectionsByDeviceID[deviceID] {
                if section.overview != nil {
                    retained.formUnion(retainedDismissedAttentionItemIDs(Set(bucket), in: section.alertsGroups))
                } else {
                    retained.formUnion(bucket)
                }
            } else if pairedDeviceIDs.contains(deviceID) {
                retained.formUnion(bucket)
            }
        }
        return retained
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
        let consumed = Self.bellAttentionIDs(in: host.deviceModel.alertsGroups, watch: focusedBellWatch).subtracting(dismissedAlertsAttentionItemIDs)
        guard !consumed.isEmpty else { return }
        dismissedAlertsAttentionItemIDs.formUnion(consumed)
        do { try storeDismissedAlertsAttentionItemIDs(dismissedAlertsAttentionItemIDs) } catch { host.showError(error) }
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
            try storeDismissedAlertsAttentionItemIDs(dismissedAlertsAttentionItemIDs)
            host.updateAlertsSidebarBadge()
            if host.showingAlerts { showAlertsDetail() }
            // A dismissal can flip an exited process's row color (failed → inactive) and always
            // changes which rows still carry an undismissed alert, so the sidebar re-derives through
            // its normal signature-diff reload rather than an unconditional or per-frame rebuild. That
            // apply is also what repaints the cycling row, whose Alerts set this dismissal just shrank.
            host.sidebar.applySidebarDataChange()
            // The palette otherwise only re-derives on its next presentation (`commandPaletteNeedsReload`);
            // while it is already open, reload it now so a dismissal from underneath it (e.g. the sidebar's
            // Dismiss Alert menu) is reflected without waiting for the palette to be reopened.
            if host.commandPalette.commandPalettePanel?.isVisible == true {
                host.commandPalette.reloadCommandPaletteItems()
            } else {
                host.commandPalette.invalidateCommandPaletteCache()
            }
        } catch {
            dismissedAlertsAttentionItemIDs.remove(attentionID)
            host.showError(error)
        }
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

        let statusView = Self.alertsStatusIndicator(processStatus: entry.processStatus, agentStatus: entry.agentStatus, automationID: automationID)

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
    private static func alertsStatusIndicator(processStatus: RunningProcessState?, agentStatus: AgentWindowStatus?, automationID: String?) -> NSView {
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
