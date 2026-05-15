import Testing
import workspacecore

@testable import spacesui

@Suite struct AppKitControllerRecoveryFeedbackTests {
    @Test func recoveredProcessWindowDetailUsesSpacesWindowLabel() {
        #expect(
            AppKitController.recoveredProcessWindowDetail(title: "frontend", terminalApp: TerminalHost.spaces.appName)
                == "frontend reopened in a new Spaces window.")
    }

    @Test func recoveredProcessWindowDetailUsesGenericTerminalLabelForNonSpacesApps() {
        #expect(
            AppKitController.recoveredProcessWindowDetail(title: "frontend", terminalApp: "Ghostty") == "frontend reopened in a new terminal window.")
        #expect(
            AppKitController.recoveredProcessWindowDetail(title: "frontend", terminalApp: "iTerm2") == "frontend reopened in a new terminal window.")
    }

    @Test func recoveredProcessWindowDetailFallsBackToGenericTerminalWindow() {
        #expect(AppKitController.recoveredProcessWindowDetail(title: "frontend", terminalApp: nil) == "frontend reopened in a new terminal window.")
        #expect(
            AppKitController.recoveredProcessWindowDetail(title: "frontend", terminalApp: "Terminal") == "frontend reopened in a new terminal window."
        )
    }
}
