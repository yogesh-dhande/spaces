import Foundation
import StoreKit
import UIKit

/// Owns the app's single auto-renewable subscription: it loads the yearly product, resolves the
/// entitlement from `Transaction.currentEntitlements`, listens to `Transaction.updates` for the app's
/// lifetime, and drives purchase/restore. The app gates its whole UI on `state` (see
/// `SubscriptionGateView`), so this is the one place that decides whether the user reaches the app.
@MainActor @Observable final class SubscriptionStore {
    /// The gate the app renders against. `checking` is only the brief startup window before the first
    /// entitlement read resolves; everything after lands on `entitled` or `notEntitled`.
    enum State: Equatable {
        case checking
        case entitled
        case notEntitled
    }

    /// Whether the active entitlement is inside its introductory free trial or fully paid, used only for
    /// the Settings status label. `none` while not entitled.
    enum EntitlementDetail: Equatable {
        case none
        case trial
        case active
    }

    /// The single auto-renewable product ID. Declared once so the paywall, entitlement checks, and the
    /// local `SpacesMobile.storekit` config all agree on the same identifier.
    static let yearlyProductID = "dev.usespaces.spacesmobile.yearly"

    /// DEBUG-only launch flag that skips the paywall so the mobile e2e/demo lanes reach the app shell
    /// without a real subscription. Release builds ignore it entirely.
    static let bypassEnvironmentKey = "SPACES_MOBILE_PAYWALL_BYPASS"

    private(set) var state: State
    private(set) var product: Product?
    /// Whether this specific customer is still eligible for the product's introductory free trial.
    /// Distinct from the product having a configured trial at all: a lapsed subscriber who already
    /// consumed it is not eligible again, so the paywall must not advertise "Start Free Trial" to them.
    /// Defaults to false and is only set true once StoreKit confirms eligibility, so the conservative
    /// (paid) framing is what shows if that check has not resolved yet.
    private(set) var isEligibleForIntroOffer = false
    private(set) var entitlementDetail: EntitlementDetail = .none
    private(set) var isPurchasing = false
    private(set) var errorMessage: String?

    /// True when the DEBUG bypass flag is set. Held so the Settings section can label the status
    /// honestly and so `start()` skips all StoreKit work.
    let isBypassed: Bool

