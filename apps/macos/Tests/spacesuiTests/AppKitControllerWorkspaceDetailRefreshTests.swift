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

    /// Codex round 5 (P1) on issue #438: `isRunning` turns true the instant an ad hoc terminal or agent
    /// session starts, independent of whether any configured process is actually running, so gating Start
    /// purely on `isRunning` hides it exactly in the state where it is the right (non-destructive) action.
    @Test func workspaceLifecycleControlsOfferStartWheneverConfiguredRuntimeIsMissing() {
        // Stopped: Start is offered regardless of the missing count (matches today's behavior).
        #expect(AppKitController.workspaceLifecycleControlsOfferStart(isRunning: false, missingConfiguredProcessCount: 0))
        #expect(AppKitController.workspaceLifecycleControlsOfferStart(isRunning: false, missingConfiguredProcessCount: 1))
        // Running with every configured process up: Start stays hidden, matching today's behavior.
        #expect(!AppKitController.workspaceLifecycleControlsOfferStart(isRunning: true, missingConfiguredProcessCount: 0))
        // Running from ad hoc/agent runtime alone, with a configured process still missing: Start must be
        // offered instead of forcing the user through the destructive Restart action.
        #expect(AppKitController.workspaceLifecycleControlsOfferStart(isRunning: true, missingConfiguredProcessCount: 1))
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
        let matchedURL = BrowserSessionCoordinator.matchedBrowserSessionShortcutURL(
            configuredSession: BrowserSession(name: "frontend url", url: "http://localhost:$FRONTEND_PORT"),
            rawURL: "http://localhost:$FRONTEND_PORT", resolvedSessions: [BrowserSession(name: "frontend url", url: "http://localhost:3000")],
            resolvedSessionCursor: &resolvedCursor, shortcutIndicesByURL: ["http://localhost:3000": 1])

        #expect(matchedURL == "http://localhost:3000")
        #expect(resolvedCursor == 0, "Named match should not consume the sequential fallback cursor")
    }

    @MainActor @Test func browserSessionDisplayURLsPreferResolvedValues() {
        let displayURLs = BrowserSessionCoordinator.browserSessionDisplayURLs(
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
        var pane = DetailPane.workspace(id: "workspace-1", deviceID: "device-1")
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

        pane = .workspace(id: "workspace-2", deviceID: "device-1")
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
    // the Alerts list, a sidebar reload rebuilding the selected workspace's detail. Dismissing the open
    // New Project / New Workspace / project settings window there would throw away input the user is in
    // the middle of typing, so a refresh never dismisses.
    @Test func backgroundRefreshOfTheVisiblePaneKeepsFormWindows() {
        #expect(!AppKitController.detailPanePresentationDismissesFormWindows(current: .alerts, presented: .alerts, presentation: .backgroundRefresh))
        #expect(
            !AppKitController.detailPanePresentationDismissesFormWindows(
                current: .workspace(id: "workspace-1", deviceID: "device-1"), presented: .workspace(id: "workspace-1", deviceID: "device-1"),
                presentation: .backgroundRefresh))
    }

    // The refresh paths change pane content on their own: a remote device turning wire-incompatible
    // swaps in its compatibility block, recovery clears the pane, a failed reload swaps in the error
    // placeholder, and a selected workspace deleted elsewhere drops the pane to the placeholder. None of
    // those are the user navigating, so none may dismiss a form window — which is why the rule reads the
    // caller's intent instead of inferring it from the content having changed.
    @Test func backgroundRefreshThatChangesPaneContentKeepsFormWindows() {
        #expect(
            !AppKitController.detailPanePresentationDismissesFormWindows(
                current: .workspace(id: "workspace-1", deviceID: "device-1"), presented: .compatibilityBlock(deviceID: "device-1"),
                presentation: .backgroundRefresh), "A device turning wire-incompatible must not close a dialog")
        #expect(
            !AppKitController.detailPanePresentationDismissesFormWindows(
                current: .compatibilityBlock(deviceID: "device-1"), presented: .none, presentation: .backgroundRefresh),
            "A device recovering must not close a dialog")
        #expect(
            !AppKitController.detailPanePresentationDismissesFormWindows(current: .alerts, presented: .none, presentation: .backgroundRefresh),
            "A failed reload's placeholder must not close a dialog")
        #expect(
            !AppKitController.detailPanePresentationDismissesFormWindows(
                current: .workspace(id: "workspace-1", deviceID: "device-1"), presented: .none, presentation: .backgroundRefresh),
            "A selected workspace deleted elsewhere must not close a dialog")
    }

    @Test func userNavigationToDifferentPaneContentDismissesFormWindows() {
        #expect(
            AppKitController.detailPanePresentationDismissesFormWindows(
                current: .alerts, presented: .workspace(id: "workspace-1", deviceID: "device-1"), presentation: .userNavigation))
        #expect(
            AppKitController.detailPanePresentationDismissesFormWindows(
                current: .workspace(id: "workspace-1", deviceID: "device-1"), presented: .alerts, presentation: .userNavigation))
        #expect(
            AppKitController.detailPanePresentationDismissesFormWindows(
                current: .workspace(id: "workspace-1", deviceID: "device-1"), presented: .workspace(id: "workspace-2", deviceID: "device-1"),
                presentation: .userNavigation))
        #expect(
            AppKitController.detailPanePresentationDismissesFormWindows(
                current: .compatibilityBlock(deviceID: "device-1"), presented: .compatibilityBlock(deviceID: "device-2"),
                presentation: .userNavigation))
        #expect(AppKitController.detailPanePresentationDismissesFormWindows(current: .alerts, presented: .none, presentation: .userNavigation))
    }

    // Clicking the Alerts row while Alerts is already showing, or re-selecting the selected workspace,
    // moves nothing out from under the dialog, so it stays open.
    // The workspace pane's footer strip is rebuilt from scratch on every refresh that reaches it, and
    // refreshes arrive many times a second while a coding agent streams, so the Launch/Stop/notes
    // buttons were being destroyed between mouse-down and mouse-up. The signature is what decides
    // whether a refresh redraws them, so it has to carry everything the strip shows and nothing that
    // moves on its own.
    private func footerSignature(
        workspaceID: String = "workspace-1", displayName: String = "feature", branch: String = "feature", directory: String = "/tmp/feature",
        notes: String = "", isLifecycleRunning: Bool = true, isRunning: Bool = true, offersStart: Bool = false, warningSummary: String? = nil,
        deviceAcceptsDaemonActions: Bool = true, unreachableDeviceTooltip: String? = nil
    ) -> AppKitController.WorkspaceDetailFooterSignature {
        AppKitController.WorkspaceDetailFooterSignature(
            workspaceID: workspaceID, displayName: displayName, branch: branch, directory: directory, notes: notes,
            isLifecycleRunning: isLifecycleRunning, isRunning: isRunning, offersStart: offersStart, warningSummary: warningSummary,
            deviceAcceptsDaemonActions: deviceAcceptsDaemonActions, unreachableDeviceTooltip: unreachableDeviceTooltip)
    }

    @Test func anUnchangedWorkspaceLeavesTheFooterStripAlone() { #expect(footerSignature() == footerSignature()) }

    /// Each of these draws or removes a control, a label, or its dimming, so each has to redraw the strip.
    @Test func everythingTheFooterDrawsIsPartOfItsSignature() {
        let rendered = footerSignature()

        #expect(footerSignature(workspaceID: "workspace-2") != rendered)
        #expect(footerSignature(displayName: "renamed") != rendered)
        #expect(footerSignature(branch: "other") != rendered)
        #expect(footerSignature(directory: "/tmp/other") != rendered)
        #expect(footerSignature(notes: "check the flake") != rendered)
        #expect(footerSignature(isLifecycleRunning: false) != rendered, "the status dot follows the lifecycle state")
        #expect(footerSignature(isRunning: false) != rendered, "a stopped workspace offers Launch alone, with no Stop button")
        #expect(
            footerSignature(offersStart: true) != rendered,
            "Start becomes reachable alongside Restart/Stop when a configured process is missing (issue #438)")
        #expect(footerSignature(warningSummary: "1 process exited") != rendered)
        #expect(footerSignature(deviceAcceptsDaemonActions: false) != rendered, "an unreachable device's controls are disabled and dimmed")
        #expect(footerSignature(unreachableDeviceTooltip: "linux-box is offline") != rendered)
    }

    @Test func userNavigationToTheSamePaneKeepsFormWindows() {
        #expect(!AppKitController.detailPanePresentationDismissesFormWindows(current: .alerts, presented: .alerts, presentation: .userNavigation))
        #expect(
            !AppKitController.detailPanePresentationDismissesFormWindows(
                current: .workspace(id: "workspace-1", deviceID: "device-1"), presented: .workspace(id: "workspace-1", deviceID: "device-1"),
                presentation: .userNavigation))
    }

}
