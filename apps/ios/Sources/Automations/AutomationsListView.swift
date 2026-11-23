import SwiftUI
import spacesdevicecore
import spacesterminalcore

/// Which list the Automations tab shows under its title.
enum AutomationsTabSection: String, CaseIterable, Identifiable {
    case automations = "Automations"
    case runs = "Runs"

    var id: String { rawValue }
}

/// Root content of the Automations tab (see `AutomationsTabView` for the tab shell). Automations are a
/// headline feature, so they get their own bottom tab rather than living under Settings or joining the
/// workspace-scoped Alerts/Spaces/Agents tabs. iOS view scope is deliberately narrow: view automations and
/// runs, trigger a run, cancel a running run, and open a run's terminal. Create, edit, and delete stay
/// Mac-only.
///
/// The tab has its own device (see `AutomationsPreferences`), chosen from the toolbar menu, and never
/// reads or writes the app-wide active device: what it lists, and where every action from it and its
/// detail screens goes, is the chosen device.
///
/// A segmented control switches between the device's automations and its recent runs. Tapping an
/// automation opens its detail screen (`AutomationDetailView`), where its schedule, command, and run
/// history live and "Run Now" is the explicit manual trigger.
struct AutomationsListView: View {
    @Bindable var model: SpacesMobileAppModel
    @State private var rememberedDeviceID = AutomationsPreferences().deviceID
    @State private var section = AutomationsTabSection.automations
    @State private var selectedAutomationID: String?
    @State private var selectedSession: SelectedTerminalSessionRoute?
    /// Required by `terminalSessionNavigation`'s shared modifier, which installs both a session route and
    /// a pending-launch route; the Automations tab never launches a session (it only opens one that
    /// already exists), so this stays nil.
    @State private var pendingTerminalLaunch: PendingTerminalLaunch?

    private var deviceID: String? {
        AutomationsPreferences.resolvedDeviceID(remembered: rememberedDeviceID, pairedDeviceIDs: model.pairedDevices.map(\.id))
    }

    private var deviceName: String? { model.pairedDevices.first { $0.id == deviceID }?.name }

    private var isDeviceOffline: Bool { deviceID.map { model.offlineDeviceIDs.contains($0) } ?? false }

    var body: some View {
        content.background(Theme.bg.ignoresSafeArea()).navigationTitle("Automations").tint(Theme.accent).toolbar {
            ToolbarItem(placement: .topBarTrailing) { deviceMenu }
        }.navigationDestination(item: $selectedAutomationID) { automationID in
            if let deviceID { AutomationDetailView(model: model, deviceID: deviceID, automationID: automationID, selectedSession: $selectedSession) }
        }.terminalSessionNavigation(model: model, selectedSession: $selectedSession, pendingTerminalLaunch: $pendingTerminalLaunch)
    }

    @ViewBuilder private var deviceMenu: some View {
        if let deviceName {
            Menu {
                Picker(
                    "Device",
                    selection: Binding(
                        get: { deviceID ?? "" },
                        set: { chosen in
                            rememberedDeviceID = chosen
                            AutomationsPreferences().deviceID = chosen
                            selectedAutomationID = nil
                        })
                ) {
                    ForEach(model.pairedDevices) { device in
                        Text(model.offlineDeviceIDs.contains(device.id) ? "\(device.name) (offline)" : device.name).tag(device.id)
                            .accessibilityIdentifier("automations.device.\(device.id)")
                    }
                }
            } label: {
                Text(deviceName)
            }.accessibilityIdentifier("automations.device")
        }
    }

    @ViewBuilder private var content: some View {
        if let deviceID, let deviceName {
            VStack(spacing: 0) {
                Picker("Show", selection: $section) { ForEach(AutomationsTabSection.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    .padding(.horizontal, 16).padding(.vertical, 8).accessibilityIdentifier("automations.section")
                if isDeviceOffline {
                    ContentUnavailableView("\(deviceName) is offline", systemImage: "wifi.slash").accessibilityIdentifier("automations.offline")
                } else {
                    switch section {
                    case .automations: automationsList(deviceID: deviceID)
                    case .runs: runsList(deviceID: deviceID)
                    }
                }
            }
        } else {
            ContentUnavailableView("No Devices", systemImage: "desktopcomputer", description: Text("Pair a device to see its automations."))
        }
    }

    @ViewBuilder private func automationsList(deviceID: String) -> some View {
        let rows = model.automationRows(forDeviceID: deviceID)
        if rows.isEmpty {
            ContentUnavailableView {
                Label("No automations", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("Create automations in Spaces on your Mac.")
            }.accessibilityIdentifier("automations.empty")
        } else {
            List { ForEach(rows) { row in automationRow(row, deviceID: deviceID).bandListRow() } }.listStyle(.plain).scrollContentBackground(.hidden)
                .refreshable { await model.refresh(deviceID: deviceID) }
        }
    }

    @ViewBuilder private func runsList(deviceID: String) -> some View {
        let overview = model.overview(forDeviceID: deviceID)
        let rows = SpacesMobileAutomations.runRows(overview?.automationRuns ?? [])
        if rows.isEmpty {
            ContentUnavailableView {
                Label("No runs yet", systemImage: "list.bullet.rectangle")
            } description: {
                Text("Runs appear here once an automation fires.")
            }.accessibilityIdentifier("automations.runs.empty")
        } else {
            List {
                AutomationRunRowsList(
                    model: model, deviceID: deviceID, rows: rows, title: { $0.automationName ?? "Automation" }, onMutated: {},
                    onOpenSession: { session in selectedSession = SelectedTerminalSessionRoute(session: session, deviceID: deviceID) }
                ).bandListRow()
            }.listStyle(.plain).scrollContentBackground(.hidden).refreshable { await model.refresh(deviceID: deviceID) }
        }
    }

    private func automationRow(_ row: SpacesMobileAutomationRow, deviceID: String) -> some View {
        let automation = row.automation
        var detailParts = [
            SpacesMobileAutomations.triggerSummary(automation),
            // Reads the shared 30-second label clock rather than `Date()`, so this text stays put across
            // every overview push instead of jittering (#540); see
            // `SpacesMobileAppModel.relativeTimeReference`.
            SpacesMobileAutomations.nextFireDescription(automation, relativeTo: model.relativeTimeReference),
        ]
        if let workspaceName = SpacesMobileAutomations.workspaceName(
            for: automation, in: model.overview(forDeviceID: deviceID)?.workspaces ?? [])
        {
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
