import SwiftUI
import spacesdevicecore

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
            // Both link kinds share the `spaces` scheme; distinguish by shape. A pairing link starts
            // the pairing flow; a terminal deep link focuses the named session; anything else is logged
            // and ignored rather than misrouted.
            if (try? SpacesDevicePairingLink.parse(url)) != nil {
                model.preparePairingLink(url)
            } else if let link = SpacesTerminalDeepLink.parse(url) {
                Task { await model.openTerminalDeepLink(link) }
            } else {
                NSLog("Ignoring unrecognized spaces link: %@", url.absoluteString)
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
