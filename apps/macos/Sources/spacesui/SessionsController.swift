import AppKit
import Foundation
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import workspacecore

/// Owns the Sessions pane: a search over the coding-agent conversations in the agents' own stores on one
/// device, as one list with agent and project filters, with resume.
///
/// Nothing is cached on the client. Leaving the pane drops the results and the polling; coming back asks
/// the device again. The query, the device, and each device's agent and project filters survive, all but
/// the query on disk.
/// The device answers every request itself, so an offline device shows no results rather than a stale list.
///
/// While the device is building its index or scanning the stores, the results are still moving, so the pane
/// repeats its current query every `pollSeconds` for as long as it is on screen.
@MainActor final class SessionsController: NSObject {
    unowned let host: AppKitController

    init(host: AppKitController) {
        self.host = host
        super.init()
    }

    private static let debounceSeconds = 0.15
    private static let pollSeconds = 2.0

    private var model: SessionsPaneModel?
    private var pane: SessionsPaneView?
    private var debounceTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    // MARK: - Presentation

    /// Presents the pane, or when it is already showing, brings it up to date with the host's devices.
    /// Navigation cleanup runs only on entry: the host re-invokes this on every device update.
    func showSessionsDetail() {
        if !host.showingSessions {
            host.projectForms.clearActiveAddFormStateAndCloseWindows()
            host.stopWorkspaceSetupDetailRefreshTimer()
            host.presentDetailPane(.sessions)
            host.showingSettings = false
            let previousProjectID = host.selectedProjectID
            let previousWorkspaceID = host.selectedWorkspaceID
            host.selectedProjectID = nil
            host.selectedWorkspaceID = nil
            host.outlineView.deselectAll(nil)
            host.refreshSidebarSelectionRows(
                previousProjectID: previousProjectID, currentProjectID: nil, previousWorkspaceID: previousWorkspaceID, currentWorkspaceID: nil)
            host.updateAlertsRowAppearance()
        }
        if pane == nil {
            installPane()
            startPolling()
        }
        reconcile()
        render()
    }

    /// Another pane replaced this one: the views, the results, and the polling go.
    func paneDidHide() {
        debounceTask?.cancel()
        debounceTask = nil
        pollTask?.cancel()
        pollTask = nil
        pane = nil
        model?.clearResults()
    }

    private func installPane() {
        let pairedDeviceIDs = host.deviceModel.deviceSections.map(\.deviceID)
        var model =
            self.model
            ?? SessionsPaneModel(
                deviceID: SessionsPaneModel.initialDeviceID(
                    lastSearched: storedSetting(ClientSettingsKey.sessionsLastDeviceID), pairedDeviceIDs: pairedDeviceIDs,
                    localDeviceID: host.deviceModel.localDeviceID),
                agentsByDevice: SessionsPaneModel.decodeAgentSelections(storedSetting(ClientSettingsKey.sessionsAgentsByDevice)),
                projectByDevice: SessionsPaneModel.decodeProjectSelections(storedSetting(ClientSettingsKey.sessionsProjectByDevice)))
        // The device may have been unpaired since the pane was last open.
        if !pairedDeviceIDs.contains(model.deviceID) { model.selectDevice(host.deviceModel.localDeviceID) }
        self.model = model

        host.clearWorkspaceDetailFooter()
        for view in host.detailContainer.subviews { view.removeFromSuperview() }
        host.detailContainer.wantsLayer = true
        bindAppearanceReactiveLayer(host.detailContainer) { [unowned host] view in
            view.layer?.backgroundColor = host.sidebar.sidebarPanelBackgroundColor().cgColor
        }
        let pane = SessionsPaneView(query: model.query)
        pane.onQueryChange = { [weak self] query in self?.queryChanged(query) }
        pane.onDeviceChosen = { [weak self] id in self?.deviceChosen(id) }
        pane.onAgentToggled = { [weak self] agent in self?.changeAgents { $0.toggleAgent(agent) } }
        pane.onAllAgents = { [weak self] in self?.changeAgents { $0.clearAgents() } }
        pane.onProjectChosen = { [weak self] id in self?.changeProject(id) }
        pane.onRowActivate = { [weak self] key in self?.resume(key: key) }
        pane.onMoveSelection = { [weak self] delta in
            self?.model?.moveSelection(by: delta)
            self?.render(scrollSelectionIntoView: true)
        }
        pane.onShowMore = { [weak self] in self?.showMore() }
        showScrollableDetailStack(pane.stack, in: host.detailContainer)
        self.pane = pane
        // The view is in the window only after the current layout pass.
        Task { @MainActor [weak pane] in pane?.focusSearch() }
    }

