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
        if model.attentionGroups.isEmpty {
            ContentUnavailableView {
                Label("No Alerts", systemImage: "bell")
            } description: {
                Text("Agents waiting for input and exited runs show up here.")
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) { ForEach(model.attentionGroups) { group in alertGroupSection(group).padding(.bottom, 14) } }.padding(
                    .vertical, 12)
            }.scrollContentBackground(.hidden)
        }
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
