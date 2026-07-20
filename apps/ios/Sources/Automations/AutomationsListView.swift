import SwiftUI
import spacesdevicecore
import spacesterminalcore

/// Root content of the Automations tab (see `AutomationsTabView` for the tab shell). Automations are a
/// headline feature, so they get their own bottom tab rather than living under Settings or joining the
/// workspace-scoped Alerts/Spaces/Agents tabs — an automation is device-scoped, not tied to any one
/// workspace. iOS view scope is deliberately narrow: view automations and runs, trigger a run, and
/// cancel a running run — no create/edit/delete, which stay Mac-only.
///
/// Tapping a row runs it now, mirroring the Agents/Spaces tabs' "tap performs the primary action"
/// convention (there is no session to open for an automation, so a tap always runs). Viewing an
/// automation's run history is a secondary action, reached through the row's context menu.
struct AutomationsListView: View {
    @Bindable var model: SpacesMobileAppModel
    @State private var selectedAutomationID: String?
    @State private var isShowingRecentRuns = false

    private var rows: [SpacesMobileAutomationRow] { model.automationRows }

    var body: some View {
        content.navigationTitle("Automations").tint(Theme.accent).toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Recent Runs") { isShowingRecentRuns = true }.font(.system(size: 13, weight: .semibold)).disabled(
                    (model.overview?.automationRuns.isEmpty ?? true)
                ).accessibilityIdentifier("automations.recentRuns")
            }
        }.navigationDestination(item: $selectedAutomationID) { automationID in
            AutomationRunsView(model: model, automationID: automationID, title: automationName(for: automationID))
        }.navigationDestination(isPresented: $isShowingRecentRuns) { AutomationRunsView(model: model, automationID: nil, title: "Recent Runs") }
            .overviewPolling(model: model, tab: .automations, activeDetailRouteID: activeDetailRouteID)
    }

    private var activeDetailRouteID: String? { selectedAutomationID ?? (isShowingRecentRuns ? "recent-runs" : nil) }

    private func automationName(for automationID: String) -> String {
        rows.first(where: { $0.automation.id == automationID })?.automation.name ?? "Automation"
    }

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
        var detailParts = [SpacesMobileAutomations.triggerSummary(automation), SpacesMobileAutomations.nextFireDescription(automation)]
        if let workspaceName = SpacesMobileAutomations.workspaceName(for: automation, in: model.overview?.workspaces ?? []) {
            detailParts.append(workspaceName)
        }
        let detail = detailParts.compactMap { $0 }.joined(separator: " · ")
        let excerpt = SpacesMobileAutomations.excerpt(automation)

        return Button {
            Task { await model.triggerAutomation(id: automation.id) }
        } label: {
            BandRow(
                dotKind: StatusDot.Kind(automationRunStatus: row.lastRunStatus), tile: TypeIconTile(systemName: "clock.arrow.circlepath"),
                title: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(automation.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                        if !excerpt.isEmpty {
                            Text(excerpt).font(.system(size: 11)).foregroundStyle(Theme.mutedSecondary).lineLimit(1)
                        }
                    }
                }, detail: detail, detailIsMonospaced: false
            ) {
                if !automation.enabled {
                    Image(systemName: "bolt.slash").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.mutedSecondary)
                        .accessibilityLabel("Disabled")
                }
                RowPlayIndicator()
            }
        }.buttonStyle(.plain).disabled(model.isMutating).accessibilityIdentifier("automations.row.\(row.id)").contextMenu {
            Button {
                selectedAutomationID = automation.id
            } label: {
                Label("View Runs", systemImage: "list.bullet.rectangle")
            }
        }
    }
}

/// Runs list for one automation (pushed from a row's context menu) or every automation ("Recent Runs",
/// from the toolbar) — newest first, with a Cancel action on running rows and an End Agents action on
/// finished runs that still have a live attributed coding agent. Read-only beyond that: no terminal or
/// replay viewing on iOS, matching the view/trigger/cancel scope of this feature — attributed agents are
/// display-only, not tappable.
struct AutomationRunsView: View {
    @Bindable var model: SpacesMobileAppModel
    let automationID: String?
    let title: String
    @State private var pendingCancelRunID: String?
    @State private var pendingEndAgentsRunID: String?
    /// Retained per-automation run history fetched directly from the daemon (nil until first fetched). Only
    /// used for the per-automation screen (`automationID != nil`); the global "Recent Runs" screen stays
    /// overview-derived because it genuinely is the recent-runs window.
    @State private var fetchedRuns: [TerminalServiceAutomationRunSummary]?

    private var rows: [SpacesMobileAutomationRunRow] {
        if let automationID, let fetchedRuns { return SpacesMobileAutomations.runRows(fetchedRuns, automationID: automationID) }
        return SpacesMobileAutomations.runRows(model.overview?.automationRuns ?? [], automationID: automationID)
    }

