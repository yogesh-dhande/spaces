import SwiftUI
import spacesdevicecore
import spacesterminalcore

/// Terminal navigation shared by the Alerts, Spaces, and Agents tabs: session routes, pending
/// launch routes, the launch progress view, and the polling refresh loop each tab runs while
/// it is visible.

struct SelectedTerminalSessionRoute: Identifiable, Hashable {
    let session: SpacesDeviceTerminalSessionSummary

    var id: String { session.id }

    static func == (lhs: SelectedTerminalSessionRoute, rhs: SelectedTerminalSessionRoute) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct PendingTerminalLaunch: Identifiable, Sendable, Hashable {
    enum Action: Sendable {
        case primary
        case run
        case restart
        case workspaceTerminal
    }

    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let action: Action
    let row: SpacesMobileWorkspaceRuntimeRow?
    let workspaceID: String?

    init(row: SpacesMobileWorkspaceRuntimeRow, action: Action) {
        self.id = "\(action.idComponent):\(row.id)"
        title = row.title
        detail = row.detail
        systemImage = row.type.iconName
        self.action = action
        self.row = row
        workspaceID = nil
    }

    init(workspace: SpacesDeviceWorkspaceSummary) {
        id = "workspace-terminal:\(workspace.id)"
        title = "Workspace Terminal"
        detail = workspace.dir
        systemImage = "terminal.fill"
        action = .workspaceTerminal
        row = nil
        workspaceID = workspace.id
    }

    static func == (lhs: PendingTerminalLaunch, rhs: PendingTerminalLaunch) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension PendingTerminalLaunch.Action {
    var idComponent: String {
        switch self {
        case .primary: "primary"
        case .run: "run"
        case .restart: "restart"
        case .workspaceTerminal: "workspace-terminal"
        }
    }

    var progressLabel: String {
        switch self {
        case .primary: "Starting terminal..."
        case .run: "Starting terminal..."
        case .restart: "Restarting terminal..."
        case .workspaceTerminal: "Opening terminal..."
        }
    }
}

struct TerminalLaunchPendingView: View {
    private static let chromeControlHeight: CGFloat = 36
    private static let surfaceBackground = Color(red: 15 / 255, green: 21 / 255, blue: 23 / 255)

    let launch: PendingTerminalLaunch
    let model: SpacesMobileAppModel
    let onSessionReady: @MainActor (SpacesDeviceTerminalSessionSummary?) -> Void
    let onBack: @MainActor () -> Void

    @State private var hasStarted = false

    var body: some View {
        VStack(spacing: 0) {
            topOverlay.padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 4)

            VStack(spacing: 18) {
                Spacer(minLength: 0)
                Image(systemName: launch.systemImage).font(.system(size: 34, weight: .semibold)).foregroundStyle(.white.opacity(0.82))
                ProgressView().tint(.white)
                Text(launch.action.progressLabel).font(.body.monospaced()).foregroundStyle(.white.opacity(0.88)).multilineTextAlignment(.center)
                Text(launch.detail).font(.footnote.monospaced()).foregroundStyle(.white.opacity(0.56)).lineLimit(2).truncationMode(.middle)
                    .multilineTextAlignment(.center).padding(.horizontal, 28)
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(Self.surfaceBackground.ignoresSafeArea()).toolbar(.hidden, for: .navigationBar).task(id: launch.id) {
            guard !hasStarted else { return }
            hasStarted = true
            let session = await runLaunch()
            guard !Task.isCancelled else { return }
            await onSessionReady(session)
        }.accessibilityIdentifier("terminal.launch.\(launch.id)")
    }

    private var topOverlay: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left").font(.subheadline.weight(.semibold)).foregroundStyle(.white).frame(height: Self.chromeControlHeight)
                    .padding(.horizontal, 12).background(
                        Capsule().fill(.black.opacity(0.28)).overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1)))
            }.accessibilityIdentifier("terminal.launch.back").accessibilityLabel("Back")

            Spacer(minLength: 0)

            Text(launch.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(1).accessibilityIdentifier(
                "terminal.launch.title")

            Spacer(minLength: 0)
            Color.clear.frame(width: Self.chromeControlHeight, height: 1)
        }.frame(height: Self.chromeControlHeight)
    }

    private func runLaunch() async -> SpacesDeviceTerminalSessionSummary? {
        switch launch.action {
        case .primary:
            guard let row = launch.row else { return nil }
            return await model.performPrimaryAction(for: row)
        case .run:
            guard let row = launch.row else { return nil }
            return await model.run(row: row)
        case .restart:
            guard let row = launch.row else { return nil }
            return await model.restart(row: row)
        case .workspaceTerminal:
            guard let workspaceID = launch.workspaceID else { return nil }
            return await model.openWorkspaceTerminal(workspaceID: workspaceID)
        }
    }
}

// MARK: - Navigation destinations

