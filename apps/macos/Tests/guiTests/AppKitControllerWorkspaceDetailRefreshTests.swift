import AppKit
import Testing

@testable import gui

@Suite struct AppKitControllerWorkspaceDetailRefreshTests {
    @Test func terminalFallbackRowTextUsesTerminalNameAndShellDetail() {
        let row = AppKitController.terminalFallbackRowText(title: "* zsh", app: "iTerm2")
        #expect(row.label == "Terminal")
        #expect(row.detail == "zsh")
    }

    @Test func terminalFallbackRowTextOmitsDetailWhenTitleMissing() {
        let row = AppKitController.terminalFallbackRowText(title: nil, app: "iTerm2")
        #expect(row.label == "Terminal")
        #expect(row.detail == nil)
    }

    @Test func visibleWorkspaceDetailRefreshRequiresSelectedExistingWorkspace() {
        #expect(
            AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: "workspace-1",
                showingDashboard: false,
                showingSettings: false,
                workspaceExists: true))
        #expect(
            !AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: nil,
                showingDashboard: false,
                showingSettings: false,
                workspaceExists: true))
        #expect(
            !AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: "workspace-1",
                showingDashboard: false,
                showingSettings: false,
                workspaceExists: false))
    }

    @Test func visibleWorkspaceDetailRefreshSkipsDashboardAndSettings() {
        #expect(
            !AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: "workspace-1",
                showingDashboard: true,
                showingSettings: false,
                workspaceExists: true))
        #expect(
            !AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: "workspace-1",
                showingDashboard: false,
                showingSettings: true,
                workspaceExists: true))
    }

    @Test func restoredWorkspaceDetailTabIdentifierDefaultsToRunForUnknownSelection() {
        #expect(AppKitController.restoredWorkspaceDetailTabIdentifier(savedIdentifier: nil) == "run")
        #expect(AppKitController.restoredWorkspaceDetailTabIdentifier(savedIdentifier: "run") == "run")
        #expect(AppKitController.restoredWorkspaceDetailTabIdentifier(savedIdentifier: "unknown") == "run")
    }

    @Test func restoredWorkspaceDetailTabIdentifierKeepsEnvAndSettingsTabs() {
        #expect(AppKitController.restoredWorkspaceDetailTabIdentifier(savedIdentifier: "env") == "env")
        #expect(AppKitController.restoredWorkspaceDetailTabIdentifier(savedIdentifier: "settings") == "settings")
    }

    @MainActor @Test func selectedWorkspaceDetailTabIdentifierFindsNestedSelectedTab() {
        let container = NSView()
        let nested = NSView()
        let tabs = NSTabView()
        let runTab = NSTabViewItem(identifier: "run")
        runTab.label = "Run"
        runTab.view = NSView()
        let settingsTab = NSTabViewItem(identifier: "settings")
        settingsTab.label = "Settings"
        settingsTab.view = NSView()
        tabs.addTabViewItem(runTab)
        tabs.addTabViewItem(settingsTab)
        tabs.selectTabViewItem(settingsTab)
        nested.addSubview(tabs)
        container.addSubview(nested)

        #expect(AppKitController.selectedWorkspaceDetailTabIdentifier(in: container) == "settings")
    }

}
