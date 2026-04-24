import AppKit
import Testing
import streamctl

@testable import gui

@Suite struct AppKitControllerWorkspaceDetailRefreshTests {
    @Test func terminalFallbackRowTextUsesNameAndLiveTitle() {
        let row = AppKitController.terminalFallbackRowText(name: "shell-1", detail: "* zsh", app: "iTerm2")
        #expect(row.label == "shell-1")
        #expect(row.detail == "zsh")
    }

    @Test func terminalFallbackRowTextFallsBackToTerminalLabelWhenNameMissing() {
        let row = AppKitController.terminalFallbackRowText(name: nil, detail: "* zsh", app: "iTerm2")
        #expect(row.label == "Terminal")
        #expect(row.detail == "zsh")
    }

    @Test func terminalFallbackRowTextOmitsDetailWhenTitleMissing() {
        let row = AppKitController.terminalFallbackRowText(name: nil, detail: nil, app: "iTerm2")
        #expect(row.label == "Terminal")
        #expect(row.detail == nil)
    }

    @Test func visibleWorkspaceDetailRefreshRequiresSelectedExistingWorkspace() {
        #expect(
            AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: "workspace-1", showingDashboard: false, showingSettings: false, workspaceExists: true))
        #expect(
            !AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: nil, showingDashboard: false, showingSettings: false, workspaceExists: true))
        #expect(
            !AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: "workspace-1", showingDashboard: false, showingSettings: false, workspaceExists: false))
    }

    @Test func visibleWorkspaceDetailRefreshSkipsDashboardAndSettings() {
        #expect(
            !AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: "workspace-1", showingDashboard: true, showingSettings: false, workspaceExists: true))
        #expect(
            !AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: "workspace-1", showingDashboard: false, showingSettings: true, workspaceExists: true))
    }

    @Test func configuredBrowserSessionsAlsoShowForStoppedWorkspaces() {
        #expect(AppKitController.shouldShowConfiguredBrowserSessions(workspaceIsRunning: true))
        #expect(AppKitController.shouldShowConfiguredBrowserSessions(workspaceIsRunning: false))
    }

    @MainActor @Test func workspaceDetailSectionsKeepBrowserSessionsAheadOfCodingAgents() {
        let processes = NSView()
        let browserSessions = NSView()
        let agentLaunchers = NSView()
        let ports = NSView()
        let stopScript = NSView()

        let sections = AppKitController.orderedWorkspaceDetailSections(
            processesSection: processes, browserSessionsSection: browserSessions, agentLaunchersSection: agentLaunchers, portsSection: ports,
            stopScriptSection: stopScript)

        #expect(sections.count == 5)
        #expect(sections[0] === browserSessions)
        #expect(sections[1] === processes)
        #expect(sections[2] === agentLaunchers)
        #expect(sections[3] === ports)
        #expect(sections[4] === stopScript)
    }

    @Test func workspaceProcessStatusByNameReflectsRuntimeState() {
        let statuses = AppKitController.workspaceProcessStatusByName([
            RunningProcessRecord(
                id: "running", workspaceID: "workspace", templateName: "web", command: "npm run dev", terminalApp: "iTerm2", windowID: 101,
                terminalTrackingID: "session-web", itermTabIndex: nil, tmuxWindowID: nil, pid: 1, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: nil, exitedAt: nil),
            RunningProcessRecord(
                id: "exited", workspaceID: "workspace", templateName: "worker", command: "npm run worker", terminalApp: "iTerm2", windowID: 102,
                terminalTrackingID: "session-worker", itermTabIndex: nil, tmuxWindowID: nil, pid: nil, status: .exited, logPath: nil,
                lastOutputAt: nil, startedAt: nil, exitedAt: nil),
        ])

        #expect(statuses["web"] == RowPrimitives.StatusKind.running)
        #expect(statuses["worker"] == RowPrimitives.StatusKind.exited)
    }

}
