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

    /// Names the automation run an alert card deep-links to (its device and run id).
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
        var latestDate: Date? { items.compactMap(\.eventDate).max() }
    }

    // ISO8601DateFormatter construction is expensive and this is shared by the `nonisolated`
    // overview-mapping helper below (buildOverviewAlertsGroups), which runs off the main actor.
    // ISO8601DateFormatter is documented thread-safe, so a single nonisolated instance is safe to
    // reuse instead of allocating a fresh formatter per call. `AppKitController` keeps its own
    // identical instance for its overview-mapping helpers (agentWindows, deviceTerminalWindows)
    // rather than reaching into this one.
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
                        detail: AppKitController.terminalPaletteSecondaryLabel(liveTitle: agent.liveTitle, sessionID: agent.sessionID, sessionsByID: sessionsByID),
                        shortcut: "", processStatus: nil, agentStatus: AgentWindowStatus(rawValue: agent.activityState.rawValue),
                        countsTowardBadge: true, eventDate: eventDate,
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
                        detail: AppKitController.terminalPaletteSecondaryLabel(liveTitle: session.liveTitle, sessionID: session.id, sessionsByID: sessionsByID),
                        shortcut: "", processStatus: nil, agentStatus: nil, countsTowardBadge: true, eventDate: eventDate,
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
                    workspaceBranch: workspace.branch, isFromHiddenWorkspace: !overview.isWorkspaceVisible(workspace), items: items))
        }
        // Failed/timed-out automation runs form their own synthetic group ("Automations / <device>") whose
        // cards deep-link to the Runs tab instead of focusing a live workspace target that may be detached.
        let automationEntries = AutomationsViewModel.alertEntries(deviceID: deviceID, deviceName: deviceName, runs: overview.automationRuns)
        if !automationEntries.isEmpty {
            let items = automationEntries.map { entry in
                AlertsAttentionEntry(
                    attentionID: entry.attentionID, icon: entry.status == "timed_out" ? "clock.badge.exclamationmark.fill" : "xmark.octagon.fill",
                    iconTint: .warning, label: entry.text, detail: nil, shortcut: "", countsTowardBadge: true, eventDate: entry.eventDate,
                    automationRunTarget: AutomationRunAlertTarget(deviceID: entry.deviceID, runID: entry.runID))
            }
            groups.append(
                AlertsGroup(
                    projectName: "Automations", workspaceID: "automations:\(deviceID)",
                    workspaceName: deviceName.isEmpty ? "This device" : deviceName, workspaceBranch: nil, isFromHiddenWorkspace: false, items: items))
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
    /// Maps sequential window shortcut numbers (1-10, shown as 1-0) to focus targets for the current Alerts view.
    private var alertsFocusRequestMap: [Int: WindowFocusRequest] = [:]
    /// The alerts pane as it stands on screen: the signature it was rendered from and its row views keyed
    /// by attention id. Non-nil exactly while those views are the detail pane's content, so a refresh can
    /// be answered without rebuilding them (see `showAlertsDetail`).
    private var renderedAlerts: RenderedAlertsDetail?

    func alertsFocusRequest(for index: Int) -> WindowFocusRequest? { alertsFocusRequestMap[index] }

    private struct RenderedAlertsDetail {
        let signature: AlertsRenderSignature
        let rowsByAttentionID: [String: ClickableRowView]
    }

    /// Forgets what the pane was rendered from, so the next `showAlertsDetail` builds it again. Called
    /// from `presentDetailPane` whenever other content takes over the detail container.
    func invalidateRenderedAlertsDetail() { renderedAlerts = nil }

    // MARK: - Alerts content

    private func buildAlertsGroups() -> [AlertsGroup] {
        Self.visibleAlertsGroups(in: host.alertsGroups, dismissedAttentionItemIDs: dismissedAlertsAttentionItemIDs)
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
                workspaceBranch: group.workspaceBranch, isFromHiddenWorkspace: group.isFromHiddenWorkspace, items: items)
        }
    }

    func alertsAttentionCount() -> Int { buildAlertsGroups().reduce(0) { total, group in total + group.items.filter(\.countsTowardBadge).count } }

    // MARK: - Render plan and signature

    /// The alerts pane's content resolved for drawing: the visible groups, the owning device's offline
    /// state, and the sequential window shortcut each row carries. Built once per refresh so the pane's
    /// signature and the pane itself are derived from the same resolution and cannot drift apart.
    private struct AlertsRenderPlan {
        struct Row {
            let entry: AlertsAttentionEntry
            let shortcut: String
            /// The row's window shortcut number, or nil past the tenth row: those get no badge and no
            /// entry in the focus-request map.
            let shortcutIndex: Int?
        }

        struct Group {
            let projectName: String
            let workspaceName: String
            let offlineDeviceName: String?
            let rows: [Row]
        }

        let groups: [Group]
    }

    /// Everything `showAlertsDetail` renders, split by how a change to it has to be answered.
    ///
    /// `groups` is what decides which views the pane builds: the group headers, the entry identities and
    /// their order, and each row's icon, tint, status indicator, shortcut badge, focus target, offline
    /// dimming, and whether it carries a detail line at all (that one decides the label's font and the
    /// detail field's visibility, so gaining or losing a detail line is a change of shape, not of text).
    /// `text` is the two strings each row displays.
    ///
    /// They are compared separately because a bell alert renders its session's live title as its detail
    /// text, which moves as often as the terminal's title does.
    struct AlertsRenderSignature: Equatable {
        struct Row: Equatable {
            let attentionID: String
            let icon: String
            let iconTint: AppKitController.AlertsIconTint
            let shortcut: String
            let processStatus: RunningProcessState?
            let agentStatus: AgentWindowStatus?
            let focusRequestKey: String?
            let hasDetail: Bool
        }

        struct Group: Equatable {
            let projectName: String
            let workspaceName: String
            let offlineDeviceName: String?
            let rows: [Row]
        }

        struct RowText: Equatable {
            let attentionID: String
            let label: String
            let detail: String
        }

        let groups: [Group]
        /// Flattened in render order, so an equal `groups` guarantees this lines up index for index with
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
        guard rendered.groups == refreshed.groups else { return .structural }
        return rendered.text == refreshed.text ? .unchanged : .textOnly
    }

    private func buildAlertsRenderPlan() -> AlertsRenderPlan {
        // Sequential window shortcut counter across all groups and items.
        var shortcutCounter = 1
        let groups = buildAlertsGroups().map { group -> AlertsRenderPlan.Group in
            // An unreachable device keeps its alerts listed and attributed to the workspace that raised
            // them, marked stale by the same dimming its sidebar rows carry: they report what the device
            // last said, and nothing can be done about them until it answers again.
            let offlineDeviceName = unreachableDeviceName(workspaceID: group.workspaceID)
            let rows = group.items.map { entry -> AlertsRenderPlan.Row in
                let shortcutIndex = shortcutCounter <= 10 ? shortcutCounter : nil
                shortcutCounter += 1
                return AlertsRenderPlan.Row(
                    entry: entry, shortcut: shortcutIndex.map { host.windowShortcutBadgeText(index: $0) } ?? "", shortcutIndex: shortcutIndex)
            }
            return AlertsRenderPlan.Group(
                projectName: group.projectName, workspaceName: group.workspaceName, offlineDeviceName: offlineDeviceName, rows: rows)
        }
        return AlertsRenderPlan(groups: groups)
    }

    private static func alertsRenderSignature(plan: AlertsRenderPlan) -> AlertsRenderSignature {
        var text: [AlertsRenderSignature.RowText] = []
        var groups: [AlertsRenderSignature.Group] = []
        for group in plan.groups {
            var rows: [AlertsRenderSignature.Row] = []
            for row in group.rows {
                text.append(AlertsRenderSignature.RowText(attentionID: row.entry.attentionID, label: row.entry.label, detail: row.entry.detail ?? ""))
                rows.append(
                    AlertsRenderSignature.Row(
                        attentionID: row.entry.attentionID, icon: row.entry.icon, iconTint: row.entry.iconTint, shortcut: row.shortcut,
                        processStatus: row.entry.processStatus, agentStatus: row.entry.agentStatus,
                        focusRequestKey: row.entry.focusRequest?.signatureKey, hasDetail: row.entry.detail != nil))
            }
            groups.append(
                AlertsRenderSignature.Group(
                    projectName: group.projectName, workspaceName: group.workspaceName, offlineDeviceName: group.offlineDeviceName, rows: rows))
        }
        return AlertsRenderSignature(groups: groups, text: text)
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
        let prunedIDs = Self.retainedDismissedAttentionItemIDs(dismissedAlertsAttentionItemIDs, in: host.alertsGroups)
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
            // its normal signature-diff reload rather than an unconditional or per-frame rebuild.
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
                // Only the rows whose strings moved are touched; an equal `groups` means the two text
                // lists line up index for index. `alertsFocusRequestMap` is rebuilt by the render below,
                // so skipping the render keeps the map the previous one left, which is still correct: an
                // equal `groups` means the same entries in the same order with the same focus targets.
                for (previous, current) in zip(rendered.signature.text, signature.text) where previous != current {
                    rendered.rowsByAttentionID[current.attentionID]?.updateText(label: current.label, detail: current.detail)
                }
                renderedAlerts = RenderedAlertsDetail(signature: signature, rowsByAttentionID: rendered.rowsByAttentionID)
                return
            case .structural: break
            }
        }

        alertsFocusRequestMap = [:]
        host.clearWorkspaceDetailFooter()
        for view in host.detailContainer.subviews { view.removeFromSuperview() }
        host.detailContainer.wantsLayer = true
        bindAppearanceReactiveLayer(host.detailContainer) { [unowned host] view in
            view.layer?.backgroundColor = host.sidebar.sidebarPanelBackgroundColor().cgColor
        }

        var rowsByAttentionID: [String: ClickableRowView] = [:]
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Header
        let accentColor = host.sidebar.sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
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

        if plan.groups.isEmpty {
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
        } else {
            for group in plan.groups {
                let offlineDeviceName = group.offlineDeviceName

                // Workspace group header
                let groupHeaderStack = NSStackView()
                groupHeaderStack.orientation = .horizontal
                groupHeaderStack.alignment = .centerY
                groupHeaderStack.spacing = 4
                groupHeaderStack.translatesAutoresizingMaskIntoConstraints = false

                let projectLabel = NSTextField(labelWithString: group.projectName)
                projectLabel.font = Typography.compactTitle
                projectLabel.textColor = .secondaryLabelColor
                projectLabel.setContentHuggingPriority(.required, for: .horizontal)

                let slashLabel = NSTextField(labelWithString: "/")
                slashLabel.font = Typography.rowDetail
                slashLabel.textColor = .tertiaryLabelColor
                slashLabel.setContentHuggingPriority(.required, for: .horizontal)

                let workspaceLabel = NSTextField(labelWithString: group.workspaceName)
                workspaceLabel.font = Typography.compactTitle
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
                constrainFormFieldToFillWidth(groupHeaderStack, in: stack)

                let itemsStack = NSStackView()
                itemsStack.orientation = .vertical
                itemsStack.spacing = 4
                itemsStack.translatesAutoresizingMaskIntoConstraints = false

                for planRow in group.rows {
                    let entry = planRow.entry
                    if let shortcutIndex = planRow.shortcutIndex, let focusRequest = entry.focusRequest {
                        alertsFocusRequestMap[shortcutIndex] = focusRequest
                    }
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
                    let card = alertsWindowCard(entry: entry, shortcut: planRow.shortcut, action: cardAction)
                    if let offlineDeviceName {
                        card.container.alphaValue = AppKitController.unreachableDeviceAlpha
                        card.container.toolTip = "\(offlineDeviceName) is offline"
                    }
                    rowsByAttentionID[entry.attentionID] = card.row
                    itemsStack.addArrangedSubview(card.container)
                    constrainFormFieldToFillWidth(card.container, in: itemsStack)
                }

                stack.addArrangedSubview(itemsStack)
                constrainFormFieldToFillWidth(itemsStack, in: stack)
            }
        }

        showScrollableDetailStack(stack, in: host.detailContainer)
        renderedAlerts = RenderedAlertsDetail(signature: signature, rowsByAttentionID: rowsByAttentionID)
    }

    /// The display name of the device that raised this workspace's alerts when that device is
    /// unreachable, and nil while it is loaded — the alerts pane's only piece of device context, shown
    /// because a stale alert is otherwise indistinguishable from a live one.
    private func unreachableDeviceName(workspaceID: String) -> String? {
        guard let deviceID = host.deviceID(forWorkspaceID: workspaceID), let section = host.deviceSection(id: deviceID), section.loadState.isOffline
        else { return nil }
        return section.displayName
    }

    /// Builds an alerts card with focus and dismiss affordances while preserving the workspace Run tab
    /// rows. The card's row is returned alongside its container so a later text-only refresh can write
    /// into it (see `showAlertsDetail`).
    private func alertsWindowCard(entry: AlertsAttentionEntry, shortcut: String, action: (() async -> Void)? = nil) -> (
        container: NSView, row: ClickableRowView
    ) {
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
        constrainFormFieldToFillWidth(mainRow, in: container)

        return (container: container, row: mainRow)
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
