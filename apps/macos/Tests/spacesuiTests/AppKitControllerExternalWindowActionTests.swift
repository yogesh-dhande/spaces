import Testing

@testable import spacesui
@testable import workspacecore

@Suite struct AppKitControllerExternalWindowActionTests {
    @MainActor private final class EventRecorder { var events: [String] = [] }

    @Test @MainActor func builtInTerminalWindowActionsRunInlineOnMainThread() {
        let recorder = EventRecorder()

        AppKitController.dispatchBuiltInTerminalWindowActionOnMainThread(
            isMainThread: true, scheduler: { _ in recorder.events.append("scheduled") }, action: { recorder.events.append("ran") })

        #expect(recorder.events == ["ran"])
    }

    @Test @MainActor func builtInTerminalWindowActionsScheduleOffMainThread() {
        let recorder = EventRecorder()

        AppKitController.dispatchBuiltInTerminalWindowActionOnMainThread(
            isMainThread: false,
            scheduler: { action in
                recorder.events.append("scheduled")
                MainActor.assumeIsolated { action() }
            }, action: { recorder.events.append("ran") })

        #expect(recorder.events == ["scheduled", "ran"])
    }

    @Test func successfulExternalFocusActionsHideSpaces() {
        #expect(AppKitController.shouldHideAfterSuccessfulExternalWindowAction(true, action: .focus(hidesApp: true)))
    }

    @Test func successfulFocusActionsDelayHideForPulseVisibility() {
        #expect(AppKitController.hideDelayAfterSuccessfulExternalWindowAction(true, action: .focus(hidesApp: true)) == .milliseconds(400))
    }

    @Test func successfulBuiltInFocusActionsDoNotHideSpaces() {
        #expect(!AppKitController.shouldHideAfterSuccessfulExternalWindowAction(true, action: .focus(hidesApp: false)))
    }

    @Test func successfulExternalOpenActionsHideSpaces() {
        #expect(AppKitController.shouldHideAfterSuccessfulExternalWindowAction(true, action: .open(hidesApp: true)))
    }

    @Test func successfulOpenActionsDoNotDelayHide() {
        #expect(AppKitController.hideDelayAfterSuccessfulExternalWindowAction(true, action: .open(hidesApp: true)) == nil)
    }

    @Test func successfulBuiltInOpenActionsDoNotHideSpaces() {
        #expect(!AppKitController.shouldHideAfterSuccessfulExternalWindowAction(true, action: .open(hidesApp: false)))
        #expect(AppKitController.hideDelayAfterSuccessfulExternalWindowAction(true, action: .open(hidesApp: false)) == nil)
    }

    @Test func failedActionsDoNotHideSpaces() {
        #expect(!AppKitController.shouldHideAfterSuccessfulExternalWindowAction(false, action: .focus(hidesApp: true)))
        #expect(!AppKitController.shouldHideAfterSuccessfulExternalWindowAction(false, action: .open(hidesApp: true)))
        #expect(AppKitController.hideDelayAfterSuccessfulExternalWindowAction(false, action: .focus(hidesApp: true)) == nil)
        #expect(AppKitController.hideDelayAfterSuccessfulExternalWindowAction(false, action: .open(hidesApp: true)) == nil)
    }
}
