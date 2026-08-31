import SwiftUI
import spacesdevicecore
import spacesterminalcore

/// Root content of the Automations tab (see `AutomationsTabView` for the tab shell). Automations are a
/// headline feature, so they get their own bottom tab rather than living under Settings or joining the
/// workspace-scoped Alerts/Spaces/Agents tabs — an automation is device-scoped, not tied to any one
/// workspace. iOS view scope is deliberately narrow: view automations and runs, trigger a run, cancel a
/// running run, and open a run's terminal — no create/edit/delete, which stay Mac-only.
///
/// Tapping a row opens that automation's detail screen (`AutomationDetailView`), where its schedule,
/// command, and run history live and "Run Now" is the explicit manual trigger — unlike the Agents/Spaces
/// tabs, an automation tap has somewhere to navigate to, so it opens that rather than firing a side
/// effect blind. The toolbar's Recent Runs stays a flat cross-automation view, reached the same way.
struct AutomationsListView: View {
    @Bindable var model: SpacesMobileAppModel
    @State private var selectedAutomationID: String?
    @State private var isShowingRecentRuns = false
    @State private var selectedSession: SelectedTerminalSessionRoute?
    /// Required by `terminalSessionNavigation`'s shared modifier, which installs both a session route and
    /// a pending-launch route; the Automations tab never launches a session (it only opens one that
    /// already exists), so this stays nil.
    @State private var pendingTerminalLaunch: PendingTerminalLaunch?

    private var rows: [SpacesMobileAutomationRow] { model.automationRows }

    var body: some View {
        content.navigationTitle("Automations").tint(Theme.accent).toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Recent Runs") { isShowingRecentRuns = true }.font(.system(size: 13, weight: .semibold)).disabled(
                    (model.overview?.automationRuns.isEmpty ?? true)
                ).accessibilityIdentifier("automations.recentRuns")
            }
        }.navigationDestination(item: $selectedAutomationID) { automationID in
            AutomationDetailView(model: model, automationID: automationID, selectedSession: $selectedSession)
        }.navigationDestination(isPresented: $isShowingRecentRuns) {
            AutomationRunsView(model: model, title: "Recent Runs", selectedSession: $selectedSession)
        }.overviewPolling(model: model, tab: .automations, activeDetailRouteID: activeDetailRouteID).terminalSessionNavigation(
            model: model, selectedSession: $selectedSession, pendingTerminalLaunch: $pendingTerminalLaunch)
    }

    private var activeDetailRouteID: String? { selectedAutomationID ?? (isShowingRecentRuns ? "recent-runs" : nil) ?? selectedSession?.id }

    @ViewBuilder private var content: some View {
        if rows.isEmpty {
            ContentUnavailableView {
                Label("No Automations", systemImage: "clock.arrow.circlepath")
            } description: {
                Text(
                    "Automations run commands on \(model.activeDeviceName ?? "this device") on a schedule — manually or with cron. Create them in Spaces on your Mac."
                )
            }.background(Theme.bg.ignoresSafeArea())
        } else {
            ScrollView { LazyVStack(spacing: 0) { ForEach(rows) { row in automationRow(row) } }.padding(.vertical, 12) }.scrollContentBackground(
                .hidden
            ).background(Theme.bg.ignoresSafeArea()).refreshable { await model.refresh() }
        }
    }

    private func automationRow(_ row: SpacesMobileAutomationRow) -> some View {
        let automation = row.automation
        var detailParts = [
            SpacesMobileAutomations.triggerSummary(automation),
            // Reads the shared 30-second label clock rather than `Date()`, so this text stays put across
            // the 2-second overview poll instead of jittering (#540) — see
            // `SpacesMobileAppModel.relativeTimeReference`.
            SpacesMobileAutomations.nextFireDescription(automation, relativeTo: model.relativeTimeReference),
        ]
        if let workspaceName = SpacesMobileAutomations.workspaceName(for: automation, in: model.overview?.workspaces ?? []) {
            detailParts.append(workspaceName)
        }
        let detail = detailParts.compactMap { $0 }.joined(separator: " · ")
        let excerpt = SpacesMobileAutomations.excerpt(automation)

        return Button {
            selectedAutomationID = automation.id
        } label: {
            BandRow(
                dotKind: StatusDot.Kind(automationRunStatus: row.lastRunStatus), tile: TypeIconTile(systemName: "clock.arrow.circlepath"),
                title: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(automation.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                        if !excerpt.isEmpty { Text(excerpt).font(.system(size: 11)).foregroundStyle(Theme.mutedSecondary).lineLimit(1) }
                    }
                }, detail: detail, detailIsMonospaced: false
            ) {
                if !automation.enabled {
                    Image(systemName: "bolt.slash").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.mutedSecondary)
                        .accessibilityLabel("Disabled")
                }
                RowChevron()
            }
        }.buttonStyle(.plain).accessibilityIdentifier("automations.row.\(row.id)")
    }
}

