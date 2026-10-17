import AppKit
import Foundation
import spacesclientcore
import spacesdevicecore
import workspacecore

/// Owns the Resources detail pane: what it measures, when, and how it reaches the screen.
///
/// Measurement runs only while the pane is on screen: selected, and the main window neither closed,
/// minimized, nor hidden with the app. Entering the pane opens one resource stream per
/// reachable, wire-compatible device (the local daemon included, since every device is reached through
/// the Device API) and starts the local sampler for the Spaces app. Leaving it stops all of them and
/// drops every history, so a closed pane costs nothing and a reopened one starts fresh. `AppKitController`
/// reaches this through `presentDetailPane`, the single choke point for pane changes.
///
/// The host re-invokes `showResourcesDetail()` whenever device state changes while the pane is
/// visible. Re-invoking updates names, devices, and subscriptions and repaints in place; only the first
/// call builds the views.
@MainActor final class ResourcesController: NSObject {
    unowned let host: AppKitController

    init(host: AppKitController) {
        self.host = host
        super.init()
    }

    /// The local Mac's name in the pane, in place of the sidebar's "Local".
    static let localDeviceTitle = "This Mac"

    private var model = ResourcesViewModel()
    private var mode: ResourcesMode = .terminals
    private var sortColumn: ResourcesSortColumn = .cpu
    private var pane: ResourcesPaneView?
    private var subscriptions: RemoteOverviewSubscriptionCoordinator<SpacesDeviceResourcesStreamClient>?
    private var appSamplingTask: Task<Void, Never>?
    /// Identifies one visit to the pane. A stream's connect result or callback from an earlier visit
    /// can land after a new visit has begun, when the new coordinator has reused the attempt numbers.
    private var visit = 0

    // MARK: - Presentation

    /// Presents the pane, or when it is already showing, brings it up to date with the host's devices.
    ///
    /// Navigation cleanup runs only on entry. The host re-invokes this on every device update, and a
    /// background refresh must never close an open New Project / New Workspace / project settings form
    /// or discard what the user typed into it.
    func showResourcesDetail() {
        let isEntering = !host.showingResources
        if isEntering {
            host.projectForms.clearActiveAddFormStateAndCloseWindows()
            host.stopWorkspaceSetupDetailRefreshTimer()
            host.presentDetailPane(.resources)
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
        // Measurement is keyed on its own state, not on the pane: the pane stays selected while the main
        // window is closed, hidden, or minimized, and measurement must start again when it returns.
        if subscriptions == nil {
            guard host.mainWindowIsOnScreen else { return }
            start()
        }
        reconcileSubscriptions()
    }

    /// Ends measurement while the main window is off screen (closed, minimized, or the app hidden) and
    /// starts it fresh when the window returns with this pane still selected.
    func mainWindowOnScreenChanged() { if host.mainWindowIsOnScreen { if host.showingResources { showResourcesDetail() } } else { stop() } }

    /// Stops all measurement and forgets everything measured. Called when any other pane replaces this
    /// one and when the main window leaves the screen.
    func stop() {
        guard subscriptions != nil || appSamplingTask != nil else { return }
        appSamplingTask?.cancel()
        appSamplingTask = nil
        for client in subscriptions?.disable() ?? [] { client.stop() }
        subscriptions = nil
        model.reset()
        pane = nil
    }

    private func start() {
        visit += 1
        installPane()
        let coordinator = RemoteOverviewSubscriptionCoordinator<SpacesDeviceResourcesStreamClient>(requestReconcile: { [weak self] in
            self?.reconcileSubscriptions()
        })
        coordinator.enable()
        subscriptions = coordinator
        startAppSampling()
    }

    private func installPane() {
        host.clearWorkspaceDetailFooter()
        for view in host.detailContainer.subviews { view.removeFromSuperview() }
        host.detailContainer.wantsLayer = true
        bindAppearanceReactiveLayer(host.detailContainer) { [unowned host] view in
            view.layer?.backgroundColor = host.sidebar.sidebarPanelBackgroundColor().cgColor
        }
        let pane = ResourcesPaneView(mode: mode, sort: sortColumn)
        pane.onModeChange = { [weak self] mode in
            self?.mode = mode
            self?.render()
        }
        pane.onSortChange = { [weak self] column in
            self?.sortColumn = column
            self?.render()
        }
        pane.onJump = { [weak self] row in self?.jump(to: row) }
        showScrollableDetailStack(pane.stack, in: host.detailContainer)
        self.pane = pane
    }

    private func render() {
        guard let pane else { return }
        let terminals = model.terminalsCardLines()
        pane.update(
            mode: mode, sort: sortColumn, terminals: terminals, spaces: model.spacesCardLines(localDeviceName: Self.localDeviceTitle),
            rows: model.rows(mode: mode, sort: sortColumn), hasMeasurement: model.hasMeasurement, showsDevice: terminals.count > 1)
    }

    /// Opens the row's terminal, or in Workspaces mode selects the workspace in the sidebar.
    private func jump(to row: ResourcesRow) {
        if let sessionID = row.sessionID {
            host.handleTerminalDeepLink(SpacesTerminalDeepLink(sessionID: sessionID, deviceID: row.deviceID))
        } else if row.canJump, let (_, workspace) = host.findWorkspace(id: row.workspaceID) {
            host.sidebar.selectWorkspace(workspace)
        }
    }

    // MARK: - Local app sampling

    /// Samples the Spaces app every interval on a background task, which owns the sampler outright so no
    /// state is shared. The first sample only records a baseline, so the first figure lands one interval
    /// after the pane opens, the same as a daemon's first frame.
    private func startAppSampling() {
        appSamplingTask = Task.detached(priority: .utility) { [weak self] in
            var sampler = ResourcesAppSampler()
            while !Task.isCancelled, self != nil {
                if let usage = sampler.sample(uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds), let controller = self {
                    await MainActor.run { controller.receiveApp(usage) }
                }
                try? await Task.sleep(for: .seconds(SpacesDeviceResourcesFrame.samplingInterval))
            }
        }
    }

    private func receiveApp(_ usage: SpacesDeviceResourceUsage) {
        guard subscriptions != nil else { return }
        model.ingestApp(usage)
        render()
    }

    // MARK: - Device streams

    private struct Candidate {
        let deviceID: String
        let name: String
        let record: SpacesPairedDeviceRecord
        let overview: SpacesDeviceOverviewPayload?
    }

    /// Devices to measure: every one the host can reach with a usable credential, minus those whose
    /// daemon speaks an incompatible wire version (their stream could not decode a frame).
    private func candidates() -> [Candidate] {
        host.deviceModel.deviceSections.compactMap { section in
            guard host.deviceCompatibility(forDeviceID: section.deviceID)?.isCompatible != false,
                let record = host.automationDeviceRecord(deviceID: section.deviceID),
                section.isLocal || AppKitController.pairedDeviceHasRequiredCredentials(device: record)
            else { return nil }
            return Candidate(
                deviceID: section.deviceID, name: section.isLocal ? Self.localDeviceTitle : section.deviceName, record: record,
                overview: section.overview)
        }
    }

    /// Brings the open streams and the model's names in line with the host's current devices, then
    /// repaints. Safe to call on every device update: a device that already has a stream, or is waiting
    /// out its retry delay, is left alone.
    private func reconcileSubscriptions() {
        guard let subscriptions else { return }
        let candidates = candidates()
        model.setDevices(candidates.map { ($0.deviceID, $0.name) })
        for candidate in candidates {
            guard let overview = candidate.overview else { continue }
            model.setLabels(ResourcesSessionLabel.labels(from: overview), deviceID: candidate.deviceID)
        }
        let outcome = subscriptions.reconcile(desiredIDs: Set(candidates.map(\.deviceID)))
        for removal in outcome.removed { removal.client.stop() }
        let clientApp = SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)
        for candidate in candidates {
            guard let attempt = outcome.devicesToOpen[candidate.deviceID] else { continue }
            openSubscription(record: candidate.record, attempt: attempt, clientApp: clientApp)
        }
        render()
    }

