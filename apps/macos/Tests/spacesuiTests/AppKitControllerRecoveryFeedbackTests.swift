import Testing
import workspacecore

@testable import spacesui

@Suite struct AppKitControllerRecoveryFeedbackTests {
    @Test func recoveredProcessWindowDetailUsesSpacesWindowLabel() {
        #expect(
            AppKitController.recoveredProcessWindowDetail(title: "frontend", terminalApp: TerminalHost.spaces.appName)
                == "frontend reopened in a new Spaces window.")
    }

    @Test func recoveredProcessWindowDetailUsesSpacesWindowLabelWithoutStoredApp() {
        #expect(AppKitController.recoveredProcessWindowDetail(title: "frontend", terminalApp: nil) == "frontend reopened in a new Spaces window.")
    }
}
