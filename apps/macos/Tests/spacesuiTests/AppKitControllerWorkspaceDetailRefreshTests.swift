import AppKit
import Testing
import workspacecore

@testable import spacesui

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
                selectedWorkspaceID: "workspace-1", showingAlerts: false, showingSettings: false, workspaceExists: true))
        #expect(
            !AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: nil, showingAlerts: false, showingSettings: false, workspaceExists: true))
        #expect(
            !AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: "workspace-1", showingAlerts: false, showingSettings: false, workspaceExists: false))
    }

    @Test func visibleWorkspaceDetailRefreshSkipsAlertsAndSettings() {
        #expect(
            !AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: "workspace-1", showingAlerts: true, showingSettings: false, workspaceExists: true))
        #expect(
            !AppKitController.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: "workspace-1", showingAlerts: false, showingSettings: true, workspaceExists: true))
    }

    @Test func configuredBrowserSessionsAlsoShowForStoppedWorkspaces() {
        #expect(AppKitController.shouldShowConfiguredBrowserSessions(workspaceIsRunning: true))
        #expect(AppKitController.shouldShowConfiguredBrowserSessions(workspaceIsRunning: false))
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
