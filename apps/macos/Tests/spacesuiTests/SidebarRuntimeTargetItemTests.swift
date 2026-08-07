import Testing
import spacesclientcore
import spacesdevicecore
import workspacecore

@testable import spacesui

@Suite struct SidebarRuntimeTargetItemTests {
    /// A workspace with one of everything: an open browser session, a running configured
    /// process, a configured-but-not-running process, an ad hoc terminal, and a live coding agent.
    private func fixtureDetail() -> SpacesDeviceWorkspaceDetailViewModel {
        let config = SpacesDeviceWorkspaceConfig(
            processes: [
                SpacesDeviceProcessTemplate(id: "tpl-web", name: "web", command: "npm run dev"),
                SpacesDeviceProcessTemplate(id: "tpl-api", name: "api", command: "npm run api"),
            ], browserSessions: [SpacesDeviceBrowserSession(name: "App", url: "http://localhost:$PORT")],
            resolvedBrowserSessions: [SpacesDeviceBrowserSession(name: "App", url: "http://localhost:3000")])
        let summary = SpacesDeviceWorkspaceSummary(
            id: "workspace", projectID: "project", projectName: "project", branch: "main", baseBranch: nil, dir: "/tmp/workspace", isRunning: true,
            isHidden: false, isDefault: false, sessionCount: 3, config: config,
            processRows: [
                SpacesDeviceWorkspaceProcessRow(
                    id: "row-web", workspaceID: "workspace", name: "web", command: "npm run dev", templateID: "tpl-web", processID: "proc-web",
                    sessionID: "sess-web", runState: .running, canRun: false, canStop: true, canRestart: true),
                SpacesDeviceWorkspaceProcessRow(
                    id: "row-api", workspaceID: "workspace", name: "api", command: "npm run api", templateID: "tpl-api", processID: nil,
                    sessionID: nil, runState: .notStarted, canRun: true, canStop: false, canRestart: false),
            ],
            codingAgentRows: [
                SpacesDeviceWorkspaceCodingAgentRow(
                    id: "agent:agent-1", workspaceID: "workspace", name: "claude", command: "claude", agentID: "agent-1", sessionID: "sess-agent",
                    runState: .running, activityState: .idle, canStop: true)
            ],
            terminalRows: [
                SpacesDeviceWorkspaceTerminalRow(
                    id: "term-1", workspaceID: "workspace", title: "zsh", workingDirectory: "/tmp/workspace", sessionID: "sess-term",
                    runState: .running, canOpenTerminal: true, canStop: true)
            ])
        return SpacesDeviceWorkspaceDetailViewModel(workspace: summary)
    }

    private func fixtureItems() -> [SidebarRuntimeTargetItem] {
        AppKitController.sidebarRuntimeTargetItems(
            detail: fixtureDetail(), browserSessions: [BrowserSession(name: "App", url: "http://localhost:3000")])
    }

    /// Runtime rows group by family: browser sessions, configured processes, coding agents, then ad hoc
    /// terminals. Shortcut numbering follows the same order, so ⌘1…⌘0 and the sidebar rows never disagree.
    @Test func itemsFollowShortcutTargetOrderWithStableKeys() {
        let items = fixtureItems()
        #expect(items.map(\.key) == ["browser:http://localhost:3000", "process:proc-web", "missing:api", "agent:agent-1", "terminal:sess-term"])
        #expect(items.map(\.shortcutIndex) == [1, 2, 3, 4, 5])
        #expect(items.map(\.title) == ["App", "web", "api", "claude", "zsh"])
    }

