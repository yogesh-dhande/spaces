import Testing
import workspacecore

@testable import spacesui

@Suite struct AppKitControllerRecoveryFeedbackTests {
    @Test func recoveredProcessWindowDetailUsesSpacesWindowLabel() {
        #expect(
            AppKitController.recoveredProcessWindowDetail(title: "frontend", terminalApp: TerminalHost.spaces.appName)
                == "frontend reopened in a new Spaces window.")
    }

    @Test func recoveredProcessWindowDetailUsesExplicitExternalHostLabels() {
        #expect(
            AppKitController.recoveredProcessWindowDetail(title: "frontend", terminalApp: TerminalHost.ghostty.appName)
                == "frontend reopened in a new Ghostty window.")
        #expect(
            AppKitController.recoveredProcessWindowDetail(title: "frontend", terminalApp: TerminalHost.iterm2.appName)
                == "frontend reopened in a new iTerm2 window.")
    }

    @Test func recoveredProcessWindowDetailFallsBackToGenericTerminalWindow() {
        #expect(AppKitController.recoveredProcessWindowDetail(title: "frontend", terminalApp: nil) == "frontend reopened in a new terminal window.")
        #expect(
            AppKitController.recoveredProcessWindowDetail(title: "frontend", terminalApp: "Terminal") == "frontend reopened in a new terminal window."
        )
    }
}
