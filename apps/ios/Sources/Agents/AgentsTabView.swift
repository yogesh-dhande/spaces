import SwiftUI
import spacesdevicecore

/// Agents tab: every coding-agent row across workspaces, grouped by activity.
struct AgentsTabView: View {
    @Bindable var model: SpacesMobileAppModel
    @State private var selectedSession: SelectedTerminalSessionRoute?
    @State private var pendingTerminalLaunch: PendingTerminalLaunch?

    var body: some View {
        NavigationStack {
            content.background(Theme.bg.ignoresSafeArea()).navigationTitle("Agents").tint(Theme.accent).terminalSessionNavigation(
                model: model, selectedSession: $selectedSession, pendingTerminalLaunch: $pendingTerminalLaunch)
        }.accessibilityIdentifier("tab.agents").overviewPolling(model: model, tab: .agents, activeDetailRouteID: activeDetailRouteID)
    }

    private var activeDetailRouteID: String? { selectedSession?.id ?? pendingTerminalLaunch?.id }

    @ViewBuilder private var content: some View {
        if model.agentGroups.isEmpty {
            ContentUnavailableView {
                Label("No Active Agents", systemImage: "cpu")
            } description: {
                Text("Blocked, finished, and working coding agents show up here. Launch one from its workspace on the Spaces tab.")
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

    private func agentRow(_ entry: SpacesMobileAgentEntry) -> some View {
        let row = entry.runtimeRow
        return Button {
            activateAgentRow(row)
        } label: {
            BandRow(dotKind: row.statusDotKind, tile: .tile(for: .codingAgents), title: entry.row.name, detail: entry.detail) {
                if row.sessionID != nil { RowChevron() } else if row.canRun { RowPlayIndicator() }
            }
        }.buttonStyle(.plain).disabled(model.isMutating || (row.sessionID == nil && !row.canRun)).accessibilityIdentifier("agents.row.\(entry.id)")
    }

    private func activateAgentRow(_ row: SpacesMobileWorkspaceRuntimeRow) {
        if let session = model.terminalSession(for: row) {
            selectedSession = SelectedTerminalSessionRoute(session: session)
        } else if row.canRun {
            pendingTerminalLaunch = PendingTerminalLaunch(row: row, action: .primary)
        }
    }
}
