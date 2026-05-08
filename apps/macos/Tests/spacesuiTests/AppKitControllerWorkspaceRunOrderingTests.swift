import Testing
import workspacecore

@testable import spacesui

@Suite struct AppKitControllerWorkspaceRunOrderingTests {
    @Test func configuredProcessesKeepSettingsOrderBeforeExtraWindows() {
        let configuredProcesses = [ProcessTemplate(name: "api", command: "run api"), ProcessTemplate(name: "web", command: "run web")]
        let windows = [
            WindowRecord(
                id: "win-web", workspaceID: "workspace", app: "iTerm2", title: "web", targetURL: nil, windowID: 102,
                terminalTrackingID: "session-web", itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now"),
            WindowRecord(
                id: "win-api", workspaceID: "workspace", app: "iTerm2", title: "api", targetURL: nil, windowID: 101,
                terminalTrackingID: "session-api", itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 201, lastSeenAt: "now"),
            WindowRecord(
                id: "win-shell", workspaceID: "workspace", app: "iTerm2", title: "* zsh", targetURL: nil, windowID: 103,
                terminalTrackingID: "session-shell", itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 202, lastSeenAt: "now"),
        ]
        let processes = [
            RunningProcessRecord(
                id: "process-web", workspaceID: "workspace", templateName: "web", command: "run web", terminalApp: "iTerm2", windowID: 102,
                terminalTrackingID: "session-web", itermTabIndex: nil, tmuxWindowID: nil, pid: 2, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: nil, exitedAt: nil),
            RunningProcessRecord(
                id: "process-api", workspaceID: "workspace", templateName: "api", command: "run api", terminalApp: "iTerm2", windowID: 101,
                terminalTrackingID: "session-api", itermTabIndex: nil, tmuxWindowID: nil, pid: 1, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: nil, exitedAt: nil),
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
                id: "win-web", workspaceID: "workspace", app: "iTerm2", title: "web", targetURL: nil, windowID: 102,
                terminalTrackingID: "session-web", itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now")
        ]
        let processes = [
            RunningProcessRecord(
                id: "process-web", workspaceID: "workspace", templateName: "web", command: "run web", terminalApp: "iTerm2", windowID: 102,
                terminalTrackingID: "session-web", itermTabIndex: nil, tmuxWindowID: nil, pid: 2, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: nil, exitedAt: nil)
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
                id: "win-web", workspaceID: "workspace", app: "iTerm2", title: "web server", targetURL: nil, windowID: 102,
                terminalTrackingID: "session-web", itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now")
        ]
        let processes = [
            RunningProcessRecord(
                id: "process-web", workspaceID: "workspace", templateName: "web server", command: "PORT=20003 npm run dev", terminalApp: "iTerm2",
                windowID: 102, terminalTrackingID: "session-web", itermTabIndex: nil, tmuxWindowID: nil, pid: 2, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: nil, exitedAt: nil)
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
                id: "win-api", workspaceID: "workspace", app: "iTerm2", title: "name:api", targetURL: nil, windowID: 102,
                terminalTrackingID: "session-api", itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now")
        ]
        let processes = [
            RunningProcessRecord(
                id: "process-api", workspaceID: "workspace", templateName: "name:api", command: "npm run api", terminalApp: "iTerm2", windowID: 102,
                terminalTrackingID: "session-api", itermTabIndex: nil, tmuxWindowID: nil, pid: 2, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: nil, exitedAt: nil)
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
                id: "win-agent", workspaceID: "workspace", app: "iTerm2", title: "agent", targetURL: nil, windowID: 104,
                terminalTrackingID: "session-agent", itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now"),
            WindowRecord(
                id: "win-api", workspaceID: "workspace", app: "iTerm2", title: "api", targetURL: nil, windowID: 101,
                terminalTrackingID: "session-api", itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 201, lastSeenAt: "now"),
        ]
        let processes = [
            RunningProcessRecord(
                id: "process-api", workspaceID: "workspace", templateName: "api", command: "run api", terminalApp: "iTerm2", windowID: 101,
                terminalTrackingID: "session-api", itermTabIndex: nil, tmuxWindowID: nil, pid: 1, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: nil, exitedAt: nil),
            RunningProcessRecord(
                id: "process-agent", workspaceID: "workspace", templateName: "agent", command: "run agent", terminalApp: "iTerm2", windowID: 104,
                terminalTrackingID: "session-agent", itermTabIndex: nil, tmuxWindowID: nil, pid: 2, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: nil, exitedAt: nil),
        ]
        let agentWindows = [
            AgentWindowRecord(
                id: "agent", workspaceID: "workspace", provider: .iterm2, label: "Agent", terminalTrackingID: "session-agent", tmuxWindowID: nil,
                codexThreadID: nil, windowID: 104, yabaiWindowID: 104, status: .spinning, createdAt: "now", updatedAt: "now")
        ]

        let entries = AppKitController.orderedWorkspaceRunProcessEntries(
            configuredProcesses: configuredProcesses, windows: windows, processes: processes, agentWindows: agentWindows)

        #expect(entries.count == 1)
        #expect(entries.first?.kind == .process)
        #expect(entries.first?.processID == "process-api")
    }

    @Test func ghosttyAgentClaimedManualTerminalRowIsExcludedFromProcessOrdering() {
        let configuredProcesses = [ProcessTemplate(name: "web", command: "run web")]
        let windows = [
            WindowRecord(
                id: "win-web", workspaceID: "workspace", app: "Ghostty", title: "web", targetURL: nil, windowID: 101,
                terminalTrackingID: "ghostty-web", itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now"),
            WindowRecord(
                id: "win-shell", workspaceID: "workspace", app: "Ghostty", title: "shell-1", targetURL: nil, windowID: 202,
                terminalTrackingID: "spaces-ghostty-token", itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 201,
                lastSeenAt: "now"),
        ]
        let processes = [
            RunningProcessRecord(
                id: "process-web", workspaceID: "workspace", templateName: "web", command: "run web", terminalApp: "Ghostty", windowID: 101,
                terminalTrackingID: "ghostty-web", itermTabIndex: nil, tmuxWindowID: nil, pid: 1, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: nil, exitedAt: nil)
        ]
        let agentWindows = [
            AgentWindowRecord(
                id: "agent", workspaceID: "workspace", provider: .ghostty, label: "Claude Code CLI", terminalTrackingID: "spaces-ghostty-token",
                tmuxWindowID: nil, codexThreadID: nil, windowID: 202, yabaiWindowID: 202, status: .idle, createdAt: "now", updatedAt: "now")
        ]

        let entries = AppKitController.orderedWorkspaceRunProcessEntries(
            configuredProcesses: configuredProcesses, windows: windows, processes: processes, agentWindows: agentWindows)

        #expect(entries.count == 1)
        #expect(entries.first?.kind == .process)
        #expect(entries.first?.processID == "process-web")
    }

    @Test func ghosttyAgentClaimedTerminalRowIsExcludedWhenWindowOnlyHasHookToken() {
        let configuredProcesses = [ProcessTemplate(name: "web", command: "run web")]
        let windows = [
            WindowRecord(
                id: "win-web", workspaceID: "workspace", app: "Ghostty", name: "web", detail: nil, targetURL: nil, windowID: 101,
                terminalTrackingID: "ghostty-web", terminalNativeID: "ghostty-web-native", itermTabIndex: nil, tmuxWindowID: nil, role: "terminal",
                orderIndex: 200, lastSeenAt: "now"),
            WindowRecord(
                id: "win-shell", workspaceID: "workspace", app: "Ghostty", name: "shell-1", detail: nil, targetURL: nil, windowID: 202,
                terminalTrackingID: "spaces-ghostty-hook", terminalNativeID: nil, itermTabIndex: nil, tmuxWindowID: nil, role: "terminal",
                orderIndex: 201, lastSeenAt: "now"),
        ]
        let processes = [
            RunningProcessRecord(
                id: "process-web", workspaceID: "workspace", templateName: "web", command: "run web", terminalApp: "Ghostty", windowID: 101,
                terminalTrackingID: "ghostty-web", terminalNativeID: "ghostty-web-native", itermTabIndex: nil, tmuxWindowID: nil, pid: 1,
                status: .running, logPath: nil, lastOutputAt: nil, startedAt: nil, exitedAt: nil)
        ]
        let agentWindows = [
            AgentWindowRecord(
                id: "agent", workspaceID: "workspace", provider: .ghostty, label: "Claude Code CLI", terminalTrackingID: "spaces-ghostty-hook",
                terminalNativeID: "ghostty-native-id", tmuxWindowID: nil, codexThreadID: nil, windowID: 202, yabaiWindowID: 202, status: .idle,
                createdAt: "now", updatedAt: "now")
        ]

        let entries = AppKitController.orderedWorkspaceRunProcessEntries(
            configuredProcesses: configuredProcesses, windows: windows, processes: processes, agentWindows: agentWindows)

        #expect(entries.count == 1)
        #expect(entries.first?.kind == .process)
        #expect(entries.first?.processID == "process-web")
    }

    @Test func preferredTerminalWindowsByTrackingKeyKeepsLowestOrderWhenKeysCollide() {
        let windows = [
            WindowRecord(
                id: "win-newer", workspaceID: "workspace", app: "Ghostty", name: "shell-2", detail: "newer", targetURL: nil, windowID: 202,
                terminalTrackingID: "ghostty-hook", terminalNativeID: nil, itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 205,
                lastSeenAt: "now"),
            WindowRecord(
                id: "win-older", workspaceID: "workspace", app: "Ghostty", name: "shell-1", detail: "older", targetURL: nil, windowID: 201,
                terminalTrackingID: "ghostty-hook", terminalNativeID: nil, itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 201,
                lastSeenAt: "now"),
        ]

        let linkedWindows = AppKitController.preferredTerminalWindowsByTrackingKey(windows)

        #expect(linkedWindows["terminal:ghostty-hook"]?.id == "win-older")
    }

    @Test func shortcutTargetsFollowVisibleRunSectionOrder() {
        let configuredProcesses = [ProcessTemplate(name: "web", command: "npm run dev")]
        let browserSessions = [BrowserSession(name: "frontend", url: "http://localhost:3000")]
        let configuredAgentLaunchers = [AgentLauncher(name: "claude", command: "claude")]
        let windows = [
            WindowRecord(
                id: "win-web", workspaceID: "workspace", app: "iTerm2", title: "web", targetURL: nil, windowID: 101,
                terminalTrackingID: "session-web", itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now")
        ]
        let processes = [
            RunningProcessRecord(
                id: "process-web", workspaceID: "workspace", templateName: "web", command: "npm run dev", terminalApp: "iTerm2", windowID: 101,
                terminalTrackingID: "session-web", itermTabIndex: nil, tmuxWindowID: nil, pid: 1, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: nil, exitedAt: nil)
        ]
        let agentWindows = [
            AgentWindowRecord(
                id: "agent", workspaceID: "workspace", provider: .iterm2, label: "Claude Code CLI", terminalTrackingID: "session-agent",
                tmuxWindowID: nil, codexThreadID: nil, windowID: 202, yabaiWindowID: 202, status: .spinning, createdAt: "now", updatedAt: "now")
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
                id: "configured", workspaceID: "workspace", provider: .iterm2, label: "claude", terminalTrackingID: "session-claude",
                tmuxWindowID: nil, codexThreadID: nil, windowID: 202, yabaiWindowID: 202, status: .idle, createdAt: "now", updatedAt: "now"),
            AgentWindowRecord(
                id: "adhoc", workspaceID: "workspace", provider: .iterm2, label: "reviewer", terminalTrackingID: "session-reviewer",
                tmuxWindowID: nil, codexThreadID: nil, windowID: 203, yabaiWindowID: 203, status: .spinning, createdAt: "now", updatedAt: "now"),
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
                id: "win-web", workspaceID: "workspace", app: "iTerm2", name: "web", detail: "npm run dev", targetURL: nil, windowID: 101,
                terminalTrackingID: "session-web", itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now"),
            WindowRecord(
                id: "win-shell", workspaceID: "workspace", app: "iTerm2", name: nil, detail: "* zsh", targetURL: nil, windowID: 102,
                terminalTrackingID: "session-shell", itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 201, lastSeenAt: "now"),
        ]
        let processes = [
            RunningProcessRecord(
                id: "process-web", workspaceID: "workspace", templateName: "web", command: "npm run dev", terminalApp: "iTerm2", windowID: 101,
                terminalTrackingID: "session-web", itermTabIndex: nil, tmuxWindowID: nil, pid: 1, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: nil, exitedAt: nil)
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
                id: "agent-unlabeled", workspaceID: "workspace", provider: .ghostty, label: nil, terminalTrackingID: "ghostty-hook-1",
                terminalNativeID: "ghostty-terminal-1", tmuxWindowID: nil, codexThreadID: nil, windowID: 202, yabaiWindowID: 202, status: .waiting,
                createdAt: "now", updatedAt: "now")
        ]

        let shortcutIndices = AppKitController.workspaceDetailShortcutIndices(
            browserSessions: [], processEntries: [], processesByID: [:], configuredAgentLaunchers: [], agentWindows: agentWindows)

        #expect(shortcutIndices.codingAgentsByIdentity[AppKitController.codingAgentShortcutIdentity(agentWindowID: "agent-unlabeled")] == 1)
    }

    @Test func resolvedCodingAgentEntriesKeepConfiguredSlotsBeforeAdHocAgents() {
        let configuredAgentLaunchers = [AgentLauncher(name: "claude", command: "claude"), AgentLauncher(name: "codex", command: "codex")]
        let agentWindows = [
            AgentWindowRecord(
                id: "matched", workspaceID: "workspace", provider: .iterm2, label: "Claude", terminalTrackingID: "session-claude", tmuxWindowID: nil,
                codexThreadID: nil, windowID: 202, yabaiWindowID: 202, status: .idle, createdAt: "now", updatedAt: "now"),
            AgentWindowRecord(
                id: "adhoc", workspaceID: "workspace", provider: .iterm2, label: "reviewer", terminalTrackingID: "session-reviewer",
                tmuxWindowID: nil, codexThreadID: nil, windowID: 203, yabaiWindowID: 203, status: .spinning, createdAt: "now", updatedAt: "now"),
        ]

        let entries = AppKitController.resolvedCodingAgentRunEntries(configuredAgentLaunchers: configuredAgentLaunchers, agentWindows: agentWindows)

        #expect(entries.map(\.kind) == [.agent, .agentLauncher, .agent])
        #expect(entries.map(\.launcherName) == ["claude", "codex", nil])
        #expect(entries.map { $0.agentWindow?.id } == ["matched", nil, "adhoc"])
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
                id: "agent-waiting", workspaceID: "workspace", provider: .iterm2, label: "Waiting", terminalTrackingID: "session-1",
                tmuxWindowID: nil, codexThreadID: nil, windowID: 101, yabaiWindowID: 101, status: .waiting, createdAt: "2026-01-01T00:00:00Z",
                updatedAt: "2026-01-01T00:01:00Z"),
            AgentWindowRecord(
                id: "agent-done", workspaceID: "workspace", provider: .iterm2, label: "Done", terminalTrackingID: "session-2", tmuxWindowID: nil,
                codexThreadID: nil, windowID: 102, yabaiWindowID: 102, status: .done, createdAt: "2026-01-01T00:00:00Z",
                updatedAt: "2026-01-01T00:02:00Z"),
            AgentWindowRecord(
                id: "agent-idle", workspaceID: "workspace", provider: .iterm2, label: "Idle", terminalTrackingID: "session-3", tmuxWindowID: nil,
                codexThreadID: nil, windowID: 103, yabaiWindowID: 103, status: .idle, createdAt: "2026-01-01T00:00:00Z",
                updatedAt: "2026-01-01T00:03:00Z"),
        ]