    // MARK: - Devices

    private struct DeviceStatus {
        let record: SpacesPairedDeviceRecord?
        let name: String
    }

    /// Same test as the saved prompts library: a loaded section proves the credentials work, and the
    /// daemon must speak a compatible wire version.
    private func status(ofDevice deviceID: String) -> DeviceStatus {
        guard let section = host.deviceModel.deviceSections.first(where: { $0.deviceID == deviceID }) else {
            return DeviceStatus(record: nil, name: "This device")
        }
        let name = section.isLocal ? ResourcesController.localDeviceTitle : section.deviceName
        guard section.loadState == .loaded, host.deviceCompatibility(forDeviceID: deviceID)?.isCompatible != false else {
            return DeviceStatus(record: nil, name: name)
        }
        return DeviceStatus(record: host.automationDeviceRecord(deviceID: deviceID), name: name)
    }

    private func requestContext(for record: SpacesPairedDeviceRecord) -> DeviceRequestContext {
        DeviceRequestContext(device: record, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
    }

    private func deviceChosen(_ id: String) {
        guard var model else { return }
        model.selectDevice(id)
        self.model = model
        storeSetting(ClientSettingsKey.sessionsLastDeviceID, id)
        reconcile()
        render()
    }

    // MARK: - Searching

    /// Asks the device when the pane has not heard from it yet, and forgets the results of a device that
    /// went offline so the next time it is reachable they are fetched fresh.
    private func reconcile() {
        guard let model else { return }
        if status(ofDevice: model.deviceID).record == nil { self.model?.clearResults() } else if model.needsSearch { search() }
    }

    private func queryChanged(_ query: String) {
        model?.query = query
        render()
        debounceTask?.cancel()
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.debounceSeconds))
            guard !Task.isCancelled else { return }
            self?.search()
        }
    }

    private func changeAgents(_ change: (inout SessionsPaneModel) -> Void) {
        guard var model else { return }
        change(&model)
        self.model = model
        storeSetting(ClientSettingsKey.sessionsAgentsByDevice, SessionsPaneModel.encodeAgentSelections(model.agentsByDevice))
        search()
    }

    private func changeProject(_ id: String?) {
        guard var model else { return }
        model.selectProject(id)
        self.model = model
        storeSetting(ClientSettingsKey.sessionsProjectByDevice, SessionsPaneModel.encodeProjectSelections(model.projectByDevice))
        search()
    }

    private func search() {
        guard var model, let record = status(ofDevice: model.deviceID).record else { return }
        let request = model.beginSearch()
        self.model = model
        run(request, record: record)
        render()
    }

    private func showMore() {
        guard var model, let record = status(ofDevice: model.deviceID).record, let request = model.beginShowMore() else { return }
        self.model = model
        run(request, record: record)
        render()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.pollSeconds))
                guard !Task.isCancelled, let self else { return }
                self.pollIfNeeded()
            }
        }
    }

    private func pollIfNeeded() {
        guard var model, model.shouldPoll, model.inFlight == nil, host.mainWindowIsOnScreen, let record = status(ofDevice: model.deviceID).record
        else { return }
        let request = model.beginRefresh()
        self.model = model
        run(request, record: record)
    }

    private func run(_ request: SessionsPaneModel.Request, record: SpacesPairedDeviceRecord) {
        let context = requestContext(for: record)
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try Self.fetch(request, context: context) } }.value
            guard let self, var model else { return }
            let applied: Bool
            switch result {
            case .success(let response): applied = model.apply(response, to: request)
            case .failure(let error): applied = model.fail(error.localizedDescription, for: request)
            }
            guard applied else { return }
            self.model = model
            // Applying a response may have dropped a remembered project the device no longer has.
            if model.needsSearch, model.selectedProjectID == nil, request.projectID != nil {
                storeSetting(ClientSettingsKey.sessionsProjectByDevice, SessionsPaneModel.encodeProjectSelections(model.projectByDevice))
                search()
            }
            render()
        }
    }

    /// The pages a request covers, one request each: a refresh re-reads every page already shown so the
    /// list does not shrink back to its first page while the index grows.
    nonisolated private static func fetch(_ request: SessionsPaneModel.Request, context: DeviceRequestContext) throws -> SessionsPaneModel.Response {
        var result = try SpacesDeviceClient.searchAgentSessions(
            query: request.query, page: request.firstPage, agents: request.agents, projectID: request.projectID, context: context)
        var hits = result.results
        var pagesFetched = 1
        while pagesFetched < request.pageCount, result.hasMore {
            result = try SpacesDeviceClient.searchAgentSessions(
                query: request.query, page: request.firstPage + pagesFetched, agents: request.agents, projectID: request.projectID, context: context)
            hits += result.results
            pagesFetched += 1
        }
        return SessionsPaneModel.Response(
            hits: hits, hasMore: result.hasMore, availableAgents: result.availableAgents, availableProjects: result.availableProjects,
            progress: result.progress, pagesFetched: pagesFetched)
    }

    // MARK: - Resuming

    private func resume(key: String) {
        guard var model, let hit = model.hit(forKey: key), hit.resumability == .resumable, model.beginResume(key: key) else { return }
        model.select(key)
        self.model = model
        render()
        guard let record = host.deviceForMutation(deviceID: model.deviceID) else {
            finishResume(key: key, message: "\(status(ofDevice: model.deviceID).name) is offline")
            return
        }
        let (agent, sessionKey, workingDirectory) = (hit.agent, hit.sessionKey, hit.workingDirectory)
        let workspaceID = hit.workspace.workspaceID
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await host.attemptTerminalSessionMutation(
                device: record, workspaceID: workspaceID,
                operation: { device in
                    try SpacesDeviceClient.resumeAgentSession(
                        agent: agent, sessionKey: sessionKey, workingDirectory: workingDirectory,
                        context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
                })
            switch outcome {
            case .success(let request?):
                finishResume(key: key, message: nil)
                await host.windowFocus.openOrFocusTerminalTarget(request)
            case .success(nil): finishResume(key: key, message: "The session started but has no terminal to open.")
            case .failure(let error): finishResume(key: key, message: error.localizedDescription)
            }
        }
    }

    private func finishResume(key: String, message: String?) {
        model?.finishResume(key: key, errorMessage: message)
        render()
    }

    // MARK: - Rendering

    private func render(scrollSelectionIntoView: Bool = false) {
        guard let pane, let model else { return }
        let device = status(ofDevice: model.deviceID)
        let isOffline = device.record == nil
        let hasQuery = !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var message: String?
        if isOffline {
            message = "\(device.name) is offline"
        } else if model.hits.isEmpty {
            if model.progress == nil {
                message = model.errorMessage == nil ? "Searching" : nil
            } else if model.progress?.isBuilding != true {
                message = hasQuery ? "No sessions match" : "No sessions on \(device.name)"
            }
        }
        let state = SessionsPaneState(
            deviceChoices: host.deviceModel.deviceSections.map {
                .init(id: $0.deviceID, name: $0.isLocal ? ResourcesController.localDeviceTitle : $0.deviceName)
            }, selectedDeviceID: model.deviceID, agentChoices: isOffline ? [] : model.availableAgents, selectedAgents: model.selectedAgents,
            agentsTitle: model.agentsTitle, projectChoices: isOffline ? [] : model.availableProjects, selectedProjectID: model.selectedProjectID,
            countText: isOffline ? nil : model.countText, progressText: isOffline ? nil : model.progressText,
            errorText: isOffline ? nil : model.errorMessage, message: message, rows: isOffline ? [] : model.rows(now: Date()), query: model.query,
            selectedKey: model.selectedKey, resumingKey: model.resumingKey, resumeError: model.resumeError,
            canShowMore: !isOffline && model.canShowMore, isLoadingMore: model.isLoadingMore)
        pane.render(state, scrollSelectionIntoView: scrollSelectionIntoView)
    }

    // MARK: - Persistence

    private func storedSetting(_ key: String) -> String? { (try? host.clientDatabase().setting(key: key)) ?? nil }

    /// A failed write only means the choice is not remembered, which is not worth interrupting the search for.
    private func storeSetting(_ key: String, _ value: String?) { try? host.clientDatabase().setSetting(key: key, value: value) }
}
