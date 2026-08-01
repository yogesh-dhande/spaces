import AppKit
import Testing
import workspacecore

@testable import spacesui

@Suite struct AppKitControllerWorkspaceDetailRefreshTests {
    @Test func terminalFallbackRowTextUsesNameAndLiveTitle() {
        let row = AppKitController.terminalFallbackRowText(name: "shell-1", detail: "* zsh", app: "Spaces")
        #expect(row.label == "shell-1")
        #expect(row.detail == "zsh")
    }

    @Test func terminalFallbackRowTextFallsBackToTerminalLabelWhenNameMissing() {
        let row = AppKitController.terminalFallbackRowText(name: nil, detail: "* zsh", app: "Spaces")
        #expect(row.label == "Terminal")
        #expect(row.detail == "zsh")
    }

    @Test func terminalFallbackRowTextOmitsDetailWhenTitleMissing() {
        let row = AppKitController.terminalFallbackRowText(name: nil, detail: nil, app: "Spaces")
        #expect(row.label == "Terminal")
        #expect(row.detail == nil)
    }

    @Test func visibleWorkspaceDetailRefreshRequiresSelectedExistingWorkspace() {
        #expect(
            AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: "workspace-1", showingAlerts: false, showingSettings: false, workspaceExists: true, mainWindowIsFocused: true,
                commandPaletteIsVisible: false))
        #expect(
            !AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: nil, showingAlerts: false, showingSettings: false, workspaceExists: true, mainWindowIsFocused: true,
                commandPaletteIsVisible: false))
        #expect(
            !AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: "workspace-1", showingAlerts: false, showingSettings: false, workspaceExists: false, mainWindowIsFocused: true,
                commandPaletteIsVisible: false))
    }

    @Test func visibleWorkspaceDetailRefreshSkipsAlertsAndSettings() {
        #expect(
            !AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: "workspace-1", showingAlerts: true, showingSettings: false, workspaceExists: true, mainWindowIsFocused: true,
                commandPaletteIsVisible: false))
        #expect(
            !AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: "workspace-1", showingAlerts: false, showingSettings: true, workspaceExists: true, mainWindowIsFocused: true,
                commandPaletteIsVisible: false))
    }

    @Test func visibleWorkspaceDetailRefreshRequiresForegroundSurface() {
        #expect(
            !AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: "workspace-1", showingAlerts: false, showingSettings: false, workspaceExists: true, mainWindowIsFocused: false,
                commandPaletteIsVisible: false))
        #expect(
            AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: "workspace-1", showingAlerts: false, showingSettings: false, workspaceExists: true, mainWindowIsFocused: false,
                commandPaletteIsVisible: true))
    }

    @Test func configuredBrowserSessionsAlsoShowForStoppedWorkspaces() {
        #expect(AppKitController.shouldShowConfiguredBrowserSessions(workspaceIsRunning: true))
        #expect(AppKitController.shouldShowConfiguredBrowserSessions(workspaceIsRunning: false))
    }

    @Test func workspaceSetupPanelReplacesNormalDetailUntilSetupSucceeds() {
        #expect(AppKitController.shouldShowWorkspaceSetupPanel(status: .pending))
        #expect(AppKitController.shouldShowWorkspaceSetupPanel(status: .running))
        #expect(AppKitController.shouldShowWorkspaceSetupPanel(status: .failed))
        #expect(!AppKitController.shouldShowWorkspaceSetupPanel(status: .succeeded))
    }

    @Test func workspaceSetupScriptEditorOnlyShowsForFailedSetup() {
        #expect(!AppKitController.shouldShowWorkspaceSetupScriptEditor(status: .pending))
        #expect(!AppKitController.shouldShowWorkspaceSetupScriptEditor(status: .running))
        #expect(AppKitController.shouldShowWorkspaceSetupScriptEditor(status: .failed))
        #expect(!AppKitController.shouldShowWorkspaceSetupScriptEditor(status: .succeeded))
    }

    @Test func workspaceSetupPanelStatusesSkipNormalWorkspaceDetailRefresh() {
        #expect(!AppKitController.shouldRequestNormalWorkspaceDetailRefresh(setupStatus: .pending))
        #expect(!AppKitController.shouldRequestNormalWorkspaceDetailRefresh(setupStatus: .running))
        #expect(!AppKitController.shouldRequestNormalWorkspaceDetailRefresh(setupStatus: .failed))
        #expect(AppKitController.shouldRequestNormalWorkspaceDetailRefresh(setupStatus: .succeeded))
    }

    @MainActor @Test func browserSessionShortcutMatchingFallsBackToResolvedURLForTemplatedSession() {
        var resolvedCursor = 0
        let matchedURL = AppKitController.matchedBrowserSessionShortcutURL(
            configuredSession: BrowserSession(name: "frontend url", url: "http://localhost:$FRONTEND_PORT"),
            rawURL: "http://localhost:$FRONTEND_PORT", resolvedSessions: [BrowserSession(name: "frontend url", url: "http://localhost:3000")],
            resolvedSessionCursor: &resolvedCursor, shortcutIndicesByURL: ["http://localhost:3000": 1])

        #expect(matchedURL == "http://localhost:3000")
        #expect(resolvedCursor == 0, "Named match should not consume the sequential fallback cursor")
    }

    @MainActor @Test func browserSessionDisplayURLsPreferResolvedValues() {
        let displayURLs = AppKitController.browserSessionDisplayURLs(
            configuredSessions: [BrowserSession(name: "frontend url", url: "http://localhost:$FRONTEND_PORT")],
            resolvedSessions: [BrowserSession(name: "frontend url", url: "http://localhost:3000")])

        #expect(displayURLs == ["http://localhost:3000"])
    }

    @MainActor @Test func inlineEditorSlotKeepsEditorExpandedToAvailableWidth() {
        let label = NSTextField(labelWithString: "default")
        let editor = NSTextField(string: "default")
        label.isHidden = true

        let slot = AppKitController.makeInlineEditorSlot(label: label, editor: editor)
        let button = NSButton(title: "Save", target: nil, action: nil)

        let row = NSStackView(views: [NSView(), slot, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 60))
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor), row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor),
        ])
        slot.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        host.layoutSubtreeIfNeeded()

        #expect(editor.frame.width >= 120)
        #expect(abs(editor.frame.width - slot.bounds.width) < 0.5)
    }

    @Test func workspaceProcessStatusByNameReflectsRuntimeState() {
        let statuses = AppKitController.workspaceProcessStatusByName([
            RunningProcessRecord(
                id: "running", workspaceID: "workspace", templateName: "web", command: "npm run dev", terminalApp: "Spaces",
                terminalTrackingID: "session-web", pid: 1, status: .running, logPath: nil, lastOutputAt: nil, startedAt: nil, exitedAt: nil),
            RunningProcessRecord(
                id: "exited", workspaceID: "workspace", templateName: "worker", command: "npm run worker", terminalApp: "Spaces",
                terminalTrackingID: "session-worker", pid: nil, status: .exited, logPath: nil, lastOutputAt: nil, startedAt: nil, exitedAt: nil),
        ])

        #expect(statuses["web"] == RowPrimitives.StatusKind.running)
        #expect(statuses["worker"] == RowPrimitives.StatusKind.exited)
    }

    // The detail pane shows exactly one content at a time. `DetailPane` is the single source of truth the
    // controller's `visibleDetailWorkspaceID` / `showingAlerts` / `visibleCompatibilityBlockDeviceID`
    // shims read, so asserting the pane's facets asserts the single-pane invariant those shims expose.
    // Settings is intentionally not a pane case: it floats over whatever pane is shown, so it stays a
    // separate flag and is not cleared by presenting a pane.
    @Test func presentingAPaneReplacesThePreviousPanesFacets() {
        var pane = DetailPane.workspace(id: "workspace-1")
        #expect(pane.workspaceID == "workspace-1")
        #expect(!pane.isAlerts)
        #expect(pane.compatibilityBlockDeviceID == nil)

        pane = .alerts
        #expect(pane.isAlerts)
        #expect(pane.workspaceID == nil, "Presenting alerts clears the visible workspace")
        #expect(pane.compatibilityBlockDeviceID == nil)

        pane = .compatibilityBlock(deviceID: "device-1")
        #expect(pane.compatibilityBlockDeviceID == "device-1")
        #expect(!pane.isAlerts, "Presenting the compatibility block clears alerts")
        #expect(pane.workspaceID == nil)

        pane = .workspace(id: "workspace-2")
        #expect(pane.workspaceID == "workspace-2")
        #expect(pane.compatibilityBlockDeviceID == nil, "Presenting a workspace clears the compatibility block")
        #expect(!pane.isAlerts)
    }

    @Test func detailPaneNoneClearsEveryFacet() {
        let pane = DetailPane.none
        #expect(pane.workspaceID == nil)
        #expect(!pane.isAlerts)
        #expect(pane.compatibilityBlockDeviceID == nil)
    }

    // A background refresh re-presents the pane that is already showing — an overview tick rebuilding
    // the Alerts list, a sidebar reload rebuilding the selected workspace's detail. That re-render must
    // not be treated as navigation, because navigation dismisses the open New Project / New Workspace /
    // Project Settings windows, and a dialog the user is filling in has to survive every refresh.
    @Test func rePresentingTheVisiblePaneIsNotNavigation() {
        #expect(!AppKitController.detailPanePresentationIsNavigation(current: .alerts, presented: .alerts))
        #expect(
            !AppKitController.detailPanePresentationIsNavigation(current: .workspace(id: "workspace-1"), presented: .workspace(id: "workspace-1")))
        #expect(
            !AppKitController.detailPanePresentationIsNavigation(
                current: .compatibilityBlock(deviceID: "device-1"), presented: .compatibilityBlock(deviceID: "device-1")))
        #expect(!AppKitController.detailPanePresentationIsNavigation(current: .none, presented: .none))
    }

    @Test func presentingDifferentPaneContentIsNavigation() {
        #expect(AppKitController.detailPanePresentationIsNavigation(current: .alerts, presented: .workspace(id: "workspace-1")))
        #expect(AppKitController.detailPanePresentationIsNavigation(current: .workspace(id: "workspace-1"), presented: .alerts))
        #expect(AppKitController.detailPanePresentationIsNavigation(current: .workspace(id: "workspace-1"), presented: .workspace(id: "workspace-2")))
        #expect(
            AppKitController.detailPanePresentationIsNavigation(
                current: .compatibilityBlock(deviceID: "device-1"), presented: .compatibilityBlock(deviceID: "device-2")))
        #expect(AppKitController.detailPanePresentationIsNavigation(current: .none, presented: .alerts))
        #expect(AppKitController.detailPanePresentationIsNavigation(current: .alerts, presented: .none))
    }

}
