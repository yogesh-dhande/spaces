import Testing
import workspacecore

@testable import spacesui

@Suite struct AppKitControllerWorkspaceRunOrderingTests {
    @Test func configuredProcessesKeepSettingsOrderBeforeExtraWindows() {
        let configuredProcesses = [ProcessTemplate(name: "api", command: "run api"), ProcessTemplate(name: "web", command: "run web")]
        let windows = [
            WindowRecord(
                id: "win-web", workspaceID: "workspace", app: "Spaces", title: "web", targetURL: nil, terminalTrackingID: "session-web", role: "terminal", orderIndex: 200, lastSeenAt: "now"),
            WindowRecord(
                id: "win-api", workspaceID: "workspace", app: "Spaces", title: "api", targetURL: nil, terminalTrackingID: "session-api", role: "terminal", orderIndex: 201, lastSeenAt: "now"),
            WindowRecord(
                id: "win-shell", workspaceID: "workspace", app: "Spaces", title: "* zsh", targetURL: nil, terminalTrackingID: "session-shell", role: "terminal", orderIndex: 202, lastSeenAt: "now"),
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
                id: "win-web", workspaceID: "workspace", app: "Spaces", title: "web", targetURL: nil, terminalTrackingID: "session-web", role: "terminal", orderIndex: 200, lastSeenAt: "now")
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
                id: "win-web", workspaceID: "workspace", app: "Spaces", title: "web server", targetURL: nil, terminalTrackingID: "session-web", role: "terminal", orderIndex: 200, lastSeenAt: "now")
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
                id: "win-api", workspaceID: "workspace", app: "Spaces", title: "name:api", targetURL: nil, terminalTrackingID: "session-api", role: "terminal", orderIndex: 200, lastSeenAt: "now")
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
                id: "win-agent", workspaceID: "workspace", app: "Spaces", title: "agent", targetURL: nil, terminalTrackingID: "session-agent", role: "terminal", orderIndex: 200, lastSeenAt: "now"),
            WindowRecord(
                id: "win-api", workspaceID: "workspace", app: "Spaces", title: "api", targetURL: nil, terminalTrackingID: "session-api", role: "terminal", orderIndex: 201, lastSeenAt: "now"),
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
                id: "agent", workspaceID: "workspace", provider: .spaces, label: "Agent", terminalTrackingID: "session-agent", codexThreadID: nil,
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
                id: "win-shell", workspaceID: "workspace", app: "Spaces", title: "shell-1", targetURL: nil, terminalTrackingID: "spaces-spaces-token", role: "terminal", orderIndex: 201, lastSeenAt: "now"),
        ]
        let processes = [
            RunningProcessRecord(
                id: "process-web", workspaceID: "workspace", templateName: "web", command: "run web", terminalApp: "Spaces",
                terminalTrackingID: "spaces-web", pid: 1, status: .running, logPath: nil, lastOutputAt: nil, startedAt: nil, exitedAt: nil)
        ]
        let agentWindows = [
            AgentWindowRecord(
                id: "agent", workspaceID: "workspace", provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "spaces-spaces-token",
                codexThreadID: nil, status: .idle, createdAt: "now", updatedAt: "now")
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
                id: "win-web", workspaceID: "workspace", app: "Spaces", name: "web", detail: nil, targetURL: nil, terminalTrackingID: "spaces-web", terminalNativeID: "spaces-web", role: "terminal", orderIndex: 200, lastSeenAt: "now"),
            WindowRecord(
                id: "win-shell", workspaceID: "workspace", app: "Spaces", name: "shell-1", detail: nil, targetURL: nil, terminalTrackingID: "spaces-spaces-hook", terminalNativeID: nil, role: "terminal", orderIndex: 201, lastSeenAt: "now"),
        ]
        let processes = [
            RunningProcessRecord(
                id: "process-web", workspaceID: "workspace", templateName: "web", command: "run web", terminalApp: "Spaces",
                terminalTrackingID: "spaces-web", terminalNativeID: "spaces-web", pid: 1, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: nil, exitedAt: nil)
        ]
        let agentWindows = [
            AgentWindowRecord(
                id: "agent", workspaceID: "workspace", provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "spaces-spaces-hook",
                terminalNativeID: nil, codexThreadID: nil, status: .idle, createdAt: "now", updatedAt: "now")
        ]

        let entries = AppKitController.orderedWorkspaceRunProcessEntries(
            configuredProcesses: configuredProcesses, windows: windows, processes: processes, agentWindows: agentWindows)

        #expect(entries.count == 1)
        #expect(entries.first?.kind == .process)
        #expect(entries.first?.processID == "process-web")
    }

    @Test func adHocDetectedAgentUsesForegroundCommandAsDetail() {
        let windows = [
            WindowRecord(
                id: "win-shell", workspaceID: "workspace", app: TerminalHost.spaces.appName, name: "shell-1", detail: "codex --model gpt-5",
                targetURL: nil, terminalTrackingID: "spaces-session", terminalNativeID: "spaces-session", role: "terminal",
                orderIndex: 200, lastSeenAt: "now")
        ]
        let agentWindows = [
            AgentWindowRecord(
                id: "agent", workspaceID: "workspace", provider: .spaces, label: "Codex", terminalTrackingID: "spaces-session",
                terminalNativeID: "spaces-session", codexThreadID: nil, status: .idle, createdAt: "now", updatedAt: "now")
        ]

        let titleByAgentID = AppKitController.codingAgentWindowTitleByAgentID(agentWindows: agentWindows, trackedWindows: windows)

        #expect(titleByAgentID["agent"] == "codex --model gpt-5")
    }

    @Test func adHocDetectedAgentHidesRedundantForegroundCommandDetail() {
        let windows = [
            WindowRecord(
                id: "win-shell", workspaceID: "workspace", app: TerminalHost.spaces.appName, name: "shell-1", detail: "codex", targetURL: nil,
                terminalTrackingID: "spaces-session", terminalNativeID: "spaces-session", role: "terminal", orderIndex: 200,
                lastSeenAt: "now")
        ]
        let agentWindows = [
            AgentWindowRecord(
                id: "agent", workspaceID: "workspace", provider: .spaces, label: "Codex", terminalTrackingID: "spaces-session",
                terminalNativeID: "spaces-session", codexThreadID: nil, status: .idle, createdAt: "now", updatedAt: "now")
        ]

        let titleByAgentID = AppKitController.codingAgentWindowTitleByAgentID(agentWindows: agentWindows, trackedWindows: windows)

        #expect(titleByAgentID["agent"] == nil)
    }

    @Test func demotedAdHocSpacesTerminalReturnsToProcessOrderingAsWindow() {
        let windows = [
            WindowRecord(
                id: "win-shell", workspaceID: "workspace", app: TerminalHost.spaces.appName, name: "shell-1", detail: nil, targetURL: nil,
                terminalTrackingID: "spaces-session", terminalNativeID: "spaces-session", role: "terminal", orderIndex: 200,
                lastSeenAt: "now")
        ]

        let entries = AppKitController.orderedWorkspaceRunProcessEntries(configuredProcesses: [], windows: windows, processes: [], agentWindows: [])

        #expect(entries.count == 1)
        #expect(entries.first?.kind == .window)
        #expect(entries.first?.windowListIndex == 0)
    }

    @Test func preferredTerminalWindowsByTrackingKeyKeepsLowestOrderWhenKeysCollide() {
        let windows = [
            WindowRecord(
                id: "win-newer", workspaceID: "workspace", app: "Spaces", name: "shell-2", detail: "newer", targetURL: nil, terminalTrackingID: "spaces-hook", terminalNativeID: nil, role: "terminal", orderIndex: 205, lastSeenAt: "now"),
            WindowRecord(
                id: "win-older", workspaceID: "workspace", app: "Spaces", name: "shell-1", detail: "older", targetURL: nil, terminalTrackingID: "spaces-hook", terminalNativeID: nil, role: "terminal", orderIndex: 201, lastSeenAt: "now"),
        ]

        let linkedWindows = AppKitController.preferredTerminalWindowsByTrackingKey(windows)

        #expect(linkedWindows["terminal:spaces-hook"]?.id == "win-older")
    }

    @Test func shortcutTargetsFollowVisibleRunSectionOrder() {
        let configuredProcesses = [ProcessTemplate(name: "web", command: "npm run dev")]
        let browserSessions = [BrowserSession(name: "frontend", url: "http://localhost:3000")]
        let configuredAgentLaunchers = [AgentLauncher(name: "claude", command: "claude")]
        let windows = [
            WindowRecord(
                id: "win-web", workspaceID: "workspace", app: "Spaces", title: "web", targetURL: nil, terminalTrackingID: "session-web", role: "terminal", orderIndex: 200, lastSeenAt: "now")
        ]
        let processes = [
            RunningProcessRecord(
                id: "process-web", workspaceID: "workspace", templateName: "web", command: "npm run dev", terminalApp: "Spaces",
                terminalTrackingID: "session-web", pid: 1, status: .running, logPath: nil, lastOutputAt: nil, startedAt: nil, exitedAt: nil)
        ]
        let agentWindows = [
            AgentWindowRecord(
                id: "agent", workspaceID: "workspace", provider: .spaces, label: "Claude Code CLI", terminalTrackingID: "session-agent",
                codexThreadID: nil, status: .spinning, createdAt: "now", updatedAt: "now")
        ]

        let processEntries = AppKitController.orderedWorkspaceRunProcessEntries(
            configuredProcesses: configuredProcesses, windows: windows, processes: processes, agentWindows: agentWindows)
        let shortcutTargets = AppKitController.orderedWorkspaceRunShortcutTargets(
            browserSessions: browserSessions, processEntries: processEntries,
            processesByID: Dictionary(uniqueKeysWithValues: processes.map { ($0.id, $0) }), configuredAgentLaunchers: configuredAgentLaunchers,
            agentWindows: agentWindows)

        #expect(shortcutTargets.map(\.kind) == [.browser, .process, .agentLauncher, .agent])
        #expect(shortcutTargets.first?.targetURL == "http://localhost:3000")
        #expect(shortcutTargets[1].processID == "process-web")
        #expect(shortcutTargets[2].launcherName == "claude")
        #expect(shortcutTargets[3].agentWindow?.id == "agent")
    }

    @Test func configuredAndAdHocAgentsShareOneVisibleShortcutRunOrder() {
        let configuredAgentLaunchers = [AgentLauncher(name: "claude", command: "claude")]
        let agentWindows = [
            AgentWindowRecord(
                id: "configured", workspaceID: "workspace", provider: .spaces, label: "claude", terminalTrackingID: "session-claude",
                codexThreadID: nil, status: .idle, createdAt: "now", updatedAt: "now"),
            AgentWindowRecord(
                id: "adhoc", workspaceID: "workspace", provider: .spaces, label: "reviewer", terminalTrackingID: "session-reviewer",
                codexThreadID: nil, status: .spinning, createdAt: "now", updatedAt: "now"),
        ]

        let shortcutTargets = AppKitController.orderedWorkspaceRunShortcutTargets(
            browserSessions: [], processEntries: [], processesByID: [:], configuredAgentLaunchers: configuredAgentLaunchers,
            agentWindows: agentWindows)

        #expect(shortcutTargets.map(\.kind) == [.agent, .agent])
        #expect(shortcutTargets.map { $0.agentWindow?.id } == ["configured", "adhoc"])
    }

    @Test func workspaceDetailShortcutIndicesFollowLiveRuntimeOrder() {
        let browserSessions = [BrowserSession(name: "docs", url: "http://localhost:3000")]
        let configuredProcesses = [ProcessTemplate(name: "web", command: "npm run dev")]
        let configuredAgentLaunchers = [AgentLauncher(name: "claude", command: "claude")]
        let windows = [
            WindowRecord(
                id: "win-web", workspaceID: "workspace", app: "Spaces", name: "web", detail: "npm run dev", targetURL: nil, terminalTrackingID: "session-web", role: "terminal", orderIndex: 200, lastSeenAt: "now"),
            WindowRecord(
                id: "win-shell", workspaceID: "workspace", app: "Spaces", name: nil, detail: "* zsh", targetURL: nil, terminalTrackingID: "session-shell", role: "terminal", orderIndex: 201, lastSeenAt: "now"),
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
            processesByID: Dictionary(uniqueKeysWithValues: processes.map { ($0.id, $0) }), configuredAgentLaunchers: configuredAgentLaunchers,
            agentWindows: [])

        #expect(shortcutIndices.browserSessionsByURL["http://localhost:3000"] == 1)
        #expect(shortcutIndices.processesByName["web"] == 2)
        #expect(shortcutIndices.codingAgentsByName["claude"] == 4)
        #expect(shortcutIndices.codingAgentsByIdentity[AppKitController.codingAgentShortcutIdentity(launcherName: "claude")] == 4)
    }

    @Test func unlabeledAgentRowsStillReceiveShortcutIdentity() {
        let agentWindows = [
            AgentWindowRecord(
                id: "agent-unlabeled", workspaceID: "workspace", provider: .spaces, label: nil, terminalTrackingID: "spaces-hook-1",
                terminalNativeID: "spaces-terminal-1", codexThreadID: nil, status: .waiting, createdAt: "now", updatedAt: "now")
        ]

        let shortcutIndices = AppKitController.workspaceDetailShortcutIndices(
            browserSessions: [], processEntries: [], processesByID: [:], configuredAgentLaunchers: [], agentWindows: agentWindows)

        #expect(shortcutIndices.codingAgentsByIdentity[AppKitController.codingAgentShortcutIdentity(agentWindowID: "agent-unlabeled")] == 1)
    }

    @Test func resolvedCodingAgentEntriesKeepConfiguredSlotsBeforeAdHocAgents() {
        let configuredAgentLaunchers = [AgentLauncher(name: "claude", command: "claude"), AgentLauncher(name: "codex", command: "codex")]
        let agentWindows = [
            AgentWindowRecord(
                id: "matched", workspaceID: "workspace", provider: .spaces, label: "Claude", terminalTrackingID: "session-claude", codexThreadID: nil,
                status: .idle, createdAt: "now", updatedAt: "now"),
            AgentWindowRecord(
                id: "adhoc", workspaceID: "workspace", provider: .spaces, label: "reviewer", terminalTrackingID: "session-reviewer",
                codexThreadID: nil, status: .spinning, createdAt: "now", updatedAt: "now"),
        ]

        let entries = AppKitController.resolvedCodingAgentRunEntries(configuredAgentLaunchers: configuredAgentLaunchers, agentWindows: agentWindows)

        #expect(entries.map(\.kind) == [.agent, .agentLauncher, .agent])
        #expect(entries.map(\.launcherName) == ["claude", "codex", nil])
        #expect(entries.map { $0.agentWindow?.id } == ["matched", nil, "adhoc"])
    }

    @Test func resolvedCodingAgentEntriesMatchRenamedLaunchersByID() {
        let configuredAgentLaunchers = [AgentLauncher(id: "launcher-codex", name: "Codex Renamed", command: "codex")]
        let agentWindows = [
            AgentWindowRecord(
                id: "matched", workspaceID: "workspace", provider: .spaces, label: "Codex",
                terminalTarget: TerminalTargetRecord(trackingID: "session-codex"), claimedLauncherID: "launcher-codex", claimedLauncherName: "Codex",
                status: .idle, createdAt: "now", updatedAt: "now")
        ]

        let entries = AppKitController.resolvedCodingAgentRunEntries(configuredAgentLaunchers: configuredAgentLaunchers, agentWindows: agentWindows)

        #expect(entries.map(\.kind) == [.agent])
        #expect(entries.map(\.launcherName) == ["Codex Renamed"])
        #expect(entries.map { $0.agentWindow?.id } == ["matched"])
    }

    @Test func staleClaimedLauncherIDDoesNotHideLiveAgentShortcutTarget() {
        let configuredAgentLaunchers = [AgentLauncher(id: "launcher-codex-new", name: "Codex", command: "codex")]
        let agentWindows = [
            AgentWindowRecord(
                id: "codex-runtime", workspaceID: "workspace", provider: .spaces, label: "Codex",
                terminalTarget: TerminalTargetRecord(trackingID: "session-codex"), claimedLauncherID: "launcher-codex-old",
                claimedLauncherName: "Codex", status: .idle, createdAt: "now", updatedAt: "now")
        ]

        let entries = AppKitController.resolvedCodingAgentRunEntries(configuredAgentLaunchers: configuredAgentLaunchers, agentWindows: agentWindows)
        let shortcutIndices = AppKitController.workspaceDetailShortcutIndices(
            browserSessions: [], processEntries: [], processesByID: [:], configuredAgentLaunchers: configuredAgentLaunchers,
            agentWindows: agentWindows)

        #expect(entries.map(\.kind) == [.agentLauncher, .agent])
        #expect(entries.map(\.launcherName) == ["Codex", nil])
        #expect(entries.map { $0.agentWindow?.id } == [nil, "codex-runtime"])
        #expect(shortcutIndices.codingAgentsByIdentity[AppKitController.codingAgentShortcutIdentity(launcherName: "Codex")] == 1)
        #expect(shortcutIndices.codingAgentsByIdentity[AppKitController.codingAgentShortcutIdentity(agentWindowID: "codex-runtime")] == 2)
    }

    @Test func missingConfiguredProcessShortcutTargetsRecoveryAction() {
        let processEntries = [
            AppKitController.WorkspaceRunProcessEntry(
                kind: .missingConfiguredProcess, processID: nil, windowListIndex: nil, processKey: "api", processLabel: "api",
                processCommand: "run api")
        ]

        let shortcutTargets = AppKitController.orderedWorkspaceRunShortcutTargets(
            browserSessions: [], processEntries: processEntries, processesByID: [:], configuredAgentLaunchers: [], agentWindows: [])

        #expect(shortcutTargets.count == 1)
        #expect(shortcutTargets.first?.kind == .missingConfiguredProcess)
        #expect(shortcutTargets.first?.processKey == "api")
    }

    @Test func doneAndWaitingAgentsRemainAlertsAttentionItems() {
        let agents = [
            AgentWindowRecord(
                id: "agent-waiting", workspaceID: "workspace", provider: .spaces, label: "Waiting", terminalTrackingID: "session-1",
                codexThreadID: nil, status: .waiting, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:01:00Z"),
            AgentWindowRecord(
                id: "agent-done", workspaceID: "workspace", provider: .spaces, label: "Done", terminalTrackingID: "session-2", codexThreadID: nil,
                status: .done, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:02:00Z"),
            AgentWindowRecord(
                id: "agent-idle", workspaceID: "workspace", provider: .spaces, label: "Idle", terminalTrackingID: "session-3", codexThreadID: nil,
                status: .idle, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:03:00Z"),
        ]

        let attentionAgents = AppKitController.alertsAttentionAgentWindows(agents)

        #expect(attentionAgents.map(\.id) == ["agent-waiting", "agent-done"])
    }

}
