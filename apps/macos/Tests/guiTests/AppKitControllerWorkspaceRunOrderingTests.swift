import Testing
import streamctl

@testable import gui

@Suite struct AppKitControllerWorkspaceRunOrderingTests {
    @Test func configuredProcessesKeepSettingsOrderBeforeExtraWindows() {
        let configuredProcesses = [
            ProcessTemplate(name: "api", command: "run api"),
            ProcessTemplate(name: "web", command: "run web"),
        ]
        let windows = [
            WindowRecord(
                id: "win-web", workspaceID: "workspace", app: "iTerm2", title: "web", targetURL: nil, windowID: 102, itermSessionID: "session-web",
                itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now"),
            WindowRecord(
                id: "win-api", workspaceID: "workspace", app: "iTerm2", title: "api", targetURL: nil, windowID: 101, itermSessionID: "session-api",
                itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 201, lastSeenAt: "now"),
            WindowRecord(
                id: "win-shell", workspaceID: "workspace", app: "iTerm2", title: "* zsh", targetURL: nil, windowID: 103, itermSessionID: "session-shell",
                itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 202, lastSeenAt: "now"),
        ]
        let processes = [
            RunningProcessRecord(
                id: "process-web", workspaceID: "workspace", templateName: "web", command: "run web", terminalApp: "iTerm2", windowID: 102,
                itermSessionID: "session-web", itermTabIndex: nil, tmuxWindowID: nil, pid: 2, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: nil, exitedAt: nil),
            RunningProcessRecord(
                id: "process-api", workspaceID: "workspace", templateName: "api", command: "run api", terminalApp: "iTerm2", windowID: 101,
                itermSessionID: "session-api", itermTabIndex: nil, tmuxWindowID: nil, pid: 1, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: nil, exitedAt: nil),
        ]

        let entries = AppKitController.orderedWorkspaceRunProcessEntries(
            configuredProcesses: configuredProcesses,
            windows: windows,
            processes: processes,
            agentWindows: [])

        #expect(entries.map(\.kind) == [.process, .process, .window])
        #expect(entries.map(\.processID) == ["process-api", "process-web", nil])
        #expect(entries.map(\.windowListIndex) == [nil, nil, 2])
    }

    @Test func agentClaimedTerminalRowsAreExcludedFromProcessOrdering() {
        let configuredProcesses = [ProcessTemplate(name: "api", command: "run api")]
        let windows = [
            WindowRecord(
                id: "win-agent", workspaceID: "workspace", app: "iTerm2", title: "agent", targetURL: nil, windowID: 104, itermSessionID: "session-agent",
                itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 200, lastSeenAt: "now"),
            WindowRecord(
                id: "win-api", workspaceID: "workspace", app: "iTerm2", title: "api", targetURL: nil, windowID: 101, itermSessionID: "session-api",
                itermTabIndex: nil, tmuxWindowID: nil, role: "terminal", orderIndex: 201, lastSeenAt: "now"),
        ]
        let processes = [
            RunningProcessRecord(
                id: "process-api", workspaceID: "workspace", templateName: "api", command: "run api", terminalApp: "iTerm2", windowID: 101,
                itermSessionID: "session-api", itermTabIndex: nil, tmuxWindowID: nil, pid: 1, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: nil, exitedAt: nil),
            RunningProcessRecord(
                id: "process-agent", workspaceID: "workspace", templateName: "agent", command: "run agent", terminalApp: "iTerm2", windowID: 104,
                itermSessionID: "session-agent", itermTabIndex: nil, tmuxWindowID: nil, pid: 2, status: .running, logPath: nil, lastOutputAt: nil,
                startedAt: nil, exitedAt: nil),
        ]
        let agentWindows = [
            AgentWindowRecord(
                id: "agent", workspaceID: "workspace", provider: .iterm2, label: "Agent", itermSessionID: "session-agent", tmuxWindowID: nil,
                codexThreadID: nil, windowID: 104, yabaiWindowID: 104, status: .spinning, createdAt: "now", updatedAt: "now")
        ]

        let entries = AppKitController.orderedWorkspaceRunProcessEntries(
            configuredProcesses: configuredProcesses,
            windows: windows,
            processes: processes,
            agentWindows: agentWindows)

        #expect(entries.count == 1)
        #expect(entries.first?.kind == .process)
        #expect(entries.first?.processID == "process-api")
    }
}