    @ObservationIgnored private var transactionListener: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        isBypassed = Self.paywallBypassEnabled(environment: environment)
        state = isBypassed ? .entitled : .checking
    }

    deinit { transactionListener?.cancel() }

    /// Whether the paywall bypass is active. The flag is honored only in DEBUG builds; a release build
    /// always returns false regardless of the environment, so the shipped app can never be unlocked
    /// through a launch variable.
    static func paywallBypassEnabled(environment: [String: String]) -> Bool {
        #if DEBUG
            return environment[bypassEnvironmentKey] == "1"
        #else
            return false
        #endif
    }

    /// Maps a resolved entitlement into the gate state, accounting for the bypass. Pure so the gating
    /// contract is testable without StoreKit.
    static func resolvedState(hasActiveEntitlement: Bool, isBypassed: Bool) -> State {
        if isBypassed { return .entitled }
        return hasActiveEntitlement ? .entitled : .notEntitled
    }

    /// Begins the transaction listener and loads the product and entitlement. Idempotent, so the gate
    /// view can call it on every appearance. A no-op when bypassed.
    func start() {
        guard !isBypassed, !hasStarted else { return }
        hasStarted = true
        transactionListener = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(verificationResult: update)
            }
        }
        Task { await load() }
    }

    /// Loads the product and refreshes the entitlement. Also the paywall's retry path: when StoreKit
    /// is unreachable, or the product fetch succeeds but returns nothing, the product stays `nil` and
    /// the paywall stays up with a retry affordance rather than falling through to the app.
    func load() async {
        do {
            let products = try await Product.products(for: [Self.yearlyProductID])
            let outcome = Self.productLoadOutcome(products: products)
            product = outcome.product
            errorMessage = outcome.errorMessage
            if let product = outcome.product {
                isEligibleForIntroOffer = await product.subscription?.isEligibleForIntroOffer ?? false
            } else {
                isEligibleForIntroOffer = false
            }
        } catch {
            errorMessage = error.localizedDescription
            isEligibleForIntroOffer = false
        }
        await refreshEntitlement()
    }

    /// Maps a successful (non-throwing) product fetch to the store's fields. An empty response — e.g.
    /// the product not yet available in this storefront while App Store Connect configuration
    /// propagates — is a load failure the paywall must surface, not a silent nil: without this, `product`
    /// stays nil, `errorMessage` is cleared, and the paywall shows "Loading subscription…" forever with
    /// no retry affordance. Pure so it is testable without constructing a `Product`.
    static func productLoadOutcome(products: [Product]) -> (product: Product?, errorMessage: String?) {
        guard let product = products.first else {
            return (nil, "The subscription is currently unavailable. Please try again later.")
        }
        return (product, nil)
    }

    /// Purchases the yearly subscription. A verified success finishes the transaction and unlocks the
    /// app; user cancellation and pending (e.g. Ask to Buy) states leave the paywall in place. The
    /// confirmation sheet is anchored to the app's window scene: the sceneless `purchase()` is
    /// deprecated on iOS 18.2+, and the scene overload is always available at our iOS 17 deployment
    /// target.
    func purchase() async {
        guard let product else {
            await load()
            return
        }
        guard let scene = Self.purchaseConfirmationScene() else {
            errorMessage = Self.purchaseFailureMessage
            return
        }
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase(confirmIn: scene)
            switch result {
            case .success(let verification):
                await handle(verificationResult: verification)
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = Self.failureMessage(for: error, fallback: Self.purchaseFailureMessage)
        }
    }

    /// The window scene the purchase confirmation sheet is anchored to. Prefers the foreground-active
    /// scene; during a brief activation transition none may report `.foregroundActive` yet, so any
    /// connected window scene still anchors correctly in this single-scene app.
    private static func purchaseConfirmationScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// Restores purchases by syncing with the App Store, then re-reads the entitlement. Used by both the
    /// paywall and the Settings section.
    func restore() async {
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }
        do {
            try await AppStore.sync()
        } catch {
            errorMessage = Self.failureMessage(for: error, fallback: Self.restoreFailureMessage)
        }
        await refreshEntitlement()
    }

    static let purchaseFailureMessage = "The purchase could not be completed. Please try again in a moment."
    static let restoreFailureMessage = "Purchases could not be restored. Please try again in a moment."
    static let networkFailureMessage =
        "The App Store could not be reached. Check your internet connection and try again."

    /// Maps a thrown StoreKit error to the message the paywall shows, or nil when nothing should be
    /// surfaced. Cancellation arrives both as a `.userCancelled` purchase result and as a thrown
    /// `StoreKitError.userCancelled` (e.g. dismissing the App Store sign-in sheet); either is the
    /// user's own choice, not a failure. Everything else gets a retryable message in the app's voice —
    /// raw system strings like "Unable to Complete Request" read as a broken purchase flow, which is
    /// what App Review rejected. Pure so the mapping is testable without StoreKit.
    static func failureMessage(for error: any Error, fallback: String) -> String? {
        guard let storeKitError = error as? StoreKitError else { return fallback }
        switch storeKitError {
        case .userCancelled:
            return nil
        case .networkError:
            return networkFailureMessage
        default:
            return fallback
        }
    }

    /// Resolves the entitlement from the current verified transactions. `currentEntitlements` already
    /// excludes expired and revoked subscriptions, so any verified transaction for our product means the
    /// user is entitled.
    func refreshEntitlement() async {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.productID == Self.yearlyProductID else { continue }
            entitlementDetail = Self.entitlementDetail(for: transaction)
            state = Self.resolvedState(hasActiveEntitlement: true, isBypassed: isBypassed)
            return
        }
        entitlementDetail = .none
        state = Self.resolvedState(hasActiveEntitlement: false, isBypassed: isBypassed)
    }

    private func handle(verificationResult: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = verificationResult else {
            errorMessage = "Your purchase could not be verified. Please try again."
            return
        }
        await transaction.finish()
        await refreshEntitlement()
    }

    /// Whether an entitled transaction is inside its introductory free trial. Introductory-offer
    /// inspection is only available without deprecation on iOS 17.2+, so on 17.0–17.1 an active trial
    /// reports as `active` rather than `trial` — a cosmetic Settings-label difference only.
    private static func entitlementDetail(for transaction: Transaction) -> EntitlementDetail {
        if #available(iOS 17.2, *) {
            return transaction.offer?.type == .introductory ? .trial : .active
        }
        return .active
    }
}