/// Runs list across every automation ("Recent Runs", from the toolbar) — newest first, with a Cancel
/// action on running rows and an End Agents action on finished runs that still have a live attributed
/// coding agent. Purely overview-derived: unlike the per-automation detail screen, this is genuinely the
/// live recent-runs window, so there is no retained-history fetch to reconcile. Tapping a navigable run
/// row opens its terminal session (live while running, its read-only ended transcript once finished);
/// tapping an attributed-agent chip opens that agent's own session — see
/// `SpacesMobileAutomations.runSession`/`agentSession`.
struct AutomationRunsView: View {
    @Bindable var model: SpacesMobileAppModel
    let title: String
    @Binding var selectedSession: SelectedTerminalSessionRoute?

    private var rows: [SpacesMobileAutomationRunRow] { SpacesMobileAutomations.runRows(model.overview?.automationRuns ?? [], automationID: nil) }

    var body: some View {
        content.navigationTitle(title).tint(Theme.accent).overviewPolling(model: model, tab: .automations, activeDetailRouteID: selectedSession?.id)
    }

    @ViewBuilder private var content: some View {
        if rows.isEmpty {
            ContentUnavailableView {
                Label("No Runs", systemImage: "list.bullet.rectangle")
            } description: {
                Text("Runs appear here once an automation fires.")
            }.background(Theme.bg.ignoresSafeArea())
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    AutomationRunRowsList(
                        model: model, rows: rows, title: { $0.automationName ?? "Automation" }, onMutated: {},
                        onOpenSession: { selectedSession = SelectedTerminalSessionRoute(session: $0) })
                }.padding(.vertical, 12)
            }.scrollContentBackground(.hidden).background(Theme.bg.ignoresSafeArea()).refreshable { await model.refresh() }
        }
    }
}

extension StatusDot.Kind {
    /// Maps an `AutomationRunStatus` raw value (or nil, meaning "never run") to the dot's three-way
    /// signal: `.running` for an in-flight run, `.succeeded` for a clean success, `.exited` for a failure
    /// (failed or timed out — both read as the same "needs attention" red ring), and `.idle` for
    /// everything else (queued, canceled, skipped, or no run yet).
    init(automationRunStatus status: String?) {
        switch status.flatMap(AutomationRunStatus.init(rawValue:)) {
        case .running: self = .running
        case .succeeded: self = .succeeded
        case .failed, .timedOut: self = .exited
        default: self = .idle
        }
    }

    /// Maps an attributed agent's raw `AgentWindowStatus` to the dot's signal, reusing the exact vocabulary
    /// the Agents tab uses for a workspace coding-agent row (`init(runState:activityState:)` in
    /// `BandPrimitives.swift`): waiting/done/spinning map directly, exited always reads as exited, and idle
    /// — meaning no agent row yet, including the detection-pending phase of a starting run — reads as
    /// running while the terminal session is still live (a bare shell) and idle once it is not.
    init(agentStatus status: String, live: Bool) {
        switch status {
        case "waiting": self = .waiting
        case "done": self = .done
        case "spinning": self = .running
        case "exited": self = .exited
        default: self = live ? .running : .idle
        }
    }
}
