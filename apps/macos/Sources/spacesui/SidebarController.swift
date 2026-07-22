import AppKit
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
        reloadCoordinator = SidebarReloadCoordinator<SidebarDataSnapshot>(
            loadSnapshot: { await AppKitController.initialSidebarDataSnapshot() },
            applySnapshot: { [weak self] snapshot, forceRemoteRefresh in
                self?.applySidebarDataSnapshot(snapshot, preserveDetailPane: true, forceRemoteRefresh: forceRemoteRefresh)
            },
            handleFailure: { [weak self] error, failurePlaceholderMessage in
                guard let self else { return }
                if let failurePlaceholderMessage {
                    self.host.showError(error)
                    self.host.showPlaceholder(message: failurePlaceholderMessage)
                } else {
                    self.host.handleBackgroundRefreshFailure(error, source: "sidebar_reload")
                }
            })
    }

    typealias OutlineItem = AppKitController.OutlineItem
    typealias OutlineItemRef = AppKitController.OutlineItemRef
    typealias DeviceSection = AppKitController.DeviceSection
    typealias SidebarDeviceLoadState = AppKitController.SidebarDeviceLoadState
    typealias SidebarDataSnapshot = AppKitController.SidebarDataSnapshot
    typealias AlertsGroup = AppKitController.AlertsGroup
    typealias SidebarArrowSelectionTarget = AppKitController.SidebarArrowSelectionTarget

    enum RemoteOverviewDisconnectAction: Equatable {
        case ignoreIntentionalRemoval
        case recordStartupDisconnect
        case markOffline
    }

    nonisolated static func remoteOverviewDisconnectAction(hasStoredSubscription: Bool, isOpeningSubscription: Bool) -> RemoteOverviewDisconnectAction
    {
        if hasStoredSubscription { return .markOffline }
        if isOpeningSubscription { return .recordStartupDisconnect }
        return .ignoreIntentionalRemoval
    }

    private var outlineItemRefCache: [String: OutlineItemRef] = [:]
    /// Memoized filtered+sorted visible workspaces per project. `visibleWorkspaces`
    /// is on the NSOutlineView data-source hot path (queried per row); caching keeps
    /// it from re-filtering and re-sorting on every query, and it is invalidated
    /// whenever the host's `workspacesByProject` changes.
    private var visibleWorkspacesCache: [String: [WorkspaceSummary]] = [:]
    /// Memoized per-workspace runtime-target rows, on the same data-source hot path
    /// and invalidated together with `visibleWorkspacesCache` (every overview change
    /// reassigns the host's `workspacesByProject`, which invalidates both).
    private var runtimeTargetItemsCache: [String: [SidebarRuntimeTargetItem]] = [:]
    /// Workspaces the user pinned open by an explicit mouse interaction — clicking the
    /// workspace row or expanding it with its disclosure chevron. A pinned workspace
    /// stays expanded even after the selection moves away, until the user collapses it
    /// with the chevron. Workspaces default to collapsed (empty set). Held in memory on
    /// this long-lived controller so the state survives sidebar refreshes without a
    /// database round trip (project collapse, by contrast, is a deliberate
    /// organizational choice persisted to `project_sidebar_state`).
    private var pinnedWorkspaceIDs: Set<String> = []
    /// The workspace expanded only because it is the current arrow-key selection, not
    /// because it was pinned. It collapses as soon as the selection moves off it. This
    /// makes keyboard navigation a lightweight preview while mouse clicks pin, matching
    /// "collapse when no longer selected, unless explicitly expanded by a click."
    private var transientlyExpandedWorkspaceID: String?
    /// The runtime target currently being renamed inline, if any. The row cell swaps
    /// its title for an editor while this matches (same pattern as the device rename).
    private var renamingRuntimeTarget: (workspaceID: String, item: SidebarRuntimeTargetItem)?
    weak var renamingRuntimeTargetField: NSTextField?
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
    private var reloadCoordinator: SidebarReloadCoordinator<SidebarDataSnapshot>!
    /// Set when a database-change signal arrives while the user is mid-edit;
    /// flushed at idle points so a deferred change is not lost.
    private var pendingDatabaseReload = false

    // Alerts sidebar row
    private var alertsRowView: NSView?
    private var alertsRowStack: NSStackView?
    private var alertsRowBadge: NSTextField?

    // Automations sidebar row (header + collapsible running-run children)
    private var automationsRowContainer: NSView?
    private var automationsHeaderStack: NSStackView?
    private var automationsRowBadge: NSTextField?
    private var automationsChildrenStack: NSStackView?
    private var automationsDisclosureButton: NSButton?
    /// Whether the running-run children are expanded. Session state; defaults collapsed.
    private var automationsExpanded = false
    /// Top-bar warning icon shown while another Spaces instance owns desktop control.
    private(set) weak var desktopControlStatusIcon: NSImageView?

    private static let placeholderProject = ProjectSummary(id: "", name: "", dir: "", isGitRepo: false, defaultBranch: nil)

    /// Leading indent applied to a git project's workspace rows (and their runtime-target rows) so
    /// they read as nested under the project header. A non-git project has no workspace level, so its
    /// runtime-target rows are not given this extra indent.
    private static let workspaceIndent: CGFloat = 16
    private static let runtimeTargetShortcutSlotWidth: CGFloat = 20

    func invalidateVisibleWorkspacesCache() {
        visibleWorkspacesCache.removeAll(keepingCapacity: true)
        runtimeTargetItemsCache.removeAll(keepingCapacity: true)
    }

    /// Wires the host's outline view to this controller as its delegate/data source
    /// and installs the row mouse-down and arrow-navigation callbacks.
    func attachOutlineView(_ outlineView: SidebarOutlineView) {
        outlineView.selectedWorkspaceHighlight = { [weak self, weak outlineView] in
            guard let self, let outlineView else { return nil }
            return self.selectedWorkspaceHighlight(in: outlineView)
        }
        outlineView.onRowMouseDown = { [weak self] row in
            guard let self, let ref = self.host.outlineView.item(atRow: row) as? OutlineItemRef else { return false }
            if case .project(let project) = ref.item {
                if project.isGitRepo {
                    // Git project rows are not selectable; a click just toggles their workspace list.
                    self.toggleProjectExpanded(projectID: project.id)
                    return true
                }
                // A non-git project row stands in for its single workspace, so it stays selectable.
                // Also toggle its runtime-target list on click, matching how git project and workspace
                // rows respond to a row click; returning false lets normal row selection proceed.
                self.toggleProjectExpanded(projectID: project.id)
                return false
            }
            if case .runtimeTarget(_, let workspace, let item) = ref.item {
                // While this row's inline rename editor is up, let clicks reach the editor.
                if let renaming = self.renamingRuntimeTarget, renaming.workspaceID == workspace.id, renaming.item.key == item.key { return false }
                // Clicking into a workspace's targets is a mouse interaction with it, so keep it pinned open.
                self.pinWorkspaceOpen(workspace.id)
                if self.host.selectedWorkspaceID != workspace.id { self.selectWorkspace(workspace) }
                self.host.focusSidebarRuntimeTarget(workspaceID: workspace.id, key: item.key)
                return true
            }
            if case .workspace(_, let workspace) = ref.item {
                // A mouse click on a workspace row is an explicit expand: pin it open so it stays
                // expanded after the selection moves away. Arrow-key navigation routes through
                // selectWorkspace without this handler and so expands the workspace only transiently.
                self.pinWorkspaceOpen(workspace.id)
                return false
            }
            return false
        }
        outlineView.onRowMenu = { [weak self] row in self?.menuForRow(row) }
        outlineView.delegate = self
        outlineView.dataSource = self
    }

    /// Cancels in-flight reload state. Called from the host's background-service
    /// teardown and termination paths.
    func stopSidebarTasks() {
        pendingDatabaseReload = false
        reloadCoordinator.stop()
        stopRemoteOverviewSubscriptions()
    }

    func cancelSidebarReloadTask() { reloadCoordinator.cancelCurrentTask() }

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
        if host.workspaceSettingsWorkspaceID != nil { return true }
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
            if host.showLocalDaemonCompatibilityBlockIfNeeded(error) {
                host.startBackgroundServicesIfNeeded()
                return
            }
            host.showError(error)
            host.showPlaceholder(message: "Spaces couldn't load workspace data.")
            host.startBackgroundServicesIfNeeded()
        }
    }

    func requestSidebarReload(failurePlaceholderMessage: String? = nil, forceRemoteRefresh: Bool = false) {
        reloadCoordinator.request(failurePlaceholderMessage: failurePlaceholderMessage, forceRemoteRefresh: forceRemoteRefresh)
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
        host.maybeRequestSilentDaemonHandoff(deviceID: snapshot.localDeviceID, status: snapshot.localDaemonStatus)
        host.localDeviceID = snapshot.localDeviceID
        host.localDeviceName = snapshot.localDeviceName
        host.localPairedDevice = snapshot.localPairedDevice
        host.localDeviceOverview = snapshot.localDeviceOverview
        // If the local block was showing and the daemon is now compatible, drop the obsolete block
        // (canPreserveDetailPaneAfterSidebarReload was evaluated against the stale pre-reload verdict).
        host.clearCompatibilityBlockIfResolved(deviceID: snapshot.localDeviceID)
        tearDownBrowserSessionsForLocallyStoppedWorkspaces(
            previous: previousLocalSection?.workspaceRuntimeStatusByID, current: snapshot.workspaceRuntimeStatusByID,
            previousOverview: previousLocalSection?.overview)
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
        host.reopenPersistedPanelWindowsIfPossible()
        loadRemoteDeviceSections(forceRefresh: forceRemoteRefresh)
    }

    /// Closes browser-session tabs for local-device workspaces that the daemon now reports as no
    /// longer running, comparing the previous local-section runtime state against the just-fetched
    /// snapshot. This reload is the only channel through which the GUI learns about stop/archive
    /// actions taken outside it (the CLI, MCP, the Device API, or another device), so without this
    /// diff those externally-stopped workspaces would leave their tracked Chrome tabs and the
    /// client `browser_session_window_ids` rows alive. The GUI's own stop/restart/archive handlers
    /// already tear the tabs down eagerly; `closeLocalBrowserSessionWindows` is idempotent, so a
    /// workspace stopped through the GUI that also surfaces here closes nothing the second time.
    private func tearDownBrowserSessionsForLocallyStoppedWorkspaces(
        previous: [String: WorkspaceRuntimeStatus]?, current: [String: WorkspaceRuntimeStatus], previousOverview: SpacesDeviceOverviewPayload?
    ) {
        guard let previous else { return }
        for workspaceID in Self.workspaceIDsTransitionedToNotRunning(previous: previous, current: current) {
            host.closeLocalBrowserSessionWindows(
                workspaceID: workspaceID,
                configuredBrowserSessionTargetURLs: AppKitController.browserSessionTargetURLs(workspaceID: workspaceID, overview: previousOverview))
        }
    }

    /// Workspace ids that were running in `previous` but are no longer running in `current` — either
    /// reported stopped or absent entirely (deleted/archived out of the runtime map). Pure so the
    /// transition contract can be unit-tested without Chrome or the client store.
    nonisolated static func workspaceIDsTransitionedToNotRunning(
        previous: [String: WorkspaceRuntimeStatus], current: [String: WorkspaceRuntimeStatus]
    ) -> [String] {
        previous.compactMap { workspaceID, previousStatus in
            previousStatus.lifecycleState == .running && current[workspaceID]?.lifecycleState != .running ? workspaceID : nil
        }
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
            guard AppKitController.pairedDeviceHasRequiredCredentials(device: record) else {
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
        let remotes = host.macPairedDevices().filter { AppKitController.pairedDeviceHasRequiredCredentials(device: $0) }
        let desiredIDs = Set(remotes.map(\.id))
        for (id, client) in remoteOverviewSubscriptions where !desiredIDs.contains(id) {
            // Remove before stopping so the disconnect callback treats it as intentional.
            remoteOverviewSubscriptions[id] = nil
            client.stop()
            host.stopRemoteBrowserForwards(deviceID: id)
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
            // frozen-core status so the compatibility verdict rides along, the same way the
            // polling `resolveOverview` path derives it.
            let daemonStatus = overview.overview.daemonStatus
            let compatibility = SpacesWireCompatibility.evaluate(daemonStatus: daemonStatus)
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
            host.maybeRequestSilentDaemonHandoff(deviceID: deviceID, status: load.daemonStatus)
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
                host.stopRemoteBrowserForwards(deviceID: deviceID)
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
            host.deviceSections[index].alertsGroups = AppKitController.buildOverviewAlertsGroups(
                from: overview.overview, deviceID: deviceID, deviceName: host.deviceSections[index].deviceName)
            host.deviceSections[index].overview = overview.overview
            host.deviceSections[index].device = overview.device
            host.deviceSections[index].loadState = .loaded
            host.reconcileRemoteBrowserForwards(device: overview.device, overview: overview.overview)
        case .failure(let error):
            if case .offline = host.deviceSections[index].loadState { return }
            // Capture (before the rebuild drops this device's rows from the merged data) whether the
            // current selection belongs to this device, so the offline transition can reconcile a now-
            // stale detail pane.
            selectionInvalidatedByOffline = AppKitController.sidebarSelectionBelongsToDeviceSection(
                selectedWorkspaceID: host.selectedWorkspaceID, selectedProjectID: host.selectedProjectID, section: host.deviceSections[index])
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
            host.stopRemoteBrowserForwards(deviceID: deviceID)
        }
        rebuildFlatSidebarData()
        host.outlineView.reloadData()
        applySidebarProjectExpansionState()
        updateAlertsSidebarBadge()
        host.reopenPersistedPanelWindowsIfPossible()
        // Rebuild the Alerts detail when either:
        //  (a) the offline device owned the current selection — its rows are gone from the merged data, so
        //      the workspace/project detail pane is stale and would misroute follow-up actions to the local
        //      daemon; fall back to the Alerts view, which clears the invalid selection; or
        //  (b) the Alerts pane is already visible — its cards and `alertsFocusRequestMap` were built from the
        //      pre-rebuild groups and would keep showing (and routing clicks to) the now-removed device's
        //      alerts until the user navigates away.
        if selectionInvalidatedByOffline || host.showingAlerts { host.showAlertsDetail() }
        if host.showingAutomations { host.showAutomationsDetail() }
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
        // host.workspaceIndex is a flat id -> (projectID, workspace) map rebuilt alongside
        // workspacesByProject (see its didSet), so this is O(1) plus one linear scan over
        // projects (typically far smaller than projects x workspaces) instead of a nested scan.
        guard let entry = host.workspaceIndex[id], let project = host.projects.first(where: { $0.id == entry.projectID }) else { return nil }
        return (project, entry.workspace)
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

    /// The runtime-target rows shown under a workspace, memoized per workspace id.
    func runtimeTargetItems(workspaceID: String) -> [SidebarRuntimeTargetItem] {
        if let cached = runtimeTargetItemsCache[workspaceID] { return cached }
        let items = host.sidebarRuntimeTargetItems(workspaceID: workspaceID)
        runtimeTargetItemsCache[workspaceID] = items
        return items
    }

    /// A non-git project row stands in for its single workspace, so its outline
    /// children are that workspace's runtime targets.
    private func nonGitProjectTargetWorkspace(_ project: ProjectSummary) -> WorkspaceSummary? {
        guard !project.isGitRepo else { return nil }
        return visibleWorkspaces(projectID: project.id).first
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return showsDeviceHeaders ? host.deviceSections.count : deviceProjects(deviceID: singleDeviceID).count }
        if case .device(let deviceID) = (item as? OutlineItemRef)?.item { return deviceProjects(deviceID: deviceID).count }
        if case .project(let project) = (item as? OutlineItemRef)?.item {
            // Non-git projects own exactly one workspace (the project directory) and render
            // as a single flat row; their children are that workspace's runtime targets.
            guard project.isGitRepo else {
                guard let workspace = nonGitProjectTargetWorkspace(project) else { return 0 }
                return runtimeTargetItems(workspaceID: workspace.id).count
            }
            return max(visibleWorkspaces(projectID: project.id).count, 1)
        }
        if case .workspace(_, let workspace) = (item as? OutlineItemRef)?.item { return runtimeTargetItems(workspaceID: workspace.id).count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if case .device = (item as? OutlineItemRef)?.item { return true }
        if case .project(let project) = (item as? OutlineItemRef)?.item {
            guard project.isGitRepo else {
                guard let workspace = nonGitProjectTargetWorkspace(project) else { return false }
                return !runtimeTargetItems(workspaceID: workspace.id).isEmpty
            }
            return true
        }
        if case .workspace(_, let workspace) = (item as? OutlineItemRef)?.item { return !runtimeTargetItems(workspaceID: workspace.id).isEmpty }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { true }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        switch (item as? OutlineItemRef)?.item {
        case .device, .emptyProject, .runtimeTarget: return false
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
            if let workspace = nonGitProjectTargetWorkspace(project) {
                let items = runtimeTargetItems(workspaceID: workspace.id)
                if index >= 0 && index < items.count { return outlineItemRef(for: .runtimeTarget(project, workspace, items[index])) }
            }
            let visible = visibleWorkspaces(projectID: project.id)
            guard !visible.isEmpty else { return outlineItemRef(for: .emptyProject(project)) }
            let workspace =
                (index >= 0 && index < visible.count ? visible[index] : nil)
                ?? WorkspaceSummary(
                    id: "", branch: nil, baseBranch: nil, dir: "", isRunning: false, isArchived: false, isHidden: false, isDefault: false)
            return outlineItemRef(for: .workspace(project, workspace))
        }
        if case .workspace(let project, let workspace) = (item as? OutlineItemRef)?.item {
            let items = runtimeTargetItems(workspaceID: workspace.id)
            if index >= 0 && index < items.count { return outlineItemRef(for: .runtimeTarget(project, workspace, items[index])) }
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
            return projectRowCell(project: project, isSelected: isSelected)
        case .workspace(let project, let workspace):
            return workspaceRowCell(project: project, workspace: workspace, isSelected: host.selectedWorkspaceID == workspace.id)
        case .emptyProject(let project): return emptyProjectRowCell(project: project)
        case .runtimeTarget(let project, let workspace, let item):
            return runtimeTargetRowCell(workspace: workspace, item: item, nestedUnderWorkspace: project.isGitRepo)
        }
    }

    private func deviceSectionName(deviceID: String) -> String {
        host.deviceSections.first(where: { $0.deviceID == deviceID })?.displayName ?? deviceID
    }

    private func deviceSectionLoadStateLabel(deviceID: String) -> (text: String, color: NSColor)? {
        guard let section = host.deviceSections.first(where: { $0.deviceID == deviceID }) else { return nil }
        switch section.loadState {
        case .loading: return ("loading…", .tertiaryLabelColor)
        case .offline: return ("offline", sidebarFailedIndicatorColor())
        case .loaded:
            // Incompatible devices render an actionable button in the caption (see sidebarSectionRowCell);
            // a device with a newer build installed than its daemon is running shows a quiet
            // "update pending" caption.
            if section.compatibility?.isCompatible == false { return nil }
            if section.daemonStatus?.isUpdatePending == true { return ("update pending", .tertiaryLabelColor) }
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

    private func projectRowCell(project: ProjectSummary, isSelected: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.setAccessibilityIdentifier("sidebar-project-\(project.id)")
        let usesGroupedWorkspaceSelection = isSelected && !project.isGitRepo && host.selectedWorkspaceID != nil

        let rowBackground = NSView()
        rowBackground.translatesAutoresizingMaskIntoConstraints = false
        rowBackground.wantsLayer = true
        rowBackground.layer?.cornerRadius = UIRadius.regular
        rowBackground.layer?.borderWidth = isSelected && !usesGroupedWorkspaceSelection ? 1 : 0
        bindAppearanceReactiveLayer(rowBackground) { [weak self] view in
            view.layer?.borderColor = self?.sidebarCardBorderColor(isSelected: true).cgColor
            view.layer?.backgroundColor =
                isSelected && !usesGroupedWorkspaceSelection ? self?.sidebarSelectedCardBackgroundColor().cgColor : NSColor.clear.cgColor
        }

        let titleLabel = NSTextField(labelWithString: project.name)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = sidebarPrimaryTextColor(isSelected: isSelected, isArchived: false)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityIdentifier("sidebar-project-title-\(project.id)")

        let leadingStack = NSStackView()
        leadingStack.orientation = .horizontal
        leadingStack.alignment = .centerY
        leadingStack.spacing = 6
        leadingStack.translatesAutoresizingMaskIntoConstraints = false
        leadingStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        leadingStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Every project row reserves a leading icon slot so titles align in one column, and the glyph
        // marks the row as a project (never a workspace, which lead with a status circle). A git project
        // shows a muted connected-nodes glyph; a non-git project is a plain directory, so it shows a
        // folder tinted by its single workspace's run state — green when running, muted when stopped —
        // which is a prominent status without mimicking a workspace's leading dot.
        let leadingIcon = NSImageView()
        leadingIcon.translatesAutoresizingMaskIntoConstraints = false
        leadingIcon.widthAnchor.constraint(equalToConstant: 13).isActive = true
        leadingIcon.heightAnchor.constraint(equalToConstant: 13).isActive = true
        if project.isGitRepo {
            // The marketing site's project glyph (connected nodes) marks a git project without reading
            // as the ubiquitous branch icon.
            let glyph = RowPrimitives.projectGlyphImage()
            glyph.accessibilityDescription = "Git project"
            leadingIcon.image = glyph
            leadingIcon.contentTintColor = .tertiaryLabelColor
            leadingIcon.toolTip = "Git repository"
        } else {
            let workspace = visibleWorkspaces(projectID: project.id).first
            let lifecycleRunning =
                (workspace.flatMap { host.workspaceRuntimeStatusByID[$0.id]?.lifecycleState }
                    ?? WorkspaceLifecycleState(isRunning: workspace?.isRunning ?? false)) == .running
            leadingIcon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: lifecycleRunning ? "Running" : "Stopped")
            leadingIcon.contentTintColor = lifecycleRunning ? sidebarRunningIndicatorColor() : sidebarIdleIndicatorColor()
            leadingIcon.toolTip = lifecycleRunning ? "Running" : "Stopped"
        }
        leadingStack.addArrangedSubview(leadingIcon)
        leadingStack.addArrangedSubview(titleLabel)

        let accessoryStack = NSStackView()
        accessoryStack.orientation = .horizontal
        accessoryStack.alignment = .centerY
        // Match the workspace row's trailing spacing (and inset, below) so the gear and chevron
        // line up in the same columns across project and workspace rows.
        accessoryStack.spacing = 6
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false
        accessoryStack.setContentHuggingPriority(.required, for: .horizontal)
        // Both git and non-git project rows open project settings. A non-git project stands in for
        // its single workspace, and its project template is kept in sync with that workspace (see
        // updateProjectConfig), so editing project settings edits the config that actually runs while
        // still exposing project-level Delete and spaces.yaml import/export.
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

        rowBackground.addSubview(contentRow)
        cell.addSubview(rowBackground)
        NSLayoutConstraint.activate([
            rowBackground.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            rowBackground.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            rowBackground.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
            rowBackground.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -2),

            contentRow.leadingAnchor.constraint(equalTo: rowBackground.leadingAnchor, constant: 10),
            // -12 matches the workspace card's content trailing inset so the gear/chevron columns align.
            contentRow.trailingAnchor.constraint(equalTo: rowBackground.trailingAnchor, constant: -12),
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
        // A project row carries a right-edge disclosure chevron mirroring its collapse state. A git
        // project is always collapsible (it can hold workspaces); a non-git project is collapsible
        // only when its single workspace has runtime targets to hide.
        if outlineView(host.outlineView, isItemExpandable: OutlineItemRef(.project(project))) {
            let isExpanded = !project.isCollapsed
            let chevron = host.sidebarRowChevronButton(
                expanded: isExpanded, tooltip: isExpanded ? "Collapse \(project.name)" : "Expand \(project.name)",
                action: #selector(AppKitController.toggleSidebarProjectDisclosure(_:)))
            chevron.identifier = NSUserInterfaceItemIdentifier(project.id)
            chevron.setAccessibilityIdentifier("sidebar-project-disclosure-\(project.id)")
            accessoryStack.addArrangedSubview(chevron)
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
            // Align with the indented workspace rows this placeholder stands in for.
            hintLabel.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Self.workspaceIndent + 12),
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
        cardView.layer?.borderWidth = 0
        bindAppearanceReactiveLayer(cardView) { [weak self] view in
            view.layer?.borderColor = self?.sidebarCardBorderColor(isSelected: true).cgColor
            view.layer?.backgroundColor = NSColor.clear.cgColor
        }

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
        let gearSpacer = NSView()
        gearSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleRow.addArrangedSubview(gearSpacer)
        let settingsButton = host.sidebarRowIconButton(
            symbol: "gearshape", tooltip: "Workspace settings for \(workspace.displayName)",
            action: #selector(AppKitController.showWorkspaceSettings(_:)))
        settingsButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        settingsButton.setAccessibilityIdentifier("sidebar-workspace-settings-\(workspace.id)")
        titleRow.addArrangedSubview(settingsButton)
        // A workspace with no runtime targets has nothing to expand, so it carries no chevron.
        if !runtimeTargetItems(workspaceID: workspace.id).isEmpty {
            let isExpanded = isWorkspaceExpanded(workspace.id)
            let chevron = host.sidebarRowChevronButton(
                expanded: isExpanded, tooltip: isExpanded ? "Collapse \(workspace.displayName)" : "Expand \(workspace.displayName)",
                action: #selector(AppKitController.toggleSidebarWorkspaceDisclosure(_:)))
            chevron.identifier = NSUserInterfaceItemIdentifier(workspace.id)
            chevron.setAccessibilityIdentifier("sidebar-workspace-disclosure-\(workspace.id)")
            titleRow.addArrangedSubview(chevron)
        }
        contentStack.addArrangedSubview(titleRow)
        titleRow.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

        cardView.addSubview(contentStack)
        cell.addSubview(cardView)

        NSLayoutConstraint.activate([
            // Indent the card so the workspace reads as nested under its git project header.
            cardView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Self.workspaceIndent),
            cardView.trailingAnchor.constraint(equalTo: cell.trailingAnchor), cardView.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
            cardView.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -2),

            contentStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            contentStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 5),
            contentStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -5),
        ])

        return cell
    }

    /// The SF Symbol conveying a runtime target's kind in the sidebar list, matching the
    /// icons the settings sections use (terminal for process-backed rows, globe for
    /// browser sessions, sparkles for coding agents).
    private static func runtimeTargetSymbol(kind: AppKitController.WorkspaceRunShortcutTarget.Kind) -> String {
        switch kind {
        case .browser: return "globe"
        case .process, .window, .missingConfiguredProcess: return "terminal"
        case .agent, .agentLauncher: return "sparkles"
        }
    }

    private func runtimeTargetSymbolColor(item: SidebarRuntimeTargetItem, isSelected: Bool) -> NSColor {
        switch item.runState {
        case .running: return sidebarRunningIndicatorColor()
        case .exited: return sidebarFailedIndicatorColor()
        case .notStarted, nil: return sidebarMetadataTextColor(isSelected: isSelected)
        }
    }

    private func runtimeTargetTextColor(item: SidebarRuntimeTargetItem, isSelected: Bool) -> NSColor {
        switch item.runState {
        case .running: return sidebarRunningIndicatorColor()
        case .exited: return sidebarFailedIndicatorColor()
        case .notStarted: return sidebarMetadataTextColor(isSelected: isSelected)
        case nil: return sidebarPrimaryTextColor(isSelected: isSelected, isArchived: false)
        }
    }

    private func runtimeTargetRowCell(workspace: WorkspaceSummary, item: SidebarRuntimeTargetItem, nestedUnderWorkspace: Bool) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.setAccessibilityIdentifier("sidebar-target-\(workspace.id)-\(item.key)")
        let isWorkspaceSelected = host.selectedWorkspaceID == workspace.id
        let bottomPadding: CGFloat = isWorkspaceSelected && isLastRuntimeTarget(workspaceID: workspace.id, key: item.key) ? 6 : 0

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false

        // The ⌘-number hint leads the row (left of the kind icon), matching the
        // command palette's shortcut-icon-title ordering. Every row carries the fixed-width
        // slot — hints render only on the selected workspace's rows, and reserving the
        // space keeps target rows vertically aligned across workspaces either way.
        let chipSlot = NSView()
        chipSlot.translatesAutoresizingMaskIntoConstraints = false
        chipSlot.widthAnchor.constraint(equalToConstant: Self.runtimeTargetShortcutSlotWidth).isActive = true
        chipSlot.setContentHuggingPriority(.required, for: .horizontal)
        if host.selectedWorkspaceID == workspace.id, let index = item.shortcutIndex {
            let chip = RowPrimitives.sidebarShortcutHint(host.windowShortcutBadgeText(index: index))
            chipSlot.addSubview(chip)
            NSLayoutConstraint.activate([
                chip.trailingAnchor.constraint(equalTo: chipSlot.trailingAnchor), chip.centerYAnchor.constraint(equalTo: chipSlot.centerYAnchor),
            ])
        }
        row.addArrangedSubview(chipSlot)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: Self.runtimeTargetSymbol(kind: item.kind), accessibilityDescription: nil)?.withSymbolConfiguration(
            .init(pointSize: 10, weight: .medium))
        icon.contentTintColor = runtimeTargetSymbolColor(item: item, isSelected: isWorkspaceSelected)
        icon.toolTip = item.runState.map { $0 == .running ? "Running" : ($0 == .exited ? "Exited" : "Not started") }
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 12).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 12).isActive = true
        icon.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(icon)

        if let renaming = renamingRuntimeTarget, renaming.workspaceID == workspace.id, renaming.item.key == item.key {
            let editor = NSTextField(string: item.title)
            editor.font = .systemFont(ofSize: 11, weight: .regular)
            editor.delegate = host
            editor.toolTip = "Press Return to save, Esc to cancel."
            editor.setAccessibilityIdentifier("sidebar-target-rename-input")
            editor.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            renamingRuntimeTargetField = editor
            Task { @MainActor [weak editor] in
                guard let editor else { return }
                editor.window?.makeFirstResponder(editor)
                editor.selectText(nil)
            }
            row.addArrangedSubview(editor)
        } else {
            let titleLabel = PressableLabel(labelWithString: item.title)
            // Mirror the row identifier onto the title label. AppKit does not expose an
            // NSTableCellView's own accessibility identifier as a queryable element (only its
            // text/interactive subviews are), so the cell-level id on line ~1147 is invisible to
            // VoiceOver and UI automation; the label carries a findable copy. The press action
            // mirrors `onRowMouseDown`'s runtimeTarget branch below so VoiceOver activation and
            // UI automation's `AXPress` both actually open/focus the target, not just find it.
            titleLabel.setAccessibilityIdentifier("sidebar-target-\(workspace.id)-\(item.key)")
            titleLabel.onAccessibilityPress = { [weak self] in
                guard let self else { return }
                if self.host.selectedWorkspaceID != workspace.id { self.selectWorkspace(workspace) }
                self.host.focusSidebarRuntimeTarget(workspaceID: workspace.id, key: item.key)
            }
            titleLabel.font = .systemFont(ofSize: 11, weight: .regular)
            titleLabel.textColor = runtimeTargetTextColor(item: item, isSelected: isWorkspaceSelected)
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(titleLabel)
        }

        row.addArrangedSubview(NSView())

        cell.addSubview(row)
        NSLayoutConstraint.activate([
            // Indent the target row one level below its owner so it reads as nested: two levels in
            // under a git workspace (project → workspace → target), one level in under a non-git
            // project (project → target), whose project row stands in for the missing workspace level.
            row.leadingAnchor.constraint(
                equalTo: cell.leadingAnchor, constant: nestedUnderWorkspace ? Self.workspaceIndent * 2 : Self.workspaceIndent),
            row.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10), row.topAnchor.constraint(equalTo: cell.topAnchor),
            row.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -bottomPadding),
        ])
        return cell
    }

    private func isLastRuntimeTarget(workspaceID: String, key: String) -> Bool { runtimeTargetItems(workspaceID: workspaceID).last?.key == key }

    /// Context payload carried on runtime-target menu items so the action selectors can
    /// recover the clicked target without re-deriving it from the outline row.
    private final class RuntimeTargetMenuContext: NSObject {
        let workspaceID: String
        let item: SidebarRuntimeTargetItem
        init(workspaceID: String, item: SidebarRuntimeTargetItem) {
            self.workspaceID = workspaceID
            self.item = item
        }
    }

    func menuForRow(_ row: Int) -> NSMenu? {
        guard let ref = host.outlineView.item(atRow: row) as? OutlineItemRef else { return nil }
        switch ref.item {
        case .runtimeTarget(_, let workspace, let item): return runtimeTargetMenu(workspace: workspace, item: item)
        case .workspace(_, let workspace): return workspaceContextMenu(workspace: workspace)
        // A non-git project's row stands in for its single workspace, so its right-click menu offers
        // the same workspace actions, resolved to that lone visible workspace.
        case .project(let project) where !project.isGitRepo:
            guard let workspace = visibleWorkspaces(projectID: project.id).first else { return nil }
            return workspaceContextMenu(workspace: workspace)
        default: return nil
        }
    }

    /// Right-click menu for a sidebar workspace row (and the standin row of a non-git project):
    /// lifecycle controls gated on run state, path actions, and Hide. Lifecycle/Hide items carry the
    /// workspace id and path actions carry the directory in `identifier.rawValue`. Reveal also carries
    /// the workspace id so it resolves remote/local state against the clicked row, not the selection.
    private func workspaceContextMenu(workspace: WorkspaceSummary) -> NSMenu {
        let menu = NSMenu()
        func addItem(_ title: String, symbol: String, target: AnyObject, action: Selector, identifier: String, representedObject: Any? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
            item.representedObject = representedObject
            menu.addItem(item)
        }
        if workspace.isRunning {
            addItem("Restart", symbol: "arrow.clockwise", target: self, action: #selector(restartWorkspaceMenuItem(_:)), identifier: workspace.id)
            addItem("Stop", symbol: "stop", target: self, action: #selector(stopWorkspaceMenuItem(_:)), identifier: workspace.id)
        } else {
            addItem("Start", symbol: "play", target: self, action: #selector(startWorkspaceMenuItem(_:)), identifier: workspace.id)
        }
        menu.addItem(.separator())
        addItem("Copy path", symbol: "doc.on.doc", target: host, action: #selector(AppKitController.copyDirectoryPath(_:)), identifier: workspace.dir)
        // Reveal in Finder needs a path on this Mac, so it is offered only for local-device workspaces.
        if host.isLocalWorkspace(workspace) {
            addItem(
                "Reveal in Finder", symbol: "folder", target: host, action: #selector(AppKitController.revealDirectoryInFinder(_:)),
                identifier: workspace.dir,
                representedObject: AppKitController.WorkspacePathActionContext(workspaceID: workspace.id, path: workspace.dir))
        }
        menu.addItem(.separator())
        addItem("Hide", symbol: "eye.slash", target: self, action: #selector(hideWorkspaceMenuItem(_:)), identifier: workspace.id)
        // Archive is destructive (it removes the git worktree), so it sits last, below the separator, and
        // routes through the same confirmation the detail ⋯ overflow menu uses.
        addItem("Archive…", symbol: "archivebox", target: self, action: #selector(archiveWorkspaceMenuItem(_:)), identifier: workspace.id)
        return menu
    }

    @objc private func startWorkspaceMenuItem(_ sender: NSMenuItem) {
        guard let id = sender.identifier?.rawValue else { return }
        host.launchWorkspace(id: id)
    }

    @objc private func restartWorkspaceMenuItem(_ sender: NSMenuItem) {
        guard let id = sender.identifier?.rawValue else { return }
        host.restartWorkspace(id: id)
    }

    @objc private func stopWorkspaceMenuItem(_ sender: NSMenuItem) {
        guard let id = sender.identifier?.rawValue else { return }
        host.stopWorkspace(id: id)
    }

    @objc private func hideWorkspaceMenuItem(_ sender: NSMenuItem) {
        guard let id = sender.identifier?.rawValue else { return }
        host.hideWorkspace(id: id)
    }

    @objc private func archiveWorkspaceMenuItem(_ sender: NSMenuItem) {
        guard let id = sender.identifier?.rawValue else { return }
        host.archiveWorkspace(id: id)
    }

    private func runtimeTargetMenu(workspace: WorkspaceSummary, item: SidebarRuntimeTargetItem) -> NSMenu {
        let context = RuntimeTargetMenuContext(workspaceID: workspace.id, item: item)
        let menu = NSMenu()
        func addItem(_ title: String, symbol: String, action: Selector?) {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            menuItem.target = action == nil ? nil : self
            menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menuItem.representedObject = context
            menu.addItem(menuItem)
        }
        if item.canRun { addItem("Start", symbol: "play", action: #selector(startRuntimeTargetMenuItem(_:))) }
        if item.canStop { addItem("Stop", symbol: "stop", action: #selector(stopRuntimeTargetMenuItem(_:))) }
        if item.canRestart { addItem("Restart", symbol: "arrow.clockwise", action: #selector(restartRuntimeTargetMenuItem(_:))) }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        addItem("Rename", symbol: "pencil", action: #selector(renameRuntimeTargetMenuItem(_:)))
        if item.kind != .browser {
            // Only session-backed targets can move into a panel window; a target that
            // hasn't started yet keeps the item visible but disabled for discoverability.
            addItem(
                "Open in New Window", symbol: "macwindow.badge.plus",
                action: item.sessionID == nil ? nil : #selector(openRuntimeTargetInNewWindowMenuItem(_:)))
        }
        return menu
    }

    @objc private func openRuntimeTargetInNewWindowMenuItem(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? RuntimeTargetMenuContext else { return }
        host.openSidebarRuntimeTargetInNewWindow(workspaceID: context.workspaceID, item: context.item)
    }

    @objc private func startRuntimeTargetMenuItem(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? RuntimeTargetMenuContext else { return }
        host.startSidebarRuntimeTarget(workspaceID: context.workspaceID, item: context.item)
    }

    @objc private func stopRuntimeTargetMenuItem(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? RuntimeTargetMenuContext else { return }
        host.stopSidebarRuntimeTarget(workspaceID: context.workspaceID, item: context.item)
    }

    @objc private func restartRuntimeTargetMenuItem(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? RuntimeTargetMenuContext else { return }
        host.restartSidebarRuntimeTarget(workspaceID: context.workspaceID, item: context.item)
    }

    @objc private func renameRuntimeTargetMenuItem(_ sender: NSMenuItem) {
        guard let context = sender.representedObject as? RuntimeTargetMenuContext else { return }
        renamingRuntimeTarget = (context.workspaceID, context.item)
        reloadRuntimeTargetRow(workspaceID: context.workspaceID, key: context.item.key)
    }

    func cancelRuntimeTargetRename() {
        guard let renaming = renamingRuntimeTarget else { return }
        renamingRuntimeTarget = nil
        renamingRuntimeTargetField = nil
        reloadRuntimeTargetRow(workspaceID: renaming.workspaceID, key: renaming.item.key)
    }

    func commitRuntimeTargetRename(newTitle: String) {
        guard let renaming = renamingRuntimeTarget else { return }
        renamingRuntimeTarget = nil
        renamingRuntimeTargetField = nil
        reloadRuntimeTargetRow(workspaceID: renaming.workspaceID, key: renaming.item.key)
        host.commitSidebarRuntimeTargetRename(workspaceID: renaming.workspaceID, item: renaming.item, newTitle: newTitle)
    }

    private func reloadRuntimeTargetRow(workspaceID: String, key: String) {
        for row in 0..<host.outlineView.numberOfRows {
            guard let ref = host.outlineView.item(atRow: row) as? OutlineItemRef, case .runtimeTarget(_, let workspace, let item) = ref.item,
                workspace.id == workspaceID, item.key == key
            else { continue }
            host.outlineView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
            return
        }
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
        case .runtimeTarget(_, let workspace, let item):
            return host.selectedWorkspaceID == workspace.id && isLastRuntimeTarget(workspaceID: workspace.id, key: item.key) ? 28 : 22
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

    func sidebarFailedIndicatorColor() -> NSColor { Theme.statusFailed }

    func sidebarIdleIndicatorColor() -> NSColor { sidebarThemeColor(light: (213, 216, 211), dark: (48, 67, 70), alpha: 0.85) }

    func sidebarThemeColor(light: (Int, Int, Int), dark: (Int, Int, Int), alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let source = isDark ? dark : light
            // sRGB, not calibrated/generic RGB: the design values are CSS (sRGB) numbers, and
            // every other surface — Theme tokens and the Ghostty terminal background — renders
            // them as sRGB. Calibrated RGB rendered the same numbers a shade lighter, which made
            // the sidebar visibly mismatch the terminal background.
            return NSColor(srgbRed: CGFloat(source.0) / 255, green: CGFloat(source.1) / 255, blue: CGFloat(source.2) / 255, alpha: alpha)
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
            updateWorkspaceExpansionForSelection(newWorkspaceID: nil)
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
        case .device, .emptyProject, .runtimeTarget: return
        case .project(let project):
            guard let workspace = visibleWorkspaces(projectID: project.id).first else { return }
            host.selectedProjectID = project.id
            host.selectedWorkspaceID = workspace.id
            AppKitController.setClientActiveWorkspaceID(workspace.id)
            host.showingSettings = false
            // A non-git project has no workspace row to expand, but a git workspace that was only
            // transiently expanded still needs to collapse now that the selection moved to this project.
            updateWorkspaceExpansionForSelection(newWorkspaceID: workspace.id)
            host.showWorkspaceDetail(project: project, workspace: workspace)
        case .workspace(let project, let workspace):
            host.selectedProjectID = project.id
            host.selectedWorkspaceID = workspace.id
            AppKitController.setClientActiveWorkspaceID(workspace.id)
            host.showingSettings = false
            updateWorkspaceExpansionForSelection(newWorkspaceID: workspace.id)
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
        // The ⌘-number shortcut chips only render on the selected workspace's target
        // rows, so the outgoing and incoming workspaces' target lists reload too.
        for workspaceID in [previousWorkspaceID, currentWorkspaceID].compactMap({ $0 }) where previousWorkspaceID != currentWorkspaceID {
            for row in 0..<host.outlineView.numberOfRows {
                guard let ref = host.outlineView.item(atRow: row) as? OutlineItemRef, case .runtimeTarget(_, let workspace, _) = ref.item,
                    workspace.id == workspaceID
                else { continue }
                rowsToReload.insert(row)
            }
        }
        guard !rowsToReload.isEmpty else { return }
        host.outlineView.noteHeightOfRows(withIndexesChanged: rowsToReload)
        host.outlineView.reloadData(forRowIndexes: rowsToReload, columnIndexes: IndexSet(integer: 0))
        host.outlineView.needsDisplay = true
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

    private func selectedWorkspaceHighlight(in outlineView: NSOutlineView) -> (frame: NSRect, fill: NSColor, border: NSColor)? {
        guard let selectedWorkspaceID = host.selectedWorkspaceID else { return nil }

        var firstRow: Int?
        var lastRow: Int?
        var leadingInset: CGFloat = 0

        for row in 0..<outlineView.numberOfRows {
            guard let ref = outlineView.item(atRow: row) as? OutlineItemRef else { continue }
            switch ref.item {
            case .workspace(let project, let workspace) where workspace.id == selectedWorkspaceID:
                firstRow = row
                lastRow = row
                leadingInset = project.isGitRepo ? Self.workspaceIndent : 0
            case .project(let project) where !project.isGitRepo:
                guard let workspace = visibleWorkspaces(projectID: project.id).first, workspace.id == selectedWorkspaceID else { continue }
                firstRow = row
                lastRow = row
                leadingInset = 0
            case .runtimeTarget(_, let workspace, _) where workspace.id == selectedWorkspaceID && firstRow != nil: lastRow = row
            default: if firstRow != nil { break }
            }
        }

        guard let firstRow, let lastRow else { return nil }
        let firstFrame = outlineView.rect(ofRow: firstRow)
        let lastFrame = outlineView.rect(ofRow: lastRow)
        let verticalFrame = NSUnionRect(firstFrame, lastFrame).insetBy(dx: 0, dy: 2)
        guard verticalFrame.height > 0 else { return nil }
        let highlightFrame = NSRect(
            x: leadingInset, y: verticalFrame.minY, width: max(0, outlineView.bounds.width - leadingInset), height: verticalFrame.height)
        return (highlightFrame, sidebarSelectedCardBackgroundColor(), sidebarCardBorderColor(isSelected: true))
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
        if isCollapsed {
            host.outlineView.collapseItem(item)
        } else {
            // Reveal the project's workspace rows but keep each workspace collapsed until
            // expanded or selected; a non-git project's children are its runtime targets directly.
            host.outlineView.expandItem(item)
            applyWorkspaceExpansionState(inProject: projectID)
        }
        // Collapsing a git project hides its selected workspace row, so the selection must clear.
        // A non-git project's own row stays visible (only its runtime targets hide), so it stays selected.
        if isCollapsed, let selectedWorkspaceID = host.selectedWorkspaceID, let (project, _) = findWorkspace(id: selectedWorkspaceID),
            project.id == projectID, project.isGitRepo
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
        // Drop expansion state for workspaces that no longer exist.
        let visibleWorkspaceIDs = Set(host.projects.flatMap { visibleWorkspaces(projectID: $0.id).map(\.id) })
        pinnedWorkspaceIDs.formIntersection(visibleWorkspaceIDs)
        if let transient = transientlyExpandedWorkspaceID, !visibleWorkspaceIDs.contains(transient) { transientlyExpandedWorkspaceID = nil }
        for project in host.projects {
            guard let row = rowIndex(forProjectID: project.id), let item = host.outlineView.item(atRow: row) else { continue }
            guard !project.isCollapsed else {
                host.outlineView.collapseItem(item)
                continue
            }
            // Reveal the project's rows but leave each workspace collapsed until expanded or
            // selected; a non-git project's children are its runtime targets, so this shows them.
            host.outlineView.expandItem(item)
            applyWorkspaceExpansionState(inProject: project.id)
        }
    }

    /// Whether a workspace's runtime-target list should be shown: pinned open by an explicit
    /// mouse interaction, or expanded transiently because it is the current arrow-key selection.
    private func isWorkspaceExpanded(_ workspaceID: String) -> Bool {
        pinnedWorkspaceIDs.contains(workspaceID) || transientlyExpandedWorkspaceID == workspaceID
    }

    /// Marks a workspace as explicitly pinned open in response to a mouse interaction (clicking
    /// its row or one of its target rows), so it stays expanded after the selection moves away.
    /// A workspace with no runtime targets has nothing to expand and is left unpinned.
    private func pinWorkspaceOpen(_ workspaceID: String) {
        guard !runtimeTargetItems(workspaceID: workspaceID).isEmpty else { return }
        pinnedWorkspaceIDs.insert(workspaceID)
        if transientlyExpandedWorkspaceID == workspaceID { transientlyExpandedWorkspaceID = nil }
    }

    /// Applies each workspace row's expanded/collapsed state for a git project. A non-git
    /// project has no workspace rows (its project row stands in for its single workspace),
    /// so there is nothing to apply.
    private func applyWorkspaceExpansionState(inProject projectID: String) {
        guard host.projects.first(where: { $0.id == projectID })?.isGitRepo == true else { return }
        for workspace in visibleWorkspaces(projectID: projectID) {
            guard let row = rowIndex(forWorkspaceID: workspace.id), let item = host.outlineView.item(atRow: row) else { continue }
            if isWorkspaceExpanded(workspace.id) { host.outlineView.expandItem(item) } else { host.outlineView.collapseItem(item) }
        }
    }

    /// Toggles a workspace's runtime-target list from its disclosure chevron. Expanding pins the
    /// workspace open so it survives losing the selection; collapsing removes both the pin and any
    /// transient expansion, so even the selected workspace stays collapsed until it is expanded again.
    func toggleWorkspaceExpanded(workspaceID: String) {
        guard let row = rowIndex(forWorkspaceID: workspaceID), let item = host.outlineView.item(atRow: row) else { return }
        if isWorkspaceExpanded(workspaceID) {
            pinnedWorkspaceIDs.remove(workspaceID)
            if transientlyExpandedWorkspaceID == workspaceID { transientlyExpandedWorkspaceID = nil }
            host.outlineView.collapseItem(item)
        } else {
            pinnedWorkspaceIDs.insert(workspaceID)
            host.outlineView.expandItem(item)
        }
        host.outlineView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    /// Reconciles workspace expansion when the selection moves. The newly selected workspace is
    /// expanded transiently unless it was already pinned open by a mouse click; the workspace that
    /// was previously expanded only transiently collapses. Pinned workspaces are untouched, so a
    /// clicked workspace stays open while arrow-key navigation only previews. Collapsing the old
    /// row first keeps the new workspace's row lookup accurate as rows shift.
    private func updateWorkspaceExpansionForSelection(newWorkspaceID: String?) {
        let previousTransient = transientlyExpandedWorkspaceID
        let newTransient: String? = {
            guard let newWorkspaceID, !pinnedWorkspaceIDs.contains(newWorkspaceID) else { return nil }
            return newWorkspaceID
        }()
        transientlyExpandedWorkspaceID = newTransient

        if let previousTransient, previousTransient != newTransient, !pinnedWorkspaceIDs.contains(previousTransient),
            let row = rowIndex(forWorkspaceID: previousTransient), let item = host.outlineView.item(atRow: row)
        {
            host.outlineView.collapseItem(item)
            host.outlineView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        }
        if let newWorkspaceID, isWorkspaceExpanded(newWorkspaceID), !runtimeTargetItems(workspaceID: newWorkspaceID).isEmpty,
            let row = rowIndex(forWorkspaceID: newWorkspaceID), let item = host.outlineView.item(atRow: row)
        {
            host.outlineView.expandItem(item)
            host.outlineView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
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
        // The automations row's running-run count and children track the same overview changes as the alerts
        // badge, so refresh them here to cover every sidebar-refresh path in one place.
        updateAutomationsSidebarRow()
    }

    func makeAutomationsSidebarRow() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.setAccessibilityIdentifier("sidebar-automations")

        let disclosure = NSButton()
        disclosure.bezelStyle = .regularSquare
        disclosure.isBordered = false
        disclosure.imagePosition = .imageOnly
        disclosure.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Expand")?.withSymbolConfiguration(
            .init(pointSize: 9, weight: .semibold))
        disclosure.contentTintColor = .tertiaryLabelColor
        disclosure.target = self
        disclosure.action = #selector(automationsDisclosureToggled)
        disclosure.setContentHuggingPriority(.required, for: .horizontal)
        disclosure.toolTip = "Show running automations"
        automationsDisclosureButton = disclosure

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Automations")?.withSymbolConfiguration(
            .init(pointSize: 11, weight: .medium))
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = NSTextField(labelWithString: "Automations")
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor

        let badge = NSTextField(labelWithString: "")
        badge.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        badge.textColor = sidebarRunningIndicatorColor()
        badge.alignment = .right
        badge.isBordered = false
        badge.isEditable = false
        badge.drawsBackground = false
        badge.isHidden = true
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        automationsRowBadge = badge

        let header = NSStackView(views: [disclosure, icon, titleLabel, NSView(), badge])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        header.wantsLayer = true
        header.layer?.cornerRadius = UIRadius.regular
        header.translatesAutoresizingMaskIntoConstraints = false
        automationsHeaderStack = header
        // The header (not the disclosure triangle) opens the detail pane; the triangle only expands. The
        // recognizer is attached to the whole header stack (not just the title/icon) so the badge, spacer,
        // padding, and row background are all clickable too. A container-level recognizer would otherwise
        // also swallow clicks meant for the disclosure button (a container recognizer gets first crack at
        // events in its subtree), so `self` is the delegate and refuses recognition when the event lands
        // inside the disclosure button's frame, letting the button's own click-through handle that toggle.
        let click = NSClickGestureRecognizer(target: host, action: #selector(AppKitController.automationsRowClicked))
        click.delegate = self
        header.addGestureRecognizer(click)

        let children = NSStackView()
        children.orientation = .vertical
        children.alignment = .leading
        children.spacing = 2
        children.translatesAutoresizingMaskIntoConstraints = false
        automationsChildrenStack = children

        container.addSubview(header)
        container.addSubview(children)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor), header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            children.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            children.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            children.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            children.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        automationsRowContainer = container

        updateAutomationsSidebarRow()
        return container
    }

    @objc private func automationsDisclosureToggled() {
        automationsExpanded.toggle()
        updateAutomationsSidebarRow()
    }

    /// Refreshes the automations row: the running-run count badge, the disclosure state, and (when expanded)
    /// the running-run children across every device. Each child opens its run's live terminal on click.
    func updateAutomationsSidebarRow() {
        guard let container = automationsRowContainer else { return }
        let runningRuns = AutomationsViewModel.runningRuns(from: host.automationDeviceInputs())

        if let badge = automationsRowBadge {
            badge.stringValue = "\(runningRuns.count)"
            badge.isHidden = runningRuns.isEmpty
        }
        automationsDisclosureButton?.isHidden = runningRuns.isEmpty
        automationsDisclosureButton?.image = NSImage(
            systemSymbolName: automationsExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: automationsExpanded ? "Collapse" : "Expand")?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))

        updateAutomationsRowAppearance()

        guard let children = automationsChildrenStack else { return }
        children.removeAllArrangedSubviews()
        guard automationsExpanded, !runningRuns.isEmpty else {
            children.isHidden = true
            return
        }
        children.isHidden = false
        let showDevice = host.deviceSections.count > 1
        for row in runningRuns {
            let child = makeAutomationRunningChildRow(row, showDevice: showDevice)
            children.addArrangedSubview(child)
            // Leading is pinned by the stack's .leading alignment; stretch to full width so the whole row is
            // a click target.
            child.trailingAnchor.constraint(equalTo: children.trailingAnchor).isActive = true
        }
    }

    private func makeAutomationRunningChildRow(_ row: AutomationRunTableRow, showDevice: Bool) -> NSView {
        let dot = RowPrimitives.statusDot(.running)
        dot.setContentHuggingPriority(.required, for: .horizontal)
        let name = row.run.automationName ?? "Automation"
        let label = NSTextField(labelWithString: showDevice ? "\(name) — \(row.deviceName)" : name)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [dot, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.toolTip = "Open live terminal"
        attachRowClickAction(to: stack) { [weak self] in self?.host.openAutomationRunTerminal(deviceID: row.deviceID, run: row.run) }
        return stack
    }

    func updateAutomationsRowAppearance() {
        guard let header = automationsHeaderStack else { return }
        let isShowing = host.showingAutomations
        header.layer?.borderWidth = isShowing ? 1 : 0
        bindAppearanceReactiveLayer(header) { [weak self] view in
            view.layer?.backgroundColor = isShowing ? self?.sidebarSelectedCardBackgroundColor().cgColor : NSColor.clear.cgColor
            view.layer?.borderColor = self?.sidebarCardBorderColor(isSelected: true).cgColor
        }
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

        // The window titlebar is hidden, so the app name lives here next to the logo.
        let appNameLabel = NSTextField(labelWithString: "Spaces")
        appNameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        appNameLabel.textColor = .labelColor
        appNameLabel.setContentHuggingPriority(.required, for: .horizontal)

        // Replaces the hidden titlebar's subtitle as the passive desktop-control
        // signal: visible only while another Spaces instance owns global shortcuts.
        let statusIcon = NSImageView()
        statusIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Desktop control unavailable")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        statusIcon.contentTintColor = .systemOrange
        statusIcon.isHidden = true
        statusIcon.setContentHuggingPriority(.required, for: .horizontal)
        desktopControlStatusIcon = statusIcon

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
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(appNameLabel)
        stack.addArrangedSubview(NSView())
        stack.addArrangedSubview(statusIcon)
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

        let bellIcon = NSImageView()
        bellIcon.image = NSImage(systemSymbolName: "bell", accessibilityDescription: "Alerts")?.withSymbolConfiguration(
            .init(pointSize: 11, weight: .medium))
        bellIcon.contentTintColor = .secondaryLabelColor
        bellIcon.setContentHuggingPriority(.required, for: .horizontal)

        let titleLabel = NSTextField(labelWithString: "Alerts")
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor

        let hintLabel = NSTextField(labelWithString: host.footerShortcutHint(for: .guiAlertsShortcut))
        hintLabel.font = .systemFont(ofSize: 10, weight: .regular)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.setContentHuggingPriority(.required, for: .horizontal)

        let badge = NSTextField(labelWithString: "")
        badge.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
        badge.textColor = sidebarFailedIndicatorColor()
        badge.alignment = .right
        badge.isBordered = false
        badge.isEditable = false
        badge.drawsBackground = false
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        alertsRowBadge = badge

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 8, bottom: 7, right: 8)
        stack.wantsLayer = true
        stack.layer?.cornerRadius = UIRadius.regular
        stack.layer?.borderWidth = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(bellIcon)
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
        let isShowingAlerts = host.showingAlerts
        stack.layer?.borderWidth = isShowingAlerts ? 1 : 0
        bindAppearanceReactiveLayer(stack) { [weak self] view in
            view.layer?.backgroundColor = isShowingAlerts ? self?.sidebarSelectedCardBackgroundColor().cgColor : NSColor.clear.cgColor
            view.layer?.borderColor = self?.sidebarCardBorderColor(isSelected: true).cgColor
        }
    }
}

extension SidebarController: NSGestureRecognizerDelegate {
    /// The automations header row's click recognizer is attached to the whole `header` stack so the badge,
    /// spacer, and padding all open the detail pane, not just the title/icon. A container-level recognizer
    /// would otherwise also capture clicks on the disclosure triangle nested inside it, which must keep
    /// toggling expand/collapse instead. Refuse recognition for events that land inside the disclosure
    /// button's frame so its own click target handles those.
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer, shouldAttemptToRecognizeWith event: NSEvent) -> Bool {
        guard let disclosure = automationsDisclosureButton, !disclosure.isHidden, let header = automationsHeaderStack else { return true }
        let locationInHeader = header.convert(event.locationInWindow, from: nil)
        let disclosureFrameInHeader = disclosure.convert(disclosure.bounds, to: header)
        return !disclosureFrameInHeader.contains(locationInHeader)
    }
}
