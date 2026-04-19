import XCTest

@testable import streamctl

final class TerminalTrackingKeyTests: XCTestCase {
    func testGhosttyProcessPrefersWindowTrackingKey() {
        let process = RunningProcessRecord(
            id: UUID().uuidString,
            workspaceID: "workspace",
            templateName: "web",
            command: "npm run dev",
            terminalApp: "Ghostty",
            windowID: 559,
            itermSessionID: "ghostty-terminal-2",
            itermTabIndex: nil,
            tmuxWindowID: nil,
            pid: 1234,
            status: .running,
            logPath: nil,
            lastOutputAt: nil,
            startedAt: "now",
            exitedAt: nil)

        XCTAssertEqual(process.terminalTrackingKey, "window:559")
    }

    func testItermProcessPrefersSessionTrackingKey() {
        let process = RunningProcessRecord(
            id: UUID().uuidString,
            workspaceID: "workspace",
            templateName: "web",
            command: "npm run dev",
            terminalApp: "iTerm2",
            windowID: 559,
            itermSessionID: "session-2",
            itermTabIndex: nil,
            tmuxWindowID: nil,
            pid: 1234,
            status: .running,
            logPath: nil,
            lastOutputAt: nil,
            startedAt: "now",
            exitedAt: nil)

        XCTAssertEqual(process.terminalTrackingKey, "terminal:session-2")
    }

    func testGhosttyWindowPrefersWindowTrackingKey() {
        let window = WindowRecord(
            id: UUID().uuidString,
            workspaceID: "workspace",
            app: "Ghostty",
            title: "web",
            targetURL: nil,
            windowID: 559,
            itermSessionID: "ghostty-terminal-2",
            itermTabIndex: nil,
            tmuxWindowID: nil,
            role: "terminal",
            orderIndex: 200,
            lastSeenAt: "now")

        XCTAssertEqual(window.terminalTrackingKey, "window:559")
    }
}
