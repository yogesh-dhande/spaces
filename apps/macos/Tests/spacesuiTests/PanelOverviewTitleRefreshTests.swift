import Testing

@testable import spacesui

/// Which panels an overview update has to re-title. Panels are titled from their panes' names, and a
/// name changes only when the user renames it — which reaches this client in an overview and nowhere
/// else.
@Suite struct PanelOverviewTitleRefreshTests {
    /// A global panel window stands in its own window that no overview update re-renders, so it has to
    /// be re-titled explicitly; workspace panels are already covered by the workspace-detail path.
    @Test func onlyGlobalPanelWindowsNeedRetitlingOnAnOverviewUpdate() {
        let scopes: Set<PanelScope> = [
            .workspace(deviceID: "device-1", workspaceID: "workspace-1"), .workspace(deviceID: "device-2", workspaceID: "workspace-2"),
            .globalWindow(panelWindowID: "panel-b"), .globalWindow(panelWindowID: "panel-a"),
        ]
        #expect(PanelCoordinator.globalPanelWindowIDsNeedingOverviewTitleRefresh(scopes) == ["panel-a", "panel-b"])
    }

    @Test func aClientWithNoGlobalPanelHasNothingToRetitle() {
        #expect(
            PanelCoordinator.globalPanelWindowIDsNeedingOverviewTitleRefresh([.workspace(deviceID: "device-1", workspaceID: "workspace-1")]).isEmpty)
    }
}
