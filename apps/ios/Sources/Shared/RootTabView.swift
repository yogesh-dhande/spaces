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
        // The banner is stacked above the TabView rather than applied as a top safeAreaInset:
        // the UIKit navigation bars inside each tab position their toolbar items against the
        // scene's safe area, not SwiftUI's extra inset, so an inset banner would sit on top of
        // nav-bar buttons (e.g. the Alerts "Clear" button under "Turn Off").
        VStack(spacing: 0) {
            demoModeBanner
            TabView(selection: $model.selectedTab) {
                AlertsTabView(model: model).id(model.activeDeviceID).tag(SpacesMobileTab.alerts).tabItem { Label("Alerts", systemImage: "bell") }
                    .badge(model.undismissedAlertCount)
                SpacesTabView(model: model).id(model.activeDeviceID).tag(SpacesMobileTab.spaces).tabItem {
                    Label("Spaces", systemImage: "rectangle.stack")
                }
                AgentsTabView(model: model).id(model.activeDeviceID).tag(SpacesMobileTab.agents).tabItem { Label("Agents", systemImage: "cpu") }
                AutomationsTabView(model: model).id(model.activeDeviceID).tag(SpacesMobileTab.automations).tabItem {
                    Label("Automations", systemImage: "clock.arrow.circlepath")
                }.badge(model.automationRunningRunCount)
                SettingsTabView(model: model).tag(SpacesMobileTab.settings).tabItem { Label("Settings", systemImage: "gearshape") }
            }
        }.tint(Theme.accent).alert("Connection Error", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }.alert("Deleted Workspace", isPresented: deletedWorkspaceNoticeBinding) {
            Button("OK", role: .cancel) { model.dismissDeletedWorkspaceNotice() }
        } message: {
            Text(model.deletedWorkspaceNotice ?? "")
        }
        // Applying a staged build to a blocked device is the one thing this app does on its own, so its
        // one report lives at the shell: it is about the device, not about whichever tab happens to be
        // on screen when the wait runs out.
        .alert(stagedApplyAlertTitle, isPresented: stagedApplyDidNotLandBinding, presenting: model.stagedApplyDidNotLandAlert) { _ in
            Button("Try Again") { Task { await model.retryStagedApply() } }
            Button("Not Now", role: .cancel) { model.dismissStagedApplyDidNotLandAlert() }
        } message: { alert in
            Text(alert.message)
        }.onChange(of: model.isShowingConnectionSettings) { _, isShowing in if isShowing { model.selectedTab = .settings } }.onOpenURL { url in
            switch SpacesIncomingLinkRoute.route(for: url) {
            case .pairing(let url): model.preparePairingLink(url)
            case .terminal(let link): Task { await model.openTerminalDeepLink(link) }
            case .unrecognized(let url): NSLog("Ignoring unrecognized spaces link: %@", url.absoluteString)
            }
        }
        // The browser proxy serves the whole app, so its lifetime follows the app shell rather than the
        // Spaces tab: backgrounding closes its tunnels, and foregrounding restores them. Backgrounding
        // also ends any run of failed refreshes, since a suspended app polls nothing and cannot claim the
        // connection kept failing while it was away.
        .task { model.browserProxyStart() }.onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                model.browserProxyStart()
                // Returning to the foreground is the moment this device has plausibly moved networks
                // (e.g. walked back home onto the LAN after being away on the tailnet). Clearing every
                // paired device's cached active host means the next connect re-evaluates `hosts` from
                // the top, preferring the LAN address again when it is reachable rather than staying on
                // the slower tailnet path out of habit. That alone only resets the persisted store, so
                // also reset the live client: it keeps its own in-memory resolver cache and open command
                // connection independent of the store until something makes it fail over on its own (see
                // `SpacesDeviceEndpointResolver`), which a `resetActiveConnectionEndpoint()` foreground
                // reset with no open failure would otherwise never trigger. That reset deliberately
                // leaves any open terminal viewer's own stream alone — see its doc comment.
                SpacesMobileDeviceStore.clearActiveHosts()
                model.resetActiveConnectionEndpoint()
                model.resumeTerminalWatch()
            case .background:
                model.browserProxyStop()
                model.noteConnectionMonitoringPaused()
                // An open terminal detail survives backgrounding, so watching has to be ended here or the
                // app would go on treating a session the user cannot see as the one they are looking at
                // and swallow the bells it rings while away.
                model.suspendTerminalWatch()
            case .inactive: break
            @unknown default: break
            }
        }
    }

    private var errorAlertBinding: Binding<Bool> { Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.dismissError() } }) }

    /// The alert's title has to be readable when the alert is absent (SwiftUI evaluates it either way),
    /// so it collapses to empty rather than forcing the state to survive the dismissal that clears it.
    private var stagedApplyAlertTitle: String { model.stagedApplyDidNotLandAlert?.title ?? "" }

    private var stagedApplyDidNotLandBinding: Binding<Bool> {
        Binding(get: { model.stagedApplyDidNotLandAlert != nil }, set: { if !$0 { model.dismissStagedApplyDidNotLandAlert() } })
    }

    private var deletedWorkspaceNoticeBinding: Binding<Bool> {
        Binding(get: { model.deletedWorkspaceNotice != nil }, set: { if !$0 { model.dismissDeletedWorkspaceNotice() } })
    }

    /// Slim accent-tinted strip pinned above every tab while Demo Mode is on, so the sample-data context
    /// stays visible on all four tabs and one tap turns it off. Absent (zero height) when Demo Mode is off.
    @ViewBuilder private var demoModeBanner: some View {
        if model.isDemoModeEnabled {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                Text("Demo Mode — sample data").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                Spacer(minLength: 0)
                Button("Turn Off") {
                    model.setDemoMode(false)
                    Task { await model.refresh() }
                }.font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent).buttonStyle(.plain)
            }.padding(.horizontal, 16).padding(.vertical, 8).frame(maxWidth: .infinity)
                // accentTint is translucent, so back it with the app background; both extend under
                // the status bar because the banner is the topmost view while Demo Mode is on.
                .background { Theme.accentTint.ignoresSafeArea(edges: .top) }.background { Theme.bg.ignoresSafeArea(edges: .top) }.overlay(
                    Rectangle().frame(height: 1).foregroundStyle(Theme.border), alignment: .bottom
                ).accessibilityIdentifier("demo.banner")
        }
    }
}
