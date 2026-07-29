import Testing
import spacesclientcore
import spacesdevicecore
import workspacecore

@testable import spacesui

@Suite struct SidebarRuntimeTargetItemTests {
    /// A workspace with one of everything: an open browser session, a running configured
    /// process, a configured-but-not-running process, an ad hoc terminal, a running
    /// coding agent claiming its launcher, and an idle launcher.
    private func fixtureDetail() -> SpacesDeviceWorkspaceDetailViewModel {
        let config = SpacesDeviceWorkspaceConfig(
            processes: [
                SpacesDeviceProcessTemplate(id: "tpl-web", name: "web", command: "npm run dev"),
                SpacesDeviceProcessTemplate(id: "tpl-api", name: "api", command: "npm run api"),
            ], browserSessions: [SpacesDeviceBrowserSession(name: "App", url: "http://localhost:$PORT")],
            resolvedBrowserSessions: [SpacesDeviceBrowserSession(name: "App", url: "http://localhost:3000")],
            agentLaunchers: [
                SpacesDeviceAgentLauncher(id: "launcher-claude", name: "claude", command: "claude"),
                SpacesDeviceAgentLauncher(id: "launcher-codex", name: "codex", command: "codex"),
            ])
        let summary = SpacesDeviceWorkspaceSummary(
            id: "workspace", projectID: "project", projectName: "project", branch: "main", baseBranch: nil, dir: "/tmp/workspace", isRunning: true,
            isArchived: false, isHidden: false, isDefault: false, sessionCount: 3, config: config,
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
                    id: "row-agent", workspaceID: "workspace", name: "claude", command: "claude", launcherID: "launcher-claude", agentID: "agent-1",
                    sessionID: "sess-agent", isConfigured: true, runState: .running, activityState: .idle, canRun: false, canStop: true,
                    canRestart: true)
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
            detail: fixtureDetail(), browserSessions: [BrowserSession(name: "App", url: "http://localhost:3000")], daemonHomeDirectory: "/Users/ada")
    }

    /// Runtime rows group by family: browser sessions, configured processes, coding agents, then ad hoc
    /// terminals. Shortcut numbering follows the same order, so ⌘1…⌘0 and the sidebar rows never disagree.
    @Test func itemsFollowShortcutTargetOrderWithStableKeys() {
        let items = fixtureItems()
        #expect(
            items.map(\.key) == [
                "browser:http://localhost:3000", "process:proc-web", "missing:api", "agent:agent-1", "launcher:codex", "terminal:sess-term",
            ])
        #expect(items.map(\.shortcutIndex) == [1, 2, 3, 4, 5, 6])
        #expect(items.map(\.title) == ["App", "web", "api", "claude", "codex", "zsh"])
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

        let agent = byKey["agent:agent-1"]
        #expect(agent?.runState == .running)
        #expect(agent?.canRun == false && agent?.canStop == true && agent?.canRestart == true)
        #expect(agent?.sessionID == "sess-agent")

        let codex = byKey["launcher:codex"]
        #expect(codex?.runState == .notStarted)
        #expect(codex?.canRun == true && codex?.canStop == false && codex?.canRestart == false)
    }

    @Test func itemsCarryRenameIdentities() {
        let items = fixtureItems()
        let byKey = Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0) })
        #expect(byKey["process:proc-web"]?.processTemplateID == "tpl-web")
        #expect(byKey["process:proc-web"]?.processKey == "web")
        #expect(byKey["missing:api"]?.processTemplateID == "tpl-api")
        #expect(byKey["agent:agent-1"]?.launcherID == "launcher-claude")
        #expect(byKey["launcher:codex"]?.launcherID == "launcher-codex")
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

    /// Only ad hoc shells carry secondary text, and only once they leave the workspace root: a
    /// configured process or agent is named by what it is, not by where it happens to be.
    @Test func onlyShellsAwayFromTheWorkspaceRootCarrySecondaryText() {
        let byKey = Dictionary(uniqueKeysWithValues: fixtureItems().map { ($0.key, $0) })
        // The fixture's shell sits at the workspace root, so it has nothing to add.
        #expect(byKey["terminal:sess-term"]?.detail == nil)
        #expect(byKey["process:proc-web"]?.detail == nil)
        #expect(byKey["agent:agent-1"]?.detail == nil)
        #expect(byKey["browser:http://localhost:3000"]?.detail == nil)

        let summary = SpacesDeviceWorkspaceSummary(
            id: "workspace", projectID: "project", projectName: "project", branch: "main", baseBranch: nil, dir: "/Users/ada/workspace",
            isRunning: true, isArchived: false, isHidden: false, isDefault: false, sessionCount: 1,
            terminalRows: [
                SpacesDeviceWorkspaceTerminalRow(
                    id: "term-1", workspaceID: "workspace", title: "vim main.swift", workingDirectory: "/Users/ada/workspace/apps/web",
                    sessionID: "sess-term", runState: .running, canOpenTerminal: true, canStop: true)
            ])
        // `/Users/ada` is the OWNING DEVICE's home, reported by its daemon — not the home this test
        // process runs under, which must never reach the abbreviation.
        let wandered = AppKitController.sidebarRuntimeTargetItems(
            detail: SpacesDeviceWorkspaceDetailViewModel(workspace: summary), browserSessions: [], daemonHomeDirectory: "/Users/ada"
        ).first
        #expect(wandered?.title == "vim main.swift")
        #expect(wandered?.detail == "~/w/a/web")
    }

    @Test func shortcutIndexStopsAfterTen() {
        let terminalRows = (0..<12).map { index in
            SpacesDeviceWorkspaceTerminalRow(
                id: "term-\(index)", workspaceID: "workspace", title: "zsh \(index)", workingDirectory: "/tmp/workspace", sessionID: "sess-\(index)",
                runState: .running, canOpenTerminal: true, canStop: true)
        }
        let summary = SpacesDeviceWorkspaceSummary(
            id: "workspace", projectID: "project", projectName: "project", branch: "main", baseBranch: nil, dir: "/tmp/workspace", isRunning: true,
            isArchived: false, isHidden: false, isDefault: false, sessionCount: terminalRows.count, terminalRows: terminalRows)
        let items = AppKitController.sidebarRuntimeTargetItems(
            detail: SpacesDeviceWorkspaceDetailViewModel(workspace: summary), browserSessions: [], daemonHomeDirectory: "/Users/ada")
        #expect(items.count == 12)
        #expect(items[9].shortcutIndex == 10)
        #expect(items[10].shortcutIndex == nil)
        #expect(items[11].shortcutIndex == nil)
    }
}
