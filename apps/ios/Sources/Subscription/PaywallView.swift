import StoreKit
import SwiftUI

/// The hard paywall shown whenever the app has no active entitlement. It is the app's whole UI in the
/// `notEntitled` state, so it is not dismissible: the only ways forward are subscribing or restoring a
/// prior purchase.
struct PaywallView: View {
    @Bindable var store: SubscriptionStore

    private static let privacyPolicyURL = URL(string: "https://usespaces.dev/privacy")
    private static let termsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")

    private static let features = [
        "Watch and steer terminal sessions and coding agents from your phone.",
        "Get alerts the moment an agent needs your input.",
        "Works with your own paired Mac and Linux machines.",
    ]

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    header
                    features
                    Spacer(minLength: 0)
                    purchaseSection
                }
                .padding(.horizontal, 28)
                .padding(.top, 48)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, minHeight: 0)
            }
        }
        .accessibilityIdentifier("paywall")
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("Spaces")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.text)
            Text("Your coding sessions, on your phone.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Self.features, id: \.self) { feature in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text(feature)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var purchaseSection: some View {
        VStack(spacing: 14) {
            Text(priceLine)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)

            if let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.red)
                    .multilineTextAlignment(.center)
            }

            primaryButton
            restoreButton

            Text(
                "Payment is charged to your Apple Account. The subscription renews automatically each year "
                    + "unless canceled at least 24 hours before the end of the current period. Manage or cancel "
                    + "anytime in Settings."
            )
            .font(.system(size: 11))
            .foregroundStyle(Theme.mutedSecondary)
            .multilineTextAlignment(.center)

            legalLinks
        }
    }

    @ViewBuilder private var primaryButton: some View {
        Button {
            Task {
                if store.product == nil {
                    await store.load()
                } else {
                    await store.purchase()
                }
            }
        } label: {
            Group {
                if store.isPurchasing {
                    ProgressView().tint(Theme.primaryButtonText)
                } else {
                    Text(primaryButtonTitle)
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(Theme.primaryButtonFill)
            .foregroundStyle(Theme.primaryButtonText)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .disabled(store.isPurchasing)
        .accessibilityIdentifier("paywall.subscribe")
    }

    private var restoreButton: some View {
        Button {
            Task { await store.restore() }
        } label: {
            Text("Restore Purchases")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
        .disabled(store.isPurchasing)
        .accessibilityIdentifier("paywall.restore")
    }

    private var legalLinks: some View {
        HStack(spacing: 6) {
            if let privacyPolicyURL = Self.privacyPolicyURL {
                Link("Privacy Policy", destination: privacyPolicyURL)
            }
            Text("·")
            if let termsOfUseURL = Self.termsOfUseURL {
                Link("Terms of Use", destination: termsOfUseURL)
            }
        }
        .font(.system(size: 11))
        .tint(Theme.mutedSecondary)
        .foregroundStyle(Theme.mutedSecondary)
    }

    private var primaryButtonTitle: String {
        guard let product = store.product else { return "Try Again" }
        return SubscriptionPricing.hasFreeTrial(product) ? "Start Free Trial" : "Subscribe"
    }

    /// The price line derived entirely from the loaded product — no hard-coded price strings. Falls back
    /// to a loading label while the product is being fetched (or a retry hint if the fetch failed).
    private var priceLine: String {
        guard let product = store.product else {
            return store.errorMessage == nil ? "Loading subscription…" : "Couldn't load the subscription."
        }
        return SubscriptionPricing.priceLine(for: product)
    }
}

/// Formats the subscription's price and introductory trial from the loaded `Product`, so every price
/// string in the UI is derived from StoreKit rather than hard-coded.
enum SubscriptionPricing {
    static func hasFreeTrial(_ product: Product) -> Bool {
        guard let offer = product.subscription?.introductoryOffer else { return false }
        return offer.paymentMode == .freeTrial
    }

    static func priceLine(for product: Product) -> String {
        let perYear = "\(product.displayPrice)/year"
        guard let offer = product.subscription?.introductoryOffer, offer.paymentMode == .freeTrial else {
            return perYear
        }
        return "\(trialLength(offer.period)) free, then \(perYear)"
    }

    /// Renders an introductory period like "7 days" or "1 month". Weeks are expressed in days so a
    /// one-week trial reads as "7 days", matching how the trial is described to users.
    private static func trialLength(_ period: Product.SubscriptionPeriod) -> String {
        let (count, unit): (Int, String)
        switch period.unit {
        case .day: (count, unit) = (period.value, "day")
        case .week: (count, unit) = (period.value * 7, "day")
        case .month: (count, unit) = (period.value, "month")
        case .year: (count, unit) = (period.value, "year")
        @unknown default: (count, unit) = (period.value, "day")
        }
        return "\(count) \(unit)\(count == 1 ? "" : "s")"
    }
}
