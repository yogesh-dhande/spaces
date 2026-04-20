import Foundation
import streamctl

struct JSONEnvelope<Payload: Encodable>: Encodable {
    let ok = true
    let data: Payload
}

struct JSONErrorEnvelope: Encodable {
    struct JSONError: Encodable {
        let code: String
        let message: String
    }

    let ok = false
    let error: JSONError
}

struct CLITextOrJSONOutput {
    let wantsJSON: Bool

    func emit<Payload: Encodable>(text: @autoclosure () -> String, json: @autoclosure () -> Payload) throws {
        if wantsJSON {
            try printJSON(JSONEnvelope(data: json()))
        } else {
            print(text())
        }
    }

    func emitLines<Payload: Encodable>(text: @autoclosure () -> [String], json: @autoclosure () -> Payload) throws {
        if wantsJSON {
            try printJSON(JSONEnvelope(data: json()))
        } else {
            for line in text() { print(line) }
        }
    }

    func printJSON<Payload: Encodable>(_ payload: Payload) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "mx.cli", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode JSON output."])
        }
        print(text)
    }

    static func emitError(_ error: Error, wantsJSON: Bool) {
        guard wantsJSON else {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            return
        }

        let nsError = error as NSError
        let payload = JSONErrorEnvelope(
            error: .init(code: stableErrorCode(for: nsError), message: nsError.localizedDescription))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(payload), let text = String(data: data, encoding: .utf8) {
            fputs("\(text)\n", stderr)
        } else {
            fputs("{\"ok\":false,\"error\":{\"code\":\"mx.cli.encoding_failed\",\"message\":\"\(nsError.localizedDescription)\"}}\n", stderr)
        }
    }

    private static func stableErrorCode(for error: NSError) -> String {
        let rawDomain = error.domain.isEmpty ? "mx.error" : error.domain
        let normalizedDomain = rawDomain
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: ".")
        return "\(normalizedDomain).\(error.code)"
    }
}

struct SettingsSnapshot: Encodable {
    let editor: String?
    let terminalHost: String
    let portRange: String
    let guiHotkey: String
    let guiLeaderHotkey: String
    let guiDashboardShortcut: String
    let guiAddProjectShortcut: String
    let guiAddWorkspaceShortcut: String
    let guiReloadShortcut: String
    let guiNextShortcut: String
    let guiPrevShortcut: String
    let guiOpenEditorShortcut: String
    let guiOpenTerminalShortcut: String
    let guiOpenFinderShortcut: String
    let guiOpenSettingsShortcut: String
    let guiTooltipShortcut: String
    let guiWindowShortcut: String
    let guiWindowSequenceShortcut: String
    let itermFocusPulseColor: String
    let itermFocusPulseEnabled: Bool
}

extension SettingsSnapshot {
    static func load(from orchestrator: MuxyOrchestrator) throws -> SettingsSnapshot {
        let config = try orchestrator.appConfig()
        let pulseColor = try orchestrator.itermFocusPulseColor()
        return SettingsSnapshot(
            editor: config.editor?.rawValue,
            terminalHost: config.terminalHost.rawValue,
            portRange: "\(config.portRange.start)-\(config.portRange.end)",
            guiHotkey: try orchestrator.guiHotkey(),
            guiLeaderHotkey: try orchestrator.guiLeaderHotkey(),
            guiDashboardShortcut: try orchestrator.guiDashboardShortcut(),
            guiAddProjectShortcut: try orchestrator.guiAddProjectShortcut(),
            guiAddWorkspaceShortcut: try orchestrator.guiAddWorkspaceShortcut(),
            guiReloadShortcut: try orchestrator.guiReloadShortcut(),
            guiNextShortcut: try orchestrator.guiNextShortcut(),
            guiPrevShortcut: try orchestrator.guiPreviousShortcut(),
            guiOpenEditorShortcut: try orchestrator.guiOpenEditorShortcut(),
            guiOpenTerminalShortcut: try orchestrator.guiOpenTerminalShortcut(),
            guiOpenFinderShortcut: try orchestrator.guiOpenFinderShortcut(),
            guiOpenSettingsShortcut: try orchestrator.guiOpenSettingsShortcut(),
            guiTooltipShortcut: try orchestrator.guiTooltipShortcut(),
            guiWindowShortcut: try orchestrator.guiWindowShortcut(),
            guiWindowSequenceShortcut: try orchestrator.guiWindowSequenceShortcut(),
            itermFocusPulseColor: "\(pulseColor.0),\(pulseColor.1),\(pulseColor.2)",
            itermFocusPulseEnabled: try orchestrator.itermFocusPulseEnabled())
    }
}

struct SettingValuePayload: Encodable {
    let name: String
    let value: String
}

