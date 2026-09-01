import AppKit
import Carbon
import CoreImage
import Foundation
import spacesclientcore
import spacesdeviceapi
import spacesdevicecore
import spacesterminalcore
import spacesterminalghostty
import spacesterminalui
import systembridge
import workspacecore

struct CommandPaletteItem: Sendable {
    enum Source: Sendable {
        case alertsAttention
        case workspaceTarget
        /// A workspace-scoped action row (currently only "Open in Editor") rather than a
        /// focusable runtime target. Excluded from the empty-query recency ranking, which
        /// only ever surfaces `.workspaceTarget` rows, so it appears in the palette only
        /// once the user searches for its workspace or its label.
        case editorAction
    }

    enum Status: Sendable {
        case none
        case process(RunningProcessState)
        case agent(AgentWindowStatus)
        case idle
    }

    let id: String
    let source: Source
    let alertsAttentionID: String?
    let workspaceID: String
    let workspaceTitle: String
    let workspaceBranch: String?
    let projectTitle: String
    let kind: AppKitController.WorkspaceRunShortcutTarget.Kind
    let label: String
    let detail: String?
    let status: Status
    /// Nil for a `.editorAction` row: opening the workspace's Editor is a synchronous,
    /// in-process call to `openWorkspaceEditor(workspaceID:)`, not a window to focus, the
    /// same reason `AlertsController`'s automation-run alert leaves its own `focusRequest`
    /// nil in favor of `automationRunTarget`. Every other row focuses a runtime target.
    let focusRequest: AppKitController.WindowFocusRequest?
    let recentFocusIdentity: String

    var workspaceContextText: String {
        let project = projectTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = workspaceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = workspaceBranch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceDuplicatesBranch = branch?.isEmpty == false && workspace == branch
        return [project, workspaceDuplicatesBranch ? nil : workspace].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " › ")
    }

    var secondaryText: String {
        guard let detail, !detail.isEmpty else { return workspaceContextText }
        return "\(workspaceContextText)  ·  \(detail)"
    }

    var searchCandidate: FuzzyTextSearch.Candidate<String> {
        let combinedText = "\(projectTitle) \(workspaceTitle) \(workspaceBranch ?? "") \(label) \(detail ?? "")"
        return FuzzyTextSearch.Candidate(
            id: id,
            fields: [
                .init(text: projectTitle, weight: 0.92), .init(text: workspaceTitle, weight: 0.92), .init(text: workspaceBranch ?? "", weight: 0.9),
                .init(text: label, weight: 1.0), .init(text: detail ?? "", weight: 0.78), .init(text: secondaryText, weight: 0.84),
                .init(text: combinedText, weight: 0.88), .init(text: Self.searchInitials(for: combinedText), weight: 0.94),
            ])
    }

    var focusIdentity: String {
        // `.editorAction` rows never reach either dedup loop in `visibleCommandPaletteItems`
        // (they're neither `.alertsAttention` nor `.workspaceTarget`), so this branch is
        // unreachable in practice; it exists only to keep this property total.
        guard let focusRequest else { return "editor:\(workspaceID)" }
        switch focusRequest {
        case .workspaceBrowserSession(let workspaceID, let targetURL): return "browser:\(workspaceID):\(targetURL)"
        case .workspaceWindow(let workspaceID, let index): return "window:\(workspaceID):\(index)"
        case .workspaceProcess(let workspaceID, let processID): return "process:\(workspaceID):\(processID)"
        case .workspaceMissingConfiguredProcess(let workspaceID, let processKey): return "missing:\(workspaceID):\(processKey)"
        case .agentWindow(let record): return "agent:\(record.id)"
        case .terminalSession(let workspaceID, let sessionID): return "terminal-session:\(workspaceID):\(sessionID)"
        }
    }

    var visibleIdentity: String {
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        // Ad hoc terminal names are unique within a workspace and remain stable while their live
        // title/foreground command changes. A bell alert and the workspace target therefore describe
        // one visible row even if their overview snapshots carried different secondary text.
        if kind == .window { return "\(workspaceID):\(kind):\(normalizedLabel)" }
        return "\(workspaceID):\(kind):\(normalizedLabel):\(normalizedDetail)"
    }

    var iconSymbol: String {
        switch kind {
        case .browser: return "globe"
        case .process, .missingConfiguredProcess: return "terminal"
        case .window: return (detail?.localizedStandardContains("http") == true) ? "globe" : "chevron.left.forwardslash.chevron.right"
        case .agent: return "cpu.fill"
        }
    }

    var typeKind: RowPrimitives.TypeKind {
        switch kind {
        case .browser: return .browser
        case .agent: return .agent
        case .process, .window, .missingConfiguredProcess: return .process
        }
    }

    var isAlertsAttention: Bool { source == .alertsAttention }

    private static func searchInitials(for text: String) -> String {
        text.split { !$0.isLetter && !$0.isNumber }.compactMap { $0.first.map(String.init) }.joined()
    }

    static func recentFocusIdentity(for focusRequest: AppKitController.WindowFocusRequest, detail: String? = nil) -> String {
        switch focusRequest {
        case .workspaceBrowserSession(let workspaceID, let targetURL): return "browser:\(workspaceID):\(targetURL)"
        case .workspaceWindow(let workspaceID, let index):
            let normalizedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return "window:\(workspaceID):\(index):\(normalizedDetail)"
        case .workspaceProcess(let workspaceID, let processID): return "process:\(workspaceID):\(processID)"
        case .workspaceMissingConfiguredProcess(let workspaceID, let processKey): return "missing:\(workspaceID):\(processKey)"
        case .agentWindow(let record): return "agent:\(record.workspaceID):\(record.id)"
        case .terminalSession(let workspaceID, let sessionID): return "terminal-session:\(workspaceID):\(sessionID)"
        }
    }
}

