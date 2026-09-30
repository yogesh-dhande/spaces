import SwiftUI
import spacesdevicecore

/// Alerts tab: attention events and automation alerts across every paired device, merged into one flat,
/// newest-first list. No workspace or device bands: each row carries its own project/workspace and
/// (when more than one device is paired, or any paired device is offline) device text; see
/// `SpacesMobileAppModel.alertItems`.
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
        }.accessibilityIdentifier("tab.alerts")
    }

    @ViewBuilder private var content: some View {
        if model.alertItems.isEmpty {
            ContentUnavailableView {
                Label("No Alerts", systemImage: "bell")
            } description: {
                Text("Agents waiting for input and exited runs show up here.")
            }.accessibilityIdentifier("alerts.empty")
        } else {
            List {
                swipeHint
                ForEach(model.alertItems) { item in alertRow(item).bandListRow().swipeActions(edge: .trailing) { dismissButton(item) } }
            }.listStyle(.plain).scrollContentBackground(.hidden)
        }
    }

    /// Swiping is the only way to dismiss a single alert, and nothing on the row advertises it, so the
    /// list opens with a one-line caption styled as a subheading under the navigation title. It rides
    /// along with the alerts, so it disappears with them.
    private var swipeHint: some View {
        Text("Swipe an alert to dismiss it.").font(.system(size: 12)).foregroundStyle(Theme.mutedSecondary).frame(
            maxWidth: .infinity, alignment: .leading
        ).padding(.top, 2).padding(.bottom, 6).padding(.horizontal, 20).bandListRow().accessibilityIdentifier("alerts.swipeHint")
    }

    @ViewBuilder private func alertRow(_ item: SpacesMobileAlertItem) -> some View {
        switch item {
        case .event(let event): eventRow(event)
        case .automation(let entry): automationAlertRow(entry)
        }
    }

    @ViewBuilder private func dismissButton(_ item: SpacesMobileAlertItem) -> some View {
        Button(role: .destructive) {
            switch item {
            case .event(let event): model.dismissAlert(event)
            case .automation(let entry): model.dismissAutomationAlert(entry)
            }
        } label: {
            Label("Dismiss", systemImage: "bell.slash")
            // Same suffix the row itself carries (`alert.row.<event.id>` / `alert.automation.<entry.id>`),
            // not `item.id` (`"event:<id>"`/`"automation:<id>"`): a UI test locates a row, then derives
            // this identifier from it, so the two must agree on which string names the same alert.
        }.accessibilityIdentifier("alert.dismiss.\(dismissIdentifierSuffix(item))")
    }

    private func dismissIdentifierSuffix(_ item: SpacesMobileAlertItem) -> String {
        switch item {
        case .event(let event): event.id
        case .automation(let entry): entry.id
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
            Text(AlertsAgeFormatting.abbreviatedAge(of: event.date, relativeTo: model.relativeTimeReference)).font(.system(size: 11)).foregroundStyle(
                Theme.mutedSecondary
            ).monospacedDigit()
        }.opacity(event.isDeviceOffline ? Theme.offlineRowOpacity : 1)
        if let session = event.sessionID.flatMap({ model.session(forSessionID: $0, deviceID: event.deviceID) }) {
            Button {
                selectedSession = SelectedTerminalSessionRoute(session: session, deviceID: event.deviceID)
            } label: {
                row
            }.buttonStyle(.plain).disabled(model.isMutating).accessibilityIdentifier("alert.row.\(event.id)")
        } else {
            row.accessibilityIdentifier("alert.row.\(event.id)")
        }
    }

    /// Status-level only: automation terminal and replay navigation lives in the Runs screens, so unlike
    /// `eventRow` this alert row is never a button.
    private func automationAlertRow(_ entry: SpacesMobileAutomationAlertEntry) -> some View {
        BandRow(
            dotKind: .exited,
            tile: TypeIconTile(systemName: "clock.arrow.circlepath", background: Theme.orange.opacity(0.16), foreground: Theme.orange),
            title: entry.automationName, detail: entry.detail, detailIsMonospaced: false
        ) {
            if let date = entry.date {
                Text(AlertsAgeFormatting.abbreviatedAge(of: date, relativeTo: model.relativeTimeReference)).font(.system(size: 11)).foregroundStyle(
                    Theme.mutedSecondary
                ).monospacedDigit()
            }
        }.opacity(entry.isDeviceOffline ? Theme.offlineRowOpacity : 1).accessibilityIdentifier("alert.automation.\(entry.id)")
    }
}
