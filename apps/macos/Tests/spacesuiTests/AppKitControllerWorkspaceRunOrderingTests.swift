import Testing
import spacesclientcore
import spacesdevicecore
import workspacecore

@testable import spacesui

@Suite struct AppKitControllerWorkspaceRunOrderingTests {
    @Test func configuredProcessesKeepSettingsOrderBeforeExtraWindows() {
        let configuredProcesses = [ProcessTemplate(name: "api", command: "run api"), ProcessTemplate(name: "web", command: "run web")]
        let windows = [
            WindowRecord(
                id: "win-web", workspaceID: "workspace", app: "Spaces", title: "web", targetURL: nil, terminalTrackingID: "session-web",
                role: "terminal", orderIndex: 200, lastSeenAt: "now"),
            WindowRecord(
                id: "win-api", workspaceID: "workspace", app: "Spaces", title: "api", targetURL: nil, terminalTrackingID: "session-api",
                role: "terminal", orderIndex: 201, lastSeenAt: "now"),
            WindowRecord(
                id: "win-shell", workspaceID: "workspace", app: "Spaces", title: "* zsh", targetURL: nil, terminalTrackingID: "session-shell",
                role: "terminal", orderIndex: 202, lastSeenAt: "now"),
        ]
        let processes = [
            RunningProcessRecord(
                id: "process-web", workspaceID: "workspace", templateName: "web", command: "run web", terminalApp: "Spaces",
                terminalTrackingID: "session-web", pid: 2, status: .running, logPath: nil, lastOutputAt: nil, startedAt: nil, exitedAt: nil),
            RunningProcessRecord(
                id: "process-api", workspaceID: "workspace", templateName: "api", command: "run api", terminalApp: "Spaces",
                terminalTrackingID: "session-api", pid: 1, status: .running, logPath: nil, lastOutputAt: nil, startedAt: nil, exitedAt: nil),
        ]

        let entries = AppKitController.orderedWorkspaceRunProcessEntries(
            configuredProcesses: configuredProcesses, windows: windows, processes: processes, agentWindows: [])

        #expect(entries.map(\.kind) == [.process, .process, .window])
        #expect(entries.map(\.processID) == ["process-api", "process-web", nil])
        #expect(entries.map(\.windowListIndex) == [nil, nil, 2])
    }

    @Test func missingConfiguredProcessesKeepVisibleRecoveryRowInSettingsOrder() {
        let configuredProcesses = [ProcessTemplate(name: "api", command: "run api"), ProcessTemplate(name: "web", command: "run web")]
        let windows = [
            WindowRecord(
                id: "win-web", workspaceID: "workspace", app: "Spaces", title: "web", targetURL: nil, terminalTrackingID: "session-web",
                role: "terminal", orderIndex: 200, lastSeenAt: "now")
        ]
        let processes = [
            RunningProcessRecord(
                id: "process-web", workspaceID: "workspace", templateName: "web", command: "run web", terminalApp: "Spaces",
                terminalTrackingID: "session-web", pid: 2, status: .running, logPath: nil, lastOutputAt: nil, startedAt: nil, exitedAt: nil)
        ]

        let entries = AppKitController.orderedWorkspaceRunProcessEntries(
            configuredProcesses: configuredProcesses, windows: windows, processes: processes, agentWindows: [])

        #expect(entries.map(\.kind) == [.missingConfiguredProcess, .process])
        #expect(entries.map(\.processKey) == ["api", "web"])
        #expect(entries.map(\.processID) == [nil, "process-web"])
        #expect(entries.first?.processLabel == "api")
        #expect(entries.first?.processCommand == "run api")
    }

