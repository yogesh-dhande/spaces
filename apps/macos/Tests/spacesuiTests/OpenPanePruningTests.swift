import Foundation
import Testing

@testable import spacesui

@Suite struct OpenPanePruningTests {
    private func pane(_ device: String, _ session: String) -> OpenPanePruning.OpenPane {
        OpenPanePruning.OpenPane(deviceID: device, sessionID: session)
    }

    /// Restoring a workspace panel between a restart's stop and its replacement's open must keep the pane
    /// being held. The stop deleted the predecessor's row, so the overview cannot carry it, and pruning it
    /// would leave the replacement with nothing to claim: it would append at the end of the tab strip and
    /// the user's saved tab and split position would be gone. This is the ordinary case for a CLI or MCP
    /// restart, whose workspace panel is usually first materialized by the replacement's own open.
    @Test func restorationKeepsAPaneHeldForAReplacement() {
        // Stands in for the overview after the stop: it no longer references the predecessor.
        let overviewKeepSet = OpenPanePruning.restorationKeepSet(overview: nil)

        let keepSet = OpenPanePruning.restorationKeepSet(overview: nil, heldForReplacementSessionIDs: ["predecessor"])

        #expect(!overviewKeepSet.contains("predecessor"))
        #expect(keepSet.contains("predecessor"))
    }

    /// The held pane surviving restoration is what lets the replacement claim its slot: the predecessor's
    /// pane is still in the restored layout, in its original tab, for `retargetPane` to point at the new
    /// session. Without the hold it is pruned and the slot is lost.
    @Test func aHeldPaneSurvivesRestorationSoTheReplacementCanClaimItsSlot() {
        var layout = PanelLayoutEngine.appendTab(
            tabID: "tab-1", pane: Pane(id: "a", content: .terminalSession(deviceID: "local", sessionID: "predecessor")), to: PanelLayout())
        layout = PanelLayoutEngine.appendTab(
            tabID: "tab-2", pane: Pane(id: "b", content: .terminalSession(deviceID: "local", sessionID: "other")), to: layout)

        let withoutHold = PanelLayoutEngine.prunedLayout(
            layout, keepingSessionIDs: OpenPanePruning.restorationKeepSet(overview: nil, heldForReplacementSessionIDs: []).union(["other"]))
        let withHold = PanelLayoutEngine.prunedLayout(
            layout,
            keepingSessionIDs: OpenPanePruning.restorationKeepSet(overview: nil, heldForReplacementSessionIDs: ["predecessor"]).union(["other"]))

        #expect(PanelLayoutEngine.orderedTerminalSessionIDs(in: withoutHold) == ["other"])
        #expect(withHold.tabs.map(\.id) == ["tab-1", "tab-2"])
        let claimed = PanelLayoutEngine.retargetPane(paneID: "a", to: .terminalSession(deviceID: "local", sessionID: "replacement"), in: withHold)
        #expect(PanelLayoutEngine.orderedTerminalSessionIDs(in: claimed) == ["replacement", "other"])
    }

    /// A global panel window waits for every device its panes reference, so a restart during that wait is
    /// where a hold has to survive longest. Its multi-device keep-set honors holds the same way the
    /// workspace one does, or the pane would be pruned the moment the offline device returned.
    @Test func globalWindowRestorationKeepsAPaneHeldForAReplacement() {
        let overviewsOnly = OpenPanePruning.restorationKeepSet(overviews: [nil, nil])

        let keepSet = OpenPanePruning.restorationKeepSet(overviews: [nil, nil], heldForReplacementSessionIDs: ["predecessor"])

        #expect(!overviewsOnly.contains("predecessor"))
        #expect(keepSet.contains("predecessor"))
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