/// Installs the terminal detail and pending-launch destinations on a tab's NavigationStack and
/// owns the deferred authentication-failure handoff when a terminal route closes.
struct TerminalSessionNavigationModifier: ViewModifier {
    let model: SpacesMobileAppModel
    @Binding var selectedSession: SelectedTerminalSessionRoute?
    @Binding var pendingTerminalLaunch: PendingTerminalLaunch?
    var onTerminalDismissed: (@MainActor () -> Void)?

    @State private var pendingAuthenticationMessage: String?

    private var activeRouteID: String? { selectedSession?.id ?? pendingTerminalLaunch?.id }

    func body(content: Content) -> some View {
        content.navigationDestination(item: $selectedSession) { route in
            TerminalDetailView(
                session: route.session, settings: model.settings, appModel: model,
                onAuthenticationRequired: { message in
                    pendingAuthenticationMessage = message
                    selectedSession = nil
                }, onSessionChanged: { session in selectedSession = SelectedTerminalSessionRoute(session: session) }
            ) { selectedSession = nil }
                .id(route.id)
                // Hide the tab bar in terminal detail so the keyboard accessory row owns the bottom
                // edge instead of overlapping the tabs.
                .toolbar(.hidden, for: .tabBar)
        }.navigationDestination(item: $pendingTerminalLaunch) { launch in
            TerminalLaunchPendingView(launch: launch, model: model) { session in
                pendingTerminalLaunch = nil
                if let session { selectedSession = SelectedTerminalSessionRoute(session: session) }
            } onBack: {
                pendingTerminalLaunch = nil
            }.toolbar(.hidden, for: .tabBar)
        }.onChange(of: activeRouteID) { oldValue, newValue in
            if oldValue != nil, newValue == nil { onTerminalDismissed?() }
            guard newValue == nil, let message = pendingAuthenticationMessage else { return }
            pendingAuthenticationMessage = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                model.handleAuthenticationFailure(message: message)
            }
        }
    }
}

extension View {
    func terminalSessionNavigation(
        model: SpacesMobileAppModel, selectedSession: Binding<SelectedTerminalSessionRoute?>, pendingTerminalLaunch: Binding<PendingTerminalLaunch?>,
        onTerminalDismissed: (@MainActor () -> Void)? = nil
    ) -> some View {
        modifier(
            TerminalSessionNavigationModifier(
                model: model, selectedSession: selectedSession, pendingTerminalLaunch: pendingTerminalLaunch, onTerminalDismissed: onTerminalDismissed
            ))
    }
}

// MARK: - Overview polling

/// Refreshes the overview every two seconds while the app is active, the owning tab is
/// selected, this device is paired, and no detail route (terminal or browser session) is open.
struct OverviewPollingModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let model: SpacesMobileAppModel
    let tab: SpacesMobileTab
    let activeDetailRouteID: String?
    var refreshGeneration = 0

    private var taskID: String {
        [
            scenePhase == .active ? "active" : "inactive", model.selectedTab == tab ? "visible" : "hidden", activeDetailRouteID ?? "list",
            model.activeDeviceID ?? "no-device", model.settings.isPaired ? "paired" : "unpaired", "\(refreshGeneration)",
        ].joined(separator: "|")
    }

    func body(content: Content) -> some View {
        content.task(id: taskID) {
            // Every end of this task is a boundary where the connection stops being watched from here —
            // a detail route opening, another tab taking over, the app leaving the foreground, the device
            // going unpaired. The connection-error alert times how long refreshes have been failing, so
            // that clock must not keep running across a gap in which nothing refreshed at all.
            defer { model.noteConnectionMonitoringPaused() }
            guard shouldPoll else { return }
            if !isPaused { await model.refresh() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, shouldPoll else { return }
                if isPaused { continue }
                await model.refresh()
            }
        }
    }

    private var shouldPoll: Bool { scenePhase == .active && model.selectedTab == tab && activeDetailRouteID == nil && model.settings.isPaired }

    /// A daemon update deliberately takes its device offline mid-handoff, and `requestDaemonUpdate()`
    /// runs its own poll across that outage, treating the unreachable window as expected rather than as
    /// an error. A routine overview refresh landing in that window would take the normal failure path
    /// and raise a connection error for an outage the app already knows about.
    ///
    /// This skips the refresh and keeps looping rather than joining `shouldPoll`, whose conditions end
    /// the task outright: the task only restarts when `taskID` changes, so returning here would leave
    /// polling dead after the update instead of resuming it.
    private var isPaused: Bool { model.isApplyingDaemonUpdate }
}

extension View {
    func overviewPolling(model: SpacesMobileAppModel, tab: SpacesMobileTab, activeDetailRouteID: String?, refreshGeneration: Int = 0) -> some View {
        modifier(OverviewPollingModifier(model: model, tab: tab, activeDetailRouteID: activeDetailRouteID, refreshGeneration: refreshGeneration))
    }
}
