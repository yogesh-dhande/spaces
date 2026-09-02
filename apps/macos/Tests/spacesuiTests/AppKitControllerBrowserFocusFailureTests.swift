import Testing
import systembridge

@testable import spacesui

/// Covers the message shown when a workspace browser-session focus fails because Chrome could
/// not be scripted. Workspace browser sessions are Chrome-only, so a failure is reported instead
/// of silently redirecting to another browser; a denied Automation permission is named
/// specifically since it is the one cause the user can fix themselves.
@Suite struct AppKitControllerBrowserFocusFailureTests {
    @Test func deniedPermissionNamesChromeAndSystemSettings() {
        let message = BrowserSessionCoordinator.browserSessionFocusFailureMessage(automationStatus: .denied)
        #expect(message.contains("Google Chrome"))
        #expect(message.contains("System Settings"))
        #expect(message.contains("Automation"))
    }

    @Test func grantedNotDeterminedAndUnavailableShareThePlainMessageWithNoSystemSettingsMention() {
        for status: ChromeAutomationStatus in [.granted, .notDetermined, .unavailable] {
            let message = BrowserSessionCoordinator.browserSessionFocusFailureMessage(automationStatus: status)
            #expect(message.contains("Google Chrome"))
            #expect(!message.contains("System Settings"))
        }
    }

    /// Every Finder reveal entry point reports a refused reveal through one message, so the
    /// keyboard shortcut, the detail Reveal button, and the sidebar row menu cannot drift apart.
    @Test func finderRevealFailureNamesTheDirectoryAndFinder() {
        let message = AppKitController.finderRevealFailureMessage(path: "/Users/someone/code/harbor")
        #expect(message.contains("/Users/someone/code/harbor"))
        #expect(message.contains("Finder"))
    }

    @Test func everyVariantNamesChromeAndNoOtherBrowser() {
        for status: ChromeAutomationStatus in [.denied, .granted, .notDetermined, .unavailable] {
            let message = BrowserSessionCoordinator.browserSessionFocusFailureMessage(automationStatus: status)
            #expect(message.contains("Google Chrome"))
            for otherBrowser in ["Safari", "Firefox", "Edge", "Arc"] { #expect(!message.contains(otherBrowser)) }
        }
    }
}