    /// Opens one stream attempt. Both callbacks hop to the main queue, which is strictly FIFO, so a
    /// disconnect can never overtake the frame before it. `attempt` and `visit` ride in every callback so
    /// a stopped stream, or one from an earlier visit, is never mistaken for the current one.
    private func openSubscription(record: SpacesPairedDeviceRecord, attempt: Int, clientApp: SpacesDeviceClientApp) {
        let deviceID = record.id
        let visit = visit
        let onFrame: @Sendable (SpacesDeviceResourcesFrame) -> Void = { [weak self] frame in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(frame, deviceID: deviceID, attempt: attempt, visit: visit) } }
        }
        let onDisconnect: @Sendable ((any Error)?) -> Void = { [weak self] error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleDisconnect(deviceID: deviceID, attempt: attempt, visit: visit, error: error) }
            }
        }
        Task { @MainActor [weak self] in
            // Resolving credentials and connecting block, so they run off the main actor.
            let client = await Task.detached(priority: .userInitiated) { () -> SpacesDeviceResourcesStreamClient? in
                try? SpacesDeviceClient.subscribeDeviceResources(
                    context: DeviceRequestContext(device: record, clientApp: clientApp), onFrame: onFrame, onDisconnect: onDisconnect)
            }.value
            guard let self, visit == self.visit, let subscriptions = self.subscriptions else {
                client?.stop()
                return
            }
            switch subscriptions.applyConnectResult(deviceID: deviceID, attempt: attempt, client: client) {
            case .keep: break
            case .discard: client?.stop()
            case .connectFailed, .discardDisconnected:
                client?.stop()
                self.markOffline(deviceID: deviceID)
            }
        }
    }

    private func receive(_ frame: SpacesDeviceResourcesFrame, deviceID: String, attempt: Int, visit: Int) {
        guard visit == self.visit, let subscriptions, subscriptions.isCurrentAttempt(deviceID: deviceID, attempt: attempt) else { return }
        // A delivered frame is what proves the subscription works, so only now does the retry backoff reset.
        subscriptions.noteOverviewDelivered(deviceID: deviceID, attempt: attempt)
        model.ingest(frame, deviceID: deviceID)
        render()
    }

    private func handleDisconnect(deviceID: String, attempt: Int, visit: Int, error: (any Error)?) {
        guard visit == self.visit, let subscriptions else { return }
        guard case .markOffline(let client) = subscriptions.applyDisconnect(deviceID: deviceID, attempt: attempt, error: error) else { return }
        client.stop()
        markOffline(deviceID: deviceID)
    }

    private func markOffline(deviceID: String) {
        model.setStatus(.offline, deviceID: deviceID)
        render()
    }
}
