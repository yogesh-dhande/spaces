import Foundation
import Testing
import spacesdevicecore

@testable import spacesui

/// A workspace whose owning device the sidebar cannot name (no loaded section claims it) has no
/// overview: `AppKitController.overview(forWorkspaceID:)` returns nil rather than substituting the
/// local device's overview. These cover the pure builders every such call site feeds that nil into,
/// pinning the contract that an unknown owner yields "nothing to act on" instead of an answer
/// computed from this Mac's rows.
@Suite struct UnknownOwningDeviceWorkspaceTests {
    @Test func paneOpenRequestForAnUnknownOverviewIsRefused() {
        // Panel restore and the terminal-open IPC build their request from the owning daemon's
        // overview. With no overview there is no launch configuration to open the session with, so
        // no pane opens — rather than one built from a same-id session on this Mac.
        #expect(AppKitController.deviceTerminalOpenRequest(workspaceID: "workspace", sessionID: "session", overview: nil) == nil)
    }

    @Test func browserSessionTeardownForAnUnknownOverviewClosesNothing() {
        // Stop/restart/archive close the workspace's configured browser tabs. An unknown overview
        // lists no configured sessions, so teardown closes no Chrome tabs — closing the ones the
        // local overview happens to configure would tear down another workspace's tabs.
        #expect(BrowserSessionCoordinator.browserSessionTargetURLs(workspaceID: "workspace", overview: nil).isEmpty)
    }

    @Test func browserFocusForAnUnknownOverviewHasNoSiblingTabs() {
        // Focus dedupes a session's tab against its workspace's sibling URLs. With no overview the
        // only known URL is the one the focus request carried, so there are no siblings to exclude.
        let targetURL = "http://localhost:3000"
        let targetURLs = BrowserSessionCoordinator.browserSessionTargetURLs(workspaceID: "workspace", targetURL: targetURL, overview: nil)

        #expect(targetURLs == [targetURL])
        #expect(BrowserSessionCoordinator.browserSessionSiblingTargetURLs(targetURL: targetURL, targetURLs: targetURLs).isEmpty)
    }

    @Test func sessionPickerForAnUnknownOverviewListsNoRuntimeTargets() {
        // The picker's runtime-target rows come from the scoped workspaces' overviews. An unknown
        // owner contributes no scope, leaving only the workspace-agnostic "New terminal session"
        // row — no other device's targets leak in through a substituted local overview.
        let presentation = AppKitController.sessionPickerPresentation(
            newTerminalWorkspaceID: "workspace", newTerminalOverview: nil, scopedWorkspaces: [], openSessionIDs: [])

        #expect(presentation.items.map(\.id) == ["picker:new"])
        #expect(presentation.items.map(\.workspaceTitle) == ["workspace"])
    }
}
