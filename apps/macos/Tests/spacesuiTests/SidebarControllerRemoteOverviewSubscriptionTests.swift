import Testing

@testable import spacesui

@Suite struct SidebarControllerRemoteOverviewSubscriptionTests {
    @Test func startupDisconnectIsNotTreatedAsIntentionalRemoval() {
        #expect(
            SidebarController.remoteOverviewDisconnectAction(hasStoredSubscription: false, isOpeningSubscription: true) == .recordStartupDisconnect)
        #expect(SidebarController.remoteOverviewDisconnectAction(hasStoredSubscription: true, isOpeningSubscription: false) == .markOffline)
        #expect(
            SidebarController.remoteOverviewDisconnectAction(hasStoredSubscription: false, isOpeningSubscription: false) == .ignoreIntentionalRemoval)
    }
}
