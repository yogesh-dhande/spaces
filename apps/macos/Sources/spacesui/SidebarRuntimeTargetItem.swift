import Foundation
import spacesclientcore
import spacesdevicecore
import workspacecore

/// One compact sidebar row for a focusable runtime target of a workspace. Items are
/// derived from the same ordered target list the numbered shortcuts use
/// (`workspaceShortcutTargets`). Window cycling uses the already-open subset of those
/// targets with MRU ordering, so sidebar rows, ⌘-number hints, and cycle identities stay
/// aligned without requiring the same visible order.
struct SidebarRuntimeTargetItem: Hashable, Sendable {
    /// Stable per-target identity, using the cycle-cursor key scheme
    /// (e.g. `process:<id>`, `terminal:<sessionID>`, `browser:<url>`).
    let key: String
    let title: String
    /// Dimmed secondary text trailing the title: the title the row's terminal last reported. Ad hoc
    /// shells and coding agents carry one, since both run whatever the user is working on and their names
    /// say nothing about it. A process row is described by the command its config entry names, so it
    /// carries none.
    let detail: String?
    let kind: AppKitController.WorkspaceRunShortcutTarget.Kind
    /// `nil` for browser targets: whether a browser session is "open" is a Chrome-side
    /// question the sidebar row does not answer.
    let runState: SpacesDeviceRunState?
    /// 1-based numbered-shortcut index (1...10) in the workspace's ordered target list.
    let shortcutIndex: Int?
    let sessionID: String?
    let canRun: Bool
    let canStop: Bool
    let canRestart: Bool
    // Per-kind identities consumed by the context-menu actions and rename.
    let processID: String?
    let processKey: String?
    let processTemplateID: String?
    let agentID: String?
    let browserTargetURL: String?

    /// Coding-agent activity is richer than the process-like run state: a running session may be
    /// actively working, blocked on input, or finished. Non-agent rows leave this nil.
    let agentActivityState: SpacesDeviceCodingAgentActivityState?

    init(
        key: String, title: String, detail: String?, kind: AppKitController.WorkspaceRunShortcutTarget.Kind, runState: SpacesDeviceRunState?,
        shortcutIndex: Int?, sessionID: String?, canRun: Bool, canStop: Bool, canRestart: Bool, processID: String?, processKey: String?,
        processTemplateID: String?, agentID: String?, browserTargetURL: String?, agentActivityState: SpacesDeviceCodingAgentActivityState? = nil
    ) {
        self.key = key
        self.title = title
        self.detail = detail
        self.kind = kind
        self.runState = runState
        self.shortcutIndex = shortcutIndex
        self.sessionID = sessionID
        self.canRun = canRun
        self.canStop = canStop
        self.canRestart = canRestart
        self.processID = processID
        self.processKey = processKey
        self.processTemplateID = processTemplateID
        self.agentID = agentID
        self.browserTargetURL = browserTargetURL
        self.agentActivityState = agentActivityState
    }
}

/// Semantic attention carried by sidebar runtime rows and rolled up to their workspace header. Raw
/// ordering is the product priority: red failure, blocked, done, working, then inactive.
enum SidebarAttentionStatus: Int, Hashable, Sendable, Comparable {
    case inactive
    case working
    case done
    case blocked
    case failed

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    static func resolve(
        kind: AppKitController.WorkspaceRunShortcutTarget.Kind, runState: SpacesDeviceRunState?,
        agentActivityState: SpacesDeviceCodingAgentActivityState?
    ) -> Self? {
        if kind == .agent {
            switch agentActivityState {
            case .spinning: return .working
            case .waiting: return .blocked
            case .done: return .done
            case .idle, .exited, nil: return .inactive
            }
        }
        switch kind {
        case .process, .missingConfiguredProcess:
            switch runState {
            case .running: return .working
            case .exited: return .failed
            case .notStarted, nil: return .inactive
            }
        // Ad hoc terminals and browser sessions are not managed process/agent rows, so their
        // lifecycle does not contribute an operational color or workspace attention state.
        case .browser, .window: return nil
        case .agent: return .inactive
        }
    }

    static func highest<S: Sequence>(_ statuses: S) -> Self where S.Element == Self { statuses.max() ?? .inactive }

    /// Filled marks mean active or completed work. Failure and inactivity use hollow marks everywhere,
    /// including the compact workspace rollup and the larger palette indicator.
    var usesFilledIndicator: Bool { self != .failed && self != .inactive }
}

