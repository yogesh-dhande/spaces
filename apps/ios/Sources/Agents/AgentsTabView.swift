import SwiftUI
import spacesdevicecore

/// Agents tab: every coding-agent row across workspaces, grouped by activity.
struct AgentsTabView: View {
    @Bindable var model: SpacesMobileAppModel
    @State private var selectedSession: SelectedTerminalSessionRoute?

    var body: some View {
        NavigationStack {
            // An agent row is a live session the user already started, so this tab opens sessions and
            // never launches one: the shared navigation's pending-launch route stays permanently empty.
            content.background(Theme.bg.ignoresSafeArea()).navigationTitle("Agents").tint(Theme.accent).terminalSessionNavigation(
                model: model, selectedSession: $selectedSession, pendingTerminalLaunch: .constant(nil))
        }.accessibilityIdentifier("tab.agents").overviewPolling(model: model, tab: .agents, activeDetailRouteID: activeDetailRouteID)
    }

    private var activeDetailRouteID: String? { selectedSession?.id }

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
            activateAgentRow(row)
        } label: {
            BandRow(dotKind: row.statusDotKind(exitAcknowledged: false), tile: .tile(for: .codingAgents), title: entry.row.name, detail: entry.detail)
            {
                if row.sessionID != nil { RowChevron() }
            }
        }.buttonStyle(.plain).disabled(model.isMutating || row.sessionID == nil).accessibilityIdentifier("agents.row.\(entry.id)")
        if model.hasUndismissedAlerts(for: row) {
            button.contextMenu { DismissAlertMenuButton(model: model, row: row) }
        } else {
            button
        }
    }

    private func activateAgentRow(_ row: SpacesMobileWorkspaceRuntimeRow) {
        guard let session = model.terminalSession(for: row) else { return }
        selectedSession = SelectedTerminalSessionRoute(session: session)
    }
}
