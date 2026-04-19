import AppKit
import Testing
import streamctl

@testable import gui

@MainActor @Suite struct TerminalWindowEditorTests {
    @Test func currentWindowsReturnsConfiguredRows() throws {
        let editor = TerminalWindowEditor()
        editor.setWindows([
            .init(name: "Shell"),
            .init(name: "Logs", command: "tail -f log/development.log"),
        ])

        let windows = try editor.currentWindows()
        #expect(windows.count == 2)
        #expect(windows[0] == .init(name: "Shell"))
        #expect(windows[1] == .init(name: "Logs", command: "tail -f log/development.log"))
    }

    @Test func currentWindowsRequiresNameWhenCommandIsPresent() {
        let editor = TerminalWindowEditor()
        editor.setWindows([.init(name: "", command: "npm run dev")])

        do {
            _ = try editor.currentWindows()
            Issue.record("Expected validation error for missing terminal window name")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            #expect(message.localizedStandardContains("name is required"))
        }
    }
}
