import SwiftUI
import spacesterminalcore

@main struct SpacesMobileApp: App {
    @UIApplicationDelegateAdaptor(SpacesAppDelegate.self) private var appDelegate
    @State private var model = SpacesMobileAppModel()
    @State private var subscription = SubscriptionStore()
    @AppStorage(AppAppearanceStorage.key) private var appearanceMode: AppAppearanceMode = .default

    var body: some Scene {
        WindowGroup {
            // One entitlement gate wraps the whole app: the tab shell renders only when subscribed, the
            // paywall replaces it otherwise. The store is placed in the environment so the Settings tab's
            // subscription section reads the same instance.
            SubscriptionGateView(store: subscription) { RootTabView(model: model) }.environment(subscription).preferredColorScheme(
                appearanceMode.colorScheme
            ).task {
                // The delegate can receive a tap or a device token before the model exists; connecting
                // here hands it whatever arrived first.
                appDelegate.router.connect(openAlerts: { model.openAlertsFromNotification() }, deviceToken: { model.pushDeviceTokenReceived($0) })
            }
        }
    }
}
