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

/// Reason carried into the offline load state when a remote overview stream closes without an
/// underlying transport error (a graceful server-side close), so the offline caption still has a
/// non-empty tooltip explaining why the device went offline.
private enum RemoteOverviewDisconnectError: LocalizedError {
    case streamClosed

    var errorDescription: String? {
        switch self {
        case .streamClosed: return "The connection to this device closed."
        }
    }
}

/// Owns the left-hand project/workspace/device outline tree (an `NSOutlineView`) and
/// its state, plus the sidebar's data load/merge pipeline and the Alerts row chrome.
/// `AppKitController` holds a single instance and delegates sidebar interactions to it.
/// The controller reaches back into the host for shared selection/model state and
/// services via `host`.
@MainActor final class SidebarController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    unowned let host: AppKitController

    init(host: AppKitController) {
        self.host = host
        super.init()
    }

    typealias OutlineItem = AppKitController.OutlineItem
    typealias OutlineItemRef = AppKitController.OutlineItemRef
    typealias DeviceSection = AppKitController.DeviceSection
    typealias SidebarDeviceLoadState = AppKitController.SidebarDeviceLoadState
    typealias SidebarDataSnapshot = AppKitController.SidebarDataSnapshot
    typealias AlertsGroup = AppKitController.AlertsGroup
    typealias SidebarArrowSelectionTarget = AppKitController.SidebarArrowSelectionTarget

    private var outlineItemRefCache: [String: OutlineItemRef] = [:]
    /// Memoized filtered+sorted visible workspaces per project. `visibleWorkspaces`
    /// is on the NSOutlineView data-source hot path (queried per row); caching keeps
    /// it from re-filtering and re-sorting on every query, and it is invalidated
    /// whenever the host's `workspacesByProject` changes.
    private var visibleWorkspacesCache: [String: [WorkspaceSummary]] = [:]
    /// Per-remote-device timestamp of the last overview fetch, so polls driven by
    /// local events don't re-request every remote's overview on every cycle.
    private var remoteOverviewFetchInstants: [String: ContinuousClock.Instant] = [:]
    /// Live device-overview subscriptions per paired remote device. The remote
    /// daemon pushes a fresh overview on every database change, so remote sidebar
    /// state stays current without polling (remote state has no local event).
    private var remoteOverviewSubscriptions: [String: SpacesDeviceAPIOverviewStreamClient] = [:]
    /// Devices with a subscription open in flight, so rapid refreshes don't start
    /// duplicate connections.
    private var remoteOverviewSubscribing: Set<String> = []
    private var remoteOverviewSubscriptionsEnabled = false
    private var sidebarReloadTask: Task<Void, Never>?
    private var pendingSidebarReloadRequest = false
    private var pendingSidebarReloadFailureMessage: String?
    private var pendingSidebarReloadForceRemoteRefresh = false
    /// Set when a database-change signal arrives while the user is mid-edit;
    /// flushed at idle points so a deferred change is not lost.
    private var pendingDatabaseReload = false

    // Alerts sidebar row
    private var alertsRowView: NSView?
    private var alertsRowStack: NSStackView?
    private var alertsRowBadge: NSTextField?

    private static let placeholderProject = ProjectSummary(id: "", name: "", dir: "", isGitRepo: false, defaultBranch: nil)

    func invalidateVisibleWorkspacesCache() { visibleWorkspacesCache.removeAll(keepingCapacity: true) }

    /// Wires the host's outline view to this controller as its delegate/data source
    /// and installs the row mouse-down and arrow-navigation callbacks.
    func attachOutlineView(_ outlineView: SidebarOutlineView) {
        outlineView.onRowMouseDown = { [weak self] row in
            guard let self, let ref = self.host.outlineView.item(atRow: row) as? OutlineItemRef else { return false }
            if case .project(let project) = ref.item {
                // Git project rows toggle their workspace list; non-git rows act as a
                // single selectable workspace, so let normal row selection proceed.
                guard project.isGitRepo else { return false }
                self.toggleProjectExpanded(projectID: project.id)
                return true
            }
            return false
        }
        outlineView.onArrowNavigation = { [weak self] direction in self?.navigateSidebarSelection(direction: direction) ?? false }
        outlineView.delegate = self
        outlineView.dataSource = self
    }

    /// Cancels in-flight reload state. Called from the host's background-service
    /// teardown and termination paths.
    func stopSidebarTasks() {
        pendingDatabaseReload = false
        sidebarReloadTask?.cancel()
        sidebarReloadTask = nil
        pendingSidebarReloadRequest = false
        pendingSidebarReloadFailureMessage = nil
        stopRemoteOverviewSubscriptions()
    }

    func cancelSidebarReloadTask() { sidebarReloadTask?.cancel() }

    /// Reloads sidebar metadata after a database write, signaled by whichever
    /// process committed it (`IPCNotification.databaseDidChange`). Catches external
    /// CLI/daemon edits (for example title changes) that no other event-driven
    /// reload would observe. Driven by the writer, so there is no polling and no
    /// file-watch feedback loop from the app's own reads.
    func handleDatabaseDidChange() {
        guard host.canReloadAfterBackgroundWorkspaceRefresh() else {
            pendingDatabaseReload = true
            return
        }
        requestSidebarReload()
    }

    /// Flushes a database-driven reload deferred while the user was mid-edit.
    func flushPendingDatabaseReloadIfNeeded() {
        guard pendingDatabaseReload, host.canReloadAfterBackgroundWorkspaceRefresh() else { return }
        pendingDatabaseReload = false
        requestSidebarReload()
    }

    func canPreserveDetailPaneAfterSidebarReload() -> Bool {
        if host.activeAddWorkspaceFormTag != nil || host.activeAddProjectFormTag != nil { return true }
        if host.projectSettingsProjectID != nil { return true }
        if host.showingAlerts || host.showingSettings { return true }
        if let selectedWorkspaceID = host.selectedWorkspaceID { return findWorkspace(id: selectedWorkspaceID) != nil }
        if let selectedProjectID = host.selectedProjectID { return host.projects.contains(where: { $0.id == selectedProjectID }) }
        if let blockDeviceID = host.visibleCompatibilityBlockDeviceID {
            return host.deviceCompatibility(forDeviceID: blockDeviceID)?.isCompatible == false
        }
        return false
    }

    func loadInitialSidebarData() async {
        host.logStartupProfile("sidebar_snapshot_requested")
        let result = await AppKitController.initialSidebarDataSnapshot()
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let snapshot):
            host.logStartupProfile("sidebar_snapshot_received")
            applySidebarDataSnapshot(snapshot)
            host.logStartupProfile("sidebar_snapshot_applied")
            host.startBackgroundServicesIfNeeded()
        case .failure(let error):
            if host.handleDeferredSetupRequirementIfNeeded(error) { return }
            host.showError(error)
            host.showPlaceholder(message: "Spaces couldn't load workspace data.")
            host.startBackgroundServicesIfNeeded()
        }
    }

    func requestSidebarReload(failurePlaceholderMessage: String? = nil, forceRemoteRefresh: Bool = false) {
        if let sidebarReloadTask, !sidebarReloadTask.isCancelled {
            pendingSidebarReloadRequest = true
            pendingSidebarReloadForceRemoteRefresh = pendingSidebarReloadForceRemoteRefresh || forceRemoteRefresh
            pendingSidebarReloadFailureMessage = pendingSidebarReloadFailureMessage ?? failurePlaceholderMessage
            return
        }
        let currentFailurePlaceholderMessage = failurePlaceholderMessage
        sidebarReloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await AppKitController.initialSidebarDataSnapshot()
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let snapshot): self.applySidebarDataSnapshot(snapshot, preserveDetailPane: true, forceRemoteRefresh: forceRemoteRefresh)
            case .failure(let error):
                if let currentFailurePlaceholderMessage {
                    self.host.showError(error)
                    self.host.showPlaceholder(message: currentFailurePlaceholderMessage)
                } else {
                    self.host.handleBackgroundRefreshFailure(error, source: "sidebar_reload")
                }
            }
            self.sidebarReloadTask = nil
            if self.pendingSidebarReloadRequest {
                let pendingFailurePlaceholderMessage = self.pendingSidebarReloadFailureMessage
                let pendingForceRemoteRefresh = self.pendingSidebarReloadForceRemoteRefresh
                self.pendingSidebarReloadRequest = false
                self.pendingSidebarReloadFailureMessage = nil
                self.pendingSidebarReloadForceRemoteRefresh = false
                self.requestSidebarReload(failurePlaceholderMessage: pendingFailurePlaceholderMessage, forceRemoteRefresh: pendingForceRemoteRefresh)
            }
        }
    }

    func applySidebarDataSnapshot(_ snapshot: SidebarDataSnapshot, preserveDetailPane: Bool = false, forceRemoteRefresh: Bool = false) {
        host.logStartupProfile("apply_snapshot_start")
        let shouldPreserveDetailPane = preserveDetailPane && canPreserveDetailPaneAfterSidebarReload()
        pendingDatabaseReload = false
        host.commandPalette.invalidateCommandPaletteCache()
        host.configCache = snapshot.config
        host.loadShortcutSpecs()
        // Update the local device's section in place and keep already-loaded remote
        // sections, so a periodic refresh never makes remote devices vanish and
        // reload. Skip the full outline reload entirely when the local overview is
        // unchanged, so background polls don't collapse expanded projects.
        // Include the daemon status/compatibility in the unchanged check: when only those change (a
        // restart resolving a block, or an update-pending state clearing), the caption must still
        // reload or it keeps showing stale Resolve/update-pending UI.
        let previousLocalSection = host.deviceSections.first(where: { $0.deviceID == snapshot.localDeviceID })
        // An unreachable local daemon renders as offline (red caption), exactly like a remote device that
        // fails to load; otherwise the device is loaded. Fold loadState into the unchanged check so a
        // loaded→offline transition still reloads the caption even when both overviews are empty.
        let localLoadState = AppKitController.localDeviceLoadState(offlineMessage: snapshot.localOfflineMessage)
        let localOutlineUnchanged =
            previousLocalSection?.overview == snapshot.localDeviceOverview && previousLocalSection?.compatibility == snapshot.localCompatibility
            && previousLocalSection?.daemonStatus == snapshot.localDaemonStatus && previousLocalSection?.loadState == localLoadState
        let localSection = DeviceSection(
            deviceID: snapshot.localDeviceID, deviceName: snapshot.localDeviceName, isLocal: true, loadState: localLoadState,
            device: snapshot.localPairedDevice, projects: snapshot.projects, workspacesByProject: snapshot.workspacesByProject,
            workspaceRuntimeStatusByID: snapshot.workspaceRuntimeStatusByID, alertsGroups: snapshot.alertsGroups,
            overview: snapshot.localDeviceOverview, daemonStatus: snapshot.localDaemonStatus, compatibility: snapshot.localCompatibility)
        if let localIndex = host.deviceSections.firstIndex(where: { $0.deviceID == snapshot.localDeviceID }) {
            host.deviceSections[localIndex] = localSection
        } else {
            host.deviceSections.insert(localSection, at: 0)
        }
        host.localDeviceID = snapshot.localDeviceID
        host.localDeviceName = snapshot.localDeviceName
        host.localPairedDevice = snapshot.localPairedDevice
        host.localDeviceOverview = snapshot.localDeviceOverview
        // If the local block was showing and the daemon is now compatible, drop the obsolete block
        // (canPreserveDetailPaneAfterSidebarReload was evaluated against the stale pre-reload verdict).
        host.clearCompatibilityBlockIfResolved(deviceID: snapshot.localDeviceID)
        rebuildFlatSidebarData()
        host.loadAlertsDismissedAttentionItemIDs()
        host.pruneDismissedAlertsAttentionItemIDsIfNeeded()
        if !localOutlineUnchanged {
            host.outlineView.reloadData()
            applySidebarProjectExpansionState()
        }
        host.logStartupProfile("apply_snapshot_outline_ready")
        if !shouldPreserveDetailPane {
            host.refreshSelection()
            host.logStartupProfile("apply_snapshot_selection_ready")
        } else if !canPreserveDetailPaneAfterSidebarReload() {
            // The preserve verdict was computed against the pre-reload data; this reload removed what the
            // detail pane was preserving — e.g. the local daemon went offline and its selected workspace
            // vanished. Reconcile the pane instead of leaving stale workspace detail/actions visible.
            host.refreshSelection()
            host.logStartupProfile("apply_snapshot_selection_reconciled_ready")
        } else if AppKitController.shouldRefreshVisibleWorkspaceDetail(
            selectedWorkspaceID: host.selectedWorkspaceID, showingAlerts: host.showingAlerts, showingSettings: host.showingSettings,
            workspaceExists: host.selectedWorkspaceID.flatMap { findWorkspace(id: $0) } != nil, mainWindowIsFocused: host.window?.isKeyWindow == true,
            commandPaletteIsVisible: host.commandPalette.commandPalettePanel?.isVisible == true)
        {
            host.refreshSelection()
            host.logStartupProfile("apply_snapshot_selection_preserved_ready")
        }
        updateAlertsSidebarBadge()
        host.logStartupProfile("apply_snapshot_alerts_badge_ready", details: "group_count=\(host.alertsGroups.count)")
        if host.showingAlerts { host.showAlertsDetail() }
        loadRemoteDeviceSections(forceRefresh: forceRemoteRefresh)
    }

    /// Adds a section for every paired remote device and fetches each one's overview
    /// independently so a slow or unreachable device never blocks the sidebar.
    /// A reachable remote device's loaded overview plus its frozen-core handshake result.
    struct RemoteDeviceLoad: Sendable {
        /// `nil` when the device is reachable but wire-incompatible (no decodable overview).
        let overview: SpacesDeviceOverview?
        let daemonStatus: TerminalServiceDaemonStatus?
        let compatibility: SpacesWireCompatibility?
    }

    func loadRemoteDeviceSections(forceRefresh: Bool = false) {
        let remotes = host.macPairedDevices()
        var addedSection = false
        for record in remotes where !host.deviceSections.contains(where: { $0.deviceID == record.id }) {
            host.deviceSections.append(
                DeviceSection(deviceID: record.id, deviceName: record.name, isLocal: false, loadState: .loading, device: record))
            addedSection = true
        }
        if addedSection {
            host.outlineView.reloadData()
            applySidebarProjectExpansionState()
        }
        let clientApp = SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)
        let now = ContinuousClock.now
        let freshnessWindow = Duration.seconds(PollingConstants.remoteOverviewFreshnessInterval)
        var updatedReconnectSection = false
        for record in remotes {
            guard AppKitController.pairedDeviceHasRequiredCredentials(deviceID: record.id) else {
                if let index = host.deviceSections.firstIndex(where: { $0.deviceID == record.id }) {
                    updatedReconnectSection = updatedReconnectSection || host.deviceSections[index].loadState != .offline("Reconnect required")
                    host.deviceSections[index].loadState = .offline("Reconnect required")
                    host.deviceSections[index].device = record
                }
                continue
            }
            // A snapshot can be applied far more often than the metadata cadence
            // (process monitor, worktree discovery, event-driven reloads). Skip
            // devices fetched within the freshness window so local activity doesn't
            // spam remote overview requests; a freshly paired device has no recorded
            // instant and refreshes immediately. Forced reloads (explicit refresh,
            // mutations that expect fresh remote data) bypass the gate.
            if !forceRefresh, let last = remoteOverviewFetchInstants[record.id], now - last < freshnessWindow { continue }
            remoteOverviewFetchInstants[record.id] = now
            Task { @MainActor [weak self] in
                let result: Result<RemoteDeviceLoad, Error> = await Task.detached(priority: .userInitiated) {
                    do {
                        // Read compatibility from the overview's inline frozen-core status: a compatible
                        // remote costs one round-trip, and only an incompatible/too-old daemon falls back
                        // to the standalone handshake — which stays decodable when the overview would not,
                        // so the device is presented as blocked (no overview) rather than offline.
                        let resolution = try SpacesDeviceClient.resolveOverview(device: record, clientApp: clientApp)
                        return .success(
                            RemoteDeviceLoad(
                                overview: resolution.overview, daemonStatus: resolution.daemonStatus, compatibility: resolution.compatibility))
                    } catch { return .failure(error) }
                }.value
                self?.applyRemoteDeviceSection(deviceID: record.id, result: result)
            }
        }
        if updatedReconnectSection {
            rebuildFlatSidebarData()
            host.outlineView.reloadData()
            applySidebarProjectExpansionState()
            updateAlertsSidebarBadge()
        }
        refreshRemoteOverviewSubscriptions()
    }

    /// Enables and opens live overview subscriptions for paired remote devices.
    /// Called when background services start; the pull above still gives immediate
    /// population, while the subscription delivers subsequent changes by push.
    func startRemoteOverviewSubscriptions() {
        remoteOverviewSubscriptionsEnabled = true
        refreshRemoteOverviewSubscriptions()
    }

    func stopRemoteOverviewSubscriptions() {
        remoteOverviewSubscriptionsEnabled = false
        let clients = remoteOverviewSubscriptions
        remoteOverviewSubscriptions.removeAll()
        remoteOverviewSubscribing.removeAll()
        for client in clients.values { client.stop() }
    }

    /// Reconciles open subscriptions to the set of credentialed paired remotes:
    /// drops gone devices and opens one per newly present device.
    func refreshRemoteOverviewSubscriptions() {
        guard remoteOverviewSubscriptionsEnabled else { return }
        let remotes = host.macPairedDevices().filter { AppKitController.pairedDeviceHasRequiredCredentials(deviceID: $0.id) }
        let desiredIDs = Set(remotes.map(\.id))
        for (id, client) in remoteOverviewSubscriptions where !desiredIDs.contains(id) {
            // Remove before stopping so the disconnect callback treats it as intentional.
            remoteOverviewSubscriptions[id] = nil
            client.stop()
        }
        let clientApp = SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)
        for record in remotes where remoteOverviewSubscriptions[record.id] == nil && !remoteOverviewSubscribing.contains(record.id) {
            remoteOverviewSubscribing.insert(record.id)
            openRemoteOverviewSubscription(record: record, clientApp: clientApp)
        }
    }

    private func openRemoteOverviewSubscription(record: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp) {
        let deviceID = record.id
        // Build the stream callbacks with a single weak capture so the detached
        // connect task below captures only Sendable values (not `self`).
        let onOverview: @Sendable (SpacesDeviceOverview) -> Void = { [weak self] overview in
            // A pushed overview comes from a reachable, decodable daemon; read its inline
            // frozen-core status (if present) so the compatibility verdict rides along, the
            // same way the polling `resolveOverview` path derives it.
            let daemonStatus = overview.overview.daemonStatus
            let compatibility = daemonStatus.map { SpacesWireCompatibility.evaluate(daemonStatus: $0) }
            Task { @MainActor in
                self?.applyRemoteDeviceSection(
                    deviceID: deviceID,
                    result: .success(RemoteDeviceLoad(overview: overview, daemonStatus: daemonStatus, compatibility: compatibility)))
            }
        }
        let onDisconnect: @Sendable ((any Error)?) -> Void = { [weak self] error in
            Task { @MainActor in self?.handleRemoteOverviewDisconnected(deviceID: deviceID, error: error) }
        }
        Task { @MainActor [weak self] in
            // Resolving credentials and connecting block, so do it off the main actor.
            let client = await Task.detached(priority: .userInitiated) { () -> SpacesDeviceAPIOverviewStreamClient? in
                try? SpacesDeviceClient.subscribeOverview(device: record, clientApp: clientApp, onOverview: onOverview, onDisconnect: onDisconnect)
            }.value
            guard let self else {
                client?.stop()
                return
            }
            self.remoteOverviewSubscribing.remove(deviceID)
            guard let client else {
                // The connect attempt failed (remote offline at launch or still
                // unreachable on a reconnect). With no periodic metadata refresh to
                // fall back on, schedule the same delayed retry the disconnect path
                // uses so the remote section recovers on its own rather than staying
                // stale until an unrelated sidebar reload.
                self.scheduleRemoteOverviewReconnect()
                return
            }
            guard self.remoteOverviewSubscriptionsEnabled, self.host.macPairedDevices().contains(where: { $0.id == deviceID }) else {
                client.stop()
                return
            }
            self.remoteOverviewSubscriptions[deviceID] = client
        }
    }

    private func handleRemoteOverviewDisconnected(deviceID: String, error: (any Error)?) {
        // Ignore disconnects for subscriptions we intentionally removed.
        guard remoteOverviewSubscriptions[deviceID] != nil else { return }
        remoteOverviewSubscriptions[deviceID] = nil
        guard remoteOverviewSubscriptionsEnabled else { return }
        // An established stream dropping means the remote daemon or network went away. With no
        // periodic remote refresh to fall back on, transition the section to offline now — the same
        // way a failed pull does — so the sidebar shows the offline caption instead of stale
        // projects/alerts, then schedule the delayed reconnect. A graceful stream close carries no
        // error, so fall back to a descriptive reason for the offline tooltip.
        applyRemoteDeviceSection(deviceID: deviceID, result: .failure(error ?? RemoteOverviewDisconnectError.streamClosed))
        scheduleRemoteOverviewReconnect()
    }

    /// Retries opening overview subscriptions after a short delay so a persistently
    /// unreachable remote reconnects without spinning. Used both when an open stream
    /// drops and when the initial connect fails; `refreshRemoteOverviewSubscriptions`
    /// reopens any paired device that has no live subscription. This is
    /// reconnect-on-failure, not a poll of healthy state.
    private func scheduleRemoteOverviewReconnect() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.refreshRemoteOverviewSubscriptions()
        }
    }

    func applyRemoteDeviceSection(deviceID: String, result: Result<RemoteDeviceLoad, Error>) {
        guard let index = host.deviceSections.firstIndex(where: { $0.deviceID == deviceID }) else { return }
        // A background refresh re-fetches each remote; only touch the outline when
        // the device's overview or load state actually changed, so unchanged polls
        // don't collapse expanded projects.
        let wasLoaded = host.deviceSections[index].loadState == .loaded
        // Set when this call marks the device offline while a workspace/project of that device was the
        // current selection: its rows drop out of the merged sidebar data below, so the detail pane is
        // left stale and must fall back to the alerts view (see the end of this method).
        var selectionInvalidatedByOffline = false
        switch result {
        case .success(let load):
            // Compatibility/status can change while the overview stays identical (e.g. after a restart
            // updates a remote daemon), so the unchanged-check must include them or the badge/block
            // would keep showing the stale verdict until an unrelated overview change.
            let statusUnchanged =
                host.deviceSections[index].compatibility == load.compatibility && host.deviceSections[index].daemonStatus == load.daemonStatus
            host.deviceSections[index].daemonStatus = load.daemonStatus
            host.deviceSections[index].compatibility = load.compatibility
            // If this device's block was showing and it is now compatible, drop the obsolete block.
            host.clearCompatibilityBlockIfResolved(deviceID: deviceID)
            guard let overview = load.overview else {
                // Reachable but wire-incompatible: present an empty loaded section so the sidebar shows
                // the compatibility badge instead of a generic offline error.
                // Capture (before clearing) whether a workspace of this device is the current selection —
                // its detail controls are about to become stale and must switch to the block.
                let selectedWorkspaceUnderThisDevice =
                    host.selectedWorkspaceID.map { wsID in
                        host.deviceSections[index].workspacesByProject.values.contains { $0.contains { $0.id == wsID } }
                    } ?? false
                let changed = !wasLoaded || !statusUnchanged || host.deviceSections[index].overview != nil
                host.deviceSections[index].projects = []
                host.deviceSections[index].workspacesByProject = [:]
                host.deviceSections[index].workspaceRuntimeStatusByID = [:]
                host.deviceSections[index].alertsGroups = []
                host.deviceSections[index].overview = nil
                host.deviceSections[index].loadState = .loaded
                if changed {
                    rebuildFlatSidebarData()
                    host.outlineView.reloadData()
                    applySidebarProjectExpansionState()
                }
                if selectedWorkspaceUnderThisDevice, let verdict = load.compatibility {
                    host.showCompatibilityBlock(deviceID: deviceID, verdict: verdict)
                }
                updateAlertsSidebarBadge()
                return
            }
            if wasLoaded, statusUnchanged, host.deviceSections[index].overview == overview.overview {
                updateAlertsSidebarBadge()
                return
            }
            let collapseStates = (try? SpacesClientDatabase.defaultDatabase().projectCollapseStates(deviceID: deviceID)) ?? [:]
            let mapped = AppKitController.deviceSidebarData(from: overview.overview, deviceID: deviceID, projectCollapseStates: collapseStates)
            host.deviceSections[index].projects = mapped.projects
            host.deviceSections[index].workspacesByProject = mapped.workspacesByProject
            host.deviceSections[index].workspaceRuntimeStatusByID = mapped.workspaceRuntimeStatusByID
            host.deviceSections[index].alertsGroups = AppKitController.buildOverviewAlertsGroups(from: overview.overview, deviceID: deviceID)
            host.deviceSections[index].overview = overview.overview
            host.deviceSections[index].device = overview.device
            host.deviceSections[index].loadState = .loaded
        case .failure(let error):
            if case .offline = host.deviceSections[index].loadState { return }
            // Capture (before the rebuild drops this device's rows from the merged data) whether the
            // current selection belongs to this device, so the offline transition can reconcile a now-
            // stale detail pane.
            selectionInvalidatedByOffline = AppKitController.sidebarSelectionBelongsToDeviceSection(
                selectedWorkspaceID: host.selectedWorkspaceID, selectedProjectID: host.selectedProjectID,
                section: host.deviceSections[index])
            // Drop the offline device's cached rows and overview. The merged sidebar data already excludes
            // non-loaded sections, but the section's `overview` is still searched directly by id-based
            // lookups (e.g. `clientWorkspaceID(forTerminalSession:)`); leaving it populated lets an offline
            // remote's workspace/session ids resolve through the stale overview while `deviceID(forWorkspaceID:)`
            // falls back to the local daemon, misrouting terminal cleanup to the wrong device. Clearing here
            // (as the reachable-but-incompatible branch above already does) keeps offline devices out of every
            // overview lookup from one place.
            host.deviceSections[index].projects = []
            host.deviceSections[index].workspacesByProject = [:]
            host.deviceSections[index].workspaceRuntimeStatusByID = [:]
            host.deviceSections[index].alertsGroups = []
            host.deviceSections[index].overview = nil
            // Drop the prior verdict so an offline device shows "offline" rather than a stale Resolve
            // button / restart block from when it was last reachable-but-incompatible.
            host.deviceSections[index].compatibility = nil
            host.deviceSections[index].daemonStatus = nil
            host.deviceSections[index].loadState = .offline(error.localizedDescription)
            host.clearCompatibilityBlockIfResolved(deviceID: deviceID)
        }
        rebuildFlatSidebarData()
        host.outlineView.reloadData()
        applySidebarProjectExpansionState()
        updateAlertsSidebarBadge()
        // Rebuild the Alerts detail when either:
        //  (a) the offline device owned the current selection — its rows are gone from the merged data, so
        //      the workspace/project detail pane is stale and would misroute follow-up actions to the local
        //      daemon; fall back to the Alerts view, which clears the invalid selection; or
        //  (b) the Alerts pane is already visible — its cards and `alertsFocusRequestMap` were built from the
        //      pre-rebuild groups and would keep showing (and routing clicks to) the now-removed device's
        //      alerts until the user navigates away.
        if selectionInvalidatedByOffline || host.showingAlerts { host.showAlertsDetail() }
    }

    /// Recomputes the flat, id-keyed sidebar dictionaries as the union of every
    /// loaded device section. Project/workspace ids are globally unique, so the
    /// union never collides and all existing id-keyed lookups keep working.
    func rebuildFlatSidebarData() {
        var mergedProjects: [ProjectSummary] = []
        var mergedWorkspaces: [String: [WorkspaceSummary]] = [:]
        var mergedRuntime: [String: WorkspaceRuntimeStatus] = [:]
        var mergedAlerts: [AlertsGroup] = []
        for section in host.deviceSections where section.loadState == .loaded {
            mergedProjects.append(contentsOf: section.projects)
            mergedWorkspaces.merge(section.workspacesByProject) { current, _ in current }
            mergedRuntime.merge(section.workspaceRuntimeStatusByID) { current, _ in current }
            mergedAlerts.append(contentsOf: section.alertsGroups)
        }
        host.projects = mergedProjects
        host.workspacesByProject = mergedWorkspaces
        host.workspaceRuntimeStatusByID = mergedRuntime
        host.alertsGroups = mergedAlerts
    }

    func deviceRecord(forDeviceID deviceID: String) -> SpacesPairedDeviceRecord? {
        host.deviceSections.first(where: { $0.deviceID == deviceID })?.device
    }

    func deviceSection(id deviceID: String) -> DeviceSection? { host.deviceSections.first(where: { $0.deviceID == deviceID }) }

    func findWorkspace(id: String) -> (ProjectSummary, WorkspaceSummary)? {
        for project in host.projects {
            if let workspaces = host.workspacesByProject[project.id], let workspace = workspaces.first(where: { $0.id == id }) {
                return (project, workspace)
            }
        }
        return nil
    }

    private func isVisibleWorkspace(_ workspace: WorkspaceSummary) -> Bool { !workspace.isArchived && !workspace.isHidden }

    func visibleWorkspaces(projectID: String) -> [WorkspaceSummary] {
        if let cached = visibleWorkspacesCache[projectID] { return cached }
        let result = (host.workspacesByProject[projectID] ?? []).filter { isVisibleWorkspace($0) }.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        visibleWorkspacesCache[projectID] = result
        return result
    }

    /// True when the sidebar groups projects under per-device header rows: whenever more than one device
    /// is paired, or when any section is offline so its "offline" caption — the only surface for an
    /// unreachable daemon's reason — still has a header row to render in (a single offline local device
    /// otherwise has no project rows and would show nothing). A single loaded device stays a flat list.
    var showsDeviceHeaders: Bool {
        AppKitController.sidebarShowsDeviceHeaders(
            deviceCount: host.deviceSections.count, hasOfflineSection: host.deviceSections.contains { $0.loadState.isOffline })
    }

    func deviceProjects(deviceID: String) -> [ProjectSummary] {
        host.projects.filter { project in
            guard project.deviceID == deviceID else { return false }
            // A non-git project's row stands in for its single workspace. If that
            // workspace is hidden it has no visible workspace, so drop the row entirely
            // (it stays reachable from the Workspace Visibility dialog) rather than
            // leaving a dead stand-in that selects nothing.
            if !project.isGitRepo, visibleWorkspaces(projectID: project.id).isEmpty { return false }
            return true
        }
    }

    func navigateSidebarSelection(direction: Int) -> Bool {
        guard
            let target = AppKitController.sidebarArrowSelectionTarget(
                visibleWorkspaceIDsByProject: host.projects.map { project in
                    let visibleWorkspaceIDs = project.isCollapsed ? [] : visibleWorkspaces(projectID: project.id).map(\.id)
                    return (project.id, visibleWorkspaceIDs)
                }, hiddenWorkspaceIDs: [], selectedProjectID: host.selectedProjectID, selectedWorkspaceID: host.selectedWorkspaceID,
                showingAlerts: host.showingAlerts, direction: direction)
        else { return false }
        switch target {
        case .alerts: host.showAlertsDetail()
        case .workspace(let workspaceID):
            guard let (_, workspace) = findWorkspace(id: workspaceID) else { return false }
            selectWorkspace(workspace)
        }
        return true
    }

    func handleSidebarArrowNavigation(event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.isEmpty else { return false }
        let direction: Int
        switch event.keyCode {
        case UInt16(kVK_UpArrow): direction = -1
        case UInt16(kVK_DownArrow): direction = 1
        default: return false
        }
        return navigateSidebarSelection(direction: direction)
    }

    func selectWorkspace(_ workspace: WorkspaceSummary) {
        // A non-git project's single workspace has no dedicated row; its project row
        // stands in for it, so select that row instead of a `.workspace` item.
        let owningProject = findWorkspace(id: workspace.id)?.0
        for row in 0..<host.outlineView.numberOfRows {
            guard let ref = host.outlineView.item(atRow: row) as? OutlineItemRef else { continue }
            switch ref.item {
            case .workspace(_, let ws) where ws.id == workspace.id:
                host.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                return
            case .project(let project) where !project.isGitRepo && project.id == owningProject?.id:
                host.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                return
            default: continue
            }
        }
    }

    func orderedSidebarWorkspaces() -> [WorkspaceSummary] { host.projects.flatMap { visibleWorkspaces(projectID: $0.id) } }

    private var singleDeviceID: String { host.deviceSections.first?.deviceID ?? SpacesPairedDeviceRecord.localDeviceID }

    private func rootChildRef(index: Int) -> OutlineItemRef {
        if showsDeviceHeaders {
            let deviceID = (index >= 0 && index < host.deviceSections.count) ? host.deviceSections[index].deviceID : singleDeviceID
            return outlineItemRef(for: .device(deviceID))
        }
        let deviceProjects = deviceProjects(deviceID: singleDeviceID)
        let project = (index >= 0 && index < deviceProjects.count) ? deviceProjects[index] : (deviceProjects.first ?? Self.placeholderProject)
        return outlineItemRef(for: .project(project))
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return showsDeviceHeaders ? host.deviceSections.count : deviceProjects(deviceID: singleDeviceID).count }
        if case .device(let deviceID) = (item as? OutlineItemRef)?.item { return deviceProjects(deviceID: deviceID).count }
        if case .project(let project) = (item as? OutlineItemRef)?.item {
            // Non-git projects own exactly one workspace (the project directory) and
            // render as a single flat row, so they expose no expandable children.
            guard project.isGitRepo else { return 0 }
            return max(visibleWorkspaces(projectID: project.id).count, 1)
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if case .device = (item as? OutlineItemRef)?.item { return true }
        if case .project(let project) = (item as? OutlineItemRef)?.item { return project.isGitRepo }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { true }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        switch (item as? OutlineItemRef)?.item {
        case .device, .emptyProject: return false
        default: return true
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return rootChildRef(index: index) }
        if case .device(let deviceID) = (item as? OutlineItemRef)?.item {
            let deviceProjects = deviceProjects(deviceID: deviceID)
            let project = (index >= 0 && index < deviceProjects.count) ? deviceProjects[index] : (deviceProjects.first ?? Self.placeholderProject)
            return outlineItemRef(for: .project(project))
        }
        if case .project(let project) = (item as? OutlineItemRef)?.item {
            let visible = visibleWorkspaces(projectID: project.id)
            guard !visible.isEmpty else { return outlineItemRef(for: .emptyProject(project)) }
            let workspace =
                (index >= 0 && index < visible.count ? visible[index] : nil)
                ?? WorkspaceSummary(
                    id: "", branch: nil, baseBranch: nil, dir: "", isRunning: false, isArchived: false, isHidden: false, isDefault: false)
            return outlineItemRef(for: .workspace(project, workspace))
        }
        return outlineItemRef(for: .project(host.projects.first ?? Self.placeholderProject))
    }

    private func outlineItemRef(for item: OutlineItem) -> OutlineItemRef {
        let key = item.cacheKey
        if let existing = outlineItemRefCache[key] {
            existing.item = item
            return existing
        }
        let ref = OutlineItemRef(item)
        outlineItemRefCache[key] = ref
        return ref
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let ref = item as? OutlineItemRef else { return nil }
        switch ref.item {
        case .device(let deviceID): return sidebarSectionRowCell(deviceID: deviceID)
        case .project(let project):
            // A non-git project row stands in for its single workspace, so it reads as
            // selected whenever that workspace is the active selection.
            let isSelected =
                project.isGitRepo
                ? host.selectedProjectID == project.id && host.selectedWorkspaceID == nil
                : host.selectedProjectID == project.id && host.selectedWorkspaceID != nil
            return projectRowCell(project: project, isSelected: isSelected, isExpanded: outlineView.isItemExpanded(ref))
        case .workspace(let project, let workspace):
            return workspaceRowCell(project: project, workspace: workspace, isSelected: host.selectedWorkspaceID == workspace.id)
        case .emptyProject(let project): return emptyProjectRowCell(project: project)
        }
    }

    private func deviceSectionName(deviceID: String) -> String {
        host.deviceSections.first(where: { $0.deviceID == deviceID })?.deviceName ?? deviceID
    }

    private func deviceSectionLoadStateLabel(deviceID: String) -> (text: String, color: NSColor)? {
        guard let section = host.deviceSections.first(where: { $0.deviceID == deviceID }) else { return nil }
        switch section.loadState {
        case .loading: return ("loading…", .tertiaryLabelColor)
        case .offline: return ("offline", sidebarFailedIndicatorColor())
        case .loaded:
            // Incompatible devices render an actionable button in the caption (see sidebarSectionRowCell);
            // a compatible-but-older daemon shows a quiet "update pending" caption.
            if section.compatibility?.isCompatible == false { return nil }
            if AppKitController.daemonUpdatePending(status: section.daemonStatus) { return ("update pending", .tertiaryLabelColor) }
            return nil
        }
    }

    /// Renders a paired device as a quiet, non-interactive section caption. The device node stays a
    /// structural parent of its project rows (always expanded), so the caption carries no chevron or
    /// selection chrome; load state is shown inline as muted trailing text.
    private func sidebarSectionRowCell(deviceID: String) -> NSTableCellView {
        let cell = NSTableCellView()

        let nameLabel = NSTextField(labelWithString: deviceSectionName(deviceID: deviceID).localizedUppercase)
        nameLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingTail

        let contentRow = NSStackView()
        contentRow.orientation = .horizontal
        contentRow.alignment = .centerY
        contentRow.spacing = 6
        contentRow.translatesAutoresizingMaskIntoConstraints = false
        contentRow.addArrangedSubview(nameLabel)
        contentRow.addArrangedSubview(NSView())

        if let compatibility = host.deviceSections.first(where: { $0.deviceID == deviceID })?.compatibility, !compatibility.isCompatible {
            // Device headers are non-selectable, so an incompatible device's only affordance is this
            // caption button, which opens the compatibility block (restart/update) in the detail pane.
            let button = NSButton(
                title: compatibility == .clientTooOld ? "Update app" : "Resolve", target: self, action: #selector(compatibilityActionClicked(_:)))
            button.bezelStyle = .inline
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11, weight: .semibold)
            button.contentTintColor = .systemOrange
            button.identifier = NSUserInterfaceItemIdentifier("compat:\(deviceID)")
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            contentRow.addArrangedSubview(button)
        } else if let state = deviceSectionLoadStateLabel(deviceID: deviceID) {
            let stateLabel = NSTextField(labelWithString: state.text)
            stateLabel.font = .systemFont(ofSize: 11, weight: .regular)
            stateLabel.textColor = state.color
            stateLabel.lineBreakMode = .byTruncatingTail
            stateLabel.setContentHuggingPriority(.required, for: .horizontal)
            stateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            // Surface the offline reason (e.g. the daemon startup error) on hover; the caption itself
            // stays the terse "offline" to match remote devices and avoid widening the sidebar.
            if case .offline(let message)? = host.deviceSections.first(where: { $0.deviceID == deviceID })?.loadState, !message.isEmpty {
                stateLabel.toolTip = message
            }
            contentRow.addArrangedSubview(stateLabel)
        }

        cell.addSubview(contentRow)
        NSLayoutConstraint.activate([
            contentRow.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            contentRow.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            contentRow.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
        ])
        return cell
    }

    private func projectRowCell(project: ProjectSummary, isSelected: Bool, isExpanded: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.setAccessibilityIdentifier("sidebar-project-\(project.id)")

        let rowBackground = NSView()
        rowBackground.translatesAutoresizingMaskIntoConstraints = false
        rowBackground.wantsLayer = true
        rowBackground.layer?.cornerRadius = UIRadius.regular
        rowBackground.layer?.borderWidth = isSelected ? 1 : 0
        rowBackground.layer?.borderColor = sidebarCardBorderColor(isSelected: true).cgColor
        rowBackground.layer?.backgroundColor = isSelected ? sidebarSelectedCardBackgroundColor().cgColor : NSColor.clear.cgColor

        let titleLabel = NSTextField(labelWithString: project.name)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = sidebarPrimaryTextColor(isSelected: isSelected, isArchived: false)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityIdentifier("sidebar-project-title-\(project.id)")

        let leadingStack = NSStackView()
        leadingStack.orientation = .horizontal
        leadingStack.alignment = .centerY
        leadingStack.spacing = 8
        leadingStack.translatesAutoresizingMaskIntoConstraints = false
        leadingStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        leadingStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Non-git projects are a single workspace, so surface its running indicator
        // inline the way a workspace row would.
        if !project.isGitRepo, let workspace = visibleWorkspaces(projectID: project.id).first {
            let lifecycleRunning =
                (host.workspaceRuntimeStatusByID[workspace.id]?.lifecycleState ?? WorkspaceLifecycleState(isRunning: workspace.isRunning)) == .running
            let statusIcon = NSImageView()
            statusIcon.translatesAutoresizingMaskIntoConstraints = false
            statusIcon.image = NSImage(systemSymbolName: lifecycleRunning ? "circle.fill" : "circle", accessibilityDescription: "Status")
            statusIcon.contentTintColor = lifecycleRunning ? sidebarRunningIndicatorColor() : sidebarIdleIndicatorColor()
            statusIcon.toolTip = lifecycleRunning ? "Running" : "Stopped"
            statusIcon.widthAnchor.constraint(equalToConstant: 10).isActive = true
            statusIcon.heightAnchor.constraint(equalToConstant: 10).isActive = true
            leadingStack.addArrangedSubview(statusIcon)
        }
        leadingStack.addArrangedSubview(titleLabel)

        let accessoryStack = NSStackView()
        accessoryStack.orientation = .horizontal
        accessoryStack.alignment = .centerY
        accessoryStack.spacing = 4
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false
        accessoryStack.setContentHuggingPriority(.required, for: .horizontal)
        let settingsButton = host.sidebarRowIconButton(
            symbol: "gearshape", tooltip: "Project settings for \(project.name)", action: #selector(AppKitController.showProjectSettings(_:)))
        settingsButton.identifier = NSUserInterfaceItemIdentifier(project.id)
        settingsButton.setAccessibilityIdentifier("sidebar-project-settings-\(project.id)")
        let projectActions = AppKitController.sidebarProjectActions(isGitRepo: project.isGitRepo)
        if projectActions.showsSettings { accessoryStack.addArrangedSubview(settingsButton) }

        let contentRow = NSStackView()
        contentRow.orientation = .horizontal
        contentRow.alignment = .centerY
        contentRow.spacing = 8
        contentRow.translatesAutoresizingMaskIntoConstraints = false
        contentRow.addArrangedSubview(leadingStack)
        contentRow.addArrangedSubview(NSView())
        contentRow.addArrangedSubview(accessoryStack)
        // Only git projects expand into a workspace list, so only they show a chevron.
        if project.isGitRepo {
            let chevron = NSImageView()
            chevron.translatesAutoresizingMaskIntoConstraints = false
            chevron.imageScaling = .scaleNone
            chevron.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
            chevron.contentTintColor = .tertiaryLabelColor
            chevron.setContentHuggingPriority(.required, for: .horizontal)
            chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([chevron.widthAnchor.constraint(equalToConstant: 14), chevron.heightAnchor.constraint(equalToConstant: 14)])
            contentRow.addArrangedSubview(chevron)
        }

        rowBackground.addSubview(contentRow)
        cell.addSubview(rowBackground)
        NSLayoutConstraint.activate([
            rowBackground.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            rowBackground.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            rowBackground.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
            rowBackground.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -2),

            contentRow.leadingAnchor.constraint(equalTo: rowBackground.leadingAnchor, constant: 10),
            contentRow.trailingAnchor.constraint(equalTo: rowBackground.trailingAnchor, constant: -10),
            contentRow.topAnchor.constraint(equalTo: rowBackground.topAnchor, constant: 3),
            contentRow.bottomAnchor.constraint(equalTo: rowBackground.bottomAnchor, constant: -3),
        ])
        if projectActions.showsAddWorkspace {
            let addButton = host.sidebarRowIconButton(
                symbol: "plus", tooltip: "New workspace in \(project.name)", action: #selector(AppKitController.addWorkspace(_:)))
            addButton.identifier = NSUserInterfaceItemIdentifier(project.id)
            addButton.setAccessibilityIdentifier("sidebar-project-add-workspace-\(project.id)")
            accessoryStack.addArrangedSubview(addButton)
        }
        return cell
    }

    private func emptyProjectRowCell(project: ProjectSummary) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.setAccessibilityIdentifier("sidebar-project-empty-\(project.id)")

        let hintLabel = NSTextField(labelWithString: "No workspaces yet")
        hintLabel.font = NSFontManager.shared.convert(.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(hintLabel)
        NSLayoutConstraint.activate([
            hintLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 22),
            hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -10),
            hintLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func workspaceRowCell(project: ProjectSummary, workspace: WorkspaceSummary, isSelected: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.setAccessibilityIdentifier("sidebar-workspace-\(workspace.id)")

        let cardView = NSView()
        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.setAccessibilityIdentifier("sidebar-workspace-card-\(workspace.id)")
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = UIRadius.regular
        cardView.layer?.borderWidth = isSelected ? 1 : 0
        cardView.layer?.borderColor = sidebarCardBorderColor(isSelected: true).cgColor
        cardView.layer?.backgroundColor = isSelected ? sidebarSelectedCardBackgroundColor().cgColor : NSColor.clear.cgColor

        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 4
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let titleRow = NSStackView()
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 6
        titleRow.translatesAutoresizingMaskIntoConstraints = false

        let statusIcon = NSImageView()
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        let runtimeStatus =
            host.workspaceRuntimeStatusByID[workspace.id]
            ?? WorkspaceRuntimeStatus(
                workspaceID: workspace.id, lifecycleState: WorkspaceLifecycleState(isRunning: workspace.isRunning), runtimeHealth: .healthy,
                hasTrackedRuntimeIndicators: false, runningProcessCount: 0, exitedProcessCount: 0, waitingAgentWindowCount: 0,
                missingConfiguredProcessCount: 0, missingConfiguredBrowserSessionCount: 0)
        let isLifecycleRunning = runtimeStatus.lifecycleState == .running
        statusIcon.image = NSImage(systemSymbolName: isLifecycleRunning ? "circle.fill" : "circle", accessibilityDescription: "Status")
        statusIcon.contentTintColor = isLifecycleRunning ? sidebarRunningIndicatorColor() : sidebarIdleIndicatorColor()
        statusIcon.toolTip = isLifecycleRunning ? "Running" : "Stopped"
        statusIcon.widthAnchor.constraint(equalToConstant: 10).isActive = true
        statusIcon.heightAnchor.constraint(equalToConstant: 10).isActive = true

        let nameLabel = NSTextField(labelWithString: workspace.displayName)
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.textColor = sidebarPrimaryTextColor(isSelected: isSelected, isArchived: workspace.isArchived)
        nameLabel.setAccessibilityIdentifier("sidebar-workspace-title-\(workspace.id)")
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        titleRow.addArrangedSubview(statusIcon)
        titleRow.addArrangedSubview(nameLabel)
        if let warningSummary = runtimeStatus.warningSummary {
            let warningIcon = NSImageView()
            warningIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Status warning")
            warningIcon.contentTintColor = sidebarFailedIndicatorColor()
            warningIcon.toolTip = warningSummary
            warningIcon.translatesAutoresizingMaskIntoConstraints = false
            warningIcon.widthAnchor.constraint(equalToConstant: 11).isActive = true
            warningIcon.heightAnchor.constraint(equalToConstant: 11).isActive = true
            titleRow.addArrangedSubview(warningIcon)
        }
        contentStack.addArrangedSubview(titleRow)

        cardView.addSubview(contentStack)
        cell.addSubview(cardView)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: cell.leadingAnchor), cardView.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            cardView.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
            cardView.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -2),

            contentStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            contentStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 5),
            contentStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -5),
        ])

        return cell
    }

    private func sidebarMetadataRow(
        symbol: String, text: String, isSelected: Bool, leadingIndent: CGFloat = 0, trailingSymbol: String? = nil, trailingColor: NSColor? = nil
    ) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false

        if leadingIndent > 0 {
            let indent = NSView()
            indent.translatesAutoresizingMaskIntoConstraints = false
            indent.widthAnchor.constraint(equalToConstant: leadingIndent).isActive = true
            indent.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(indent)
        }

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = sidebarMetadataTextColor(isSelected: isSelected)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 10).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 10).isActive = true

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = sidebarMetadataTextColor(isSelected: isSelected)
        label.lineBreakMode = .byTruncatingTail

        row.addArrangedSubview(icon)
        row.addArrangedSubview(label)

        if let trailingSymbol {
            let trailingIcon = NSImageView()
            trailingIcon.image = NSImage(systemSymbolName: trailingSymbol, accessibilityDescription: nil)
            trailingIcon.contentTintColor = trailingColor ?? sidebarMetadataTextColor(isSelected: isSelected)
            trailingIcon.translatesAutoresizingMaskIntoConstraints = false
            trailingIcon.widthAnchor.constraint(equalToConstant: 10).isActive = true
            trailingIcon.heightAnchor.constraint(equalToConstant: 10).isActive = true
            row.addArrangedSubview(trailingIcon)
        }

        return row
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let ref = item as? OutlineItemRef else { return 24 }
        switch ref.item {
        case .device: return 30
        case .project(let project):
            let isSelected = project.isGitRepo ? host.selectedWorkspaceID == nil : host.selectedWorkspaceID != nil
            return host.selectedProjectID == project.id && isSelected ? 32 : 30
        case .workspace: return 32
        case .emptyProject: return 28
        }
    }

    func sidebarPanelBackgroundColor() -> NSColor { sidebarThemeColor(light: (248, 247, 241), dark: (15, 21, 23)) }

    func sidebarCardBackgroundColor(isArchived: Bool) -> NSColor {
        let alpha: CGFloat = isArchived ? 0.42 : 0.55
        return sidebarThemeColor(light: (240, 238, 230), dark: (24, 36, 39), alpha: alpha)
    }

    func sidebarSelectedCardBackgroundColor() -> NSColor { sidebarThemeColor(light: (226, 224, 216), dark: (24, 35, 39), alpha: 0.85) }

    func sidebarCardBorderColor(isSelected: Bool) -> NSColor {
        if isSelected { return sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184), alpha: 0.28) }
        return sidebarThemeColor(light: (213, 216, 211), dark: (48, 67, 70), alpha: 0.72)
    }

    func sidebarPrimaryTextColor(isSelected: Bool, isArchived: Bool) -> NSColor {
        let alpha: CGFloat = if isArchived { 0.70 } else if isSelected { 0.96 } else { 0.92 }
        return sidebarThemeColor(light: (16, 32, 40), dark: (234, 240, 239), alpha: alpha)
    }

    func sidebarMetadataTextColor(isSelected: Bool) -> NSColor {
        let alpha: CGFloat = isSelected ? 0.88 : 0.82
        return sidebarThemeColor(light: (58, 77, 87), dark: (173, 192, 196), alpha: alpha)
    }

    func sidebarRunningIndicatorColor() -> NSColor { sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184), alpha: 0.95) }

    func sidebarFailedIndicatorColor() -> NSColor { sidebarThemeColor(light: (186, 67, 111), dark: (255, 111, 91), alpha: 0.95) }

    func sidebarIdleIndicatorColor() -> NSColor { sidebarThemeColor(light: (213, 216, 211), dark: (48, 67, 70), alpha: 0.85) }

    func sidebarThemeColor(light: (Int, Int, Int), dark: (Int, Int, Int), alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let source = isDark ? dark : light
            return NSColor(calibratedRed: CGFloat(source.0) / 255, green: CGFloat(source.1) / 255, blue: CGFloat(source.2) / 255, alpha: alpha)
        }
    }

    @objc private func compatibilityActionClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("compat:") else { return }
        let deviceID = String(raw.dropFirst("compat:".count))
        guard let verdict = host.deviceCompatibility(forDeviceID: deviceID), !verdict.isCompatible else { return }
        host.showCompatibilityBlock(deviceID: deviceID, verdict: verdict)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        if host.suppressOutlineSelectionChanges { return }
        let row = host.outlineView.selectedRow
        guard row >= 0, let ref = host.outlineView.item(atRow: row) as? OutlineItemRef else {
            let previousProjectID = host.selectedProjectID
            let previousWorkspaceID = host.selectedWorkspaceID
            host.selectedProjectID = nil
            host.selectedWorkspaceID = nil
            host.showingSettings = false
            if !host.showingAlerts { host.showPlaceholder() }
            refreshSidebarSelectionRows(
                previousProjectID: previousProjectID, currentProjectID: host.selectedProjectID, previousWorkspaceID: previousWorkspaceID,
                currentWorkspaceID: host.selectedWorkspaceID)
            return
        }
        let item = ref.item
        // Structural rows (devices, empty placeholders) and collapsible git project
        // headers are not selectable detail targets, so deselect and bail. Non-git
        // project rows fall through: they stand in for their single workspace.
        switch item {
        case .device, .emptyProject:
            host.suppressOutlineSelectionChanges = true
            host.outlineView.deselectAll(nil)
            host.suppressOutlineSelectionChanges = false
            return
        case .project(let project) where project.isGitRepo:
            host.suppressOutlineSelectionChanges = true
            host.outlineView.deselectAll(nil)
            host.suppressOutlineSelectionChanges = false
            return
        default: break
        }

        let previousProjectID = host.selectedProjectID
        let previousWorkspaceID = host.selectedWorkspaceID
        host.lastSelectedRow = row
        switch item {
        case .device, .emptyProject: return
        case .project(let project):
            guard let workspace = visibleWorkspaces(projectID: project.id).first else { return }
            host.selectedProjectID = project.id
            host.selectedWorkspaceID = workspace.id
            AppKitController.setClientActiveWorkspaceID(workspace.id)
            host.showingSettings = false
            host.showWorkspaceDetail(project: project, workspace: workspace)
        case .workspace(let project, let workspace):
            host.selectedProjectID = project.id
            host.selectedWorkspaceID = workspace.id
            AppKitController.setClientActiveWorkspaceID(workspace.id)
            host.showingSettings = false
            host.showWorkspaceDetail(project: project, workspace: workspace)
        }
        refreshSidebarSelectionRows(
            previousProjectID: previousProjectID, currentProjectID: host.selectedProjectID, previousWorkspaceID: previousWorkspaceID,
            currentWorkspaceID: host.selectedWorkspaceID)
    }

    func refreshSidebarSelectionRows(previousProjectID: String?, currentProjectID: String?, previousWorkspaceID: String?, currentWorkspaceID: String?)
    {
        var rowsToReload = IndexSet()
        if let previousProjectID, let previousRow = rowIndex(forProjectID: previousProjectID) { rowsToReload.insert(previousRow) }
        if let currentProjectID, let currentRow = rowIndex(forProjectID: currentProjectID) { rowsToReload.insert(currentRow) }
        if let previousWorkspaceID, let previousRow = rowIndex(forWorkspaceID: previousWorkspaceID) { rowsToReload.insert(previousRow) }
        if let currentWorkspaceID, let currentRow = rowIndex(forWorkspaceID: currentWorkspaceID) { rowsToReload.insert(currentRow) }
        guard !rowsToReload.isEmpty else { return }
        host.outlineView.reloadData(forRowIndexes: rowsToReload, columnIndexes: IndexSet(integer: 0))
    }

    private func rowIndex(forWorkspaceID workspaceID: String) -> Int? {
        for row in 0..<host.outlineView.numberOfRows {
            guard let ref = host.outlineView.item(atRow: row) as? OutlineItemRef else { continue }
            if case .workspace(_, let workspace) = ref.item, workspace.id == workspaceID { return row }
        }
        return nil
    }

    private func rowIndex(forProjectID projectID: String) -> Int? {
        for row in 0..<host.outlineView.numberOfRows {
            guard let ref = host.outlineView.item(atRow: row) as? OutlineItemRef else { continue }
            if case .project(let project) = ref.item, project.id == projectID { return row }
        }
        return nil
    }

    private func rowIndex(forDeviceID deviceID: String) -> Int? {
        for row in 0..<host.outlineView.numberOfRows {
            guard let ref = host.outlineView.item(atRow: row) as? OutlineItemRef else { continue }
            if case .device(let id) = ref.item, id == deviceID { return row }
        }
        return nil
    }

    func toggleProjectExpanded(projectID: String) {
        guard let row = rowIndex(forProjectID: projectID), let item = host.outlineView.item(atRow: row) else { return }
        // true when currently expanded (want to collapse); false when currently collapsed (want to expand).
        // Uses in-memory state instead of isItemExpanded, which may be unreliable when the outline
        // cell is hidden by indentationPerLevel = 0.
        let isCollapsed = !(host.projects.first(where: { $0.id == projectID })?.isCollapsed ?? false)
        let previousProjectID = host.selectedProjectID
        let previousWorkspaceID = host.selectedWorkspaceID
        do {
            let deviceID = host.projects.first(where: { $0.id == projectID })?.deviceID ?? host.localDeviceID
            try host.clientDatabase().setProjectCollapsed(deviceID: deviceID, projectID: projectID, isCollapsed: isCollapsed)
            updateProjectCollapsedStateInMemory(projectID: projectID, isCollapsed: isCollapsed)
        } catch {
            host.showError(error)
            return
        }
        if isCollapsed { host.outlineView.collapseItem(item) } else { host.outlineView.expandItem(item) }
        if isCollapsed, let selectedWorkspaceID = host.selectedWorkspaceID, let (project, _) = findWorkspace(id: selectedWorkspaceID),
            project.id == projectID
        {
            host.selectedWorkspaceID = nil
            host.selectedProjectID = nil
            host.lastSelectedRow = -1
            host.suppressOutlineSelectionChanges = true
            host.outlineView.deselectAll(nil)
            host.suppressOutlineSelectionChanges = false
            host.refreshSelection()
            refreshSidebarSelectionRows(
                previousProjectID: previousProjectID, currentProjectID: nil, previousWorkspaceID: previousWorkspaceID, currentWorkspaceID: nil)
        }
        host.outlineView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    func applySidebarProjectExpansionState() {
        if showsDeviceHeaders {
            for section in host.deviceSections {
                guard let row = rowIndex(forDeviceID: section.deviceID), let item = host.outlineView.item(atRow: row) else { continue }
                host.outlineView.expandItem(item)
            }
        }
        for project in host.projects {
            guard let row = rowIndex(forProjectID: project.id), let item = host.outlineView.item(atRow: row) else { continue }
            if project.isCollapsed { host.outlineView.collapseItem(item) } else { host.outlineView.expandItem(item) }
        }
    }

    private func updateProjectCollapsedStateInMemory(projectID: String, isCollapsed: Bool) {
        guard let index = host.projects.firstIndex(where: { $0.id == projectID }) else { return }
        let project = host.projects[index]
        host.projects[index] = ProjectSummary(
            id: project.id, name: project.name, dir: project.dir, isGitRepo: project.isGitRepo, defaultBranch: project.defaultBranch,
            isCollapsed: isCollapsed, deviceID: project.deviceID)
    }

    /// Update the Alerts sidebar row badge with the current attention item count.
    func updateAlertsSidebarBadge() {
        let totalCount = host.alertsAttentionCount()
        if let badge = alertsRowBadge {
            badge.stringValue = "\(totalCount)"
            badge.isHidden = totalCount == 0
        }
        NSApp.dockTile.badgeLabel = totalCount == 0 ? nil : "\(totalCount)"
        NSApp.dockTile.display()
    }

    func makeSidebarTopBarRow() -> NSView {
        let row = NSView()

        let iconView = NSImageView()
        if let appIcon = NSApp.applicationIconImage.copy() as? NSImage {
            appIcon.size = NSSize(width: 18, height: 18)
            iconView.image = appIcon
        } else {
            iconView.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "Spaces")
            iconView.contentTintColor = sidebarRunningIndicatorColor()
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([iconView.widthAnchor.constraint(equalToConstant: 18), iconView.heightAnchor.constraint(equalToConstant: 18)])

        let mobileButton = host.sidebarRowIconButton(
            symbol: "desktopcomputer.and.macbook", tooltip: "Devices", action: #selector(AppKitController.showMobileConnection))
        mobileButton.setAccessibilityIdentifier("sidebar-device-pairing")
        let settingsButton = host.sidebarRowIconButton(
            symbol: "gearshape", tooltip: "User settings", action: #selector(AppKitController.showSettings))
        let reloadButton = host.sidebarRowIconButton(symbol: "arrow.clockwise", tooltip: "Reload", action: #selector(AppKitController.reloadTapped))

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(NSView())
        stack.addArrangedSubview(mobileButton)
        stack.addArrangedSubview(settingsButton)
        stack.addArrangedSubview(reloadButton)

        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor), stack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            stack.topAnchor.constraint(equalTo: row.topAnchor), stack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }

    func makeAlertsSidebarRow() -> NSView {
        let row = NSView()
        row.setAccessibilityIdentifier("sidebar-alerts")

        let titleLabel = NSTextField(labelWithString: "Alerts")
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor

        let hintLabel = NSTextField(labelWithString: host.footerShortcutHint(for: .guiAlertsShortcut))
        hintLabel.font = .systemFont(ofSize: 10, weight: .regular)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.setContentHuggingPriority(.required, for: .horizontal)

        let badge = NSTextField(labelWithString: "")
        badge.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = sidebarFailedIndicatorColor().cgColor
        badge.layer?.cornerRadius = UIRadius.pill(forHeight: 14)
        badge.isBordered = false
        badge.isEditable = false
        badge.drawsBackground = false
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 18), badge.heightAnchor.constraint(equalToConstant: 14),
        ])
        alertsRowBadge = badge

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 8, bottom: 7, right: 8)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = UIRadius.regular
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(hintLabel)
        stack.addArrangedSubview(NSView())  // spacer
        stack.addArrangedSubview(badge)
        alertsRowStack = stack

        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor), stack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            stack.topAnchor.constraint(equalTo: row.topAnchor), stack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])

        let click = NSClickGestureRecognizer(target: host, action: #selector(AppKitController.alertsRowClicked))
        row.addGestureRecognizer(click)
        alertsRowView = row
        return row
    }

    func updateAlertsRowAppearance() {
        guard let stack = alertsRowStack else { return }
        if host.showingAlerts {
            stack.layer?.backgroundColor = sidebarSelectedCardBackgroundColor().cgColor
        } else {
            stack.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}
