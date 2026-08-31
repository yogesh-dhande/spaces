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
        detail = row.command
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

    let launch: PendingTerminalLaunch
    let model: SpacesMobileAppModel
    let onSessionReady: @MainActor (SpacesDeviceTerminalSessionSummary?) -> Void
    let onBack: @MainActor () -> Void

    @State private var hasStarted = false

    var body: some View {
        VStack(spacing: 0) {
            topOverlay.padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 4)

            TerminalStatusPlaceholder(systemName: launch.systemImage) {
                ProgressView().tint(.white)
                Text(launch.action.progressLabel).font(.body.monospaced()).foregroundStyle(.white.opacity(0.88)).multilineTextAlignment(.center)
                Text(launch.detail).font(.footnote.monospaced()).foregroundStyle(.white.opacity(0.56)).lineLimit(2).truncationMode(.middle)
                    .multilineTextAlignment(.center).padding(.horizontal, 28)
            }
        }.background(Theme.terminalSurface.ignoresSafeArea()).toolbar(.hidden, for: .navigationBar).task(id: launch.id) {
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
                    .padding(.horizontal, 12).background(Theme.terminalChromePillBackground)
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
            ) { selectedSession = nil }.id(route.id)
                // Hide the tab bar in terminal detail so the keyboard accessory row owns the bottom
                // edge instead of overlapping the tabs.
                .toolbar(.hidden, for: .tabBar)
                // The watch has to end whenever this detail leaves the screen, not only when the user
                // navigates back: switching devices re-identifies the whole tab (`.id(activeDeviceID)`),
                // which destroys this stack outright without ever driving `selectedSession` to nil, and a
                // watch left running would then span the entire stretch with no terminal on screen.
                // It hangs on the detail rather than on the modifier's own content because that content is
                // the stack's root, which SwiftUI un-appears as soon as this detail is pushed onto it.
                // Scoped to this route's session so a teardown that lands after another session's route
                // has taken over cannot end the new session's watch.
                .onDisappear { model.endTerminalWatch(forSessionID: route.session.id) }
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
        // No `initial: true`: all three tabs install this modifier, but only one can have a detail
        // route open at a time (the tab bar is hidden in detail), so firing on install would let an
        // inactive tab clobber the active tab's value with nil.
        .onChange(of: selectedSession?.session.id) { _, newValue in model.setActiveTerminalSession(newValue) }
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

// MARK: - Stop confirmation wording

/// Wording for the Stop confirmation dialog, shared by every entry point that can stop a session or a
/// workspace (the runtime row's swipe tray and long-press menu, the workspace control bar, the terminal
/// detail toolbar) so the phrasing stays identical no matter which one asked. A row stop names the
/// session it kills; a workspace stop states the wider blast radius, since it takes every process,
/// coding agent, and terminal the workspace owns down with it.
enum StopConfirmationCopy {
    static func rowTitle(_ name: String) -> String { "Stop \"\(name)\"?" }
    static let rowMessage = "Its process will be terminated."

    static func workspaceTitle(_ name: String) -> String { "Stop \"\(name)\"?" }
    static let workspaceMessage = "Its processes, coding agents, and terminals will all stop."
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
