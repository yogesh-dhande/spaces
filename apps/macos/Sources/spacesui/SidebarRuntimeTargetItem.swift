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
    let launcherName: String?
    let launcherID: String?
    let browserTargetURL: String?
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
                key: key, title: title ?? targetURL, kind: .browser, runState: nil, shortcutIndex: shortcutIndex, sessionID: nil, canRun: false,
                canStop: false, canRestart: false, processID: nil, processKey: nil, processTemplateID: nil, agentID: nil, launcherName: nil,
                launcherID: nil, browserTargetURL: targetURL)
        case .process:
            guard let processID = target.processID, let row = detail.processRows.first(where: { ($0.processID ?? $0.id) == processID }) else {
                return nil
            }
            return SidebarRuntimeTargetItem(
                key: key, title: title ?? row.name, kind: .process, runState: row.runState, shortcutIndex: shortcutIndex, sessionID: row.sessionID,
                canRun: row.canRun, canStop: row.canStop, canRestart: row.canRestart, processID: processID, processKey: row.name,
                processTemplateID: row.templateID, agentID: nil, launcherName: nil, launcherID: nil, browserTargetURL: nil)
        case .window:
            guard let index = target.windowListIndex, detail.terminalRows.indices.contains(index) else { return nil }
            let row = detail.terminalRows[index]
            return SidebarRuntimeTargetItem(
                key: key, title: title ?? row.title, kind: .window, runState: row.runState, shortcutIndex: shortcutIndex, sessionID: row.sessionID,
                canRun: false, canStop: row.canStop, canRestart: false, processID: nil, processKey: nil, processTemplateID: nil, agentID: nil,
                launcherName: nil, launcherID: nil, browserTargetURL: nil)
        case .agent:
            guard let agentWindow = target.agentWindow, let row = detail.codingAgentRows.first(where: { ($0.agentID ?? $0.id) == agentWindow.id })
            else { return nil }
            return SidebarRuntimeTargetItem(
                key: key, title: title ?? row.name, kind: .agent, runState: row.runState, shortcutIndex: shortcutIndex, sessionID: row.sessionID,
                canRun: row.canRun, canStop: row.canStop, canRestart: row.canRestart, processID: nil, processKey: nil, processTemplateID: nil,
                agentID: agentWindow.id, launcherName: row.name, launcherID: row.launcherID, browserTargetURL: nil)
        case .missingConfiguredProcess:
            guard let processKey = target.processKey else { return nil }
            let templateID = detail.config.processes.first { normalizedRunRowName($0.name ?? "") == normalizedRunRowName(processKey) }?.id
            return SidebarRuntimeTargetItem(
                key: key, title: title ?? processKey, kind: .missingConfiguredProcess, runState: .notStarted, shortcutIndex: shortcutIndex,
                sessionID: nil, canRun: true, canStop: false, canRestart: false, processID: nil, processKey: processKey,
                processTemplateID: templateID, agentID: nil, launcherName: nil, launcherID: nil, browserTargetURL: nil)
        case .agentLauncher:
            guard let launcherName = target.launcherName else { return nil }
            let launcherID = detail.config.agentLaunchers.first { normalizedRunRowName($0.name) == normalizedRunRowName(launcherName) }?.id
            return SidebarRuntimeTargetItem(
                key: key, title: title ?? launcherName, kind: .agentLauncher, runState: .notStarted, shortcutIndex: shortcutIndex, sessionID: nil,
                canRun: true, canStop: false, canRestart: false, processID: nil, processKey: nil, processTemplateID: nil, agentID: nil,
                launcherName: launcherName, launcherID: launcherID, browserTargetURL: nil)
        }
    }
}

extension AppKitController {
    /// The sidebar's runtime-target rows for a workspace, from the owning device's overview.
    func sidebarRuntimeTargetItems(workspaceID: String) -> [SidebarRuntimeTargetItem] {
        guard let context = focusableWindowContext(workspaceID: workspaceID) else { return [] }
        return Self.sidebarRuntimeTargetItems(detail: context.detail, browserSessions: context.browserSessions)
    }

    /// The runtime targets' display names (what the sidebar rows show) for a workspace's
    /// terminal sessions, so pane and tab titles match the target list instead of the
    /// terminal's own window title. Returned as a map because a caller titling a panel
    /// needs a name per open session, and one target-list build answers all of them.
    /// When two targets claim the same session, the first in target order wins — the
    /// order the sidebar rows and numbered shortcuts use.
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
        case .agent, .agentLauncher:
            guard let launcherName = item.launcherName else { return }
            runSidebarDeviceMutation(workspaceID: workspaceID) { device, clientApp in
                try SpacesDeviceClient.runCodingAgent(
                    workspaceID: workspaceID, agentName: launcherName, agentLauncherID: item.launcherID, device: device, clientApp: clientApp)
            }
        case .browser, .window: return
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
            runSidebarDeviceMutation(workspaceID: workspaceID) { device, clientApp in
                try SpacesDeviceClient.stopCodingAgent(
                    workspaceID: workspaceID, agentID: item.agentID, agentName: item.launcherName, agentLauncherID: item.launcherID, device: device,
                    clientApp: clientApp)
            }
        case .window:
            guard let sessionID = item.sessionID else { return }
            runSidebarDeviceMutation(workspaceID: workspaceID) { device, clientApp in
                try SpacesDeviceClient.stopWorkspaceTerminal(workspaceID: workspaceID, sessionID: sessionID, device: device, clientApp: clientApp)
            }
        case .browser, .missingConfiguredProcess, .agentLauncher: return
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
        case .agent:
            runSidebarDeviceMutation(workspaceID: workspaceID) { device, clientApp in
                try SpacesDeviceClient.restartCodingAgent(
                    workspaceID: workspaceID, agentID: item.agentID, agentName: item.launcherName, agentLauncherID: item.launcherID, device: device,
                    clientApp: clientApp)
            }
        case .browser, .window, .missingConfiguredProcess, .agentLauncher: return
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

    /// Renames a sidebar runtime target. Ad hoc terminal sessions rename through the
    /// dedicated Device API command; configured processes, agent launchers, and browser
    /// sessions rename their workspace-config entry (so a running process picks the new
    /// name up on restart, matching how config edits behave elsewhere).
    func commitSidebarRuntimeTargetRename(workspaceID: String, item: SidebarRuntimeTargetItem, newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != item.title else { return }
        switch item.kind {
        case .window:
            guard let sessionID = item.sessionID else { return }
            runSidebarDeviceMutation(workspaceID: workspaceID) { device, clientApp in
                try SpacesDeviceClient.renameTerminalSession(
                    workspaceID: workspaceID, sessionID: sessionID, title: title, device: device, clientApp: clientApp)
            }
        case .process, .missingConfiguredProcess:
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
        case .agent, .agentLauncher:
            do {
                try updateDeviceWorkspaceConfig(workspaceID: workspaceID) { settings in
                    guard
                        let index = settings.agentLaunchers.firstIndex(where: {
                            if let launcherID = item.launcherID { return $0.id == launcherID }
                            return Self.normalizedRunRowName($0.name) == Self.normalizedRunRowName(item.launcherName ?? "")
                        })
                    else { return }
                    settings.agentLaunchers[index].name = title
                }
            } catch { showError(error) }
        case .browser:
            do {
                try updateDeviceWorkspaceConfig(workspaceID: workspaceID) { settings in
                    guard let index = Self.configuredBrowserSessionIndex(named: item.title, in: settings.browserSessions) else { return }
                    settings.browserSessions[index].name = title
                }
            } catch { showError(error) }
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
