import Testing

@testable import spacesui

@Suite struct AppKitControllerTerminalOverviewSignalTests {
    @Test func terminalOverviewSignalReloadsOnlyForStartedMatchingProfile() {
        #expect(
            AppKitController.shouldReloadSidebarForTerminalOverviewSignal(
                didStartBackgroundServices: true, notificationObject: "profile-a", profileObject: "profile-a"))
        #expect(
            !AppKitController.shouldReloadSidebarForTerminalOverviewSignal(
                didStartBackgroundServices: false, notificationObject: "profile-a", profileObject: "profile-a"))
        #expect(
            !AppKitController.shouldReloadSidebarForTerminalOverviewSignal(
                didStartBackgroundServices: true, notificationObject: "profile-b", profileObject: "profile-a"))
        #expect(
            !AppKitController.shouldReloadSidebarForTerminalOverviewSignal(
                didStartBackgroundServices: true, notificationObject: nil, profileObject: "profile-a"))
    }
}