    @Test func recoveredConfiguredProcessClaimsExistingRow() {
        let configuredProcesses = [ProcessTemplate(name: "web server", command: "PORT=20003 npm run dev")]
        let windows = [
            WindowRecord(
                id: "win-web", workspaceID: "workspace", app: "Spaces", title: "web server", targetURL: nil, terminalTrackingID: "session-web",
                role: "terminal", orderIndex: 200, lastSeenAt: "now")
        ]
        let processes = [
            RunningProcessRecord(
                id: "process-web", workspaceID: "workspace", templateName: "web server", command: "PORT=20003 npm run dev", terminalApp: "Spaces",
                terminalTrackingID: "session-web", pid: 2, status: .running, logPath: nil, lastOutputAt: nil, startedAt: nil, exitedAt: nil)
        ]

        let entries = AppKitController.orderedWorkspaceRunProcessEntries(
            configuredProcesses: configuredProcesses, windows: windows, processes: processes, agentWindows: [])

        #expect(entries.count == 1)
        #expect(entries.first?.kind == .process)
        #expect(entries.first?.processKey == "web server")
        #expect(entries.first?.processLabel == "web server")
    }

    @Test func literalPrefixedProcessNamesStillMatchRunningProcessRows() {
        let configuredProcesses = [ProcessTemplate(name: "name:api", command: "npm run api")]
        let windows = [
            WindowRecord(
                id: "win-api", workspaceID: "workspace", app: "Spaces", title: "name:api", targetURL: nil, terminalTrackingID: "session-api",
                role: "terminal", orderIndex: 200, lastSeenAt: "now")
        ]
        let processes = [
            RunningProcessRecord(
                id: "process-api", workspaceID: "workspace", templateName: "name:api", command: "npm run api", terminalApp: "Spaces",
                terminalTrackingID: "session-api", pid: 2, status: .running, logPath: nil, lastOutputAt: nil, startedAt: nil, exitedAt: nil)
        ]

        let entries = AppKitController.orderedWorkspaceRunProcessEntries(
            configuredProcesses: configuredProcesses, windows: windows, processes: processes, agentWindows: [])

        #expect(entries.count == 1)
        #expect(entries.first?.kind == .process)
        #expect(entries.first?.processKey == "name:api")
        #expect(entries.first?.processLabel == "name:api")
    }

    @Test func agentClaimedTerminalRowsAreExcludedFromProcessOrdering() {
        let configuredProcesses = [ProcessTemplate(name: "api", command: "run api")]
        let windows = [
            WindowRecord(
                id: "win-agent", workspaceID: "workspace", app: "Spaces", title: "agent", targetURL: nil, terminalTrackingID: "session-agent",
                role: "terminal", orderIndex: 200, lastSeenAt: "now"),
            WindowRecord(
                id: "win-api", workspaceID: "workspace", app: "Spaces", title: "api", targetURL: nil, terminalTrackingID: "session-api",
                role: "terminal", orderIndex: 201, lastSeenAt: "now"),
        ]
        let processes = [
            RunningProcessRecord(
                id: "process-api", workspaceID: "workspace", templateName: "api", command: "run api", terminalApp: "Spaces",
                terminalTrackingID: "session-api", pid: 1, status: .running, logPath: nil, lastOutputAt: nil, startedAt: nil, exitedAt: nil),
            RunningProcessRecord(
                id: "process-agent", workspaceID: "workspace", templateName: "agent", command: "run agent", terminalApp: "Spaces",
                terminalTrackingID: "session-agent", pid: 2, status: .running, logPath: nil, lastOutputAt: nil, startedAt: nil, exitedAt: nil),
        ]
        let agentWindows = [
            AgentWindowRecord(
                id: "agent", workspaceID: "workspace", provider: .spaces, label: "Agent", terminalTrackingID: "session-agent", sessionKey: nil,
                status: .spinning, createdAt: "now", updatedAt: "now")
        ]

        let entries = AppKitController.orderedWorkspaceRunProcessEntries(
            configuredProcesses: configuredProcesses, windows: windows, processes: processes, agentWindows: agentWindows)

        #expect(entries.count == 1)
        #expect(entries.first?.kind == .process)
        #expect(entries.first?.processID == "process-api")
    }

