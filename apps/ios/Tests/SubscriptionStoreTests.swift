#if canImport(UIKit)
    import XCTest
    import StoreKit

    @testable import SpacesMobile

    @MainActor final class SubscriptionStoreTests: XCTestCase {
        // MARK: - DEBUG bypass flag

        func testBypassEnabledOnlyWhenFlagSetToOne() {
            // These tests run in a DEBUG build, where the flag is honored. A release build always returns
            // false via the `#if DEBUG` in `paywallBypassEnabled`, which the compiler enforces and this
            // suite cannot exercise at runtime.
            XCTAssertTrue(SubscriptionStore.paywallBypassEnabled(environment: ["SPACES_MOBILE_PAYWALL_BYPASS": "1"]))
            XCTAssertFalse(SubscriptionStore.paywallBypassEnabled(environment: [:]))
            XCTAssertFalse(SubscriptionStore.paywallBypassEnabled(environment: ["SPACES_MOBILE_PAYWALL_BYPASS": "0"]))
            XCTAssertFalse(SubscriptionStore.paywallBypassEnabled(environment: ["SPACES_MOBILE_PAYWALL_BYPASS": "true"]))
        }

        func testBypassInitStartsEntitledAndSkipsChecking() {
            let store = SubscriptionStore(environment: ["SPACES_MOBILE_PAYWALL_BYPASS": "1"])
            XCTAssertTrue(store.isBypassed)
            XCTAssertEqual(store.state, .entitled)
        }

        func testNonBypassInitStartsChecking() {
            let store = SubscriptionStore(environment: [:])
            XCTAssertFalse(store.isBypassed)
            XCTAssertEqual(store.state, .checking)
        }

        // MARK: - Entitlement-state mapping

        func testResolvedStateWhenBypassedIsAlwaysEntitled() {
            XCTAssertEqual(SubscriptionStore.resolvedState(hasActiveEntitlement: false, isBypassed: true), .entitled)
            XCTAssertEqual(SubscriptionStore.resolvedState(hasActiveEntitlement: true, isBypassed: true), .entitled)
        }

        func testResolvedStateWhenNotBypassedFollowsEntitlement() {
            XCTAssertEqual(SubscriptionStore.resolvedState(hasActiveEntitlement: true, isBypassed: false), .entitled)
            XCTAssertEqual(SubscriptionStore.resolvedState(hasActiveEntitlement: false, isBypassed: false), .notEntitled)
        }

        // MARK: - Product load outcome

        func testProductLoadOutcomeWithEmptyProductsIsAFailure() {
            let outcome = SubscriptionStore.productLoadOutcome(products: [])
            XCTAssertNil(outcome.product)
            XCTAssertNotNil(outcome.errorMessage)
        }

        // MARK: - Failure messaging

        func testFailureMessageIsSilentOnUserCancellation() {
            XCTAssertNil(SubscriptionStore.failureMessage(for: StoreKitError.userCancelled, fallback: SubscriptionStore.purchaseFailureMessage))
            XCTAssertNil(SubscriptionStore.failureMessage(for: StoreKitError.userCancelled, fallback: SubscriptionStore.restoreFailureMessage))
        }

        func testFailureMessageNamesTheNetworkOnNetworkErrors() {
            XCTAssertEqual(
                SubscriptionStore.failureMessage(
                    for: StoreKitError.networkError(URLError(.notConnectedToInternet)), fallback: SubscriptionStore.purchaseFailureMessage),
                SubscriptionStore.networkFailureMessage)
        }

        func testFailureMessageFallsBackToActionSpecificRetryText() {
            XCTAssertEqual(
                SubscriptionStore.failureMessage(for: StoreKitError.unknown, fallback: SubscriptionStore.purchaseFailureMessage),
                SubscriptionStore.purchaseFailureMessage)
            XCTAssertEqual(
                SubscriptionStore.failureMessage(for: URLError(.timedOut), fallback: SubscriptionStore.restoreFailureMessage),
                SubscriptionStore.restoreFailureMessage)
        }

        // MARK: - Trial eligibility gating

        func testShowsTrialOnlyWhenConfiguredAndEligible() {
            XCTAssertTrue(SubscriptionPricing.showsTrial(hasConfiguredFreeTrial: true, isEligibleForIntroOffer: true))
            XCTAssertFalse(SubscriptionPricing.showsTrial(hasConfiguredFreeTrial: true, isEligibleForIntroOffer: false))
            XCTAssertFalse(SubscriptionPricing.showsTrial(hasConfiguredFreeTrial: false, isEligibleForIntroOffer: true))
            XCTAssertFalse(SubscriptionPricing.showsTrial(hasConfiguredFreeTrial: false, isEligibleForIntroOffer: false))
        }
    }
#endif