    var body: some View {
        content.navigationTitle(title).tint(Theme.accent).overviewPolling(model: model, tab: .automations, activeDetailRouteID: nil)
            .task { await loadRuns() }
            .confirmationDialog("Cancel this run?", isPresented: cancelDialogBinding, titleVisibility: .visible) {
                Button("Cancel Run", role: .destructive) {
                    guard let pendingCancelRunID else { return }
                    Task { await model.cancelAutomationRun(runID: pendingCancelRunID); await loadRuns() }
                }
                Button("Keep Running", role: .cancel) {}
            }.confirmationDialog("End this run's agents?", isPresented: endAgentsDialogBinding, titleVisibility: .visible) {
                Button("End Agents", role: .destructive) {
                    guard let pendingEndAgentsRunID else { return }
                    Task { await model.endAutomationAgents(runID: pendingEndAgentsRunID); await loadRuns() }
                }
                Button("Keep Agents Running", role: .cancel) {}
            }
    }

    /// Fetches the per-automation run history through the daemon's retained-runs endpoint. A no-op for the
    /// global "Recent Runs" screen, which stays overview-derived.
    private func loadRuns() async {
        guard let automationID else { return }
        if let runs = await model.fetchAutomationRuns(automationID: automationID) { fetchedRuns = runs }
    }

    private var cancelDialogBinding: Binding<Bool> { Binding(get: { pendingCancelRunID != nil }, set: { if !$0 { pendingCancelRunID = nil } }) }

    private var endAgentsDialogBinding: Binding<Bool> {
        Binding(get: { pendingEndAgentsRunID != nil }, set: { if !$0 { pendingEndAgentsRunID = nil } })
    }

    @ViewBuilder private var content: some View {
        if rows.isEmpty {
            ContentUnavailableView {
                Label("No Runs", systemImage: "list.bullet.rectangle")
            } description: {
                Text("Runs appear here once an automation fires.")
            }.background(Theme.bg.ignoresSafeArea())
        } else {
            ScrollView { LazyVStack(spacing: 0) { ForEach(rows) { row in runRow(row) } }.padding(.vertical, 12) }.scrollContentBackground(.hidden)
                .background(Theme.bg.ignoresSafeArea()).refreshable { await model.refresh(); await loadRuns() }
        }
    }

    private func runRow(_ row: SpacesMobileAutomationRunRow) -> some View {
        let run = row.run
        var detailParts = [SpacesMobileAutomations.runTriggerLabel(run)]
        if let started = SpacesMobileAutomations.startedDescription(run) { detailParts.append(started) }
        if let duration = SpacesMobileAutomations.durationDescription(run) { detailParts.append(duration) }
        if let exitCode = run.exitCode { detailParts.append("exit \(exitCode)") }
        if run.status == "skipped", let reason = run.skipReason { detailParts.append("skipped: \(SpacesMobileAutomations.skipReasonLabel(reason))") }

        return VStack(alignment: .leading, spacing: 0) {
            BandRow(
                dotKind: StatusDot.Kind(automationRunStatus: run.status), tile: TypeIconTile(systemName: "clock.arrow.circlepath"),
                title: run.automationName ?? "Automation", detail: detailParts.joined(separator: " · "), detailIsMonospaced: false
            ) {
                if row.isRunning {
                    Button {
                        pendingCancelRunID = run.id
                    } label: {
                        Image(systemName: "stop.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.red)
                    }.buttonStyle(.plain).disabled(model.isMutating).accessibilityIdentifier("automations.run.cancel.\(run.id)")
                } else if SpacesMobileAutomations.endAgentsAvailable(run) {
                    // A text label, not an icon: ending someone's agent is not an obvious action (see
                    // AGENTS.md GUI rules), matching the Mac's own "End agents" button.
                    Button {
                        pendingEndAgentsRunID = run.id
                    } label: {
                        Text("End agents").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.red)
                    }.buttonStyle(.plain).disabled(model.isMutating).accessibilityIdentifier("automations.run.endAgents.\(run.id)")
                }
            }
            if !run.attributedAgents.isEmpty { attributedAgentsRow(run.attributedAgents) }
        }.accessibilityIdentifier("automations.run.\(row.id)")
    }

    /// The run's attributed coding agents (its own spawned agent, plus any a script's command spawned),
    /// each as a compact dot-plus-title element — display-only, no tap-to-open, since iOS shows no
    /// terminal. Indented to align under the row's title column and independently horizontally
    /// scrollable so several agents never wrap or clip the row.
    private func attributedAgentsRow(_ agents: [TerminalServiceAutomationAgentSummary]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) { ForEach(agents, id: \.terminalSessionID) { agent in attributedAgentChip(agent) } }
        }.padding(.leading, 58).padding(.trailing, 20).padding(.bottom, 8)
    }

    private func attributedAgentChip(_ agent: TerminalServiceAutomationAgentSummary) -> some View {
        HStack(spacing: 5) {
            StatusDot(kind: StatusDot.Kind(agentStatus: agent.status, live: agent.live))
            Text(agent.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Agent").font(.system(size: 11)).foregroundStyle(Theme.mutedSecondary).lineLimit(1)
        }
    }
}

extension StatusDot.Kind {
    /// Maps an `AutomationRunStatus` raw value (or nil, meaning "never run") to the dot's three-way
    /// signal: `.running` for an in-flight run, `.done` for a clean success, `.exited` for a failure
    /// (failed or timed out — both read as the same "needs attention" red ring), and `.idle` for
    /// everything else (queued, canceled, skipped, or no run yet).
    init(automationRunStatus status: String?) {
        switch status {
        case "running": self = .running
        case "succeeded": self = .done
        case "failed", "timed_out": self = .exited
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