    @Test func spacesAgentClaimedManualTerminalRowIsExcludedFromProcessOrdering() {
        let configuredProcesses = [ProcessTemplate(name: "web", command: "run web")]
        let windows = [
            WindowRecord(
                id: "win-web", workspaceID: "workspace", app: "Spaces", title: "web", targetURL: nil, terminalTrackingID: "spaces-web",
                role: "terminal", orderIndex: 200, lastSeenAt: "now"),
            WindowRecord(
                id: "win-shell", workspaceID: "workspace", app: "Spaces", title: "shell-1", targetURL: nil, terminalTrackingID: "spaces-spaces-token",
                role: "terminal", orderIndex: 201, lastSeenAt: "now"),
        ]
        let processes = [
            RunningProcessRecord(
                id: "process-web", workspaceID: "workspace", templateName: "web", command: "run web", terminalApp: "Spaces",
                terminalTrackingID: "spaces-web", pid: 1, status: .running, logPath: nil, lastOutputAt: nil, startedAt: nil, exitedAt: nil)
        ]
        let agentWindows = [
            AgentWindowRecord(
                id: "agent", workspaceID: "workspace", provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "spaces-spaces-token",
                sessionKey: nil, status: .idle, createdAt: "now", updatedAt: "now")
        ]

        let entries = AppKitController.orderedWorkspaceRunProcessEntries(
            configuredProcesses: configuredProcesses, windows: windows, processes: processes, agentWindows: agentWindows)

        #expect(entries.count == 1, "entries: \(entries)")
        #expect(entries.first?.kind == .process)
        #expect(entries.first?.processID == "process-web")
    }

    @Test func spacesAgentClaimedTerminalRowIsExcludedWhenWindowOnlyHasHookToken() {
        let configuredProcesses = [ProcessTemplate(name: "web", command: "run web")]
        let windows = [
            WindowRecord(
                id: "win-web", workspaceID: "workspace", app: "Spaces", name: "web", detail: nil, targetURL: nil, terminalTrackingID: "spaces-web",
                role: "terminal", orderIndex: 200, lastSeenAt: "now"),
            WindowRecord(
                id: "win-shell", workspaceID: "workspace", app: "Spaces", name: "shell-1", detail: nil, targetURL: nil,
                terminalTrackingID: "spaces-spaces-hook", role: "terminal", orderIndex: 201, lastSeenAt: "now"),
        ]
        let processes = [
            RunningProcessRecord(
                id: "process-web", workspaceID: "workspace", templateName: "web", command: "run web", terminalApp: "Spaces",
                terminalTrackingID: "spaces-web", pid: 1, status: .running, logPath: nil, lastOutputAt: nil, startedAt: nil, exitedAt: nil)
        ]
        let agentWindows = [
            AgentWindowRecord(
                id: "agent", workspaceID: "workspace", provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "spaces-spaces-hook",
                sessionKey: nil, status: .idle, createdAt: "now", updatedAt: "now")
        ]

        let entries = AppKitController.orderedWorkspaceRunProcessEntries(
            configuredProcesses: configuredProcesses, windows: windows, processes: processes, agentWindows: agentWindows)

        #expect(entries.count == 1)
        #expect(entries.first?.kind == .process)
        #expect(entries.first?.processID == "process-web")
    }

    @Test func demotedAdHocSpacesTerminalReturnsToProcessOrderingAsWindow() {
        let windows = [
            WindowRecord(
                id: "win-shell", workspaceID: "workspace", app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                terminalTrackingID: "spaces-session", role: "terminal", orderIndex: 200, lastSeenAt: "now")
        ]

        let entries = AppKitController.orderedWorkspaceRunProcessEntries(configuredProcesses: [], windows: windows, processes: [], agentWindows: [])

        #expect(entries.count == 1)
        #expect(entries.first?.kind == .window)
        #expect(entries.first?.windowListIndex == 0)
    }

    @Test func preferredTerminalWindowsByTrackingKeyKeepsLowestOrderWhenKeysCollide() {
        let windows = [
            WindowRecord(
                id: "win-newer", workspaceID: "workspace", app: "Spaces", name: "shell-2", detail: "newer", targetURL: nil,
                terminalTrackingID: "spaces-hook", role: "terminal", orderIndex: 205, lastSeenAt: "now"),
            WindowRecord(
                id: "win-older", workspaceID: "workspace", app: "Spaces", name: "shell-1", detail: "older", targetURL: nil,
                terminalTrackingID: "spaces-hook", role: "terminal", orderIndex: 201, lastSeenAt: "now"),
        ]

        let linkedWindows = AppKitController.preferredTerminalWindowsByTrackingKey(windows)

        #expect(linkedWindows["terminal:spaces-hook"]?.id == "win-older")
    }

