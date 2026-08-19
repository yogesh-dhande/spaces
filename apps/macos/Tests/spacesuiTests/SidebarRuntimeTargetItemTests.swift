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

    /// A workspace with an exited process, a waiting agent, and a bell on the ad hoc terminal — one row
    /// of each kind that can carry an alert — used to test undismissed-id derivation and the
    /// exit-acknowledgment color downgrade in isolation from the rest of the row-building logic.
    private func fixtureDetailWithExitedProcess(exitedAt: String) -> SpacesDeviceWorkspaceDetailViewModel {
        let config = SpacesDeviceWorkspaceConfig(processes: [SpacesDeviceProcessTemplate(id: "tpl-web", name: "web", command: "npm run dev")])
        let summary = SpacesDeviceWorkspaceSummary(
            id: "workspace", projectID: "project", projectName: "project", branch: "main", baseBranch: nil, dir: "/tmp/workspace", isRunning: true,
            isHidden: false, isDefault: false, sessionCount: 3, config: config,
            processRows: [
                SpacesDeviceWorkspaceProcessRow(
                    id: "row-web", workspaceID: "workspace", name: "web", command: "npm run dev", templateID: "tpl-web", processID: "proc-web",
                    sessionID: "sess-web", runState: .exited, exitedAt: exitedAt, canRun: true, canStop: false, canRestart: true)
            ],
            codingAgentRows: [
                SpacesDeviceWorkspaceCodingAgentRow(
                    id: "agent:agent-1", workspaceID: "workspace", name: "claude", command: "claude", agentID: "agent-1", sessionID: "sess-agent",
                    runState: .running, activityState: .waiting, canStop: true)
            ],
            terminalRows: [
                SpacesDeviceWorkspaceTerminalRow(
                    id: "term-1", workspaceID: "workspace", title: "zsh", workingDirectory: "/tmp/workspace", sessionID: "sess-term",
                    runState: .running, canOpenTerminal: true, canStop: true)
            ])
        return SpacesDeviceWorkspaceDetailViewModel(workspace: summary)
    }

    /// One alert entry of each kind a row can own: the exited process, the waiting agent, and a bell on
    /// the ad hoc terminal's session — mirroring the identities `buildOverviewAlertsGroups` derives.
    private func alertsGroup(processExitedAt: String, bellSessionID: String = "sess-term") -> AppKitController.AlertsGroup {
        AppKitController.AlertsGroup(
            projectName: "project", workspaceID: "workspace", workspaceName: "workspace", workspaceBranch: "main", isFromHiddenWorkspace: false,
            items: [
                AppKitController.AlertsAttentionEntry(
                    attentionID: "alert:local:process:proc-web:\(processExitedAt)", icon: "terminal", iconTint: .terminal, label: "web",
                    detail: "npm run dev", shortcut: "", processStatus: .exited, countsTowardBadge: true, eventDate: nil,
                    focusRequest: .workspaceProcess(workspaceID: "workspace", processID: "proc-web")),
                AppKitController.AlertsAttentionEntry(
                    attentionID: "alert:local:agent:agent-1:waiting:t1", icon: "cpu.fill", iconTint: .warning, label: "claude", detail: nil,
                    shortcut: "", agentStatus: .waiting, countsTowardBadge: true, eventDate: nil,
                    focusRequest: .agentWindow(
                        AgentWindowRecord(
                            id: "agent-1", workspaceID: "workspace", provider: .spaces, label: "claude", terminalTrackingID: "sess-agent",
                            sessionKey: nil, status: .waiting, createdAt: "t1", updatedAt: "t1"))),
                AppKitController.AlertsAttentionEntry(
                    attentionID: "alert:local:session:\(bellSessionID):bell:t1", icon: "terminal", iconTint: .terminal, label: "zsh", detail: nil,
                    shortcut: "", countsTowardBadge: true, eventDate: nil,
                    focusRequest: .terminalSession(workspaceID: "workspace", sessionID: bellSessionID)),
            ])
    }

    /// Each row's `undismissedAttentionIDs` carries exactly the alert entries that match its own focus
    /// identity: the process row gets its exit (and would get a bell on its own session, which this
    /// fixture has none of), the agent row gets its waiting alert and its own session's bell (none
    /// here), and the ad hoc terminal row gets only the bell on its session — never another row's.
    @Test func rowsCarryOnlyTheirOwnUndismissedAttentionIDs() {
        let items = AppKitController.sidebarRuntimeTargetItems(
            detail: fixtureDetailWithExitedProcess(exitedAt: "2026-08-18T10:00:00Z"), browserSessions: [],
            alertsGroups: [alertsGroup(processExitedAt: "2026-08-18T10:00:00Z")])
        let byKey = Dictionary(uniqueKeysWithValues: items.map { ($0.key, $0) })

        #expect(byKey["process:proc-web"]?.undismissedAttentionIDs == ["alert:local:process:proc-web:2026-08-18T10:00:00Z"])
        #expect(byKey["agent:agent-1"]?.undismissedAttentionIDs == ["alert:local:agent:agent-1:waiting:t1"])
        #expect(byKey["terminal:sess-term"]?.undismissedAttentionIDs == ["alert:local:session:sess-term:bell:t1"])
    }

    /// An undismissed exit alert keeps the process row failed (red); dismissing it — the exact id the
    /// row reported as undismissed — drops the row to inactive without touching the agent or terminal
    /// rows' colors, which dismissal never affects.
    @Test func dismissingAnExitedProcessAlertDowngradesOnlyThatRowToInactive() {
        let exitedAt = "2026-08-18T10:00:00Z"
        let detail = fixtureDetailWithExitedProcess(exitedAt: exitedAt)
        let groups = [alertsGroup(processExitedAt: exitedAt)]

        let undismissed = Dictionary(
            uniqueKeysWithValues: AppKitController.sidebarRuntimeTargetItems(detail: detail, browserSessions: [], alertsGroups: groups).map {
                ($0.key, $0)
            })
        #expect(undismissed["process:proc-web"]?.attentionStatus == .failed)
        #expect(undismissed["agent:agent-1"]?.attentionStatus == .blocked)

        let dismissedIDs: Set<String> = ["alert:local:process:proc-web:\(exitedAt)"]
        let dismissed = Dictionary(
            uniqueKeysWithValues: AppKitController.sidebarRuntimeTargetItems(
                detail: detail, browserSessions: [], alertsGroups: groups, dismissedAttentionItemIDs: dismissedIDs
            ).map { ($0.key, $0) })
        #expect(dismissed["process:proc-web"]?.attentionStatus == .inactive)
        #expect(dismissed["process:proc-web"]?.undismissedAttentionIDs == [])
        // Dismissing the process's alert leaves the agent's own alert, and its color, untouched.
        #expect(dismissed["agent:agent-1"]?.attentionStatus == .blocked)
        #expect(dismissed["agent:agent-1"]?.undismissedAttentionIDs == ["alert:local:agent:agent-1:waiting:t1"])
    }

    /// A later exit of the same process carries a new `exitedAt`, hence a new alert identity: dismissing
    /// the earlier exit's alert does not carry forward to it, so the row reads as failed again.
    @Test func aNewExitCarriesANewAlertIdentityAndReadsFailedAgain() {
        let firstExitedAt = "2026-08-18T10:00:00Z"
        let secondExitedAt = "2026-08-18T11:00:00Z"
        let dismissedIDs: Set<String> = ["alert:local:process:proc-web:\(firstExitedAt)"]

        let afterSecondExit = Dictionary(
            uniqueKeysWithValues: AppKitController.sidebarRuntimeTargetItems(
                detail: fixtureDetailWithExitedProcess(exitedAt: secondExitedAt), browserSessions: [],
                alertsGroups: [alertsGroup(processExitedAt: secondExitedAt)], dismissedAttentionItemIDs: dismissedIDs
            ).map { ($0.key, $0) })
        #expect(afterSecondExit["process:proc-web"]?.attentionStatus == .failed)
        #expect(afterSecondExit["process:proc-web"]?.undismissedAttentionIDs == ["alert:local:process:proc-web:\(secondExitedAt)"])
    }

    /// The workspace header rolls up the highest of its rows' colors (`SidebarAttentionStatus.highest`).
    /// Acknowledging the only failure drops the roll-up straight to the next-highest row's color rather
    /// than staying pinned on the acknowledged failure.
    @Test func workspaceRollUpDropsToNextHighestOnceTheOnlyFailureIsAcknowledged() {
        let exitedAt = "2026-08-18T10:00:00Z"
        let detail = fixtureDetailWithExitedProcess(exitedAt: exitedAt)
        let groups = [alertsGroup(processExitedAt: exitedAt)]

        let beforeDismissal = AppKitController.sidebarRuntimeTargetItems(detail: detail, browserSessions: [], alertsGroups: groups)
        #expect(SidebarAttentionStatus.highest(beforeDismissal.compactMap(\.attentionStatus)) == .failed)

        let afterDismissal = AppKitController.sidebarRuntimeTargetItems(
            detail: detail, browserSessions: [], alertsGroups: groups, dismissedAttentionItemIDs: ["alert:local:process:proc-web:\(exitedAt)"])
        // The agent's waiting alert (blocked) is the next-highest remaining row once the exit is
        // acknowledged; nothing else in the fixture outranks it.
        #expect(SidebarAttentionStatus.highest(afterDismissal.compactMap(\.attentionStatus)) == .blocked)
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
