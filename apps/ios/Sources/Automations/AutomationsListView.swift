import SwiftUI
import spacesterminalcore

/// Automations list, pushed from the Settings tab (see `SettingsTabView`). Automations are workspace-
/// less and device-scoped like paired devices, so they live alongside "Paired Devices" rather than
/// under Alerts/Spaces/Agents, which are all workspace-scoped. iOS view scope is deliberately narrow:
/// view automations and runs, trigger a run, and cancel a running run — no create/edit/delete, which
/// stay Mac-only.
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
            .overviewPolling(model: model, tab: .settings, activeDetailRouteID: activeDetailRouteID)
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
                Text("Automations created on \(model.activeDeviceName ?? "this device") show up here.")
            }.background(Theme.bg.ignoresSafeArea())
        } else {
            ScrollView {
                LazyVStack(spacing: 0) { ForEach(rows) { row in automationRow(row) } }.padding(.vertical, 12)
            }.scrollContentBackground(.hidden).background(Theme.bg.ignoresSafeArea()).refreshable { await model.refresh() }
        }
    }

    private func automationRow(_ row: SpacesMobileAutomationRow) -> some View {
        let automation = row.automation
        let detailParts = [SpacesMobileAutomations.triggerSummary(automation), SpacesMobileAutomations.nextFireDescription(automation)]
        let detail = detailParts.compactMap { $0 }.joined(separator: " · ")

        return Button {
            Task { await model.triggerAutomation(id: automation.id) }
        } label: {
            BandRow(
                dotKind: StatusDot.Kind(automationRunStatus: row.lastRunStatus), tile: TypeIconTile(systemName: "clock.arrow.circlepath"),
                title: automation.name, detail: detail, detailIsMonospaced: false
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
/// from the toolbar) — newest first, with a Cancel action on running rows. Read-only beyond that: no
/// terminal or replay viewing on iOS, matching the view/trigger/cancel scope of this feature.
struct AutomationRunsView: View {
    @Bindable var model: SpacesMobileAppModel
    let automationID: String?
    let title: String
    @State private var pendingCancelRunID: String?

    private var rows: [SpacesMobileAutomationRunRow] { SpacesMobileAutomations.runRows(model.overview?.automationRuns ?? [], automationID: automationID) }

    var body: some View {
        content.navigationTitle(title).tint(Theme.accent).overviewPolling(model: model, tab: .settings, activeDetailRouteID: nil)
            .confirmationDialog("Cancel this run?", isPresented: cancelDialogBinding, titleVisibility: .visible) {
                Button("Cancel Run", role: .destructive) {
                    guard let pendingCancelRunID else { return }
                    Task { await model.cancelAutomationRun(runID: pendingCancelRunID) }
                }
                Button("Keep Running", role: .cancel) {}
            }
    }

    private var cancelDialogBinding: Binding<Bool> { Binding(get: { pendingCancelRunID != nil }, set: { if !$0 { pendingCancelRunID = nil } }) }

    @ViewBuilder private var content: some View {
        if rows.isEmpty {
            ContentUnavailableView {
                Label("No Runs", systemImage: "list.bullet.rectangle")
            } description: {
                Text("Runs appear here once an automation fires.")
            }.background(Theme.bg.ignoresSafeArea())
        } else {
            ScrollView {
                LazyVStack(spacing: 0) { ForEach(rows) { row in runRow(row) } }.padding(.vertical, 12)
            }.scrollContentBackground(.hidden).background(Theme.bg.ignoresSafeArea()).refreshable { await model.refresh() }
        }
    }

    private func runRow(_ row: SpacesMobileAutomationRunRow) -> some View {
        let run = row.run
        var detailParts = [SpacesMobileAutomations.runTriggerLabel(run)]
        if let started = SpacesMobileAutomations.startedDescription(run) { detailParts.append(started) }
        if let duration = SpacesMobileAutomations.durationDescription(run) { detailParts.append(duration) }
        if let exitCode = run.exitCode { detailParts.append("exit \(exitCode)") }
        if run.status == "skipped", let reason = run.skipReason { detailParts.append("skipped: \(SpacesMobileAutomations.skipReasonLabel(reason))") }

        return BandRow(
            dotKind: StatusDot.Kind(automationRunStatus: run.status), tile: TypeIconTile(systemName: "clock.arrow.circlepath"),
            title: run.automationName ?? "Automation", detail: detailParts.joined(separator: " · "), detailIsMonospaced: false
        ) {
            if row.isRunning {
                Button {
                    pendingCancelRunID = run.id
                } label: {
                    Image(systemName: "stop.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.red)
                }.buttonStyle(.plain).disabled(model.isMutating).accessibilityIdentifier("automations.run.cancel.\(run.id)")
            }
        }.accessibilityIdentifier("automations.run.\(row.id)")
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
}