        let attentionAgents = AppKitController.alertsAttentionAgentWindows(agents)

        #expect(attentionAgents.map(\.id) == ["agent-waiting", "agent-done"])
    }

    @Test func tmuxBackedRowsUseTmuxIdentityBeforeSharedItermSession() {
        let configuredProcesses = [ProcessTemplate(name: "web server", command: "npm run dev"), ProcessTemplate(name: "claude", command: "claude")]
        let windows = [
            WindowRecord(
                id: "win-web", workspaceID: "workspace", app: "iTerm2", title: "web server", targetURL: nil, windowID: 101,
                terminalTrackingID: "shared-session", itermTabIndex: nil, tmuxWindowID: "@1", role: "terminal", orderIndex: 200, lastSeenAt: "now"),
            WindowRecord(
                id: "win-claude", workspaceID: "workspace", app: "iTerm2", title: "claude", targetURL: nil, windowID: 101,
                terminalTrackingID: "shared-session", itermTabIndex: nil, tmuxWindowID: "@2", role: "terminal", orderIndex: 201, lastSeenAt: "now"),
        ]
        let processes = [
            RunningProcessRecord(
                id: "process-web", workspaceID: "workspace", templateName: "web server", command: "npm run dev", terminalApp: "iTerm2", windowID: 101,
                terminalTrackingID: "shared-session", itermTabIndex: nil, tmuxWindowID: "@1", pid: 1, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: nil, exitedAt: nil),
            RunningProcessRecord(
                id: "process-claude", workspaceID: "workspace", templateName: "claude", command: "claude", terminalApp: "iTerm2", windowID: 101,
                terminalTrackingID: "shared-session", itermTabIndex: nil, tmuxWindowID: "@2", pid: 2, status: .running, logPath: nil,
                lastOutputAt: nil, startedAt: nil, exitedAt: nil),
        ]
        let agentWindows = [
            AgentWindowRecord(
                id: "agent", workspaceID: "workspace", provider: .iterm2, label: "Claude Code CLI", terminalTrackingID: "shared-session",
                tmuxWindowID: "@2", codexThreadID: nil, windowID: 101, yabaiWindowID: 101, status: .idle, createdAt: "now", updatedAt: "now")
        ]

        let entries = AppKitController.orderedWorkspaceRunProcessEntries(
            configuredProcesses: configuredProcesses, windows: windows, processes: processes, agentWindows: agentWindows)

        #expect(entries.count == 1)
        #expect(entries.first?.kind == .process)
        #expect(entries.first?.processID == "process-web")
    }
}
