import AppKit
import Carbon
import Foundation
import appctl
import streamctl

private let startupProfileBaselineUptime = ProcessInfo.processInfo.systemUptime

@MainActor
public final class AppKitController: NSObject, NSApplicationDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSplitViewDelegate,
    NSWindowDelegate, NSTextFieldDelegate
{
    private enum DashboardIconTint: Sendable {
        case browser
        case terminal
        case code
        case success
        case warning
    }

    private enum InlineWorkspaceDetailField {
        case title
        case branch
        case tooltip
    }

    private struct InlineWorkspaceDetailFieldRefs {
        let workspaceID: String
        let field: InlineWorkspaceDetailField
        let valueLabel: NSTextField
        let textField: NSTextField
        let saveButton: NSButton
        let cancelButton: NSButton
        var originalValue: String
        var isEditing: Bool
    }

    private struct DashboardAttentionEntry: Sendable {
        let attentionID: String
        let icon: String
        let iconTint: DashboardIconTint
        let label: String
        let detail: String?
        let shortcut: String
        let processStatus: RunningProcessState?
        let agentStatus: AgentWindowStatus?
        let countsTowardBadge: Bool
        /// All status checks for this process (green and red), matching Run tab display.
        let statusChecks: [StatusResult]
        let eventDate: Date?
        let focusRequest: WindowFocusRequest?
    }

    private struct DashboardGroup: Sendable {
        let projectName: String
        let workspaceID: String
        let workspaceName: String
        let items: [DashboardAttentionEntry]
        var latestDate: Date? { items.compactMap(\.eventDate).max() }
    }

    struct MissingConfiguredProcessDashboardItem: Sendable, Equatable {
        let attentionID: String
        let label: String
        let detail: String?
        let processKey: String
    }

    enum StatusColorStyle: Sendable {
        case metadata
        case warning
    }

    enum SidebarArrowSelectionTarget: Equatable, Sendable {
        case dashboard
        case workspace(String)
    }

    private var window: NSWindow!
    private var splitView: NSSplitView?
    private let outlineView = SidebarOutlineView()
    private let detailContainer = NSView()
    private weak var workspaceShortcutFooterRowView: NSStackView?
    private var workspaceShortcutFooterLabels: [NSTextField] = []
    private var orchestrator: MuxyOrchestrator!
    private var projects: [ProjectSummary] = []
    private var outlineItemRefCache: [String: OutlineItemRef] = [:]
    private var workspacesByProject: [String: [WorkspaceSummary]] = [:]
    private var workspaceRuntimeStatusByID: [String: WorkspaceRuntimeStatus] = [:]
    private var dashboardGroups: [DashboardGroup] = []
    private var dismissedDashboardAttentionItemIDs: Set<String> = []
    private var visibleDetailWorkspaceID: String?

    private var selectedProjectID: String?
    private var selectedWorkspaceID: String?
    private var lastSelectedRow: Int = -1
    private var suppressOutlineSelectionChanges = false
    private var projectHasUnsavedChanges = false
    private var showingSettings = false
    private var hiddenWorkspacesCollapsed = true

    private var hotkeyHandler: EventHandlerRef?
    private var hotkeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var shortcutLeaderModifiers: Set<HotkeyModifier> = []
    private var pendingLeaderCaptureModifiers: Set<HotkeyModifier> = []
    private var toggleShortcutSpec: HotkeySpec?
    private var dashboardShortcutSpec: HotkeySpec?
    private var shortcutMonitor: Any?
    private var addProjectShortcutSpec: HotkeySpec?
    private var addWorkspaceShortcutSpec: HotkeySpec?
    private var reloadShortcutSpec: HotkeySpec?
    private var openEditorShortcutSpec: HotkeySpec?
    private var openTerminalShortcutSpec: HotkeySpec?
    private var openFinderShortcutSpec: HotkeySpec?
    private var openSettingsShortcutSpec: HotkeySpec?
    private var nextShortcutSpec: HotkeySpec?
    private var previousShortcutSpec: HotkeySpec?
    private var windowShortcutSpec: HotkeySpec?
    private var windowSequenceShortcutSpec: HotkeySpec?
    private var shortcutButtonsBySetting: [String: NSButton] = [:]
    private var activeShortcutCaptureSetting: ShortcutSetting?
    private weak var pulseColorWell: NSColorWell?
    private var periodicWorkspaceRefreshTask: Task<Void, Never>?
    private var periodicUpdateCheckTask: Task<Void, Never>?
    private var periodicProcessMonitorTask: Task<Void, Never>?
    private var periodicWorktreeDiscoveryTask: Task<Void, Never>?
    private var periodicSidebarMetadataRefreshTask: Task<Void, Never>?
    private var deferredHotkeySelectionRefreshTask: Task<Void, Never>?
    private var activeSpaceSummonCleanupTask: Task<Void, Never>?
    private var visibleWorkspaceDetailRefreshTask: Task<Void, Never>?
    private var visibleWorkspaceDetailRefreshWorkspaceID: String?
    private var pendingWorktreeDiscoveryReload = false
    private var lastTrackedWindowCounts: [String: Int] = [:]
    private let updateChecker = UpdateChecker()
    private let appUpdater = AppUpdater()
    private var checkForUpdatesMenuItem: NSMenuItem?
    private var availableUpdate: UpdateInfo?
    private var agentEventIPCObserver: NSObjectProtocol?
    private var selectWorkspaceDetailIPCObserver: NSObjectProtocol?
    private var appDidBecomeActiveObserver: NSObjectProtocol?
    private var appDidResignActiveObserver: NSObjectProtocol?
    private var didStartBackgroundServices = false
    private var setupManager: SetupManager?
    private var sidebarReloadTask: Task<Void, Never>?
    private var pendingSidebarReloadRequest = false
    private var activeWindowShortcutProfile: WindowShortcutProfile?
    private let startupProfileStartTime = startupProfileBaselineUptime
    private var didLogFirstStartupInteraction = false

    private var configCache: AppConfig?
    private let defaultSplitViewWidth: CGFloat = 360
    private let shortcutLabelColumnWidth: CGFloat = 250
    private var isApplyingSplitViewWidth = false
    private var hasAppliedSplitViewWidth = false
    private var inlineWorkspaceFieldRefsByTag: [Int: InlineWorkspaceDetailFieldRefs] = [:]
    private var inlineWorkspaceFieldTagByObjectID: [ObjectIdentifier: Int] = [:]
    private var inlineWorkspaceLabelTagByObjectID: [ObjectIdentifier: Int] = [:]
    private var inlineWorkspaceOutsideClickMonitor: Any?
    private var activeAddWorkspaceFormTag: Int?
    private var activeAddProjectFormTag: Int?
    private var operationProgressOverlay: NSVisualEffectView?
    private var operationProgressOverlayTitleLabel: NSTextField?
    private var operationProgressOverlayDetailLabel: NSTextField?
    private var windowIssueToastOverlay: NSVisualEffectView?
    private var windowIssueToastTitleLabel: NSTextField?
    private var windowIssueToastDetailLabel: NSTextField?
    private var windowIssueToastActionButton: NSButton?
    private var windowIssueToastActionHandler: (() -> Void)?
    private var windowIssueToastDismissTask: Task<Void, Never>?
    private lazy var iso8601Formatter: ISO8601DateFormatter = ISO8601DateFormatter()

    // Dashboard sidebar row
    private var dashboardRowView: NSView?
    private var dashboardRowStack: NSStackView?
    private var dashboardRowBadge: NSTextField?
    private var showingDashboard = false
    /// Maps sequential window shortcut numbers (1-9) to focus targets for the current dashboard view.
    private var dashboardFocusRequestMap: [Int: WindowFocusRequest] = [:]
    private var bufferedWindowShortcutIndices: [Int] = []
    private var deferredExternalWindowHideTask: Task<Void, Never>?

    private struct WindowShortcutProfile {
        let index: Int
        let startedAt: Date
        var routeCompletedAt: Date?
    }

    private enum WindowFocusRequest: Sendable {
        case workspaceBrowserSession(workspaceID: String, targetURL: String)
        case workspaceWindow(workspaceID: String, index: Int)
        case workspaceProcess(workspaceID: String, processID: String)
        case workspaceMissingConfiguredProcess(workspaceID: String, processKey: String)
        case agentWindow(AgentWindowRecord)
    }

    enum ExternalWindowAction: Sendable {
        case focus
        case open
    }

    private enum WindowShortcutExecutionOutcome: Sendable {
        case focused(kind: String)
        case opened(kind: String)
        case noWorkspace
        case noMatch
    }

    private lazy var hotkeyHandlerProc: EventHandlerUPP = { _, event, userData in
        guard let userData else { return noErr }
        let controller = Unmanaged<AppKitController>.fromOpaque(userData).takeUnretainedValue()
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        if status != noErr { return status }
        Task { @MainActor in controller.handleGlobalHotkey(id: hotKeyID.id) }
        return noErr
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        logStartupProfile("did_finish_launching")
        do {
            let db = try DatabaseLocator.defaultPath()
            let store = try SQLiteStore(path: db)
            orchestrator = MuxyOrchestrator(store: store)
        } catch {
            showError(error)
            return
        }
        logStartupProfile("store_ready")

        buildShellWindow()
        logStartupProfile("shell_window_ready")
        NSApp.activate(ignoringOtherApps: true)
        logStartupProfile("app_activated")
        buildMainMenu()
        logStartupProfile("main_menu_ready")
        loadShortcutSpecs()
        logStartupProfile("shortcut_specs_loaded")
        setupGlobalHotkey()
        logStartupProfile("global_hotkeys_ready")
        setupShortcutMonitor()
        logStartupProfile("shortcut_monitor_ready")
        setupAgentEventIPCObserver()
        setupSelectWorkspaceDetailIPCObserver()
        setupAppActivationObservers()
        logStartupProfile("ipc_observers_ready")

        enterSetupFlow()
        logStartupProfile("setup_started")
    }

    public func applicationWillTerminate(_ notification: Notification) {
        periodicWorkspaceRefreshTask?.cancel()
        periodicUpdateCheckTask?.cancel()
        periodicProcessMonitorTask?.cancel()
        periodicWorktreeDiscoveryTask?.cancel()
        periodicSidebarMetadataRefreshTask?.cancel()
        deferredHotkeySelectionRefreshTask?.cancel()
        sidebarReloadTask?.cancel()
        teardownInlineWorkspaceOutsideClickMonitor()
        teardownGlobalHotkey()
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
        if let agentEventIPCObserver {
            DistributedNotificationCenter.default().removeObserver(agentEventIPCObserver)
            self.agentEventIPCObserver = nil
        }
        if let selectWorkspaceDetailIPCObserver {
            DistributedNotificationCenter.default().removeObserver(selectWorkspaceDetailIPCObserver)
            self.selectWorkspaceDetailIPCObserver = nil
        }
        if let appDidBecomeActiveObserver {
            NotificationCenter.default.removeObserver(appDidBecomeActiveObserver)
            self.appDidBecomeActiveObserver = nil
        }
        if let appDidResignActiveObserver {
            NotificationCenter.default.removeObserver(appDidResignActiveObserver)
            self.appDidResignActiveObserver = nil
        }
    }

    private func setupAgentEventIPCObserver() {
        agentEventIPCObserver = DistributedNotificationCenter.default().addObserver(
            forName: IPCNotification.agentEventFired, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reloadData()
            }
        }
    }

    private func setupSelectWorkspaceDetailIPCObserver() {
        selectWorkspaceDetailIPCObserver = DistributedNotificationCenter.default().addObserver(
            forName: IPCNotification.selectWorkspaceDetail, object: nil, queue: .main
        ) { [weak self] notification in
            guard let workspaceID = notification.userInfo?[IPCNotification.workspaceIDUserInfoKey] as? String else { return }
            Task { @MainActor [weak self, workspaceID] in
                guard let self else { return }
                guard let (_, workspace) = self.findWorkspace(id: workspaceID) else {
                    self.logWorkspaceDetailIPC("workspace_not_found id=\(workspaceID)")
                    return
                }
                self.logWorkspaceDetailIPC("selecting id=\(workspaceID) title=\(workspace.title)")
                self.showingDashboard = false
                self.showingSettings = false
                self.selectWorkspace(workspace)
                self.refreshSelection()
                NSApp.activate(ignoringOtherApps: true)
                NSApp.unhide(nil)
                if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first {
                    if window.isMiniaturized { window.deminiaturize(nil) }
                    self.prepareWindowForActiveSpaceSummon(window)
                    window.orderFrontRegardless()
                    window.makeKey()
                }
                self.logWorkspaceDetailIPC("selected id=\(workspaceID) title=\(workspace.title)")
            }
        }
    }

    private func logWorkspaceDetailIPC(_ message: String) {
        guard ProcessInfo.processInfo.environment["DEBUG"] == "1" else { return }
        // Manual real-system E2E uses these lines to confirm the helper-driven
        // workspace-detail selection request was accepted by the running app.
        fputs("muxy: workspace_detail_ipc \(message)\n", stderr)
    }

    private func setupAppActivationObservers() {
        appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let profile = self.activeWindowShortcutProfile {
                    let routeElapsedMS = profile.routeCompletedAt.map { self.windowShortcutElapsedMS(since: $0) } ?? -1
                    self.logWindowShortcutProfile(
                        "stage=app_became_active index=\(profile.index) elapsed_ms=\(self.windowShortcutElapsedMS(since: profile.startedAt)) route_gap_ms=\(routeElapsedMS)"
                    )
                }
                self.requestVisibleWorkspaceDetailRefreshIfNeeded(reason: "app_became_active")
            }
        }
        appDidResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let profile = self.activeWindowShortcutProfile else { return }
                let routeElapsedMS = profile.routeCompletedAt.map { self.windowShortcutElapsedMS(since: $0) } ?? -1
                self.logWindowShortcutProfile(
                    "stage=app_resigned_active index=\(profile.index) elapsed_ms=\(self.windowShortcutElapsedMS(since: profile.startedAt)) route_gap_ms=\(routeElapsedMS)"
                )
            }
        }
    }

    private func startPeriodicWorkspaceWindowRefresh() {
        periodicWorkspaceRefreshTask?.cancel()
        periodicWorkspaceRefreshTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let result = await Self.refreshWorkspaceWindowsSnapshot()
                if Task.isCancelled { break }
                switch result {
                case .success(let refreshResult):
                    let windowCountsChanged = refreshResult.trackedWindowCounts != self.lastTrackedWindowCounts
                    self.lastTrackedWindowCounts = refreshResult.trackedWindowCounts
                    if (refreshResult.didMutateDB || windowCountsChanged) && self.canReloadAfterBackgroundWorkspaceRefresh() {
                        self.requestSidebarReload()
                    }
                case .failure(let error): if !self.handleDeferredSetupRequirementIfNeeded(error) { self.showError(error) }
                }
                do { try await Task.sleep(for: .seconds(PollingConstants.workspaceWindowRefreshInterval)) } catch { break }
            }
        }
    }

    private func startPeriodicProcessMonitor() {
        periodicProcessMonitorTask?.cancel()
        periodicProcessMonitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let result = await Self.runProcessMonitorSnapshot()
                if Task.isCancelled { break }
                switch result {
                case .success(let didUpdate): if didUpdate && self.canReloadAfterBackgroundWorkspaceRefresh() { self.requestSidebarReload() }
                case .failure: break
                }
                do { try await Task.sleep(for: .seconds(PollingConstants.processStatusCheckInterval)) } catch { break }
            }
        }
    }

    private func startPeriodicWorktreeDiscovery() {
        periodicWorktreeDiscoveryTask?.cancel()
        periodicWorktreeDiscoveryTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let result = await Self.runWorktreeDiscoverySnapshot()
                if Task.isCancelled { break }
                switch result {
                case .success(let createdCount):
                    if createdCount > 0 {
                        if self.canReloadAfterBackgroundWorkspaceRefresh() {
                            self.pendingWorktreeDiscoveryReload = false
                            self.requestSidebarReload()
                        } else {
                            self.pendingWorktreeDiscoveryReload = true
                        }
                    } else if self.pendingWorktreeDiscoveryReload, self.canReloadAfterBackgroundWorkspaceRefresh() {
                        self.pendingWorktreeDiscoveryReload = false
                        self.requestSidebarReload()
                    }
                case .failure: break
                }
                do { try await Task.sleep(for: .seconds(PollingConstants.worktreeDiscoveryInterval)) } catch { break }
            }
        }
    }

    private func startPeriodicSidebarMetadataRefresh() {
        periodicSidebarMetadataRefreshTask?.cancel()
        periodicSidebarMetadataRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(PollingConstants.sidebarMetadataRefreshInterval)) } catch { break }
                if Task.isCancelled { break }
                guard self.canReloadAfterBackgroundWorkspaceRefresh() else { continue }
                // Catch external CLI edits (for example title changes) that do not trigger other poller reloads.
                self.requestSidebarReload()
            }
        }
    }

    private func startPeriodicUpdateCheck() {
        periodicUpdateCheckTask?.cancel()
        periodicUpdateCheckTask = Task { [weak self] in
            guard let self else { return }
            await self.performUpdateCheck()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(4 * 60 * 60)) } catch { break }
                await self.performUpdateCheck()
            }
        }
    }

    private func performUpdateCheck() async {
        let info = await updateChecker.checkForUpdate()
        availableUpdate = info
        if let info {
            checkForUpdatesMenuItem?.title = "Update Available: v\(info.version)"
        } else {
            checkForUpdatesMenuItem?.title = "Up to Date"
            checkForUpdatesMenuItem?.action = #selector(checkForUpdatesMenuAction(_:))
        }
    }

    @objc private func checkForUpdatesMenuAction(_ sender: Any?) {
        Task {
            checkForUpdatesMenuItem?.title = "Checking..."
            checkForUpdatesMenuItem?.isEnabled = false
            let info = await updateChecker.forceCheck()
            availableUpdate = info
            checkForUpdatesMenuItem?.isEnabled = true
            if let info {
                checkForUpdatesMenuItem?.title = "Update Available: v\(info.version)"
                showUpdateAlert(info: info)
            } else {
                checkForUpdatesMenuItem?.title = "Up to Date"
                let alert = NSAlert()
                alert.messageText = "You're up to date"
                alert.informativeText = "Muxy \(AppVersion.current) is the latest version."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
                checkForUpdatesMenuItem?.title = "Check for Updates..."
            }
        }
    }

    private func showUpdateAlert(info: UpdateInfo) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "Muxy v\(info.version) is available (you have v\(AppVersion.current)).\n\n\(info.releaseNotes.prefix(500))"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download & Install")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn { performUpdate(info: info) }
    }

    private func performUpdate(info: UpdateInfo) {
        Task {
            checkForUpdatesMenuItem?.title = "Downloading..."
            checkForUpdatesMenuItem?.isEnabled = false
            do { try await appUpdater.downloadAndInstall(from: info.downloadURL) } catch {
                checkForUpdatesMenuItem?.title = "Update Available: v\(info.version)"
                checkForUpdatesMenuItem?.isEnabled = true
                showError(error)
            }
        }
    }

    private func canReloadAfterBackgroundWorkspaceRefresh() -> Bool {
        !projectHasUnsavedChanges && activeAddWorkspaceFormTag == nil && activeAddProjectFormTag == nil && !isTextInputFocused()
    }

    private func canPreserveDetailPaneAfterSidebarReload() -> Bool {
        if activeAddWorkspaceFormTag != nil || activeAddProjectFormTag != nil { return true }
        if showingDashboard || showingSettings { return true }
        if let selectedWorkspaceID { return findWorkspace(id: selectedWorkspaceID) != nil }
        if let selectedProjectID { return projects.contains(where: { $0.id == selectedProjectID }) }
        return false
    }

    private enum WorkspaceLifecycleAction {
        case launch
        case restart
        case stop
        case archive
    }

    private enum AddWorkspaceBranchMode: String {
        case existing
        case create
    }

    private struct WorkspaceLifecycleOutcome: Sendable { let notice: String? }

    private struct VisibleWorkspaceDetailRefreshOutcome: Sendable {
        let didMutateWindows: Bool
        let didUpdateProcesses: Bool

        var didChangeVisibleState: Bool { didMutateWindows || didUpdateProcesses }
    }

    private struct WorkspaceCreateInput: Sendable {
        let projectID: String
        let name: String
        let branch: String?
        let targetBranch: String?
        let directoryName: String?
        let tooltip: String?
        let allowRemoteBranchLookup: Bool
    }

    private struct ProjectCreateInput: Sendable {
        let gitURL: String?
        let directoryPath: String?
        let setupScript: String?
        let stopScript: String?
        let ports: [PortDefinition]
        let processes: [ProcessTemplate]
        let browserSessions: [BrowserSession]
        let statusChecks: [StatusCheckDefinition]
        let agentLaunchers: [AgentLauncher]
    }

    private struct SidebarDataSnapshot: Sendable {
        let config: AppConfig
        let projects: [ProjectSummary]
        let workspacesByProject: [String: [WorkspaceSummary]]
        let workspaceRuntimeStatusByID: [String: WorkspaceRuntimeStatus]
        let dashboardGroups: [DashboardGroup]
    }

    /// Holds a click closure and serves as the NSGestureRecognizer target for clickable row views.
    @MainActor private final class ClickTarget: NSObject {
        let action: () async -> Void
        init(_ action: @escaping () async -> Void) { self.action = action }
        @objc func clicked(_ sender: NSGestureRecognizer) { Task { await self.action() } }
    }

    private static var clickTargetAssocKey: UInt8 = 0

    nonisolated private static func startupProfileEnabled() -> Bool { ProcessInfo.processInfo.environment["MUXY_STARTUP_PROFILE"] == "1" }

    nonisolated private static func startupElapsedMS() -> Int { Int((ProcessInfo.processInfo.systemUptime - startupProfileBaselineUptime) * 1000) }

    private func logStartupProfile(_ stage: String, details: String = "") {
        guard Self.startupProfileEnabled() else { return }
        let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - startupProfileStartTime) * 1000)
        let suffix = details.isEmpty ? "" : " \(details)"
        fputs("muxy: startup stage=\(stage) elapsed_ms=\(elapsedMS)\(suffix)\n", stderr)
    }

    nonisolated private static func logStartupSnapshotProfile(_ stage: String, details: String = "") {
        guard startupProfileEnabled() else { return }
        let suffix = details.isEmpty ? "" : " \(details)"
        fputs("muxy: startup stage=\(stage) elapsed_ms=\(startupElapsedMS())\(suffix)\n", stderr)
    }

    private func recordStartupInteraction(kind: String) {
        guard !didLogFirstStartupInteraction else { return }
        didLogFirstStartupInteraction = true
        logStartupProfile("first_interaction", details: "kind=\(kind)")
    }

    private static func dashboardIconColor(_ tint: DashboardIconTint) -> NSColor {
        switch tint {
        case .browser: .systemBlue
        case .terminal: .systemGreen
        case .code: .systemPurple
        case .success: .systemGreen
        case .warning: .systemOrange
        }
    }

    nonisolated private static func dashboardAttentionID(process: RunningProcessRecord, failedChecks: [StatusResult]) -> String {
        if process.status == .exited { return "process:\(process.id):exited:\(process.exitedAt ?? "unknown")" }
        let failedCheckNames = failedChecks.map(\.checkName).sorted().joined(separator: ",")
        let latestFailure = failedChecks.compactMap(\.lastRunAt).max() ?? "unknown"
        return "process:\(process.id):failed:\(failedCheckNames):\(latestFailure)"
    }

    nonisolated private static func dashboardAttentionID(agentWindow: AgentWindowRecord) -> String {
        "agent:\(agentWindow.id):\(agentWindow.status.rawValue):\(agentWindow.updatedAt)"
    }

    nonisolated static func dashboardAttentionAgentWindows(_ agentWindows: [AgentWindowRecord]) -> [AgentWindowRecord] {
        agentWindows.filter { $0.status == .waiting || $0.status == .done }
    }

    nonisolated static func dashboardMissingConfiguredProcessItems(workspaceID: String, processEntries: [WorkspaceRunProcessEntry])
        -> [MissingConfiguredProcessDashboardItem]
    {
        processEntries.compactMap { entry in
            guard entry.kind == .missingConfiguredProcess, let processKey = entry.processKey, let label = entry.processLabel else { return nil }
            return MissingConfiguredProcessDashboardItem(
                attentionID: "process-missing:\(workspaceID):\(processKey)", label: label, detail: entry.processCommand, processKey: processKey)
        }
    }

    nonisolated private static func dashboardFocusRequest(
        window: WindowRecord, windowListIndex: Int, process: RunningProcessRecord, workspaceID: String
    ) -> WindowFocusRequest {
        if window.role == "browser", let targetURL = window.targetURL, !targetURL.isEmpty {
            return .workspaceBrowserSession(workspaceID: workspaceID, targetURL: targetURL)
        }
        if window.role == "terminal" { return .workspaceProcess(workspaceID: workspaceID, processID: process.id) }
        return .workspaceWindow(workspaceID: workspaceID, index: windowListIndex)
    }

    nonisolated private static func refreshWorkspaceWindowsSnapshot() async -> Result<MuxyOrchestrator.RefreshResult, Error> {
        await Task.detached(priority: .utility) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = MuxyOrchestrator(store: store)
                let result = try orchestrator.refreshAllWorkspaceWindows()
                return .success(result)
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func refreshVisibleWorkspaceDetailSnapshot(workspaceID: String) async -> Result<
        VisibleWorkspaceDetailRefreshOutcome, Error
    > {
        await Task.detached(priority: .utility) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = MuxyOrchestrator(store: store)
                let didMutateWindows = try orchestrator.refreshWorkspaceWindows(workspaceID: workspaceID)
                let didUpdateProcesses = try orchestrator.checkAndUpdateProcessStatuses() || orchestrator.runDueStatusChecksForRunningWorkspaces()
                return .success(.init(didMutateWindows: didMutateWindows, didUpdateProcesses: didUpdateProcesses))
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func runWorkspaceLifecycleAction(_ action: WorkspaceLifecycleAction, workspaceID: String) async -> Result<
        WorkspaceLifecycleOutcome, Error
    > {
        await Task.detached(priority: .userInitiated) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = MuxyOrchestrator(store: store)
                var notice: String?
                switch action {
                case .launch: try orchestrator.launchWorkspace(workspaceID: workspaceID)
                case .restart: try orchestrator.restartWorkspace(workspaceID: workspaceID)
                case .stop:
                    let outcome = try orchestrator.stopWorkspace(workspaceID: workspaceID)
                    if outcome.skippedStopScriptBecauseWorkspaceDirectoryMissing {
                        notice = "Workspace directory is missing. Muxy stopped the workspace and skipped its stop script."
                    }
                case .archive: try orchestrator.archiveWorkspace(workspaceID: workspaceID)
                }
                return .success(.init(notice: notice))
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func createWorkspaceSnapshot(input: WorkspaceCreateInput) async -> Result<WorkspaceRecord, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = MuxyOrchestrator(store: store)
                var workspace = try orchestrator.createWorkspace(
                    projectID: input.projectID, name: input.name, branch: input.branch, targetBranch: input.targetBranch,
                    directoryName: input.directoryName, runSetupScript: false, allowRemoteBranchLookup: input.allowRemoteBranchLookup)
                if let tooltip = input.tooltip {
                    try orchestrator.updateWorkspaceTooltip(workspaceID: workspace.id, tooltip: tooltip)
                    if let updated = try orchestrator.store.workspace(id: workspace.id) { workspace = updated }
                }
                return .success(workspace)
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func createProjectSnapshot(input: ProjectCreateInput) async -> Result<ProjectRecord, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = MuxyOrchestrator(store: store)
                let record: ProjectRecord
                if let gitURL = input.gitURL {
                    record = try orchestrator.addProject(gitURL: gitURL)
                } else if let directoryPath = input.directoryPath {
                    record = try orchestrator.addProject(dir: directoryPath)
                } else {
                    throw MuxyError.invalidArgument(message: "Project source is required.")
                }
                try orchestrator.updateProjectConfig(projectID: record.id) { project in
                    project.setupScript = input.setupScript
                    project.stopScript = input.stopScript
                    project.ports = input.ports
                    project.processes = input.processes
                    project.browserSessions = input.browserSessions
                    project.statusChecks = input.statusChecks
                    project.agentLaunchers = input.agentLaunchers
                }
                return .success(record)
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func deleteProjectSnapshot(projectDirectory: String) async -> Result<Void, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = MuxyOrchestrator(store: store)
                try orchestrator.removeProject(dir: projectDirectory)
                return .success(())
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func performWindowFocusSnapshot(_ request: WindowFocusRequest) async -> Result<Void, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = MuxyOrchestrator(store: store)
                switch request {
                case .workspaceBrowserSession(let workspaceID, let targetURL):
                    try orchestrator.focusWorkspaceBrowserSession(workspaceID: workspaceID, targetURL: targetURL)
                case .workspaceWindow(let workspaceID, let index): try orchestrator.focusWorkspaceWindow(workspaceID: workspaceID, index: index)
                case .workspaceProcess(let workspaceID, let processID):
                    try orchestrator.focusWorkspaceProcess(workspaceID: workspaceID, processID: processID)
                case .workspaceMissingConfiguredProcess(let workspaceID, let processKey):
                    try orchestrator.recoverMissingConfiguredProcess(workspaceID: workspaceID, processKey: processKey)
                case .agentWindow(let record): try orchestrator.focusAgentWindow(record)
                }
                return .success(())
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func recoverMissingTrackedWindowSnapshot(_ context: MissingTrackedWindowContext) async -> Result<Void, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = MuxyOrchestrator(store: store)
                switch context.kind {
                case .browserSession:
                    guard let targetURL = context.targetURL else {
                        throw MuxyError.invalidArgument(message: "Browser recovery requires a target URL.")
                    }
                    try orchestrator.recoverMissingBrowserSession(workspaceID: context.workspaceID, targetURL: targetURL)
                case .process:
                    guard let processID = context.processID else {
                        throw MuxyError.invalidArgument(message: "Process recovery requires a process identifier.")
                    }
                    let recovered = try orchestrator.recoverRunningWorkspaceProcessIfPossible(workspaceID: context.workspaceID, processID: processID)
                    if !recovered { try orchestrator.restartWorkspaceProcess(workspaceID: context.workspaceID, processID: processID) }
                case .codingAgent, .window: throw MuxyError.invalidArgument(message: "This window cannot be recovered automatically.")
                }
                return .success(())
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func recoverRunningWorkspaceProcessIfPossibleSnapshot(_ context: MissingTrackedWindowContext) async -> Result<
        Bool, Error
    > {
        await Task.detached(priority: .userInitiated) {
            do {
                guard context.kind == .process, let processID = context.processID else {
                    throw MuxyError.invalidArgument(message: "Running-process recovery requires a process identifier.")
                }
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = MuxyOrchestrator(store: store)
                return .success(try orchestrator.recoverRunningWorkspaceProcessIfPossible(workspaceID: context.workspaceID, processID: processID))
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func launchConfiguredAgentSnapshot(workspaceID: String, name: String) async -> Result<Void, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = MuxyOrchestrator(store: store)
                _ = try orchestrator.launchAgentLauncher(workspaceID: workspaceID, name: name)
                return .success(())
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func focusWindowShortcutSnapshot(index: Int, selectedWorkspaceID: String?, dashboardFocusRequest: WindowFocusRequest?)
        async -> Result<WindowShortcutExecutionOutcome, Error>
    {
        await Task.detached(priority: .userInitiated) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = MuxyOrchestrator(store: store)

                if let dashboardFocusRequest {
                    switch dashboardFocusRequest {
                    case .workspaceBrowserSession(let workspaceID, let targetURL):
                        try orchestrator.focusWorkspaceBrowserSession(workspaceID: workspaceID, targetURL: targetURL)
                        return .success(.focused(kind: "dashboard_browser"))
                    case .workspaceWindow(let workspaceID, let index):
                        try orchestrator.focusWorkspaceWindow(workspaceID: workspaceID, index: index)
                        return .success(.focused(kind: "dashboard_window"))
                    case .workspaceProcess(let workspaceID, let processID):
                        try orchestrator.focusWorkspaceProcess(workspaceID: workspaceID, processID: processID)
                        return .success(.focused(kind: "dashboard_process"))
                    case .workspaceMissingConfiguredProcess(let workspaceID, let processKey):
                        try orchestrator.recoverMissingConfiguredProcess(workspaceID: workspaceID, processKey: processKey)
                        return .success(.opened(kind: "dashboard_process"))
                    case .agentWindow(let record):
                        try orchestrator.focusAgentWindow(record)
                        return .success(.focused(kind: "dashboard_agent"))
                    }
                }
                guard let selectedWorkspaceID else { return .success(.noWorkspace) }

                let windows = try orchestrator.windows(workspaceID: selectedWorkspaceID)
                let processes = try orchestrator.runningProcesses(workspaceID: selectedWorkspaceID)
                let agentWindows = try orchestrator.agentWindows(workspaceID: selectedWorkspaceID)
                let workspaceIsRunning = try orchestrator.store.workspace(id: selectedWorkspaceID)?.isRunning ?? false
                let browserSessions =
                    shouldShowConfiguredBrowserSessions(workspaceIsRunning: workspaceIsRunning)
                    ? try orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: selectedWorkspaceID) : []
                let workspaceSettings = try orchestrator.workspaceSettings(workspaceID: selectedWorkspaceID)
                let configuredProcesses = workspaceSettings?.processes ?? []
                let processEntries = orderedWorkspaceRunProcessEntries(
                    configuredProcesses: configuredProcesses, windows: windows, processes: processes, agentWindows: agentWindows)
                let processesByID = Dictionary(uniqueKeysWithValues: processes.map { ($0.id, $0) })
                let shortcutTargets = orderedWorkspaceRunShortcutTargets(
                    browserSessions: browserSessions, processEntries: processEntries, processesByID: processesByID,
                    configuredAgentLaunchers: workspaceSettings?.agentLaunchers ?? [], agentWindows: agentWindows)
                guard index > 0, index <= shortcutTargets.count else { return .success(.noMatch) }
                let target = shortcutTargets[index - 1]
                switch target.kind {
                case .browser:
                    guard let targetURL = target.targetURL else { return .success(.noMatch) }
                    try orchestrator.focusWorkspaceBrowserSession(workspaceID: selectedWorkspaceID, targetURL: targetURL)
                    return .success(.focused(kind: "browser"))
                case .process:
                    guard let processID = target.processID else { return .success(.noMatch) }
                    try orchestrator.focusWorkspaceProcess(workspaceID: selectedWorkspaceID, processID: processID)
                    return .success(.focused(kind: "process"))
                case .window:
                    guard let windowListIndex = target.windowListIndex else { return .success(.noMatch) }
                    try orchestrator.focusWorkspaceWindow(workspaceID: selectedWorkspaceID, index: windowListIndex + 1)
                    return .success(.focused(kind: "window"))
                case .missingConfiguredProcess:
                    guard let processKey = target.processKey else { return .success(.noMatch) }
                    try orchestrator.recoverMissingConfiguredProcess(workspaceID: selectedWorkspaceID, processKey: processKey)
                    return .success(.opened(kind: "process"))
                case .agentLauncher:
                    guard let launcherName = target.launcherName else { return .success(.noMatch) }
                    _ = try orchestrator.launchAgentLauncher(workspaceID: selectedWorkspaceID, name: launcherName)
                    return .success(.opened(kind: "agent_launcher"))
                case .agent:
                    guard let record = target.agentWindow else { return .success(.noMatch) }
                    try orchestrator.focusAgentWindow(record)
                    return .success(.focused(kind: "agent"))
                }
            } catch { return .failure(error) }
        }.value
    }

    // Browser rows stay visible even when the workspace is stopped so the Run tab
    // remains a stable launch surface for configured browser sessions.
    nonisolated static func shouldShowConfiguredBrowserSessions(workspaceIsRunning _: Bool) -> Bool { true }

    nonisolated private static func runWorkspaceSetupSnapshot(workspaceID: String) async -> Result<Void, Error> {
        await Task.detached(priority: .utility) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = MuxyOrchestrator(store: store)
                try orchestrator.runWorkspaceSetup(workspaceID: workspaceID)
                return .success(())
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func branchOptionsSnapshot(projectID: String) async -> Result<[String], Error> {
        await Task.detached(priority: .utility) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = MuxyOrchestrator(store: store)
                let options = try orchestrator.gitBranchOptions(projectID: projectID, includeLiveRemoteHeads: false)
                return .success(options)
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func runProcessMonitorSnapshot() async -> Result<Bool, Error> {
        await Task.detached(priority: .utility) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = MuxyOrchestrator(store: store)
                let didUpdateProcessStates = try orchestrator.checkAndUpdateProcessStatuses()
                let didRunStatusChecks = try orchestrator.runDueStatusChecksForRunningWorkspaces()
                return .success(didUpdateProcessStates || didRunStatusChecks)
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func runWorktreeDiscoverySnapshot() async -> Result<Int, Error> {
        await Task.detached(priority: .utility) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = MuxyOrchestrator(store: store)
                let created = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: nil)
                return .success(created.count)
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func buildDashboardGroupsSnapshot(
        orchestrator: MuxyOrchestrator, projects: [ProjectSummary], workspacesByProject: [String: [WorkspaceSummary]]
    ) throws -> [DashboardGroup] {
        let iso8601Formatter = ISO8601DateFormatter()
        var groups: [DashboardGroup] = []
        for project in projects {
            let workspaces = workspacesByProject[project.id] ?? []
            for workspace in workspaces {
                let agentWindowsList = (try? orchestrator.agentWindows(workspaceID: workspace.id)) ?? []
                let attentionAgentWindows = dashboardAttentionAgentWindows(agentWindowsList)
                guard workspace.isRunning || !attentionAgentWindows.isEmpty else { continue }

                let processes = workspace.isRunning ? ((try? orchestrator.runningProcesses(workspaceID: workspace.id)) ?? []) : []
                let windows = workspace.isRunning ? ((try? orchestrator.windows(workspaceID: workspace.id)) ?? []) : []
                let configuredProcesses =
                    workspace.isRunning ? ((try? orchestrator.workspaceSettings(workspaceID: workspace.id)?.processes) ?? []) : []
                let configuredSessions: [BrowserSession] = {
                    guard workspace.isRunning else { return [] }
                    return (try? orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspace.id)) ?? []
                }()
                let processEntries = orderedWorkspaceRunProcessEntries(
                    configuredProcesses: configuredProcesses, windows: windows, processes: processes, agentWindows: agentWindowsList)
                var processByWindowID: [Int: RunningProcessRecord] = [:]
                for process in processes { if let wid = process.windowID { processByWindowID[wid] = process } }
                var statusResultsByProcessID: [String: [StatusResult]] = [:]
                for process in processes { statusResultsByProcessID[process.id] = (try? orchestrator.statusResults(processID: process.id)) ?? [] }

                var items: [DashboardAttentionEntry] = []
                var matchedProcessIDs: Set<String> = []

                for (idx, win) in windows.enumerated() {
                    guard let wid = win.windowID, let process = processByWindowID[wid] else { continue }
                    matchedProcessIDs.insert(process.id)
                    let allChecks = statusResultsByProcessID[process.id] ?? []
                    let hasFailedCheck = allChecks.contains { $0.status == .failed }
                    guard process.status == .exited || hasFailedCheck else { continue }
                    let icon: String
                    let iconTint: DashboardIconTint
                    let label: String
                    let detail: String?
                    switch win.role {
                    case "browser":
                        icon = "globe"
                        iconTint = .browser
                        if let name = Self.browserSessionDisplayName(for: win.targetURL, sessions: configuredSessions), let url = win.targetURL {
                            label = name
                            detail = url
                        } else {
                            label = win.name ?? win.targetURL ?? win.app
                            detail = win.detail
                        }
                    case "terminal":
                        icon = "terminal"
                        iconTint = .terminal
                        label = process.templateName
                        detail = process.command
                    default:
                        icon = "chevron.left.forwardslash.chevron.right"
                        iconTint = .code
                        label = win.name ?? win.app
                        detail = win.detail
                    }
                    let redChecks = allChecks.filter { $0.status == .failed }
                    let eventDate: Date? =
                        process.status == .exited
                        ? process.exitedAt.flatMap { iso8601Formatter.date(from: $0) }
                        : redChecks.compactMap { $0.lastRunAt.flatMap { iso8601Formatter.date(from: $0) } }.max()
                    items.append(
                        DashboardAttentionEntry(
                            attentionID: Self.dashboardAttentionID(process: process, failedChecks: redChecks), icon: icon, iconTint: iconTint,
                            label: label, detail: detail, shortcut: "", processStatus: process.status, agentStatus: nil, countsTowardBadge: true,
                            statusChecks: allChecks, eventDate: eventDate,
                            focusRequest: Self.dashboardFocusRequest(
                                window: win, windowListIndex: idx + 1, process: process, workspaceID: workspace.id)))
                }

                for process in processes where !matchedProcessIDs.contains(process.id) {
                    let allChecks = statusResultsByProcessID[process.id] ?? []
                    let hasFailedCheck = allChecks.contains { $0.status == .failed }
                    guard process.status == .exited || hasFailedCheck else { continue }
                    let redChecks = allChecks.filter { $0.status == .failed }
                    let eventDate: Date? =
                        process.status == .exited
                        ? process.exitedAt.flatMap { iso8601Formatter.date(from: $0) }
                        : redChecks.compactMap { $0.lastRunAt.flatMap { iso8601Formatter.date(from: $0) } }.max()
                    items.append(
                        DashboardAttentionEntry(
                            attentionID: Self.dashboardAttentionID(process: process, failedChecks: redChecks), icon: "terminal", iconTint: .terminal,
                            label: process.templateName, detail: process.command, shortcut: "", processStatus: process.status, agentStatus: nil,
                            countsTowardBadge: true, statusChecks: allChecks, eventDate: eventDate,
                            focusRequest: .workspaceProcess(workspaceID: workspace.id, processID: process.id)))
                }

                for item in dashboardMissingConfiguredProcessItems(workspaceID: workspace.id, processEntries: processEntries) {
                    items.append(
                        DashboardAttentionEntry(
                            attentionID: item.attentionID, icon: "terminal", iconTint: .warning, label: item.label, detail: item.detail, shortcut: "",
                            processStatus: .idle, agentStatus: nil, countsTowardBadge: true, statusChecks: [], eventDate: nil,
                            focusRequest: .workspaceMissingConfiguredProcess(workspaceID: workspace.id, processKey: item.processKey)))
                }

                for agentWin in attentionAgentWindows {
                    items.append(
                        DashboardAttentionEntry(
                            attentionID: Self.dashboardAttentionID(agentWindow: agentWin), icon: "cpu.fill", iconTint: .warning,
                            label: agentWin.label ?? "Coding Agent CLI", detail: nil, shortcut: "", processStatus: nil, agentStatus: agentWin.status,
                            countsTowardBadge: true, statusChecks: [], eventDate: iso8601Formatter.date(from: agentWin.updatedAt),
                            focusRequest: .agentWindow(agentWin)))
                }

                guard !items.isEmpty else { continue }

                items.sort {
                    switch ($0.eventDate, $1.eventDate) {
                    case (let a?, let b?): return a > b
                    case (nil, _): return false
                    case (_, nil): return true
                    }
                }
                groups.append(DashboardGroup(projectName: project.name, workspaceID: workspace.id, workspaceName: workspace.title, items: items))
            }
        }
        groups.sort {
            switch ($0.latestDate, $1.latestDate) {
            case (let a?, let b?): return a > b
            case (nil, _): return false
            case (_, nil): return true
            }
        }
        return groups
    }

    nonisolated private static func initialSidebarDataSnapshot() async -> Result<SidebarDataSnapshot, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let snapshotStartedAt = ProcessInfo.processInfo.systemUptime
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = MuxyOrchestrator(store: store)
                logStartupSnapshotProfile("sidebar_snapshot_store_ready")
                let config = try orchestrator.syncConfig()
                logStartupSnapshotProfile("sidebar_snapshot_config_ready")
                let projects = try orchestrator.listProjects()
                logStartupSnapshotProfile("sidebar_snapshot_projects_ready", details: "project_count=\(projects.count)")
                var workspacesByProject: [String: [WorkspaceSummary]] = [:]
                var workspaceRuntimeStatusByID: [String: WorkspaceRuntimeStatus] = [:]
                var workspaceCount = 0
                let workspaceScanStartedAt = ProcessInfo.processInfo.systemUptime
                var listWorkspacesMS = 0
                var runtimeStatusMS = 0
                for project in projects {
                    let listStartedAt = ProcessInfo.processInfo.systemUptime
                    let workspaces = try orchestrator.listWorkspaces(projectID: project.id, includeArchived: false)
                    listWorkspacesMS += Int((ProcessInfo.processInfo.systemUptime - listStartedAt) * 1000)
                    workspacesByProject[project.id] = workspaces
                    for workspace in workspaces {
                        workspaceCount += 1
                        let runtimeStatusStartedAt = ProcessInfo.processInfo.systemUptime
                        workspaceRuntimeStatusByID[workspace.id] = try orchestrator.workspaceRuntimeStatus(workspaceID: workspace.id)
                        runtimeStatusMS += Int((ProcessInfo.processInfo.systemUptime - runtimeStatusStartedAt) * 1000)
                    }
                }
                let workspaceScanMS = Int((ProcessInfo.processInfo.systemUptime - workspaceScanStartedAt) * 1000)
                logStartupSnapshotProfile(
                    "sidebar_snapshot_workspace_scan_breakdown",
                    details:
                        "workspace_count=\(workspaceCount) list_ms=\(listWorkspacesMS) runtime_ms=\(runtimeStatusMS) git_ms=0 unaccounted_ms=\(workspaceScanMS - listWorkspacesMS - runtimeStatusMS)"
                )
                logStartupSnapshotProfile(
                    "sidebar_snapshot_workspace_scan_ready", details: "workspace_count=\(workspaceCount) scan_ms=\(workspaceScanMS)")
                let dashboardGroups = try buildDashboardGroupsSnapshot(
                    orchestrator: orchestrator, projects: projects, workspacesByProject: workspacesByProject)
                logStartupSnapshotProfile(
                    "sidebar_snapshot_dashboard_ready",
                    details: "group_count=\(dashboardGroups.count) item_count=\(dashboardGroups.reduce(0) { $0 + $1.items.count })")
                logStartupSnapshotProfile(
                    "sidebar_snapshot_complete", details: "total_ms=\(Int((ProcessInfo.processInfo.systemUptime - snapshotStartedAt) * 1000))")
                return .success(
                    .init(
                        config: config, projects: projects, workspacesByProject: workspacesByProject,
                        workspaceRuntimeStatusByID: workspaceRuntimeStatusByID, dashboardGroups: dashboardGroups))
            } catch { return .failure(error) }
        }.value
    }

    nonisolated static func shouldHideAfterSuccessfulExternalWindowAction(_ succeeded: Bool, action: ExternalWindowAction) -> Bool {
        guard succeeded else { return false }
        switch action {
        case .focus, .open: return true
        }
    }

    nonisolated static func hideDelayAfterSuccessfulExternalWindowAction(_ succeeded: Bool, action: ExternalWindowAction) -> Duration? {
        guard shouldHideAfterSuccessfulExternalWindowAction(succeeded, action: action) else { return nil }
        switch action {
        case .focus: return .milliseconds(400)
        case .open: return nil
        }
    }

    nonisolated static func shouldRefreshVisibleWorkspaceDetail(
        selectedWorkspaceID: String?, showingDashboard: Bool, showingSettings: Bool, workspaceExists: Bool
    ) -> Bool {
        guard selectedWorkspaceID != nil else { return false }
        guard !showingDashboard, !showingSettings else { return false }
        return workspaceExists
    }

    struct WorkspaceRunProcessEntry: Sendable {
        enum Kind: Sendable, Equatable {
            case process
            case window
            case missingConfiguredProcess
        }

        let kind: Kind
        let processID: String?
        let windowListIndex: Int?
        let processKey: String?
        let processLabel: String?
        let processCommand: String?
    }

    struct WorkspaceRunShortcutTarget: Sendable {
        enum Kind: String, Sendable, Equatable {
            case browser
            case process
            case window
            case missingConfiguredProcess
            case agentLauncher
            case agent
        }

        let kind: Kind
        let processID: String?
        let windowListIndex: Int?
        let targetURL: String?
        let processKey: String?
        let launcherName: String?
        let agentWindow: AgentWindowRecord?
    }

    struct WorkspaceDetailShortcutIndices: Sendable {
        let browserSessionsByURL: [String: Int]
        let processesByName: [String: Int]
        let codingAgentsByName: [String: Int]
    }

    struct ResolvedCodingAgentRunEntry: Sendable {
        let launcher: AgentLauncher?
        let agentWindow: AgentWindowRecord?

        var launcherName: String? { launcher?.name }

        var kind: WorkspaceRunShortcutTarget.Kind {
            if agentWindow != nil { return .agent }
            return .agentLauncher
        }
    }

    enum RunningWorkspaceProcessEditDecision: Equatable, Sendable {
        case applyImmediately
        case confirmRestart(processNames: [String])
    }

    nonisolated static func processTemplateKey(for template: ProcessTemplate) -> String {
        template.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated static func runningWorkspaceProcessEditDecision(previous: [ProcessTemplate], updated: [ProcessTemplate])
        -> RunningWorkspaceProcessEditDecision
    {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let changedProcessNames = updated.compactMap { updatedTemplate -> String? in
            guard let previousTemplate = previousByID[updatedTemplate.id], previousTemplate.command != updatedTemplate.command else { return nil }
            let trimmedUpdatedName = updatedTemplate.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedUpdatedName.isEmpty { return trimmedUpdatedName }
            let trimmedPreviousName = previousTemplate.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedPreviousName.isEmpty { return trimmedPreviousName }
            return "Process"
        }
        if changedProcessNames.isEmpty { return .applyImmediately }
        return .confirmRestart(processNames: changedProcessNames)
    }

    // Configured-process rows match live runtime rows by the raw configured name.
    nonisolated static func processRuntimeKey(name: String) -> String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    nonisolated static func normalizedRunRowName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    nonisolated static func automationIdentifierSlug(_ value: String) -> String {
        let lowercased = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let slug = lowercased.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    nonisolated static func resolvedCodingAgentRunEntries(configuredAgentLaunchers: [AgentLauncher], agentWindows: [AgentWindowRecord])
        -> [ResolvedCodingAgentRunEntry]
    {
        let configuredAgentNames = Set(configuredAgentLaunchers.map(\.name).map(normalizedRunRowName).filter { !$0.isEmpty })
        var entries: [ResolvedCodingAgentRunEntry] = []

        // Configured coding agents always own the first slots in the Coding Agents
        // section. If a live agent matches one of those names, the slot resolves to
        // that agent; otherwise the slot stays launchable from the config row.
        for launcher in configuredAgentLaunchers {
            let normalizedName = normalizedRunRowName(launcher.name)
            guard !normalizedName.isEmpty else { continue }
            let matchedAgent = agentWindows.first(where: { normalizedRunRowName($0.label ?? "") == normalizedName })
            entries.append(ResolvedCodingAgentRunEntry(launcher: launcher, agentWindow: matchedAgent))
        }

        for agentWindow in agentWindows {
            guard !configuredAgentNames.contains(normalizedRunRowName(agentWindow.label ?? "")) else { continue }
            entries.append(ResolvedCodingAgentRunEntry(launcher: nil, agentWindow: agentWindow))
        }

        return entries
    }

    nonisolated static func agentTerminalTrackingKeys(for record: AgentWindowRecord) -> Set<String> {
        var keys = Set<String>()
        if let trackingKey = record.terminalTrackingKey, !trackingKey.isEmpty { keys.insert(trackingKey) }
        if record.provider == .ghostty, let sessionID = record.terminalTrackingID, !sessionID.isEmpty {
            keys.insert(TerminalTrackingIdentity.session(sessionID).trackingKey)
        }
        return keys
    }

    nonisolated static func preferredTerminalWindowsByTrackingKey(_ windows: [WindowRecord]) -> [String: WindowRecord] {
        windows.reduce(into: [:]) { result, window in
            guard window.role == "terminal", let trackingKey = window.terminalTrackingKey else { return }
            // Duplicate keys can exist transiently while Ghostty rows are being reconciled.
            // Prefer the earliest ordered tracked window instead of crashing on duplicates.
            let existingOrder = result[trackingKey]?.orderIndex ?? Int.max
            if window.orderIndex <= existingOrder { result[trackingKey] = window }
        }
    }

    nonisolated static func orderedWorkspaceRunProcessEntries(
        configuredProcesses: [ProcessTemplate], windows: [WindowRecord], processes: [RunningProcessRecord], agentWindows: [AgentWindowRecord]
    ) -> [WorkspaceRunProcessEntry] {
        let terminalOrderByTargetID: [String: Int] = windows.reduce(into: [:]) { result, window in
            guard window.role == "terminal", let targetID = window.terminalTrackingKey else { return }
            let existingOrder = result[targetID] ?? Int.max
            result[targetID] = min(existingOrder, window.orderIndex)
        }
        let processesByTerminalID: [String: [RunningProcessRecord]] = {
            var map: [String: [RunningProcessRecord]] = [:]
            for process in processes {
                guard let targetID = process.terminalTrackingKey else { continue }
                map[targetID, default: []].append(process)
            }
            for (targetID, list) in map {
                map[targetID] = list.sorted { lhs, rhs in
                    let lhsOrder = lhs.terminalTrackingKey.flatMap { terminalOrderByTargetID[$0] } ?? Int.max
                    let rhsOrder = rhs.terminalTrackingKey.flatMap { terminalOrderByTargetID[$0] } ?? Int.max
                    if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                    return lhs.templateName.localizedStandardCompare(rhs.templateName) == .orderedAscending
                }
            }
            return map
        }()
        let agentTerminalIDs = Set(agentWindows.flatMap { agentTerminalTrackingKeys(for: $0) })
        let eligibleProcesses = processes.filter { process in process.terminalTrackingKey.map { !agentTerminalIDs.contains($0) } != false }
        let agentClaimedProcessKeys = Set(
            processes.filter { process in process.terminalTrackingKey.map(agentTerminalIDs.contains) ?? false }.map {
                processRuntimeKey(name: $0.templateName)
            })
        var processQueuesByKey: [String: [RunningProcessRecord]] = [:]
        for process in eligibleProcesses { processQueuesByKey[processRuntimeKey(name: process.templateName), default: []].append(process) }
        for (key, list) in processQueuesByKey {
            processQueuesByKey[key] = list.sorted { lhs, rhs in
                let lhsOrder = lhs.terminalTrackingKey.flatMap { terminalOrderByTargetID[$0] } ?? Int.max
                let rhsOrder = rhs.terminalTrackingKey.flatMap { terminalOrderByTargetID[$0] } ?? Int.max
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                return lhs.templateName.localizedStandardCompare(rhs.templateName) == .orderedAscending
            }
        }

        var entries: [WorkspaceRunProcessEntry] = []
        var matchedProcessIDs = Set<String>()
        for template in configuredProcesses {
            let key = processTemplateKey(for: template)
            guard !key.isEmpty else { continue }
            guard var queue = processQueuesByKey[key], let process = queue.first else {
                if agentClaimedProcessKeys.contains(key) { continue }
                entries.append(
                    WorkspaceRunProcessEntry(
                        kind: .missingConfiguredProcess, processID: nil, windowListIndex: nil, processKey: key, processLabel: key,
                        processCommand: template.command))
                continue
            }
            queue.removeFirst()
            processQueuesByKey[key] = queue.isEmpty ? nil : queue
            matchedProcessIDs.insert(process.id)
            entries.append(
                WorkspaceRunProcessEntry(
                    kind: .process, processID: process.id, windowListIndex: nil, processKey: key, processLabel: process.templateName,
                    processCommand: process.command))
        }

        for (windowIdx, window) in windows.enumerated() where window.role != "browser" {
            let windowProcesses = (window.role == "terminal" ? (window.terminalTrackingKey.flatMap { processesByTerminalID[$0] }) : nil) ?? []
            let isAgentClaimedWindow = window.terminalTrackingKey.map(agentTerminalIDs.contains) ?? false
            let nonAgentWindowProcesses = windowProcesses.filter { process in
                guard let terminalID = process.terminalTrackingKey else { return true }
                return !agentTerminalIDs.contains(terminalID)
            }
            if isAgentClaimedWindow && (window.role != "terminal" || windowProcesses.isEmpty) { continue }
            if window.role == "terminal", !nonAgentWindowProcesses.isEmpty {
                for process in nonAgentWindowProcesses where !matchedProcessIDs.contains(process.id) {
                    matchedProcessIDs.insert(process.id)
                    entries.append(
                        WorkspaceRunProcessEntry(
                            kind: .process, processID: process.id, windowListIndex: nil, processKey: processRuntimeKey(name: process.templateName),
                            processLabel: process.templateName, processCommand: process.command))
                }
                continue
            }
            if !isAgentClaimedWindow {
                entries.append(
                    WorkspaceRunProcessEntry(
                        kind: .window, processID: nil, windowListIndex: windowIdx, processKey: nil, processLabel: nil, processCommand: nil))
            }
        }

        for process in eligibleProcesses where !matchedProcessIDs.contains(process.id) {
            matchedProcessIDs.insert(process.id)
            entries.append(
                WorkspaceRunProcessEntry(
                    kind: .process, processID: process.id, windowListIndex: nil, processKey: processRuntimeKey(name: process.templateName),
                    processLabel: process.templateName, processCommand: process.command))
        }
        return entries
    }

    nonisolated static func orderedWorkspaceRunShortcutTargets(
        browserSessions: [BrowserSession], processEntries: [WorkspaceRunProcessEntry], processesByID: [String: RunningProcessRecord],
        configuredAgentLaunchers: [AgentLauncher], agentWindows: [AgentWindowRecord]
    ) -> [WorkspaceRunShortcutTarget] {
        var targets: [WorkspaceRunShortcutTarget] = []

        for session in browserSessions {
            guard let targetURL = session.url, !targetURL.isEmpty else { continue }
            targets.append(
                WorkspaceRunShortcutTarget(
                    kind: .browser, processID: nil, windowListIndex: nil, targetURL: targetURL, processKey: nil, launcherName: nil, agentWindow: nil))
        }

        for entry in processEntries {
            switch entry.kind {
            case .process:
                guard let processID = entry.processID, processesByID[processID] != nil else { continue }
                targets.append(
                    WorkspaceRunShortcutTarget(
                        kind: .process, processID: processID, windowListIndex: nil, targetURL: nil, processKey: nil, launcherName: nil,
                        agentWindow: nil))
            case .window:
                guard let windowListIndex = entry.windowListIndex else { continue }
                targets.append(
                    WorkspaceRunShortcutTarget(
                        kind: .window, processID: nil, windowListIndex: windowListIndex, targetURL: nil, processKey: nil, launcherName: nil,
                        agentWindow: nil))
            case .missingConfiguredProcess:
                guard let processKey = entry.processKey else { continue }
                targets.append(
                    WorkspaceRunShortcutTarget(
                        kind: .missingConfiguredProcess, processID: nil, windowListIndex: nil, targetURL: nil, processKey: processKey,
                        launcherName: nil, agentWindow: nil))
            }
        }

        for entry in resolvedCodingAgentRunEntries(configuredAgentLaunchers: configuredAgentLaunchers, agentWindows: agentWindows) {
            targets.append(
                WorkspaceRunShortcutTarget(
                    kind: entry.kind, processID: nil, windowListIndex: nil, targetURL: nil, processKey: nil,
                    launcherName: entry.agentWindow == nil ? entry.launcherName : nil, agentWindow: entry.agentWindow))
        }

        return targets
    }

    nonisolated static func workspaceDetailShortcutIndices(
        browserSessions: [BrowserSession], processEntries: [WorkspaceRunProcessEntry], processesByID: [String: RunningProcessRecord],
        configuredAgentLaunchers: [AgentLauncher], agentWindows: [AgentWindowRecord]
    ) -> WorkspaceDetailShortcutIndices {
        let targets = orderedWorkspaceRunShortcutTargets(
            browserSessions: browserSessions, processEntries: processEntries, processesByID: processesByID,
            configuredAgentLaunchers: configuredAgentLaunchers, agentWindows: agentWindows)

        var browserSessionsByURL: [String: Int] = [:]
        var processesByName: [String: Int] = [:]
        var codingAgentsByName: [String: Int] = [:]

        for (offset, target) in targets.enumerated() {
            let index = offset + 1
            switch target.kind {
            case .browser: if let targetURL = target.targetURL, !targetURL.isEmpty { browserSessionsByURL[targetURL] = index }
            case .process:
                if let processID = target.processID, let process = processesByID[processID] { processesByName[process.templateName] = index }
            case .missingConfiguredProcess: if let processKey = target.processKey, !processKey.isEmpty { processesByName[processKey] = index }
            case .agentLauncher: if let launcherName = target.launcherName, !launcherName.isEmpty { codingAgentsByName[launcherName] = index }
            case .agent: if let label = target.agentWindow?.label, !label.isEmpty { codingAgentsByName[label] = index }
            case .window: break
            }
        }

        return WorkspaceDetailShortcutIndices(
            browserSessionsByURL: browserSessionsByURL, processesByName: processesByName, codingAgentsByName: codingAgentsByName)
    }

    nonisolated static func workspaceProcessStatusByName(_ processes: [RunningProcessRecord]) -> [String: RowPrimitives.StatusKind] {
        func statusKind(for status: RunningProcessState) -> RowPrimitives.StatusKind {
            switch status {
            case .running: return .running
            case .exited: return .exited
            case .idle: return .idle
            }
        }

        func priority(for status: RowPrimitives.StatusKind) -> Int {
            switch status {
            case .running: return 2
            case .exited: return 1
            case .idle, .waiting: return 0
            }
        }

        return processes.reduce(into: [:]) { result, process in
            let next = statusKind(for: process.status)
            let current = result[process.templateName] ?? .idle
            if priority(for: next) >= priority(for: current) { result[process.templateName] = next }
        }
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Muxy")
        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdatesMenuAction(_:)), keyEquivalent: "")
        updateItem.target = self
        checkForUpdatesMenuItem = updateItem
        appMenu.addItem(updateItem)
        let versionItem = NSMenuItem(title: "Version \(AppVersion.current)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        appMenu.addItem(versionItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Muxy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    /// Creates and shows the NSWindow shell (size, title, center, delegate, makeKeyAndOrderFront) without setting content.
    private func buildShellWindow() {
        let rect = NSRect(x: 200, y: 200, width: 1100, height: 700)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.title = "Muxy"
        window.center()
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
    }

    /// Builds the split view layout + footer and sets it as window.contentView.
    private func buildMainWindowContent() {
        let splitView = NSSplitView()
        splitView.dividerStyle = .thin
        splitView.isVertical = true
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.delegate = self
        self.splitView = splitView

        let leftPane = makeLeftPane()
        let rightPane = makeRightPane()

        splitView.addArrangedSubview(leftPane)
        splitView.addArrangedSubview(rightPane)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        let footerRow = workspaceDetailShortcutFooterRow()
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(splitView)
        content.addSubview(footerSeparator)
        content.addSubview(footerRow)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor), splitView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: content.topAnchor), splitView.bottomAnchor.constraint(equalTo: footerSeparator.topAnchor),
            footerSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footerSeparator.bottomAnchor.constraint(equalTo: footerRow.topAnchor),
            footerRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            footerRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            footerRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6), footerRow.heightAnchor.constraint(equalToConstant: 28),
        ])
        refreshWorkspaceShortcutFooterRow()
        window.contentView = content
    }

    private func makeLeftPane() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = sidebarPanelBackgroundColor().cgColor

        let topBarRow = makeSidebarTopBarRow()
        topBarRow.translatesAutoresizingMaskIntoConstraints = false

        let dashboardRow = makeDashboardSidebarRow()
        dashboardRow.translatesAutoresizingMaskIntoConstraints = false
        dashboardRowView = dashboardRow

        let sectionHeader = sidebarSectionHeader(
            title: "Projects", actions: [(symbol: "plus", tooltip: "New project", action: #selector(addProject))])
        sectionHeader.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        if outlineView.tableColumns.isEmpty {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
            column.title = "Projects"
            outlineView.addTableColumn(column)
            outlineView.outlineTableColumn = column
        } else if outlineView.outlineTableColumn == nil {
            outlineView.outlineTableColumn = outlineView.tableColumns.first
        }
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .medium
        outlineView.style = .plain
        outlineView.selectionHighlightStyle = .none
        outlineView.backgroundColor = .clear
        outlineView.indentationPerLevel = 0
        outlineView.onRowMouseDown = { [weak self] row in
            guard let self, let ref = self.outlineView.item(atRow: row) as? OutlineItemRef else { return false }
            if case .project(let project) = ref.item {
                self.toggleProjectExpanded(projectID: project.id)
                return true
            }
            if case .hiddenWorkspaces = ref.item {
                self.toggleHiddenWorkspacesExpanded()
                return true
            }
            return false
        }
        outlineView.onArrowNavigation = { [weak self] direction in self?.navigateSidebarSelection(direction: direction) ?? false }
        outlineView.delegate = self
        outlineView.dataSource = self

        scroll.documentView = outlineView

        container.addSubview(topBarRow)
        container.addSubview(dashboardRow)
        container.addSubview(sectionHeader)
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            topBarRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            topBarRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            topBarRow.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),

            dashboardRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            dashboardRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            dashboardRow.topAnchor.constraint(equalTo: topBarRow.bottomAnchor, constant: 8),

            sectionHeader.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            sectionHeader.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            sectionHeader.topAnchor.constraint(equalTo: dashboardRow.bottomAnchor, constant: 10),

            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: sectionHeader.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    private func makeSidebarTopBarRow() -> NSView {
        let row = NSView()

        let iconView = NSImageView()
        if let appIcon = NSApp.applicationIconImage.copy() as? NSImage {
            appIcon.size = NSSize(width: 18, height: 18)
            iconView.image = appIcon
        } else {
            iconView.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "Muxy")
            iconView.contentTintColor = sidebarRunningIndicatorColor()
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([iconView.widthAnchor.constraint(equalToConstant: 18), iconView.heightAnchor.constraint(equalToConstant: 18)])

        let settingsButton = sidebarRowIconButton(symbol: "gearshape", tooltip: "User settings", action: #selector(showSettings))
        let reloadButton = sidebarRowIconButton(symbol: "arrow.clockwise", tooltip: "Reload", action: #selector(reloadTapped))

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(NSView())
        stack.addArrangedSubview(settingsButton)
        stack.addArrangedSubview(reloadButton)

        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor), stack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            stack.topAnchor.constraint(equalTo: row.topAnchor), stack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }

    private func makeDashboardSidebarRow() -> NSView {
        let row = NSView()
        row.setAccessibilityIdentifier("sidebar-dashboard")

        let titleLabel = NSTextField(labelWithString: "Dashboard")
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor

        let hintLabel = NSTextField(labelWithString: footerShortcutHint(for: .guiDashboardShortcut))
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
        dashboardRowBadge = badge

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
        dashboardRowStack = stack

        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor), stack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            stack.topAnchor.constraint(equalTo: row.topAnchor), stack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(dashboardRowClicked))
        row.addGestureRecognizer(click)
        return row
    }

    @objc private func dashboardRowClicked() { showDashboardDetail() }

    private func updateDashboardRowAppearance() {
        guard let stack = dashboardRowStack else { return }
        if showingDashboard {
            stack.layer?.backgroundColor = sidebarSelectedCardBackgroundColor().cgColor
        } else {
            stack.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    // MARK: - Dashboard content

    private func buildDashboardGroups() -> [DashboardGroup] {
        dashboardGroups.compactMap { group in
            let items = group.items.filter { !dismissedDashboardAttentionItemIDs.contains($0.attentionID) }
            guard !items.isEmpty else { return nil }
            return DashboardGroup(projectName: group.projectName, workspaceID: group.workspaceID, workspaceName: group.workspaceName, items: items)
        }
    }

    private func dashboardAttentionCount() -> Int {
        buildDashboardGroups().reduce(0) { total, group in total + group.items.filter(\.countsTowardBadge).count }
    }

    private func loadDashboardDismissedAttentionItemIDs() {
        dismissedDashboardAttentionItemIDs = (try? orchestrator.dashboardDismissedAttentionItemIDs()) ?? []
    }

    private func pruneDismissedDashboardAttentionItemIDsIfNeeded() {
        let activeIDs = Set(dashboardGroups.flatMap { $0.items.map(\.attentionID) })
        let prunedIDs = dismissedDashboardAttentionItemIDs.intersection(activeIDs)
        guard prunedIDs != dismissedDashboardAttentionItemIDs else { return }
        dismissedDashboardAttentionItemIDs = prunedIDs
        do { try orchestrator.setDashboardDismissedAttentionItemIDs(prunedIDs) } catch { showError(error) }
    }

    private func dismissDashboardAttentionItem(_ attentionID: String) {
        guard !dismissedDashboardAttentionItemIDs.contains(attentionID) else { return }
        dismissedDashboardAttentionItemIDs.insert(attentionID)
        do {
            try orchestrator.setDashboardDismissedAttentionItemIDs(dismissedDashboardAttentionItemIDs)
            updateDashboardSidebarBadge()
            if showingDashboard { showDashboardDetail() }
        } catch {
            dismissedDashboardAttentionItemIDs.remove(attentionID)
            showError(error)
        }
    }

    private func showDashboardDetail() {
        clearInlineWorkspaceFieldRefs()
        activeAddWorkspaceFormTag = nil
        activeAddProjectFormTag = nil
        visibleDetailWorkspaceID = nil
        showingSettings = false
        showingDashboard = true
        let previousProjectID = selectedProjectID
        let previousWorkspaceID = selectedWorkspaceID
        selectedProjectID = nil
        selectedWorkspaceID = nil
        dashboardFocusRequestMap = [:]
        outlineView.deselectAll(nil)
        // Reload only the previously-selected workspace row to clear its selection styling;
        // avoid full reloadData() which would reset expand/collapse state.
        refreshSidebarSelectionRows(
            previousProjectID: previousProjectID, currentProjectID: nil, previousWorkspaceID: previousWorkspaceID, currentWorkspaceID: nil)
        updateDashboardRowAppearance()

        for view in detailContainer.subviews { view.removeFromSuperview() }
        detailContainer.wantsLayer = true
        detailContainer.layer?.backgroundColor = sidebarPanelBackgroundColor().cgColor

        let groups = buildDashboardGroups()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Header
        let accentColor = sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
        let headerTitle = NSTextField(labelWithString: "Dashboard")
        headerTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        headerTitle.textColor = sidebarPrimaryTextColor(isSelected: false, isArchived: false)

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.addArrangedSubview(headerTitle)

        stack.addArrangedSubview(headerRow)
        constrainFormFieldToFillWidth(headerRow, in: stack)

        if groups.isEmpty {
            let sep = NSView()
            sep.translatesAutoresizingMaskIntoConstraints = false
            sep.wantsLayer = true
            sep.layer?.backgroundColor = sidebarCardBorderColor(isSelected: false).cgColor
            sep.heightAnchor.constraint(equalToConstant: 1).isActive = true
            stack.addArrangedSubview(sep)
            constrainFormFieldToFillWidth(sep, in: stack)

            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "All clear")
            icon.contentTintColor = sidebarRunningIndicatorColor()
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28)])
            let emptyTitle = NSTextField(labelWithString: "No attention required")
            emptyTitle.font = .systemFont(ofSize: 13, weight: .medium)
            emptyTitle.textColor = .labelColor
            let emptyDetail = NSTextField(labelWithString: "All running workspaces are healthy.")
            emptyDetail.font = .systemFont(ofSize: 11)
            emptyDetail.textColor = .secondaryLabelColor
            let emptyStack = NSStackView()
            emptyStack.orientation = .vertical
            emptyStack.alignment = .centerX
            emptyStack.spacing = 6
            emptyStack.translatesAutoresizingMaskIntoConstraints = false
            emptyStack.addArrangedSubview(icon)
            emptyStack.addArrangedSubview(emptyTitle)
            emptyStack.addArrangedSubview(emptyDetail)
            stack.addArrangedSubview(emptyStack)
            constrainFormFieldToFillWidth(emptyStack, in: stack)
        } else {
            // Sequential window shortcut counter across all groups and items.
            var shortcutCounter = 1

            for group in groups {
                // Workspace group header
                let groupHeaderStack = NSStackView()
                groupHeaderStack.orientation = .horizontal
                groupHeaderStack.alignment = .centerY
                groupHeaderStack.spacing = 4
                groupHeaderStack.translatesAutoresizingMaskIntoConstraints = false

                let projectLabel = NSTextField(labelWithString: group.projectName)
                projectLabel.font = .systemFont(ofSize: 12, weight: .semibold)
                projectLabel.textColor = .secondaryLabelColor
                projectLabel.setContentHuggingPriority(.required, for: .horizontal)

                let slashLabel = NSTextField(labelWithString: "/")
                slashLabel.font = .systemFont(ofSize: 12)
                slashLabel.textColor = .tertiaryLabelColor
                slashLabel.setContentHuggingPriority(.required, for: .horizontal)

                let workspaceLabel = NSTextField(labelWithString: group.workspaceName)
                workspaceLabel.font = .systemFont(ofSize: 12, weight: .semibold)
                workspaceLabel.textColor = accentColor
                workspaceLabel.lineBreakMode = .byTruncatingTail
                workspaceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

                groupHeaderStack.addArrangedSubview(projectLabel)
                groupHeaderStack.addArrangedSubview(slashLabel)
                groupHeaderStack.addArrangedSubview(workspaceLabel)
                stack.addArrangedSubview(groupHeaderStack)
                constrainFormFieldToFillWidth(groupHeaderStack, in: stack)

                let itemsStack = NSStackView()
                itemsStack.orientation = .vertical
                itemsStack.spacing = 4
                itemsStack.translatesAutoresizingMaskIntoConstraints = false

                for entry in group.items {
                    let shortcut = shortcutCounter <= 9 ? windowShortcutBadgeText(index: shortcutCounter) : ""
                    if shortcutCounter <= 9, let focusRequest = entry.focusRequest { dashboardFocusRequestMap[shortcutCounter] = focusRequest }
                    shortcutCounter += 1
                    let cardAction: (() async -> Void)?
                    if let focusRequest = entry.focusRequest {
                        cardAction = { [weak self] in
                            guard let self else { return }
                            await self.performWindowFocus(focusRequest)
                        }
                    } else {
                        cardAction = nil
                    }
                    let card = dashboardWindowCard(entry: entry, shortcut: shortcut, action: cardAction)
                    itemsStack.addArrangedSubview(card)
                    constrainFormFieldToFillWidth(card, in: itemsStack)
                }

                stack.addArrangedSubview(itemsStack)
                constrainFormFieldToFillWidth(itemsStack, in: stack)
            }
        }

        showScrollableDetailStack(stack)
    }

    /// Builds a dashboard card with focus and dismiss affordances while preserving the workspace Run tab rows.
    private func dashboardWindowCard(entry: DashboardAttentionEntry, shortcut: String, action: (() async -> Void)? = nil) -> NSView {
        let dismissButton = NSButton()
        dismissButton.title = ""
        dismissButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        dismissButton.imagePosition = .imageOnly
        dismissButton.setButtonType(.momentaryPushIn)
        dismissButton.isBordered = false
        dismissButton.contentTintColor = .secondaryLabelColor
        dismissButton.bezelStyle = .regularSquare
        dismissButton.target = self
        dismissButton.action = #selector(dismissDashboardAttentionItemAction(_:))
        dismissButton.identifier = NSUserInterfaceItemIdentifier(entry.attentionID)
        dismissButton.toolTip = "Dismiss from dashboard"

        let mainRow = windowRow(
            icon: entry.icon, iconColor: Self.dashboardIconColor(entry.iconTint), label: entry.label, detail: entry.detail, shortcut: shortcut,
            processStatus: entry.processStatus, agentStatus: entry.agentStatus,
            automationID: entry.agentStatus == nil ? nil : "dashboard-agent-\(Self.automationIdentifierSlug(entry.label))",
            trailingAccessory: dismissButton, action: action)

        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 4
        container.translatesAutoresizingMaskIntoConstraints = false

        container.addArrangedSubview(mainRow)
        constrainFormFieldToFillWidth(mainRow, in: container)

        for check in entry.statusChecks {
            let checkColor: NSColor = check.status == .passed ? .systemGreen : .systemRed
            let checkRow = statusCheckSubRow(name: check.checkName, color: checkColor, status: check.status)
            if let action { attachAsyncClickAction(to: checkRow, label: entry.label, shortcut: shortcut, action: action) }
            container.addArrangedSubview(checkRow)
            constrainFormFieldToFillWidth(checkRow, in: container)
        }
        return container
    }

    @objc private func dismissDashboardAttentionItemAction(_ sender: NSButton) {
        guard let attentionID = sender.identifier?.rawValue, !attentionID.isEmpty else { return }
        dismissDashboardAttentionItem(attentionID)
    }

    private func makeRightPane() -> NSView {
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.wantsLayer = true
        detailContainer.layer?.backgroundColor = sidebarPanelBackgroundColor().cgColor
        showPlaceholder()
        return detailContainer
    }

    private func reloadData() {
        do {
            pendingWorktreeDiscoveryReload = false
            configCache = try orchestrator.syncConfig()
            loadShortcutSpecs()
            projects = try orchestrator.listProjects()
            workspacesByProject = [:]
            workspaceRuntimeStatusByID = [:]
            for project in projects {
                let workspaces = try orchestrator.listWorkspaces(projectID: project.id, includeArchived: false)
                workspacesByProject[project.id] = workspaces
                for workspace in workspaces {
                    workspaceRuntimeStatusByID[workspace.id] = try orchestrator.workspaceRuntimeStatus(workspaceID: workspace.id)
                }
            }
            dashboardGroups = try Self.buildDashboardGroupsSnapshot(
                orchestrator: orchestrator, projects: projects, workspacesByProject: workspacesByProject)
            loadDashboardDismissedAttentionItemIDs()
            pruneDismissedDashboardAttentionItemIDsIfNeeded()
            outlineView.reloadData()
            applySidebarProjectExpansionState()
            refreshSelection()
            updateDashboardSidebarBadge()
        } catch { showError(error) }
    }

    private func startBackgroundServicesIfNeeded() {
        guard !didStartBackgroundServices else { return }
        didStartBackgroundServices = true
        startPeriodicWorkspaceWindowRefresh()
        startPeriodicUpdateCheck()
        startPeriodicProcessMonitor()
        startPeriodicWorktreeDiscovery()
        startPeriodicSidebarMetadataRefresh()
    }

    private func stopBackgroundServices() {
        periodicWorkspaceRefreshTask?.cancel()
        periodicWorkspaceRefreshTask = nil
        periodicUpdateCheckTask?.cancel()
        periodicUpdateCheckTask = nil
        periodicProcessMonitorTask?.cancel()
        periodicProcessMonitorTask = nil
        periodicWorktreeDiscoveryTask?.cancel()
        periodicWorktreeDiscoveryTask = nil
        periodicSidebarMetadataRefreshTask?.cancel()
        periodicSidebarMetadataRefreshTask = nil
        sidebarReloadTask?.cancel()
        sidebarReloadTask = nil
        pendingSidebarReloadRequest = false
        didStartBackgroundServices = false
    }

    private func enterSetupFlow(preferredInitialCheckID: SetupCheckID? = nil) {
        stopBackgroundServices()
        setupManager?.stop()
        let mgr = SetupManager()
        mgr.onComplete = { [weak self] in
            self?.logStartupProfile("setup_complete")
            self?.setupManager = nil
            self?.buildMainWindowContent()
            self?.logStartupProfile("main_content_ready")
            self?.showLoadingPlaceholder(message: "Loading projects and workspaces...", detail: "Muxy is preparing your workspace data.")
            self?.logStartupProfile("loading_placeholder_ready")
            Task { @MainActor [weak self] in await self?.loadInitialSidebarData() }
        }
        setupManager = mgr
        window.contentView = mgr.makeContentView()
        // start() can complete synchronously when all required checks already pass,
        // which avoids a visible setup flash during normal launch.
        mgr.start(preferredInitialCheckID: preferredInitialCheckID)
    }

    private func handleDeferredSetupRequirementIfNeeded(_ error: Error) -> Bool {
        guard shouldRouteToDeferredSetup(for: error) else { return false }
        enterSetupFlow(preferredInitialCheckID: .yabaiServiceRunning)
        return true
    }

    private func shouldRouteToDeferredSetup(for error: Error) -> Bool {
        if case MuxyError.yabaiUnavailable(let message) = error { return message.localizedStandardContains("failed to connect to socket") }
        let message = error.localizedDescription
        return message.localizedStandardContains("yabai-msg") && message.localizedStandardContains("failed to connect to socket")
    }

    private func loadInitialSidebarData() async {
        logStartupProfile("sidebar_snapshot_requested")
        let result = await Self.initialSidebarDataSnapshot()
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let snapshot):
            logStartupProfile("sidebar_snapshot_received")
            applySidebarDataSnapshot(snapshot)
            logStartupProfile("sidebar_snapshot_applied")
            startBackgroundServicesIfNeeded()
        case .failure(let error):
            if handleDeferredSetupRequirementIfNeeded(error) { return }
            showError(error)
            showPlaceholder(message: "Muxy couldn't load workspace data.")
            startBackgroundServicesIfNeeded()
        }
    }

    private func clearSidebarSelectionForTransientDetail() {
        let previousProjectID = selectedProjectID
        let previousWorkspaceID = selectedWorkspaceID
        suppressOutlineSelectionChanges = true
        selectedProjectID = nil
        selectedWorkspaceID = nil
        lastSelectedRow = -1
        outlineView.deselectAll(nil)
        suppressOutlineSelectionChanges = false
        refreshSidebarSelectionRows(
            previousProjectID: previousProjectID, currentProjectID: nil, previousWorkspaceID: previousWorkspaceID, currentWorkspaceID: nil)
        updateDashboardRowAppearance()
    }

    private func requestSidebarReload() {
        if let sidebarReloadTask, !sidebarReloadTask.isCancelled {
            pendingSidebarReloadRequest = true
            return
        }
        sidebarReloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Self.initialSidebarDataSnapshot()
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let snapshot): self.applySidebarDataSnapshot(snapshot, preserveDetailPane: true)
            case .failure(let error): if !self.handleDeferredSetupRequirementIfNeeded(error) { self.showError(error) }
            }
            self.sidebarReloadTask = nil
            if self.pendingSidebarReloadRequest {
                self.pendingSidebarReloadRequest = false
                self.requestSidebarReload()
            }
        }
    }

    private func applySidebarDataSnapshot(_ snapshot: SidebarDataSnapshot, preserveDetailPane: Bool = false) {
        logStartupProfile("apply_snapshot_start")
        let shouldPreserveDetailPane = preserveDetailPane && canPreserveDetailPaneAfterSidebarReload()
        pendingWorktreeDiscoveryReload = false
        configCache = snapshot.config
        loadShortcutSpecs()
        projects = snapshot.projects
        workspacesByProject = snapshot.workspacesByProject
        workspaceRuntimeStatusByID = snapshot.workspaceRuntimeStatusByID
        dashboardGroups = snapshot.dashboardGroups
        loadDashboardDismissedAttentionItemIDs()
        pruneDismissedDashboardAttentionItemIDsIfNeeded()
        outlineView.reloadData()
        applySidebarProjectExpansionState()
        logStartupProfile("apply_snapshot_outline_ready")
        if !shouldPreserveDetailPane {
            refreshSelection()
            logStartupProfile("apply_snapshot_selection_ready")
        } else if Self.shouldRefreshVisibleWorkspaceDetail(
            selectedWorkspaceID: selectedWorkspaceID, showingDashboard: showingDashboard, showingSettings: showingSettings,
            workspaceExists: selectedWorkspaceID.flatMap { findWorkspace(id: $0) } != nil)
        {
            refreshSelection()
            logStartupProfile("apply_snapshot_selection_preserved_ready")
        }
        updateDashboardSidebarBadge()
        logStartupProfile("apply_snapshot_dashboard_badge_ready", details: "group_count=\(dashboardGroups.count)")
        if showingDashboard { showDashboardDetail() }
    }

    /// Update the Dashboard sidebar row badge with the current attention item count.
    private func updateDashboardSidebarBadge() {
        let totalCount = dashboardAttentionCount()
        if let badge = dashboardRowBadge {
            badge.stringValue = "\(totalCount)"
            badge.isHidden = totalCount == 0
        }
        NSApp.dockTile.badgeLabel = totalCount == 0 ? nil : "\(totalCount)"
        NSApp.dockTile.display()
    }

    private func refreshSelection() {
        if showingDashboard {
            showDashboardDetail()
            return
        }
        if showingSettings {
            showSettingsDetail()
            return
        }
        if let selectedWorkspaceID {
            if let (project, workspace) = findWorkspace(id: selectedWorkspaceID) {
                showWorkspaceDetail(project: project, workspace: workspace)
                return
            }
        }
        if let selectedProjectID, let project = projects.first(where: { $0.id == selectedProjectID }) {
            showProjectDetail(project: project)
            return
        }
        showDashboardDetail()
    }

    private func requestVisibleWorkspaceDetailRefreshIfNeeded(reason _: String) {
        guard let workspaceID = selectedWorkspaceID else { return }
        guard
            Self.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: selectedWorkspaceID, showingDashboard: showingDashboard, showingSettings: showingSettings,
                workspaceExists: findWorkspace(id: workspaceID) != nil)
        else { return }
        if visibleWorkspaceDetailRefreshWorkspaceID == workspaceID, let task = visibleWorkspaceDetailRefreshTask, !task.isCancelled { return }

        visibleWorkspaceDetailRefreshTask?.cancel()
        visibleWorkspaceDetailRefreshWorkspaceID = workspaceID
        visibleWorkspaceDetailRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Self.refreshVisibleWorkspaceDetailSnapshot(workspaceID: workspaceID)
            guard !Task.isCancelled else { return }
            defer {
                if self.visibleWorkspaceDetailRefreshWorkspaceID == workspaceID {
                    self.visibleWorkspaceDetailRefreshWorkspaceID = nil
                    self.visibleWorkspaceDetailRefreshTask = nil
                }
            }

            guard self.selectedWorkspaceID == workspaceID, !self.showingDashboard, !self.showingSettings else { return }
            switch result {
            case .success(let outcome):
                guard outcome.didChangeVisibleState else { return }
                guard self.canReloadAfterBackgroundWorkspaceRefresh() else { return }
                self.reloadData()
            case .failure(let error): if !self.handleDeferredSetupRequirementIfNeeded(error) { self.showError(error) }
            }
        }
    }

    private func showPlaceholder(message: String = "Select a project or workspace.") {
        clearInlineWorkspaceFieldRefs()
        activeAddWorkspaceFormTag = nil
        activeAddProjectFormTag = nil
        visibleDetailWorkspaceID = nil
        showingSettings = false
        showingDashboard = false
        updateDashboardRowAppearance()
        activeShortcutCaptureSetting = nil
        for view in detailContainer.subviews { view.removeFromSuperview() }
        let placeholder = NSTextField(labelWithString: message)
        placeholder.font = .systemFont(ofSize: 14)
        placeholder.textColor = .secondaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: detailContainer.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: detailContainer.centerYAnchor),
        ])
    }

    private func showLoadingPlaceholder(message: String, detail: String?) {
        clearInlineWorkspaceFieldRefs()
        activeAddWorkspaceFormTag = nil
        activeAddProjectFormTag = nil
        visibleDetailWorkspaceID = nil
        showingSettings = false
        showingDashboard = false
        updateDashboardRowAppearance()
        activeShortcutCaptureSetting = nil
        for view in detailContainer.subviews { view.removeFromSuperview() }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(spinner)

        let title = NSTextField(labelWithString: message)
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.textColor = .labelColor
        stack.addArrangedSubview(title)

        if let detail, !detail.isEmpty {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 12)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.alignment = .center
            stack.addArrangedSubview(detailLabel)
        }

        detailContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: detailContainer.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: detailContainer.centerYAnchor),
        ])
    }

    private func showOperationProgressOverlay(message: String, detail: String) {
        guard let contentView = window?.contentView else { return }
        let overlay: NSVisualEffectView
        let titleLabel: NSTextField
        let detailLabel: NSTextField
        if let existingOverlay = operationProgressOverlay, let existingTitleLabel = operationProgressOverlayTitleLabel,
            let existingDetailLabel = operationProgressOverlayDetailLabel
        {
            overlay = existingOverlay
            titleLabel = existingTitleLabel
            detailLabel = existingDetailLabel
        } else {
            overlay = NSVisualEffectView()
            overlay.material = .hudWindow
            overlay.blendingMode = .withinWindow
            overlay.state = .active
            overlay.wantsLayer = true
            overlay.layer?.cornerRadius = UIRadius.large
            overlay.layer?.borderWidth = 1
            overlay.layer?.borderColor = sidebarCardBorderColor(isSelected: false).cgColor
            overlay.translatesAutoresizingMaskIntoConstraints = false

            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.alignment = .top
            stack.spacing = 10
            stack.translatesAutoresizingMaskIntoConstraints = false

            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.setContentHuggingPriority(.required, for: .horizontal)
            stack.addArrangedSubview(spinner)

            let labelStack = NSStackView()
            labelStack.orientation = .vertical
            labelStack.alignment = .leading
            labelStack.spacing = 2
            labelStack.translatesAutoresizingMaskIntoConstraints = false

            titleLabel = NSTextField(labelWithString: "")
            titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            titleLabel.textColor = .labelColor
            titleLabel.maximumNumberOfLines = 1
            labelStack.addArrangedSubview(titleLabel)

            detailLabel = NSTextField(labelWithString: "")
            detailLabel.font = .systemFont(ofSize: 11)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.maximumNumberOfLines = 2
            labelStack.addArrangedSubview(detailLabel)

            stack.addArrangedSubview(labelStack)
            overlay.addSubview(stack)
            contentView.addSubview(overlay)

            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -12),
                stack.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 10),
                stack.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -10),

                overlay.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
                overlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                overlay.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            ])

            operationProgressOverlay = overlay
            operationProgressOverlayTitleLabel = titleLabel
            operationProgressOverlayDetailLabel = detailLabel
        }

        titleLabel.stringValue = message
        detailLabel.stringValue = detail
        overlay.isHidden = false
    }

    private func hideOperationProgressOverlay() { operationProgressOverlay?.isHidden = true }

    private func showWindowIssueToast(title: String, detail: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        guard let contentView = window?.contentView else { return }
        let overlay: NSVisualEffectView
        let titleLabel: NSTextField
        let detailLabel: NSTextField
        let actionButton: NSButton
        if let existingOverlay = windowIssueToastOverlay, let existingTitleLabel = windowIssueToastTitleLabel,
            let existingDetailLabel = windowIssueToastDetailLabel, let existingActionButton = windowIssueToastActionButton
        {
            overlay = existingOverlay
            titleLabel = existingTitleLabel
            detailLabel = existingDetailLabel
            actionButton = existingActionButton
        } else {
            overlay = NSVisualEffectView()
            overlay.material = .hudWindow
            overlay.blendingMode = .withinWindow
            overlay.state = .active
            overlay.wantsLayer = true
            overlay.layer?.cornerRadius = UIRadius.large
            overlay.layer?.borderWidth = 1
            overlay.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.35).cgColor
            overlay.translatesAutoresizingMaskIntoConstraints = false

            let stack = NSStackView()
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false

            titleLabel = NSTextField(labelWithString: "")
            titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            titleLabel.textColor = .labelColor
            titleLabel.maximumNumberOfLines = 1
            stack.addArrangedSubview(titleLabel)

            detailLabel = NSTextField(labelWithString: "")
            detailLabel.font = .systemFont(ofSize: 11)
            detailLabel.textColor = .secondaryLabelColor
            detailLabel.maximumNumberOfLines = 2
            stack.addArrangedSubview(detailLabel)

            actionButton = NSButton(title: "", target: self, action: #selector(handleWindowIssueToastAction))
            actionButton.bezelStyle = .rounded
            actionButton.controlSize = .small
            actionButton.isBordered = true
            actionButton.contentTintColor = .systemBlue
            stack.addArrangedSubview(actionButton)

            overlay.addSubview(stack)
            contentView.addSubview(overlay)

            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -12),
                stack.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 10),
                stack.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -10),

                overlay.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
                overlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                overlay.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            ])

            windowIssueToastOverlay = overlay
            windowIssueToastTitleLabel = titleLabel
            windowIssueToastDetailLabel = detailLabel
            windowIssueToastActionButton = actionButton
        }

        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        actionButton.title = actionTitle ?? ""
        actionButton.isHidden = actionTitle == nil
        windowIssueToastActionHandler = action
        overlay.isHidden = false

        windowIssueToastDismissTask?.cancel()
        let dismissAfterSeconds: Double = actionTitle == nil ? 4 : 8
        windowIssueToastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(dismissAfterSeconds))
            guard !Task.isCancelled else { return }
            self?.hideWindowIssueToast()
        }
    }

    private func hideWindowIssueToast() {
        windowIssueToastDismissTask?.cancel()
        windowIssueToastDismissTask = nil
        windowIssueToastActionHandler = nil
        windowIssueToastOverlay?.isHidden = true
    }

    @objc private func handleWindowIssueToastAction() {
        let action = windowIssueToastActionHandler
        hideWindowIssueToast()
        action?()
    }

    private func showWindowIssueModal(title: String, detail: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        hideWindowIssueToast()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail

        if let actionTitle {
            let actionButton = alert.addButton(withTitle: actionTitle)
            actionButton.keyEquivalent = "r"
            actionButton.keyEquivalentModifierMask = [.command]
            let cancelButton = alert.addButton(withTitle: "Cancel (Esc)")
            cancelButton.keyEquivalent = "\u{1b}"
            cancelButton.keyEquivalentModifierMask = []
        } else {
            let okButton = alert.addButton(withTitle: "OK")
            okButton.keyEquivalent = "\r"
            okButton.keyEquivalentModifierMask = []
        }

        guard let window else {
            let response = alert.runModal()
            if actionTitle != nil, response == .alertFirstButtonReturn { action?() }
            return
        }

        alert.beginSheetModal(for: window) { response in if actionTitle != nil, response == .alertFirstButtonReturn { action?() } }
    }

    private func showSettingsDetail() {
        clearInlineWorkspaceFieldRefs()
        activeAddWorkspaceFormTag = nil
        activeAddProjectFormTag = nil
        visibleDetailWorkspaceID = nil
        showingSettings = true
        showingDashboard = false
        updateDashboardRowAppearance()
        shortcutButtonsBySetting.removeAll()
        activeShortcutCaptureSetting = nil
        for view in detailContainer.subviews { view.removeFromSuperview() }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false

        // --- Header ---
        let header = NSTextField(labelWithString: "Settings")
        header.font = .systemFont(ofSize: 20, weight: .semibold)
        let pageSubtitle = NSTextField(labelWithString: "App preferences")
        pageSubtitle.font = .systemFont(ofSize: 12)
        pageSubtitle.textColor = .secondaryLabelColor
        let headerStack = NSStackView()
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 2
        headerStack.addArrangedSubview(header)
        headerStack.addArrangedSubview(pageSubtitle)
        stack.addArrangedSubview(headerStack)

        // --- Editor & terminal section ---
        let options = installedEditorOptions()
        let currentEditor: EditorPreference? = {
            guard let editor = configCache?.editor, editor != .none else { return nil }
            return editor
        }()
        let editorPopUp = NSPopUpButton()
        editorPopUp.translatesAutoresizingMaskIntoConstraints = false
        editorPopUp.autoenablesItems = false
        if options.isEmpty {
            editorPopUp.addItem(withTitle: "None detected")
            editorPopUp.isEnabled = false
        } else {
            editorPopUp.addItem(withTitle: "Select editor")
            editorPopUp.item(at: 0)?.isEnabled = false
            for option in options {
                editorPopUp.addItem(withTitle: option.displayName)
                editorPopUp.itemArray.last?.representedObject = option.preference
            }
            if let current = currentEditor, let item = editorPopUp.itemArray.first(where: { ($0.representedObject as? EditorPreference) == current })
            {
                editorPopUp.select(item)
            } else {
                editorPopUp.selectItem(at: 0)
            }
            editorPopUp.target = self
            editorPopUp.action = #selector(editorPreferenceChanged(_:))
        }
        editorPopUp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        editorPopUp.setAccessibilityIdentifier("settings-editor")

        let terminalPopUp = NSPopUpButton()
        terminalPopUp.translatesAutoresizingMaskIntoConstraints = false
        for host in TerminalHost.allCases {
            terminalPopUp.addItem(withTitle: host.displayName)
            terminalPopUp.itemArray.last?.representedObject = host
        }
        if let currentHost = configCache?.terminalHost,
            let item = terminalPopUp.itemArray.first(where: { ($0.representedObject as? TerminalHost) == currentHost })
        {
            terminalPopUp.select(item)
        }
        terminalPopUp.setAccessibilityIdentifier("settings-terminal-host")
        terminalPopUp.target = self
        terminalPopUp.action = #selector(terminalHostChanged(_:))
        terminalPopUp.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var editorContentViews: [NSView] = [
            settingsLabeledField(
                name: "Preferred editor", hint: "Opened when you use the editor shortcut from inside a workspace", control: editorPopUp),
            settingsLabeledField(name: "Terminal host", hint: "Used for process panes and coding agents", control: terminalPopUp),
        ]
        if let current = currentEditor, !options.contains(where: { $0.preference == current }) {
            let note = helpTextLabel("Saved editor \"\(editorDisplayName(current))\" is not installed.")
            editorContentViews.append(note)
        }
        let editorCard = formSectionCard(icon: "square.and.pencil", title: "Editor & terminal", contentViews: editorContentViews)
        stack.addArrangedSubview(editorCard)
        constrainFormFieldToFillWidth(editorCard, in: stack)

        // --- Window focus pulse section ---
        let pulseEnabledCheckbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(windowPulseEnabledChanged(_:)))
        pulseEnabledCheckbox.state = ((try? orchestrator.windowFocusPulseEnabled()) ?? SettingsKey.defaultWindowFocusPulseEnabled) ? .on : .off

        let (pulseR, pulseG, pulseB) = (try? orchestrator.windowFocusPulseColor()) ?? (r: 72, g: 98, b: 110)
        let colorWell = NSColorWell()
        colorWell.color = NSColor(red: CGFloat(pulseR) / 255, green: CGFloat(pulseG) / 255, blue: CGFloat(pulseB) / 255, alpha: 1)
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.target = self
        colorWell.action = #selector(windowPulseColorChanged(_:))
        colorWell.widthAnchor.constraint(equalToConstant: 36).isActive = true
        colorWell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        pulseColorWell = colorWell

        let resetColorButton = actionButton(
            title: "Reset", symbol: nil, tooltip: "Reset to default color (\(SettingsKey.defaultWindowFocusPulseColor))",
            action: #selector(resetWindowPulseColor(_:)), primary: false)
        let colorControlRow = NSStackView()
        colorControlRow.orientation = .horizontal
        colorControlRow.alignment = .centerY
        colorControlRow.spacing = 8
        colorControlRow.addArrangedSubview(colorWell)
        colorControlRow.addArrangedSubview(resetColorButton)

        let pulseCard = formSectionCard(
            icon: "eye", title: "Window focus pulse", subtitle: "Briefly overlays focused terminal windows when focus moves to them",
            contentViews: [
                settingsSettingRow(
                    name: "Enable focus pulse", hint: "Tints the border so the focused window is obvious", control: pulseEnabledCheckbox),
                settingsSettingRow(name: "Pulse color", hint: "Default \(SettingsKey.defaultWindowFocusPulseColor)", control: colorControlRow),
            ])
        stack.addArrangedSubview(pulseCard)
        constrainFormFieldToFillWidth(pulseCard, in: stack)

        // --- Keyboard shortcuts section ---
        let shortcutContainer = buildShortcutRowsContainer()
        let shortcutCard = formSectionCard(
            icon: "keyboard", title: "Keyboard shortcuts",
            subtitle: "Click record on a row to capture a new chord. Leader-based shortcuts inherit the leader modifier.",
            contentViews: [shortcutContainer])
        stack.addArrangedSubview(shortcutCard)
        constrainFormFieldToFillWidth(shortcutCard, in: stack)

        showScrollableDetailStack(stack)
    }

    private func settingsLabeledField(name: String, hint: String, control: NSView) -> NSView {
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)

        let hintLabel = NSTextField(labelWithString: hint)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.maximumNumberOfLines = 2
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        control.translatesAutoresizingMaskIntoConstraints = false
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.addArrangedSubview(nameLabel)
        stack.addArrangedSubview(hintLabel)
        stack.addArrangedSubview(control)
        control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func settingsSettingRow(name: String, hint: String, control: NSView) -> NSView {
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)

        let hintLabel = NSTextField(labelWithString: hint)
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.maximumNumberOfLines = 2
        hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let labelStack = NSStackView()
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 2
        labelStack.addArrangedSubview(nameLabel)
        labelStack.addArrangedSubview(hintLabel)
        labelStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        control.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.addArrangedSubview(labelStack)
        row.addArrangedSubview(control)
        return row
    }

    private func buildShortcutRowsContainer() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = UIRadius.compact
        container.layer?.borderWidth = 1
        container.layer?.borderColor = sidebarCardBorderColor(isSelected: false).cgColor
        container.layer?.masksToBounds = true

        let captureWidth: CGFloat = 140
        let rowHeight: CGFloat = 28
        let hPad: CGFloat = 10
        let vPad: CGFloat = 4
        var previousBottom: NSLayoutYAxisAnchor = container.topAnchor

        for (i, setting) in ShortcutSetting.settingsPanelCases.enumerated() {
            if i > 0 {
                let sep = NSView()
                sep.translatesAutoresizingMaskIntoConstraints = false
                sep.wantsLayer = true
                sep.layer?.backgroundColor = sidebarCardBorderColor(isSelected: false).withAlphaComponent(0.5).cgColor
                container.addSubview(sep)
                NSLayoutConstraint.activate([
                    sep.leadingAnchor.constraint(equalTo: container.leadingAnchor), sep.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    sep.topAnchor.constraint(equalTo: previousBottom), sep.heightAnchor.constraint(equalToConstant: 1),
                ])
                previousBottom = sep.bottomAnchor
            }

            let titleLabel = NSTextField(labelWithString: setting.label)
            titleLabel.font = .systemFont(ofSize: 12)
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let captureButton = NSButton(title: "", target: self, action: #selector(beginShortcutCapture(_:)))
            captureButton.identifier = NSUserInterfaceItemIdentifier(setting.settingKey)
            captureButton.isBordered = false
            captureButton.alignment = .center
            captureButton.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            captureButton.translatesAutoresizingMaskIntoConstraints = false
            updateShortcutCaptureButtonText(captureButton, text: shortcutCaptureButtonTitle(setting: setting), active: false)
            styleShortcutCaptureButton(captureButton, active: false)
            captureButton.widthAnchor.constraint(equalToConstant: captureWidth).isActive = true
            shortcutButtonsBySetting[setting.settingKey] = captureButton

            let resetButton = actionButton(
                title: "Reset", symbol: nil, tooltip: "Reset to default shortcut", action: #selector(resetShortcutSetting(_:)), primary: false)
            resetButton.identifier = NSUserInterfaceItemIdentifier(setting.settingKey)
            resetButton.setContentHuggingPriority(.required, for: .horizontal)

            // Right-side group: capture button + reset button, pinned to trailing edge.
            // Grouping them ensures both columns align identically across all rows.
            let rightStack = NSStackView(views: [captureButton, resetButton])
            rightStack.orientation = .horizontal
            rightStack.alignment = .centerY
            rightStack.spacing = 8
            rightStack.translatesAutoresizingMaskIntoConstraints = false

            container.addSubview(titleLabel)
            container.addSubview(rightStack)

            NSLayoutConstraint.activate([
                rightStack.topAnchor.constraint(equalTo: previousBottom, constant: vPad),
                rightStack.heightAnchor.constraint(equalToConstant: rowHeight),
                rightStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -hPad),
                titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: hPad),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -8),
                titleLabel.centerYAnchor.constraint(equalTo: rightStack.centerYAnchor),
            ])
            previousBottom = rightStack.bottomAnchor
        }

        container.bottomAnchor.constraint(equalTo: previousBottom, constant: vPad).isActive = true
        return container
    }

    private func showProjectDetail(project: ProjectSummary) {
        clearInlineWorkspaceFieldRefs()
        activeAddWorkspaceFormTag = nil
        activeAddProjectFormTag = nil
        visibleDetailWorkspaceID = nil
        showingSettings = false
        showingDashboard = false
        updateDashboardRowAppearance()
        activeShortcutCaptureSetting = nil
        for view in detailContainer.subviews { view.removeFromSuperview() }
        detailContainer.wantsLayer = true
        detailContainer.layer?.backgroundColor = sidebarPanelBackgroundColor().cgColor

        let fullProject = (try? orchestrator.project(id: project.id))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        // --- Header ---
        let accentColor = sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
        let headerIcon = NSImageView()
        if let img = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: project.name) {
            let config = NSImage.SymbolConfiguration(paletteColors: [accentColor]).applying(
                NSImage.SymbolConfiguration(pointSize: 22, weight: .medium))
            headerIcon.image = img.withSymbolConfiguration(config)
        }
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([headerIcon.widthAnchor.constraint(equalToConstant: 28), headerIcon.heightAnchor.constraint(equalToConstant: 28)])

        let headerTitle = NSTextField(labelWithString: project.name)
        headerTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        headerTitle.textColor = sidebarPrimaryTextColor(isSelected: false, isArchived: false)

        let addWorkspaceButton = actionButton(
            title: "New Workspace", symbol: "plus.rectangle.on.rectangle", tooltip: "New workspace for \(project.name)",
            action: #selector(addWorkspaceFromToolbar), primary: false)
        addWorkspaceButton.identifier = NSUserInterfaceItemIdentifier(project.id)

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 10
        headerRow.addArrangedSubview(headerIcon)
        headerRow.addArrangedSubview(headerTitle)
        headerRow.addArrangedSubview(NSView())
        if project.isGitRepo { headerRow.addArrangedSubview(addWorkspaceButton) }

        let headerSubtitle = NSTextField(labelWithString: project.dir)
        headerSubtitle.font = .systemFont(ofSize: 12)
        headerSubtitle.textColor = .secondaryLabelColor
        headerSubtitle.lineBreakMode = .byTruncatingMiddle

        stack.addArrangedSubview(headerRow)
        stack.addArrangedSubview(headerSubtitle)
        constrainFormFieldToFillWidth(headerRow, in: stack)

        // --- Fields ---
        let setupView = makeEditableTextView()
        let stopView = makeEditableTextView()
        let portEditor = PortEditor()
        let processEditor = ProcessEditor()
        let browserSessionEditor = BrowserSessionEditor()
        let agentLauncherEditor = AgentLauncherEditor()
        setupView.string = fullProject?.setupScript ?? ""
        stopView.string = fullProject?.stopScript ?? ""
        portEditor.setDefinitions(fullProject?.ports ?? [])
        processEditor.setProcessesWithChecks(fullProject?.processes ?? [], statusChecks: fullProject?.statusChecks ?? [])
        browserSessionEditor.setSessions(fullProject?.browserSessions ?? [])
        agentLauncherEditor.setLaunchers(fullProject?.agentLaunchers ?? [])

        // --- Setup script card ---
        let setupScroll = scrollableTextView(setupView, height: 90)
        let setupCard = formSectionCard(
            icon: "terminal", title: "Setup script", subtitle: "Runs when each new workspace is created or revived from archive.",
            contentViews: [setupScroll])
        stack.addArrangedSubview(setupCard)
        constrainFormFieldToFillWidth(setupCard, in: stack)

        // --- Port definitions card ---
        let portCard = formSectionCard(
            icon: "network", title: "Port definitions",
            subtitle: "Named ports allocated per workspace. Available as env vars in scripts and commands.", contentViews: [portEditor.container])
        stack.addArrangedSubview(portCard)
        constrainFormFieldToFillWidth(portCard, in: stack)

        // --- Processes card ---
        let processCard = formSectionCard(
            icon: "terminal.fill", title: "Processes", subtitle: "Define the commands that run inside your workspace.",
            contentViews: [processEditor.container])
        stack.addArrangedSubview(processCard)
        constrainFormFieldToFillWidth(processCard, in: stack)

        // --- Browser sessions card ---
        let browserCard = formSectionCard(
            icon: "globe", title: "Browser sessions", subtitle: "Optional names with URL prefixes to open automatically.",
            contentViews: [browserSessionEditor.container])
        stack.addArrangedSubview(browserCard)
        constrainFormFieldToFillWidth(browserCard, in: stack)

        let agentLauncherCard = formSectionCard(
            icon: "cpu.fill", title: "Coding agents", subtitle: "Named interactive coding agents that open outside tmux.",
            contentViews: [agentLauncherEditor.container])
        stack.addArrangedSubview(agentLauncherCard)
        constrainFormFieldToFillWidth(agentLauncherCard, in: stack)

        // --- Stop script card ---
        let stopScroll = scrollableTextView(stopView, height: 90)
        let stopCard = formSectionCard(
            icon: "stop.circle", title: "Stop script", subtitle: "Runs on stop/restart/archive after process termination.", contentViews: [stopScroll]
        )
        stack.addArrangedSubview(stopCard)
        constrainFormFieldToFillWidth(stopCard, in: stack)

        // --- Buttons ---
        let saveButton = actionButton(
            title: "Save Project", symbol: "square.and.arrow.down", tooltip: "Save project (⌘S)", action: #selector(saveProject(_:)), primary: true)
        saveButton.identifier = NSUserInterfaceItemIdentifier(project.id)
        saveButton.keyEquivalent = "\r"

        let deleteButton = iconButton(symbol: "trash", tooltip: "Delete project", action: #selector(deleteProject(_:)))
        deleteButton.identifier = NSUserInterfaceItemIdentifier(project.id)
        let muted = NSColor.systemRed.withAlphaComponent(0.6)
        deleteButton.contentTintColor = muted

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(deleteButton)
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(saveButton)
        stack.addArrangedSubview(buttonRow)
        constrainFormFieldToFillWidth(buttonRow, in: stack)

        showScrollableDetailStack(stack)

        saveButton.tag = storeProjectFields(
            projectID: project.id, setupView: setupView, stopView: stopView, portEditor: portEditor, processEditor: processEditor,
            browserSessionEditor: browserSessionEditor, agentLauncherEditor: agentLauncherEditor)
        registerDirtyTracking(
            setupView: setupView, stopView: stopView, portEditor: portEditor, processEditor: processEditor,
            browserSessionEditor: browserSessionEditor, agentLauncherEditor: agentLauncherEditor)
    }

    private func formSectionCard(icon: String, title: String, subtitle: String = "", trailingView: NSView? = nil, contentViews: [NSView]) -> NSView {
        let section = NSView()
        section.translatesAutoresizingMaskIntoConstraints = false
        section.setContentHuggingPriority(.required, for: .vertical)

        let accentColor = sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))

        // Header row: icon + title/subtitle + optional trailing view
        let iconView = NSImageView()
        if let img = NSImage(systemSymbolName: icon, accessibilityDescription: title) {
            let config = NSImage.SymbolConfiguration(paletteColors: [accentColor])
            iconView.image = img.withSymbolConfiguration(config)
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([iconView.widthAnchor.constraint(equalToConstant: 20), iconView.heightAnchor.constraint(equalToConstant: 20)])

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        titleStack.addArrangedSubview(titleLabel)
        if !subtitle.isEmpty { titleStack.addArrangedSubview(subtitleLabel) }
        titleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .top
        headerRow.spacing = 10
        headerRow.addArrangedSubview(iconView)
        headerRow.addArrangedSubview(titleStack)
        if let trailing = trailingView {
            trailing.setContentHuggingPriority(.required, for: .horizontal)
            headerRow.addArrangedSubview(trailing)
        }

        let innerStack = NSStackView()
        innerStack.orientation = .vertical
        innerStack.alignment = .leading
        innerStack.spacing = 12
        innerStack.translatesAutoresizingMaskIntoConstraints = false
        innerStack.addArrangedSubview(headerRow)
        for view in contentViews { innerStack.addArrangedSubview(view) }

        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = sidebarCardBorderColor(isSelected: false).withAlphaComponent(0.55).cgColor

        section.addSubview(innerStack)
        section.addSubview(divider)
        NSLayoutConstraint.activate([
            innerStack.leadingAnchor.constraint(equalTo: section.leadingAnchor),
            innerStack.trailingAnchor.constraint(equalTo: section.trailingAnchor),
            innerStack.topAnchor.constraint(equalTo: section.topAnchor, constant: 4),

            divider.leadingAnchor.constraint(equalTo: section.leadingAnchor), divider.trailingAnchor.constraint(equalTo: section.trailingAnchor),
            divider.topAnchor.constraint(equalTo: innerStack.bottomAnchor, constant: 18), divider.heightAnchor.constraint(equalToConstant: 1),
            divider.bottomAnchor.constraint(equalTo: section.bottomAnchor),
        ])
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.widthAnchor.constraint(equalTo: innerStack.widthAnchor).isActive = true
        for view in contentViews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: innerStack.widthAnchor).isActive = true
        }

        return section
    }

    private func showAddProjectForm() {
        clearInlineWorkspaceFieldRefs()
        activeAddWorkspaceFormTag = nil
        activeAddProjectFormTag = nil
        showingSettings = false
        showingDashboard = false
        clearSidebarSelectionForTransientDetail()
        for view in detailContainer.subviews { view.removeFromSuperview() }
        detailContainer.wantsLayer = true
        detailContainer.layer?.backgroundColor = sidebarPanelBackgroundColor().cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false

        // --- Header ---
        let accentColor = sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
        let headerIcon = NSImageView()
        if let img = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "New Project") {
            let config = NSImage.SymbolConfiguration(paletteColors: [accentColor]).applying(
                NSImage.SymbolConfiguration(pointSize: 22, weight: .medium))
            headerIcon.image = img.withSymbolConfiguration(config)
        }
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([headerIcon.widthAnchor.constraint(equalToConstant: 28), headerIcon.heightAnchor.constraint(equalToConstant: 28)])

        let headerTitle = NSTextField(labelWithString: "New Project")
        headerTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        headerTitle.textColor = sidebarPrimaryTextColor(isSelected: false, isArchived: false)

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 10
        headerRow.addArrangedSubview(headerIcon)
        headerRow.addArrangedSubview(headerTitle)

        let headerSubtitle = NSTextField(labelWithString: "Configure your workspace, processes, and lifecycle scripts.")
        headerSubtitle.font = .systemFont(ofSize: 12)
        headerSubtitle.textColor = .secondaryLabelColor

        stack.addArrangedSubview(headerRow)
        stack.addArrangedSubview(headerSubtitle)

        // --- Fields ---
        let sourcePopup = NSPopUpButton()
        sourcePopup.addItems(withTitles: ["Existing directory", "Clone repository"])
        sourcePopup.selectItem(at: 0)
        sourcePopup.target = self
        sourcePopup.action = #selector(projectSourceChanged(_:))

        let dirField = NSTextField(labelWithString: "")
        dirField.toolTip = nil
        dirField.textColor = .secondaryLabelColor
        dirField.lineBreakMode = .byTruncatingMiddle
        dirField.isHidden = true
        let browseButton = NSButton(title: "Choose a project directory", target: self, action: #selector(browseProjectDir(_:)))
        browseButton.bezelStyle = .texturedRounded
        browseButton.controlSize = .regular
        browseButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Choose directory")
        browseButton.imagePosition = .imageLeading
        browseButton.toolTip = "Choose directory"
        let repoURLField = NSTextField(string: "")
        repoURLField.placeholderString = "https://github.com/org/repo.git"
        repoURLField.delegate = self

        let setupScriptSection = SetupScriptSection(value: "", subtitle: "Runs when each new workspace is created or revived from archive.")
        let stopScriptSection = StopScriptSection(value: "", subtitle: "Runs on workspace stop, restart, or archive.")
        let portsSection = PortsSection(subtitle: "Named ports allocated per workspace, available as env vars.")
        let processesSection = ProcessesSection(subtitle: "Commands that run inside each workspace.")
        let browserSessionsSection = BrowserSessionsSection(subtitle: "Browser windows opened automatically on launch.")
        let agentLaunchersSection = AgentLaunchersSection(subtitle: "Interactive coding agents that open outside tmux.")

        // --- Source row: popup + dir/URL input on same line ---
        let localSourceSection = NSStackView()
        localSourceSection.orientation = .horizontal
        localSourceSection.alignment = .centerY
        localSourceSection.spacing = 8
        localSourceSection.detachesHiddenViews = true

        browseButton.translatesAutoresizingMaskIntoConstraints = false
        browseButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        browseButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([browseButton.heightAnchor.constraint(equalToConstant: 28)])

        dirField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        dirField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        localSourceSection.addArrangedSubview(browseButton)
        localSourceSection.addArrangedSubview(dirField)

        let cloneSourceSection = NSStackView()
        cloneSourceSection.orientation = .horizontal
        cloneSourceSection.alignment = .centerY
        cloneSourceSection.spacing = 8
        cloneSourceSection.detachesHiddenViews = true

        repoURLField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        repoURLField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        cloneSourceSection.addArrangedSubview(repoURLField)

        // --- Source section (combined): popup on top, then dir/url row ---
        let sourceInputRow = NSStackView()
        sourceInputRow.orientation = .horizontal
        sourceInputRow.alignment = .centerY
        sourceInputRow.spacing = 8
        sourceInputRow.detachesHiddenViews = true

        sourcePopup.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        sourcePopup.setContentCompressionResistancePriority(.required, for: .horizontal)

        sourceInputRow.addArrangedSubview(sourcePopup)
        sourceInputRow.addArrangedSubview(localSourceSection)
        sourceInputRow.addArrangedSubview(cloneSourceSection)

        let sourceContentStack = NSStackView()
        sourceContentStack.orientation = .vertical
        sourceContentStack.alignment = .leading
        sourceContentStack.spacing = 12
        sourceContentStack.detachesHiddenViews = true
        sourceContentStack.addArrangedSubview(sourceInputRow)
        constrainFormFieldToFillWidth(sourceInputRow, in: sourceContentStack)

        let sourceCard = formSectionCard(
            icon: "folder.badge.plus", title: "Source", subtitle: "Where does your project live?", contentViews: [sourceContentStack])
        stack.addArrangedSubview(sourceCard)

        // --- Section cards (shown once source is configured) ---
        setupScriptSection.view.isHidden = true
        stack.addArrangedSubview(setupScriptSection.view)

        portsSection.view.isHidden = true
        stack.addArrangedSubview(portsSection.view)

        processesSection.view.isHidden = true
        stack.addArrangedSubview(processesSection.view)

        browserSessionsSection.view.isHidden = true
        stack.addArrangedSubview(browserSessionsSection.view)

        agentLaunchersSection.view.isHidden = true
        stack.addArrangedSubview(agentLaunchersSection.view)

        stopScriptSection.view.isHidden = true
        stack.addArrangedSubview(stopScriptSection.view)

        // --- Buttons ---
        let createButton = actionButton(
            title: "Create Project", symbol: nil, tooltip: "Create project (Return)", action: #selector(createProject(_:)), primary: true)
        createButton.keyEquivalent = "\r"
        createButton.isEnabled = false
        let cancelButton = actionButton(
            title: "Cancel (Esc)", symbol: nil, tooltip: "Cancel (Esc)", action: #selector(cancelProjectForm), primary: false)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(createButton)
        stack.addArrangedSubview(buttonRow)

        // --- Width constraints ---
        constrainFormFieldToFillWidth(sourceCard, in: stack)
        constrainFormFieldToFillWidth(setupScriptSection.view, in: stack)
        constrainFormFieldToFillWidth(portsSection.view, in: stack)
        constrainFormFieldToFillWidth(processesSection.view, in: stack)
        constrainFormFieldToFillWidth(browserSessionsSection.view, in: stack)
        constrainFormFieldToFillWidth(agentLaunchersSection.view, in: stack)
        constrainFormFieldToFillWidth(stopScriptSection.view, in: stack)
        constrainFormFieldToFillWidth(buttonRow, in: stack)

        showScrollableDetailStack(stack)

        createButton.tag = storeAddProjectFields(
            sourcePopup: sourcePopup, localSourceSection: localSourceSection, cloneSourceSection: cloneSourceSection, dirField: dirField,
            repoURLField: repoURLField, setupScriptSection: setupScriptSection, stopScriptSection: stopScriptSection, portsSection: portsSection,
            processesSection: processesSection, browserSessionsSection: browserSessionsSection, agentLaunchersSection: agentLaunchersSection,
            browseButton: browseButton,
            progressiveInputViews: [
                setupScriptSection.view, portsSection.view, processesSection.view, browserSessionsSection.view, agentLaunchersSection.view,
                stopScriptSection.view,
            ], createButton: createButton)
        activeAddProjectFormTag = createButton.tag
        if let refs = AddProjectFieldCache.shared.cache[createButton.tag] { updateAddProjectSourceUI(refs) }
    }

    private func showAddWorkspaceForm(project: ProjectSummary) {
        clearInlineWorkspaceFieldRefs()
        activeAddWorkspaceFormTag = nil
        activeAddProjectFormTag = nil
        showingSettings = false
        showingDashboard = false
        clearSidebarSelectionForTransientDetail()
        for view in detailContainer.subviews { view.removeFromSuperview() }
        detailContainer.wantsLayer = true
        detailContainer.layer?.backgroundColor = sidebarPanelBackgroundColor().cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        // --- Header ---
        let accentColor = sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
        let headerIcon = NSImageView()
        if let img = NSImage(systemSymbolName: "plus.rectangle.on.folder", accessibilityDescription: "New Workspace") {
            let config = NSImage.SymbolConfiguration(paletteColors: [accentColor]).applying(
                NSImage.SymbolConfiguration(pointSize: 22, weight: .medium))
            headerIcon.image = img.withSymbolConfiguration(config)
        }
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([headerIcon.widthAnchor.constraint(equalToConstant: 28), headerIcon.heightAnchor.constraint(equalToConstant: 28)])

        let headerTitle = NSTextField(labelWithString: "New Workspace")
        headerTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        headerTitle.textColor = sidebarPrimaryTextColor(isSelected: false, isArchived: false)

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 10
        headerRow.addArrangedSubview(headerIcon)
        headerRow.addArrangedSubview(headerTitle)

        let headerSubtitle = NSTextField(labelWithString: "Create a new workspace for \(project.name).")
        headerSubtitle.font = .systemFont(ofSize: 12)
        headerSubtitle.textColor = .secondaryLabelColor
        let headerHint = helpTextLabel("Tip: Press Cmd+N to quickly create a workspace with an auto-generated name.")

        stack.addArrangedSubview(headerRow)
        stack.addArrangedSubview(headerSubtitle)
        stack.addArrangedSubview(headerHint)

        // --- Fields ---
        let suggestedName = suggestedWorkspaceNameFast(projectID: project.id)
        let nameField = NSTextField(string: project.isGitRepo ? "" : suggestedName)
        nameField.placeholderString = "workspace title"
        nameField.setAccessibilityIdentifier("add-workspace-title")
        let branchModePopup = NSPopUpButton()
        branchModePopup.addItems(withTitles: ["Existing branch", "Create branch"])
        branchModePopup.selectItem(at: 1)
        branchModePopup.setAccessibilityIdentifier("add-workspace-branch-mode")
        branchModePopup.target = self
        branchModePopup.action = #selector(addWorkspaceBranchModeChanged(_:))
        let targetBranchField = NSComboBox()
        targetBranchField.usesDataSource = false
        targetBranchField.completes = true
        targetBranchField.numberOfVisibleItems = 10
        targetBranchField.setAccessibilityIdentifier("add-workspace-target-branch")
        let targetBranches = project.isGitRepo ? [defaultWorkspaceTargetBranchFast(project: project)].compactMap { $0 } : []
        targetBranchField.addItems(withObjectValues: targetBranches)
        if let defaultTargetBranch = defaultWorkspaceTargetBranch(project: project, branches: targetBranches) {
            targetBranchField.stringValue = defaultTargetBranch
        }
        let existingBranchField = NSComboBox()
        existingBranchField.usesDataSource = false
        existingBranchField.completes = true
        existingBranchField.numberOfVisibleItems = 10
        existingBranchField.placeholderString = "search branches"
        existingBranchField.setAccessibilityIdentifier("add-workspace-existing-branch")
        existingBranchField.addItems(withObjectValues: targetBranches)
        if let defaultBranch = defaultWorkspaceTargetBranch(project: project, branches: targetBranches) {
            existingBranchField.stringValue = defaultBranch
        }
        let newBranchField = NSTextField(string: "")
        newBranchField.placeholderString = "new branch name"
        newBranchField.setAccessibilityIdentifier("add-workspace-new-branch")
        newBranchField.delegate = self
        let directoryNameField = NSTextField(string: "")
        directoryNameField.placeholderString = "optional: letters, numbers, -, _"
        directoryNameField.setAccessibilityIdentifier("add-workspace-directory-name")
        let tooltipField = NSTextField(string: "")
        tooltipField.placeholderString = "optional: context about what you're working on"
        tooltipField.setAccessibilityIdentifier("add-workspace-tooltip")
        let autoNameState = project.isGitRepo ? AddWorkspaceAutoNameState() : nil

        // --- Single card with all inputs ---
        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 12
        var progressiveInputViews: [NSView] = []

        if project.isGitRepo {
            contentStack.addArrangedSubview(label(text: "Branch"))
            contentStack.addArrangedSubview(helpTextLabel("Pick an existing branch or switch to create a new one."))
            contentStack.addArrangedSubview(branchModePopup)
            contentStack.addArrangedSubview(existingBranchField)
            contentStack.addArrangedSubview(newBranchField)
            constrainFormFieldToFillWidth(branchModePopup, in: contentStack)
            constrainFormFieldToFillWidth(existingBranchField, in: contentStack)
            constrainFormFieldToFillWidth(newBranchField, in: contentStack)

            let advancedInputStack = NSStackView()
            advancedInputStack.orientation = .vertical
            advancedInputStack.alignment = .leading
            advancedInputStack.spacing = 12
            advancedInputStack.addArrangedSubview(label(text: "Target branch"))
            advancedInputStack.addArrangedSubview(helpTextLabel("The existing branch your new branch will be based on."))
            advancedInputStack.addArrangedSubview(targetBranchField)
            advancedInputStack.addArrangedSubview(label(text: "Workspace title"))
            advancedInputStack.addArrangedSubview(helpTextLabel("Display title for this workspace in the sidebar."))
            advancedInputStack.addArrangedSubview(nameField)
            advancedInputStack.addArrangedSubview(label(text: "Directory name"))
            advancedInputStack.addArrangedSubview(helpTextLabel("Auto-filled from branch name. Only letters, numbers, -, _ allowed."))
            advancedInputStack.addArrangedSubview(directoryNameField)
            advancedInputStack.addArrangedSubview(label(text: "Tooltip"))
            advancedInputStack.addArrangedSubview(helpTextLabel("Optional context to display when viewing this workspace."))
            advancedInputStack.addArrangedSubview(tooltipField)
            constrainFormFieldToFillWidth(targetBranchField, in: advancedInputStack)
            constrainFormFieldToFillWidth(nameField, in: advancedInputStack)
            constrainFormFieldToFillWidth(directoryNameField, in: advancedInputStack)
            constrainFormFieldToFillWidth(tooltipField, in: advancedInputStack)
            advancedInputStack.isHidden = true
            contentStack.addArrangedSubview(advancedInputStack)
            progressiveInputViews = [advancedInputStack]
        } else {
            contentStack.addArrangedSubview(label(text: "Workspace title"))
            contentStack.addArrangedSubview(helpTextLabel("Display title for this workspace in the sidebar."))
            contentStack.addArrangedSubview(nameField)
            constrainFormFieldToFillWidth(nameField, in: contentStack)

            contentStack.addArrangedSubview(label(text: "Tooltip"))
            contentStack.addArrangedSubview(helpTextLabel("Optional context to display when viewing this workspace."))
            contentStack.addArrangedSubview(tooltipField)
            constrainFormFieldToFillWidth(tooltipField, in: contentStack)
        }

        let card = formSectionCard(
            icon: "plus.rectangle.on.folder", title: "Workspace",
            subtitle: project.isGitRepo ? "Configure branch, title, and directory for your new workspace." : "Title your new workspace.",
            contentViews: [contentStack])
        stack.addArrangedSubview(card)
        constrainFormFieldToFillWidth(card, in: stack)

        // --- Buttons ---
        let createButton = actionButton(
            title: "Create Workspace (Cmd+Return)", symbol: nil, tooltip: "Create workspace (Cmd+Return)", action: #selector(createWorkspace(_:)),
            primary: true)
        createButton.setAccessibilityIdentifier("add-workspace-create")
        createButton.keyEquivalent = "\r"
        createButton.keyEquivalentModifierMask = [.command]
        let cancelButton = actionButton(
            title: "Cancel (Esc)", symbol: nil, tooltip: "Cancel (Esc)", action: #selector(cancelProjectForm), primary: false)
        cancelButton.setAccessibilityIdentifier("add-workspace-cancel")
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(cancelButton)
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(createButton)
        stack.addArrangedSubview(buttonRow)
        constrainFormFieldToFillWidth(buttonRow, in: stack)

        showScrollableDetailStack(stack)

        createButton.tag = storeAddWorkspaceFields(
            projectID: project.id, isGitRepo: project.isGitRepo, branchModePopup: project.isGitRepo ? branchModePopup : nil,
            existingBranchField: project.isGitRepo ? existingBranchField : nil, newBranchField: project.isGitRepo ? newBranchField : nil,
            targetBranchField: project.isGitRepo ? targetBranchField : nil, nameField: nameField,
            directoryNameField: project.isGitRepo ? directoryNameField : nil, tooltipField: tooltipField, autoNameState: autoNameState,
            progressiveInputViews: progressiveInputViews, createButton: createButton)
        activeAddWorkspaceFormTag = createButton.tag
        if let refs = AddWorkspaceFieldCache.shared.cache[createButton.tag] {
            updateAddWorkspaceBranchInputUI(refs: refs)
            updateAddWorkspaceProgressiveDisclosure(refs: refs, branchValue: currentAddWorkspaceBranchValue(refs))
        }
        Task { @MainActor [weak self, weak newBranchField] in
            await Task.yield()
            guard let self else { return }
            if project.isGitRepo { self.window.makeFirstResponder(newBranchField) } else { self.window.makeFirstResponder(nameField) }
        }
        guard project.isGitRepo else { return }
        let formTag = createButton.tag
        Task { @MainActor [weak self, weak targetBranchField, weak existingBranchField] in
            guard let self else { return }
            let result = await Self.branchOptionsSnapshot(projectID: project.id)
            guard activeAddWorkspaceFormTag == formTag else { return }
            guard let targetBranchField else { return }
            guard case .success(let options) = result else { return }
            autoNameState?.branchOptions = options
            let currentValue = targetBranchField.stringValue
            targetBranchField.removeAllItems()
            targetBranchField.addItems(withObjectValues: options)
            if !currentValue.isEmpty {
                targetBranchField.stringValue = currentValue
            } else if let defaultBranch = defaultWorkspaceTargetBranch(project: project, branches: options) {
                targetBranchField.stringValue = defaultBranch
            }
            if let existingBranchField {
                let existingValue = existingBranchField.stringValue
                existingBranchField.removeAllItems()
                existingBranchField.addItems(withObjectValues: options)
                if !existingValue.isEmpty {
                    existingBranchField.stringValue = existingValue
                } else if let suggested = options.first {
                    existingBranchField.stringValue = suggested
                }
            }
            if let refs = AddWorkspaceFieldCache.shared.cache[formTag] {
                self.updateAddWorkspaceProgressiveDisclosure(refs: refs, branchValue: self.currentAddWorkspaceBranchValue(refs))
            }
        }
    }

    private func showWorkspaceDetail(project: ProjectSummary, workspace: WorkspaceSummary) {
        requestVisibleWorkspaceDetailRefreshIfNeeded(reason: "workspace_detail_shown")
        clearInlineWorkspaceFieldRefs()
        activeAddWorkspaceFormTag = nil
        activeAddProjectFormTag = nil
        visibleDetailWorkspaceID = workspace.id
        showingSettings = false
        showingDashboard = false
        updateDashboardRowAppearance()
        activeShortcutCaptureSetting = nil
        for view in detailContainer.subviews { view.removeFromSuperview() }
        detailContainer.wantsLayer = true
        detailContainer.layer?.backgroundColor = sidebarPanelBackgroundColor().cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        // --- Header with status dot ---
        let accentColor = sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
        let runtimeStatus =
            workspaceRuntimeStatusByID[workspace.id]
            ?? WorkspaceRuntimeStatus(
                workspaceID: workspace.id, lifecycleState: WorkspaceLifecycleState(isRunning: workspace.isRunning), runtimeHealth: .healthy,
                hasTrackedRuntimeIndicators: false, runningProcessCount: 0, exitedProcessCount: 0, failedCheckCount: 0, waitingAgentWindowCount: 0,
                missingConfiguredProcessCount: 0, missingConfiguredBrowserSessionCount: 0)
        let isLifecycleRunning = runtimeStatus.lifecycleState == .running
        let statusDot = NSImageView()
        statusDot.image = NSImage(
            systemSymbolName: isLifecycleRunning ? "circle.fill" : "circle", accessibilityDescription: isLifecycleRunning ? "Running" : "Stopped")
        statusDot.contentTintColor = isLifecycleRunning ? accentColor : .tertiaryLabelColor
        statusDot.toolTip = isLifecycleRunning ? "Running" : "Stopped"
        statusDot.setContentHuggingPriority(.required, for: .horizontal)
        let workspaceTitleLabel = NSTextField(labelWithString: inlineWorkspaceFieldDisplayValue(workspace.title, field: .title))
        workspaceTitleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        workspaceTitleLabel.textColor = sidebarPrimaryTextColor(isSelected: false, isArchived: false)
        workspaceTitleLabel.lineBreakMode = .byTruncatingTail
        workspaceTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        workspaceTitleLabel.setAccessibilityIdentifier("workspace-detail-title-label")

        let runtimeWarningIcon = NSImageView()
        runtimeWarningIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Status warning")
        runtimeWarningIcon.contentTintColor = .systemOrange
        runtimeWarningIcon.toolTip = runtimeStatus.warningSummary
        runtimeWarningIcon.translatesAutoresizingMaskIntoConstraints = false
        runtimeWarningIcon.isHidden = runtimeStatus.warningSummary == nil
        runtimeWarningIcon.widthAnchor.constraint(equalToConstant: 12).isActive = true
        runtimeWarningIcon.heightAnchor.constraint(equalToConstant: 12).isActive = true

        let workspaceTitleField = NSTextField(string: workspace.title)
        workspaceTitleField.placeholderString = "Workspace title"
        workspaceTitleField.delegate = self
        workspaceTitleField.font = .systemFont(ofSize: 18, weight: .semibold)
        workspaceTitleField.isHidden = true
        workspaceTitleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        workspaceTitleField.setAccessibilityIdentifier("workspace-detail-title-input")

        let titleSaveButton = NSButton(title: "Save", target: self, action: #selector(saveInlineWorkspaceMetadata(_:)))
        titleSaveButton.controlSize = .small
        titleSaveButton.bezelStyle = .rounded
        titleSaveButton.isHidden = true
        titleSaveButton.setAccessibilityIdentifier("workspace-detail-title-save")

        let titleCancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelInlineWorkspaceMetadata(_:)))
        titleCancelButton.controlSize = .small
        titleCancelButton.bezelStyle = .rounded
        titleCancelButton.isHidden = true
        titleCancelButton.setAccessibilityIdentifier("workspace-detail-title-cancel")
        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.addArrangedSubview(statusDot)
        headerRow.addArrangedSubview(workspaceTitleLabel)
        headerRow.addArrangedSubview(runtimeWarningIcon)
        headerRow.addArrangedSubview(workspaceTitleField)
        headerRow.addArrangedSubview(titleSaveButton)
        headerRow.addArrangedSubview(titleCancelButton)
        headerRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let tag = UUID().uuidString.hashValue
        let refs = InlineWorkspaceDetailFieldRefs(
            workspaceID: workspace.id, field: .title, valueLabel: workspaceTitleLabel, textField: workspaceTitleField, saveButton: titleSaveButton,
            cancelButton: titleCancelButton, originalValue: workspace.title, isEditing: false)
        inlineWorkspaceFieldRefsByTag[tag] = refs
        inlineWorkspaceFieldTagByObjectID[ObjectIdentifier(workspaceTitleField)] = tag
        inlineWorkspaceLabelTagByObjectID[ObjectIdentifier(workspaceTitleLabel)] = tag
        titleSaveButton.tag = tag
        titleCancelButton.tag = tag

        let titleDoubleClick = NSClickGestureRecognizer(target: self, action: #selector(beginInlineWorkspaceMetadataEdit(_:)))
        titleDoubleClick.numberOfClicksRequired = 2
        workspaceTitleLabel.addGestureRecognizer(titleDoubleClick)
        workspaceTitleLabel.toolTip = "Double-click to edit title."

        // --- Directory subtitle ---
        let dirField = NSTextField(string: workspace.dir)
        dirField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        dirField.textColor = .tertiaryLabelColor
        dirField.lineBreakMode = .byTruncatingMiddle
        dirField.isEditable = false
        dirField.isSelectable = true
        dirField.drawsBackground = false
        dirField.isBordered = false
        dirField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dirField.setAccessibilityIdentifier("workspace-detail-dir")

        // --- Inline editable metadata ---
        let inlineTooltipRow = makeInlineWorkspaceMetadataEditRow(
            workspaceID: workspace.id, field: .tooltip, icon: "info.circle", labelText: "Tooltip", value: workspace.tooltip ?? "",
            placeholder: "Optional workspace context", isEditable: true)

        // --- Action buttons (icon-only) ---
        let iconSymbolConfig = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        let launchOrRestartButton: NSButton
        if workspace.isRunning {
            launchOrRestartButton = NSButton(
                image: NSImage(systemSymbolName: "arrow.clockwise.circle", accessibilityDescription: "Restart")!.withSymbolConfiguration(
                    iconSymbolConfig)!, target: self, action: #selector(restartWorkspace(_:)))
        } else {
            launchOrRestartButton = NSButton(
                image: NSImage(systemSymbolName: "play.circle", accessibilityDescription: "Launch")!.withSymbolConfiguration(iconSymbolConfig)!,
                target: self, action: #selector(launchWorkspace(_:)))
        }
        launchOrRestartButton.bezelStyle = .inline
        launchOrRestartButton.isBordered = false
        launchOrRestartButton.toolTip = workspace.isRunning ? "Restart" : "Launch"
        launchOrRestartButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        launchOrRestartButton.setAccessibilityIdentifier("workspace-detail-launch-restart")

        let stopButton = NSButton(
            image: NSImage(systemSymbolName: "stop.circle", accessibilityDescription: "Stop")!.withSymbolConfiguration(iconSymbolConfig)!,
            target: self, action: #selector(stopWorkspace(_:)))
        stopButton.bezelStyle = .inline
        stopButton.isBordered = false
        stopButton.toolTip = "Stop"
        stopButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        stopButton.setAccessibilityIdentifier("workspace-detail-stop")

        let overflowButton = NSButton(
            image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More actions")!, target: self,
            action: #selector(showWorkspaceOverflowMenu(_:)))
        overflowButton.bezelStyle = .inline
        overflowButton.isBordered = false
        overflowButton.toolTip = "More actions"
        overflowButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        overflowButton.setAccessibilityIdentifier("workspace-detail-overflow")

        // Add action buttons to the right side of the header row
        let actionSpacer = NSView()
        actionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerRow.addArrangedSubview(actionSpacer)
        headerRow.addArrangedSubview(launchOrRestartButton)
        headerRow.addArrangedSubview(stopButton)
        headerRow.addArrangedSubview(overflowButton)

        let headerAndActionsRow = NSStackView()
        headerAndActionsRow.orientation = .vertical
        headerAndActionsRow.alignment = .leading
        headerAndActionsRow.spacing = 4
        headerAndActionsRow.addArrangedSubview(headerRow)
        headerAndActionsRow.addArrangedSubview(dirField)
        headerAndActionsRow.setCustomSpacing(2, after: headerRow)
        if let warningSummary = runtimeStatus.warningSummary {
            let warningLabel = NSTextField(labelWithString: warningSummary)
            warningLabel.font = .systemFont(ofSize: 11)
            warningLabel.textColor = .systemOrange
            warningLabel.lineBreakMode = .byTruncatingTail
            warningLabel.maximumNumberOfLines = 1
            headerAndActionsRow.addArrangedSubview(warningLabel)
        }

        let sectionConfig = try? orchestrator.workspaceSettings(workspaceID: workspace.id)
        let trackedWindows = (try? orchestrator.windows(workspaceID: workspace.id)) ?? []
        let runningProcesses = (try? orchestrator.runningProcesses(workspaceID: workspace.id)) ?? []
        let agentWindows = (try? orchestrator.agentWindows(workspaceID: workspace.id)) ?? []
        let browserSessions = (try? orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspace.id)) ?? []
        let configuredProcesses = sectionConfig?.processes ?? []
        let configuredAgentLaunchers = sectionConfig?.agentLaunchers ?? []
        let processEntries = Self.orderedWorkspaceRunProcessEntries(
            configuredProcesses: configuredProcesses, windows: trackedWindows, processes: runningProcesses, agentWindows: agentWindows)
        let processesByID = Dictionary(uniqueKeysWithValues: runningProcesses.map { ($0.id, $0) })
        let shortcutIndices = Self.workspaceDetailShortcutIndices(
            browserSessions: browserSessions, processEntries: processEntries, processesByID: processesByID,
            configuredAgentLaunchers: configuredAgentLaunchers, agentWindows: agentWindows)
        let processStatusByName = Self.workspaceProcessStatusByName(runningProcesses)
        let processesSection = workspaceProcessesSection(
            workspace: workspace, shortcutIndicesByName: shortcutIndices.processesByName, statusByName: processStatusByName)
        let agentLaunchersSection = workspaceAgentLaunchersSection(
            workspace: workspace, shortcutIndicesByName: shortcutIndices.codingAgentsByName, agentWindows: agentWindows,
            trackedWindows: trackedWindows)
        let browserSessionsSection = workspaceBrowserSessionsSection(workspace: workspace, shortcutIndicesByURL: shortcutIndices.browserSessionsByURL)
        let portsSection = workspacePortsSection(workspace: workspace)
        let stopScriptSection = workspaceStopScriptSection(workspace: workspace)

        stack.addArrangedSubview(headerAndActionsRow)
        stack.addArrangedSubview(inlineTooltipRow)
        for section in Self.orderedWorkspaceDetailSections(
            processesSection: processesSection, browserSessionsSection: browserSessionsSection, agentLaunchersSection: agentLaunchersSection,
            portsSection: portsSection, stopScriptSection: stopScriptSection)
        {
            stack.addArrangedSubview(section)
            constrainFormFieldToFillWidth(section, in: stack)
            stack.setCustomSpacing(10, after: section)
        }
        if let agentLaunchersSection { stack.setCustomSpacing(36, after: agentLaunchersSection) }
        if let portsSection { stack.setCustomSpacing(20, after: portsSection) }
        stack.setCustomSpacing(16, after: headerAndActionsRow)
        stack.setCustomSpacing(20, after: inlineTooltipRow)
        constrainFormFieldToFillWidth(inlineTooltipRow, in: stack)
        constrainFormFieldToFillWidth(headerRow, in: headerAndActionsRow)
        constrainFormFieldToFillWidth(dirField, in: headerAndActionsRow)
        constrainFormFieldToFillWidth(headerAndActionsRow, in: stack)
        showScrollableDetailStack(stack)
        detailContainer.layoutSubtreeIfNeeded()
    }

    private func workspaceProcessesSection(
        workspace: WorkspaceSummary, shortcutIndicesByName: [String: Int], statusByName: [String: RowPrimitives.StatusKind]
    ) -> NSView? {
        guard let config = try? orchestrator.workspaceSettings(workspaceID: workspace.id) else { return nil }
        let runningProcesses = (try? orchestrator.runningProcesses(workspaceID: workspace.id)) ?? []
        let runningProcessIDByName = Dictionary(uniqueKeysWithValues: runningProcesses.map { (Self.processRuntimeKey(name: $0.templateName), $0.id) })
        let section = ProcessesSection(processes: config.processes)
        section.onCommit = { [weak self] updated in
            guard let self else { return }
            do {
                if workspace.isRunning {
                    switch Self.runningWorkspaceProcessEditDecision(previous: config.processes, updated: updated) {
                    case .applyImmediately:
                        try orchestrator.updateRunningWorkspaceProcesses(workspaceID: workspace.id, processes: updated, restartChangedCommands: false)
                    case .confirmRestart(let processNames):
                        guard confirmRunningWorkspaceProcessCommandChanges(processNames: processNames) else {
                            reloadData()
                            return
                        }
                        try orchestrator.updateRunningWorkspaceProcesses(workspaceID: workspace.id, processes: updated, restartChangedCommands: true)
                    }
                } else {
                    try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { $0.processes = updated }
                }
                reloadData()
            } catch {
                reloadData()
                showError(error)
            }
        }
        section.onRunProcess = { [weak self] process in
            guard let self else { return }
            let key = Self.processTemplateKey(for: process)
            do {
                try orchestrator.recoverMissingConfiguredProcess(workspaceID: workspace.id, processKey: key)
                reloadData()
            } catch {
                reloadData()
                showError(error)
            }
        }
        section.onStopProcess = { [weak self] process in
            guard let self else { return }
            let key = Self.processTemplateKey(for: process)
            guard let processID = runningProcessIDByName[key] else { return }
            do {
                try orchestrator.stopWorkspaceProcess(workspaceID: workspace.id, processID: processID)
                reloadData()
            } catch {
                reloadData()
                showError(error)
            }
        }
        section.onRestartProcess = { [weak self] process in
            guard let self else { return }
            let key = Self.processTemplateKey(for: process)
            guard let processID = runningProcessIDByName[key] else { return }
            do {
                try orchestrator.restartWorkspaceProcess(workspaceID: workspace.id, processID: processID)
                reloadData()
            } catch {
                reloadData()
                showError(error)
            }
        }
        var nameToIndex: [String: Int] = [:]
        var shortcutMap: [String: String] = [:]
        for process in config.processes {
            guard let name = process.name, !name.isEmpty else { continue }
            guard let index = shortcutIndicesByName[name] else { continue }
            shortcutMap[name] = windowShortcutBadgeText(index: index)
            nameToIndex[name] = index
        }
        // onFocus must be set before shortcutsByName so that the refreshRows
        // triggered by shortcutsByName's didSet sees onFocus already populated.
        section.onFocus = { [weak self] process in
            guard let self, let name = process.name, let index = nameToIndex[name] else { return }
            Task { @MainActor [weak self] in await self?.runWindowShortcut(index: index, startedAt: Date()) }
        }
        section.statusByName = statusByName
        section.shortcutsByName = shortcutMap
        return section.view
    }

    private func confirmRunningWorkspaceProcessCommandChanges(processNames: [String]) -> Bool {
        let alert = NSAlert()
        let names = processNames.joined(separator: ", ")
        alert.messageText = processNames.count == 1 ? "Restart running process?" : "Restart running processes?"
        alert.informativeText =
            "Changing the command for \(names) requires an immediate restart. Choose Restart to apply the new command now, or Cancel Changes to keep the existing configuration."
        alert.alertStyle = .warning
        alert.addButton(withTitle: processNames.count == 1 ? "Restart Process" : "Restart Processes")
        alert.addButton(withTitle: "Cancel Changes")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func orderedWorkspaceDetailSections(
        processesSection: NSView?, browserSessionsSection: NSView?, agentLaunchersSection: NSView?, portsSection: NSView?, stopScriptSection: NSView?
    ) -> [NSView] { [browserSessionsSection, processesSection, agentLaunchersSection, portsSection, stopScriptSection].compactMap { $0 } }

    nonisolated static func codingAgentWindowTitleByAgentID(agentWindows: [AgentWindowRecord], trackedWindows: [WindowRecord]) -> [String: String] {
        agentWindows.reduce(into: [:]) { result, agentWindow in
            guard
                let window = trackedWindows.first(where: {
                    guard $0.role == "terminal" else { return false }
                    if let trackingID = agentWindow.terminalTrackingID, !trackingID.isEmpty, $0.terminalTrackingID == trackingID { return true }
                    if let nativeID = agentWindow.terminalNativeID, !nativeID.isEmpty, $0.terminalNativeID == nativeID { return true }
                    if let windowID = agentWindow.yabaiWindowID ?? agentWindow.windowID, $0.windowID == windowID { return true }
                    return false
                })
            else { return }

            let title =
                (window.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? (window.detail?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            if let title { result[agentWindow.id] = title }
        }
    }

    private func workspaceAgentLaunchersSection(
        workspace: WorkspaceSummary, shortcutIndicesByName: [String: Int], agentWindows: [AgentWindowRecord], trackedWindows: [WindowRecord]
    ) -> NSView? {
        guard let config = try? orchestrator.workspaceSettings(workspaceID: workspace.id) else { return nil }
        let section = AgentLaunchersSection(launchers: config.agentLaunchers)
        section.runtimeAgentWindows = agentWindows
        section.runtimeWindowTitleByAgentWindowID = Self.codingAgentWindowTitleByAgentID(agentWindows: agentWindows, trackedWindows: trackedWindows)
        section.onCommit = { [weak self] updated in
            guard let self else { return }
            do {
                try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { $0.agentLaunchers = updated }
                reloadData()
            } catch { showError(error) }
        }
        var nameToIndex: [String: Int] = [:]
        var shortcutMap: [String: String] = [:]
        for entry in Self.resolvedCodingAgentRunEntries(configuredAgentLaunchers: config.agentLaunchers, agentWindows: agentWindows) {
            guard let name = entry.launcher?.name ?? entry.agentWindow?.label, !name.isEmpty else { continue }
            guard let index = shortcutIndicesByName[name] else { continue }
            shortcutMap[name] = windowShortcutBadgeText(index: index)
            nameToIndex[name] = index
        }
        section.onFocus = { [weak self] launcher in
            guard let self, !launcher.name.isEmpty, let index = nameToIndex[launcher.name] else { return }
            Task { @MainActor [weak self] in await self?.runWindowShortcut(index: index, startedAt: Date()) }
        }
        section.shortcutsByName = shortcutMap
        return section.view
    }

    private func workspaceBrowserSessionsSection(workspace: WorkspaceSummary, shortcutIndicesByURL: [String: Int]) -> NSView? {
        guard let config = try? orchestrator.workspaceSettings(workspaceID: workspace.id) else { return nil }
        let resolvedSessions = (try? orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspace.id)) ?? []
        let displayURLs = Self.browserSessionDisplayURLs(configuredSessions: config.browserSessions, resolvedSessions: resolvedSessions)
        let section = BrowserSessionsSection(sessions: config.browserSessions, collapsedDisplayURLs: displayURLs)
        section.onCommit = { [weak self] updated in
            guard let self else { return }
            do {
                try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { $0.browserSessions = updated }
                reloadData()
            } catch { showError(error) }
        }
        var urlToIndex: [String: Int] = [:]
        var shortcutMap: [String: String] = [:]
        var resolvedSessionCursor = 0
        for session in config.browserSessions {
            guard let url = session.url, !url.isEmpty else { continue }
            guard
                let matchedURL = Self.matchedBrowserSessionShortcutURL(
                    configuredSession: session, rawURL: url, resolvedSessions: resolvedSessions, resolvedSessionCursor: &resolvedSessionCursor,
                    shortcutIndicesByURL: shortcutIndicesByURL)
            else { continue }
            guard let index = shortcutIndicesByURL[matchedURL] else { continue }
            shortcutMap[url] = windowShortcutBadgeText(index: index)
            urlToIndex[url] = index
        }
        section.onFocus = { [weak self] session in
            guard let self, let url = session.url, let index = urlToIndex[url] else { return }
            Task { @MainActor [weak self] in await self?.runWindowShortcut(index: index, startedAt: Date()) }
        }
        section.shortcutsByURL = shortcutMap
        return section.view
    }

    static func browserSessionDisplayURLs(configuredSessions: [BrowserSession], resolvedSessions: [BrowserSession]) -> [String?] {
        var resolvedSessionCursor = 0
        return configuredSessions.map { session in
            guard let rawURL = session.url, !rawURL.isEmpty else { return nil }
            return matchedBrowserSessionResolvedURL(
                configuredSession: session, rawURL: rawURL, resolvedSessions: resolvedSessions, resolvedSessionCursor: &resolvedSessionCursor)
                ?? rawURL
        }
    }

    static func matchedBrowserSessionResolvedURL(
        configuredSession: BrowserSession, rawURL: String, resolvedSessions: [BrowserSession], resolvedSessionCursor: inout Int
    ) -> String? {
        let resolvedURLs = Set(resolvedSessions.compactMap(\.url).filter { !$0.isEmpty })
        return matchedBrowserSessionShortcutURL(
            configuredSession: configuredSession, rawURL: rawURL, resolvedSessions: resolvedSessions, resolvedSessionCursor: &resolvedSessionCursor,
            shortcutIndicesByURL: Dictionary(uniqueKeysWithValues: resolvedURLs.map { ($0, 0) }))
    }

    static func matchedBrowserSessionShortcutURL(
        configuredSession: BrowserSession, rawURL: String, resolvedSessions: [BrowserSession], resolvedSessionCursor: inout Int,
        shortcutIndicesByURL: [String: Int]
    ) -> String? {
        if shortcutIndicesByURL[rawURL] != nil { return rawURL }

        let trimmedName = configuredSession.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedName, !trimmedName.isEmpty,
            let matched = resolvedSessions.first(where: {
                $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedName && ($0.url.map { shortcutIndicesByURL[$0] != nil } ?? false)
            })?.url
        {
            return matched
        }

        guard rawURL.contains("$") else { return nil }
        while resolvedSessionCursor < resolvedSessions.count {
            let candidate = resolvedSessions[resolvedSessionCursor]
            resolvedSessionCursor += 1
            guard let candidateURL = candidate.url, shortcutIndicesByURL[candidateURL] != nil else { continue }
            return candidateURL
        }
        return nil
    }

    private func workspacePortsSection(workspace: WorkspaceSummary) -> NSView? {
        guard let config = try? orchestrator.workspaceSettings(workspaceID: workspace.id) else { return nil }
        let reservedPorts = (try? orchestrator.workspacePortsNamed(workspaceID: workspace.id).map(\.port)) ?? []
        let section = PortsSection(ports: config.ports, collapsedDisplayPorts: reservedPorts.map(Optional.some))
        section.onCommit = { [weak self] updated in
            guard let self else { return }
            do {
                try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { $0.ports = updated }
                reloadData()
            } catch { showError(error) }
        }
        return section.view
    }

    private func workspaceStopScriptSection(workspace: WorkspaceSummary) -> NSView? {
        guard let config = try? orchestrator.workspaceSettings(workspaceID: workspace.id) else { return nil }
        let section = StopScriptSection(value: config.stopScript ?? "")
        section.onCommit = { [weak self] value in
            guard let self else { return }
            do {
                try orchestrator.updateWorkspaceSettings(workspaceID: workspace.id) { $0.stopScript = value.isEmpty ? nil : value }
                reloadData()
            } catch { showError(error) }
        }
        return section.view
    }

    private func clearInlineWorkspaceFieldRefs() {
        teardownInlineWorkspaceOutsideClickMonitor()
        inlineWorkspaceFieldRefsByTag.removeAll()
        inlineWorkspaceFieldTagByObjectID.removeAll()
        inlineWorkspaceLabelTagByObjectID.removeAll()
    }

    private func isView(_ view: NSView?, descendantOf ancestor: NSView) -> Bool {
        var current = view
        while let node = current {
            if node === ancestor { return true }
            current = node.superview
        }
        return false
    }

    private func activeInlineWorkspaceEditTags() -> [Int] { inlineWorkspaceFieldRefsByTag.compactMap { key, refs in refs.isEditing ? key : nil } }

    private func cancelInlineWorkspaceMetadataEdit(tag: Int) { endInlineWorkspaceMetadataEdit(tag: tag, keepCurrentValueAsOriginal: false) }

    private func setupInlineWorkspaceOutsideClickMonitorIfNeeded() {
        guard inlineWorkspaceOutsideClickMonitor == nil else { return }
        inlineWorkspaceOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            let activeTags = self.activeInlineWorkspaceEditTags()
            guard !activeTags.isEmpty else { return event }
            guard let contentView = self.window?.contentView else { return event }
            let point = contentView.convert(event.locationInWindow, from: nil)
            let hitView = contentView.hitTest(point)
            for tag in activeTags {
                guard let refs = self.inlineWorkspaceFieldRefsByTag[tag] else { continue }
                if self.isView(hitView, descendantOf: refs.textField) || self.isView(hitView, descendantOf: refs.saveButton)
                    || self.isView(hitView, descendantOf: refs.cancelButton)
                {
                    return event
                }
            }
            for tag in activeTags { self.cancelInlineWorkspaceMetadataEdit(tag: tag) }
            return event
        }
    }

    private func teardownInlineWorkspaceOutsideClickMonitor() {
        if let inlineWorkspaceOutsideClickMonitor {
            NSEvent.removeMonitor(inlineWorkspaceOutsideClickMonitor)
            self.inlineWorkspaceOutsideClickMonitor = nil
        }
    }

    private func inlineWorkspaceFieldDisplayValue(_ value: String, field: InlineWorkspaceDetailField) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field {
        case .tooltip: return trimmed.isEmpty ? "No tooltip" : trimmed
        case .title, .branch: return trimmed
        }
    }

    private func isProtectedBranchName(_ branch: String) -> Bool {
        let normalized = branch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "main" || normalized == "master"
    }

    private func makeInlineWorkspaceMetadataEditRow(
        workspaceID: String, field: InlineWorkspaceDetailField, icon: String, labelText: String, value: String, placeholder: String, isEditable: Bool
    ) -> NSView {
        let automationID: String =
            switch field {
            case .title: "workspace-detail-title"
            case .branch: "workspace-detail-branch"
            case .tooltip: "workspace-detail-tooltip"
            }
        let isMultiline = field == .tooltip
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = isMultiline ? .top : .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setAccessibilityIdentifier("\(automationID)-row")

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: labelText)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        let valueLabel = NSTextField(labelWithString: inlineWorkspaceFieldDisplayValue(value, field: field))
        valueLabel.font = .systemFont(ofSize: 12)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.lineBreakMode = isMultiline ? .byWordWrapping : .byTruncatingTail
        if isMultiline { valueLabel.maximumNumberOfLines = 0 }
        valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        valueLabel.setAccessibilityIdentifier("\(automationID)-label")
        valueLabel.toolTip =
            isEditable
            ? "Double-click to edit \(labelText.lowercased())."
            : (field == .branch ? "Protected branch names main/master cannot be renamed." : "\(labelText) is not editable.")

        let textField = NSTextField(string: value)
        textField.placeholderString = placeholder
        textField.delegate = self
        textField.isEnabled = isEditable
        textField.isHidden = true
        textField.font = .systemFont(ofSize: 12)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textField.setAccessibilityIdentifier("\(automationID)-input")
        if isMultiline {
            textField.usesSingleLineMode = false
            (textField.cell as? NSTextFieldCell)?.wraps = true
            (textField.cell as? NSTextFieldCell)?.isScrollable = false
        }

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveInlineWorkspaceMetadata(_:)))
        saveButton.controlSize = .small
        saveButton.bezelStyle = .rounded
        saveButton.isHidden = true
        saveButton.setAccessibilityIdentifier("\(automationID)-save")

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelInlineWorkspaceMetadata(_:)))
        cancelButton.controlSize = .small
        cancelButton.bezelStyle = .rounded
        cancelButton.isHidden = true
        cancelButton.setAccessibilityIdentifier("\(automationID)-cancel")

        row.addArrangedSubview(iconView)
        row.addArrangedSubview(valueLabel)
        row.addArrangedSubview(textField)
        row.addArrangedSubview(saveButton)
        row.addArrangedSubview(cancelButton)

        if isEditable {
            let tag = UUID().uuidString.hashValue
            let refs = InlineWorkspaceDetailFieldRefs(
                workspaceID: workspaceID, field: field, valueLabel: valueLabel, textField: textField, saveButton: saveButton,
                cancelButton: cancelButton, originalValue: value, isEditing: false)
            inlineWorkspaceFieldRefsByTag[tag] = refs
            inlineWorkspaceFieldTagByObjectID[ObjectIdentifier(textField)] = tag
            inlineWorkspaceLabelTagByObjectID[ObjectIdentifier(valueLabel)] = tag
            saveButton.tag = tag
            cancelButton.tag = tag

            let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(beginInlineWorkspaceMetadataEdit(_:)))
            doubleClick.numberOfClicksRequired = 2
            valueLabel.addGestureRecognizer(doubleClick)
        } else {
            textField.toolTip = field == .branch ? "Protected branch names main/master cannot be renamed." : "\(labelText) is not editable."
        }

        return row
    }

    private func normalizeInlineWorkspaceMetadataValue(_ value: String, for field: InlineWorkspaceDetailField) -> String {
        switch field {
        case .title, .branch: return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .tooltip: return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func updateInlineWorkspaceMetadataButtons(tag: Int) {
        guard let refs = inlineWorkspaceFieldRefsByTag[tag] else { return }
        refs.saveButton.isHidden = !refs.isEditing
        refs.cancelButton.isHidden = !refs.isEditing
    }

    @objc private func beginInlineWorkspaceMetadataEdit(_ sender: NSClickGestureRecognizer) {
        guard let valueLabel = sender.view as? NSTextField else { return }
        guard let tag = inlineWorkspaceLabelTagByObjectID[ObjectIdentifier(valueLabel)] else { return }
        if let refs = inlineWorkspaceFieldRefsByTag[tag], refs.field == .branch, isProtectedBranchName(refs.originalValue) { return }
        for activeTag in activeInlineWorkspaceEditTags() where activeTag != tag { cancelInlineWorkspaceMetadataEdit(tag: activeTag) }
        guard var refs = inlineWorkspaceFieldRefsByTag[tag] else { return }
        refs.isEditing = true
        refs.valueLabel.isHidden = true
        refs.textField.stringValue = refs.originalValue
        refs.textField.isHidden = false
        refs.textField.isEnabled = true
        setupInlineWorkspaceOutsideClickMonitorIfNeeded()
        refs.textField.becomeFirstResponder()
        inlineWorkspaceFieldRefsByTag[tag] = refs
        updateInlineWorkspaceMetadataButtons(tag: tag)
    }

    private func endInlineWorkspaceMetadataEdit(tag: Int, keepCurrentValueAsOriginal: Bool) {
        guard var refs = inlineWorkspaceFieldRefsByTag[tag] else { return }
        if keepCurrentValueAsOriginal {
            refs.originalValue = normalizeInlineWorkspaceMetadataValue(refs.textField.stringValue, for: refs.field)
        } else {
            refs.textField.stringValue = refs.originalValue
        }
        refs.valueLabel.stringValue = inlineWorkspaceFieldDisplayValue(refs.originalValue, field: refs.field)
        refs.valueLabel.isHidden = false
        refs.textField.isHidden = true
        refs.isEditing = false
        refs.saveButton.isHidden = true
        refs.cancelButton.isHidden = true
        inlineWorkspaceFieldRefsByTag[tag] = refs
        if activeInlineWorkspaceEditTags().isEmpty { teardownInlineWorkspaceOutsideClickMonitor() }
    }

    private func saveInlineWorkspaceMetadata(tag: Int) {
        guard var refs = inlineWorkspaceFieldRefsByTag[tag] else { return }
        do {
            switch refs.field {
            case .title:
                let title = refs.textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                try orchestrator.updateWorkspaceName(workspaceID: refs.workspaceID, name: title)
                refs.originalValue = title
            case .branch:
                let branch = refs.textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                try orchestrator.updateWorkspaceMetadata(workspaceID: refs.workspaceID, branch: branch)
                refs.originalValue = branch
            case .tooltip:
                let trimmedTooltip = refs.textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let tooltip = trimmedTooltip.isEmpty ? nil : trimmedTooltip
                try orchestrator.updateWorkspaceTooltip(workspaceID: refs.workspaceID, tooltip: tooltip)
                refs.originalValue = tooltip ?? ""
            }
            refs.valueLabel.stringValue = inlineWorkspaceFieldDisplayValue(refs.originalValue, field: refs.field)
            inlineWorkspaceFieldRefsByTag[tag] = refs
            endInlineWorkspaceMetadataEdit(tag: tag, keepCurrentValueAsOriginal: true)
            reloadData()
        } catch { showError(error) }
    }

    @objc private func saveInlineWorkspaceMetadata(_ sender: NSButton) { saveInlineWorkspaceMetadata(tag: sender.tag) }

    @objc private func cancelInlineWorkspaceMetadata(_ sender: NSButton) {
        endInlineWorkspaceMetadataEdit(tag: sender.tag, keepCurrentValueAsOriginal: false)
    }

    private func label(text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func helpTextLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    private func attachAsyncClickAction(to view: NSView, label: String, shortcut: String, action: @escaping () async -> Void) {
        let profiledAction = { [weak self] in
            let startedAt = Date()
            self?.logWindowRowClickProfile("stage=received label=\(label) shortcut=\(shortcut)")
            await action()
            self?.logWindowRowClickProfile(
                "stage=completed label=\(label) shortcut=\(shortcut) elapsed_ms=\(self?.windowShortcutElapsedMS(since: startedAt) ?? 0)")
        }
        let target = ClickTarget(profiledAction)
        let recognizer = NSClickGestureRecognizer(target: target, action: #selector(ClickTarget.clicked(_:)))
        view.addGestureRecognizer(recognizer)
        objc_setAssociatedObject(view, &Self.clickTargetAssocKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    nonisolated static func terminalFallbackRowText(name: String?, detail: String?, app _: String) -> (label: String, detail: String?) {
        let cleanedName = name?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
            of: #"^[*-]\s*"#, with: "", options: .regularExpression)
        let cleanedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
            of: #"^[*-]\s*"#, with: "", options: .regularExpression)
        return (cleanedName?.isEmpty == false ? cleanedName! : "Terminal", cleanedDetail?.isEmpty == false ? cleanedDetail : nil)
    }

    private func windowRow(
        icon: String, iconColor: NSColor, label: String, detail: String? = nil, shortcut: String, processStatus: RunningProcessState? = nil,
        agentStatus: AgentWindowStatus? = nil, automationID: String? = nil, trailingAccessory: NSView? = nil, action: (() async -> Void)? = nil
    ) -> NSView {
        let container = ClickableRowView(isInteractive: action != nil)
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityLabel(label)
        if let detail, !detail.isEmpty { container.setAccessibilityValue(detail) }
        if let automationID { container.setAccessibilityIdentifier("\(automationID)-row") }

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        iconView.contentTintColor = iconColor
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let labelField = NSTextField(labelWithString: label)
        if let automationID { labelField.setAccessibilityIdentifier("\(automationID)-label") }
        labelField.font = detail == nil ? .systemFont(ofSize: 12) : .systemFont(ofSize: 12, weight: .semibold)
        labelField.textColor = .labelColor
        labelField.lineBreakMode = .byTruncatingTail
        labelField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        labelField.setContentCompressionResistancePriority(.required, for: .horizontal)

        let detailField = NSTextField(labelWithString: detail ?? "")
        if let automationID { detailField.setAccessibilityIdentifier("\(automationID)-detail") }
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        detailField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailField.isHidden = detail == nil

        let badge = NSTextField(labelWithString: shortcut)
        badge.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        badge.textColor = .secondaryLabelColor
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        let statusSlot = NSView()
        statusSlot.translatesAutoresizingMaskIntoConstraints = false
        statusSlot.setContentHuggingPriority(.required, for: .horizontal)
        statusSlot.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            statusSlot.widthAnchor.constraint(equalToConstant: 10), statusSlot.heightAnchor.constraint(greaterThanOrEqualToConstant: 10),
        ])

        // Status indicator (spinner/dot/spacer) always placed before badge so shortcut hints align.
        if let agentStatus {
            if agentStatus == .spinning {
                let spinner = NSProgressIndicator()
                if let automationID { spinner.setAccessibilityIdentifier("\(automationID)-status-spinning") }
                spinner.style = .spinning
                spinner.controlSize = .mini
                spinner.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    spinner.widthAnchor.constraint(equalToConstant: 10), spinner.heightAnchor.constraint(equalToConstant: 10),
                ])
                spinner.setContentHuggingPriority(.required, for: .horizontal)
                spinner.setContentCompressionResistancePriority(.required, for: .horizontal)
                spinner.startAnimation(nil)
                statusSlot.addSubview(spinner)
                NSLayoutConstraint.activate([
                    spinner.centerXAnchor.constraint(equalTo: statusSlot.centerXAnchor),
                    spinner.centerYAnchor.constraint(equalTo: statusSlot.centerYAnchor),
                ])
            } else {
                let statusIconName: String
                let statusColor: NSColor
                switch agentStatus {
                case .waiting:
                    statusIconName = "exclamationmark.triangle.fill"
                    statusColor = .systemOrange
                case .done:
                    statusIconName = "circle.fill"
                    statusColor = .systemGreen
                default:
                    statusIconName = "circle.fill"
                    statusColor = .tertiaryLabelColor
                }
                let statusDot = NSImageView()
                if let automationID { statusDot.setAccessibilityIdentifier("\(automationID)-status-\(agentStatus.rawValue)") }
                statusDot.image = NSImage(systemSymbolName: statusIconName, accessibilityDescription: agentStatus.rawValue)
                statusDot.contentTintColor = statusColor
                statusDot.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    statusDot.widthAnchor.constraint(equalToConstant: 10), statusDot.heightAnchor.constraint(equalToConstant: 10),
                ])
                statusDot.setContentHuggingPriority(.required, for: .horizontal)
                statusDot.setContentCompressionResistancePriority(.required, for: .horizontal)
                statusSlot.addSubview(statusDot)
                NSLayoutConstraint.activate([
                    statusDot.centerXAnchor.constraint(equalTo: statusSlot.centerXAnchor),
                    statusDot.centerYAnchor.constraint(equalTo: statusSlot.centerYAnchor),
                ])
            }
        } else if let processStatus {
            let statusIconName: String
            let statusColor: NSColor
            switch processStatus {
            case .running:
                statusIconName = "circle.fill"
                statusColor = .systemGreen
            case .exited:
                statusIconName = "circle"
                statusColor = .systemRed
            case .idle:
                statusIconName = "circle"
                statusColor = .tertiaryLabelColor
            }
            let statusDot = NSImageView()
            statusDot.image = NSImage(systemSymbolName: statusIconName, accessibilityDescription: processStatus.rawValue)
            statusDot.contentTintColor = statusColor
            statusDot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([statusDot.widthAnchor.constraint(equalToConstant: 8), statusDot.heightAnchor.constraint(equalToConstant: 8)])
            statusDot.setContentHuggingPriority(.required, for: .horizontal)
            statusDot.setContentCompressionResistancePriority(.required, for: .horizontal)
            statusSlot.addSubview(statusDot)
            NSLayoutConstraint.activate([
                statusDot.centerXAnchor.constraint(equalTo: statusSlot.centerXAnchor),
                statusDot.centerYAnchor.constraint(equalTo: statusSlot.centerYAnchor),
            ])
        }

        let contentRow = NSStackView()
        contentRow.orientation = .horizontal
        contentRow.alignment = .centerY
        contentRow.spacing = 8
        contentRow.translatesAutoresizingMaskIntoConstraints = false

        if let action { attachAsyncClickAction(to: contentRow, label: label, shortcut: shortcut, action: action) }

        contentRow.addArrangedSubview(statusSlot)
        contentRow.addArrangedSubview(badge)
        contentRow.addArrangedSubview(iconView)
        contentRow.addArrangedSubview(labelField)
        contentRow.addArrangedSubview(detailField)
        contentRow.addArrangedSubview(NSView())
        row.addArrangedSubview(contentRow)
        contentRow.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contentRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let trailingAccessory {
            trailingAccessory.setContentHuggingPriority(.required, for: .horizontal)
            trailingAccessory.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(trailingAccessory)
        }

        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor), row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor), row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func logWindowRowClickProfile(_ message: String) {
        guard ProcessInfo.processInfo.environment["DEBUG"] == "1" else { return }
        fputs("muxy: window_row_click \(message)\n", stderr)
    }

    private func statusCheckSubRow(name: String, color: NSColor, status: StatusCheckStatus) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 2, left: 28, bottom: 2, right: 8)

        let arrow = NSTextField(labelWithString: "↳")
        arrow.font = .systemFont(ofSize: 10)
        arrow.textColor = .tertiaryLabelColor
        arrow.setContentHuggingPriority(.required, for: .horizontal)

        let dot = NSImageView()
        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: status.rawValue)
        dot.contentTintColor = color
        dot.setContentHuggingPriority(.required, for: .horizontal)
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 8), dot.heightAnchor.constraint(equalToConstant: 8)])

        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(arrow)
        row.addArrangedSubview(dot)
        row.addArrangedSubview(label)
        return row
    }

    private func sectionHeader(icon: String, title: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6

        let accentColor = sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
        let iconView = NSImageView()
        if let img = NSImage(systemSymbolName: icon, accessibilityDescription: title) {
            let config = NSImage.SymbolConfiguration(paletteColors: [accentColor])
            iconView.image = img.withSymbolConfiguration(config)
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([iconView.widthAnchor.constraint(equalToConstant: 16), iconView.heightAnchor.constraint(equalToConstant: 16)])

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor

        row.addArrangedSubview(iconView)
        row.addArrangedSubview(label)
        return row
    }

    private func labeledValue(title: String, value: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        let label = NSTextField(labelWithString: "\(title):")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        let valueField = NSTextField(labelWithString: value)
        valueField.font = .systemFont(ofSize: 12)
        valueField.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(valueField)
        return stack
    }

    private func statusRow(isRunning: Bool) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 8
        let label = NSTextField(labelWithString: "Status:")
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: isRunning ? "circle.fill" : "circle", accessibilityDescription: "Status")
        icon.contentTintColor = isRunning ? .systemGreen : .tertiaryLabelColor
        icon.toolTip = isRunning ? "Running" : "Stopped"
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(icon)
        return stack
    }

    private struct EditorOption {
        let preference: EditorPreference
        let displayName: String
        let bundleName: String
    }

    private func installedEditorOptions() -> [EditorOption] {
        let candidates = [
            EditorOption(preference: .vscode, displayName: "VS Code", bundleName: "Visual Studio Code.app"),
            EditorOption(preference: .cursor, displayName: "Cursor", bundleName: "Cursor.app"),
            EditorOption(preference: .windsurf, displayName: "Windsurf", bundleName: "Windsurf.app"),
        ]
        return candidates.filter { isEditorInstalled(bundleName: $0.bundleName) }
    }

    private func isEditorInstalled(bundleName: String) -> Bool {
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let userApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        let paths = [applications.appendingPathComponent(bundleName).path, userApplications.appendingPathComponent(bundleName).path]
        return paths.contains { FileManager.default.fileExists(atPath: $0) }
    }

    private func editorDisplayName(_ editor: EditorPreference) -> String {
        switch editor {
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        case .windsurf: return "Windsurf"
        case .vim: return "Vim"
        case .none: return "None"
        }
    }

    private func shortcutSettingsRow(setting: ShortcutSetting) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8

        let title = NSTextField(labelWithString: setting.label)
        title.font = .systemFont(ofSize: 12)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let captureButton = actionButton(
            title: shortcutCaptureButtonTitle(setting: setting), symbol: nil, tooltip: "Click to capture shortcut",
            action: #selector(beginShortcutCapture(_:)), primary: false)
        captureButton.identifier = NSUserInterfaceItemIdentifier(setting.settingKey)
        captureButton.alignment = .center
        captureButton.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        captureButton.isBordered = false
        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        captureButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        captureButton.heightAnchor.constraint(equalToConstant: 28).isActive = true
        captureButton.widthAnchor.constraint(equalToConstant: 140).isActive = true
        updateShortcutCaptureButtonText(captureButton, text: shortcutCaptureButtonTitle(setting: setting), active: false)
        styleShortcutCaptureButton(captureButton, active: false)
        shortcutButtonsBySetting[setting.settingKey] = captureButton

        let resetButton = actionButton(
            title: "Reset", symbol: nil, tooltip: "Reset to default shortcut", action: #selector(resetShortcutSetting(_:)), primary: false)
        resetButton.identifier = NSUserInterfaceItemIdentifier(setting.settingKey)
        resetButton.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(title)
        row.addArrangedSubview(captureButton)
        row.addArrangedSubview(resetButton)
        return row
    }

    private func shortcutCaptureButtonTitle(setting: ShortcutSetting) -> String {
        if activeShortcutCaptureSetting == setting {
            if setting.capturesModifierOnly, !pendingLeaderCaptureModifiers.isEmpty {
                return displayShortcutText(modifiers: pendingLeaderCaptureModifiers)
            }
            return setting.capturesModifierOnly ? "Hold modifiers" : "Press shortcut"
        }
        return shortcutDisplayText(for: setting)
    }

    private func shortcutDisplayText(for setting: ShortcutSetting) -> String {
        if setting == .guiLeaderHotkey { return displayShortcutText(modifiers: shortcutLeaderModifiers) }
        guard let spec = shortcutSpec(for: setting) else { return setting.defaultSpec }
        if setting.usesDigitRangeCapture { return displayShortcutText(spec, keyText: "1-9") }
        return spec.normalized
    }

    private func actionTitle(base: String, setting: ShortcutSetting) -> String { "\(base) (\(shortcutHint(for: setting)))" }

    private func actionTooltip(base: String, setting: ShortcutSetting) -> String { "\(base) (\(shortcutHint(for: setting)))" }

    private func shortcutHint(for setting: ShortcutSetting) -> String {
        if setting == .guiLeaderHotkey { return displayShortcut(modifiers: shortcutLeaderModifiers) }
        guard let spec = shortcutSpec(for: setting) else { return setting.defaultSpec }
        if setting.usesDigitRangeCapture { return displayShortcut(spec, keyText: "1-9") }
        return displayShortcut(spec)
    }

    private func workspaceDetailShortcutFooterRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        workspaceShortcutFooterRowView = row
        workspaceShortcutFooterLabels = []

        for index in workspaceDetailShortcutFooterSegments().indices {
            if index > 0 {
                let separator = NSTextField(labelWithString: "•")
                separator.font = .systemFont(ofSize: 11, weight: .medium)
                separator.textColor = .tertiaryLabelColor
                row.addArrangedSubview(separator)
            }

            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            workspaceShortcutFooterLabels.append(label)
            row.addArrangedSubview(label)
        }

        row.addArrangedSubview(NSView())
        return row
    }

    private func refreshWorkspaceShortcutFooterRow() {
        let segments = workspaceDetailShortcutFooterSegments()
        guard workspaceShortcutFooterLabels.count == segments.count else { return }
        for (index, label) in workspaceShortcutFooterLabels.enumerated() { label.stringValue = segments[index] }
        workspaceShortcutFooterRowView?.needsLayout = true
    }

    private func workspaceDetailShortcutFooterSegments() -> [String] {
        [
            "Dashboard \(footerShortcutHint(for: .guiDashboardShortcut))", "Next window \(footerShortcutHint(for: .guiNextShortcut))",
            "Prev window \(footerShortcutHint(for: .guiPreviousShortcut))", "Settings \(footerShortcutHint(for: .guiOpenSettingsShortcut))",
        ]
    }

    private func footerShortcutHint(for setting: ShortcutSetting) -> String {
        if setting == .guiLeaderHotkey { return displayShortcut(modifiers: shortcutLeaderModifiers, separator: " ") }
        guard let spec = shortcutSpec(for: setting) else { return setting.defaultSpec }
        if setting.usesDigitRangeCapture { return displayShortcut(spec, separator: " ", keyText: "1-9") }
        return displayShortcut(spec, separator: " ")
    }

    private func displayShortcut(_ spec: HotkeySpec) -> String { displayShortcut(spec, separator: "") }

    private func displayShortcut(_ spec: HotkeySpec, keyText: String) -> String { displayShortcut(spec, separator: "", keyText: keyText) }

    private func displayShortcut(_ spec: HotkeySpec, separator: String) -> String {
        displayShortcut(spec, separator: separator, keyText: displayShortcutKey(spec.key))
    }

    private func displayShortcut(_ spec: HotkeySpec, separator: String, keyText: String) -> String {
        displayShortcut(modifiers: spec.modifiers, separator: separator, keyText: keyText)
    }

    private func displayShortcut(modifiers: Set<HotkeyModifier>) -> String { displayShortcut(modifiers: modifiers, separator: "") }

    private func displayShortcut(modifiers: Set<HotkeyModifier>, separator: String) -> String {
        displayShortcut(modifiers: modifiers, separator: separator, keyText: nil)
    }

    private func displayShortcut(modifiers: Set<HotkeyModifier>, separator: String, keyText: String?) -> String {
        var parts: [String] = []
        if modifiers.contains(.cmd) { parts.append("⌘") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.alt) { parts.append("⌥") }
        if modifiers.contains(.ctrl) { parts.append("⌃") }
        if let keyText { parts.append(keyText) }
        return parts.joined(separator: separator)
    }

    private func displayShortcutText(_ spec: HotkeySpec, keyText: String) -> String {
        displayShortcutText(modifiers: spec.modifiers, keyText: keyText)
    }

    private func displayShortcutText(modifiers: Set<HotkeyModifier>) -> String { displayShortcutText(modifiers: modifiers, keyText: nil) }

    private func displayShortcutText(modifiers: Set<HotkeyModifier>, keyText: String?) -> String {
        var parts: [String] = []
        if modifiers.contains(.cmd) { parts.append("cmd") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.alt) { parts.append("alt") }
        if modifiers.contains(.ctrl) { parts.append("ctrl") }
        if let keyText { parts.append(keyText) }
        return parts.joined(separator: "+")
    }

    private func displayShortcutKey(_ key: String) -> String {
        switch key {
        case "return", "enter": return "↩"
        case "space": return "Space"
        case "tab": return "⇥"
        case "escape": return "⎋"
        case "delete", "backspace": return "⌫"
        case "forwarddelete": return "⌦"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        default: return key.uppercased()
        }
    }

    @objc private func beginShortcutCapture(_ sender: NSButton) {
        guard let settingKey = sender.identifier?.rawValue, let setting = ShortcutSetting(settingKey: settingKey) else { return }

        pendingLeaderCaptureModifiers = []
        if activeShortcutCaptureSetting == setting { activeShortcutCaptureSetting = nil } else { activeShortcutCaptureSetting = setting }
        refreshShortcutCaptureButtons()
    }

    @objc private func resetShortcutSetting(_ sender: NSButton) {
        guard let settingKey = sender.identifier?.rawValue, let setting = ShortcutSetting(settingKey: settingKey) else { return }

        if activeShortcutCaptureSetting == setting {
            pendingLeaderCaptureModifiers = []
            activeShortcutCaptureSetting = nil
            refreshShortcutCaptureButtons()
        }

        do {
            try setShortcutSetting(setting: setting, value: nil)
            pendingLeaderCaptureModifiers = []
            loadShortcutSpecs()
            setupGlobalHotkey()
            refreshSelection()
        } catch { showError(error) }
    }

    private func refreshShortcutCaptureButtons() {
        for (settingKey, button) in shortcutButtonsBySetting {
            guard let setting = ShortcutSetting(settingKey: settingKey) else { continue }
            let isActive = activeShortcutCaptureSetting == setting
            updateShortcutCaptureButtonText(button, text: shortcutCaptureButtonTitle(setting: setting), active: isActive)
            styleShortcutCaptureButton(button, active: isActive)
            if activeShortcutCaptureSetting == setting {
                button.toolTip =
                    setting.capturesModifierOnly ? "Hold a modifier combination (Esc to cancel)" : "Press a key combination (Esc to cancel)"
            } else {
                button.toolTip = "Click to capture shortcut"
            }
        }
    }

    private func styleShortcutCaptureButton(_ button: NSButton, active: Bool) {
        button.wantsLayer = true
        button.layer?.cornerRadius = UIRadius.compact
        button.layer?.borderWidth = 1
        button.layer?.backgroundColor = shortcutKeycapBackgroundColor(active: active).cgColor
        button.layer?.borderColor = shortcutKeycapBorderColor(active: active).cgColor
    }

    private func updateShortcutCaptureButtonText(_ button: NSButton, text: String, active: Bool) {
        let color: NSColor = active ? .white : .labelColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: color, .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .paragraphStyle: paragraph,
        ]
        button.attributedTitle = NSAttributedString(string: "  \(text)  ", attributes: attrs)
    }

    private func shortcutKeycapBackgroundColor(active: Bool) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if active {
                return isDark
                    ? NSColor(calibratedRed: 0.13, green: 0.28, blue: 0.42, alpha: 1.0)
                    : NSColor(calibratedRed: 0.80, green: 0.89, blue: 0.97, alpha: 1.0)
            }
            return isDark ? NSColor(calibratedWhite: 0.16, alpha: 1.0) : NSColor(calibratedWhite: 0.82, alpha: 1.0)
        }
    }

    private func shortcutKeycapBorderColor(active: Bool) -> NSColor {
        NSColor(name: nil) { appearance in
            if active { return .systemBlue }
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(calibratedWhite: 0.28, alpha: 1.0) : NSColor(calibratedWhite: 0.65, alpha: 1.0)
        }
    }

    private func sidebarSectionHeader(title: String, actions: [(symbol: String, tooltip: String, action: Selector)]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor

        stack.addArrangedSubview(label)
        stack.addArrangedSubview(NSView())
        for action in actions {
            let button = sidebarRowIconButton(symbol: action.symbol, tooltip: action.tooltip, action: action.action)
            stack.addArrangedSubview(button)
        }

        return stack
    }

    private func sidebarRowIconButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?.withSymbolConfiguration(
            .init(pointSize: 12, weight: .semibold))
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        return button
    }

    private func iconButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.toolTip = tooltip
        return button
    }

    private func actionButton(title: String, symbol: String?, tooltip: String, action: Selector, primary: Bool) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = primary ? .rounded : .texturedRounded
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            button.imagePosition = .imageLeading
        }
        button.toolTip = tooltip
        if primary {
            button.controlSize = .large
            stylePrimaryActionButton(button, title: title)
        }
        return button
    }

    private func primaryActionButtonColor() -> NSColor {
        // Keep primary actions legible on both appearance modes.
        sidebarThemeColor(light: (8, 66, 64), dark: (24, 124, 118))
    }

    private func stylePrimaryActionButton(_ button: NSButton, title: String) {
        let foregroundColor = NSColor.white
        button.bezelStyle = .rounded
        button.bezelColor = primaryActionButtonColor()
        button.contentTintColor = foregroundColor
        button.attributedTitle = NSAttributedString(
            string: title, attributes: [.foregroundColor: foregroundColor, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        if let image = button.image {
            let configuration = NSImage.SymbolConfiguration(paletteColors: [foregroundColor])
            button.image = image.withSymbolConfiguration(configuration)
        }
    }

    private func constrainFormFieldToFillWidth(_ view: NSView, in stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func showScrollableDetailStack(_ stack: NSStackView) {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = contentView
        contentView.addSubview(stack)

        detailContainer.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: detailContainer.topAnchor), scroll.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),

            contentView.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            contentView.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            contentView.bottomAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
        ])
    }

    private func scrollableTextView(_ textView: NSTextView, height: CGFloat) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let inputBg = sidebarThemeColor(light: (235, 233, 225), dark: (10, 15, 17))
        scroll.drawsBackground = true
        scroll.backgroundColor = inputBg
        scroll.contentView.drawsBackground = true
        scroll.contentView.backgroundColor = inputBg
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = UIRadius.compact
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = sidebarCardBorderColor(isSelected: false).cgColor
        textView.drawsBackground = true
        textView.backgroundColor = inputBg
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.minSize = NSSize(width: 0, height: height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        return scroll
    }

    private func insetContainerView(_ content: NSView, inset: CGFloat = 8) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = true
        container.autoresizingMask = [.width, .height]
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            content.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -inset),
        ])
        return container
    }

    private func makeEditableTextView() -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        return textView
    }

    private func storeProjectFields(
        projectID: String, setupView: NSTextView, stopView: NSTextView, portEditor: PortEditor, processEditor: ProcessEditor,
        browserSessionEditor: BrowserSessionEditor, agentLauncherEditor: AgentLauncherEditor
    ) -> Int {
        let id = projectID.hashValue
        ProjectFieldCache.shared.cache[id] = ProjectFieldRefs(
            projectID: projectID, setupView: setupView, stopView: stopView, portEditor: portEditor, processEditor: processEditor,
            browserSessionEditor: browserSessionEditor, agentLauncherEditor: agentLauncherEditor)
        return id
    }

    private func storeAddProjectFields(
        sourcePopup: NSPopUpButton, localSourceSection: NSStackView, cloneSourceSection: NSStackView, dirField: NSTextField,
        repoURLField: NSTextField, setupScriptSection: SetupScriptSection, stopScriptSection: StopScriptSection, portsSection: PortsSection,
        processesSection: ProcessesSection, browserSessionsSection: BrowserSessionsSection, agentLaunchersSection: AgentLaunchersSection,
        browseButton: NSButton, progressiveInputViews: [NSView], createButton: NSButton
    ) -> Int {
        let id = UUID().uuidString.hashValue
        AddProjectFieldCache.shared.cache[id] = AddProjectFieldRefs(
            sourcePopup: sourcePopup, localSourceSection: localSourceSection, cloneSourceSection: cloneSourceSection, dirField: dirField,
            repoURLField: repoURLField, browseButton: browseButton, progressiveInputViews: progressiveInputViews, createButton: createButton,
            setupScriptSection: setupScriptSection, stopScriptSection: stopScriptSection, portsSection: portsSection,
            processesSection: processesSection, browserSessionsSection: browserSessionsSection, agentLaunchersSection: agentLaunchersSection)
        sourcePopup.tag = id
        browseButton.tag = id
        return id
    }

    private func storeAddWorkspaceFields(
        projectID: String, isGitRepo: Bool, branchModePopup: NSPopUpButton?, existingBranchField: NSComboBox?, newBranchField: NSTextField?,
        targetBranchField: NSComboBox?, nameField: NSTextField, directoryNameField: NSTextField?, tooltipField: NSTextField?,
        autoNameState: AddWorkspaceAutoNameState?, progressiveInputViews: [NSView], createButton: NSButton
    ) -> Int {
        let id = UUID().uuidString.hashValue
        AddWorkspaceFieldCache.shared.cache[id] = AddWorkspaceFieldRefs(
            projectID: projectID, isGitRepo: isGitRepo, branchModePopup: branchModePopup, existingBranchField: existingBranchField,
            newBranchField: newBranchField, targetBranchField: targetBranchField, nameField: nameField, directoryNameField: directoryNameField,
            tooltipField: tooltipField, autoNameState: autoNameState, progressiveInputViews: progressiveInputViews, createButton: createButton)
        branchModePopup?.tag = id
        return id
    }

    @objc private func reloadTapped() { reloadData() }

    @objc private func showSettings() {
        if projectHasUnsavedChanges {
            let response = unsavedChangesPrompt()
            if response == .alertFirstButtonReturn {
                if !saveCurrentDetail() { return }
            } else if response == .alertThirdButtonReturn {
                return
            } else {
                projectHasUnsavedChanges = false
            }
        }
        outlineView.deselectAll(nil)
        selectedProjectID = nil
        selectedWorkspaceID = nil
        lastSelectedRow = -1
        showSettingsDetail()
    }

    @objc private func openWorkspaceEditor(_ sender: NSButton) {
        guard let workspaceID = sender.identifier?.rawValue else { return }
        openWorkspaceEditor(workspaceID: workspaceID)
    }

    @objc private func openWorkspaceTerminal(_ sender: NSButton) {
        guard let workspaceID = sender.identifier?.rawValue else { return }
        openWorkspaceTerminal(workspaceID: workspaceID)
    }

    @objc private func openWorkspaceFinder(_ sender: NSButton) {
        guard let workspaceID = sender.identifier?.rawValue else { return }
        openWorkspaceFinder(workspaceID: workspaceID)
    }

    @objc private func editorPreferenceChanged(_ sender: NSPopUpButton) {
        guard let preference = sender.selectedItem?.representedObject as? EditorPreference else { return }
        if configCache?.editor == preference { return }
        do { configCache = try orchestrator.updateEditorPreference(preference) } catch { showError(error) }
    }

    @objc private func terminalHostChanged(_ sender: NSPopUpButton) {
        guard let terminalHost = sender.selectedItem?.representedObject as? TerminalHost else { return }
        if configCache?.terminalHost == terminalHost { return }
        do { configCache = try orchestrator.updateTerminalHost(terminalHost) } catch { showError(error) }
    }

    @objc private func windowPulseEnabledChanged(_ sender: NSButton) {
        do { try orchestrator.setWindowFocusPulseEnabled(sender.state == .on) } catch { showError(error) }
    }

    @objc private func resetWindowPulseColor(_ sender: NSButton) {
        let parts = SettingsKey.defaultWindowFocusPulseColor.split(separator: ",").compactMap { Int($0) }
        guard parts.count == 3 else { return }
        do {
            try orchestrator.setWindowFocusPulseColor(r: parts[0], g: parts[1], b: parts[2])
            pulseColorWell?.color = NSColor(red: CGFloat(parts[0]) / 255, green: CGFloat(parts[1]) / 255, blue: CGFloat(parts[2]) / 255, alpha: 1)
        } catch { showError(error) }
    }

    @objc private func windowPulseColorChanged(_ sender: NSColorWell) {
        guard let rgb = sender.color.usingColorSpace(.deviceRGB) else { return }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        do { try orchestrator.setWindowFocusPulseColor(r: r, g: g, b: b) } catch { showError(error) }
    }

    @objc private func addProject() { showAddProjectForm() }

    @objc private func addWorkspace(_ sender: NSButton) {
        guard let projectID = sender.identifier?.rawValue, let project = projects.first(where: { $0.id == projectID }) else { return }
        showAddWorkspaceForm(project: project)
    }

    @objc private func addWorkspaceFromToolbar(_ sender: NSButton) {
        if let projectID = sender.identifier?.rawValue, let project = projects.first(where: { $0.id == projectID }) {
            showAddWorkspaceForm(project: project)
            return
        }
        guard let project = currentProjectForNewWorkspace() else { return }
        showAddWorkspaceForm(project: project)
    }

    private func addWorkspaceFromShortcut() {
        guard let project = currentProjectForNewWorkspace() else { return }
        showAddWorkspaceForm(project: project)
    }

    private func currentProjectForNewWorkspace() -> ProjectSummary? {
        if let selectedProjectID, let project = projects.first(where: { $0.id == selectedProjectID }) { return project }
        if let selectedWorkspaceID, let (project, _) = findWorkspace(id: selectedWorkspaceID) { return project }
        return nil
    }

    private func createWorkspaceWithDefaults(project: ProjectSummary) {
        let name = suggestedWorkspaceNameFast(projectID: project.id)
        guard !name.isEmpty else {
            showError(MuxyError.invalidArgument(message: "No available workspace names remain for project \(project.name)."))
            return
        }
        let targetBranch: String?
        if project.isGitRepo { targetBranch = defaultWorkspaceTargetBranchFast(project: project) } else { targetBranch = nil }
        let input = WorkspaceCreateInput(
            projectID: project.id, name: name, branch: project.isGitRepo ? name : nil, targetBranch: targetBranch, directoryName: nil, tooltip: nil,
            allowRemoteBranchLookup: false)
        showOperationProgressOverlay(message: "Creating workspace...", detail: "Generating defaults and creating the workspace record.")
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { hideOperationProgressOverlay() }
            let result = await Self.createWorkspaceSnapshot(input: input)
            switch result {
            case .success(let workspace):
                activeAddWorkspaceFormTag = nil
                activeAddProjectFormTag = nil
                selectedProjectID = project.id
                selectedWorkspaceID = workspace.id
                lastSelectedRow = -1
                reloadData()
                showOperationProgressOverlay(message: "Preparing workspace...", detail: "Running setup for the new workspace.")
                let setupResult = await Self.runWorkspaceSetupSnapshot(workspaceID: workspace.id)
                reloadData()
                if case .failure(let error) = setupResult { showError(error) }
            case .failure(let error): showError(error)
            }
        }
    }

    @objc private func saveProject(_ sender: NSButton) {
        commitEditing()
        guard let refs = ProjectFieldCache.shared.cache[sender.tag] else { return }
        do {
            try orchestrator.updateProjectConfig(projectID: refs.projectID) { config in
                config.setupScript = refs.setupView.string.isEmpty ? nil : refs.setupView.string
                config.stopScript = refs.stopView.string.isEmpty ? nil : refs.stopView.string
                config.ports = refs.portEditor.currentDefinitions()
                config.processes = refs.processEditor.currentProcesses()
                config.browserSessions = refs.browserSessionEditor.currentSessions()
                config.statusChecks = refs.processEditor.currentStatusChecks()
                config.agentLaunchers = refs.agentLauncherEditor.currentLaunchers()
            }
            projectHasUnsavedChanges = false
            reloadData()
        } catch { showError(error) }
    }

    @objc private func deleteProject(_ sender: NSButton) {
        guard let projectID = sender.identifier?.rawValue, let project = projects.first(where: { $0.id == projectID }) else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete project?"
        alert.informativeText = """
            This removes the project and its workspaces from muxy.
            If this project was cloned into ~/muxy/repos by muxy, that project directory is deleted.
            For git projects, related workspace directories under ~/muxy/workspaces are also deleted.
            """
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        sender.isEnabled = false
        showOperationProgressOverlay(message: "Deleting project...", detail: "Removing the project and its managed workspaces.")
        Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            defer {
                sender?.isEnabled = true
                hideOperationProgressOverlay()
            }
            let result = await Self.deleteProjectSnapshot(projectDirectory: project.dir)
            switch result {
            case .success:
                projectHasUnsavedChanges = false
                reloadData()
            case .failure(let error): showError(error)
            }
        }
    }

    @objc private func createProject(_ sender: NSButton) {
        guard let refs = AddProjectFieldCache.shared.cache[sender.tag] else { return }
        do {
            let setupScript = refs.setupScriptSection.currentValue.isEmpty ? nil : refs.setupScriptSection.currentValue
            let stopScript = refs.stopScriptSection.currentValue.isEmpty ? nil : refs.stopScriptSection.currentValue
            let input: ProjectCreateInput
            let progressDetail: String
            if refs.sourcePopup.indexOfSelectedItem == 1 {
                let repoURL = refs.repoURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !repoURL.isEmpty else { throw MuxyError.invalidArgument(message: "Git repository URL is required.") }
                input = ProjectCreateInput(
                    gitURL: repoURL, directoryPath: nil, setupScript: setupScript, stopScript: stopScript, ports: refs.portsSection.currentPorts,
                    processes: refs.processesSection.currentProcesses, browserSessions: refs.browserSessionsSection.currentSessions, statusChecks: [],
                    agentLaunchers: refs.agentLaunchersSection.currentLaunchers)
                progressDetail = "Cloning repository and applying project settings."
            } else {
                let dir = refs.dirField.toolTip?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !dir.isEmpty else { return }
                input = ProjectCreateInput(
                    gitURL: nil, directoryPath: dir, setupScript: setupScript, stopScript: stopScript, ports: refs.portsSection.currentPorts,
                    processes: refs.processesSection.currentProcesses, browserSessions: refs.browserSessionsSection.currentSessions, statusChecks: [],
                    agentLaunchers: refs.agentLaunchersSection.currentLaunchers)
                progressDetail = "Registering project and applying project settings."
            }
            let originalTitle = sender.title
            sender.isEnabled = false
            sender.title = "Creating..."
            showOperationProgressOverlay(message: "Creating project...", detail: progressDetail)
            Task { @MainActor [weak self, weak sender] in
                guard let self else { return }
                defer {
                    sender?.isEnabled = true
                    sender?.title = originalTitle
                    hideOperationProgressOverlay()
                }
                let result = await Self.createProjectSnapshot(input: input)
                switch result {
                case .success:
                    activeAddProjectFormTag = nil
                    reloadData()
                case .failure(let error): showError(error)
                }
            }
        } catch { showError(error) }
    }

    @objc private func projectSourceChanged(_ sender: NSPopUpButton) {
        guard let refs = AddProjectFieldCache.shared.cache[sender.tag] else { return }
        updateAddProjectSourceUI(refs)
    }

    @objc private func browseProjectDir(_ sender: NSButton) {
        guard let refs = AddProjectFieldCache.shared.cache[sender.tag] else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { result in
            if result == .OK, let url = panel.url {
                refs.dirField.stringValue = url.path
                refs.dirField.toolTip = url.path
                refs.dirField.textColor = .labelColor
                refs.dirField.isHidden = false
                refs.browseButton.title = url.lastPathComponent
                self.updateAddProjectSourceUI(refs)
            }
        }
    }

    private func updateAddProjectSourceUI(_ refs: AddProjectFieldRefs) {
        let cloneSelected = refs.sourcePopup.indexOfSelectedItem == 1
        refs.localSourceSection.isHidden = cloneSelected
        refs.cloneSourceSection.isHidden = !cloneSelected
        updateAddProjectProgressiveDisclosure(refs)
    }

    private func updateAddProjectProgressiveDisclosure(_ refs: AddProjectFieldRefs) {
        let hasSource = isAddProjectSourceConfigured(refs)
        for view in refs.progressiveInputViews { view.isHidden = !hasSource }
        refs.createButton.isEnabled = hasSource
    }

    private func isAddProjectSourceConfigured(_ refs: AddProjectFieldRefs) -> Bool {
        if refs.sourcePopup.indexOfSelectedItem == 1 { return !refs.repoURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let directoryPath = refs.dirField.toolTip?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !directoryPath.isEmpty
    }

    private func defaultWorkspaceTargetBranch(project: ProjectSummary, branches: [String]) -> String? {
        if let configured = project.defaultBranch, !configured.isEmpty { return configured }
        if branches.contains("main") { return "main" }
        if branches.contains("master") { return "master" }
        return branches.first
    }

    private func defaultWorkspaceTargetBranchFast(project: ProjectSummary) -> String? {
        if let configured = project.defaultBranch, !configured.isEmpty { return configured }
        return "main"
    }

    private func suggestedWorkspaceNameFast(projectID: String) -> String {
        let existingNames = Set((workspacesByProject[projectID] ?? []).map(\.title))
        if let suggestion = MuxyOrchestrator.suggestWorkspaceName(existingNames: existingNames) { return suggestion }
        return ""
    }

    private func addWorkspaceBranchMode(refs: AddWorkspaceFieldRefs) -> AddWorkspaceBranchMode {
        guard let mode = AddWorkspaceBranchMode(rawValue: refs.branchModePopup?.selectedItem?.title == "Create branch" ? "create" : "existing") else {
            return .existing
        }
        return mode
    }

    private func currentAddWorkspaceBranchValue(_ refs: AddWorkspaceFieldRefs) -> String {
        switch addWorkspaceBranchMode(refs: refs) {
        case .existing: refs.existingBranchField?.stringValue ?? ""
        case .create: refs.newBranchField?.stringValue ?? ""
        }
    }

    private func updateAddWorkspaceBranchDerivedFields(refs: AddWorkspaceFieldRefs, branchValue: String) {
        guard let autoNameState = refs.autoNameState else { return }
        let currentName = refs.nameField.stringValue
        if currentName.isEmpty || currentName == autoNameState.lastAutoWorkspaceName {
            refs.nameField.stringValue = branchValue
            autoNameState.lastAutoWorkspaceName = branchValue
        }
        if let dirField = refs.directoryNameField {
            let currentDir = dirField.stringValue
            let sanitized = branchValue.replacing(/[^A-Za-z0-9\-_]/, with: "-").replacing(/\-{2,}/, with: "-").trimmingCharacters(
                in: CharacterSet(charactersIn: "-"))
            if currentDir.isEmpty || currentDir == autoNameState.lastAutoDirName {
                dirField.stringValue = sanitized
                autoNameState.lastAutoDirName = sanitized
            }
        }
    }

    private func updateAddWorkspaceBranchInputUI(refs: AddWorkspaceFieldRefs) {
        let isCreatingBranch = addWorkspaceBranchMode(refs: refs) == .create
        refs.existingBranchField?.isHidden = isCreatingBranch
        refs.newBranchField?.isHidden = !isCreatingBranch
    }

    private func updateAddWorkspaceProgressiveDisclosure(refs: AddWorkspaceFieldRefs, branchValue: String) {
        guard refs.isGitRepo else { return }
        let hasBranch = !branchValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        for view in refs.progressiveInputViews { view.isHidden = !hasBranch }
        refs.createButton.isEnabled = hasBranch
    }

    @objc private func addWorkspaceBranchModeChanged(_ sender: NSPopUpButton) {
        guard let refs = AddWorkspaceFieldCache.shared.cache[sender.tag] else { return }
        updateAddWorkspaceBranchInputUI(refs: refs)
        let branchValue = currentAddWorkspaceBranchValue(refs)
        updateAddWorkspaceProgressiveDisclosure(refs: refs, branchValue: branchValue)
        updateAddWorkspaceBranchDerivedFields(refs: refs, branchValue: branchValue)
        if addWorkspaceBranchMode(refs: refs) == .create {
            window.makeFirstResponder(refs.newBranchField)
        } else {
            window.makeFirstResponder(refs.existingBranchField)
        }
    }

    @objc private func createWorkspace(_ sender: NSButton) {
        guard let refs = AddWorkspaceFieldCache.shared.cache[sender.tag] else { return }
        do {
            let name = refs.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw MuxyError.invalidArgument(message: "Workspace title is required.") }
            let targetBranch = refs.targetBranchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = currentAddWorkspaceBranchValue(refs).trimmingCharacters(in: .whitespacesAndNewlines)
            let directoryName = refs.directoryNameField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedDirectoryName: String?
            if let directoryName, directoryName.isEmpty { resolvedDirectoryName = nil } else { resolvedDirectoryName = directoryName }
            let tooltip = refs.tooltipField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTooltip: String?
            if let tooltip, tooltip.isEmpty { resolvedTooltip = nil } else { resolvedTooltip = tooltip }
            if refs.isGitRepo, branch.isEmpty { throw MuxyError.invalidArgument(message: "Branch name is required for git projects.") }
            if refs.isGitRepo, targetBranch == nil || targetBranch?.isEmpty == true {
                throw MuxyError.invalidArgument(message: "Target branch is required for git projects.")
            }
            if refs.isGitRepo, addWorkspaceBranchMode(refs: refs) == .create, refs.autoNameState?.branchOptions.contains(branch) == true {
                throw MuxyError.invalidArgument(
                    message: "Branch '\(branch)' already exists. Choose it from Existing branch or enter a different new branch name.")
            }
            let input = WorkspaceCreateInput(
                projectID: refs.projectID, name: name, branch: branch, targetBranch: targetBranch, directoryName: resolvedDirectoryName,
                tooltip: resolvedTooltip, allowRemoteBranchLookup: true)
            let originalTitle = sender.title
            sender.isEnabled = false
            sender.title = "Creating..."
            showOperationProgressOverlay(message: "Creating workspace...", detail: "Validating fields and creating the workspace.")
            Task { @MainActor [weak self, weak sender] in
                guard let self else { return }
                defer {
                    sender?.isEnabled = true
                    sender?.title = originalTitle
                    hideOperationProgressOverlay()
                }
                let result = await Self.createWorkspaceSnapshot(input: input)
                switch result {
                case .success(let workspace):
                    activeAddWorkspaceFormTag = nil
                    activeAddProjectFormTag = nil
                    selectedProjectID = refs.projectID
                    selectedWorkspaceID = workspace.id
                    lastSelectedRow = -1
                    reloadData()
                    showOperationProgressOverlay(message: "Preparing workspace...", detail: "Running setup for the new workspace.")
                    let setupResult = await Self.runWorkspaceSetupSnapshot(workspaceID: workspace.id)
                    reloadData()
                    if case .failure(let error) = setupResult { showError(error) }
                case .failure(let error): showError(error)
                }
            }
        } catch { showError(error) }
    }

    public func controlTextDidChange(_ obj: Notification) {
        guard let changedField = obj.object as? NSTextField else { return }
        for refs in AddProjectFieldCache.shared.cache.values {
            guard refs.repoURLField === changedField else { continue }
            updateAddProjectSourceUI(refs)
            return
        }
        if let tag = inlineWorkspaceFieldTagByObjectID[ObjectIdentifier(changedField)] {
            updateInlineWorkspaceMetadataButtons(tag: tag)
            return
        }
        for refs in AddWorkspaceFieldCache.shared.cache.values {
            guard refs.existingBranchField === changedField || refs.newBranchField === changedField else { continue }
            let branchValue = currentAddWorkspaceBranchValue(refs)
            updateAddWorkspaceProgressiveDisclosure(refs: refs, branchValue: branchValue)
            updateAddWorkspaceBranchDerivedFields(refs: refs, branchValue: branchValue)
            return
        }
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let textField = control as? NSTextField else { return false }
        guard let tag = inlineWorkspaceFieldTagByObjectID[ObjectIdentifier(textField)] else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            saveInlineWorkspaceMetadata(tag: tag)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelInlineWorkspaceMetadataEdit(tag: tag)
            return true
        }
        return false
    }

    @objc private func cancelProjectForm() { refreshSelection() }

    @objc private func launchWorkspace(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        sender.isEnabled = false
        Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            let result = await Self.runWorkspaceLifecycleAction(.launch, workspaceID: id)
            sender?.isEnabled = true
            switch result {
            case .success: reloadData()
            case .failure(let error): showError(error)
            }
        }
    }

    @objc private func restartWorkspace(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        sender.isEnabled = false
        Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            let result = await Self.runWorkspaceLifecycleAction(.restart, workspaceID: id)
            sender?.isEnabled = true
            switch result {
            case .success: reloadData()
            case .failure(let error): showError(error)
            }
        }
    }

    @objc private func stopWorkspace(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        sender.isEnabled = false
        Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            let result = await Self.runWorkspaceLifecycleAction(.stop, workspaceID: id)
            sender?.isEnabled = true
            switch result {
            case .success(let outcome):
                reloadData()
                if let notice = outcome.notice { showInfoMessage(title: "Workspace Stopped", message: notice) }
            case .failure(let error): showError(error)
            }
        }
    }

    @objc private func toggleWorkspaceHidden(_ sender: Any) {
        guard let id = Self.senderIdentifier(sender) else { return }
        guard let (project, workspace) = findWorkspace(id: id) else { return }
        let targetIsHidden = !workspace.isHidden
        if targetIsHidden, workspace.isRunning {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Hide workspace?"
            alert.informativeText =
                "\"\(workspace.title)\" is currently running. Hiding it will stop the workspace first, then move it into Hidden Workspaces."
            alert.addButton(withTitle: "Stop and Hide")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }
        }
        let button = sender as? NSButton
        button?.isEnabled = false
        Task { @MainActor [weak self, weak button] in
            guard let self else { return }
            if targetIsHidden, workspace.isRunning {
                let stopResult = await Self.runWorkspaceLifecycleAction(.stop, workspaceID: id)
                switch stopResult {
                case .success(let outcome): if let notice = outcome.notice { showInfoMessage(title: "Workspace Stopped", message: notice) }
                case .failure(let error):
                    button?.isEnabled = true
                    showError(error)
                    return
                }
            }
            do {
                try orchestrator.updateWorkspaceHidden(workspaceID: id, isHidden: targetIsHidden)
                button?.isEnabled = true
                if targetIsHidden, selectedWorkspaceID == id {
                    selectedWorkspaceID = nil
                    selectedProjectID = project.id
                    suppressOutlineSelectionChanges = true
                    outlineView.deselectAll(nil)
                    suppressOutlineSelectionChanges = false
                }
                reloadData()
            } catch {
                button?.isEnabled = true
                showError(error)
            }
        }
    }

    @objc private func archiveWorkspace(_ sender: Any) {
        guard let id = Self.senderIdentifier(sender) else { return }
        let workspace = workspacesByProject.values.flatMap({ $0 }).first(where: { $0.id == id })
        if workspace?.isDefault == true {
            showInfoMessage(
                title: "Default Workspace",
                message: "Default workspaces cannot be archived. Delete the project instead to remove all of its workspaces.")
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Archive workspace?"
        alert.informativeText =
            "Are you sure you want to archive \"\(workspace?.title ?? id)\"? This will remove its git worktree and stop all running processes."
        alert.addButton(withTitle: "Archive")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let button = sender as? NSButton
        let didOptimisticallyArchive = optimisticallyArchiveWorkspaceInSidebar(workspaceID: id)
        if !didOptimisticallyArchive { button?.isEnabled = false }
        showOperationProgressOverlay(message: "Archiving workspace...", detail: "Stopping runtime state and cleaning up workspace files.")
        Task { @MainActor [weak self, weak button] in
            guard let self else { return }
            defer { hideOperationProgressOverlay() }
            let result = await Self.runWorkspaceLifecycleAction(.archive, workspaceID: id)
            switch result {
            case .success:
                if didOptimisticallyArchive {
                    requestSidebarReload()
                } else {
                    button?.isEnabled = true
                    reloadData()
                }
            case .failure(let error):
                reloadData()
                button?.isEnabled = true
                showError(error)
            }
        }
    }

    @objc func copyDirectoryPath(_ sender: Any) {
        guard let path = Self.senderIdentifier(sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc func revealDirectoryInFinder(_ sender: Any) {
        guard let path = Self.senderIdentifier(sender) else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    /// Accepts the `identifier.rawValue` from either an `NSMenuItem` or any
    /// `NSControl` (buttons, popup buttons). Used so the same @objc action
    /// works whether it's fired from a dir-row button or a ⋯ menu item.
    static func senderIdentifier(_ sender: Any) -> String? {
        if let menuItem = sender as? NSMenuItem { return menuItem.identifier?.rawValue }
        if let control = sender as? NSControl { return control.identifier?.rawValue }
        return nil
    }

    /// Stock `NSMenu` for the workspace detail ⋯ overflow. Items carry the
    /// workspace path (for Copy/Reveal) or workspace ID (for Archive/Hide) in their
    /// `identifier.rawValue`, letting the underlying action methods stay
    /// unchanged whether they're triggered by a button or a menu item.
    static func makeWorkspaceOverflowMenu(workspaceID: String, path: String, isHidden: Bool, target: AnyObject?) -> NSMenu {
        let menu = NSMenu()

        func addItem(title: String, symbol: String?, action: Selector, keyEquivalent: String, modifiers: NSEvent.ModifierFlags, identifier: String) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
            item.keyEquivalentModifierMask = modifiers
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
            item.target = target
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(item)
        }

        addItem(
            title: "Copy path", symbol: "doc.on.doc", action: #selector(AppKitController.copyDirectoryPath(_:)), keyEquivalent: "", modifiers: [],
            identifier: path)
        addItem(
            title: "Reveal in Finder", symbol: "folder", action: #selector(AppKitController.revealDirectoryInFinder(_:)), keyEquivalent: "f",
            modifiers: [.command, .shift], identifier: path)
        menu.addItem(.separator())
        addItem(
            title: isHidden ? "Unhide" : "Hide", symbol: isHidden ? "eye" : "eye.slash",
            action: #selector(AppKitController.toggleWorkspaceHidden(_:)), keyEquivalent: "", modifiers: [], identifier: workspaceID)
        menu.addItem(.separator())
        addItem(
            title: "Archive…", symbol: "archivebox", action: #selector(AppKitController.archiveWorkspace(_:)), keyEquivalent: "", modifiers: [],
            identifier: workspaceID)
        return menu
    }

    @objc private func showWorkspaceOverflowMenu(_ sender: NSButton) {
        guard let workspaceID = sender.identifier?.rawValue,
            let workspace = workspacesByProject.values.flatMap({ $0 }).first(where: { $0.id == workspaceID })
        else { return }
        let menu = Self.makeWorkspaceOverflowMenu(workspaceID: workspaceID, path: workspace.dir, isHidden: workspace.isHidden, target: self)
        let origin = NSPoint(x: 0, y: sender.bounds.maxY + 4)
        menu.popUp(positioning: nil, at: origin, in: sender)
    }

    private func parseProcesses(_ raw: String) -> [ProcessTemplate] {
        _ = raw
        return []
    }

    private func parseStatusChecks(_ raw: String) -> [StatusCheckDefinition] {
        _ = raw
        return []
    }

    nonisolated private static func browserSessionDisplayName(for targetURL: String?, sessions: [BrowserSession]) -> String? {
        guard let targetURL, !targetURL.isEmpty else { return nil }
        var bestMatch: (length: Int, name: String)?
        for session in sessions {
            guard let prefix = session.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                let name = session.name?.trimmingCharacters(in: .whitespacesAndNewlines), !prefix.isEmpty, !name.isEmpty, targetURL.hasPrefix(prefix)
            else { continue }
            if let bestMatch, bestMatch.length >= prefix.count { continue }
            bestMatch = (length: prefix.count, name: name)
        }
        return bestMatch?.name
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    private func showInfoMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func openWorkspaceEditor(workspaceID: String) {
        do {
            try orchestrator.openWorkspaceEditor(workspaceID: workspaceID)
            reloadData()
            hideAfterSuccessfulExternalWindowAction(.open)
        } catch { showError(error) }
    }

    private func openWorkspaceTerminal(workspaceID: String) {
        do {
            try orchestrator.openWorkspaceTerminal(workspaceID: workspaceID)
            reloadData()
            hideAfterSuccessfulExternalWindowAction(.open)
        } catch { showError(error) }
    }

    private func openWorkspaceFinder(workspaceID: String) {
        guard let (_, workspace) = findWorkspace(id: workspaceID) else { return }
        let url = URL(fileURLWithPath: workspace.dir, isDirectory: true)
        if NSWorkspace.shared.open(url) { hideAfterSuccessfulExternalWindowAction(.open) }
    }

    private func findWorkspace(id: String) -> (ProjectSummary, WorkspaceSummary)? {
        for project in projects {
            if let workspaces = workspacesByProject[project.id], let workspace = workspaces.first(where: { $0.id == id }) {
                return (project, workspace)
            }
        }
        return nil
    }

    private func isVisibleWorkspace(_ workspace: WorkspaceSummary) -> Bool { !workspace.isArchived && !workspace.isHidden }

    private func visibleWorkspaces(projectID: String) -> [WorkspaceSummary] {
        (workspacesByProject[projectID] ?? []).filter { isVisibleWorkspace($0) }
    }

    private func hiddenWorkspaces() -> [(ProjectSummary, WorkspaceSummary)] {
        projects.flatMap { project in
            (workspacesByProject[project.id] ?? []).compactMap { workspace in
                guard !workspace.isArchived, workspace.isHidden else { return nil }
                return (project, workspace)
            }
        }
    }

    private func optimisticallyArchiveWorkspaceInSidebar(workspaceID: String) -> Bool {
        guard let (project, _) = findWorkspace(id: workspaceID) else { return false }
        guard var workspaces = workspacesByProject[project.id] else { return false }
        let originalCount = workspaces.count
        workspaces.removeAll(where: { $0.id == workspaceID })
        guard workspaces.count != originalCount else { return false }

        workspacesByProject[project.id] = workspaces
        if selectedWorkspaceID == workspaceID {
            selectedWorkspaceID = nil
            selectedProjectID = project.id
        }
        outlineView.reloadData()
        applySidebarProjectExpansionState()
        refreshSelection()
        return true
    }

    private func normalizePath(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }

    private func setupGlobalHotkey() {
        guard let toggleShortcutSpec else {
            teardownGlobalHotkey()
            return
        }
        registerHotkeys(toggle: toggleShortcutSpec, next: nextShortcutSpec, previous: previousShortcutSpec)
    }

    private func teardownGlobalHotkey() {
        for ref in hotkeyRefs.values { UnregisterEventHotKey(ref) }
        hotkeyRefs.removeAll()
        if let hotkeyHandler { RemoveEventHandler(hotkeyHandler) }
        hotkeyHandler = nil
    }

    private func registerHotkeys(toggle: HotkeySpec, next: HotkeySpec?, previous: HotkeySpec?) {
        teardownGlobalHotkey()
        let signature = OSType(UInt32(truncatingIfNeeded: "AMUX".utf8.reduce(0) { ($0 << 8) + UInt32($1) }))
        let target = GetEventDispatcherTarget()
        registerHotkey(spec: toggle, id: GlobalHotkey.toggle.rawValue, signature: signature, target: target)
        if let next { registerHotkey(spec: next, id: GlobalHotkey.next.rawValue, signature: signature, target: target) }
        if let previous { registerHotkey(spec: previous, id: GlobalHotkey.previous.rawValue, signature: signature, target: target) }
        if let openEditorShortcutSpec {
            registerHotkey(spec: openEditorShortcutSpec, id: GlobalHotkey.openEditor.rawValue, signature: signature, target: target)
        }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        _ = InstallEventHandler(
            target, hotkeyHandlerProc, 1, &eventSpec, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), &hotkeyHandler)
    }

    private func registerHotkey(spec: HotkeySpec, id: UInt32, signature: OSType, target: EventTargetRef?) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(UInt32(spec.keyCode), spec.modifiersCarbon, hotKeyID, target, 0, &ref)
        if status == noErr, let ref { hotkeyRefs[id] = ref }
    }

    private func setupShortcutMonitor() {
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged { return self.handleShortcutFlagsChanged(event: event) ? nil : event }
            self.recordStartupInteraction(kind: "key_down")
            if self.handleShortcutCaptureEvent(event: event) { return nil }
            if self.handleAddProjectShortcut(event: event) { return nil }
            if self.handleNewWorkspaceShortcut(event: event) { return nil }
            if self.handleReloadShortcut(event: event) { return nil }
            if self.handleFormCancelShortcut(event: event) { return nil }
            if self.handleDashboardShortcut(event: event) { return nil }
            if let openSettingsShortcutSpec, matches(event: event, spec: openSettingsShortcutSpec) {
                self.showSettings()
                return nil
            }
            if self.handleFocusedTextInputShortcut(event: event) { return nil }
            if self.isTextInputFocused() { return event }
            if self.handleSidebarArrowNavigation(event: event) { return nil }
            if let nextShortcutSpec, matches(event: event, spec: nextShortcutSpec) {
                self.selectNextVisibleWorkspace()
                return nil
            }
            if let previousShortcutSpec, matches(event: event, spec: previousShortcutSpec) {
                self.selectPreviousVisibleWorkspace()
                return nil
            }
            if let openTerminalShortcutSpec, matches(event: event, spec: openTerminalShortcutSpec) {
                if let workspaceID = self.selectedWorkspaceID { self.openWorkspaceTerminal(workspaceID: workspaceID) }
                return nil
            }
            if let openFinderShortcutSpec, matches(event: event, spec: openFinderShortcutSpec) {
                if let workspaceID = self.selectedWorkspaceID { self.openWorkspaceFinder(workspaceID: workspaceID) }
                return nil
            }
            if self.handleBufferedWindowShortcut(event: event) { return nil }
            if let windowIndex = windowShortcutIndex(for: event) {
                self.logWindowShortcutProfile("stage=monitor_schedule index=\(windowIndex)")
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.logWindowShortcutProfile("stage=monitor_dispatch index=\(windowIndex)")
                    self.focusWindowShortcut(index: windowIndex)
                    self.logWindowShortcutProfile("stage=monitor_after_handler index=\(windowIndex)")
                }
                return nil
            }
            return event
        }
    }

    private func handleShortcutFlagsChanged(event: NSEvent) -> Bool {
        if handleLeaderShortcutCaptureFlagsChanged(event: event) { return true }
        if bufferedWindowShortcutIndices.isEmpty { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !flags.contains(.command) || !flags.contains(.shift) else { return false }
        flushBufferedWindowShortcuts()
        return true
    }

    private func handleLeaderShortcutCaptureFlagsChanged(event: NSEvent) -> Bool {
        guard activeShortcutCaptureSetting == .guiLeaderHotkey else { return false }
        let modifiers = currentPressedShortcutModifiers(fallback: event.modifierFlags)
        if !modifiers.isEmpty {
            pendingLeaderCaptureModifiers.formUnion(modifiers)
            refreshShortcutCaptureButtons()
            return true
        }
        guard !pendingLeaderCaptureModifiers.isEmpty else { return true }
        do {
            try setShortcutSetting(setting: .guiLeaderHotkey, value: HotkeySpec.normalizedModifierSet(pendingLeaderCaptureModifiers))
            pendingLeaderCaptureModifiers = []
            activeShortcutCaptureSetting = nil
            loadShortcutSpecs()
            setupGlobalHotkey()
            refreshSelection()
        } catch {
            pendingLeaderCaptureModifiers = []
            activeShortcutCaptureSetting = nil
            refreshShortcutCaptureButtons()
            showError(error)
        }
        return true
    }

    private func handleFormCancelShortcut(event: NSEvent) -> Bool {
        guard event.keyCode == UInt16(kVK_Escape) else { return false }
        guard activeAddWorkspaceFormTag != nil || activeAddProjectFormTag != nil else { return false }
        cancelProjectForm()
        return true
    }

    private func handleAddProjectShortcut(event: NSEvent) -> Bool {
        guard let addProjectShortcutSpec, matches(event: event, spec: addProjectShortcutSpec) else { return false }
        addProject()
        return true
    }

    private func handleDashboardShortcut(event: NSEvent) -> Bool {
        guard let dashboardShortcutSpec, matches(event: event, spec: dashboardShortcutSpec) else { return false }
        showDashboardDetail()
        return true
    }

    private func handleNewWorkspaceShortcut(event: NSEvent) -> Bool {
        guard let addWorkspaceShortcutSpec, matches(event: event, spec: addWorkspaceShortcutSpec) else { return false }
        if showingDashboard, windowShortcutIndex(for: event) != nil { return false }
        if let activeAddWorkspaceFormTag, let refs = AddWorkspaceFieldCache.shared.cache[activeAddWorkspaceFormTag],
            let project = projects.first(where: { $0.id == refs.projectID })
        {
            createWorkspaceWithDefaults(project: project)
            return true
        }
        addWorkspaceFromShortcut()
        return true
    }

    private func handleReloadShortcut(event: NSEvent) -> Bool {
        guard let reloadShortcutSpec, matches(event: event, spec: reloadShortcutSpec) else { return false }
        reloadData()
        return true
    }

    private func handleShortcutCaptureEvent(event: NSEvent) -> Bool {
        guard let setting = activeShortcutCaptureSetting else { return false }
        if event.keyCode == UInt16(kVK_Escape) {
            pendingLeaderCaptureModifiers = []
            activeShortcutCaptureSetting = nil
            refreshShortcutCaptureButtons()
            return true
        }
        guard let spec = shortcutCaptureSpec(from: event) else {
            NSSound.beep()
            return true
        }
        guard setting.capturesModifierOnly || !spec.modifiers.isEmpty else {
            NSSound.beep()
            return true
        }
        guard shortcutCaptureAccepts(spec: spec, setting: setting) else {
            NSSound.beep()
            return true
        }

        do {
            try setShortcutSetting(setting: setting, value: normalizedShortcutSettingValue(spec: spec, setting: setting))
            pendingLeaderCaptureModifiers = []
            activeShortcutCaptureSetting = nil
            loadShortcutSpecs()
            setupGlobalHotkey()
            refreshSelection()
        } catch {
            pendingLeaderCaptureModifiers = []
            activeShortcutCaptureSetting = nil
            refreshShortcutCaptureButtons()
            showError(error)
        }
        return true
    }

    private func shortcutCaptureSpec(from event: NSEvent) -> HotkeySpec? {
        guard let key = shortcutCaptureKey(for: event.keyCode) else { return nil }
        return HotkeySpec(key: key, modifiers: shortcutModifiers(from: event.modifierFlags))
    }

    private func shortcutCaptureAccepts(spec: HotkeySpec, setting: ShortcutSetting) -> Bool {
        if setting.usesDigitRangeCapture { return Int(spec.key) != nil }
        return true
    }

    private func normalizedShortcutSettingValue(spec: HotkeySpec, setting: ShortcutSetting) -> String {
        if setting.usesLeader {
            let suffixModifiers =
                spec.modifiers.isSuperset(of: shortcutLeaderModifiers) ? spec.modifiers.subtracting(shortcutLeaderModifiers) : spec.modifiers
            let suffixKey = setting.usesDigitRangeCapture ? "1" : spec.key
            return HotkeySpec(key: suffixKey, modifiers: suffixModifiers).normalized
        }
        if setting.usesDigitRangeCapture { return HotkeySpec(key: "1", modifiers: spec.modifiers).normalized }
        return spec.normalized
    }

    private func shortcutCaptureKey(for keyCode: UInt16) -> String? { AppKitController.shortcutCaptureKeyMap[keyCode] }

    private func shortcutModifiers(from flags: NSEvent.ModifierFlags) -> Set<HotkeyModifier> {
        let filtered = flags.intersection([.command, .shift, .option, .control])
        var modifiers = Set<HotkeyModifier>()
        if filtered.contains(.command) { modifiers.insert(.cmd) }
        if filtered.contains(.shift) { modifiers.insert(.shift) }
        if filtered.contains(.option) { modifiers.insert(.alt) }
        if filtered.contains(.control) { modifiers.insert(.ctrl) }
        return modifiers
    }

    private func currentPressedShortcutModifiers(fallback flags: NSEvent.ModifierFlags) -> Set<HotkeyModifier> {
        let pressedModifierKeys: [(HotkeyModifier, [CGKeyCode])] = [
            (.cmd, [CGKeyCode(kVK_Command), CGKeyCode(kVK_RightCommand)]), (.shift, [CGKeyCode(kVK_Shift), CGKeyCode(kVK_RightShift)]),
            (.alt, [CGKeyCode(kVK_Option), CGKeyCode(kVK_RightOption)]), (.ctrl, [CGKeyCode(kVK_Control), CGKeyCode(kVK_RightControl)]),
        ]

        var modifiers = Set<HotkeyModifier>()
        for (modifier, keyCodes) in pressedModifierKeys {
            if keyCodes.contains(where: { CGEventSource.keyState(.combinedSessionState, key: $0) }) { modifiers.insert(modifier) }
        }
        return modifiers.isEmpty ? shortcutModifiers(from: flags) : modifiers
    }

    private static let shortcutCaptureKeyMap: [UInt16: String] = [
        UInt16(kVK_ANSI_A): "a", UInt16(kVK_ANSI_B): "b", UInt16(kVK_ANSI_C): "c", UInt16(kVK_ANSI_D): "d", UInt16(kVK_ANSI_E): "e",
        UInt16(kVK_ANSI_F): "f", UInt16(kVK_ANSI_G): "g", UInt16(kVK_ANSI_H): "h", UInt16(kVK_ANSI_I): "i", UInt16(kVK_ANSI_J): "j",
        UInt16(kVK_ANSI_K): "k", UInt16(kVK_ANSI_L): "l", UInt16(kVK_ANSI_M): "m", UInt16(kVK_ANSI_N): "n", UInt16(kVK_ANSI_O): "o",
        UInt16(kVK_ANSI_P): "p", UInt16(kVK_ANSI_Q): "q", UInt16(kVK_ANSI_R): "r", UInt16(kVK_ANSI_S): "s", UInt16(kVK_ANSI_T): "t",
        UInt16(kVK_ANSI_U): "u", UInt16(kVK_ANSI_V): "v", UInt16(kVK_ANSI_W): "w", UInt16(kVK_ANSI_X): "x", UInt16(kVK_ANSI_Y): "y",
        UInt16(kVK_ANSI_Z): "z", UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2", UInt16(kVK_ANSI_3): "3",
        UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5", UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7", UInt16(kVK_ANSI_8): "8",
        UInt16(kVK_ANSI_9): "9", UInt16(kVK_ANSI_Equal): "=", UInt16(kVK_ANSI_Minus): "minus", UInt16(kVK_ANSI_LeftBracket): "[",
        UInt16(kVK_ANSI_RightBracket): "]", UInt16(kVK_ANSI_Semicolon): ";", UInt16(kVK_ANSI_Quote): "'", UInt16(kVK_ANSI_Comma): ",",
        UInt16(kVK_ANSI_Period): ".", UInt16(kVK_ANSI_Slash): "/", UInt16(kVK_ANSI_Backslash): "\\", UInt16(kVK_ANSI_Grave): "`",
        UInt16(kVK_Space): "space", UInt16(kVK_Tab): "tab", UInt16(kVK_Return): "return", UInt16(kVK_Escape): "escape", UInt16(kVK_Delete): "delete",
        UInt16(kVK_ForwardDelete): "forwarddelete", UInt16(kVK_LeftArrow): "left", UInt16(kVK_RightArrow): "right", UInt16(kVK_UpArrow): "up",
        UInt16(kVK_DownArrow): "down", UInt16(kVK_F1): "f1", UInt16(kVK_F2): "f2", UInt16(kVK_F3): "f3", UInt16(kVK_F4): "f4", UInt16(kVK_F5): "f5",
        UInt16(kVK_F6): "f6", UInt16(kVK_F7): "f7", UInt16(kVK_F8): "f8", UInt16(kVK_F9): "f9", UInt16(kVK_F10): "f10", UInt16(kVK_F11): "f11",
        UInt16(kVK_F12): "f12", UInt16(kVK_F13): "f13", UInt16(kVK_F14): "f14", UInt16(kVK_F15): "f15", UInt16(kVK_F16): "f16",
        UInt16(kVK_F17): "f17", UInt16(kVK_F18): "f18", UInt16(kVK_F19): "f19", UInt16(kVK_F20): "f20",
    ]

    private func isTextInputFocused() -> Bool {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return false }
        if let textView = window.firstResponder as? NSTextView { return textView.isEditable || textView.isFieldEditor }
        return false
    }

    private func handleFocusedTextInputShortcut(event: NSEvent) -> Bool {
        guard isTextInputFocused() else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command {
            switch key {
            case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
            case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            case "z": return NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
            default: return false
            }
        }
        if flags == [.command, .shift], key == "z" { return NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
        return false
    }

    private func navigateSidebarSelection(direction: Int) -> Bool {
        guard
            let target = Self.sidebarArrowSelectionTarget(
                visibleWorkspaceIDsByProject: projects.map { project in
                    let visibleWorkspaceIDs = project.isCollapsed ? [] : visibleWorkspaces(projectID: project.id).map(\.id)
                    return (project.id, visibleWorkspaceIDs)
                }, hiddenWorkspaceIDs: hiddenWorkspacesCollapsed ? [] : hiddenWorkspaces().map { $0.1.id }, selectedProjectID: selectedProjectID,
                selectedWorkspaceID: selectedWorkspaceID, showingDashboard: showingDashboard, direction: direction)
        else { return false }
        switch target {
        case .dashboard: showDashboardDetail()
        case .workspace(let workspaceID):
            guard let (_, workspace) = findWorkspace(id: workspaceID) else { return false }
            selectWorkspace(workspace)
        }
        return true
    }

    private func handleSidebarArrowNavigation(event: NSEvent) -> Bool {
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

    nonisolated static func sidebarArrowSelectionTarget(
        visibleWorkspaceIDsByProject: [(projectID: String, workspaceIDs: [String])], hiddenWorkspaceIDs: [String], selectedProjectID: String?,
        selectedWorkspaceID: String?, showingDashboard: Bool, direction: Int
    ) -> SidebarArrowSelectionTarget? {
        guard direction == -1 || direction == 1 else { return nil }
        let visibleWorkspaceIDs = visibleWorkspaceIDsByProject.flatMap(\.workspaceIDs) + hiddenWorkspaceIDs
        if showingDashboard {
            guard direction > 0, let firstWorkspaceID = visibleWorkspaceIDs.first else { return nil }
            return .workspace(firstWorkspaceID)
        }
        if let selectedWorkspaceID, let currentIndex = visibleWorkspaceIDs.firstIndex(of: selectedWorkspaceID) {
            let targetIndex = currentIndex + direction
            if targetIndex < 0 { return .dashboard }
            guard targetIndex < visibleWorkspaceIDs.count else { return nil }
            return .workspace(visibleWorkspaceIDs[targetIndex])
        }
        guard let selectedProjectID, let projectIndex = visibleWorkspaceIDsByProject.firstIndex(where: { $0.projectID == selectedProjectID }) else {
            return nil
        }
        if direction < 0 {
            let priorProjects = visibleWorkspaceIDsByProject[..<projectIndex].reversed()
            for project in priorProjects { if let workspaceID = project.workspaceIDs.last { return .workspace(workspaceID) } }
            return .dashboard
        }
        for project in visibleWorkspaceIDsByProject[(projectIndex + 1)...] {
            if let workspaceID = project.workspaceIDs.first { return .workspace(workspaceID) }
        }
        if let hiddenWorkspaceID = hiddenWorkspaceIDs.first { return .workspace(hiddenWorkspaceID) }
        return nil
    }

    private func handleBufferedWindowShortcut(event: NSEvent) -> Bool {
        guard let windowIndex = bufferedWindowShortcutIndex(for: event) else { return false }
        bufferedWindowShortcutIndices.append(windowIndex)
        logWindowShortcutProfile(
            "stage=buffered index=\(windowIndex) sequence=\(bufferedWindowShortcutIndices.map(String.init).joined(separator: ","))")
        return true
    }

    private func handleGlobalHotkey(id: UInt32) {
        guard let hotkey = GlobalHotkey(rawValue: id) else { return }
        switch hotkey {
        case .toggle: toggleWindowFromHotkey()
        case .next: if NSApp.isActive { selectNextVisibleWorkspace() } else { focusGlobalWindowNavigation(direction: 1) }
        case .previous: if NSApp.isActive { selectPreviousVisibleWorkspace() } else { focusGlobalWindowNavigation(direction: -1) }
        case .openEditor: openGlobalEditorFromHotkey()
        }
    }

    private func openGlobalEditorFromHotkey() {
        guard let workspaceID = globalEditorWorkspaceID() else { return }
        openWorkspaceEditor(workspaceID: workspaceID)
    }

    private func globalEditorWorkspaceID() -> String? {
        if let workspaceID = try? orchestrator.workspaceIDForFocusedWindow() { return workspaceID }
        if NSApp.isActive, let selectedWorkspaceID { return selectedWorkspaceID }
        if let workspaceID = try? orchestrator.activeWorkspaceID() { return workspaceID }
        return nil
    }

    nonisolated static func activationSelectionTarget(focusedWorkspaceID: String?) -> SidebarArrowSelectionTarget {
        if let focusedWorkspaceID { return .workspace(focusedWorkspaceID) }
        return .dashboard
    }

    private func loadShortcutSpecs() {
        if let leaderRaw = try? orchestrator.guiLeaderHotkey(), let modifiers = try? HotkeySpec.parseModifierSet(leaderRaw) {
            shortcutLeaderModifiers = modifiers
        } else {
            shortcutLeaderModifiers = (try? HotkeySpec.parseModifierSet(SettingsKey.defaultGUILeaderHotkey)) ?? [.cmd, .alt]
        }
        toggleShortcutSpec = loadShortcutSpec(setting: .guiHotkey)
        dashboardShortcutSpec = loadShortcutSpec(setting: .guiDashboardShortcut)
        addProjectShortcutSpec = loadShortcutSpec(setting: .guiAddProjectShortcut)
        addWorkspaceShortcutSpec = loadShortcutSpec(setting: .guiAddWorkspaceShortcut)
        reloadShortcutSpec = loadShortcutSpec(setting: .guiReloadShortcut)
        nextShortcutSpec = loadShortcutSpec(setting: .guiNextShortcut)
        previousShortcutSpec = loadShortcutSpec(setting: .guiPreviousShortcut)
        openEditorShortcutSpec = loadShortcutSpec(setting: .guiOpenEditorShortcut)
        openTerminalShortcutSpec = loadShortcutSpec(setting: .guiOpenTerminalShortcut)
        openFinderShortcutSpec = loadShortcutSpec(setting: .guiOpenFinderShortcut)
        openSettingsShortcutSpec = loadShortcutSpec(setting: .guiOpenSettingsShortcut)
        windowShortcutSpec = loadShortcutSpec(setting: .guiWindowShortcut)
        windowSequenceShortcutSpec = loadShortcutSpec(setting: .guiWindowSequenceShortcut)
        refreshWorkspaceShortcutFooterRow()
    }

    private func loadShortcutSpec(setting: ShortcutSetting) -> HotkeySpec? {
        if let stored = try? HotkeySpec.parse(shortcutRawValue(for: setting)) { return stored }
        return try? HotkeySpec.parse(setting.defaultSpec)
    }

    private func shortcutRawValue(for setting: ShortcutSetting) throws -> String {
        switch setting {
        case .guiHotkey: return try orchestrator.guiHotkey()
        case .guiLeaderHotkey: return try orchestrator.guiLeaderHotkey()
        case .guiDashboardShortcut: return try orchestrator.guiDashboardShortcut()
        case .guiAddProjectShortcut: return try orchestrator.guiAddProjectShortcut()
        case .guiAddWorkspaceShortcut: return try orchestrator.guiAddWorkspaceShortcut()
        case .guiReloadShortcut: return try orchestrator.guiReloadShortcut()
        case .guiNextShortcut: return try orchestrator.guiNextShortcut()
        case .guiPreviousShortcut: return try orchestrator.guiPreviousShortcut()
        case .guiOpenEditorShortcut: return try orchestrator.guiOpenEditorShortcut()
        case .guiOpenTerminalShortcut: return try orchestrator.guiOpenTerminalShortcut()
        case .guiOpenFinderShortcut: return try orchestrator.guiOpenFinderShortcut()
        case .guiOpenSettingsShortcut: return try orchestrator.guiOpenSettingsShortcut()
        case .guiWindowShortcut: return try orchestrator.guiWindowShortcut()
        case .guiWindowSequenceShortcut: return try orchestrator.guiWindowSequenceShortcut()
        }
    }

    private func setShortcutSetting(setting: ShortcutSetting, value: String?) throws {
        switch setting {
        case .guiHotkey: try orchestrator.setGUIHotkey(value)
        case .guiLeaderHotkey: try orchestrator.setGUILeaderHotkey(value)
        case .guiDashboardShortcut: try orchestrator.setGUIDashboardShortcut(value)
        case .guiAddProjectShortcut: try orchestrator.setGUIAddProjectShortcut(value)
        case .guiAddWorkspaceShortcut: try orchestrator.setGUIAddWorkspaceShortcut(value)
        case .guiReloadShortcut: try orchestrator.setGUIReloadShortcut(value)
        case .guiNextShortcut: try orchestrator.setGUINextShortcut(value)
        case .guiPreviousShortcut: try orchestrator.setGUIPreviousShortcut(value)
        case .guiOpenEditorShortcut: try orchestrator.setGUIOpenEditorShortcut(value)
        case .guiOpenTerminalShortcut: try orchestrator.setGUIOpenTerminalShortcut(value)
        case .guiOpenFinderShortcut: try orchestrator.setGUIOpenFinderShortcut(value)
        case .guiOpenSettingsShortcut: try orchestrator.setGUIOpenSettingsShortcut(value)
        case .guiWindowShortcut: try orchestrator.setGUIWindowShortcut(value)
        case .guiWindowSequenceShortcut: try orchestrator.setGUIWindowSequenceShortcut(value)
        }
    }

    private func shortcutSpec(for setting: ShortcutSetting) -> HotkeySpec? {
        switch setting {
        case .guiHotkey: return toggleShortcutSpec
        case .guiLeaderHotkey: return nil
        case .guiDashboardShortcut: return dashboardShortcutSpec
        case .guiAddProjectShortcut: return addProjectShortcutSpec
        case .guiAddWorkspaceShortcut: return addWorkspaceShortcutSpec
        case .guiReloadShortcut: return reloadShortcutSpec
        case .guiNextShortcut: return nextShortcutSpec
        case .guiPreviousShortcut: return previousShortcutSpec
        case .guiOpenEditorShortcut: return openEditorShortcutSpec
        case .guiOpenTerminalShortcut: return openTerminalShortcutSpec
        case .guiOpenFinderShortcut: return openFinderShortcutSpec
        case .guiOpenSettingsShortcut: return openSettingsShortcutSpec
        case .guiWindowShortcut: return windowShortcutSpec
        case .guiWindowSequenceShortcut: return windowSequenceShortcutSpec
        }
    }

    private func matches(event: NSEvent, spec: HotkeySpec) -> Bool {
        guard UInt32(event.keyCode) == spec.keyCode else { return false }
        let flags = eventModifierCarbonFlags(event)
        return flags == spec.modifiersCarbon
    }

    private func eventModifierCarbonFlags(_ event: NSEvent) -> UInt32 {
        var result: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    private func performWindowFocus(_ request: WindowFocusRequest) async {
        let result = await Self.performWindowFocusSnapshot(request)
        switch result {
        case .success: hideAfterSuccessfulExternalWindowAction(.focus)
        case .failure(let error): await handleWindowFocusFailure(error)
        }
    }

    private func launchConfiguredAgent(workspaceID: String, name: String) async {
        let result = await Self.launchConfiguredAgentSnapshot(workspaceID: workspaceID, name: name)
        switch result {
        case .success:
            reloadData()
            hideAfterSuccessfulExternalWindowAction(.open)
        case .failure(let error): showError(error)
        }
    }

    private func focusWindowShortcut(index: Int) {
        let startedAt = Date()
        Task { @MainActor [weak self] in await self?.runWindowShortcut(index: index, startedAt: startedAt) }
    }

    private func runWindowShortcut(index: Int, startedAt: Date) async {
        activeWindowShortcutProfile = WindowShortcutProfile(index: index, startedAt: startedAt)
        logWindowShortcutProfile("stage=received index=\(index) dashboard=\(showingDashboard ? 1 : 0)")
        let dashboardFocusRequest = showingDashboard ? dashboardFocusRequestMap[index] : nil
        let routeStartedAt = Date()
        let result = await Self.focusWindowShortcutSnapshot(
            index: index, selectedWorkspaceID: selectedWorkspaceID, dashboardFocusRequest: dashboardFocusRequest)
        switch result {
        case .success(.focused(let kind)):
            logWindowShortcutProfile("stage=route_done index=\(index) kind=\(kind) elapsed_ms=\(windowShortcutElapsedMS(since: routeStartedAt))")
            activeWindowShortcutProfile?.routeCompletedAt = Date()
            logWindowShortcutProfile("stage=total index=\(index) elapsed_ms=\(windowShortcutElapsedMS(since: startedAt))")
            logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true)
            hideAfterSuccessfulExternalWindowAction(.focus)
        case .success(.opened(let kind)):
            logWindowShortcutProfile("stage=route_done index=\(index) kind=\(kind) elapsed_ms=\(windowShortcutElapsedMS(since: routeStartedAt))")
            activeWindowShortcutProfile?.routeCompletedAt = Date()
            logWindowShortcutProfile("stage=total index=\(index) elapsed_ms=\(windowShortcutElapsedMS(since: startedAt))")
            logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true)
            reloadData()
            hideAfterSuccessfulExternalWindowAction(.open)
        case .success(.noWorkspace):
            logWindowShortcutProfile("stage=aborted index=\(index) reason=no_workspace elapsed_ms=\(windowShortcutElapsedMS(since: startedAt))")
            logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false)
        case .success(.noMatch):
            logWindowShortcutProfile("stage=aborted index=\(index) reason=no_match elapsed_ms=\(windowShortcutElapsedMS(since: startedAt))")
            logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false)
        case .failure(let error):
            await handleWindowFocusFailure(error)
            logWindowShortcutProfile("stage=aborted index=\(index) reason=error elapsed_ms=\(windowShortcutElapsedMS(since: startedAt))")
            logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false)
        }
    }

    private func logWindowShortcutProfile(_ message: String) {
        guard ProcessInfo.processInfo.environment["DEBUG"] == "1" else { return }
        fputs("muxy: window_shortcut \(message)\n", stderr)
    }

    private func logPerfMetric(_ metric: String, target: String, elapsedMS: Int, success: Bool) {
        guard ProcessInfo.processInfo.environment["DEBUG"] == "1" else { return }
        fputs("muxy: perf metric=\(metric) target=\(target) success=\(success ? 1 : 0) elapsed_ms=\(elapsedMS)\n", stderr)
    }

    private func windowShortcutElapsedMS(since start: Date) -> Int { max(Int(Date().timeIntervalSince(start) * 1000), 0) }

    private func windowShortcutIndex(for event: NSEvent) -> Int? {
        guard let windowShortcutSpec else { return nil }
        return numberedWindowShortcutIndex(for: event, spec: windowShortcutSpec)
    }

    private func bufferedWindowShortcutIndex(for event: NSEvent) -> Int? {
        guard !event.isARepeat else { return nil }
        guard let windowSequenceShortcutSpec else { return nil }
        return numberedWindowShortcutIndex(for: event, spec: windowSequenceShortcutSpec)
    }

    private func numberedWindowShortcutIndex(for event: NSEvent, spec: HotkeySpec) -> Int? {
        guard eventModifierCarbonFlags(event) == spec.modifiersCarbon else { return nil }
        let keyMap: [UInt16: Int] = [
            UInt16(kVK_ANSI_1): 1, UInt16(kVK_ANSI_2): 2, UInt16(kVK_ANSI_3): 3, UInt16(kVK_ANSI_4): 4, UInt16(kVK_ANSI_5): 5, UInt16(kVK_ANSI_6): 6,
            UInt16(kVK_ANSI_7): 7, UInt16(kVK_ANSI_8): 8, UInt16(kVK_ANSI_9): 9,
        ]
        return keyMap[event.keyCode]
    }

    private func windowShortcutBadgeText(index: Int) -> String {
        guard let windowShortcutSpec else { return "SHORTCUT \(index)" }
        return displayShortcutText(windowShortcutSpec, keyText: String(index)).uppercased()
    }

    private func flushBufferedWindowShortcuts() {
        let indices = bufferedWindowShortcutIndices
        guard !indices.isEmpty else { return }
        bufferedWindowShortcutIndices.removeAll()
        logWindowShortcutProfile("stage=flush sequence=\(indices.map(String.init).joined(separator: ","))")
        Task { @MainActor [weak self] in
            guard let self else { return }
            for index in indices {
                self.logWindowShortcutProfile("stage=sequence_dispatch index=\(index)")
                await self.runWindowShortcut(index: index, startedAt: Date())
            }
        }
    }

    private func selectNextVisibleWorkspace() {
        let allVisible = orderedSidebarWorkspaces()
        guard !allVisible.isEmpty else { return }
        if let currentID = selectedWorkspaceID, let idx = allVisible.firstIndex(where: { $0.id == currentID }) {
            selectWorkspace(allVisible[(idx + 1) % allVisible.count])
        } else {
            selectWorkspace(allVisible[0])
        }
    }

    private func selectPreviousVisibleWorkspace() {
        let allVisible = orderedSidebarWorkspaces()
        guard !allVisible.isEmpty else { return }
        if let currentID = selectedWorkspaceID, let idx = allVisible.firstIndex(where: { $0.id == currentID }) {
            selectWorkspace(allVisible[(idx - 1 + allVisible.count) % allVisible.count])
        } else {
            selectWorkspace(allVisible[allVisible.count - 1])
        }
    }

    private func selectWorkspace(_ workspace: WorkspaceSummary) {
        for row in 0..<outlineView.numberOfRows {
            if let ref = outlineView.item(atRow: row) as? OutlineItemRef {
                if case .workspace(_, let ws) = ref.item, ws.id == workspace.id {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    break
                }
            }
        }
    }

    private func orderedSidebarWorkspaces() -> [WorkspaceSummary] {
        let visible = projects.flatMap { visibleWorkspaces(projectID: $0.id) }
        guard !hiddenWorkspacesCollapsed else { return visible }
        return visible + hiddenWorkspaces().map(\.1)
    }

    private func focusGlobalWindowNavigation(direction: Int) {
        guard !NSApp.isActive else { return }
        guard let workspaceID = globalWindowNavigationWorkspaceID() else { return }
        do {
            if direction > 0 {
                try orchestrator.focusNextWindow(workspaceID: workspaceID)
            } else {
                try orchestrator.focusPreviousWindow(workspaceID: workspaceID)
            }
            hideAfterSuccessfulExternalWindowAction(.focus)
        } catch { showError(error) }
    }

    private func hideAfterSuccessfulExternalWindowAction(_ action: ExternalWindowAction) {
        let hideDelay = Self.hideDelayAfterSuccessfulExternalWindowAction(true, action: action)
        guard hideDelay != nil || Self.shouldHideAfterSuccessfulExternalWindowAction(true, action: action) else { return }
        deferredExternalWindowHideTask?.cancel()
        if let hideDelay {
            deferredExternalWindowHideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: hideDelay)
                guard let self, !Task.isCancelled else { return }
                self.deferredExternalWindowHideTask = nil
                NSApp.hide(nil)
            }
            return
        }
        NSApp.hide(nil)
    }

    private func handleWindowFocusFailure(_ error: Error) async {
        guard let muxyError = error as? MuxyError, case .missingTrackedWindow(let context) = muxyError else {
            handleWindowFocusError(error)
            return
        }
        guard context.kind == .process else {
            handleWindowFocusError(error)
            return
        }

        switch await Self.recoverRunningWorkspaceProcessIfPossibleSnapshot(context) {
        case .success(true): reloadData()
        case .success(false): handleWindowFocusError(error)
        case .failure(let recoveryError): showError(recoveryError)
        }
    }

    private func handleWindowFocusError(_ error: Error) {
        guard let muxyError = error as? MuxyError, case .missingTrackedWindow(let context) = muxyError else {
            showError(error)
            return
        }
        switch context.kind {
        case .browserSession:
            showWindowIssueModal(
                title: "Browser window not found", detail: "\(context.title) is no longer open.", actionTitle: "Recover (Cmd+R)",
                action: { [weak self] in Task { await self?.recoverMissingTrackedWindow(context) } })
        case .process:
            showWindowIssueModal(
                title: "Process window not found", detail: "\(context.title) is no longer open.", actionTitle: "Recover (Cmd+R)",
                action: { [weak self] in Task { await self?.recoverMissingTrackedWindow(context) } })
        case .codingAgent: showWindowIssueModal(title: "Agent window not found", detail: "\(context.title) is no longer open.")
        case .window: showWindowIssueModal(title: "Window not found", detail: "\(context.title) is no longer open.")
        }
    }

    private func recoverMissingTrackedWindow(_ context: MissingTrackedWindowContext) async {
        let progressTitle: String
        let progressDetail: String
        switch context.kind {
        case .browserSession:
            progressTitle = "Recovering Browser Session"
            progressDetail = context.title
        case .process:
            progressTitle = "Recovering Process"
            progressDetail = context.title
        case .codingAgent, .window: return
        }

        showOperationProgressOverlay(message: progressTitle, detail: progressDetail)
        let result = await Self.recoverMissingTrackedWindowSnapshot(context)
        hideOperationProgressOverlay()
        switch result {
        case .success:
            reloadData()
            switch context.kind {
            case .browserSession:
                showWindowIssueToast(title: "Browser session recovered", detail: "\(context.title) reopened in a new Chrome window.")
            case .process: showWindowIssueToast(title: "Process recovered", detail: "\(context.title) reopened in a new iTerm2 window.")
            case .codingAgent, .window: break
            }
        case .failure(let error): showError(error)
        }
    }

    private func globalWindowNavigationWorkspaceID() -> String? {
        if let workspaceID = try? orchestrator.workspaceIDForFocusedWindow() { return workspaceID }
        if let workspaceID = try? orchestrator.activeWorkspaceID() { return workspaceID }
        return nil
    }

    private func toggleWindowFromHotkey() {
        guard let window else { return }
        if NSApp.isActive, !NSApp.isHidden, window.isVisible, !window.isMiniaturized {
            NSApp.hide(nil)
            return
        }
        let focusedWorkspaceID = try? orchestrator.workspaceIDForFocusedWindow()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.unhide(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        prepareWindowForActiveSpaceSummon(window)
        window.orderFrontRegardless()
        window.makeKey()
        scheduleDeferredHotkeySelectionRefresh(focusedWorkspaceID: focusedWorkspaceID ?? nil)
    }

    private func prepareWindowForActiveSpaceSummon(_ window: NSWindow) {
        activeSpaceSummonCleanupTask?.cancel()
        window.collectionBehavior = Self.collectionBehaviorForActiveSpaceSummon(window.collectionBehavior)
        activeSpaceSummonCleanupTask = Task { @MainActor [weak self, weak window] in
            await Task.yield()
            guard let self, !Task.isCancelled, let window else { return }
            window.collectionBehavior = Self.collectionBehaviorAfterActiveSpaceSummon(window.collectionBehavior)
            self.activeSpaceSummonCleanupTask = nil
        }
    }

    nonisolated static func collectionBehaviorForActiveSpaceSummon(_ behavior: NSWindow.CollectionBehavior) -> NSWindow.CollectionBehavior {
        var updated = behavior
        updated.insert(.moveToActiveSpace)
        return updated
    }

    nonisolated static func collectionBehaviorAfterActiveSpaceSummon(_ behavior: NSWindow.CollectionBehavior) -> NSWindow.CollectionBehavior {
        var updated = behavior
        updated.remove(.moveToActiveSpace)
        return updated
    }

    private func scheduleDeferredHotkeySelectionRefresh(focusedWorkspaceID: String?) {
        deferredHotkeySelectionRefreshTask?.cancel()
        deferredHotkeySelectionRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.refreshWorkspaceSelectionForActivation(focusedWorkspaceID: focusedWorkspaceID)
        }
    }

    private func refreshWorkspaceSelectionForActivation(focusedWorkspaceID: String?) {
        switch Self.activationSelectionTarget(focusedWorkspaceID: focusedWorkspaceID) {
        case .dashboard:
            if showingDashboard, !showingSettings {
                refreshSelection()
                return
            }
            showDashboardDetail()
        case .workspace(let targetWorkspaceID):
            guard let (_, workspace) = findWorkspace(id: targetWorkspaceID) else { return }
            if selectedWorkspaceID == targetWorkspaceID, !showingDashboard, !showingSettings {
                refreshSelection()
                return
            }
            selectWorkspace(workspace)
        }
    }

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return projects.count + (hiddenWorkspaces().isEmpty ? 0 : 1) }
        if case .project(let project) = (item as? OutlineItemRef)?.item { return visibleWorkspaces(projectID: project.id).count }
        if case .hiddenWorkspaces = (item as? OutlineItemRef)?.item { return hiddenWorkspaces().count }
        return 0
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if case .project = (item as? OutlineItemRef)?.item { return true }
        if case .hiddenWorkspaces = (item as? OutlineItemRef)?.item { return true }
        return false
    }

    public func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { true }

    public func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { return true }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            if index < projects.count { return outlineItemRef(for: .project(projects[index])) }
            return outlineItemRef(for: .hiddenWorkspaces)
        }
        if case .project(let project) = (item as? OutlineItemRef)?.item {
            let visible = visibleWorkspaces(projectID: project.id)
            let workspace =
                (index >= 0 && index < visible.count ? visible[index] : nil)
                ?? WorkspaceSummary(
                    id: "", title: "", branch: nil, targetBranch: nil, dir: "", isRunning: false, isArchived: false, isHidden: false, isDefault: false
                )
            return outlineItemRef(for: .workspace(project, workspace))
        }
        if case .hiddenWorkspaces = (item as? OutlineItemRef)?.item {
            let hidden = hiddenWorkspaces()
            let entry =
                (index >= 0 && index < hidden.count ? hidden[index] : nil) ?? (
                    projects[0],
                    WorkspaceSummary(
                        id: "", title: "", branch: nil, targetBranch: nil, dir: "", isRunning: false, isArchived: false, isHidden: true,
                        isDefault: false)
                )
            return outlineItemRef(for: .workspace(entry.0, entry.1))
        }
        return outlineItemRef(for: .project(projects[0]))
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

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let ref = item as? OutlineItemRef else { return nil }
        switch ref.item {
        case .project(let project): return projectRowCell(project: project, isSelected: selectedProjectID == project.id && selectedWorkspaceID == nil)
        case .hiddenWorkspaces: return sidebarSectionRowCell(title: "Hidden", isSelected: false)
        case .workspace(let project, let workspace):
            return workspaceRowCell(project: project, workspace: workspace, isSelected: selectedWorkspaceID == workspace.id)
        }
    }

    private func sidebarSectionRowCell(title: String, isSelected: Bool) -> NSTableCellView {
        let cell = NSTableCellView()

        let rowBackground = NSView()
        rowBackground.translatesAutoresizingMaskIntoConstraints = false
        rowBackground.wantsLayer = true
        rowBackground.layer?.cornerRadius = UIRadius.regular
        rowBackground.layer?.borderWidth = isSelected ? 1 : 0
        rowBackground.layer?.borderColor = sidebarCardBorderColor(isSelected: true).cgColor
        rowBackground.layer?.backgroundColor = isSelected ? sidebarSelectedCardBackgroundColor().cgColor : NSColor.clear.cgColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = sidebarPrimaryTextColor(isSelected: isSelected, isArchived: false)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        rowBackground.addSubview(titleLabel)
        cell.addSubview(rowBackground)
        NSLayoutConstraint.activate([
            rowBackground.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            rowBackground.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            rowBackground.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),
            rowBackground.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3),

            titleLabel.leadingAnchor.constraint(equalTo: rowBackground.leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: rowBackground.trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: rowBackground.centerYAnchor),
        ])
        return cell
    }

    private func projectRowCell(project: ProjectSummary, isSelected: Bool) -> NSTableCellView {
        let cell = NSTableCellView()

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

        let leadingStack = NSStackView()
        leadingStack.orientation = .horizontal
        leadingStack.alignment = .centerY
        leadingStack.spacing = 8
        leadingStack.translatesAutoresizingMaskIntoConstraints = false
        leadingStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        leadingStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        leadingStack.addArrangedSubview(titleLabel)

        let accessoryStack = NSStackView()
        accessoryStack.orientation = .horizontal
        accessoryStack.alignment = .centerY
        accessoryStack.spacing = 4
        accessoryStack.translatesAutoresizingMaskIntoConstraints = false
        accessoryStack.setContentHuggingPriority(.required, for: .horizontal)
        let settingsButton = sidebarRowIconButton(
            symbol: "gearshape", tooltip: "Project settings for \(project.name)", action: #selector(showProjectSettings(_:)))
        settingsButton.identifier = NSUserInterfaceItemIdentifier(project.id)
        settingsButton.setAccessibilityIdentifier("sidebar-project-settings-\(project.id)")
        accessoryStack.addArrangedSubview(settingsButton)

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
            rowBackground.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            rowBackground.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            rowBackground.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),
            rowBackground.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3),

            contentRow.leadingAnchor.constraint(equalTo: rowBackground.leadingAnchor, constant: 10),
            contentRow.trailingAnchor.constraint(equalTo: rowBackground.trailingAnchor, constant: -10),
            contentRow.topAnchor.constraint(equalTo: rowBackground.topAnchor, constant: 5),
            contentRow.bottomAnchor.constraint(equalTo: rowBackground.bottomAnchor, constant: -5),
        ])
        if project.isGitRepo {
            let addButton = sidebarRowIconButton(symbol: "plus", tooltip: "New workspace in \(project.name)", action: #selector(addWorkspace(_:)))
            addButton.identifier = NSUserInterfaceItemIdentifier(project.id)
            addButton.setAccessibilityIdentifier("sidebar-project-add-workspace-\(project.id)")
            accessoryStack.addArrangedSubview(addButton)
        }
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
            workspaceRuntimeStatusByID[workspace.id]
            ?? WorkspaceRuntimeStatus(
                workspaceID: workspace.id, lifecycleState: WorkspaceLifecycleState(isRunning: workspace.isRunning), runtimeHealth: .healthy,
                hasTrackedRuntimeIndicators: false, runningProcessCount: 0, exitedProcessCount: 0, failedCheckCount: 0, waitingAgentWindowCount: 0,
                missingConfiguredProcessCount: 0, missingConfiguredBrowserSessionCount: 0)
        let isLifecycleRunning = runtimeStatus.lifecycleState == .running
        statusIcon.image = NSImage(systemSymbolName: isLifecycleRunning ? "circle.fill" : "circle", accessibilityDescription: "Status")
        statusIcon.contentTintColor = isLifecycleRunning ? sidebarRunningIndicatorColor() : sidebarIdleIndicatorColor()
        statusIcon.toolTip = isLifecycleRunning ? "Running" : "Stopped"
        statusIcon.widthAnchor.constraint(equalToConstant: 10).isActive = true
        statusIcon.heightAnchor.constraint(equalToConstant: 10).isActive = true

        let nameLabel = NSTextField(labelWithString: workspace.title)
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
        if workspace.isHidden {
            titleRow.addArrangedSubview(NSView())

            let unhideButton = NSButton(title: "Unhide", target: self, action: #selector(toggleWorkspaceHidden(_:)))
            unhideButton.bezelStyle = .texturedRounded
            unhideButton.controlSize = .small
            unhideButton.font = .systemFont(ofSize: 11)
            unhideButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
            unhideButton.setAccessibilityIdentifier("sidebar-workspace-unhide-\(workspace.id)")
            titleRow.addArrangedSubview(unhideButton)
        }
        contentStack.addArrangedSubview(titleRow)

        if let branchRow = Self.makeSidebarWorkspaceBranchRow(
            branch: workspace.branch ?? "", textColor: sidebarMetadataTextColor(isSelected: isSelected),
            accessibilityID: "sidebar-workspace-branch-\(workspace.id)")
        {
            contentStack.addArrangedSubview(branchRow)
        }

        if workspace.isHidden {
            if !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let projectRow = sidebarMetadataRow(symbol: "folder", text: project.name, isSelected: isSelected, leadingIndent: 20)
                projectRow.setAccessibilityIdentifier("sidebar-workspace-project-\(workspace.id)")
                contentStack.addArrangedSubview(projectRow)
            }
        }

        cardView.addSubview(contentStack)
        cell.addSubview(cardView)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: cell.leadingAnchor), cardView.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            cardView.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
            cardView.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -2),

            contentStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 12),
            contentStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -12),
            contentStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 7),
            contentStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -7),
        ])

        return cell
    }

    /// Builds the branch subtitle row shown under a sidebar workspace title.
    /// Returns `nil` when the branch is missing or whitespace-only so callers can
    /// skip appending a row rather than rendering an empty line.
    static func makeSidebarWorkspaceBranchRow(branch: String, textColor: NSColor, accessibilityID: String) -> NSStackView? {
        let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false

        let indent = NSView()
        indent.translatesAutoresizingMaskIntoConstraints = false
        indent.widthAnchor.constraint(equalToConstant: 16).isActive = true
        indent.setContentHuggingPriority(.required, for: .horizontal)

        let branchIcon = NSImageView()
        branchIcon.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Branch")
        branchIcon.contentTintColor = textColor
        branchIcon.translatesAutoresizingMaskIntoConstraints = false
        branchIcon.widthAnchor.constraint(equalToConstant: 10).isActive = true
        branchIcon.heightAnchor.constraint(equalToConstant: 10).isActive = true

        let label = NSTextField(labelWithString: trimmed)
        label.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        label.textColor = textColor
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = trimmed
        label.setAccessibilityIdentifier(accessibilityID)

        row.addArrangedSubview(indent)
        row.addArrangedSubview(branchIcon)
        row.addArrangedSubview(label)
        return row
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

    public func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let ref = item as? OutlineItemRef else { return 24 }
        switch ref.item {
        case .project(let project): return selectedProjectID == project.id && selectedWorkspaceID == nil ? 38 : 36
        case .hiddenWorkspaces: return 32
        case .workspace(_, let workspace): return workspace.isHidden ? 66 : 52
        }
    }

    private func sidebarPanelBackgroundColor() -> NSColor { sidebarThemeColor(light: (248, 247, 241), dark: (15, 21, 23)) }

    private func sidebarCardBackgroundColor(isArchived: Bool) -> NSColor {
        let alpha: CGFloat = isArchived ? 0.42 : 0.55
        return sidebarThemeColor(light: (240, 238, 230), dark: (24, 36, 39), alpha: alpha)
    }

    private func sidebarSelectedCardBackgroundColor() -> NSColor { sidebarThemeColor(light: (226, 224, 216), dark: (24, 35, 39), alpha: 0.85) }

    private func sidebarCardBorderColor(isSelected: Bool) -> NSColor {
        if isSelected { return sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184), alpha: 0.28) }
        return sidebarThemeColor(light: (213, 216, 211), dark: (48, 67, 70), alpha: 0.72)
    }

    private func sidebarPrimaryTextColor(isSelected: Bool, isArchived: Bool) -> NSColor {
        let alpha: CGFloat = if isArchived { 0.70 } else if isSelected { 0.96 } else { 0.92 }
        return sidebarThemeColor(light: (16, 32, 40), dark: (234, 240, 239), alpha: alpha)
    }

    private func sidebarMetadataTextColor(isSelected: Bool) -> NSColor {
        let alpha: CGFloat = isSelected ? 0.88 : 0.82
        return sidebarThemeColor(light: (58, 77, 87), dark: (173, 192, 196), alpha: alpha)
    }

    private func sidebarRunningIndicatorColor() -> NSColor { sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184), alpha: 0.95) }

    private func sidebarFailedIndicatorColor() -> NSColor { sidebarThemeColor(light: (186, 67, 111), dark: (255, 111, 91), alpha: 0.95) }

    private func sidebarIdleIndicatorColor() -> NSColor { sidebarThemeColor(light: (213, 216, 211), dark: (48, 67, 70), alpha: 0.85) }

    private func sidebarThemeColor(light: (Int, Int, Int), dark: (Int, Int, Int), alpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let source = isDark ? dark : light
            return NSColor(calibratedRed: CGFloat(source.0) / 255, green: CGFloat(source.1) / 255, blue: CGFloat(source.2) / 255, alpha: alpha)
        }
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        if suppressOutlineSelectionChanges { return }
        let row = outlineView.selectedRow
        guard row >= 0, let ref = outlineView.item(atRow: row) as? OutlineItemRef else {
            let previousProjectID = selectedProjectID
            let previousWorkspaceID = selectedWorkspaceID
            selectedProjectID = nil
            selectedWorkspaceID = nil
            showingSettings = false
            if !showingDashboard { showPlaceholder() }
            refreshSidebarSelectionRows(
                previousProjectID: previousProjectID, currentProjectID: selectedProjectID, previousWorkspaceID: previousWorkspaceID,
                currentWorkspaceID: selectedWorkspaceID)
            return
        }
        let item = ref.item
        if case .project = item {
            suppressOutlineSelectionChanges = true
            outlineView.deselectAll(nil)
            suppressOutlineSelectionChanges = false
            return
        }
        if case .hiddenWorkspaces = item {
            suppressOutlineSelectionChanges = true
            outlineView.deselectAll(nil)
            suppressOutlineSelectionChanges = false
            return
        }

        let previousProjectID = selectedProjectID
        let previousWorkspaceID = selectedWorkspaceID
        if projectHasUnsavedChanges {
            let response = unsavedChangesPrompt()
            if response == .alertFirstButtonReturn {
                if !saveCurrentDetail() {
                    outlineView.selectRowIndexes(IndexSet(integer: lastSelectedRow), byExtendingSelection: false)
                    return
                }
            } else if response == .alertThirdButtonReturn {
                outlineView.selectRowIndexes(IndexSet(integer: lastSelectedRow), byExtendingSelection: false)
                return
            } else {
                projectHasUnsavedChanges = false
            }
        }
        lastSelectedRow = row
        switch item {
        case .project(let project):
            selectedProjectID = project.id
            selectedWorkspaceID = nil
            showingSettings = false
            showProjectDetail(project: project)
        case .hiddenWorkspaces: return
        case .workspace(let project, let workspace):
            selectedProjectID = project.id
            selectedWorkspaceID = workspace.id
            showingSettings = false
            showWorkspaceDetail(project: project, workspace: workspace)
        }
        refreshSidebarSelectionRows(
            previousProjectID: previousProjectID, currentProjectID: selectedProjectID, previousWorkspaceID: previousWorkspaceID,
            currentWorkspaceID: selectedWorkspaceID)
    }

    private func refreshSidebarSelectionRows(
        previousProjectID: String?, currentProjectID: String?, previousWorkspaceID: String?, currentWorkspaceID: String?
    ) {
        var rowsToReload = IndexSet()
        if let previousProjectID, let previousRow = rowIndex(forProjectID: previousProjectID) { rowsToReload.insert(previousRow) }
        if let currentProjectID, let currentRow = rowIndex(forProjectID: currentProjectID) { rowsToReload.insert(currentRow) }
        if let previousWorkspaceID, let previousRow = rowIndex(forWorkspaceID: previousWorkspaceID) { rowsToReload.insert(previousRow) }
        if let currentWorkspaceID, let currentRow = rowIndex(forWorkspaceID: currentWorkspaceID) { rowsToReload.insert(currentRow) }
        guard !rowsToReload.isEmpty else { return }
        outlineView.reloadData(forRowIndexes: rowsToReload, columnIndexes: IndexSet(integer: 0))
    }

    private func rowIndex(forWorkspaceID workspaceID: String) -> Int? {
        for row in 0..<outlineView.numberOfRows {
            guard let ref = outlineView.item(atRow: row) as? OutlineItemRef else { continue }
            if case .workspace(_, let workspace) = ref.item, workspace.id == workspaceID { return row }
        }
        return nil
    }

    private func rowIndex(forProjectID projectID: String) -> Int? {
        for row in 0..<outlineView.numberOfRows {
            guard let ref = outlineView.item(atRow: row) as? OutlineItemRef else { continue }
            if case .project(let project) = ref.item, project.id == projectID { return row }
        }
        return nil
    }

    private func rowIndexForHiddenWorkspacesSection() -> Int? {
        for row in 0..<outlineView.numberOfRows {
            guard let ref = outlineView.item(atRow: row) as? OutlineItemRef else { continue }
            if case .hiddenWorkspaces = ref.item { return row }
        }
        return nil
    }

    private func toggleProjectExpanded(projectID: String) {
        guard let row = rowIndex(forProjectID: projectID), let item = outlineView.item(atRow: row) else { return }
        let isCollapsed = outlineView.isItemExpanded(item)
        let previousProjectID = selectedProjectID
        let previousWorkspaceID = selectedWorkspaceID
        do {
            try orchestrator.setProjectCollapsed(projectID: projectID, isCollapsed: isCollapsed)
            updateProjectCollapsedStateInMemory(projectID: projectID, isCollapsed: isCollapsed)
        } catch {
            showError(error)
            return
        }
        if isCollapsed { outlineView.collapseItem(item) } else { outlineView.expandItem(item) }
        if isCollapsed, let selectedWorkspaceID, let (project, _) = findWorkspace(id: selectedWorkspaceID), project.id == projectID {
            self.selectedWorkspaceID = nil
            self.selectedProjectID = projectID
            lastSelectedRow = row
            suppressOutlineSelectionChanges = true
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            suppressOutlineSelectionChanges = false
            if let refreshedProject = projects.first(where: { $0.id == projectID }) { showProjectDetail(project: refreshedProject) }
            refreshSidebarSelectionRows(
                previousProjectID: previousProjectID, currentProjectID: selectedProjectID, previousWorkspaceID: previousWorkspaceID,
                currentWorkspaceID: selectedWorkspaceID)
        }
        outlineView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    private func applySidebarProjectExpansionState() {
        for project in projects {
            guard let row = rowIndex(forProjectID: project.id), let item = outlineView.item(atRow: row) else { continue }
            if project.isCollapsed { outlineView.collapseItem(item) } else { outlineView.expandItem(item) }
        }
        guard let row = rowIndexForHiddenWorkspacesSection(), let item = outlineView.item(atRow: row) else { return }
        if hiddenWorkspacesCollapsed { outlineView.collapseItem(item) } else { outlineView.expandItem(item) }
    }

    private func toggleHiddenWorkspacesExpanded() {
        guard let row = rowIndexForHiddenWorkspacesSection(), let item = outlineView.item(atRow: row) else { return }
        hiddenWorkspacesCollapsed.toggle()
        if hiddenWorkspacesCollapsed { outlineView.collapseItem(item) } else { outlineView.expandItem(item) }
        if hiddenWorkspacesCollapsed, let currentWorkspaceID = selectedWorkspaceID, let (_, workspace) = findWorkspace(id: currentWorkspaceID),
            workspace.isHidden
        {
            selectedWorkspaceID = nil
            suppressOutlineSelectionChanges = true
            outlineView.deselectAll(nil)
            suppressOutlineSelectionChanges = false
            refreshSelection()
        }
        outlineView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }

    private func updateProjectCollapsedStateInMemory(projectID: String, isCollapsed: Bool) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let project = projects[index]
        projects[index] = ProjectSummary(
            id: project.id, name: project.name, dir: project.dir, isGitRepo: project.isGitRepo, defaultBranch: project.defaultBranch,
            isCollapsed: isCollapsed)
    }

    @objc private func showProjectSettings(_ sender: NSButton) {
        guard let projectID = sender.identifier?.rawValue, let project = projects.first(where: { $0.id == projectID }) else { return }
        let previousProjectID = selectedProjectID
        let previousWorkspaceID = selectedWorkspaceID
        if projectHasUnsavedChanges {
            let response = unsavedChangesPrompt()
            if response == .alertFirstButtonReturn {
                if !saveCurrentDetail() { return }
            } else if response == .alertThirdButtonReturn {
                return
            } else {
                projectHasUnsavedChanges = false
            }
        }

        suppressOutlineSelectionChanges = true
        outlineView.deselectAll(nil)
        suppressOutlineSelectionChanges = false
        lastSelectedRow = -1
        selectedProjectID = project.id
        selectedWorkspaceID = nil
        showingSettings = false
        showProjectDetail(project: project)
        refreshSidebarSelectionRows(
            previousProjectID: previousProjectID, currentProjectID: selectedProjectID, previousWorkspaceID: previousWorkspaceID,
            currentWorkspaceID: selectedWorkspaceID)
    }

    public func splitViewDidResizeSubviews(_ notification: Notification) {}

    public func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        guard let first = splitView.subviews.first else { return true }
        return view !== first
    }

    public func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard splitView.subviews.count == 2 else {
            splitView.adjustSubviews()
            return
        }
        let divider = splitView.dividerThickness
        let bounds = splitView.bounds
        let left = splitView.subviews[0]
        let right = splitView.subviews[1]

        let preferredWidth = left.frame.width > 0 ? left.frame.width : defaultSplitViewWidth
        let maxLeftWidth = max(0, bounds.width - divider)
        let leftWidth = min(preferredWidth, maxLeftWidth)

        left.frame = NSRect(x: 0, y: 0, width: leftWidth, height: bounds.height)
        let rightX = leftWidth + divider
        right.frame = NSRect(x: rightX, y: 0, width: max(0, bounds.width - rightX), height: bounds.height)
    }

    private func registerDirtyTracking(
        setupView: NSTextView, stopView: NSTextView, portEditor: PortEditor, processEditor: ProcessEditor, browserSessionEditor: BrowserSessionEditor,
        agentLauncherEditor: AgentLauncherEditor
    ) {
        projectHasUnsavedChanges = false
        NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: setupView, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.projectHasUnsavedChanges = true }
        }
        NotificationCenter.default.addObserver(forName: NSText.didChangeNotification, object: stopView, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.projectHasUnsavedChanges = true }
        }
        portEditor.onDirty = { [weak self] in Task { @MainActor in self?.projectHasUnsavedChanges = true } }
        processEditor.onDirty = { [weak self] in Task { @MainActor in self?.projectHasUnsavedChanges = true } }
        browserSessionEditor.onDirty = { [weak self] in Task { @MainActor in self?.projectHasUnsavedChanges = true } }
        agentLauncherEditor.onDirty = { [weak self] in Task { @MainActor in self?.projectHasUnsavedChanges = true } }
    }

    private func saveCurrentDetail() -> Bool { saveCurrentProject() }

    private func applySplitViewWidth() {
        guard let splitView else { return }
        isApplyingSplitViewWidth = true
        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition(defaultSplitViewWidth, ofDividerAt: 0)
        Task { @MainActor in
            await Task.yield()
            self.isApplyingSplitViewWidth = false
        }
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        guard !hasAppliedSplitViewWidth else { return }
        hasAppliedSplitViewWidth = true
        applySplitViewWidth()
    }

    private func saveCurrentProject() -> Bool {
        commitEditing()
        guard let selectedProjectID else { return true }
        let tag = selectedProjectID.hashValue
        guard let refs = ProjectFieldCache.shared.cache[tag] else { return true }
        do {
            try orchestrator.updateProjectConfig(projectID: refs.projectID) { config in
                config.setupScript = refs.setupView.string.isEmpty ? nil : refs.setupView.string
                config.stopScript = refs.stopView.string.isEmpty ? nil : refs.stopView.string
                config.ports = refs.portEditor.currentDefinitions()
                config.processes = refs.processEditor.currentProcesses()
                config.browserSessions = refs.browserSessionEditor.currentSessions()
                config.statusChecks = refs.processEditor.currentStatusChecks()
                config.agentLaunchers = refs.agentLauncherEditor.currentLaunchers()
            }
            projectHasUnsavedChanges = false
            reloadData()
            return true
        } catch {
            showError(error)
            return false
        }
    }

    private func unsavedChangesPrompt() -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.messageText = "Unsaved Changes"
        alert.informativeText = "You have unsaved changes. Save before leaving?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal()
    }

    private func commitEditing() {
        let windows = [window, NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
        for window in windows {
            window.endEditing(for: nil)
            _ = window.makeFirstResponder(nil)
        }
    }
}