extension CommandPaletteItem.Status {
    /// The operational status represented by the palette indicator. Keeping this semantic
    /// conversion separate from drawing lets every surface share one status vocabulary.
    var attentionStatus: SidebarAttentionStatus? {
        switch self {
        case .none: return nil
        case .idle: return .inactive
        case .process(let processStatus):
            switch processStatus {
            case .running: return .working
            case .exited: return .failed
            case .idle: return .inactive
            }
        case .agent(let agentStatus):
            switch agentStatus {
            case .spinning: return .working
            case .waiting: return .blocked
            case .done: return .done
            case .idle: return .inactive
            case .exited: return .inactive
            }
        }
    }
}

extension CommandPaletteController {
    nonisolated static func visibleCommandPaletteItems(
        allItems: [CommandPaletteItem], query: String, currentWorkspaceID _: String?, recentFocusIdentities: [String], maxEmptyQueryItems: Int = 9
    ) -> [CommandPaletteItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            let recentRanks = Dictionary(uniqueKeysWithValues: recentFocusIdentities.enumerated().map { ($1, $0) })
            let rankedWorkspaceItems = allItems.enumerated().filter { $0.element.source == .workspaceTarget }.sorted { lhs, rhs in
                let lhsRank = recentRanks[lhs.element.recentFocusIdentity] ?? Int.max
                let rhsRank = recentRanks[rhs.element.recentFocusIdentity] ?? Int.max
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.offset < rhs.offset
            }.map(\.element)
            var items: [CommandPaletteItem] = []
            var seenFocusIdentities: Set<String> = []
            var seenVisibleIdentities: Set<String> = []

            for item in allItems where item.source == .alertsAttention {
                guard seenFocusIdentities.insert(item.focusIdentity).inserted else { continue }
                guard seenVisibleIdentities.insert(item.visibleIdentity).inserted else { continue }
                items.append(item)
                if items.count == maxEmptyQueryItems { break }
            }

            for item in rankedWorkspaceItems {
                guard seenFocusIdentities.insert(item.focusIdentity).inserted else { continue }
                guard seenVisibleIdentities.insert(item.visibleIdentity).inserted else { continue }
                items.append(item)
                if items.count == maxEmptyQueryItems { break }
            }
            return items
        }

