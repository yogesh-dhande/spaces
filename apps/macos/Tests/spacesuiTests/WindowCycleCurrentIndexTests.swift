import Foundation
import Testing
import spacesclientcore
import spacesdevicecore
import workspacecore

@testable import spacesui

/// Covers which candidate a rotation is standing on when the frontmost Chrome tab is what resolves
/// it, and two workspaces configured the same target URL so the URL alone cannot tell them apart.
@Suite struct WindowCycleCurrentIndexTests {
    private let sharedURL = "http://localhost:3000"

    @Test func theWorkspaceTrackingTheFrontmostChromeWindowIsTheCurrentTarget() {
        let targets = twoWorkspacesSharingATargetURL()

        let currentIndex = WindowFocusController.cycleCurrentIndex(
            targets: targets, focusedTerminalSessionID: nil, frontmostBrowserURL: sharedURL, frontmostBrowserWindowID: 22, cursor: nil)

        // Window 22 is the second workspace's, so that is where the user is standing, even though the
        // first workspace's session matches the same URL just as well.
        #expect(currentIndex == 1)
        #expect(targets[1].workspaceID == "w2")
    }

    @Test func withoutAFrontmostWindowIDTheURLMatchDecidesAlone() {
        let targets = twoWorkspacesSharingATargetURL()

        let currentIndex = WindowFocusController.cycleCurrentIndex(
            targets: targets, focusedTerminalSessionID: nil, frontmostBrowserURL: sharedURL, frontmostBrowserWindowID: nil, cursor: nil)

        #expect(currentIndex == 0)
    }

    @Test func aFrontmostWindowNoWorkspaceTracksLeavesTheCursorDeciding() {
        let targets = twoWorkspacesSharingATargetURL()

        let currentIndex = WindowFocusController.cycleCurrentIndex(
            targets: targets, focusedTerminalSessionID: nil, frontmostBrowserURL: sharedURL, frontmostBrowserWindowID: 99,
            cursor: targets[1].cursorKey)

        // Chrome's front window belongs to neither workspace (a window the user opened by hand), so
        // every URL match stays in play and the remembered cursor still decides.
        #expect(currentIndex == 1)
    }

    // MARK: - Fixtures

    /// Two workspaces on one device whose only open window is a browser session on the same target
    /// URL, each with its own tracked Chrome window.
    private func twoWorkspacesSharingATargetURL() -> [WindowCycleTarget] {
        let device = WindowCycleDeviceSnapshot(
            deviceID: "mac", overview: SpacesDeviceOverviewPayload(workspaces: [workspace(id: "w1"), workspace(id: "w2")], sessions: []))
        let session = BrowserSession(name: "docs", url: sharedURL)
        return WindowCycleModeTargets.targets(
            mode: .openSessions, devices: [device], openTerminalSessionIDsByWorkspace: [:],
            openBrowserSessionsByWorkspace: ["w1": [session], "w2": [session]], trackedBrowserWindowIDsByWorkspace: ["w1": [11], "w2": [22]],
            dismissedAlertIDs: [], recentCursors: [], retaining: [])
    }

    private func workspace(id: String) -> SpacesDeviceWorkspaceSummary {
        SpacesDeviceWorkspaceSummary(
            id: id, projectID: "project", projectName: "Project", branch: id, baseBranch: "main", dir: "/tmp/\(id)", isRunning: true, isHidden: false,
            isDefault: false, hasTrackedRuntimeIndicators: false,
            config: SpacesDeviceWorkspaceConfig(resolvedBrowserSessions: [SpacesDeviceBrowserSession(name: "docs", url: sharedURL)]),
            codingAgentRows: [], terminalRows: [])
    }
}