extension SidebarRuntimeTargetItem {
    var attentionStatus: SidebarAttentionStatus? {
        SidebarAttentionStatus.resolve(kind: kind, runState: runState, agentActivityState: agentActivityState)
    }
}

/// Where a sidebar row's rename is stored: on the row's own session, in the workspace config entry that
/// names it, or nowhere.
enum SidebarRuntimeTargetRenameDestination: Equatable, Sendable {
    case terminalSession(sessionID: String)
    case agentSession(agentID: String)
    case configuredProcess
    case configuredBrowserSession
    /// Nothing to store: the name is unchanged, an empty name arrived on a row whose config entry must
    /// keep one, or the row carries no identity to rename.
    case discard
}

extension AppKitController {
    /// Builds the sidebar's runtime-target rows for a workspace from its overview detail.
    nonisolated static func sidebarRuntimeTargetItems(detail: SpacesDeviceWorkspaceDetailViewModel, browserSessions: [BrowserSession])
        -> [SidebarRuntimeTargetItem]
    {
        let targets = workspaceShortcutTargets(detail: detail, browserSessions: browserSessions)
        return targets.enumerated().compactMap { offset, target in
            sidebarRuntimeTargetItem(
                target: target, shortcutIndex: offset + 1 <= 10 ? offset + 1 : nil, detail: detail, browserSessions: browserSessions)
        }
    }

    nonisolated private static func sidebarRuntimeTargetItem(
        target: WorkspaceRunShortcutTarget, shortcutIndex: Int?, detail: SpacesDeviceWorkspaceDetailViewModel, browserSessions: [BrowserSession]
    ) -> SidebarRuntimeTargetItem? {
        let key = cycleCursorKey(for: target, detail: detail)
        let title = focusableWindowName(for: target, detail: detail, browserSessions: browserSessions)
        switch target.kind {
        case .browser:
            guard let targetURL = target.targetURL, !targetURL.isEmpty else { return nil }
            return SidebarRuntimeTargetItem(
                key: key, title: title ?? targetURL, detail: nil, kind: .browser, runState: nil, shortcutIndex: shortcutIndex, sessionID: nil,
                canRun: false, canStop: false, canRestart: false, processID: nil, processKey: nil, processTemplateID: nil, agentID: nil,
                browserTargetURL: targetURL)
        case .process:
            guard let processID = target.processID, let row = detail.processRows.first(where: { ($0.processID ?? $0.id) == processID }) else {
                return nil
            }
            return SidebarRuntimeTargetItem(
                key: key, title: title ?? row.name, detail: nil, kind: .process, runState: row.runState, shortcutIndex: shortcutIndex,
                sessionID: row.sessionID, canRun: row.canRun, canStop: row.canStop, canRestart: row.canRestart, processID: processID,
                processKey: row.name, processTemplateID: row.templateID, agentID: nil, browserTargetURL: nil)
        case .window:
            guard let index = target.windowListIndex, detail.terminalRows.indices.contains(index) else { return nil }
            let row = detail.terminalRows[index]
            return SidebarRuntimeTargetItem(
                key: key, title: title ?? row.title, detail: row.liveTitle, kind: .window, runState: row.runState, shortcutIndex: shortcutIndex,
                sessionID: row.sessionID, canRun: false, canStop: row.canStop, canRestart: false, processID: nil, processKey: nil,
                processTemplateID: nil, agentID: nil, browserTargetURL: nil)
        case .agent:
            guard let agentWindow = target.agentWindow, let row = detail.codingAgentRows.first(where: { ($0.agentID ?? $0.id) == agentWindow.id })
            else { return nil }
            return SidebarRuntimeTargetItem(
                key: key, title: title ?? row.name, detail: row.liveTitle, kind: .agent, runState: row.runState, shortcutIndex: shortcutIndex,
                sessionID: row.sessionID, canRun: false, canStop: row.canStop, canRestart: false, processID: nil, processKey: nil,
                processTemplateID: nil, agentID: agentWindow.id, browserTargetURL: nil, agentActivityState: row.activityState)
        case .missingConfiguredProcess:
            guard let processKey = target.processKey else { return nil }
            let templateID = detail.config.processes.first { normalizedRunRowName($0.name ?? "") == normalizedRunRowName(processKey) }?.id
            return SidebarRuntimeTargetItem(
                key: key, title: title ?? processKey, detail: nil, kind: .missingConfiguredProcess, runState: .notStarted,
                shortcutIndex: shortcutIndex, sessionID: nil, canRun: true, canStop: false, canRestart: false, processID: nil, processKey: processKey,
                processTemplateID: templateID, agentID: nil, browserTargetURL: nil)
        }
    }
}