    @Test func shortcutTargetsFollowVisibleRunSectionOrder() {
        let configuredProcesses = [ProcessTemplate(name: "web", command: "npm run dev")]
        let browserSessions = [BrowserSession(name: "frontend", url: "http://localhost:3000")]
        let windows = [
            WindowRecord(
                id: "win-web", workspaceID: "workspace", app: "Spaces", title: "web", targetURL: nil, terminalTrackingID: "session-web",
                role: "terminal", orderIndex: 200, lastSeenAt: "now")
        ]
        let processes = [
            RunningProcessRecord(
                id: "process-web", workspaceID: "workspace", templateName: "web", command: "npm run dev", terminalApp: "Spaces",
                terminalTrackingID: "session-web", pid: 1, status: .running, logPath: nil, lastOutputAt: nil, startedAt: nil, exitedAt: nil)
        ]
        let agentWindows = [
            AgentWindowRecord(
                id: "agent", workspaceID: "workspace", provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "session-agent",
                sessionKey: nil, status: .spinning, createdAt: "now", updatedAt: "now")
        ]

        let processEntries = AppKitController.orderedWorkspaceRunProcessEntries(
            configuredProcesses: configuredProcesses, windows: windows, processes: processes, agentWindows: agentWindows)
        let shortcutTargets = AppKitController.orderedWorkspaceRunShortcutTargets(
            browserSessions: browserSessions, processEntries: processEntries,
            processesByID: Dictionary(uniqueKeysWithValues: processes.map { ($0.id, $0) }), agentWindows: agentWindows)
        let runtimeIndex = AppKitController.workspaceRuntimeTargetIndex(
            browserSessions: browserSessions, processEntries: processEntries,
            processesByID: Dictionary(uniqueKeysWithValues: processes.map { ($0.id, $0) }), agentWindows: agentWindows)

        #expect(shortcutTargets.map(\.kind) == [.browser, .process, .agent])
        #expect(runtimeIndex.orderedTargets.map(\.kind) == shortcutTargets.map(\.kind))
        #expect(shortcutTargets.first?.targetURL == "http://localhost:3000")
        #expect(shortcutTargets[1].processID == "process-web")
        #expect(shortcutTargets[2].agentWindow?.id == "agent")
        #expect(runtimeIndex.targetsByURL["http://localhost:3000"]?.kind == .browser)
        #expect(runtimeIndex.targetsByProcessID["process-web"]?.kind == .process)
        #expect(runtimeIndex.targetsByTerminalSessionID["session-web"]?.processID == "process-web")
        #expect(runtimeIndex.targetsByAgentID["agent"]?.kind == .agent)
    }

    /// Every coding-agent row is a live agent window: the run order lists exactly those, in the order
    /// the daemon reports them, and never a not-started row.
    @Test func runOrderingListsOnlyLiveAgents() {
        let agentWindows = [
            AgentWindowRecord(
                id: "claude", workspaceID: "workspace", provider: .spaces, label: "claude",
                terminalTarget: TerminalTargetRecord(trackingID: "session-claude"), status: .idle, createdAt: "now", updatedAt: "now"),
            AgentWindowRecord(
                id: "adhoc", workspaceID: "workspace", provider: .spaces, label: "reviewer", terminalTrackingID: "session-reviewer", sessionKey: nil,
                status: .spinning, createdAt: "now", updatedAt: "now"),
        ]

        let shortcutTargets = AppKitController.orderedWorkspaceRunShortcutTargets(
            browserSessions: [], processEntries: [], processesByID: [:], agentWindows: agentWindows)

        #expect(shortcutTargets.map(\.kind) == [.agent, .agent])
        #expect(shortcutTargets.map { $0.agentWindow?.id } == ["claude", "adhoc"])
    }

