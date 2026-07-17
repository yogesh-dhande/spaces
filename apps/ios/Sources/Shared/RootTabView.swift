import SwiftUI
import spacesdevicecore

/// Classifies an incoming `spaces://` URL for `onOpenURL`. Both link kinds share the `spaces`
/// scheme, so routing must key off shape (scheme+host), not parse success: a pairing-shaped URL
/// always routes to `.pairing`, even when malformed, so `preparePairingLink` — which owns parsing
/// and surfaces failures via `errorMessage` — gets the chance to report the error. Routing on
/// `SpacesDevicePairingLink.parse` success instead would let a thrown parse error be swallowed by
/// `try?` and silently fall through to the terminal-link branch (or "unrecognized"), leaving the
/// user with no feedback. A pure function so the shape-vs-parse decision is unit-testable without
/// a live View.
enum SpacesIncomingLinkRoute: Equatable {
    case pairing(URL)
    case terminal(SpacesTerminalDeepLink)
    case unrecognized(URL)

    static func route(for url: URL) -> SpacesIncomingLinkRoute {
        if url.scheme == SpacesDevicePairingLink.scheme, url.host == SpacesDevicePairingLink.host { return .pairing(url) }
        if let link = SpacesTerminalDeepLink.parse(url) { return .terminal(link) }
        return .unrecognized(url)
    }
}

/// The app shell: a native bottom tab bar with one NavigationStack per tab. Tab selection
/// lives on the model so pairing links, auth recovery, and the not-paired state can switch
/// tabs programmatically.
struct RootTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var model: SpacesMobileAppModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            AlertsTabView(model: model).id(model.activeDeviceID).tag(SpacesMobileTab.alerts).tabItem { Label("Alerts", systemImage: "bell") }.badge(
                model.undismissedAlertCount)
            SpacesTabView(model: model).id(model.activeDeviceID).tag(SpacesMobileTab.spaces).tabItem {
                Label("Spaces", systemImage: "rectangle.stack")
            }
            AgentsTabView(model: model).id(model.activeDeviceID).tag(SpacesMobileTab.agents).tabItem { Label("Agents", systemImage: "cpu") }
            SettingsTabView(model: model).tag(SpacesMobileTab.settings).tabItem { Label("Settings", systemImage: "gearshape") }
        }.tint(Theme.accent).alert("Connection Error", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }.onChange(of: model.isShowingConnectionSettings) { _, isShowing in if isShowing { model.selectedTab = .settings } }.onOpenURL { url in
            switch SpacesIncomingLinkRoute.route(for: url) {
            case .pairing(let url): model.preparePairingLink(url)
            case .terminal(let link): Task { await model.openTerminalDeepLink(link) }
            case .unrecognized(let url): NSLog("Ignoring unrecognized spaces link: %@", url.absoluteString)
            }
        }
        // The browser proxy serves the whole app, so its lifetime follows the app shell rather than the
        // Spaces tab: backgrounding closes its tunnels, and foregrounding restores them.
        .task { model.browserProxyStart() }.onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active: model.browserProxyStart()
            case .background: model.browserProxyStop()
            case .inactive: break
            @unknown default: break
            }
        }
    }

    private var errorAlertBinding: Binding<Bool> { Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.dismissError() } }) }
}