extension AppKitController {
    /// The sidebar's runtime-target rows for a workspace, from the owning device's overview.
    func sidebarRuntimeTargetItems(workspaceID: String) -> [SidebarRuntimeTargetItem] {
        guard let context = focusableWindowContext(workspaceID: workspaceID) else { return [] }
        return Self.sidebarRuntimeTargetItems(detail: context.detail, browserSessions: context.browserSessions)
    }

    /// The runtime targets' names (what the sidebar rows show) for a workspace's terminal sessions, so
    /// pane and tab titles read as the target list does instead of following the terminal's own live
    /// title. Returned as a map because a caller titling a panel needs a name per open session, and one
    /// target-list build answers all of them. When two targets claim the same session, the first in
    /// target order wins — the order the sidebar rows and numbered shortcuts use.
    func runtimeTargetTitlesBySessionID(workspaceID: String) -> [String: String] {
        var titles: [String: String] = [:]
        for item in sidebarRuntimeTargetItems(workspaceID: workspaceID) {
            guard let sessionID = item.sessionID, titles[sessionID] == nil else { continue }
            titles[sessionID] = item.title
        }
        return titles
    }

    /// Opens or focuses a sidebar runtime target through the same resolution pipeline the
    /// numbered shortcuts, command palette, and cycle focus use, so a sidebar click
    /// behaves identically to those paths.
    func focusSidebarRuntimeTarget(workspaceID: String, key: String) {
        Task { @MainActor [weak self] in
            guard let self, let context = self.focusableWindowContext(workspaceID: workspaceID),
                let target = context.targets.first(where: { Self.cycleCursorKey(for: $0, detail: context.detail) == key })
            else { return }
            let resolution = Self.windowShortcutTargetResolution(target, workspaceID: workspaceID, detail: context.detail, overview: context.overview)
            guard let action = await self.executeWindowFocusResolution(resolution, preferredTarget: target, preferredDetail: context.detail) else {
                return
            }
            self.hideAfterSuccessfulExternalWindowAction(action)
        }
    }

    func startSidebarRuntimeTarget(workspaceID: String, item: SidebarRuntimeTargetItem) {
        switch item.kind {
        case .process, .missingConfiguredProcess:
            guard let processKey = item.processKey else { return }
            runSidebarDeviceMutation(workspaceID: workspaceID) { device, clientApp in
                try SpacesDeviceClient.runWorkspaceProcess(
                    workspaceID: workspaceID, processKey: processKey, processTemplateID: item.processTemplateID, device: device, clientApp: clientApp)
            }
        case .agent, .browser, .window: return
        }
    }

    func stopSidebarRuntimeTarget(workspaceID: String, item: SidebarRuntimeTargetItem) {
        switch item.kind {
        case .process:
            runSidebarDeviceMutation(workspaceID: workspaceID) { device, clientApp in
                try SpacesDeviceClient.stopWorkspaceProcess(
                    workspaceID: workspaceID, processID: item.processID, processKey: item.processKey, processTemplateID: item.processTemplateID,
                    device: device, clientApp: clientApp)
            }
        case .agent:
            guard let sessionID = item.sessionID else { return }
            runSidebarDeviceMutation(workspaceID: workspaceID) { device, clientApp in
                try SpacesDeviceClient.stopWorkspaceTerminal(workspaceID: workspaceID, sessionID: sessionID, device: device, clientApp: clientApp)
            }
        case .window:
            guard let sessionID = item.sessionID else { return }
            runSidebarDeviceMutation(workspaceID: workspaceID) { device, clientApp in
                try SpacesDeviceClient.stopWorkspaceTerminal(workspaceID: workspaceID, sessionID: sessionID, device: device, clientApp: clientApp)
            }
        case .browser, .missingConfiguredProcess: return
        }
    }

    func restartSidebarRuntimeTarget(workspaceID: String, item: SidebarRuntimeTargetItem) {
        switch item.kind {
        case .process:
            runSidebarDeviceMutation(workspaceID: workspaceID) { device, clientApp in
                try SpacesDeviceClient.restartWorkspaceProcess(
                    workspaceID: workspaceID, processID: item.processID, processKey: item.processKey, processTemplateID: item.processTemplateID,
                    device: device, clientApp: clientApp)
            }
        case .agent, .browser, .window, .missingConfiguredProcess: return
        }
    }

