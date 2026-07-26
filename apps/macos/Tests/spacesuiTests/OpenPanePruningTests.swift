import Foundation
import Testing

@testable import spacesui

@Suite struct OpenPanePruningTests {
    private func pane(_ device: String, _ session: String) -> OpenPanePruning.OpenPane {
        OpenPanePruning.OpenPane(deviceID: device, sessionID: session)
    }

    @Test func closesSessionAbsentFromCatalog() {
        let panes = [pane("local", "sess-a"), pane("local", "sess-b")]
        // sess-b's product row was removed, so the catalog no longer lists it.
        let toClose = OpenPanePruning.sessionsToClose(openPanes: panes, deviceID: "local", catalogSessionIDs: ["sess-a"])
        #expect(toClose == ["sess-b"])
    }

    @Test func keepsSessionStillInCatalog() {
        // An ended session that keeps its product row stays in the catalog and must not close —
        // that is the ended-pane scrollback feature.
        let panes = [pane("local", "ended-but-present")]
        let toClose = OpenPanePruning.sessionsToClose(
            openPanes: panes, deviceID: "local", catalogSessionIDs: ["ended-but-present"])
        #expect(toClose.isEmpty)
    }

    @Test func emptyAuthoritativeCatalogClosesAllPanesForThatDevice() {
        // An online device that reports zero sessions is authoritative: every open pane it owns closes.
        let panes = [pane("local", "sess-a"), pane("local", "sess-b")]
        let toClose = OpenPanePruning.sessionsToClose(openPanes: panes, deviceID: "local", catalogSessionIDs: [])
        #expect(Set(toClose) == ["sess-a", "sess-b"])
    }

    @Test func neverClosesPanesOwnedByOtherDevices() {
        // The arriving overview is authoritative only for `local`; a remote device's panes are
        // untouched even though its sessions are absent from this device's catalog.
        let panes = [pane("local", "sess-a"), pane("remote", "sess-r")]
        let toClose = OpenPanePruning.sessionsToClose(openPanes: panes, deviceID: "local", catalogSessionIDs: ["sess-a"])
        #expect(toClose.isEmpty)
    }

    @Test func prunesOnlyTheArrivingDeviceEvenWhenBothHaveGoneSessions() {
        let panes = [pane("local", "gone-local"), pane("remote", "gone-remote")]
        // The local overview arrives lacking gone-local, but the remote pane is left for the
        // remote device's own authoritative overview to decide.
        let toClose = OpenPanePruning.sessionsToClose(openPanes: panes, deviceID: "local", catalogSessionIDs: [])
        #expect(toClose == ["gone-local"])
    }

    @Test func noOpenPanesClosesNothing() {
        #expect(OpenPanePruning.sessionsToClose(openPanes: [], deviceID: "local", catalogSessionIDs: []).isEmpty)
    }
}