    @Test func itemsCarryRunStateAndCapabilities() {
        let items = fixtureItems()
        let byKey = Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0) })

        let browser = byKey["browser:http://localhost:3000"]
        #expect(browser?.runState == nil)
        #expect(browser?.canRun == false && browser?.canStop == false && browser?.canRestart == false)
        #expect(browser?.browserTargetURL == "http://localhost:3000")

        let web = byKey["process:proc-web"]
        #expect(web?.runState == .running)
        #expect(web?.canRun == false && web?.canStop == true && web?.canRestart == true)
        #expect(web?.sessionID == "sess-web")

        let api = byKey["missing:api"]
        #expect(api?.runState == .notStarted)
        #expect(api?.canRun == true && api?.canStop == false && api?.canRestart == false)

        let terminal = byKey["terminal:sess-term"]
        #expect(terminal?.runState == .running)
        #expect(terminal?.canRun == false && terminal?.canStop == true && terminal?.canRestart == false)
        #expect(terminal?.sessionID == "sess-term")

        // Stop is an agent's only lifecycle control: it exists only as a session someone started by
        // running its command in a terminal, so there is nothing to start or restart.
        let agent = byKey["agent:agent-1"]
        #expect(agent?.runState == .running)
        #expect(agent?.canRun == false && agent?.canStop == true && agent?.canRestart == false)
        #expect(agent?.sessionID == "sess-agent")
        #expect(agent?.agentID == "agent-1")
    }

    @Test func itemsCarryRenameIdentities() {
        let items = fixtureItems()
        let byKey = Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0) })
        #expect(byKey["process:proc-web"]?.processTemplateID == "tpl-web")
        #expect(byKey["process:proc-web"]?.processKey == "web")
        #expect(byKey["missing:api"]?.processTemplateID == "tpl-api")
        #expect(byKey["agent:agent-1"]?.agentID == "agent-1")
    }

    /// A browser rename must find the configured session by its (substitution-invariant) name.
    /// The sidebar row carries the env-resolved URL (`http://localhost:3000`), while the config
    /// stores the raw `http://localhost:$PORT`, so a URL comparison would silently miss it.
    @Test func browserRenameMatchesConfiguredSessionByName() {
        let browser = fixtureItems().first { $0.kind == .browser }
        #expect(browser?.title == "App")
        #expect(browser?.browserTargetURL == "http://localhost:3000")

        let sessions = [BrowserSession(name: "App", url: "http://localhost:$PORT")]
        #expect(AppKitController.configuredBrowserSessionIndex(named: browser?.title ?? "", in: sessions) == 0)
        // A resolved-URL comparison against the raw config would not match.
        #expect(sessions.firstIndex { $0.url == browser?.browserTargetURL } == nil)
        #expect(AppKitController.configuredBrowserSessionIndex(named: "Unknown", in: sessions) == nil)
    }

    /// Ad hoc shells and coding agents carry secondary text once their terminal reports a title, and
    /// nothing else does: a configured process is described by the command its config entry names.
    @Test func shellAndAgentRowsWithAReportedTitleCarrySecondaryText() {
        let byKey = Dictionary(uniqueKeysWithValues: fixtureItems().map { ($0.key, $0) })
        // The fixture's shell and agent have reported no title, so they have nothing to add.
        #expect(byKey["terminal:sess-term"]?.detail == nil)
        #expect(byKey["agent:agent-1"]?.detail == nil)
        #expect(byKey["process:proc-web"]?.detail == nil)
        #expect(byKey["browser:http://localhost:3000"]?.detail == nil)

        let summary = SpacesDeviceWorkspaceSummary(
            id: "workspace", projectID: "project", projectName: "project", branch: "main", baseBranch: nil, dir: "/tmp/workspace", isRunning: true,
            isHidden: false, isDefault: false, sessionCount: 2,
            codingAgentRows: [
                SpacesDeviceWorkspaceCodingAgentRow(
                    id: "agent:agent-1", workspaceID: "workspace", name: "claude", command: "claude", agentID: "agent-1", sessionID: "sess-agent",
                    runState: .running, activityState: .idle, canStop: true, liveTitle: "reviewing PR 420")
            ],
            terminalRows: [
                SpacesDeviceWorkspaceTerminalRow(
                    id: "term-1", workspaceID: "workspace", title: "shell-1", workingDirectory: "/tmp/workspace", sessionID: "sess-term",
                    runState: .running, canOpenTerminal: true, canStop: true, liveTitle: "vim main.swift")
            ])
        let busy = Dictionary(
            uniqueKeysWithValues: AppKitController.sidebarRuntimeTargetItems(
                detail: SpacesDeviceWorkspaceDetailViewModel(workspace: summary), browserSessions: []
            ).map { ($0.key, $0) })
        #expect(busy["terminal:sess-term"]?.title == "shell-1", "what the program prints never renames the row")
        #expect(busy["terminal:sess-term"]?.detail == "vim main.swift")
        #expect(busy["agent:agent-1"]?.title == "claude", "the agent keeps the name it answers to")
        #expect(busy["agent:agent-1"]?.detail == "reviewing PR 420")
    }

    /// Nothing in the workspace config names a coding agent, so every agent row's rename is stored on
    /// its own session, and an empty submission clears it back to the label the agent reports.
    @Test func agentRowRenamesItsSession() throws {
        let agent = fixtureItems().first { $0.kind == .agent }
        #expect(agent?.agentID == "agent-1")
        #expect(
            AppKitController.sidebarRuntimeTargetRenameDestination(item: try #require(agent), newTitle: "Reviewer")
                == .agentSession(agentID: "agent-1"))
        #expect(
            AppKitController.sidebarRuntimeTargetRenameDestination(item: try #require(agent), newTitle: "  ") == .agentSession(agentID: "agent-1"))
    }

    /// A configured process keeps the config-entry rename rule, so the agent rule above is a real fork in
    /// routing rather than the only behavior left.
    @Test func configuredProcessRowRenamesItsConfigEntry() throws {
        let process = fixtureItems().first { $0.kind == .process }
        #expect(AppKitController.sidebarRuntimeTargetRenameDestination(item: try #require(process), newTitle: "API") == .configuredProcess)
        // A config entry must keep a name, so an empty submission on one is discarded.
        #expect(AppKitController.sidebarRuntimeTargetRenameDestination(item: try #require(process), newTitle: " ") == .discard)
    }

    @Test func shortcutIndexStopsAfterTen() {
        let terminalRows = (0..<12).map { index in
            SpacesDeviceWorkspaceTerminalRow(
                id: "term-\(index)", workspaceID: "workspace", title: "zsh \(index)", workingDirectory: "/tmp/workspace", sessionID: "sess-\(index)",
                runState: .running, canOpenTerminal: true, canStop: true)
        }
        let summary = SpacesDeviceWorkspaceSummary(
            id: "workspace", projectID: "project", projectName: "project", branch: "main", baseBranch: nil, dir: "/tmp/workspace", isRunning: true,
            isHidden: false, isDefault: false, sessionCount: terminalRows.count, terminalRows: terminalRows)
        let items = AppKitController.sidebarRuntimeTargetItems(detail: SpacesDeviceWorkspaceDetailViewModel(workspace: summary), browserSessions: [])
        #expect(items.count == 12)
        #expect(items[9].shortcutIndex == 10)
        #expect(items[10].shortcutIndex == nil)
        #expect(items[11].shortcutIndex == nil)
    }
}
