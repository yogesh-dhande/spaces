import Foundation
import StoreKit

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
    /// is unreachable the product stays `nil` and the entitlement read yields nothing, so the paywall
    /// stays up with a retry affordance rather than falling through to the app.
    func load() async {
        do {
            let products = try await Product.products(for: [Self.yearlyProductID])
            product = products.first
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshEntitlement()
    }

    /// Purchases the yearly subscription. A verified success finishes the transaction and unlocks the
    /// app; user cancellation and pending (e.g. Ask to Buy) states leave the paywall in place.
    func purchase() async {
        guard let product else {
            await load()
            return
        }
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                await handle(verificationResult: verification)
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Restores purchases by syncing with the App Store, then re-reads the entitlement. Used by both the
    /// paywall and the Settings section.
    func restore() async {
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            try await AppStore.sync()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await refreshEntitlement()
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
