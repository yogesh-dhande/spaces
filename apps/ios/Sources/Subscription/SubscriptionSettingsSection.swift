import StoreKit
import SwiftUI

/// The Settings tab's subscription section: current status, Manage Subscription (system sheet), and
/// Restore Purchases. Rendered in the shared header-band settings language.
struct SubscriptionSettingsSection: View {
    @Bindable var store: SubscriptionStore
    @State private var isShowingManageSubscriptions = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderBand {
                Text("Subscription")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
            VStack(spacing: 0) {
                statusRow
                manageRow
                restoreRow
                if let errorMessage = store.errorMessage {
                    errorRow(errorMessage)
                }
            }
            .padding(.top, 4)
        }
        .padding(.bottom, 14)
        .manageSubscriptionsSheet(isPresented: $isShowingManageSubscriptions)
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            label("Status")
            Spacer(minLength: 0)
            Text(statusText)
                .font(.system(size: 12))
                .foregroundStyle(Theme.mutedSecondary)
        }
        .rowPadding()
        .accessibilityIdentifier("settings.subscription.status")
    }

    private var manageRow: some View {
        Button {
            isShowingManageSubscriptions = true
        } label: {
            HStack(spacing: 10) {
                label("Manage Subscription")
                Spacer(minLength: 0)
                RowChevron()
            }
            .rowPadding()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.subscription.manage")
    }

    private var restoreRow: some View {
        Button {
            Task { await store.restore() }
        } label: {
            HStack(spacing: 10) {
                label("Restore Purchases")
                Spacer(minLength: 0)
                if store.isPurchasing {
                    ProgressView().controlSize(.small)
                }
            }
            .rowPadding()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isPurchasing)
        .accessibilityIdentifier("settings.subscription.restore")
    }

    /// Restore failures land in `store.errorMessage`; without this row a failed Restore Purchases tap
    /// from Settings would give no feedback at all (the paywall renders the same property itself).
    /// The channel is shared with product loading, so a rare launch-time load failure can also show
    /// here before any restore tap. Accepted: the message is still accurate about the App Store being
    /// unreachable, and a second error channel is not worth the extra state.
    private func errorRow(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(Theme.red)
            .rowPadding()
            .accessibilityIdentifier("settings.subscription.error")
    }

    private var statusText: String {
        if store.isBypassed { return "Active" }
        switch store.entitlementDetail {
        case .trial: return "Free trial"
        case .active: return "Active"
        case .none: return "Not subscribed"
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
    }
}

extension View {
    fileprivate func rowPadding() -> some View {
        padding(.vertical, 10)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
