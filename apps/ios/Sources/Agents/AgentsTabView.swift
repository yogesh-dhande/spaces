import SwiftUI
import spacesdevicecore

/// Agents tab: every coding-agent row across every paired device's workspaces, grouped by activity. A
/// device with no cached overview yet (not streamed since launch, or unpaired) contributes no rows; an
/// offline device (streamed once, then dropped) keeps its last-known rows, dimmed.
struct AgentsTabView: View {
    @Bindable var model: SpacesMobileAppModel
    @State private var selectedSession: SelectedTerminalSessionRoute?

    var body: some View {
        NavigationStack {
            // An agent row is a live session the user already started, so this tab opens sessions and
            // never launches one: the shared navigation's pending-launch route stays permanently empty.
            content.background(Theme.bg.ignoresSafeArea()).navigationTitle("Agents").tint(Theme.accent).terminalSessionNavigation(
                model: model, selectedSession: $selectedSession, pendingTerminalLaunch: .constant(nil))
        }.accessibilityIdentifier("tab.agents")
    }

    @ViewBuilder private var content: some View {
        if model.agentGroups.isEmpty {
            ContentUnavailableView {
                Label("No Active Agents", systemImage: "cpu")
            } description: {
                Text("Blocked, finished, and working coding agents show up here. Start one by running its command in a workspace terminal.")
            }
        } else {
            List { ForEach(model.agentGroups) { group in agentGroupSection(group) } }.listStyle(.plain).scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private func agentGroupSection(_ group: SpacesMobileAgentGroup) -> some View {
        HeaderBand {
            Text(group.kind.label).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 0)
            Text("\(group.entries.count)").font(.system(size: 12)).foregroundStyle(Theme.mutedSecondary).monospacedDigit()
        }.accessibilityIdentifier("agents.band.\(group.kind.rawValue)").bandListHeaderRow()
        ForEach(group.entries) { entry in agentRow(entry).bandListRow() }
    }

    @ViewBuilder private func agentRow(_ entry: SpacesMobileAgentEntry) -> some View {
        let row = entry.runtimeRow
        // Agent dots never read dismissal (see `statusDotKind(exitAcknowledged:)`), so this row's own
        // acknowledgment state is inert; passing `false` says so rather than reaching into the model for
        // an answer this row family never uses.
        let button = Button {
            activateAgentRow(entry)
        } label: {
            BandRow(dotKind: row.statusDotKind(exitAcknowledged: false), tile: .tile(for: .codingAgents), title: entry.row.name, detail: entry.detail)
            {
                if row.brief != nil { RowBriefGlyph() }
                if row.sessionID != nil { RowChevron() }
            }
        }.buttonStyle(.plain).disabled(model.isMutating || row.sessionID == nil).opacity(entry.isDeviceOffline ? Theme.offlineRowOpacity : 1)
            .accessibilityIdentifier("agents.row.\(entry.id)")
        if model.hasDismissableAlerts(for: row, deviceID: entry.deviceID) || model.comeBackLaterTarget(for: row) != nil {
            button.contextMenu {
                if model.comeBackLaterTarget(for: row) != nil { ComeBackLaterMenuButton(model: model, row: row, deviceID: entry.deviceID) }
                if model.hasDismissableAlerts(for: row, deviceID: entry.deviceID) {
                    DismissAlertMenuButton(model: model, row: row, deviceID: entry.deviceID)
                }
            }
        } else {
            button
        }
    }

    private func activateAgentRow(_ entry: SpacesMobileAgentEntry) {
        let row = entry.runtimeRow
        guard let session = model.terminalSession(for: row, in: model.overview(forDeviceID: entry.deviceID)) else { return }
        selectedSession = SelectedTerminalSessionRoute(session: session, deviceID: entry.deviceID)
    }
}