        let rankedIDs = FuzzyTextSearch.rank(query: trimmedQuery, candidates: allItems.map(\.searchCandidate)).map(\.id)
        let itemsByID = Dictionary(uniqueKeysWithValues: allItems.map { ($0.id, $0) })
        return rankedIDs.compactMap { itemsByID[$0] }
    }

    /// Session-picker visibility: the rows are host-ordered ("New terminal session"
    /// first, then the sessions in scope) and each row is a distinct choice, so an
    /// empty query shows the list head directly. The normal palette's recency ranking
    /// and focus-identity dedup would collapse picker rows, which are all built
    /// around the same placeholder focus request.
    nonisolated static func visibleSessionPickerItems(allItems: [CommandPaletteItem], query: String, maxEmptyQueryItems: Int = 10)
        -> [CommandPaletteItem]
    {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty { return Array(allItems.prefix(maxEmptyQueryItems)) }
        let rankedIDs = FuzzyTextSearch.rank(query: trimmedQuery, candidates: allItems.map(\.searchCandidate)).map(\.id)
        let itemsByID = Dictionary(uniqueKeysWithValues: allItems.map { ($0.id, $0) })
        return rankedIDs.compactMap { itemsByID[$0] }
    }

    nonisolated private static func commandPaletteKind(
        focusRequest: AppKitController.WindowFocusRequest?, fallbackIcon: String, processStatus: RunningProcessState?,
        agentStatus: AgentWindowStatus?
    ) -> AppKitController.WorkspaceRunShortcutTarget.Kind {
        switch focusRequest {
        case .workspaceBrowserSession: return .browser
        case .workspaceWindow: return .window
        case .workspaceProcess: return .process
        case .workspaceMissingConfiguredProcess: return .missingConfiguredProcess
        case .agentWindow: return .agent
        case .terminalSession: return .window
        case nil:
            if agentStatus != nil { return .agent }
            if processStatus != nil {
                switch fallbackIcon {
                case "globe": return .browser
                case "terminal": return .process
                default: return .window
                }
            }
            switch fallbackIcon {
            case "globe": return .browser
            case "terminal": return .process
            case "cpu.fill": return .agent
            default: return .window
            }
        }
    }

    nonisolated private static func buildCommandPaletteAlertsItems(alertsGroups: [AppKitController.AlertsGroup]) -> [CommandPaletteItem] {
        alertsGroups.filter { !$0.isFromHiddenWorkspace }.flatMap { group in
            group.items.compactMap { entry in
                guard let focusRequest = entry.focusRequest else { return nil }
                let kind = commandPaletteKind(
                    focusRequest: focusRequest, fallbackIcon: entry.icon, processStatus: entry.processStatus, agentStatus: entry.agentStatus)
                let status: CommandPaletteItem.Status =
                    if let processStatus = entry.processStatus { .process(processStatus) } else if let agentStatus = entry.agentStatus {
                        .agent(agentStatus)
                    } else { .none }
                let detail = entry.detail?.nilIfEmpty

                return CommandPaletteItem(
                    id: "alerts::\(entry.attentionID)", source: .alertsAttention, alertsAttentionID: entry.attentionID,
                    workspaceID: group.workspaceID, workspaceTitle: group.workspaceName, workspaceBranch: group.workspaceBranch,
                    projectTitle: group.projectName, kind: kind, label: entry.label, detail: detail, status: status, focusRequest: focusRequest,
                    recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(for: focusRequest, detail: detail))
            }
        }
    }

    nonisolated static func buildCommandPaletteItems(
        overview: SpacesDeviceOverviewPayload, alertsGroups: [AppKitController.AlertsGroup] = [], dismissedAttentionItemIDs: Set<String> = []
    ) -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = buildCommandPaletteAlertsItems(alertsGroups: alertsGroups)
        items.append(
            contentsOf: deviceCommandPaletteWorkspaceItems(
                from: overview, alertsGroups: alertsGroups, dismissedAttentionItemIDs: dismissedAttentionItemIDs))
        return items
    }

    /// `alertsGroups`/`dismissedAttentionItemIDs` default to empty for callers (tests, session-picker
    /// item construction) that don't need alert-aware status; production palette loads always pass the
    /// live values so an acknowledged process exit reads as idle here the same way it does in the sidebar.
    nonisolated static func deviceCommandPaletteWorkspaceItems(
        from overview: SpacesDeviceOverviewPayload, deviceID: String = SpacesDeviceRecord.localDeviceID, alertsGroups: [AppKitController.AlertsGroup] = [],
        dismissedAttentionItemIDs: Set<String> = []
    ) -> [CommandPaletteItem] {
        let mapped = AppKitController.deviceSidebarData(from: overview, deviceID: deviceID)
        var items: [CommandPaletteItem] = []
        let sessionsByID = Dictionary(overview.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let workspacesByID = Dictionary(overview.workspaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // The palette lists what the sidebar lists, so it walks through the same visibility rules rather
        // than the raw overview: hidden workspaces and hidden projects leave both surfaces together.
        for project in SidebarVisibility.deviceProjects(mapped.projects, deviceID: deviceID, workspacesByProject: mapped.workspacesByProject) {
            for workspace in mapped.workspacesByProject[project.id] ?? [] where SidebarVisibility.isVisibleWorkspace(workspace, inProject: project) {
                guard let deviceWorkspace = workspacesByID[workspace.id] else { continue }
                let detail = SpacesDeviceWorkspaceDetailViewModel(workspace: deviceWorkspace)
                let windows = AppKitController.deviceTerminalWindows(from: detail.terminalRows)
                let processes = AppKitController.runningProcesses(from: detail.processRows)
                let agentWindows = AppKitController.agentWindows(from: detail.codingAgentRows)
                let settings = AppKitController.localWorkspaceSettings(from: detail.config)
                let browserSessions = detail.config.resolvedBrowserSessions.map(AppKitController.localBrowserSession(from:))
                let processEntries = AppKitController.orderedWorkspaceRunProcessEntries(
                    configuredProcesses: settings.processes, windows: windows, processes: processes, agentWindows: agentWindows)
                let processesByID = Dictionary(uniqueKeysWithValues: processes.map { ($0.id, $0) })
                let shortcutTargets = AppKitController.orderedWorkspaceRunShortcutTargets(
                    browserSessions: browserSessions, processEntries: processEntries, processesByID: processesByID, agentWindows: agentWindows)
                for (offset, target) in shortcutTargets.enumerated() {
                    let itemID = "\(workspace.id)::\(offset)"
                    switch target.kind {
                    case .browser:
                        guard let targetURL = target.targetURL else { continue }
                        let label = AppKitController.browserSessionDisplayName(for: targetURL, sessions: browserSessions) ?? targetURL
                        items.append(
                            CommandPaletteItem(
                                id: itemID, source: .workspaceTarget, alertsAttentionID: nil, workspaceID: workspace.id,
                                workspaceTitle: workspace.displayName, workspaceBranch: workspace.branch, projectTitle: project.name,
                                kind: target.kind, label: label, detail: targetURL, status: .none,
                                focusRequest: .workspaceBrowserSession(workspaceID: workspace.id, targetURL: targetURL),
                                recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(
                                    for: .workspaceBrowserSession(workspaceID: workspace.id, targetURL: targetURL), detail: targetURL)))
                    case .process:
                        guard let processID = target.processID, let process = processesByID[processID] else { continue }
                        // Same downgrade the sidebar row applies: an acknowledged exit reads as idle here
                        // rather than exited, until the process exits again with a new alert identity.
                        let isAcknowledged = AlertsController.isProcessExitAcknowledged(
                            processID: processID, workspaceID: workspace.id, alertsGroups: alertsGroups,
                            dismissedAttentionItemIDs: dismissedAttentionItemIDs)
                        let status: CommandPaletteItem.Status = isAcknowledged ? .idle : .process(process.status)
                        items.append(
                            CommandPaletteItem(
                                id: itemID, source: .workspaceTarget, alertsAttentionID: nil, workspaceID: workspace.id,
                                workspaceTitle: workspace.displayName, workspaceBranch: workspace.branch, projectTitle: project.name,
                                kind: target.kind, label: process.templateName, detail: process.command, status: status,
                                focusRequest: .workspaceProcess(workspaceID: workspace.id, processID: processID),
                                recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(
                                    for: .workspaceProcess(workspaceID: workspace.id, processID: processID), detail: process.command)))
                    case .window:
                        guard let windowListIndex = target.windowListIndex, windows.indices.contains(windowListIndex) else { continue }
                        let window = windows[windowListIndex]
                        let rowText = AppKitController.terminalFallbackRowText(name: window.name, detail: window.detail, app: window.app)
                        items.append(
                            CommandPaletteItem(
                                id: itemID, source: .workspaceTarget, alertsAttentionID: nil, workspaceID: workspace.id,
                                workspaceTitle: workspace.displayName, workspaceBranch: workspace.branch, projectTitle: project.name,
                                kind: target.kind, label: rowText.label,
                                detail: AppKitController.terminalPaletteSecondaryLabel(
                                    liveTitle: rowText.detail, sessionID: window.terminalTrackingID, sessionsByID: sessionsByID), status: .none,
                                focusRequest: .workspaceWindow(workspaceID: workspace.id, index: windowListIndex + 1),
                                // Recency is keyed off the row's name: which row was last focused must not
                                // turn on what its program happens to be printing.
                                recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(
                                    for: .workspaceWindow(workspaceID: workspace.id, index: windowListIndex + 1), detail: rowText.label)))
                    case .missingConfiguredProcess:
                        guard let processKey = target.processKey else { continue }
                        items.append(
                            CommandPaletteItem(
                                id: itemID, source: .workspaceTarget, alertsAttentionID: nil, workspaceID: workspace.id,
                                workspaceTitle: workspace.displayName, workspaceBranch: workspace.branch, projectTitle: project.name,
                                kind: target.kind, label: processKey, detail: nil, status: .idle,
                                focusRequest: .workspaceMissingConfiguredProcess(workspaceID: workspace.id, processKey: processKey),
                                recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(
                                    for: .workspaceMissingConfiguredProcess(workspaceID: workspace.id, processKey: processKey))))
                    case .agent:
                        guard let agentWindow = target.agentWindow,
                            let agentRow = detail.codingAgentRows.first(where: { ($0.agentID ?? $0.id) == agentWindow.id })
                        else { continue }
                        let label = agentWindow.label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Coding Agent"
                        let detail = AppKitController.terminalPaletteSecondaryLabel(
                            liveTitle: agentRow.liveTitle, sessionID: agentRow.sessionID, sessionsByID: sessionsByID)
                        items.append(
                            CommandPaletteItem(
                                id: itemID, source: .workspaceTarget, alertsAttentionID: nil, workspaceID: workspace.id,
                                workspaceTitle: workspace.displayName, workspaceBranch: workspace.branch, projectTitle: project.name,
                                kind: target.kind, label: label, detail: detail, status: .agent(agentWindow.status),
                                focusRequest: .agentWindow(agentWindow),
                                recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(for: .agentWindow(agentWindow), detail: detail)))
                    }
                }
                // Every visible workspace gets one editor row regardless of what runtime targets it
                // has, mirroring the sidebar row's "Open in Editor" item, which is available whether
                // or not the workspace is running. `kind: .window` reuses the same icon a foreground
                // code pane gets (`iconSymbol`'s `.window` case falls back to the code-brackets glyph
                // when `detail` isn't a URL), since this row is not itself a runtime target with an
                // index in `WorkspaceRunShortcutTarget.Kind`'s numbered-shortcut vocabulary.
                items.append(
                    CommandPaletteItem(
                        id: "\(workspace.id)::editor", source: .editorAction, alertsAttentionID: nil, workspaceID: workspace.id,
                        workspaceTitle: workspace.displayName, workspaceBranch: workspace.branch, projectTitle: project.name, kind: .window,
                        label: "Open in Editor", detail: nil, status: .none, focusRequest: nil, recentFocusIdentity: "editor:\(workspace.id)"))
            }
        }

        return items
    }

    func loadCommandPaletteItemsSnapshot() async -> Result<[CommandPaletteItem], Error> {
        await Self.commandPaletteItemsSnapshot(alertsGroups: deviceModel.alertsGroups, dismissedAttentionItemIDs: alerts.dismissedAlertsAttentionItemIDs)
    }

    nonisolated private static func commandPaletteItemsSnapshot(alertsGroups: [AppKitController.AlertsGroup], dismissedAttentionItemIDs: Set<String>) async -> Result<
        [CommandPaletteItem], Error
    > {
        await Task.detached(priority: .userInitiated) {
            do {
                let localOverview = try SpacesDeviceClient.localOverview(
                    database: SpacesClientDatabase.defaultDatabase(), clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                return .success(
                    buildCommandPaletteItems(
                        overview: localOverview.overview, alertsGroups: alertsGroups, dismissedAttentionItemIDs: dismissedAttentionItemIDs))
            } catch { return .failure(error) }
        }.value
    }

}

extension String {
    fileprivate var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
