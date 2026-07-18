import SwiftUI
import spacesdevicecore

/// Alerts tab: attention events grouped by workspace, newest context first.
struct AlertsTabView: View {
    @Bindable var model: SpacesMobileAppModel
    @State private var selectedSession: SelectedTerminalSessionRoute?
    @State private var pendingTerminalLaunch: PendingTerminalLaunch?

    var body: some View {
        NavigationStack {
            content.background(Theme.bg.ignoresSafeArea()).navigationTitle("Alerts").tint(Theme.accent).toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { model.clearAlerts() }.font(.system(size: 13, weight: .semibold)).disabled(model.undismissedAlertCount == 0)
                        .accessibilityIdentifier("alerts.clear")
                }
            }.terminalSessionNavigation(model: model, selectedSession: $selectedSession, pendingTerminalLaunch: $pendingTerminalLaunch)
        }.accessibilityIdentifier("tab.alerts").overviewPolling(model: model, tab: .alerts, activeDetailRouteID: selectedSession?.id)
    }

    @ViewBuilder private var content: some View {
        if model.attentionGroups.isEmpty && model.automationAlerts.isEmpty {
            ContentUnavailableView {
                Label("No Alerts", systemImage: "bell")
            } description: {
                Text("Agents waiting for input and exited runs show up here.")
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.attentionGroups) { group in alertGroupSection(group).padding(.bottom, 14) }
                    if !model.automationAlerts.isEmpty { automationAlertsSection(model.automationAlerts).padding(.bottom, 14) }
                }.padding(.vertical, 12)
            }.scrollContentBackground(.hidden)
        }
    }

    /// Failed/timed-out automation runs are workspace-less, so they get their own band rather than
    /// joining a per-workspace section — mirrors the Mac's synthetic "Automations" alerts group.
    private func automationAlertsSection(_ entries: [SpacesMobileAutomationAlertEntry]) -> some View {
        VStack(spacing: 0) {
            HeaderBand {
                Text("Automations").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(entries.count)").font(.system(size: 12)).foregroundStyle(Theme.mutedSecondary).monospacedDigit()
            }.accessibilityIdentifier("alerts.band.automations")
            VStack(spacing: 0) { ForEach(entries) { entry in automationAlertRow(entry) } }.padding(.top, 4)
        }
    }

    /// Status-level only: there is no terminal/replay to open for an automation run in this feature, so
    /// unlike `eventRow` this row is never a button.
    private func automationAlertRow(_ entry: SpacesMobileAutomationAlertEntry) -> some View {
        BandRow(
            dotKind: .exited, tile: TypeIconTile(systemName: "clock.arrow.circlepath", background: Theme.orange.opacity(0.16), foreground: Theme.orange),
            title: entry.automationName, detail: entry.outcome, detailIsMonospaced: false
        ) { EmptyView() }.accessibilityIdentifier("alert.automation.\(entry.id)")
    }

    private func alertGroupSection(_ group: SpacesMobileAttentionGroup) -> some View {
        VStack(spacing: 0) {
            HeaderBand {
                WorkspaceBandLabel(isGitWorkspace: group.isGitWorkspace, displayName: group.workspaceDisplayName)
                Spacer(minLength: 0)
                Text(group.projectName.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.mutedSecondary).tracking(0.4)
                    .lineLimit(1)
            }.accessibilityIdentifier("alerts.band.\(group.workspaceID)")
            VStack(spacing: 0) { ForEach(group.events) { event in eventRow(event) } }.padding(.top, 4)
        }
    }

    @ViewBuilder private func eventRow(_ event: SpacesMobileAttentionEvent) -> some View {
        let row = BandRow(
            dotKind: StatusDot.Kind(attentionKind: event.kind), tile: .tile(for: event.rowType), title: event.title, detail: event.kind.label,
            detailIsMonospaced: false
        ) {
            Text(SpacesMobileAttention.abbreviatedAge(of: event.date)).font(.system(size: 11)).foregroundStyle(Theme.mutedSecondary).monospacedDigit()
        }
        if let session = event.sessionID.flatMap({ model.session(forSessionID: $0) }) {
            Button {
                selectedSession = SelectedTerminalSessionRoute(session: session)
            } label: {
                row
            }.buttonStyle(.plain).disabled(model.isMutating).accessibilityIdentifier("alert.row.\(event.id)")
        } else {
            row.accessibilityIdentifier("alert.row.\(event.id)")
        }
    }
}
