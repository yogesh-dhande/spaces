import Testing
import spacesterminalcore

@testable import spacesui

@Suite struct AppKitControllerTerminalOverviewSignalTests {
    /// Terminal runtime state raises no `databaseDidChange`, so this signal is the only thing that tells
    /// the app a session rang a bell or changed state in the daemon process: without an observer for it
    /// the Alerts list and badge only catch up on an unrelated reload.
    @MainActor @Test func terminalOverviewSignalIsObservedAcrossProcesses() {
        #expect(AppKitController.distributedIPCObservers.contains { $0.name == TerminalOverviewSignal.name })
    }

    @Test func terminalOverviewSignalReloadsOnlyForStartedMatchingProfile() {
        #expect(
            WindowFocusController.shouldReloadSidebarForTerminalOverviewSignal(
                didStartBackgroundServices: true, notificationObject: "profile-a", profileObject: "profile-a"))
        #expect(
            !WindowFocusController.shouldReloadSidebarForTerminalOverviewSignal(
                didStartBackgroundServices: false, notificationObject: "profile-a", profileObject: "profile-a"))
        #expect(
            !WindowFocusController.shouldReloadSidebarForTerminalOverviewSignal(
                didStartBackgroundServices: true, notificationObject: "profile-b", profileObject: "profile-a"))
        #expect(
            !WindowFocusController.shouldReloadSidebarForTerminalOverviewSignal(
                didStartBackgroundServices: true, notificationObject: nil, profileObject: "profile-a"))
    }
}