struct MutationResultPayload<Resource: Encodable>: Encodable {
    let message: String
    let resource: Resource?
}

struct ProjectSummaryPayload: Encodable {
    let id: String
    let name: String
    let dir: String
    let isGitRepo: Bool
    let defaultBranch: String?
}

extension ProjectSummaryPayload {
    init(_ value: ProjectSummary) {
        id = value.id
        name = value.name
        dir = value.dir
        isGitRepo = value.isGitRepo
        defaultBranch = value.defaultBranch
    }
}

struct WorkspaceSummaryPayload: Encodable {
    let id: String
    let title: String
    let branch: String?
    let targetBranch: String?
    let dir: String
    let isRunning: Bool
    let isArchived: Bool
    let isActive: Bool
    let isDefault: Bool
    let tooltip: String?
}

extension WorkspaceSummaryPayload {
    init(_ value: WorkspaceSummary) {
        id = value.id
        title = value.title
        branch = value.branch
        targetBranch = value.targetBranch
        dir = value.dir
        isRunning = value.isRunning
        isArchived = value.isArchived
        isActive = value.isActive
        isDefault = value.isDefault
        tooltip = value.tooltip
    }
}

struct WorkspaceSettingsPayload: Encodable {
    let stopScript: String?
    let ports: [PortDefinition]
    let processes: [ProcessTemplate]
    let statusChecks: [StatusCheckDefinition]
    let browserSessions: [BrowserSession]
}

extension WorkspaceSettingsPayload {
    init(_ value: WorkspaceSettings) {
        stopScript = value.stopScript
        ports = value.ports
        processes = value.processes
        statusChecks = value.statusChecks
        browserSessions = value.browserSessions
    }
}

struct PortAllocationPayload: Encodable {
    let name: String
    let port: Int
}

struct StatusResultPayload: Encodable {
    let processID: String
    let checkName: String
    let status: String
    let message: String?
    let lastRunAt: String?
}

extension StatusResultPayload {
    init(_ value: StatusResult) {
        processID = value.processID
        checkName = value.checkName
        status = value.status.rawValue
        message = value.message
        lastRunAt = value.lastRunAt
    }
}

struct WindowRecordPayload: Encodable {
    let id: String
    let workspaceID: String
    let app: String
    let title: String?
    let targetURL: String?
    let windowID: Int?
    let itermSessionID: String?
    let itermTabIndex: Int?
    let tmuxWindowID: String?
    let role: String
    let orderIndex: Int
    let lastSeenAt: String
}

extension WindowRecordPayload {
    init(_ value: WindowRecord) {
        id = value.id
        workspaceID = value.workspaceID
        app = value.app
        title = value.title
        targetURL = value.targetURL
        windowID = value.windowID
        itermSessionID = value.itermSessionID
        itermTabIndex = value.itermTabIndex
        tmuxWindowID = value.tmuxWindowID
        role = value.role
        orderIndex = value.orderIndex
        lastSeenAt = value.lastSeenAt
    }
}

struct WorkspaceRuntimeStatusPayload: Encodable {
    let workspaceID: String
    let lifecycleState: String
    let runtimeHealth: String
    let hasTrackedRuntimeIndicators: Bool
    let runningProcessCount: Int
    let exitedProcessCount: Int
    let failedCheckCount: Int
    let waitingAgentWindowCount: Int
    let missingConfiguredProcessCount: Int
    let missingConfiguredBrowserSessionCount: Int
    let isDegraded: Bool
    let warningSummary: String?
}

extension WorkspaceRuntimeStatusPayload {
    init(_ value: WorkspaceRuntimeStatus) {
        workspaceID = value.workspaceID
        lifecycleState = value.lifecycleState.rawValue
        runtimeHealth = value.runtimeHealth.rawValue
        hasTrackedRuntimeIndicators = value.hasTrackedRuntimeIndicators
        runningProcessCount = value.runningProcessCount
        exitedProcessCount = value.exitedProcessCount
        failedCheckCount = value.failedCheckCount
        waitingAgentWindowCount = value.waitingAgentWindowCount
        missingConfiguredProcessCount = value.missingConfiguredProcessCount
        missingConfiguredBrowserSessionCount = value.missingConfiguredBrowserSessionCount
        isDegraded = value.isDegraded
        warningSummary = value.warningSummary
    }
}

struct WorkspaceRuntimePayload: Encodable {
    let status: WorkspaceRuntimeStatusPayload
    let processes: [RunningProcessRecord]
    let windows: [WindowRecordPayload]
    let statusResultsByProcessID: [String: [StatusResultPayload]]
    let agentWindows: [AgentWindowRecord]
}

