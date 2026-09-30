import SwiftUI
import spacesdevicecore
import spacesterminalcore

/// Terminal navigation shared by the Alerts, Spaces, and Agents tabs: session routes, pending
/// launch routes, and the launch progress view.

struct SelectedTerminalSessionRoute: Identifiable, Hashable {
    let session: SpacesDeviceTerminalSessionSummary
    /// The paired device this session belongs to. Every creator sets it explicitly (the selected device's
    /// own id for the Spaces/Automations tabs, a deep link, or a replacement-session follow; a tapped
    /// Agents/Alerts row's own device otherwise), since the Agents/Alerts tabs stay open across a device
    /// switch and an implicit "selected device" default would silently retarget an already-open route.
    let deviceID: String
    /// Where this route was opened from, for the on-device performance log's `terminal_open_begin`
    /// `source` attribute (`"list"` or `"deep_link"`). Not part of identity or equality below: two routes
    /// for the same session are the same route regardless of how either was reached.
    var openSource: String = "list"

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

    /// Every launch action here is against the selected device: `PendingTerminalLaunch` is created only
    /// from the Spaces tab, so `model.activeDeviceID` is what to run, restart, or open on.
    private func runLaunch() async -> SpacesDeviceTerminalSessionSummary? {
        guard let activeDeviceID = model.activeDeviceID else { return nil }
        switch launch.action {
        case .primary:
            guard let row = launch.row else { return nil }
            return await model.performPrimaryAction(for: row, deviceID: activeDeviceID)
        case .run:
            guard let row = launch.row else { return nil }
            return await model.run(row: row, deviceID: activeDeviceID)
        case .restart:
            guard let row = launch.row else { return nil }
            return await model.restart(row: row, deviceID: activeDeviceID)
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

    @State private var pendingAuthentication: (message: String, deviceID: String)?

    private var activeRouteID: String? { selectedSession?.id ?? pendingTerminalLaunch?.id }

    func body(content: Content) -> some View {
        content.navigationDestination(item: $selectedSession) { route in
            // A context that fails to resolve (the device was unpaired between the tap and this push) is
            // not a state a route should ever reach in practice, but `navigationDestination` still has to
            // return a view for it; a bare `EmptyView` says nothing rather than opening the wrong device.
            if let context = model.terminalContext(forDeviceID: route.deviceID) {
                TerminalDetailView(
                    session: route.session, deviceContext: context, appModel: model, openSource: route.openSource,
                    onAuthenticationRequired: { message in
                        pendingAuthentication = (message, route.deviceID)
                        selectedSession = nil
                    }, onSessionChanged: { session in selectedSession = SelectedTerminalSessionRoute(session: session, deviceID: route.deviceID) }
                ) { selectedSession = nil }.id(route.id)
                    // Hide the tab bar in terminal detail so the keyboard accessory row owns the bottom
                    // edge instead of overlapping the tabs.
                    .toolbar(.hidden, for: .tabBar)
                    // The watch has to end whenever this detail leaves the screen, not only when the user
                    // navigates back: the Spaces and Automations tabs re-identify themselves on a device
                    // switch (`.id(activeDeviceID)` in `RootTabView`), which destroys this stack outright
                    // without ever driving `selectedSession` to nil, and a watch left running would then
                    // span the entire stretch with no terminal on screen.
                    // It hangs on the detail rather than on the modifier's own content because that content
                    // is the stack's root, which SwiftUI un-appears as soon as this detail is pushed onto it.
                    // Scoped to this route's session so a teardown that lands after another session's route
                    // has taken over cannot end the new session's watch.
                    .onDisappear { model.endTerminalWatch(forSessionID: route.session.id) }
                    // The mirror of the teardown above: a tab switch made for the user (a pairing link
                    // raising Settings) un-appears this detail without touching `selectedSession`, so
                    // returning to the tab shows the same route again with no `onChange` to re-register it.
                    // Appearing does, and it is a no-op on the first push, where `onChange` has already
                    // registered this session.
                    .onAppear { model.setActiveTerminalSession(route.session.id) }
            } else {
                // The device was removed, or Demo Mode swapped the whole paired set, between the tap that
                // opened this route and this push resolving it (or the route is for a device this session
                // never had context for at all). Popping on appear keeps the user moving back to the list
                // they came from instead of stranding them on a blank pushed screen with no way off it but
                // the system back gesture.
                EmptyView().onAppear { selectedSession = nil }
            }
        }.navigationDestination(item: $pendingTerminalLaunch) { launch in
            TerminalLaunchPendingView(launch: launch, model: model) { session in
                pendingTerminalLaunch = nil
                // `PendingTerminalLaunch` is created only from the Spaces tab (the selected device), so a
                // session it produces belongs to `activeDeviceID`.
                if let session, let activeDeviceID = model.activeDeviceID {
                    selectedSession = SelectedTerminalSessionRoute(session: session, deviceID: activeDeviceID)
                }
            } onBack: {
                pendingTerminalLaunch = nil
            }.toolbar(.hidden, for: .tabBar)
        }.onChange(of: activeRouteID) { oldValue, newValue in
            if oldValue != nil, newValue == nil { onTerminalDismissed?() }
            guard newValue == nil, let pending = pendingAuthentication else { return }
            pendingAuthentication = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                model.handleAuthenticationFailure(message: pending.message, deviceID: pending.deviceID)
            }
        }
        // No `initial: true`: all three tabs install this modifier, but only one can have a detail
        // route open at a time (the tab bar is hidden in detail), so firing on install would let an
        // inactive tab clobber the active tab's value with nil.
        .onChange(of: selectedSession?.session.id) { _, newValue in model.setActiveTerminalSession(newValue) }
        // A non-selected device's rejected mutation (`SpacesMobileAppModel.handleAuthenticationFailure(
        // message:deviceID:)`) closes this route the same way an open terminal already closes itself when
        // it is the one that discovers its own device's rejection: a device that stops recognizing this
        // iPhone must not go on showing a terminal for it, whichever request noticed the rejection first.
        .onChange(of: model.nonSelectedDeviceAuthenticationRejection) { _, rejection in
            guard let rejection, selectedSession?.deviceID == rejection.deviceID else { return }
            selectedSession = nil
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

// MARK: - Stop confirmation wording

/// Wording for the Stop confirmation dialog, shared by every entry point that can stop a session or a
/// workspace (the runtime row's swipe tray and long-press menu, the workspace actions menu, the terminal
/// detail toolbar) so the phrasing stays identical no matter which one asked. A row stop names the
/// session it kills; a workspace stop states the wider blast radius, since it takes every process,
/// coding agent, and terminal the workspace owns down with it.
enum StopConfirmationCopy {
    static func rowTitle(_ name: String) -> String { "Stop \"\(name)\"?" }
    static let rowMessage = "Its process will be terminated."

    static func workspaceTitle(_ name: String) -> String { "Stop \"\(name)\"?" }
    static let workspaceMessage = "Its processes, coding agents, and terminals will all stop."
}