    @Test func workspaceDetailShortcutIndicesFollowLiveRuntimeOrder() {
        let browserSessions = [BrowserSession(name: "docs", url: "http://localhost:3000")]
        let configuredProcesses = [ProcessTemplate(name: "web", command: "npm run dev")]
        let agentWindows = [
            AgentWindowRecord(
                id: "agent-claude", workspaceID: "workspace", provider: .spaces, label: "claude", terminalTrackingID: "session-claude",
                sessionKey: nil, status: .idle, createdAt: "now", updatedAt: "now")
        ]
        let windows = [
            WindowRecord(
                id: "win-web", workspaceID: "workspace", app: "Spaces", name: "web", detail: "npm run dev", targetURL: nil,
                terminalTrackingID: "session-web", role: "terminal", orderIndex: 200, lastSeenAt: "now"),
            WindowRecord(
                id: "win-shell", workspaceID: "workspace", app: "Spaces", name: nil, detail: "* zsh", targetURL: nil,
                terminalTrackingID: "session-shell", role: "terminal", orderIndex: 201, lastSeenAt: "now"),
        ]
        let processes = [
            RunningProcessRecord(
                id: "process-web", workspaceID: "workspace", templateName: "web", command: "npm run dev", terminalApp: "Spaces",
                terminalTrackingID: "session-web", pid: 1, status: .running, logPath: nil, lastOutputAt: nil, startedAt: nil, exitedAt: nil)
        ]
        let processEntries = AppKitController.orderedWorkspaceRunProcessEntries(
            configuredProcesses: configuredProcesses, windows: windows, processes: processes, agentWindows: [])
        let shortcutIndices = AppKitController.workspaceDetailShortcutIndices(
            browserSessions: browserSessions, processEntries: processEntries,
            processesByID: Dictionary(uniqueKeysWithValues: processes.map { ($0.id, $0) }), agentWindows: agentWindows)

        // Families are ordered browser, processes, coding agents, ad hoc terminals — so the agent takes the
        // index right after the process, and the terminal window is pushed behind it.
        #expect(shortcutIndices.browserSessionsByURL["http://localhost:3000"] == 1)
        #expect(shortcutIndices.processesByName["web"] == 2)
        #expect(shortcutIndices.codingAgentsByName["claude"] == 3)
        #expect(shortcutIndices.codingAgentsByIdentity[AppKitController.codingAgentShortcutIdentity(agentWindowID: "agent-claude")] == 3)
    }

    @Test func unlabeledAgentRowsStillReceiveShortcutIdentity() {
        let agentWindows = [
            AgentWindowRecord(
                id: "agent-unlabeled", workspaceID: "workspace", provider: .spaces, label: nil, terminalTrackingID: "spaces-hook-1", sessionKey: nil,
                status: .waiting, createdAt: "now", updatedAt: "now")
        ]

        let shortcutIndices = AppKitController.workspaceDetailShortcutIndices(
            browserSessions: [], processEntries: [], processesByID: [:], agentWindows: agentWindows)

        #expect(shortcutIndices.codingAgentsByIdentity[AppKitController.codingAgentShortcutIdentity(agentWindowID: "agent-unlabeled")] == 1)
    }

    @Test func missingConfiguredProcessShortcutTargetsRecoveryAction() {
        let processEntries = [
            AppKitController.WorkspaceRunProcessEntry(
                kind: .missingConfiguredProcess, processID: nil, windowListIndex: nil, processKey: "api", processLabel: "api",
                processCommand: "run api")
        ]

        let shortcutTargets = AppKitController.orderedWorkspaceRunShortcutTargets(
            browserSessions: [], processEntries: processEntries, processesByID: [:], agentWindows: [])

        #expect(shortcutTargets.count == 1)
        #expect(shortcutTargets.first?.kind == .missingConfiguredProcess)
        #expect(shortcutTargets.first?.processKey == "api")
    }