struct DashboardPayload: Encodable {
    struct Group: Encodable {
        let projectName: String
        let workspaceID: String
        let workspaceName: String
        let latestDate: String?
        let items: [Item]
    }

    struct Item: Encodable {
        struct FocusRequest: Encodable {
            let kind: String
            let workspaceID: String
            let windowIndex: Int?
            let processID: String?
            let agentWindowID: String?
            let targetURL: String?
        }

        let attentionID: String
        let kind: String
        let icon: String
        let label: String
        let detail: String?
        let processStatus: String?
        let agentStatus: String?
        let statusChecks: [StatusResultPayload]
        let eventDate: String?
        let focusRequest: FocusRequest?
    }

    let dismissedAttentionItemIDs: [String]
    let groups: [Group]
}

enum DashboardPayloadBuilder {
    static func build(orchestrator: MuxyOrchestrator) throws -> DashboardPayload {
        let projects = try orchestrator.listProjects()
        var workspacesByProject: [String: [WorkspaceSummary]] = [:]
        for project in projects {
            workspacesByProject[project.id] = try orchestrator.listWorkspaces(projectID: project.id, includeArchived: false)
        }

        let iso8601Formatter = ISO8601DateFormatter()
        let dismissedIDs = Array(try orchestrator.dashboardDismissedAttentionItemIDs()).sorted()
        var groups: [DashboardPayload.Group] = []

        for project in projects {
            for workspace in workspacesByProject[project.id] ?? [] {
                let agentWindows = (try? orchestrator.agentWindows(workspaceID: workspace.id)) ?? []
                let attentionAgentWindows = agentWindows.filter { $0.status == .waiting || $0.status == .done }
                guard workspace.isRunning || !attentionAgentWindows.isEmpty else { continue }

                let processes = workspace.isRunning ? ((try? orchestrator.runningProcesses(workspaceID: workspace.id)) ?? []) : []
                let windows = workspace.isRunning ? ((try? orchestrator.windows(workspaceID: workspace.id)) ?? []) : []
                let configuredSessions = workspace.isRunning ? ((try? orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspace.id)) ?? []) : []

                var processByWindowID: [Int: RunningProcessRecord] = [:]
                for process in processes {
                    if let windowID = process.windowID { processByWindowID[windowID] = process }
                }

                var statusResultsByProcessID: [String: [StatusResult]] = [:]
                for process in processes {
                    statusResultsByProcessID[process.id] = (try? orchestrator.statusResults(processID: process.id)) ?? []
                }

                var items: [DashboardPayload.Item] = []
                var matchedProcessIDs: Set<String> = []

                for (index, window) in windows.enumerated() {
                    guard let windowID = window.windowID, let process = processByWindowID[windowID] else { continue }
                    matchedProcessIDs.insert(process.id)
                    let allChecks = statusResultsByProcessID[process.id] ?? []
                    let failedChecks = allChecks.filter { $0.status == .failed }
                    guard process.status == .exited || !failedChecks.isEmpty else { continue }

                    let presentation = itemPresentation(window: window, process: process, configuredSessions: configuredSessions)
                    let eventDate = process.status == .exited
                        ? process.exitedAt
                        : failedChecks.compactMap(\.lastRunAt).max()

                    items.append(
                        DashboardPayload.Item(
                            attentionID: dashboardAttentionID(process: process, failedChecks: failedChecks),
                            kind: window.role == "browser" ? "browser" : (window.role == "terminal" ? "process" : "window"),
                            icon: presentation.icon,
                            label: presentation.label,
                            detail: presentation.detail,
                            processStatus: process.status.rawValue,
                            agentStatus: nil,
                            statusChecks: allChecks.map(StatusResultPayload.init),
                            eventDate: eventDate,
                            focusRequest: dashboardFocusRequest(window: window, windowListIndex: index + 1, process: process, workspaceID: workspace.id)))
                }

                for process in processes where !matchedProcessIDs.contains(process.id) {
                    let allChecks = statusResultsByProcessID[process.id] ?? []
                    let failedChecks = allChecks.filter { $0.status == .failed }
                    guard process.status == .exited || !failedChecks.isEmpty else { continue }
                    let eventDate = process.status == .exited
                        ? process.exitedAt
                        : failedChecks.compactMap(\.lastRunAt).max()
                    items.append(
                        DashboardPayload.Item(
                            attentionID: dashboardAttentionID(process: process, failedChecks: failedChecks),
                            kind: "process",
                            icon: "terminal",
                            label: process.templateName,
                            detail: process.command,
                            processStatus: process.status.rawValue,
                            agentStatus: nil,
                            statusChecks: allChecks.map(StatusResultPayload.init),
                            eventDate: eventDate,
                            focusRequest: .init(
                                kind: "workspace_process",
                                workspaceID: workspace.id,
                                windowIndex: nil,
                                processID: process.id,
                                agentWindowID: nil,
                                targetURL: nil)))
                }

                for agentWindow in attentionAgentWindows {
                    items.append(
                        DashboardPayload.Item(
                            attentionID: dashboardAttentionID(agentWindow: agentWindow),
                            kind: "agent",
                            icon: "cpu.fill",
                            label: agentWindow.label ?? "Coding Agent CLI",
                            detail: nil,
                            processStatus: nil,
                            agentStatus: agentWindow.status.rawValue,
                            statusChecks: [],
                            eventDate: agentWindow.updatedAt,
                            focusRequest: .init(
                                kind: "agent_window",
                                workspaceID: agentWindow.workspaceID,
                                windowIndex: nil,
                                processID: nil,
                                agentWindowID: agentWindow.id,
                                targetURL: nil)))
                }

                guard !items.isEmpty else { continue }
                items.sort { lhs, rhs in
                    switch (lhs.eventDate, rhs.eventDate) {
                    case let (a?, b?): return a > b
                    case (nil, _): return false
                    case (_, nil): return true
                    }
                }

                let latestDate = items.compactMap { item in
                    item.eventDate.flatMap { iso8601Formatter.date(from: $0) }.map { iso8601Formatter.string(from: $0) }
                }.max()

                groups.append(
                    .init(
                        projectName: project.name,
                        workspaceID: workspace.id,
                        workspaceName: workspace.name,
                        latestDate: latestDate,
                        items: items))
            }
        }

