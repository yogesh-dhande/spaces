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
        remoteOverviewSubscriptions = RemoteOverviewSubscriptionCoordinator(requestReconcile: { [weak self] in
            self?.refreshRemoteOverviewSubscriptions()
        })
        reloadCoordinator = SidebarReloadCoordinator<SidebarDataSnapshot>(
            loadSnapshot: { await AppKitController.initialSidebarDataSnapshot() },
            applySnapshot: { [weak self] snapshot, forceRemoteRefresh, bypassesBackoff in
                self?.applySidebarDataSnapshot(
                    snapshot, preserveDetailPane: true, forceRemoteRefresh: forceRemoteRefresh, bypassesBackoff: bypassesBackoff)
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
    /// Per-remote-device timestamp of the last successful overview fetch, so polls driven by
    /// local events don't re-request every remote's overview on every cycle.
    private var remoteOverviewFetchInstants: [String: ContinuousClock.Instant] = [:]
    /// Remote devices with an overview pull in flight, so nothing starts a second connection to a
    /// device that is still answering (or still timing out).
    private var remoteOverviewPullsInFlight: Set<String> = []
    /// Pacing for pulls that fail. The in-flight guard above bounds how many connections a failing
    /// device carries at once but not how often it is dialed, and only a successful pull stamps the
    /// freshness window; this is what keeps a device that fails fast from being re-dialed by every
    /// sidebar reload and watchdog tick.
    private let remoteOverviewPullBackoff = RemoteOverviewPullBackoff()
    /// Repeating reconciliation of device reachability while subscriptions are enabled; see
    /// `runDeviceReachabilityWatchdogTick`.
    private var deviceReachabilityWatchdogTimer: Timer?
    /// Detection for the one device that cannot report its own death: this Mac's daemon. Ticked by the
    /// watchdog while the local section claims to be loaded; see `LocalDaemonReachabilityProbe`.
    private let localDaemonReachabilityProbe = LocalDaemonReachabilityProbe()
    /// State of the live device-overview subscriptions, one per paired remote device. The remote
    /// daemon pushes a fresh overview on every database change, so remote sidebar state stays
    /// current without polling (remote state has no local event). This controller performs the
    /// connects, the stops, and the sidebar painting; the coordinator decides what each connect
    /// result and disconnect means.
    private var remoteOverviewSubscriptions: RemoteOverviewSubscriptionCoordinator<SpacesDeviceAPIOverviewStreamClient>!
    private var reloadCoordinator: SidebarReloadCoordinator<SidebarDataSnapshot>!
    /// Set when a database-change signal arrives while the user is mid-edit;
    /// flushed at idle points so a deferred change is not lost.
    private var pendingDatabaseReload = false

    // Alerts sidebar row
    private var alertsRowView: NSView?
    private var alertsRowStack: NSStackView?
    private var alertsRowRail: NSView?
    private var alertsRowBadge: NSTextField?
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
                // A non-git project row stands in for its single workspace, so it stays selectable — and
                // swallows the click while that workspace is marked as deleting, exactly as a workspace
                // row does: neither selecting nor expanding a project on its way out.
                guard self.projectRowState(project).isInteractive else { return true }
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
                // A row marked as deleting swallows the click: it neither selects nor expands, so the
                // click cannot pin open a workspace that is being removed.
                guard self.workspaceRowState(workspace.id).isInteractive else { return true }
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

    /// `bypassesBackoff` defaults to `forceRemoteRefresh` (nil means "same as forceRemoteRefresh"), so an
    /// existing caller asking for `forceRemoteRefresh: true` keeps clearing backoff the way it always
    /// has. Pass `false` explicitly for a forced refresh that must not clear any device's backoff — the
    /// remote workspace-setup progress poll, which needs live data on every tick but is not a user asking
    /// for a specific device again. See `startRemoteOverviewPull`.
    func requestSidebarReload(failurePlaceholderMessage: String? = nil, forceRemoteRefresh: Bool = false, bypassesBackoff: Bool? = nil) {
        reloadCoordinator.request(
            failurePlaceholderMessage: failurePlaceholderMessage, forceRemoteRefresh: forceRemoteRefresh, bypassesBackoff: bypassesBackoff)
    }

    func applySidebarDataSnapshot(
        _ snapshot: SidebarDataSnapshot, preserveDetailPane: Bool = false, forceRemoteRefresh: Bool = false, bypassesBackoff: Bool = false
    ) {
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
        if case .offline(let reason) = localLoadState, previousLocalSection?.loadState != localLoadState {
            DeviceLinkTrace.log(deviceID: snapshot.localDeviceID, event: "section_offline", detail: "reason=\(reason)")
        }
        // A loaded local section means the daemon answered this snapshot, so tell the probe the daemon
        // is back and re-arm detection. The reload a lost-contact report triggers runs through
        // `TerminalService.ensureRunning`, which restarts a dead daemon — the probe never sees that
        // recovery as an answering ping, and without this the next death of a crash-looping daemon
        // would be swallowed as a verdict it already reported, leaving the section falsely loaded with
        // nothing left to request the reload that restarts it.
        if localLoadState == .loaded { localDaemonReachabilityProbe.noteLocalSectionLoadedFromSnapshot() }
        // An unreachable local daemon answers with the offline placeholder overview, which carries no
        // rows. Keep this Mac's last known rows and overview for the whole outage — the contract
        // `applyRemoteDeviceSection`'s failure branch keeps for a remote device — so the subtree stays
        // browsable instead of vanishing and reappearing on a daemon blip. Retaining the runtime map
        // also keeps the browser-session teardown diff below from reading the outage as every workspace
        // stopping, and `localSnapshotAuthorizesPanePrune` already refuses to prune panes against the
        // placeholder.
        let retainedContent = localLoadState.isOffline ? previousLocalSection : nil
        let localSection = DeviceSection(
            deviceID: snapshot.localDeviceID, deviceName: snapshot.localDeviceName, isLocal: true, loadState: localLoadState,
            device: snapshot.localPairedDevice, projects: retainedContent?.projects ?? snapshot.projects,
            workspacesByProject: retainedContent?.workspacesByProject ?? snapshot.workspacesByProject,
            workspaceRuntimeStatusByID: retainedContent?.workspaceRuntimeStatusByID ?? snapshot.workspaceRuntimeStatusByID,
            alertsGroups: retainedContent?.alertsGroups ?? snapshot.alertsGroups, overview: retainedContent?.overview ?? snapshot.localDeviceOverview,
            daemonStatus: snapshot.localDaemonStatus, compatibility: snapshot.localCompatibility)
        // Compare against the section actually being installed, not the raw snapshot: an outage installs
        // the retained rows, so comparing with the placeholder would reload the outline on every poll of
        // a daemon that stays down and collapse the user's expanded projects each time.
        let localOutlineUnchanged =
            previousLocalSection?.overview == localSection.overview && previousLocalSection?.compatibility == localSection.compatibility
            && previousLocalSection?.daemonStatus == localSection.daemonStatus && previousLocalSection?.loadState == localSection.loadState
        if let localIndex = host.deviceSections.firstIndex(where: { $0.deviceID == snapshot.localDeviceID }) {
            // Whole-struct assignment bypasses `overview`'s `didSet`, so the install generation is carried
            // over explicitly — otherwise it would reset to zero here on every local refresh and a deferred
            // workspace delete would never observe fresh evidence for the local device. `retainedContent`
            // is exactly the offline case where this re-renders the cached overview without the daemon
            // having answered; every other rebuild is carrying a freshly read one, identical payload or not.
            host.deviceSections[localIndex] = localSection.adoptingOverviewInstallGeneration(
                from: previousLocalSection, carriesFreshInstall: retainedContent == nil)
        } else {
            host.deviceSections.insert(localSection, at: 0)
        }
        host.maybeRequestSilentDaemonHandoff(deviceID: snapshot.localDeviceID, status: snapshot.localDaemonStatus)
        host.localDeviceID = snapshot.localDeviceID
        host.localDeviceName = snapshot.localDeviceName
        host.localPairedDevice = snapshot.localPairedDevice
        // If the local block was showing, reconcile it against the fresh verdict/status: drop it if the
        // daemon is now compatible, re-render it if the remedy changed (e.g. a staged update appeared),
        // otherwise leave it (canPreserveDetailPaneAfterSidebarReload was evaluated against the stale
        // pre-reload verdict).
        host.reconcileCompatibilityBlock(deviceID: snapshot.localDeviceID)
        // Authoritative local overview: close any open local pane whose session the local daemon no
        // longer retains (its product row was removed by the CLI or another paired client), so the pane
        // cannot outlive the local daemon's transcript garbage-collection. The keep-set is the daemon's
        // own published retention rule (`overview.retainedTerminalSessionIDs`), so an ended session held
        // by any product row — including a `runtime_targets` row after its shell exits — stays open for
        // scrollback. Prune only when the local overview is authoritative — reachable (loaded, not
        // offline) and wire-compatible. An offline or wire-incompatible local daemon carries an empty
        // placeholder overview (mirroring the remote path's `load.overview == nil` branch), and absence
        // of a real overview is never evidence a session's product row was removed.
        if AppKitController.localSnapshotAuthorizesPanePrune(loadState: localLoadState, compatibility: snapshot.localCompatibility) {
            host.panelCoordinator.pruneOpenPanes(
                deviceID: snapshot.localDeviceID,
                catalogSessionIDs: OpenPanePruning.referencedTerminalSessionIDs(overview: snapshot.localDeviceOverview))
        }
        // Diff against the runtime map actually installed, not the raw snapshot. An unreachable local
        // daemon answers with the offline placeholder, whose empty map reads as every running workspace
        // having stopped — which would close the user's browser tabs for all of them on a daemon blip.
        // The installed map is the retained one during an outage, so nothing appears to transition.
        tearDownBrowserSessionsForLocallyStoppedWorkspaces(
            previous: previousLocalSection?.workspaceRuntimeStatusByID, current: localSection.workspaceRuntimeStatusByID,
            previousOverview: previousLocalSection?.overview)
        // Load the stored dismissals BEFORE installing the groups: installing them consumes the focused
        // session's bell into that same set and writes it back, so a consume that ran against a not-yet
        // loaded (empty) set would persist itself over everything the user had dismissed.
        host.loadAlertsDismissedAttentionItemIDs()
        rebuildFlatSidebarData()
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
        } else if let previousLoadState = previousLocalSection?.loadState,
            AppKitController.shouldRebuildWorkspaceDetailForDeviceLoadStateChange(
                visibleDetailWorkspaceDeviceID: host.visibleWorkspaceDetailDeviceID(), deviceID: snapshot.localDeviceID,
                previousLoadState: previousLoadState, newLoadState: localLoadState)
        {
            // This Mac's daemon crossed into or out of being actionable while its workspace detail was
            // retained, so that pane's daemon-backed controls no longer match what the device can do.
            // `shouldRefreshVisibleWorkspaceDetail` above only covers a focused main window; a daemon
            // that drops or returns while the user is in another app must still reconcile the controls
            // they come back to. Gated on the transition, so the poll of a daemon that stays down —
            // which repeats every refresh interval — rebuilds nothing.
            host.refreshSelection()
        }
        updateAlertsSidebarBadge()
        host.logStartupProfile("apply_snapshot_alerts_badge_ready", details: "group_count=\(host.alertsGroups.count)")
        if host.showingAlerts { host.showAlertsDetail() }
        host.reopenPersistedPanelWindowsIfPossible()
        loadRemoteDeviceSections(forceRefresh: forceRemoteRefresh, bypassesBackoff: bypassesBackoff)
    }

    /// Closes browser-session tabs for local-device workspaces that the daemon now reports as no
    /// longer running, comparing the previous local-section runtime state against the just-fetched
    /// snapshot. This reload is the only channel through which the GUI learns about stop/delete
    /// actions taken outside it (the CLI, MCP, the Device API, or another device), so without this
    /// diff those externally-stopped workspaces would leave their tracked Chrome tabs and the
    /// client `browser_session_window_ids` rows alive. The GUI's own stop/restart/delete handlers
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
    /// reported stopped or absent entirely (deleted out of the runtime map). Pure so the
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

    /// `forceRefresh` and `bypassesBackoff` are independent: see `startRemoteOverviewPull` for what each
    /// controls. `SidebarReloadCoordinator.request` is the single place that decides one from the other
    /// for callers that do not say.
    func loadRemoteDeviceSections(forceRefresh: Bool = false, bypassesBackoff: Bool = false) {
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
        var rebuildWorkspaceDetail = false
        for record in remotes {
            guard AppKitController.pairedDeviceHasRequiredCredentials(device: record) else {
                if let index = host.deviceSections.firstIndex(where: { $0.deviceID == record.id }) {
                    let previousLoadState = host.deviceSections[index].loadState
                    let newLoadState = SidebarDeviceLoadState.offline("Reconnect required")
                    // This is a load-state transition like any other, so it owes the same detail-pane
                    // reconciliation `applyRemoteDeviceSection` does: a retained selected workspace under
                    // this device keeps footer/setup controls that were built enabled, and every action on
                    // them is refused from here on. Both this and the outline reload are gated on an actual
                    // change, because a device that stays credential-less is re-derived on every sidebar
                    // load and rebuilding then would repeatedly throw away scroll position and focus.
                    if previousLoadState != newLoadState {
                        updatedReconnectSection = true
                        rebuildWorkspaceDetail =
                            rebuildWorkspaceDetail
                            || AppKitController.shouldRebuildWorkspaceDetailForDeviceLoadStateChange(
                                visibleDetailWorkspaceDeviceID: host.visibleWorkspaceDetailDeviceID(), deviceID: record.id,
                                previousLoadState: previousLoadState, newLoadState: newLoadState)
                        host.deviceSections[index].loadState = newLoadState
                    }
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
            // `bypassesBackoff` is independent of `forceRefresh`: a forced reload bypasses the freshness
            // gate for every device regardless of who asked (there is no per-device freshness cost to
            // that), but only a caller that actually asked for this device — the Reload command, or a
            // mutation whose response the user is waiting on — also clears its failure backoff. An
            // ambient poll that forces freshness without asking for any specific device (the remote
            // workspace-setup progress timer) passes `bypassesBackoff: false` and leaves every device's
            // backoff alone.
            startRemoteOverviewPull(record: record, clientApp: clientApp, bypassesBackoff: bypassesBackoff)
        }
        if updatedReconnectSection {
            rebuildFlatSidebarData()
            host.outlineView.reloadData()
            applySidebarProjectExpansionState()
            updateAlertsSidebarBadge()
            if rebuildWorkspaceDetail { host.refreshSelection() }
        }
        refreshRemoteOverviewSubscriptions()
    }

    /// Starts one overview pull for `record` and applies its result to that device's sidebar section.
    /// The single pull implementation, shared by the freshness-gated path above and the watchdog's
    /// forced refresh of a device that is currently offline.
    ///
    /// `bypassesBackoff` clears the device's failure backoff, distinct from bypassing the freshness
    /// window (the caller's `forceRefresh`): freshness only paces how often a healthy device is
    /// re-fetched, while the backoff paces how often a *failing* device is redialed at all, and clearing
    /// it is only correct for an explicitly requested pull — the per-device Retry, the Reload command, or
    /// a mutation whose fresh remote data the user is waiting on. Asking for a device outright is a
    /// stronger signal than the schedule its run of failures grew, so those paths clear the backoff
    /// instead of waiting it out. An ambient poll that forces freshness without the user asking for any
    /// specific device — the remote workspace-setup progress timer, which needs live data on every tick
    /// for the whole duration of a remote setup — must bypass freshness only: clearing the backoff there
    /// would redial every unrelated offline device on the same fast cadence, defeating the backoff's
    /// whole point.
    private func startRemoteOverviewPull(record: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp, bypassesBackoff: Bool) {
        if bypassesBackoff {
            remoteOverviewPullBackoff.clear(deviceID: record.id)
        } else if !remoteOverviewPullBackoff.allowsAttempt(deviceID: record.id) {
            return
        }
        // Only a successful pull stamps the freshness window, so a device that keeps failing carries no
        // stamp to throttle it; the backoff above is what paces its attempts. This guard is what keeps a
        // burst of sidebar reloads — or a watchdog tick landing while a previous connect is still timing
        // out — from stacking connections on it.
        guard remoteOverviewPullsInFlight.insert(record.id).inserted else { return }
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
            guard let self else { return }
            self.remoteOverviewPullsInFlight.remove(record.id)
            // Stamp only a fetch that produced data. A failed pull left nothing fresh to protect, so
            // letting it hold the window would suppress the next 30 s of attempts and keep the device
            // parked in offline for no reason; it arms the backoff instead, which paces the retries
            // without freezing the device's state for a fixed window.
            switch result {
            case .success: self.remoteOverviewFetchInstants[record.id] = ContinuousClock.now
            case .failure:
                let delay = self.remoteOverviewPullBackoff.recordFailure(deviceID: record.id)
                DeviceLinkTrace.log(deviceID: record.id, event: "pull_backoff_armed", detail: "delay_ms=\(Self.milliseconds(delay))")
            }
            self.applyRemoteDeviceSection(deviceID: record.id, result: result)
        }
    }

    /// Enables and opens live overview subscriptions for paired remote devices, and arms the
    /// reachability watchdog. Called when background services start; the pull above still gives
    /// immediate population, while the subscription delivers subsequent changes by push.
    func startRemoteOverviewSubscriptions() {
        remoteOverviewSubscriptions.enable()
        refreshRemoteOverviewSubscriptions()
        startDeviceReachabilityWatchdog()
    }

    func stopRemoteOverviewSubscriptions() {
        deviceReachabilityWatchdogTimer?.invalidate()
        deviceReachabilityWatchdogTimer = nil
        for client in remoteOverviewSubscriptions.disable() { client.stop() }
    }

    private func startDeviceReachabilityWatchdog() {
        deviceReachabilityWatchdogTimer?.invalidate()
        let timer = Timer(timeInterval: PollingConstants.deviceReachabilityWatchdogInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runDeviceReachabilityWatchdogTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        deviceReachabilityWatchdogTimer = timer
    }

    /// One reconciliation pass over device reachability. Everything that brings a device back —
    /// a disconnect callback firing, an overview arriving on a stream, the local snapshot succeeding —
    /// is a single event that can simply not happen: a stream can be reconnected yet never deliver
    /// (the remote daemon could not build an overview when it accepted the subscription, and pushes
    /// only on its next database change), and an offline local daemon has nothing that re-probes it.
    /// Re-running the invariant on a timer makes recovery something the sidebar converges to rather
    /// than something one event has to deliver.
    private func runDeviceReachabilityWatchdogTick() {
        refreshRemoteOverviewSubscriptions()
        let clientApp = SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)
        for record in host.macPairedDevices() where AppKitController.pairedDeviceHasRequiredCredentials(device: record) {
            // Any section that is not loaded is re-probed: offline, and equally a section left at
            // "loading…" by an attempt whose result never arrived. Deliberately bypasses the freshness
            // gate — such a section holds no data worth protecting, and a section only returns to loaded
            // when an overview arrives, so this pull is the only way back for a device whose stream is
            // healthy but silent.
            guard let section = host.deviceSections.first(where: { $0.deviceID == record.id }), section.loadState != .loaded else { continue }
            DeviceLinkTrace.log(deviceID: record.id, event: "watchdog_pull")
            startRemoteOverviewPull(record: record, clientApp: clientApp, bypassesBackoff: false)
        }
        // The local device has no stream to drop and no retry of its own. A local section already known
        // to be offline re-runs the snapshot that bootstraps and reads the local daemon — the same path
        // the Reload command uses. One that still claims to be loaded has to be checked against the
        // daemon before there is anything to recover from.
        guard let localSection = host.deviceSections.first(where: { $0.isLocal }) else { return }
        guard localSection.loadState == .loaded else {
            DeviceLinkTrace.log(deviceID: localSection.deviceID, event: "watchdog_local_reload")
            requestSidebarReload()
            return
        }
        probeLocalDaemonReachability(deviceID: localSection.deviceID)
    }

    /// Checks that a local section claiming to be loaded is still backed by a live daemon, and reloads
    /// when it is not.
    ///
    /// Nothing else can contradict that claim: the section only becomes `.offline` through a snapshot,
    /// snapshots run on `IPCNotification.databaseDidChange`, and a dead daemon commits nothing — so
    /// without this the section stays `.loaded` forever and the recovery branch above, gated on the
    /// section *not* being loaded, never runs. Reloading unconditionally instead would rebuild the whole
    /// sidebar every tick on a perfectly healthy Mac, so the tick pays a liveness ping (see
    /// `LocalDaemonReachabilityProbe`) and asks for the reload only when the ping contradicts the
    /// section. The probe is skipped entirely once the section is offline, where the branch above is
    /// already reloading on every tick.
    private func probeLocalDaemonReachability(deviceID: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch await self.localDaemonReachabilityProbe.run() {
            case .noChange: break
            case .lostContact(let error):
                DeviceLinkTrace.log(deviceID: deviceID, event: "local_probe_unreachable", detail: "error=\(String(describing: error))")
                self.requestSidebarReload()
            case .regainedContact: DeviceLinkTrace.log(deviceID: deviceID, event: "local_probe_reachable")
            }
        }
    }

    /// The remote devices that should hold a live overview subscription, out of the credentialed paired
    /// remotes.
    ///
    /// A device the sidebar knows is wire-incompatible is parked: its daemon speaks a different protocol,
    /// so the overview it pushes cannot decode and the stream dies as soon as it delivers one. Reopening
    /// it on the retry backoff buys nothing but another disconnect every few seconds. Its pull is what
    /// describes such a device — the pull falls back to the frozen-core handshake and reads the verdict
    /// from there — and a pull reporting a compatible daemon puts the device back in this set, so the
    /// next reconcile reopens its subscription with no separate recovery path.
    ///
    /// Only a verdict parks a device. One with no section yet, and one that is merely offline (the
    /// offline transition drops the verdict), both stay wanted: the subscription is how they recover.
    /// Pure so the rule is directly testable.
    nonisolated static func overviewSubscriptionDesiredIDs(credentialedRemoteIDs: [String], sections: [DeviceSection]) -> Set<String> {
        let incompatibleIDs = Set(sections.filter { $0.compatibility?.isCompatible == false }.map(\.deviceID))
        return Set(credentialedRemoteIDs).subtracting(incompatibleIDs)
    }

    /// Reconciles open subscriptions to the set of credentialed paired remotes:
    /// drops gone devices and opens one per newly present device.
    func refreshRemoteOverviewSubscriptions() {
        guard remoteOverviewSubscriptions.isEnabled else { return }
        let remotes = host.macPairedDevices().filter { AppKitController.pairedDeviceHasRequiredCredentials(device: $0) }
        let desiredIDs = Self.overviewSubscriptionDesiredIDs(credentialedRemoteIDs: remotes.map(\.id), sections: host.deviceSections)
        let outcome = remoteOverviewSubscriptions.reconcile(desiredIDs: desiredIDs)
        for removal in outcome.removed {
            removal.client.stop()
            host.stopRemoteBrowserForwards(deviceID: removal.deviceID)
        }
        guard !outcome.devicesToOpen.isEmpty else { return }
        let clientApp = SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)
        for record in remotes {
            guard let attempt = outcome.devicesToOpen[record.id] else { continue }
            openRemoteOverviewSubscription(record: record, attempt: attempt, clientApp: clientApp)
        }
    }

    /// Opens one subscription attempt. `attempt` is the coordinator's id for it and rides in both stream
    /// callbacks, so a stopped stream's disconnect is never mistaken for the state of the attempt that
    /// replaced it (a user retry stops the old client and connects again in the same turn).
    private func openRemoteOverviewSubscription(record: SpacesPairedDeviceRecord, attempt: Int, clientApp: SpacesDeviceClientApp) {
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
            Task { @MainActor in self?.handleRemoteOverviewDisconnected(deviceID: deviceID, attempt: attempt, error: error) }
        }
        DeviceLinkTrace.log(deviceID: deviceID, event: "subscribe_attempt")
        Task { @MainActor [weak self] in
            // Resolving credentials and connecting block, so do it off the main actor.
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<SpacesDeviceAPIOverviewStreamClient, Error> in
                do {
                    return .success(
                        try SpacesDeviceClient.subscribeOverview(
                            device: record, clientApp: clientApp, onOverview: onOverview, onDisconnect: onDisconnect))
                } catch { return .failure(error) }
            }.value
            let client: SpacesDeviceAPIOverviewStreamClient?
            switch outcome {
            case .success(let connected): client = connected
            case .failure(let error):
                client = nil
                DeviceLinkTrace.log(deviceID: deviceID, event: "subscribe_failed", detail: "error=\(String(describing: error))")
            }
            guard let self else {
                client?.stop()
                return
            }
            // The connect can fail (remote offline at launch or still unreachable on a retry) and the
            // stream it opens can drop before this result lands; the coordinator arms the delayed retry
            // for both, so the remote section recovers on its own rather than staying stale until an
            // unrelated sidebar reload.
            switch self.remoteOverviewSubscriptions.applyConnectResult(deviceID: deviceID, attempt: attempt, client: client) {
            case .keep: DeviceLinkTrace.log(deviceID: deviceID, event: "subscribe_connected")
            case .discard: client?.stop()
            case .discardDisconnected(let error):
                client?.stop()
                self.markRemoteOverviewSectionOffline(deviceID: deviceID, error: error)
            }
            self.traceArmedRetry(deviceID: deviceID)
        }
    }

    private func handleRemoteOverviewDisconnected(deviceID: String, attempt: Int, error: (any Error)?) {
        switch remoteOverviewSubscriptions.applyDisconnect(deviceID: deviceID, attempt: attempt, error: error) {
        case .ignore: break
        case .recordedWhileOpening:
            // The wedge race: the stream dropped before the connect that opened it handed its client
            // back. Traced because the connect result that lands afterwards is discarded silently, so
            // without this the device's failure leaves no evidence of which path it took.
            DeviceLinkTrace.log(deviceID: deviceID, event: "disconnect_during_connect", detail: "error=\(String(describing: error))")
        case .markOffline(let client):
            DeviceLinkTrace.log(deviceID: deviceID, event: "stream_disconnected", detail: "error=\(String(describing: error))")
            client.stop()
            markRemoteOverviewSectionOffline(deviceID: deviceID, error: error)
            traceArmedRetry(deviceID: deviceID)
        }
    }

    /// Traces the retry the coordinator armed for this device, if it armed one. The backoff decides when
    /// an unreachable device is next attempted and is otherwise entirely invisible.
    private func traceArmedRetry(deviceID: String) {
        guard let delay = remoteOverviewSubscriptions.armedRetryDelay(deviceID: deviceID) else { return }
        DeviceLinkTrace.log(deviceID: deviceID, event: "retry_armed", detail: "delay_ms=\(Self.milliseconds(delay))")
    }

    private static func milliseconds(_ delay: Duration) -> Int64 {
        delay.components.seconds * 1000 + delay.components.attoseconds / 1_000_000_000_000_000
    }

    /// Whether a dropped overview stream is evidence that the device it belonged to went away.
    ///
    /// A stream to a wire-incompatible daemon dies by design — the overview it pushes cannot decode —
    /// so its disconnect only restates the protocol gap the pull already reported. Letting it run the
    /// offline transition would wipe that verdict, and the two paths then alternate: the header flips
    /// between "Resolve" and "Reconnect" and the compatibility block is pulled out of the detail pane
    /// every time the verdict goes away. The pull, not the disconnect, describes such a device, and a
    /// pull that fails is never filtered here, so a genuine outage still reports one.
    /// Pure so the rule is directly testable.
    nonisolated static func streamDisconnectReportsAnOutage(compatibility: SpacesWireCompatibility?) -> Bool { compatibility?.isCompatible != false }

    /// A stream that dropped means the remote daemon or network went away. With no periodic remote
    /// refresh to fall back on, transition the section to offline now — the same way a failed pull
    /// does — so the sidebar shows the offline caption instead of stale projects/alerts. A graceful
    /// stream close carries no error, so fall back to a descriptive reason for the offline tooltip.
    ///
    /// The single chokepoint for both disconnect paths: a live stream dropping, and a stream that died
    /// before the connect that opened it handed its client back.
    private func markRemoteOverviewSectionOffline(deviceID: String, error: (any Error)?) {
        guard Self.streamDisconnectReportsAnOutage(compatibility: host.deviceCompatibility(forDeviceID: deviceID)) else {
            DeviceLinkTrace.log(deviceID: deviceID, event: "stream_disconnect_ignored_incompatible")
            return
        }
        applyRemoteDeviceSection(deviceID: deviceID, result: .failure(error ?? RemoteOverviewDisconnectError.streamClosed))
    }

    /// What a failed load must do to a device section that is already painted.
    enum OfflineSectionUpdate: Equatable {
        /// The device was not offline yet: run the full offline transition — take the reason, drop the
        /// compatibility verdict it was last reachable with, and rebuild the outline so its rows repaint
        /// as unreachable.
        case transition
        /// Already offline for a different reason: take the newer reason and rebuild that device's row
        /// alone, which is where the offline caption's tooltip comes from.
        case repaintReason
        /// Already offline for the same reason — every watchdog probe of a device that stays down. There
        /// is nothing new to tell the user, so nothing is touched.
        case unchanged
    }

    /// Pure so the "an offline device's reason stays current, but an unchanged failure never rebuilds
    /// the outline" rule is directly testable.
    nonisolated static func offlineSectionUpdate(loadState: SidebarDeviceLoadState, reason: String) -> OfflineSectionUpdate {
        guard case .offline(let currentReason) = loadState else { return .transition }
        return currentReason == reason ? .unchanged : .repaintReason
    }

    func applyRemoteDeviceSection(deviceID: String, result: Result<RemoteDeviceLoad, Error>) {
        guard let index = host.deviceSections.firstIndex(where: { $0.deviceID == deviceID }) else { return }
        // A background refresh re-fetches each remote; only touch the outline when
        // the device's overview or load state actually changed, so unchanged polls
        // don't collapse expanded projects.
        let previousLoadState = host.deviceSections[index].loadState
        let wasLoaded = previousLoadState == .loaded
        switch result {
        case .success(let load):
            // Any overview that arrives — pulled, or pushed on the subscription — is evidence this
            // device answers, so it releases the hold a run of failed pulls put it under. Without this a
            // device that came back on its stream would still have its pulls suppressed until the last
            // hold elapsed.
            remoteOverviewPullBackoff.clear(deviceID: deviceID)
            // Compatibility/status can change while the overview stays identical (e.g. after a restart
            // updates a remote daemon), so the unchanged-check must include them or the badge/block
            // would keep showing the stale verdict until an unrelated overview change.
            let statusUnchanged =
                host.deviceSections[index].compatibility == load.compatibility && host.deviceSections[index].daemonStatus == load.daemonStatus
            host.deviceSections[index].daemonStatus = load.daemonStatus
            host.deviceSections[index].compatibility = load.compatibility
            host.maybeRequestSilentDaemonHandoff(deviceID: deviceID, status: load.daemonStatus)
            // If this device's block was showing, reconcile it against the fresh verdict/status — drop it
            // if now compatible, re-render it if the remedy changed (e.g. a staged update appeared while
            // still incompatible), otherwise leave it.
            host.reconcileCompatibilityBlock(deviceID: deviceID)
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
            host.deviceSections[index].alertsGroups = AppKitController.buildOverviewAlertsGroups(from: overview.overview, deviceID: deviceID)
            host.deviceSections[index].overview = overview.overview
            host.deviceSections[index].device = overview.device
            host.deviceSections[index].loadState = .loaded
            host.reconcileRemoteBrowserForwards(device: overview.device, overview: overview.overview)
            // Authoritative overview for this remote device: close any open pane whose session it no
            // longer retains so the pane cannot outlive the remote daemon's transcript garbage-collection.
            // The keep-set is the remote daemon's own published retention rule
            // (`overview.retainedTerminalSessionIDs`), so an ended session held by any product row —
            // including a `runtime_targets` row after its shell exits — stays open for scrollback.
            // Only this success-with-overview branch prunes — the reachable-but-incompatible branch above
            // and the offline `.failure` branch below carry no overview, and absence of an overview is never
            // evidence a session's product row was removed.
            host.panelCoordinator.pruneOpenPanes(
                deviceID: deviceID, catalogSessionIDs: OpenPanePruning.referencedTerminalSessionIDs(overview: overview.overview))
        case .failure(let error):
            let reason = error.localizedDescription
            let update = Self.offlineSectionUpdate(loadState: host.deviceSections[index].loadState, reason: reason)
            // Trace the transition and any later change of reason. An unchanged repeat — every watchdog
            // probe of a device that stays down — says nothing new and would grow without bound.
            if update != .unchanged { DeviceLinkTrace.log(deviceID: deviceID, event: "section_offline", detail: "reason=\(reason)") }
            switch update {
            case .unchanged: return
            case .repaintReason:
                // Already offline, with a newer reason: freezing the reason at the first failure leaves
                // the user reading a stale explanation (e.g. the original stream-closed message) for the
                // whole outage. The caption's tooltip is copied out of the load state when the row's cell
                // is built, so the new reason only reaches the user by rebuilding that row — and only
                // that row, because the outline's contents are unchanged.
                host.deviceSections[index].loadState = .offline(reason)
                host.outlineView.reloadItem(outlineItemRef(for: .device(deviceID)))
                return
            case .transition: break
            }
            // The device keeps its rows, its alerts, and its overview for the whole outage: they stay in
            // the merged sidebar data (dimmed, and the section caption reads "offline"), so the user can
            // keep browsing what the device last reported and the selection under it stays valid. The
            // overview is what makes that browsable — every detail surface reads the workspace out of it
            // (`deviceWorkspaceSummary`), and a row whose overview is missing shows a loading placeholder
            // and asks for a sidebar reload, which against a dead device is a reload loop. It is also
            // what keeps an open pane's session resolving to its workspace while the device is away.
            // Drop the prior verdict so an offline device shows "offline" rather than a stale Resolve
            // button / restart block from when it was last reachable-but-incompatible. Only a failed
            // pull reaches this for an incompatible device — its stream's disconnects are filtered out
            // by `streamDisconnectReportsAnOutage` — so the verdict is dropped on evidence the device
            // stopped answering at all, never on the stream dying the way an old daemon's always does.
            host.deviceSections[index].compatibility = nil
            host.deviceSections[index].daemonStatus = nil
            host.deviceSections[index].loadState = .offline(reason)
            host.reconcileCompatibilityBlock(deviceID: deviceID)
            host.stopRemoteBrowserForwards(deviceID: deviceID)
        }
        rebuildFlatSidebarData()
        host.outlineView.reloadData()
        applySidebarProjectExpansionState()
        updateAlertsSidebarBadge()
        host.reopenPersistedPanelWindowsIfPossible()
        // The Alerts pane's cards and `alertsFocusRequestMap` were built from the pre-rebuild groups, so
        // when it is visible it must be rebuilt to pick up this device's new state — its alerts stay
        // listed, marked stale. The selection itself is deliberately left alone: an unreachable device's
        // rows stay in the merged data, so a selection under it is still valid and its detail pane still
        // renders from the retained overview. Only the pane's controls have to be rebuilt, and only when
        // this device crossed into or out of being actionable — every earlier branch of the switch
        // returned for a report that changed nothing.
        if host.showingAlerts {
            host.showAlertsDetail()
        } else if AppKitController.shouldRebuildWorkspaceDetailForDeviceLoadStateChange(
            visibleDetailWorkspaceDeviceID: host.visibleWorkspaceDetailDeviceID(), deviceID: deviceID, previousLoadState: previousLoadState,
            newLoadState: host.deviceSections[index].loadState)
        {
            host.refreshSelection()
        }
    }

    /// Recomputes the flat, id-keyed sidebar dictionaries as the union of every device section,
    /// including the ones that are not loaded: an unreachable device keeps its rows listed for the whole
    /// outage, and id-based lookups resolve through this merged data, so excluding it would both erase
    /// its subtree and make every workspace under it unresolvable.
    ///
    /// Every path that installs a device overview funnels through here — the local snapshot, the remote
    /// pull/subscription, and a mutation response — so this is also where surfaces that read those
    /// overviews but are re-derived by nothing else get refreshed. Global panel windows are the one such
    /// surface: a rename reaches this client only in an overview, and no overview update re-renders a
    /// global panel window (see `PanelCoordinator.refreshGlobalPanelTitles`).
    func rebuildFlatSidebarData() {
        let merged = AppKitController.mergedSidebarData(sections: host.deviceSections)
        host.projects = merged.projects
        host.workspacesByProject = merged.workspacesByProject
        host.workspaceRuntimeStatusByID = merged.workspaceRuntimeStatusByID
        host.alertsGroups = merged.alertsGroups
        // Every path that installs alerts groups lands here, so this is where a bell in the pane the user
        // is typing in gets consumed — before anything reads the groups for the badge or the list.
        host.consumeFocusedSessionBellAlerts()
        host.panelCoordinator.refreshGlobalPanelTitles()
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

    private func isVisibleWorkspace(_ workspace: WorkspaceSummary) -> Bool { !workspace.isHidden }

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
    /// is paired, or when any section is not loaded so its caption — the only surface for an unreachable
    /// daemon's reason and its recovery button — still has a header row to render in (a single offline local
    /// device otherwise has no project rows and would show nothing, and a lone device retrying would
    /// lose the header the button it was clicked in lives on). A single loaded device stays a flat list.
    var showsDeviceHeaders: Bool {
        AppKitController.sidebarShowsDeviceHeaders(
            deviceCount: host.deviceSections.count, hasUnloadedSection: host.deviceSections.contains { $0.loadState != .loaded })
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
        case .alerts: host.showAlertsDetail(presentation: .userNavigation)
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

    /// How a workspace's sidebar row renders and responds: normal, or marked while its delete runs.
    /// Every surface that treats a deleting row differently — the row cell, its children, selection, the
    /// context menu, the row click — reads this one state.
    private func workspaceRowState(_ workspaceID: String) -> AppKitController.SidebarWorkspaceRowState {
        AppKitController.sidebarWorkspaceRowState(isPendingDeletion: host.isWorkspaceMarkedDeleting(workspaceID))
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

    /// How a project's sidebar row renders and responds. A non-git project row is its single workspace's
    /// row, so it reads that workspace's state and is marked while its delete runs — a project delete
    /// reported by another client marks the row here just as a workspace delete marks a `.workspace` row.
    private func projectRowState(_ project: ProjectSummary) -> AppKitController.SidebarWorkspaceRowState {
        AppKitController.sidebarProjectRowState(
            standInWorkspaceIsPendingDeletion: nonGitProjectTargetWorkspace(project).map { host.isWorkspaceMarkedDeleting($0.id) })
    }

    /// The runtime targets listed under a non-git project's stand-in row. A row marked as deleting lists
    /// none, matching `workspaceRuntimeTargetChildren`, so the subtree of a workspace on its way out is
    /// hidden whatever the user's expansion state.
    private func nonGitProjectRuntimeTargetChildren(_ project: ProjectSummary) -> [SidebarRuntimeTargetItem] {
        guard let workspace = nonGitProjectTargetWorkspace(project), projectRowState(project).listsRuntimeTargetChildren else { return [] }
        return runtimeTargetItems(workspaceID: workspace.id)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return showsDeviceHeaders ? host.deviceSections.count : deviceProjects(deviceID: singleDeviceID).count }
        if case .device(let deviceID) = (item as? OutlineItemRef)?.item { return deviceProjects(deviceID: deviceID).count }
        if case .project(let project) = (item as? OutlineItemRef)?.item {
            // Non-git projects own exactly one workspace (the project directory) and render
            // as a single flat row; their children are that workspace's runtime targets.
            guard project.isGitRepo else { return nonGitProjectRuntimeTargetChildren(project).count }
            return max(visibleWorkspaces(projectID: project.id).count, 1)
        }
        if case .workspace(_, let workspace) = (item as? OutlineItemRef)?.item { return workspaceRuntimeTargetChildren(workspace).count }
        return 0
    }

    /// The runtime targets listed as a workspace row's children. A row marked as deleting lists none, so
    /// its children are hidden whatever the user's expansion state.
    private func workspaceRuntimeTargetChildren(_ workspace: WorkspaceSummary) -> [SidebarRuntimeTargetItem] {
        guard workspaceRowState(workspace.id).listsRuntimeTargetChildren else { return [] }
        return runtimeTargetItems(workspaceID: workspace.id)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if case .device = (item as? OutlineItemRef)?.item { return true }
        if case .project(let project) = (item as? OutlineItemRef)?.item {
            guard project.isGitRepo else { return !nonGitProjectRuntimeTargetChildren(project).isEmpty }
            return true
        }
        if case .workspace(_, let workspace) = (item as? OutlineItemRef)?.item { return !workspaceRuntimeTargetChildren(workspace).isEmpty }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { true }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        switch (item as? OutlineItemRef)?.item {
        case .device, .emptyProject, .runtimeTarget: return false
        // A row marked as deleting is inert: it refuses selection here, which also covers arrow-key
        // navigation and window cycling, since both select through the outline view. A non-git project's
        // row is its workspace's row, so it refuses selection on the same terms.
        case .workspace(_, let workspace): return workspaceRowState(workspace.id).isInteractive
        case .project(let project) where !project.isGitRepo: return projectRowState(project).isInteractive
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
                let items = nonGitProjectRuntimeTargetChildren(project)
                if index >= 0 && index < items.count { return outlineItemRef(for: .runtimeTarget(project, workspace, items[index])) }
            }
            let visible = visibleWorkspaces(projectID: project.id)
            guard !visible.isEmpty else { return outlineItemRef(for: .emptyProject(project)) }
            let workspace =
                (index >= 0 && index < visible.count ? visible[index] : nil)
                ?? WorkspaceSummary(id: "", branch: nil, baseBranch: nil, dir: "", isRunning: false, isHidden: false, isDefault: false)
            return outlineItemRef(for: .workspace(project, workspace))
        }
        if case .workspace(let project, let workspace) = (item as? OutlineItemRef)?.item {
            let items = workspaceRuntimeTargetChildren(workspace)
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
        // The device row is never dimmed: it carries the section's state, the failure reason, and the
        // action that recovers the device, which are the surfaces the outage is read and acted on through.
        case .device(let deviceID): return sidebarSectionRowCell(deviceID: deviceID)
        case .project(let project):
            // A non-git project row stands in for its single workspace, so it reads as
            // selected whenever that workspace is the active selection.
            let isSelected =
                project.isGitRepo
                ? host.selectedProjectID == project.id && host.selectedWorkspaceID == nil
                : host.selectedProjectID == project.id && host.selectedWorkspaceID != nil
            return dimmedForUnreachableDevice(projectRowCell(project: project, isSelected: isSelected), deviceID: project.deviceID)
        case .workspace(let project, let workspace):
            return dimmedForUnreachableDevice(
                workspaceRowCell(project: project, workspace: workspace, isSelected: host.selectedWorkspaceID == workspace.id),
                deviceID: project.deviceID)
        case .emptyProject(let project): return dimmedForUnreachableDevice(emptyProjectRowCell(project: project), deviceID: project.deviceID)
        case .runtimeTarget(let project, let workspace, let item):
            return dimmedForUnreachableDevice(
                runtimeTargetRowCell(workspace: workspace, item: item, nestedUnderWorkspace: project.isGitRepo), deviceID: project.deviceID)
        }
    }

    /// Applies the owning device's row treatment: a device that is not loaded keeps its rows listed —
    /// the whole point of an outage staying browsable — dimmed, with the device named in a tooltip so
    /// the state is readable from the row itself and not only from the section caption above it.
    private func dimmedForUnreachableDevice(_ cell: NSTableCellView, deviceID: String) -> NSTableCellView {
        guard let section = host.deviceSections.first(where: { $0.deviceID == deviceID }), section.loadState != .loaded else { return cell }
        cell.alphaValue = AppKitController.sidebarRowAlpha(loadState: section.loadState)
        // A retry leaves the rows dimmed while the section reads "loading…", so the tooltip is written
        // only for the state it would actually be true of.
        if section.loadState.isOffline { cell.toolTip = "\(section.displayName) is offline" }
        return cell
    }

    private func deviceSectionName(deviceID: String) -> String {
        host.deviceSections.first(where: { $0.deviceID == deviceID })?.displayName ?? deviceID
    }

    /// Gathers this device's section facts and resolves what its header's caption area shows. The
    /// retry-availability read is the same one the button's action consults, so a visible recovery button
    /// always has something to attempt.
    private func deviceSectionStatus(deviceID: String) -> SidebarDeviceSectionStatus {
        guard let section = host.deviceSections.first(where: { $0.deviceID == deviceID }) else { return .none }
        return SidebarDeviceSectionStatus.resolve(
            loadState: section.loadState, isLocal: section.isLocal, offersRetry: deviceSectionOffersRetry(deviceID: deviceID),
            isUpdatePending: section.daemonStatus?.isUpdatePending == true)
    }

    /// Renders a paired device as a quiet, non-interactive section caption. The device node stays a
    /// structural parent of its project rows (always expanded), so the caption carries no chevron or
    /// selection chrome; load state is shown inline as muted trailing text, or — where the state is
    /// actionable — as the tinted button that both reports and recovers it.
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

        let section = host.deviceSections.first(where: { $0.deviceID == deviceID })
        if let compatibility = section?.compatibility, !compatibility.isCompatible {
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
        } else {
            // The offline reason (e.g. the daemon startup error) is surfaced on hover wherever the state
            // is drawn; the visible text stays terse so the sidebar does not widen.
            let offlineReason: String? = {
                guard case .offline(let message)? = section?.loadState, !message.isEmpty else { return nil }
                return message
            }()
            switch deviceSectionStatus(deviceID: deviceID) {
            case .caption(let text, let isFailure):
                let stateLabel = NSTextField(labelWithString: text)
                stateLabel.font = .systemFont(ofSize: 11, weight: .regular)
                stateLabel.textColor = isFailure ? sidebarFailedIndicatorColor() : .tertiaryLabelColor
                stateLabel.lineBreakMode = .byTruncatingTail
                stateLabel.setContentHuggingPriority(.required, for: .horizontal)
                stateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
                stateLabel.toolTip = offlineReason
                contentRow.addArrangedSubview(stateLabel)
            case .recoveryButton(let title):
                // Device headers are non-selectable, so this caption button is an offline device's only
                // per-device recovery; without it the user's only option is reloading the whole sidebar. It
                // also stands in for the offline caption, so it keeps the failed tint and the reason tooltip.
                let button = NSButton(title: title, target: self, action: #selector(deviceRetryClicked(_:)))
                button.bezelStyle = .inline
                button.controlSize = .small
                button.font = .systemFont(ofSize: 11, weight: .semibold)
                button.contentTintColor = sidebarFailedIndicatorColor()
                button.identifier = NSUserInterfaceItemIdentifier("retry:\(deviceID)")
                button.toolTip = offlineReason
                button.setContentHuggingPriority(.required, for: .horizontal)
                button.setContentCompressionResistancePriority(.required, for: .horizontal)
                contentRow.addArrangedSubview(button)
            case .none: break
            }
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
        // A non-git project row is its single workspace's row, so it carries that workspace's delete.
        let rowState = projectRowState(project)
        cell.alphaValue = rowState.alpha

        let rowBackground = NSView()
        rowBackground.translatesAutoresizingMaskIntoConstraints = false
        rowBackground.wantsLayer = true
        rowBackground.layer?.cornerRadius = UIRadius.regular
        // Muted selection (design V2+V4) drops the full border everywhere; a selected standalone project row
        // reads from the neutral fill alone (the grouped case is drawn by the outline view's selection region).
        rowBackground.layer?.borderWidth = 0
        bindAppearanceReactiveLayer(rowBackground) { [weak self] view in
            view.layer?.backgroundColor =
                isSelected && !usesGroupedWorkspaceSelection ? self?.sidebarSelectedCardBackgroundColor().cgColor : NSColor.clear.cgColor
        }

        let titleLabel = NSTextField(labelWithString: project.name)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = sidebarPrimaryTextColor(isSelected: isSelected)
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
        // While the stand-in row's delete runs, that slot carries a spinner instead of the folder, the way
        // a workspace row trades its status dot for one: the run state it would report is on its way out.
        let leadingIndicator: NSView
        if rowState.showsDeletingProgress, let workspace = nonGitProjectTargetWorkspace(project) {
            leadingIndicator = deletingProgressIndicator(workspaceID: workspace.id)
        } else {
            let leadingIcon = NSImageView()
            if project.isGitRepo {
                // The marketing site's project glyph (connected nodes) marks a git project without reading
                // as the ubiquitous branch icon.
                let glyph = RowPrimitives.projectGlyphImage()
                glyph.accessibilityDescription = "Git project"
                leadingIcon.image = glyph
                leadingIcon.contentTintColor = .tertiaryLabelColor
                leadingIcon.toolTip = "Git repository"
            } else {
                let workspace = nonGitProjectTargetWorkspace(project)
                let lifecycleRunning =
                    (workspace.flatMap { host.workspaceRuntimeStatusByID[$0.id]?.lifecycleState }
                        ?? WorkspaceLifecycleState(isRunning: workspace?.isRunning ?? false)) == .running
                leadingIcon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: lifecycleRunning ? "Running" : "Stopped")
                leadingIcon.contentTintColor = lifecycleRunning ? sidebarRunningIndicatorColor() : sidebarIdleIndicatorColor()
                leadingIcon.toolTip = lifecycleRunning ? "Running" : "Stopped"
            }
            leadingIndicator = leadingIcon
        }
        leadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        leadingIndicator.widthAnchor.constraint(equalToConstant: 13).isActive = true
        leadingIndicator.heightAnchor.constraint(equalToConstant: 13).isActive = true
        leadingStack.addArrangedSubview(leadingIndicator)
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
        // A marked row carries no controls, like the workspace row it stands in for: opening settings for
        // a project whose sole workspace is being removed is an interaction the row refuses. (Add
        // Workspace belongs to git projects only, whose rows stand in for nothing and are never marked.)
        if projectActions.showsSettings, rowState.isInteractive { accessoryStack.addArrangedSubview(settingsButton) }

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
            // Creating a workspace runs on the owning daemon, so it is offered only while that device
            // can service it. The settings gear beside it stays enabled: the dialog reads the cached
            // config, and only its saves are refused.
            host.disableWhenDeviceCannotAct(addButton, deviceID: project.deviceID)
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
        let rowState = workspaceRowState(workspace.id)
        cell.alphaValue = rowState.alpha

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

        let runtimeStatus =
            host.workspaceRuntimeStatusByID[workspace.id]
            ?? WorkspaceRuntimeStatus(
                workspaceID: workspace.id, lifecycleState: WorkspaceLifecycleState(isRunning: workspace.isRunning), runtimeHealth: .healthy,
                hasTrackedRuntimeIndicators: false, runningProcessCount: 0, exitedProcessCount: 0, waitingAgentWindowCount: 0,
                missingConfiguredProcessCount: 0, missingConfiguredBrowserSessionCount: 0)
        // While the delete runs, the row's leading indicator is a spinner: the workspace's run state is on
        // its way out and says nothing the user can act on, so the row reports the delete instead.
        let statusIndicator = rowState.showsDeletingProgress ? deletingProgressIndicator(workspaceID: workspace.id) : statusDot(runtimeStatus)
        statusIndicator.translatesAutoresizingMaskIntoConstraints = false
        statusIndicator.widthAnchor.constraint(equalToConstant: 10).isActive = true
        statusIndicator.heightAnchor.constraint(equalToConstant: 10).isActive = true

        let nameLabel = NSTextField(labelWithString: workspace.displayName)
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.textColor = sidebarPrimaryTextColor(isSelected: isSelected)
        nameLabel.setAccessibilityIdentifier("sidebar-workspace-title-\(workspace.id)")
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        titleRow.addArrangedSubview(statusIndicator)
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
        // A marked row carries no controls: opening settings for, or expanding, a workspace that is being
        // deleted are interactions the row refuses.
        if rowState.isInteractive {
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

    /// A workspace row's run-state dot: filled while the workspace runs, hollow while it is stopped.
    private func statusDot(_ runtimeStatus: WorkspaceRuntimeStatus) -> NSView {
        let isLifecycleRunning = runtimeStatus.lifecycleState == .running
        let statusIcon = NSImageView()
        statusIcon.image = NSImage(systemSymbolName: isLifecycleRunning ? "circle.fill" : "circle", accessibilityDescription: "Status")
        statusIcon.contentTintColor = isLifecycleRunning ? sidebarRunningIndicatorColor() : sidebarIdleIndicatorColor()
        statusIcon.toolTip = isLifecycleRunning ? "Running" : "Stopped"
        return statusIcon
    }

    /// The spinner a workspace row shows in place of its run-state dot while its delete runs, matching the
    /// mini spinning indicator the agent rows use for in-flight work.
    private func deletingProgressIndicator(workspaceID: String) -> NSView {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.toolTip = "Deleting…"
        spinner.setAccessibilityIdentifier("sidebar-workspace-deleting-\(workspaceID)")
        spinner.startAnimation(nil)
        return spinner
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
        case nil: return sidebarPrimaryTextColor(isSelected: isSelected)
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
            // Name then secondary text, the two-part shape a process row already uses (see
            // `AppKitController.windowRow`): the name goes semibold once something trails it, so the
            // two halves stay tellable apart at the sidebar's one type size.
            titleLabel.font = .systemFont(ofSize: 11, weight: item.detail == nil ? .regular : .semibold)
            titleLabel.textColor = runtimeTargetTextColor(item: item, isSelected: isWorkspaceSelected)
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(titleLabel)

            // Ad hoc shells trail the title their program reported as dimmed secondary text. It
            // compresses before the name does, so a long title never squeezes out what the row is.
            if let detail = item.detail {
                let detailLabel = NSTextField(labelWithString: detail)
                detailLabel.font = .systemFont(ofSize: 11, weight: .regular)
                detailLabel.textColor = sidebarMetadataTextColor(isSelected: isWorkspaceSelected)
                detailLabel.lineBreakMode = .byTruncatingTail
                detailLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
                detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
                row.addArrangedSubview(detailLabel)
            }
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
        // A row marked as deleting offers no actions: everything in the menu targets a workspace that is
        // being removed, and the delete already running is the one thing happening to it.
        case .workspace(_, let workspace): return workspaceRowState(workspace.id).isInteractive ? workspaceContextMenu(workspace: workspace) : nil
        // A non-git project's row stands in for its single workspace, so its right-click menu offers
        // the same workspace actions, resolved to that lone visible workspace — and offers none at all
        // once that workspace is marked as deleting, on the same terms as a `.workspace` row.
        case .project(let project) where !project.isGitRepo:
            guard let workspace = nonGitProjectTargetWorkspace(project), projectRowState(project).isInteractive else { return nil }
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
        // The menu keeps its shape while the owning device is unreachable — the same items in the same
        // order — and disables only the ones that need its daemon, so lifecycle, Hide and Delete read
        // as temporarily unavailable rather than silently disappearing mid-outage. Auto-enabling is off
        // so those decisions are the menu's own rather than AppKit's responder-chain guess.
        menu.autoenablesItems = false
        let daemonActionsEnabled = host.deviceAcceptsDaemonActions(forWorkspaceID: workspace.id)
        func addItem(
            _ title: String, symbol: String, target: AnyObject, action: Selector, identifier: String, representedObject: Any? = nil,
            isEnabled: Bool = true
        ) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
            item.representedObject = representedObject
            item.isEnabled = isEnabled
            menu.addItem(item)
        }
        if workspace.isRunning {
            addItem(
                "Restart", symbol: "arrow.clockwise", target: self, action: #selector(restartWorkspaceMenuItem(_:)), identifier: workspace.id,
                isEnabled: daemonActionsEnabled)
            addItem(
                "Stop", symbol: "stop", target: self, action: #selector(stopWorkspaceMenuItem(_:)), identifier: workspace.id,
                isEnabled: daemonActionsEnabled)
        } else {
            addItem(
                "Start", symbol: "play", target: self, action: #selector(startWorkspaceMenuItem(_:)), identifier: workspace.id,
                isEnabled: daemonActionsEnabled)
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
        // Hide stops the workspace through its daemon before hiding the row, so it is a daemon action.
        addItem(
            "Hide", symbol: "eye.slash", target: self, action: #selector(hideWorkspaceMenuItem(_:)), identifier: workspace.id,
            isEnabled: daemonActionsEnabled)
        // Delete is destructive (it removes the git worktree and the workspace), so it sits last, below the separator, and
        // routes through the same confirmation the detail ⋯ overflow menu uses.
        addItem(
            "Delete…", symbol: "trash", target: self, action: #selector(deleteWorkspaceMenuItem(_:)), identifier: workspace.id,
            isEnabled: daemonActionsEnabled)
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

    @objc private func deleteWorkspaceMenuItem(_ sender: NSMenuItem) {
        guard let id = sender.identifier?.rawValue else { return }
        host.deleteWorkspace(id: id)
    }

    private func runtimeTargetMenu(workspace: WorkspaceSummary, item: SidebarRuntimeTargetItem) -> NSMenu {
        let context = RuntimeTargetMenuContext(workspaceID: workspace.id, item: item)
        let menu = NSMenu()
        // Same rule as the workspace menu: the items stay listed while the owning device is
        // unreachable, and the ones that need its daemon are disabled instead of removed.
        menu.autoenablesItems = false
        let daemonActionsEnabled = host.deviceAcceptsDaemonActions(forWorkspaceID: workspace.id)
        func addItem(_ title: String, symbol: String, action: Selector?, isEnabled: Bool = true) {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            menuItem.target = action == nil ? nil : self
            menuItem.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menuItem.representedObject = context
            menuItem.isEnabled = isEnabled && action != nil
            menu.addItem(menuItem)
        }
        if item.canRun { addItem("Start", symbol: "play", action: #selector(startRuntimeTargetMenuItem(_:)), isEnabled: daemonActionsEnabled) }
        if item.canStop { addItem("Stop", symbol: "stop", action: #selector(stopRuntimeTargetMenuItem(_:)), isEnabled: daemonActionsEnabled) }
        if item.canRestart {
            addItem("Restart", symbol: "arrow.clockwise", action: #selector(restartRuntimeTargetMenuItem(_:)), isEnabled: daemonActionsEnabled)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        // Rename writes the new name through the daemon (a session rename command or a workspace
        // config edit), so it is a daemon action too.
        addItem("Rename", symbol: "pencil", action: #selector(renameRuntimeTargetMenuItem(_:)), isEnabled: daemonActionsEnabled)
        if item.kind != .browser {
            // Only session-backed targets can move into a panel window; a target that
            // hasn't started yet keeps the item visible but disabled for discoverability.
            // Moving an already-open session into a window is client-side, so an outage does not
            // disable it — the pane it opens carries its own disconnected state. A session that is
            // not open in a pane is the other operation: it would install a fresh pane against the
            // device's daemon, so it follows the same rule the open chokepoint enforces rather than
            // being offered and then refused.
            let sessionIsOpenInAPane = item.sessionID.map { host.panelCoordinator.placement(forSessionID: $0) != nil } ?? false
            addItem(
                "Open in New Window", symbol: "macwindow.badge.plus",
                action: item.sessionID == nil ? nil : #selector(openRuntimeTargetInNewWindowMenuItem(_:)),
                isEnabled: AppKitController.canOpenOrFocusTerminalPane(
                    hasExistingPane: sessionIsOpenInAPane, deviceAcceptsDaemonActions: daemonActionsEnabled))
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

    func sidebarCardBackgroundColor() -> NSColor {
        let alpha: CGFloat = 0.55
        return sidebarThemeColor(light: (240, 238, 230), dark: (24, 36, 39), alpha: alpha)
    }

    /// Muted neutral fill for the selected workspace region (design V2+V4): a faint ink/white overlay
    /// rather than a teal-tinted card, so the leading teal rail is the only accent.
    func sidebarSelectedCardBackgroundColor() -> NSColor { sidebarThemeColor(light: (0, 0, 0), dark: (255, 255, 255), alpha: 0.06) }

    /// Teal rail drawn on the leading edge of a selected sidebar row/region — the selection's sole accent.
    /// Matches the focused-pane accent bar so the sidebar and terminal chrome share one accent.
    func sidebarSelectionRailColor() -> NSColor { sidebarThemeColor(light: (15, 122, 118), dark: (89, 219, 205), alpha: 0.9) }

    func sidebarCardBorderColor(isSelected: Bool) -> NSColor {
        if isSelected { return sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184), alpha: 0.28) }
        return sidebarThemeColor(light: (213, 216, 211), dark: (48, 67, 70), alpha: 0.72)
    }

    func sidebarPrimaryTextColor(isSelected: Bool) -> NSColor {
        let alpha: CGFloat = isSelected ? 0.96 : 0.92
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

    @objc private func deviceRetryClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("retry:") else { return }
        retryDeviceConnection(deviceID: String(raw.dropFirst("retry:".count)))
    }

    /// Whether this device's header offers a recovery button (Reconnect, or Restart for this Mac). The one
    /// place that decides it, consulted both by the header that renders the button and by the action the
    /// button fires, so a visible button always has something to attempt.
    ///
    /// The credential read is deliberately behind the offline check: it touches the paired-device
    /// records and the credential store, and every device row is rebuilt on every outline reload.
    private func deviceSectionOffersRetry(deviceID: String) -> Bool {
        guard let section = host.deviceSections.first(where: { $0.deviceID == deviceID }), section.loadState.isOffline else { return false }
        let hasCredentials =
            !section.isLocal
            && (host.macPairedDevices().first(where: { $0.id == deviceID }).map(AppKitController.pairedDeviceHasRequiredCredentials) ?? false)
        return Self.deviceSectionOffersRetry(loadState: section.loadState, isLocal: section.isLocal, hasCredentials: hasCredentials)
    }

    /// A remote whose auth token or certificate fingerprint is gone reads "Reconnect required" and is
    /// recovered by pairing it again, not by reconnecting, so it is offered no recovery button — which is
    /// why that state keeps a caption, the only thing left to report it. Pure so the rule is directly
    /// testable.
    nonisolated static func deviceSectionOffersRetry(loadState: SidebarDeviceLoadState, isLocal: Bool, hasCredentials: Bool) -> Bool {
        guard loadState.isOffline else { return false }
        // The local device has no stored credentials of its own; its retry re-runs the sidebar snapshot,
        // which is what re-probes the local daemon.
        return isLocal || hasCredentials
    }

    /// User-initiated recovery for one offline device: the work the reachability watchdog does on its
    /// own cadence, run immediately for this device alone and without waiting out its backoff. The
    /// section returns to `.loading` so the click has visible feedback, and the attempt moves it on to
    /// loaded, or back to offline carrying the reason it failed with this time.
    private func retryDeviceConnection(deviceID: String) {
        guard deviceSectionOffersRetry(deviceID: deviceID), let index = host.deviceSections.firstIndex(where: { $0.deviceID == deviceID }) else {
            return
        }
        if host.deviceSections[index].isLocal {
            markDeviceSectionRetrying(deviceID: deviceID, index: index)
            // The local device has no subscription to reopen. Re-running the snapshot is what re-probes
            // the local daemon — the same path the Reload command uses.
            requestSidebarReload()
            return
        }
        guard let record = host.macPairedDevices().first(where: { $0.id == deviceID }) else { return }
        markDeviceSectionRetrying(deviceID: deviceID, index: index)
        remoteOverviewSubscriptions.resetForUserRetry(deviceID: deviceID)?.stop()
        // Both attempts bypass their throttle deliberately: the pull skips the freshness gate and its
        // backoff, and the subscribe skips the backoff, because the user asked for this device
        // specifically.
        startRemoteOverviewPull(record: record, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short), bypassesBackoff: true)
        refreshRemoteOverviewSubscriptions()
    }

    private func markDeviceSectionRetrying(deviceID: String, index: Int) {
        DeviceLinkTrace.log(deviceID: deviceID, event: "retry_requested")
        // Reuses the load state a device starts in rather than adding a retrying-specific one: the
        // section genuinely is loading, and a failure arriving from `.loading` re-runs the full offline
        // transition, so the caption picks up the new reason instead of being dropped as a repeat.
        host.deviceSections[index].loadState = .loading
        host.outlineView.reloadData()
        applySidebarProjectExpansionState()
    }

    @objc private func compatibilityActionClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, raw.hasPrefix("compat:") else { return }
        let deviceID = String(raw.dropFirst("compat:".count))
        guard let verdict = host.deviceCompatibility(forDeviceID: deviceID), !verdict.isCompatible else { return }
        host.showCompatibilityBlock(deviceID: deviceID, verdict: verdict, presentation: .userNavigation)
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
            if !host.showingAlerts { host.showPlaceholder(presentation: .userNavigation) }
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
            host.showWorkspaceDetail(project: project, workspace: workspace, presentation: .userNavigation)
        case .workspace(let project, let workspace):
            host.selectedProjectID = project.id
            host.selectedWorkspaceID = workspace.id
            AppKitController.setClientActiveWorkspaceID(workspace.id)
            host.showingSettings = false
            updateWorkspaceExpansionForSelection(newWorkspaceID: workspace.id)
            host.showWorkspaceDetail(project: project, workspace: workspace, presentation: .userNavigation)
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

    private func selectedWorkspaceHighlight(in outlineView: NSOutlineView) -> (frame: NSRect, rail: NSColor)? {
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
        return (highlightFrame, sidebarSelectionRailColor())
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
    /// mouse interaction, or expanded transiently because it is the current arrow-key selection. A row
    /// marked as deleting shows none, without clearing either piece of state, so a failed delete restores
    /// exactly what the user had open.
    private func isWorkspaceExpanded(_ workspaceID: String) -> Bool {
        guard workspaceRowState(workspaceID).listsRuntimeTargetChildren else { return false }
        return pinnedWorkspaceIDs.contains(workspaceID) || transientlyExpandedWorkspaceID == workspaceID
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
        // Selection rail: a squared teal bar shown while the Alerts view is active. It sits on the row's own
        // leading edge (just left of the bell), not the window edge — a single short row's rail is lost in the
        // top-left corner, so it is inset here rather than aligned to the outline's window-edge workspace rail.
        let rail = NSView()
        rail.translatesAutoresizingMaskIntoConstraints = false
        rail.wantsLayer = true
        rail.isHidden = true
        row.addSubview(rail)
        alertsRowRail = rail

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor), stack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            stack.topAnchor.constraint(equalTo: row.topAnchor), stack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            rail.leadingAnchor.constraint(equalTo: row.leadingAnchor), rail.widthAnchor.constraint(equalToConstant: 2),
            rail.topAnchor.constraint(equalTo: row.topAnchor), rail.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])

        let click = NSClickGestureRecognizer(target: host, action: #selector(AppKitController.alertsRowClicked))
        row.addGestureRecognizer(click)
        alertsRowView = row
        return row
    }

    func updateAlertsRowAppearance() {
        guard let stack = alertsRowStack else { return }
        let isShowingAlerts = host.showingAlerts
        // Selection reads from the leading teal rail alone (matching the workspace selection) — no fill/border.
        stack.layer?.borderWidth = 0
        stack.layer?.backgroundColor = NSColor.clear.cgColor
        alertsRowRail?.isHidden = !isShowingAlerts
        if let rail = alertsRowRail {
            bindAppearanceReactiveLayer(rail) { [weak self] view in view.layer?.backgroundColor = self?.sidebarSelectionRailColor().cgColor }
        }
    }
}