    @Test func cycleTargetsIncludeOnlyOpenBrowserWindowsAndOpenTerminalPanes() {
        let detail = SpacesDeviceWorkspaceDetailViewModel(workspace: cycleFilteringWorkspace())

        let withoutOpenBrowser = AppKitController.cycleWindowTargets(
            detail: detail, browserSessions: [], openTerminalSessionIDs: ["session-web", "session-agent"])
        #expect(withoutOpenBrowser.map(\.kind) == [.process, .agent])
        #expect(withoutOpenBrowser.map { AppKitController.cycleCursorKey(for: $0, detail: detail) } == ["process:process-web", "agent:agent-1"])

        let withOpenBrowserAndShell = AppKitController.cycleWindowTargets(
            detail: detail, browserSessions: [BrowserSession(name: "docs", url: "http://localhost:3000")],
            openTerminalSessionIDs: ["session-web", "session-shell", "session-agent"])
        #expect(withOpenBrowserAndShell.map(\.kind) == [.browser, .process, .agent, .window])
        #expect(
            withOpenBrowserAndShell.map { AppKitController.cycleCursorKey(for: $0, detail: detail) } == [
                "browser:http://localhost:3000", "process:process-web", "agent:agent-1", "terminal:session-shell",
            ])
    }

    @Test func remoteRoutedBrowserSessionCountsAsOpenForCycle() {
        let sessions = [SpacesDeviceBrowserSession(name: "docs", url: "http://localhost:32001/docs")]
        let assignedPorts = [SpacesDeviceAssignedPort(name: "web", port: 32001, url: "http://web.feature-123.localhost:9000")]
        let routedURL = "http://web.feature-123.localhost:7391/docs"

        let openSessions = AppKitController.openBrowserSessionsForCycle(
            resolvedSessions: sessions, assignedPorts: assignedPorts, trackedTargetURLs: [routedURL], openTabURLs: [routedURL])

        #expect(openSessions.map(\.name) == ["docs"])
        #expect(openSessions.map(\.url) == ["http://localhost:32001/docs"])
    }

    @Test func remoteRoutedBrowserSessionMatchingExcludesLongerSiblingTargets() {
        let rootURL = "http://localhost:32001"
        let adminURL = "http://localhost:32001/admin"
        let assignedPorts = [SpacesDeviceAssignedPort(name: "web", port: 32001, url: "http://web.feature-123.localhost:9000")]
        let configuredTargetURLs = [rootURL, adminURL]
        let rootSiblings = AppKitController.browserSessionSiblingTargetURLs(targetURL: rootURL, targetURLs: configuredTargetURLs)
        let adminSiblings = AppKitController.browserSessionSiblingTargetURLs(targetURL: adminURL, targetURLs: configuredTargetURLs)
        let observedAdminURL = "http://web.feature-123.localhost:7391/admin/users"

        #expect(
            !AppKitController.browserObservedURL(
                observedAdminURL, matchesBrowserSessionTargetURL: rootURL, excluding: rootSiblings, assignedPorts: assignedPorts))
        #expect(
            AppKitController.browserObservedURL(
                observedAdminURL, matchesBrowserSessionTargetURL: adminURL, excluding: adminSiblings, assignedPorts: assignedPorts))
    }

    @Test func browserSessionPrefixMatchingSkipsLongerSiblingTargets() {
        let targetURL = "http://localhost:3000"
        let siblingTargetURLs = AppKitController.browserSessionSiblingTargetURLs(
            targetURL: targetURL, targetURLs: ["http://localhost:3000", "http://localhost:3000/admin", "http://localhost:3000/admin"])

        #expect(siblingTargetURLs == ["http://localhost:3000/admin"])
        #expect(AppKitController.browserTabURL("http://localhost:3000/", matchesBrowserSessionTargetURL: targetURL, excluding: siblingTargetURLs))
        #expect(AppKitController.browserTabURL("http://localhost:3000/docs", matchesBrowserSessionTargetURL: targetURL, excluding: siblingTargetURLs))
        #expect(
            !AppKitController.browserTabURL("http://localhost:3000/admin", matchesBrowserSessionTargetURL: targetURL, excluding: siblingTargetURLs))
        #expect(
            !AppKitController.browserTabURL(
                "http://localhost:3000/admin/users", matchesBrowserSessionTargetURL: targetURL, excluding: siblingTargetURLs))
        #expect(AppKitController.browserTabURL("http://localhost:3000/admin", matchesBrowserSessionTargetURL: siblingTargetURLs[0], excluding: []))
    }

    @Test func rootBrowserSessionDoesNotMatchOnlyOpenAdminSiblingTab() {
        let rootURL = "http://localhost:3000"
        let adminURL = "http://localhost:3000/admin"
        let configuredTargetURLs = [rootURL, adminURL]
        let openTabURLs = [adminURL]

        let rootSiblings = AppKitController.browserSessionSiblingTargetURLs(targetURL: rootURL, targetURLs: configuredTargetURLs)
        let adminSiblings = AppKitController.browserSessionSiblingTargetURLs(targetURL: adminURL, targetURLs: configuredTargetURLs)

        #expect(!openTabURLs.contains { AppKitController.browserTabURL($0, matchesBrowserSessionTargetURL: rootURL, excluding: rootSiblings) })
        #expect(openTabURLs.contains { AppKitController.browserTabURL($0, matchesBrowserSessionTargetURL: adminURL, excluding: adminSiblings) })
    }

    @Test func focusRequestsUseConfiguredBrowserSessionSiblingsForPrefixExclusion() {
        let rootURL = "http://localhost:3000"
        let adminURL = "http://localhost:3000/admin"
        let workspace = SpacesDeviceWorkspaceSummary(
            id: "workspace", projectID: "project", projectName: "Project", branch: "feature", baseBranch: "main", dir: "/tmp/project-feature",
            isRunning: true, isHidden: false, isDefault: false, sessionCount: 0,
            config: SpacesDeviceWorkspaceConfig(resolvedBrowserSessions: [
                SpacesDeviceBrowserSession(name: "root", url: rootURL), SpacesDeviceBrowserSession(name: "admin", url: adminURL),
            ]))
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project", name: "Project", dir: "/tmp/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [workspace], sessions: [])

        let targetURLs = AppKitController.browserSessionTargetURLs(workspaceID: "workspace", targetURL: rootURL, overview: overview)
        let rootSiblings = AppKitController.browserSessionSiblingTargetURLs(targetURL: rootURL, targetURLs: targetURLs)

        #expect(targetURLs == [rootURL, adminURL])
        #expect(rootSiblings == [adminURL])
        #expect(!AppKitController.browserTabURL(adminURL, matchesBrowserSessionTargetURL: rootURL, excluding: rootSiblings))
    }

    @Test func trackedBrowserSessionTargetMatchingAcceptsTrailingSlashOnlyDifference() {
        #expect(AppKitController.browserSessionTargetURL("http://localhost:3000/", matches: "http://localhost:3000"))
        #expect(AppKitController.browserSessionTargetURL("http://localhost:3000", matches: "http://localhost:3000/"))
        #expect(!AppKitController.browserSessionTargetURL("http://localhost:3000/admin", matches: "http://localhost:3000"))
    }

    @Test func teardownSiblingExclusionsIncludeConfiguredButUntrackedBrowserSessions() {
        let rootURL = "http://localhost:3000"
        let adminURL = "http://localhost:3000/admin"
        let teardownTargetURLs = AppKitController.browserSessionTeardownTargetURLs(
            configuredTargetURLs: [rootURL, adminURL], trackedTargetURLs: [rootURL])
        let rootSiblings = AppKitController.browserSessionSiblingTargetURLs(targetURL: rootURL, targetURLs: teardownTargetURLs)

        #expect(teardownTargetURLs == [rootURL, adminURL])
        #expect(rootSiblings == [adminURL])
        #expect(!AppKitController.browserTabURL(adminURL, matchesBrowserSessionTargetURL: rootURL, excluding: rootSiblings))
    }

    @Test func numberedShortcutResolutionStillOpensUnopenedTargets() {
        let workspace = cycleFilteringWorkspace()
        let overview = SpacesDeviceOverviewPayload(
            projects: [SpacesDeviceProjectSummary(id: "project", name: "Project", dir: "/tmp/project", isGitRepo: true, defaultBranch: "main")],
            workspaces: [workspace], sessions: [])

        #expect(
            AppKitController.deviceWindowShortcutResolution(index: 1, selectedWorkspaceID: "workspace", overview: overview)
                == .openURL(workspaceID: "workspace", targetURL: "http://localhost:3000"))
        #expect(
            AppKitController.deviceWindowShortcutResolution(index: 3, selectedWorkspaceID: "workspace", overview: overview)
                == .runProcess(workspaceID: "workspace", processKey: "api", processTemplateID: "tpl-api"))
        // Order is browser(1), web(2), api(3), claude agent(4), shell terminal(5): the live agent sits after
        // the processes and ahead of the ad hoc terminal.
        #expect(
            AppKitController.deviceWindowShortcutResolution(index: 4, selectedWorkspaceID: "workspace", overview: overview)
                == .openTerminal(
                    AppKitController.DeviceTerminalOpenRequest(
                        workspaceID: "workspace", sessionID: "session-agent", title: "claude", workingDirectory: "/tmp/project-feature", kind: .agent)
                ))
    }

    @Test func doneAndWaitingAgentsRemainAlertsAttentionItems() {
        let agents = [
            AgentWindowRecord(
                id: "agent-waiting", workspaceID: "workspace", provider: .spaces, label: "Waiting", terminalTrackingID: "session-1", sessionKey: nil,
                status: .waiting, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:01:00Z"),
            AgentWindowRecord(
                id: "agent-done", workspaceID: "workspace", provider: .spaces, label: "Done", terminalTrackingID: "session-2", sessionKey: nil,
                status: .done, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:02:00Z"),
            AgentWindowRecord(
                id: "agent-idle", workspaceID: "workspace", provider: .spaces, label: "Idle", terminalTrackingID: "session-3", sessionKey: nil,
                status: .idle, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:03:00Z"),
        ]

        let attentionAgents = AppKitController.alertsAttentionAgentWindows(agents)

        #expect(attentionAgents.map(\.id) == ["agent-waiting", "agent-done"])
    }

    private func cycleFilteringWorkspace() -> SpacesDeviceWorkspaceSummary {
        let config = SpacesDeviceWorkspaceConfig(
            processes: [
                SpacesDeviceProcessTemplate(id: "tpl-web", name: "web", command: "npm run dev"),
                SpacesDeviceProcessTemplate(id: "tpl-api", name: "api", command: "npm run api"),
            ], resolvedBrowserSessions: [SpacesDeviceBrowserSession(name: "docs", url: "http://localhost:3000")])
        return SpacesDeviceWorkspaceSummary(
            id: "workspace", projectID: "project", projectName: "Project", branch: "feature", baseBranch: "main", dir: "/tmp/project-feature",
            isRunning: true, isHidden: false, isDefault: false, sessionCount: 3, config: config,
            processRows: [
                SpacesDeviceWorkspaceProcessRow(
                    id: "row-web", workspaceID: "workspace", name: "web", command: "npm run dev", templateID: "tpl-web", processID: "process-web",
                    sessionID: "session-web", runState: .running, canRun: false, canStop: true, canRestart: true),
                SpacesDeviceWorkspaceProcessRow(
                    id: "row-api", workspaceID: "workspace", name: "api", command: "npm run api", templateID: "tpl-api", processID: nil,
                    sessionID: nil, runState: .notStarted, canRun: true, canStop: false, canRestart: false),
            ],
            codingAgentRows: [
                SpacesDeviceWorkspaceCodingAgentRow(
                    id: "agent:agent-1", workspaceID: "workspace", name: "claude", command: "claude", agentID: "agent-1", sessionID: "session-agent",
                    runState: .running, activityState: .idle, canStop: true)
            ],
            terminalRows: [
                SpacesDeviceWorkspaceTerminalRow(
                    id: "row-shell", workspaceID: "workspace", title: "shell", workingDirectory: "/tmp/project-feature", sessionID: "session-shell",
                    runState: .running, canOpenTerminal: true, canStop: true)
            ])
    }
}