        groups.sort { lhs, rhs in
            switch (lhs.latestDate, rhs.latestDate) {
            case let (a?, b?): return a > b
            case (nil, _): return false
            case (_, nil): return true
            }
        }

        return DashboardPayload(dismissedAttentionItemIDs: dismissedIDs, groups: groups)
    }

    private static func dashboardAttentionID(process: RunningProcessRecord, failedChecks: [StatusResult]) -> String {
        if process.status == .exited {
            return "process:\(process.id):exited:\(process.exitedAt ?? "unknown")"
        }
        let failedCheckNames = failedChecks.map(\.checkName).sorted().joined(separator: ",")
        let latestFailure = failedChecks.compactMap(\.lastRunAt).max() ?? "unknown"
        return "process:\(process.id):failed:\(failedCheckNames):\(latestFailure)"
    }

    private static func dashboardAttentionID(agentWindow: AgentWindowRecord) -> String {
        "agent:\(agentWindow.id):\(agentWindow.status.rawValue):\(agentWindow.updatedAt)"
    }

    private static func dashboardFocusRequest(
        window: WindowRecord,
        windowListIndex: Int,
        process: RunningProcessRecord,
        workspaceID: String
    ) -> DashboardPayload.Item.FocusRequest {
        if window.role == "browser", let targetURL = window.targetURL, !targetURL.isEmpty {
            return .init(
                kind: "workspace_browser_session",
                workspaceID: workspaceID,
                windowIndex: nil,
                processID: nil,
                agentWindowID: nil,
                targetURL: targetURL)
        }
        if window.role == "terminal" {
            return .init(
                kind: "workspace_process",
                workspaceID: workspaceID,
                windowIndex: nil,
                processID: process.id,
                agentWindowID: nil,
                targetURL: nil)
        }
        return .init(
            kind: "workspace_window",
            workspaceID: workspaceID,
            windowIndex: windowListIndex,
            processID: nil,
            agentWindowID: nil,
            targetURL: nil)
    }

    private static func itemPresentation(
        window: WindowRecord,
        process: RunningProcessRecord,
        configuredSessions: [BrowserSession]
    ) -> (icon: String, label: String, detail: String?) {
        switch window.role {
        case "browser":
            if let name = browserSessionDisplayName(for: window.targetURL, sessions: configuredSessions), let url = window.targetURL {
                return ("globe", name, url)
            }
            return ("globe", window.targetURL ?? window.title ?? window.app, nil)
        case "terminal":
            return ("terminal", process.templateName, process.command)
        default:
            return ("chevron.left.forwardslash.chevron.right", window.title ?? window.app, nil)
        }
    }

    private static func browserSessionDisplayName(for targetURL: String?, sessions: [BrowserSession]) -> String? {
        guard let targetURL, !targetURL.isEmpty else { return nil }
        var bestMatch: (length: Int, name: String)?
        for session in sessions {
            guard let prefix = session.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                let name = session.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                !prefix.isEmpty,
                !name.isEmpty,
                targetURL.hasPrefix(prefix)
            else { continue }
            if let bestMatch, bestMatch.length >= prefix.count { continue }
            bestMatch = (prefix.count, name)
        }
        return bestMatch?.name
    }
}
