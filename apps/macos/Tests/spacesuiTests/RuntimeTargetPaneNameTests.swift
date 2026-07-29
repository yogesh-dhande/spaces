import Testing

@testable import spacesui

/// The rule that titles a pane — and through it the tab and the panel window — from the runtime
/// target it belongs to plus the pane's own live title.
@Suite struct RuntimeTargetPaneNameTests {
    @Test func configuredTargetKeepsItsIdentityNameWhateverTheProgramPrints() {
        let name = RuntimeTargetPaneName(title: "npm:dev", pinnedTitle: nil, namesByIdentity: true)
        #expect(RuntimeTargetPaneName.paneTitle(name, liveTitle: "vim main.swift") == "npm:dev")
    }

    /// The overview-derived name for an ad hoc shell is a snapshot of its live title taken on the
    /// overview's poll cadence — and a global panel window never re-reads it — so the pane's own
    /// title, which changes the moment the shell retitles, wins.
    @Test func adHocShellFollowsItsLiveTitleOverTheOverviewSnapshot() {
        let name = RuntimeTargetPaneName(title: "shell-1", pinnedTitle: nil, namesByIdentity: false)
        #expect(RuntimeTargetPaneName.paneTitle(name, liveTitle: "vim main.swift") == "vim main.swift")
    }

    @Test func renamePinsAnAdHocShellNameOverItsLiveTitle() {
        let name = RuntimeTargetPaneName(title: "deploy", pinnedTitle: "deploy", namesByIdentity: false)
        #expect(RuntimeTargetPaneName.paneTitle(name, liveTitle: "vim main.swift") == "deploy")
    }

    /// Clearing the rename un-pins the name, and the pane follows its live title again.
    @Test func clearedRenameHandsTheNameBackToTheLiveTitle() {
        let name = RuntimeTargetPaneName(title: "vim main.swift", pinnedTitle: nil, namesByIdentity: false)
        #expect(RuntimeTargetPaneName.paneTitle(name, liveTitle: "vim main.swift") == "vim main.swift")
    }

    /// A shell whose program cleared its title falls back to the launch-generated name the overview
    /// row carries rather than showing a blank tab.
    @Test func blankLiveTitleFallsBackToTheTargetName() {
        let name = RuntimeTargetPaneName(title: "shell-1", pinnedTitle: nil, namesByIdentity: false)
        #expect(RuntimeTargetPaneName.paneTitle(name, liveTitle: "   ") == "shell-1")
    }

    /// A pane whose session backs no runtime target at all — every workspace terminal row is gone
    /// from the overview — still shows what the terminal itself reports.
    @Test func paneWithoutARuntimeTargetShowsItsOwnTitle() {
        #expect(RuntimeTargetPaneName.paneTitle(nil, liveTitle: "vim main.swift") == "vim main.swift")
    }

    /// Which panels an overview update must re-title. A rename reaches a client only through the
    /// overview, so a global panel window — which no overview update re-renders — has to be re-titled
    /// explicitly; workspace panels are already covered by the workspace-detail path.
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
