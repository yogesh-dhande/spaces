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
            List {
                swipeHint
                ForEach(model.attentionGroups) { group in alertGroupSection(group) }
                if !model.automationAlerts.isEmpty { automationAlertsSection(model.automationAlerts) }
            }.listStyle(.plain).scrollContentBackground(.hidden)
        }
    }

    /// Failed/timed-out automation runs get their own band rather than joining coding-agent attention
    /// grouped by workspace — mirrors the Mac's synthetic "Automations" alerts group.
    @ViewBuilder private func automationAlertsSection(_ entries: [SpacesMobileAutomationAlertEntry]) -> some View {
        HeaderBand {
            Text("Automations").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 0)
            Text("\(entries.count)").font(.system(size: 12)).foregroundStyle(Theme.mutedSecondary).monospacedDigit()
        }.accessibilityIdentifier("alerts.band.automations").bandListHeaderRow()
        ForEach(entries) { entry in
            automationAlertRow(entry).bandListRow().swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    model.dismissAutomationAlert(entry)
                } label: {
                    Label("Dismiss", systemImage: "bell.slash")
                }.accessibilityIdentifier("alert.dismiss.\(entry.id)")
            }
        }
    }

    /// Status-level only: automation terminal and replay navigation lives in the Runs screens, so unlike
    /// `eventRow` this alert row is never a button.
    private func automationAlertRow(_ entry: SpacesMobileAutomationAlertEntry) -> some View {
        BandRow(
            dotKind: .exited,
            tile: TypeIconTile(systemName: "clock.arrow.circlepath", background: Theme.orange.opacity(0.16), foreground: Theme.orange),
            title: entry.automationName, detail: entry.outcome, detailIsMonospaced: false
        ) { EmptyView() }.accessibilityIdentifier("alert.automation.\(entry.id)")
    }

    /// Swiping is the only way to dismiss a single alert, and nothing on the row advertises it, so the
    /// list opens with a one-line caption styled as a subheading under the navigation title. It rides
    /// along with the alerts, so it disappears with them.
    private var swipeHint: some View {
        Text("Swipe an alert to dismiss it.").font(.system(size: 12)).foregroundStyle(Theme.mutedSecondary).frame(
            maxWidth: .infinity, alignment: .leading
        ).padding(.top, 2).padding(.bottom, 6).padding(.horizontal, 20).bandListRow().accessibilityIdentifier("alerts.swipeHint")
    }

    @ViewBuilder private func alertGroupSection(_ group: SpacesMobileAttentionGroup) -> some View {
        HeaderBand {
            WorkspaceBandLabel(isGitWorkspace: group.isGitWorkspace, displayName: group.workspaceDisplayName)
            Spacer(minLength: 0)
            Text(group.projectName.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.mutedSecondary).tracking(0.4)
                .lineLimit(1)
        }.accessibilityIdentifier("alerts.band.\(group.workspaceID)").bandListHeaderRow()
        ForEach(group.events) { event in
            eventRow(event).bandListRow().swipeActions(edge: .trailing) {
                Button(role: .destructive) {
                    model.dismissAlert(event)
                } label: {
                    Label("Dismiss", systemImage: "bell.slash")
                }.accessibilityIdentifier("alert.dismiss.\(event.id)")
            }
        }
    }

    @ViewBuilder private func eventRow(_ event: SpacesMobileAttentionEvent) -> some View {
        let row = BandRow(
            dotKind: StatusDot.Kind(attentionKind: event.kind), tile: .tile(for: event.rowType), title: event.title, detail: event.detail,
            detailIsMonospaced: false
        ) {
            // Reads the shared 30-second label clock rather than `Date()` so this age keeps advancing on
            // its own cadence even when the overview payload itself is unchanged (#540) — see
            // `SpacesMobileAppModel.relativeTimeReference`. `abbreviatedAge` already floors anything under
            // 60 seconds to "now", so a reference trailing `event.date` cannot render a negative age.
            Text(SpacesMobileAttention.abbreviatedAge(of: event.date, relativeTo: model.relativeTimeReference)).font(.system(size: 11))
                .foregroundStyle(Theme.mutedSecondary).monospacedDigit()
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