    private func runSidebarDeviceMutation(
        workspaceID: String, _ mutation: @escaping @Sendable (SpacesPairedDeviceRecord, SpacesDeviceClientApp) throws -> SpacesDeviceAPIResponse
    ) {
        guard let device = deviceForWorkspaceMutation(workspaceID: workspaceID) else {
            showWorkspaceDeviceUnavailableError(workspaceID: workspaceID)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Self.deviceMutation(device: device) { device in
                try mutation(device, SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
            }
            switch result {
            case .success(let response): self.applyDeviceMutationResponse(response, deviceID: device.id, selectedWorkspaceID: workspaceID)
            case .failure(let error): self.showError(error)
            }
        }
    }

    /// Renames a sidebar runtime target. Rows whose name lives on a session — an ad hoc terminal and a
    /// coding agent — rename through their dedicated Device API command; configured processes and browser
    /// sessions rename their workspace-config entry (so a running process picks the new name up on
    /// restart, matching how config edits behave elsewhere).
    ///
    /// Submitting an empty name clears a session-stored rename, handing the row back to the name
    /// underneath it (an ad hoc terminal's launch title, an agent's reported label). A config entry must
    /// keep a name, so an empty submission on those kinds is discarded.
    func commitSidebarRuntimeTargetRename(workspaceID: String, item: SidebarRuntimeTargetItem, newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        switch Self.sidebarRuntimeTargetRenameDestination(item: item, newTitle: newTitle) {
        case .discard: return
        case .terminalSession(let sessionID):
            runSidebarDeviceMutation(workspaceID: workspaceID) { device, clientApp in
                try SpacesDeviceClient.renameTerminalSession(
                    workspaceID: workspaceID, sessionID: sessionID, title: title, device: device, clientApp: clientApp)
            }
        case .agentSession(let agentID):
            runSidebarDeviceMutation(workspaceID: workspaceID) { device, clientApp in
                try SpacesDeviceClient.renameAgentSession(
                    workspaceID: workspaceID, agentID: agentID, title: title, device: device, clientApp: clientApp)
            }
        case .configuredProcess:
            do {
                try updateDeviceWorkspaceConfig(workspaceID: workspaceID) { settings in
                    guard
                        let index = settings.processes.firstIndex(where: {
                            if let templateID = item.processTemplateID { return $0.id == templateID }
                            return Self.normalizedRunRowName($0.name ?? "") == Self.normalizedRunRowName(item.processKey ?? "")
                        })
                    else { return }
                    settings.processes[index].name = title
                }
            } catch { showError(error) }
        case .configuredBrowserSession:
            do {
                try updateDeviceWorkspaceConfig(workspaceID: workspaceID) { settings in
                    guard let index = Self.configuredBrowserSessionIndex(named: item.title, in: settings.browserSessions) else { return }
                    settings.browserSessions[index].name = title
                }
            } catch { showError(error) }
        }
    }

    /// Where a sidebar row's rename is stored, resolved as one value before any mutation runs so the
    /// routing rule and the empty-name rule that goes with it are one readable statement.
    nonisolated static func sidebarRuntimeTargetRenameDestination(item: SidebarRuntimeTargetItem, newTitle: String)
        -> SidebarRuntimeTargetRenameDestination
    {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title != item.title else { return .discard }
        // Agents and ad hoc terminals are live sessions nothing in the workspace config names, so their
        // rename is stored on the session and an empty name clears it back to the name underneath.
        let storesRenameOnSession = item.kind == .window || item.kind == .agent
        guard !title.isEmpty || storesRenameOnSession else { return .discard }
        switch item.kind {
        case .window:
            guard let sessionID = item.sessionID else { return .discard }
            return .terminalSession(sessionID: sessionID)
        case .agent:
            guard let agentID = item.agentID else { return .discard }
            return .agentSession(agentID: agentID)
        case .process, .missingConfiguredProcess: return .configuredProcess
        case .browser: return .configuredBrowserSession
        }
    }

    /// The configured browser session a sidebar row targets. The row's `browserTargetURL` is the
    /// env/service-resolved URL, while the config stores the raw (unsubstituted) URL, so matching on
    /// the URL would silently miss any session that uses substitution. Resolution preserves the
    /// configured name, so match on it — the way the process and agent rows fall back to name matching.
    nonisolated static func configuredBrowserSessionIndex(named name: String, in sessions: [BrowserSession]) -> Int? {
        sessions.firstIndex { normalizedRunRowName($0.name ?? "") == normalizedRunRowName(name) }
    }
}
