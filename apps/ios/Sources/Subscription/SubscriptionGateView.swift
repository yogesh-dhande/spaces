import SwiftUI

/// The single entitlement gate for the whole app: the app shell renders only when the user is
/// entitled, the paywall replaces it when not, and a minimal progress state covers the brief startup
/// check. Keeping this in one wrapper means no individual screen has to think about the subscription.
struct SubscriptionGateView<Content: View>: View {
    @Bindable var store: SubscriptionStore
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            switch store.state {
            case .checking: checkingState
            case .entitled: content()
            case .notEntitled: PaywallView(store: store)
            }
        }.task { store.start() }
    }

    private var checkingState: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ProgressView().tint(Theme.accent)
        }.accessibilityIdentifier("subscription.checking")
    }
}
