import AppKit
import Carbon
import CoreImage
import Foundation
import Sparkle
import spacesclientcore
import spacesdeviceapi
import spacesdevicecore
import spacesterminalcore
import spacesterminalghostty
import spacesterminalui
import systembridge
import workspacecore

private let startupProfileBaselineUptime = ProcessInfo.processInfo.systemUptime

protocol ProcessLifecyclePolicyController {
    func disableAutomaticTermination(_ reason: String)
    func disableSuddenTermination()
}

extension ProcessInfo: ProcessLifecyclePolicyController {}

@MainActor
public final class AppKitController: NSObject, NSApplicationDelegate, NSSplitViewDelegate, NSWindowDelegate, NSTextFieldDelegate,
    NSSearchFieldDelegate, NSComboBoxDelegate, NSTableViewDelegate, NSTableViewDataSource, NSUserInterfaceValidations
{
    static let isRunningUnderXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    enum AlertsIconTint: Sendable, Equatable {
        /// Terminal-origin alerts: an exited process, a session bell.
        case terminal
        /// A coding agent blocked on the human, and a failed automation run.
        case warning
        /// A coding agent that finished its turn.
        case done
    }

    /// Transitional aliases: the alerts model types are owned by `AlertsController`, but a wide set of
    /// consumers (tests, `DeviceSectionContent.swift`, `SidebarRuntimeTargetItem.swift`) still spell them
    /// `AppKitController.AlertsGroup`/`AppKitController.AlertsAttentionEntry`. Kept rather than rewritten
    /// everywhere to avoid disproportionate churn across files that only reference the types, not the
    /// alerts derivation itself.
    typealias AlertsAttentionEntry = AlertsController.AlertsAttentionEntry
    typealias AlertsGroup = AlertsController.AlertsGroup

    /// Transitional aliases for nested-type namespacing during the decomposition: these nested types
    /// moved onto `DeviceModelStore`, but existing `AppKitController.<Type>`-qualified references and
    /// same-file unqualified uses keep compiling unchanged.
    typealias DeviceSection = DeviceModelStore.DeviceSection
    typealias SidebarDataSnapshot = DeviceModelStore.SidebarDataSnapshot
    typealias SidebarDeviceLoadState = DeviceModelStore.SidebarDeviceLoadState

    enum SidebarArrowSelectionTarget: Equatable, Sendable {
        case alerts
        case automations
        case workspace(String)
    }

    enum TerminalQuitDialogChoice: Equatable, Sendable {
        case keepRunning
        case stopAll
        case cancel
    }

    struct HotkeyPerfContext {
        let startedAt: Date
        let appWasActive: Bool
        let appWasHidden: Bool
        let mainWindowWasVisible: Bool
        let paletteWasVisible: Bool
    }

    struct PendingCommandPalettePresentation {
        let perfContext: HotkeyPerfContext?
        let mainWindowWasVisible: Bool
    }

    struct GlobalNavigationWorkspaceResolution: Equatable, Sendable {
        let workspaceID: String?
        let source: String
    }

    var window: NSWindow!
    private var splitView: NSSplitView?
    let outlineView = SidebarOutlineView()
    lazy var sidebar = SidebarController(host: self)
    let detailContainer = NSView()
    /// The right panel's footer strip: workspace details for the selected workspace.
    private weak var workspaceDetailFooterRow: NSStackView?
    private weak var workspaceFooterPaneLabel: NSTextField?
    private var workspaceFooterWorkspaceID: String?
    /// What the footer strip currently shows. Non-nil exactly while the strip holds that workspace's
    /// controls: `clearWorkspaceDetailFooter` is the only path that empties the strip, and it clears this.
    private var renderedWorkspaceFooterSignature: WorkspaceDetailFooterSignature?
    private var workspaceNotesPopover: NSPopover?
    private weak var workspaceNotesEditorTextView: NSTextView?
    private var workspaceNotesEditorWorkspaceID: String?
    // workspaceShortcutFooterLabels removed — footer rebuilt on each refresh
    lazy var deviceModel = DeviceModelStore(
        invalidateVisibleWorkspacesCache: { [unowned self] in self.sidebar.invalidateVisibleWorkspacesCache() },
        resolveAwaitingWorkspaceDeletions: { [unowned self] in self.workspaceDeletion.resolveAwaitingWorkspaceDeletions() })
    /// The single content the detail pane is showing. Mutually exclusive by construction, so presenting
    /// one content replaces the previous one. Written only through `presentDetailPane`.
    var detailPane: DetailPane = .none
    /// Read-only facets of `detailPane` that the app reads throughout. `showingSettings` is a separate
    /// stored flag because the Settings dialog floats over, and coexists with, whatever pane is shown.
    var visibleDetailWorkspaceID: String? { detailPane.workspaceID }
    /// The workspace `showWorkspaceDetail` most recently presented, tracked independently of
    /// `detailPane` because the monitor-follow contract (docs/spec.md: a global-window code pane
    /// "follows the sidebar's workspace selection") must survive detours through non-workspace
    /// details: Alerts/Automations nil out `visibleDetailWorkspaceID`, but they do not change which
    /// workspace the user last selected — so comparing against the visible detail would silently skip
    /// the A → Alerts → B retarget. `nil` only until the first workspace presentation this launch,
    /// preserving the restore-then-follow rule (a reopened monitor stays on its persisted workspace
    /// until a real selection change).
    private var lastPresentedWorkspaceDetailID: String?
    var visibleCompatibilityBlockDeviceID: String? { detailPane.compatibilityBlockDeviceID }
    var showingAlerts: Bool { detailPane.isAlerts }
    var showingAutomations: Bool { detailPane.isAutomations }
    /// The `BlockRemedy` the visible compatibility block was last rendered with, so
    /// `reconcileCompatibilityBlock` can tell "still showing the current guidance" apart from "the
    /// device's wire status moved on and this block is now stale" without re-deriving what was already on
    /// screen. Set in `showCompatibilityBlock`; cleared automatically whenever `presentDetailPane` moves
    /// away from a compatibility block, so it is always `nil` exactly when no block is visible.
    private(set) var visibleCompatibilityBlockRemedy: CompatibilityBlockView.BlockRemedy?

    var selectedProjectID: String? { didSet { overlays.updateOperationProgressOverlayVisibility() } }
    var selectedWorkspaceID: String? { didSet { overlays.updateOperationProgressOverlayVisibility() } }
    var lastSelectedRow: Int = -1
    var suppressOutlineSelectionChanges = false
    var showingSettings = false

    private var mouseFocusMonitor: Any?
    /// The main window's titlebar accessory hosting the visible workspace panel's
    /// tab strip (hidden while the detail area shows anything but a workspace panel).
    let panelTabStripAccessory = NSTitlebarAccessoryViewController()
    let panelTabStripView = PanelTabStripAccessoryView()
    private var mainWindowIsFullScreen = false
    private var deferredHotkeySelectionRefreshTask: Task<Void, Never>?
    private var activeSpaceSummonCleanupTask: Task<Void, Never>?
    private var workspaceSetupDetailRefreshTimer: Timer?
    private var workspaceSetupDetailRefreshWorkspaceID: String?
    private weak var workspaceSetupLogTextView: NSTextView?
    lazy var commandPalette = CommandPaletteController(host: self, deviceModel: deviceModel, alerts: alerts)
    lazy var panelCoordinator: PanelCoordinator = {
        let coordinator = PanelCoordinator(host: self)
        coordinator.onLayoutChanged = { [weak self] scope, layout in self?.persistPanelLayout(scope: scope, layout: layout) }
        return coordinator
    }()
    /// Persisted `panel_windows` rows not yet reopened this launch (nil until first
    /// read). A row stays pending until every device its panes reference has a loaded
    /// overview, so an offline remote's windows return when the device does.
    var pendingPanelWindowRestores: [SpacesClientDatabase.PanelWindowRecord]?
    lazy var alerts = AlertsController(host: self) { [unowned self] in try self.clientDatabase() }
    lazy var shortcuts = ShortcutsController(host: self) { [unowned self] in try self.clientDatabase() }
    lazy var automations = AutomationsController(host: self)
    lazy var automationEditor = AutomationEditorController(host: self)
    lazy var overlays = TransientOverlaysController(host: self)
    lazy var workspaceVisibility = WorkspaceVisibilityController(host: self)
    lazy var settings = SettingsController(host: self)
    lazy var devicePairing = DevicePairingController(
        host: self, pairedDevices: { [unowned self] in self.macPairedDevices() }, database: { [unowned self] in try self.clientDatabase() })
    lazy var daemonUpdate = DaemonUpdateController(
        host: self, requestSidebarReload: { [unowned self] in self.requestSidebarReload(forceRemoteRefresh: true) })
    lazy var workspaceDeletion = WorkspaceDeletionCoordinator(host: self)
    lazy var browserSessions = BrowserSessionCoordinator(host: self)
    lazy var terminalPanes = TerminalPaneService(host: self)
    lazy var projectForms = ProjectFormsController(host: self)
    var workspaceSettingsWindow: NSWindow?
    var workspaceSettingsWorkspaceID: String?
    private lazy var updaterController: SPUStandardUpdaterController? = {
        guard Self.isRunningFromAppBundle else { return nil }
        return SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }()
    /// Distributed IPC notifications observed while the app is running, paired with their `@objc` handlers.
    /// `self` is the observer for every one, so registration and teardown are uniform loops.
    static let distributedIPCObservers: [(name: Notification.Name, selector: Selector)] = [
        (IPCNotification.agentEventFired, #selector(handleAgentEventIPC(_:))),
        (IPCNotification.showMainWindow, #selector(handleShowMainWindowIPC(_:))),
        (IPCNotification.hideMainWindow, #selector(handleHideMainWindowIPC(_:))),
        (IPCNotification.showWindowIssueModal, #selector(handleShowWindowIssueModalIPC(_:))),
        (IPCNotification.cycleWorkspaceWindow, #selector(handleCycleWorkspaceWindowIPC(_:))),
        (IPCNotification.focusWorkspaceWindowByName, #selector(handleFocusWorkspaceWindowByNameIPC(_:))),
        (IPCNotification.focusWorkspaceProcess, #selector(handleFocusWorkspaceProcessIPC(_:))),
        (IPCNotification.dumpFocusableWindowNames, #selector(handleDumpFocusableWindowNamesIPC(_:))),
        (IPCNotification.selectWorkspaceDetail, #selector(handleSelectWorkspaceDetailIPC(_:))),
        (IPCNotification.openWorkspaceTerminal, #selector(handleOpenWorkspaceTerminalIPC(_:))),
        (IPCNotification.openWorkspaceEditor, #selector(handleOpenWorkspaceEditorIPC(_:))),
        (IPCNotification.runWorkspaceProcess, #selector(handleRunWorkspaceProcessIPC(_:))),
        (IPCNotification.stopWorkspaceProcess, #selector(handleStopWorkspaceProcessIPC(_:))),
        (IPCNotification.restartWorkspaceProcess, #selector(handleRestartWorkspaceProcessIPC(_:))),
        (IPCNotification.openTerminalSessionWindow, #selector(handleOpenTerminalSessionWindowIPC(_:))),
        (IPCNotification.closeTerminalSessionWindow, #selector(handleCloseTerminalSessionWindowIPC(_:))),
        (IPCNotification.dumpTerminalSessionWindowState, #selector(handleDumpTerminalSessionWindowStateIPC(_:))),
        (IPCNotification.performTerminalSessionWindowShortcut, #selector(handlePerformTerminalSessionWindowShortcutIPC(_:))),
        (IPCNotification.focusTerminalSessionWindow, #selector(handleFocusTerminalSessionWindowIPC(_:))),
        (IPCNotification.databaseDidChange, #selector(handleDatabaseDidChangeIPC(_:))),
        (TerminalOverviewSignal.name, #selector(handleTerminalOverviewSignalIPC(_:))),
        (IPCNotification.deliverUserNotification, #selector(handleDeliverUserNotificationIPC(_:))),
    ]
    private var appDidBecomeActiveObserver: NSObjectProtocol?
    private var appDidResignActiveObserver: NSObjectProtocol?
    private var workspaceDidTerminateApplicationObserver: NSObjectProtocol?
    private var textInputDidEndEditingObserver: NSObjectProtocol?
    private var appEffectiveAppearanceObservation: NSKeyValueObservation?
    private var didStartBackgroundServices = false
    var setupFlowController: SetupFlowController?
    private var activeWindowShortcutProfile: WindowShortcutProfile?
    private let startupProfileStartTime = startupProfileBaselineUptime
    private var didLogFirstStartupInteraction = false
    private let launchProfile: SpacesProfile
    private let appOwnerLease: SpacesProcessLease
    // Not private: ShortcutsController.setupGlobalHotkey reads this from a different file in the
    // same module (cross-file `private` isn't visible).
    var desktopControlLease: SpacesProcessLease?
    private var passiveDesktopControlOwner: SpacesProcessLeaseOwner?
    private let ipcNotificationObject: String

    private let defaultSplitViewWidth: CGFloat = 360
    private let shortcutLabelColumnWidth: CGFloat = 250
    private var isApplyingSplitViewWidth = false
    private var hasAppliedSplitViewWidth = false
    private var keepsTerminalSessionsRunningDuringTermination = false
    /// AppKit remains alive in `.terminateLater` while Editor panes collect their last JS-owned
    /// workspace state and synchronously drain its queued persistence. A second quit request while
    /// that one is in flight must keep waiting for the same fence rather than starting another close.
    private var isFinalizingEditorStateForTermination = false
    private var appToggleReturnApplicationProcessID: pid_t?
    private var pendingNewTerminalSessionWorkspaceIDs: Set<String> = []

    @discardableResult func beginNewTerminalSessionCreation(workspaceID: String) -> Bool {
        pendingNewTerminalSessionWorkspaceIDs.insert(workspaceID).inserted
    }

    func finishNewTerminalSessionCreation(workspaceID: String) { pendingNewTerminalSessionWorkspaceIDs.remove(workspaceID) }

    private struct WindowShortcutProfile {
        let index: Int
        let startedAt: Date
        var routeCompletedAt: Date?
    }


    private struct TerminalSessionWindowStateDump: Codable {
        let sessionID: String
        let requestedMode: String
        let found: Bool
        let windowTitle: String?
        let rendererSummary: String?
        let renderedOutput: String?
        let visibleSurfaceOutput: String?
        let surfaceSelectionText: String?
        let summary: String?
        let state: String?
        let showsTerminalSurface: Bool?
        let showsTextRenderer: Bool?
        let didClose: Bool?
        let windowNumber: Int?
        let surfaceColumns: Int?
        let surfaceRows: Int?
        let windowIsKey: Bool?
        let firstResponderTypeName: String?
        let searchVisible: Bool?
        let searchQuery: String?
        let searchTotal: Int?
        let searchSelected: Int?
        let attachmentMode: String?
        let takeoverPending: Bool?
        let takeoverButtonVisible: Bool?
        let takeoverButtonEnabled: Bool?
        let takeoverMessage: String?
    }

    private struct WindowFocusResolutionContext {
        let resolution: DeviceWindowShortcutResolution
        let target: WorkspaceRunShortcutTarget?
        let detail: SpacesDeviceWorkspaceDetailViewModel?
    }

    enum WindowFocusRequest: Sendable {
        case workspaceBrowserSession(workspaceID: String, targetURL: String)
        case workspaceWindow(workspaceID: String, index: Int)
        case workspaceProcess(workspaceID: String, processID: String)
        case workspaceMissingConfiguredProcess(workspaceID: String, processKey: String)
        case agentWindow(AgentWindowRecord)
        case terminalSession(workspaceID: String, sessionID: String)

        var workspaceID: String {
            switch self {
            case .workspaceBrowserSession(let workspaceID, _), .workspaceWindow(let workspaceID, _), .workspaceProcess(let workspaceID, _),
                .workspaceMissingConfiguredProcess(let workspaceID, _), .terminalSession(let workspaceID, _):
                return workspaceID
            case .agentWindow(let record): return record.workspaceID
            }
        }

        /// A stable identity for what this request focuses, so a rendered pane's signature can compare
        /// focus targets without the request itself having to be `Equatable` (`agentWindow` carries a
        /// whole record).
        var signatureKey: String {
            switch self {
            case .workspaceBrowserSession(let workspaceID, let targetURL): "browser:\(workspaceID):\(targetURL)"
            case .workspaceWindow(let workspaceID, let index): "window:\(workspaceID):\(index)"
            case .workspaceProcess(let workspaceID, let processID): "process:\(workspaceID):\(processID)"
            case .workspaceMissingConfiguredProcess(let workspaceID, let processKey): "missing-process:\(workspaceID):\(processKey)"
            case .agentWindow(let record): "agent-window:\(record.id)"
            case .terminalSession(let workspaceID, let sessionID): "session:\(workspaceID):\(sessionID)"
            }
        }
    }

    private static let isRunningFromAppBundle = Bundle.main.bundleURL.pathExtension == "app"

    public init(launchContext: SpacesAppLaunchContext) {
        launchProfile = launchContext.profile
        appOwnerLease = launchContext.appOwnerLease
        ipcNotificationObject = launchContext.profile.ipcNotificationObject
        // Bind the active theme before any Theme token or embedded terminal is touched;
        // an unset or unknown stored id resolves to the default theme.
        if let storedThemeID = (try? SpacesClientDatabase.defaultDatabase().setting(key: ClientSettingsKey.appThemeID)) ?? nil {
            ActiveTheme.id = ThemeID(rawValue: storedThemeID)
        }
        switch launchContext.desktopControlState {
        case .active(let lease):
            desktopControlLease = lease
            passiveDesktopControlOwner = nil
        case .passive(let owner):
            desktopControlLease = nil
            passiveDesktopControlOwner = owner
        }
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Self.applyPersistentTerminationPolicy()
        // Apply the stored appearance before any window, menu, or terminal is built so they
        // all render in the chosen light/dark variant from the first frame.
        applyStoredAppAppearance()
        loadStoredTerminalTextSize()
        logStartupProfile(
            "did_finish_launching",
            details:
                "profile_root=\(launchProfile.rootDirectory) runtime_root=\(launchProfile.runtimeDirectory) source=\(launchProfile.source.rawValue) desktop_control=\(desktopControlLease == nil ? "passive" : "active")"
        )
        NSApp.activate(ignoringOtherApps: true)
        logStartupProfile("app_activated")
        buildMainMenu()
        updaterController?.startUpdater()
        logStartupProfile("main_menu_ready")
        shortcuts.loadShortcutSpecs()
        logStartupProfile("shortcut_specs_loaded")
        shortcuts.setupGlobalHotkey()
        logStartupProfile("global_hotkeys_ready", details: "desktop_control=\(desktopControlLease == nil ? "passive" : "active")")
        setupMouseFocusMonitor()
        shortcuts.setupShortcutMonitor()
        logStartupProfile("shortcut_monitor_ready")
        for observer in Self.distributedIPCObservers {
            DistributedNotificationCenter.default().addObserver(
                self, selector: observer.selector, name: observer.name, object: nil, suspensionBehavior: .deliverImmediately)
        }
        setupAppActivationObservers()
        setupWorkspaceApplicationObservers()
        setupTextInputDidEndEditingObserver()
        setupAppEffectiveAppearanceObserver()
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionTerminator(TerminalPaneService.terminateBuiltInTerminalSession)
        logStartupProfile("ipc_observers_ready")
        Self.scheduleAfterNextRunLoopTurn { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.buildShellWindow()
                self.logStartupProfile("shell_window_ready")
                self.enterSetupFlow()
                self.ensureMainWindowVisible()
            }
        }
        prewarmTerminalServiceAfterStartup()
        Task { @MainActor in WorkspaceOrchestrator.prepareUserNotificationAuthorization() }
    }

    nonisolated static func persistentTerminationPolicyReason() -> String {
        "Spaces coordinates long-lived workspace windows, terminal sessions, and paired device clients."
    }

    nonisolated static func applyPersistentTerminationPolicy(processInfo: any ProcessLifecyclePolicyController = ProcessInfo.processInfo) {
        let reason = persistentTerminationPolicyReason()
        processInfo.disableAutomaticTermination(reason)
        processInfo.disableSuddenTermination()
    }

    /// Clicking the Dock icon (or otherwise reopening the app) restores the main window whenever it is
    /// not visible, even if another Spaces window (a panel window) is visible: `hasVisibleWindows` counts
    /// every app window, so relying on it alone would leave the main window hidden behind a visible
    /// panel. When the main window is already visible, AppKit's default reopen handling stands.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard let window, !window.isVisible else { return true }
        ensureMainWindowVisible()
        return false
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isFinalizingEditorStateForTermination { return .terminateLater }
        let liveSessions = TerminalPaneService.liveBuiltInTerminalSessions()
        switch TerminalPaneService.terminalQuitPolicy(liveTerminalSessionCount: liveSessions.count) {
        case .quitImmediately:
            keepsTerminalSessionsRunningDuringTermination = true
            return deferTerminationUntilEditorStateIsDurable(sender)
        case .promptForLiveSessions:
            switch presentTerminalQuitDialog(liveSessionCount: liveSessions.count) {
            case .keepRunning:
                keepsTerminalSessionsRunningDuringTermination = true
                return deferTerminationUntilEditorStateIsDurable(sender)
            case .stopAll:
                keepsTerminalSessionsRunningDuringTermination = false
                let cleanupResult = performStopAllQuitCleanup(liveSessions: liveSessions)
                guard cleanupResult.succeeded else { return handleStopAllQuitCleanupFailure(cleanupResult) }
                return deferTerminationUntilEditorStateIsDurable(sender)
            case .cancel: return .terminateCancel
            }
        }
    }

    private func deferTerminationUntilEditorStateIsDurable(_ application: NSApplication) -> NSApplication.TerminateReply {
        isFinalizingEditorStateForTermination = true
        panelCoordinator.closeAllContentForTermination { [weak self, weak application] in
            // The no-pane case settles synchronously inside `applicationShouldTerminate`; reply on
            // the following main-queue turn so AppKit has observed `.terminateLater` first.
            DispatchQueue.main.async {
                guard let self, let application else { return }
                self.isFinalizingEditorStateForTermination = false
                application.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    public func applicationWillTerminate(_ notification: Notification) {
        deferredHotkeySelectionRefreshTask?.cancel()
        browserSessions.stopAllForwards()
        sidebar.cancelSidebarReloadTask()
        shortcuts.teardownGlobalHotkey()
        shortcuts.teardownShortcutMonitor()
        if let mouseFocusMonitor { NSEvent.removeMonitor(mouseFocusMonitor) }
        DistributedNotificationCenter.default().removeObserver(self)
        if let appDidBecomeActiveObserver {
            NotificationCenter.default.removeObserver(appDidBecomeActiveObserver)
            self.appDidBecomeActiveObserver = nil
        }
        if let appDidResignActiveObserver {
            NotificationCenter.default.removeObserver(appDidResignActiveObserver)
            self.appDidResignActiveObserver = nil
        }
        if let workspaceDidTerminateApplicationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceDidTerminateApplicationObserver)
            self.workspaceDidTerminateApplicationObserver = nil
        }
        if let textInputDidEndEditingObserver {
            NotificationCenter.default.removeObserver(textInputDidEndEditingObserver)
            self.textInputDidEndEditingObserver = nil
        }
        appEffectiveAppearanceObservation?.invalidate()
        appEffectiveAppearanceObservation = nil
        commandPalette.commandPaletteLoadTask?.cancel()
        commandPalette.commandPaletteLoadTask = nil
        commandPalette.commandPalettePanel?.close()
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionLauncher(nil)
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionTerminator(nil)
        releaseLaunchLeases()
    }

    @objc private nonisolated func handleAgentEventIPC(_ notification: Notification) {
        let object = notification.object as? String
        Task { @MainActor [weak self, object] in
            guard let self, self.matchesProfileIPCObject(object) else { return }
            self.reloadData()
        }
    }

    /// Delivers an OS notification the daemon asked for. The daemon detects the
    /// event (e.g. an on-exit `notify` process exit) but cannot post a notification
    /// itself (no app bundle), so the client delivers it.
    @objc private nonisolated func handleDeliverUserNotificationIPC(_ notification: Notification) {
        let object = notification.object as? String
        let userInfo = notification.userInfo as? [String: String]
        Task { @MainActor [weak self, object, userInfo] in
            guard let self, self.matchesProfileIPCObject(object) else { return }
            guard let title = userInfo?[IPCNotification.titleUserInfoKey], let body = userInfo?[IPCNotification.detailUserInfoKey] else { return }
            WorkspaceOrchestrator.deliverUserNotification(
                title: title, body: body, subtitle: userInfo?[IPCNotification.notificationSubtitleUserInfoKey])
        }
    }

    @objc private nonisolated func handleDatabaseDidChangeIPC(_ notification: Notification) {
        let object = notification.object as? String
        Task { @MainActor [weak self, object] in
            guard let self, self.didStartBackgroundServices, self.matchesProfileIPCObject(object) else { return }
            self.sidebar.handleDatabaseDidChange()
        }
    }

    /// Reloads the sidebar when a terminal session's overview-affecting state changes (a bell, an exit,
    /// a title or runtime-state change). Terminal runtime state lives outside the database and so raises
    /// no `databaseDidChange`; this signal refreshes only This Mac's overview while sharing the full
    /// reload path's mid-edit deferral and coalescing. The app and the daemon hosting the session are
    /// separate processes, so the signal arrives here through its distributed half.
    @objc private nonisolated func handleTerminalOverviewSignalIPC(_ notification: Notification) {
        let object = notification.object as? String
        Task { @MainActor [weak self, object] in
            guard let self,
                Self.shouldReloadSidebarForTerminalOverviewSignal(
                    didStartBackgroundServices: self.didStartBackgroundServices, notificationObject: object, profileObject: self.ipcNotificationObject
                )
            else { return }
            self.sidebar.handleTerminalOverviewDidChange()
        }
    }

    @objc private nonisolated func handleShowMainWindowIPC(_ notification: Notification) {
        let object = notification.object as? String
        Task { @MainActor [weak self, object] in
            guard let self, self.matchesProfileIPCObject(object), let window = self.window else { return }
            self.revealTargetedHotkeyWindow(window)
        }
    }

    @objc private nonisolated func handleHideMainWindowIPC(_ notification: Notification) {
        let object = notification.object as? String
        Task { @MainActor [weak self, object] in
            guard let self, self.matchesProfileIPCObject(object), let window = self.window else { return }
            // This IPC is only used by the real-system E2E harness. Hide the
            // entire app process so the setup state is deterministic before
            // profiling external-app -> main-window hotkey flows.
            window.orderOut(nil)
            NSApp.hide(nil)
        }
    }

    @objc private nonisolated func handleShowWindowIssueModalIPC(_ notification: Notification) {
        let object = notification.object as? String
        guard let title = notification.userInfo?[IPCNotification.titleUserInfoKey] as? String else { return }
        guard let detail = notification.userInfo?[IPCNotification.detailUserInfoKey] as? String else { return }
        let outputPath = notification.userInfo?[IPCNotification.outputPathUserInfoKey] as? String
        Task { @MainActor [weak self, object, title, detail, outputPath] in
            guard let self, self.matchesProfileIPCObject(object) else { return }
            if let outputPath { self.writeWindowIssueModalAck(to: outputPath) }
            self.showWindowIssueModal(title: title, detail: detail)
        }
    }

    @objc private nonisolated func handleCycleWorkspaceWindowIPC(_ notification: Notification) {
        let object = notification.object as? String
        guard let workspaceID = notification.userInfo?[IPCNotification.workspaceIDUserInfoKey] as? String else { return }
        guard let direction = notification.userInfo?[IPCNotification.cycleDirectionUserInfoKey] as? String else { return }
        let preferredFocusedBuiltInTerminalSessionID = (notification.userInfo?[IPCNotification.terminalSessionIDUserInfoKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let delta: Int
        switch direction {
        case "next": delta = 1
        case "previous": delta = -1
        default: return
        }
        Task { @MainActor [weak self, object, workspaceID, delta, preferredFocusedBuiltInTerminalSessionID] in
            guard let self, self.matchesProfileIPCObject(object) else { return }
            let preferredTerminalSessionID =
                (preferredFocusedBuiltInTerminalSessionID?.isEmpty == false)
                ? preferredFocusedBuiltInTerminalSessionID : self.focusedBuiltInTerminalSessionIDForGlobalNavigation()
            await self.cycleWorkspaceWindow(workspaceID: workspaceID, delta: delta, preferredTerminalSessionID: preferredTerminalSessionID)
        }
    }

    @objc private nonisolated func handleFocusWorkspaceWindowByNameIPC(_ notification: Notification) {
        let object = notification.object as? String
        guard let workspaceID = notification.userInfo?[IPCNotification.workspaceIDUserInfoKey] as? String else { return }
        guard let name = notification.userInfo?[IPCNotification.workspaceTargetNameUserInfoKey] as? String else { return }
        Task { @MainActor [weak self, object, workspaceID, name] in
            guard let self, self.matchesProfileIPCObject(object) else { return }
            await self.focusWorkspaceWindowByName(workspaceID: workspaceID, name: name)
        }
    }

    @objc private nonisolated func handleFocusWorkspaceProcessIPC(_ notification: Notification) {
        let object = notification.object as? String
        guard let workspaceID = notification.userInfo?[IPCNotification.workspaceIDUserInfoKey] as? String else { return }
        guard let name = notification.userInfo?[IPCNotification.workspaceTargetNameUserInfoKey] as? String else { return }
        let requestID = (notification.userInfo?[IPCNotification.focusRequestIDUserInfoKey] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        Task { @MainActor [weak self, object, workspaceID, name, requestID] in
            guard let self, self.matchesProfileIPCObject(object) else { return }
            await self.focusWorkspaceProcess(workspaceID: workspaceID, processName: name, requestID: (requestID?.isEmpty == false) ? requestID : nil)
        }
    }

    @objc private nonisolated func handleDumpFocusableWindowNamesIPC(_ notification: Notification) {
        let object = notification.object as? String
        guard let workspaceID = notification.userInfo?[IPCNotification.workspaceIDUserInfoKey] as? String else { return }
        guard let outputPath = notification.userInfo?[IPCNotification.outputPathUserInfoKey] as? String else { return }
        Task { @MainActor [weak self, object, workspaceID, outputPath] in
            guard let self, self.matchesProfileIPCObject(object) else { return }
            self.writeFocusableWindowNames(workspaceID: workspaceID, to: outputPath)
        }
    }

    /// A workspace's focusable targets read out of the app's current sidebar snapshot, with the data
    /// needed to name and resolve them.
    typealias FocusableWindowContext = (
        detail: SpacesDeviceWorkspaceDetailViewModel, overview: SpacesDeviceOverviewPayload, browserSessions: [BrowserSession],
        targets: [WorkspaceRunShortcutTarget]
    )

    /// The workspace's focusable targets plus the context needed to name and resolve them,
    /// using the same ordering and (all configured) browser sessions as the numbered
    /// shortcuts so by-name focus, the names dump, and Cmd-N stay consistent.
    func focusableWindowContext(workspaceID: String) -> FocusableWindowContext? {
        guard let overview = overview(forWorkspaceID: workspaceID), let detail = Self.workspaceDetail(workspaceID, in: overview) else { return nil }
        let browserSessions = detail.config.resolvedBrowserSessions.map(Self.localBrowserSession(from:))
        let targets = Self.workspaceShortcutTargets(detail: detail, browserSessions: browserSessions)
        return (detail, overview, browserSessions, targets)
    }

    /// The display name for a focusable target, matching the names the numbered-shortcut
    /// list surfaces (browser session name, process/terminal title, agent label).
    nonisolated static func focusableWindowName(
        for target: WorkspaceRunShortcutTarget, detail: SpacesDeviceWorkspaceDetailViewModel, browserSessions: [BrowserSession]
    ) -> String? {
        switch target.kind {
        case .browser: return BrowserSessionCoordinator.browserSessionDisplayName(for: target.targetURL, sessions: browserSessions)
        case .process: return target.processID.flatMap { id in detail.processRows.first(where: { ($0.processID ?? $0.id) == id })?.name }
        case .window: return target.windowListIndex.flatMap { detail.terminalRows.indices.contains($0) ? detail.terminalRows[$0].title : nil }
        case .agent: return target.agentWindow?.label
        case .missingConfiguredProcess: return target.processKey
        }
    }

    /// The workspace's ordered focusable window names. The app owns this ordering, so the
    /// dump IPC lets harnesses read it instead of recomputing it from daemon data.
    func focusableWindowNames(workspaceID: String) -> [String] {
        guard let context = focusableWindowContext(workspaceID: workspaceID) else { return [] }
        return context.targets.compactMap { Self.focusableWindowName(for: $0, detail: context.detail, browserSessions: context.browserSessions) }
    }

    private struct FocusableWindowNamesDump: Codable { let names: [String] }

    private func writeFocusableWindowNames(workspaceID: String, to outputPath: String) {
        let url = URL(fileURLWithPath: outputPath)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(FocusableWindowNamesDump(names: focusableWindowNames(workspaceID: workspaceID)))
            try data.write(to: url, options: [.atomic])
        } catch {}
    }

    /// Focuses a workspace window by display name through the shared focus path. Emits the
    /// `named_window_focus` perf line the real-system E2E parses (it also satisfies the
    /// browser-focus matcher, since a browser session resolves to the same name).
    private func focusWorkspaceWindowByName(workspaceID: String, name: String) async {
        let startedAt = Date()
        var targetResolutionMS = 0
        var routeMS = 0
        var retriedAfterReload = false
        func logResult(_ success: Bool, reason: String = "") {
            let reasonDetail = reason.isEmpty ? "" : " reason=\(reason)"
            let retryDetail = retriedAfterReload ? " retried_after_reload=1" : ""
            logPerfMetric(
                "named_window_focus", target: name, elapsedMS: windowShortcutElapsedMS(since: startedAt), success: success,
                detail: "target_resolution_ms=\(targetResolutionMS) route_ms=\(routeMS)\(reasonDetail)\(retryDetail)")
        }
        let resolutionStartedAt = Date()
        let resolved = await resolvingAfterFreshSidebarSnapshot { () -> (context: FocusableWindowContext, target: WorkspaceRunShortcutTarget)? in
            guard let context = self.focusableWindowContext(workspaceID: workspaceID),
                let target = context.targets.first(where: {
                    Self.focusableWindowName(for: $0, detail: context.detail, browserSessions: context.browserSessions).map {
                        Self.normalizedRunRowName($0) == Self.normalizedRunRowName(name)
                    } ?? false
                })
            else { return nil }
            return (context, target)
        }
        retriedAfterReload = resolved.retried
        guard let match = resolved.value else {
            targetResolutionMS = windowShortcutElapsedMS(since: resolutionStartedAt)
            logResult(false, reason: "no_match")
            return
        }
        let (context, target) = match
        targetResolutionMS = windowShortcutElapsedMS(since: resolutionStartedAt)
        let resolution = Self.windowShortcutTargetResolution(target, workspaceID: workspaceID, detail: context.detail, overview: context.overview)
        let routeStartedAt = Date()
        guard await executeWindowFocusResolution(resolution, preferredTarget: target, preferredDetail: context.detail) else {
            routeMS = windowShortcutElapsedMS(since: routeStartedAt)
            logResult(false, reason: "focus_failed")
            return
        }
        routeMS = windowShortcutElapsedMS(since: routeStartedAt)
        logResult(true)
    }

    /// Resolves `resolve` against the app's current sidebar snapshot and, when it finds nothing, once
    /// more after the next snapshot lands.
    ///
    /// A focus or open request can arrive in the window between the daemon writing a just-started
    /// process (or a just-created workspace) and the app's paced reload applying the snapshot that
    /// carries it. In that window a miss says nothing about whether the target exists, so the request
    /// waits for the app to catch up instead of being refused. Exactly one fresh snapshot and exactly
    /// one retry: the second answer is about the target, not about the app being behind.
    ///
    /// - Returns: what the resolution found, and whether it took the retry, which the caller's log line
    ///   reports so a stale snapshot can be told from a genuinely missing target.
    private func resolvingAfterFreshSidebarSnapshot<T>(_ resolve: @MainActor () -> T?) async -> (value: T?, retried: Bool) {
        if let value = resolve() { return (value, false) }
        await sidebar.reloadAwaitingFreshSnapshot()
        return (resolve(), true)
    }

    /// The focusable target for a workspace's running process, by template name, waiting once for a
    /// fresh sidebar snapshot when the current one has no running row for that name yet (it lists the
    /// process as a `.missingConfiguredProcess` target until the reload carrying the row lands).
    func processFocusMatch(workspaceID: String, processName: String) async -> (
        value: (context: FocusableWindowContext, target: WorkspaceRunShortcutTarget)?, retried: Bool
    ) {
        await resolvingAfterFreshSidebarSnapshot { () -> (context: FocusableWindowContext, target: WorkspaceRunShortcutTarget)? in
            guard let context = self.focusableWindowContext(workspaceID: workspaceID),
                let target = context.targets.first(where: { target in
                    guard target.kind == .process, let id = target.processID,
                        let rowName = context.detail.processRows.first(where: { ($0.processID ?? $0.id) == id })?.name
                    else { return false }
                    return Self.normalizedRunRowName(rowName) == Self.normalizedRunRowName(processName)
                })
            else { return nil }
            return (context, target)
        }
    }

    /// Focuses a workspace's running process window by template name. Threads `requestID`
    /// to the terminal focus so the `terminal_window_focus_ipc` line carries it, which the
    /// real-system E2E correlates; also emits `process_focus` for the non-correlated path.
    private func focusWorkspaceProcess(workspaceID: String, processName: String, requestID: String?) async {
        let startedAt = Date()
        var targetResolutionMS = 0
        var routeMS = 0
        var retriedAfterReload = false
        func logResult(_ success: Bool, reason: String = "") {
            let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
            let reasonDetail = reason.isEmpty ? "" : " reason=\(reason)"
            let retryDetail = retriedAfterReload ? " retried_after_reload=1" : ""
            logPerfMetric(
                "process_focus", target: processName, elapsedMS: windowShortcutElapsedMS(since: startedAt), success: success,
                detail: "target_resolution_ms=\(targetResolutionMS) route_ms=\(routeMS)\(requestDetail)\(reasonDetail)\(retryDetail)")
        }
        let resolutionStartedAt = Date()
        let resolved = await processFocusMatch(workspaceID: workspaceID, processName: processName)
        retriedAfterReload = resolved.retried
        guard let match = resolved.value else {
            targetResolutionMS = windowShortcutElapsedMS(since: resolutionStartedAt)
            logResult(false, reason: "no_match")
            return
        }
        let (context, target) = match
        targetResolutionMS = windowShortcutElapsedMS(since: resolutionStartedAt)
        let resolution = Self.windowShortcutTargetResolution(target, workspaceID: workspaceID, detail: context.detail, overview: context.overview)
        let routeStartedAt = Date()
        guard await executeWindowFocusResolution(resolution, requestID: requestID, preferredTarget: target, preferredDetail: context.detail) else {
            routeMS = windowShortcutElapsedMS(since: routeStartedAt)
            logResult(false, reason: "focus_failed")
            return
        }
        routeMS = windowShortcutElapsedMS(since: routeStartedAt)
        logResult(true)
    }

    // In-memory window-cycle state (a "window" is a client concept). The cursor remembers
    // the last-focused target per workspace, recent cursors provide MRU ordering at the
    // start of a cycle burst, and the cycle session preserves that burst's rotation order
    // across rapid presses. MainActor-isolated, so no lock is needed.
    private static let maxWindowNavigationRecentCursorCount = 128
    private var windowNavigationCursorByWorkspace: [String: WorkspaceWindowCycle.Cursor] = [:]
    private var windowNavigationRecentCursorsByWorkspace: [String: [WorkspaceWindowCycle.Cursor]] = [:]
    private var windowNavigationCycleSessionByWorkspace: [String: WorkspaceWindowCycle.CycleSession] = [:]

    /// Cycles focus to the next/previous window of a workspace, entirely client-side:
    /// rebuilds the focusable targets from the workspace's overview, resolves the current
    /// target from the focused terminal session / frontmost Chrome tab / remembered
    /// cursor, advances, and focuses through the shared `executeWindowFocusResolution`.
    private func cycleWorkspaceWindow(workspaceID: String, delta: Int, preferredTerminalSessionID: String?, requestID: String? = nil) async {
        let cycleStartedAt = Date()
        let direction = delta > 0 ? "next" : "previous"
        // The real-system E2E waits for this `window_cycle` perf line, so emit it on both
        // success and failure (matching the orchestrator's format) — it is a parsed surface.
        func logCycleMetric(target: String, success: Bool, detail extraDetail: String = "") {
            let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
            let suffix = extraDetail.isEmpty ? "" : " \(extraDetail)"
            TerminalPerformance.logWorkspaceMetric(
                "window_cycle", workspaceID: workspaceID, target: target, elapsedMS: windowShortcutElapsedMS(since: cycleStartedAt), success: success,
                detail: "direction=\(direction)\(requestDetail)\(suffix)")
        }
        guard let overview = overview(forWorkspaceID: workspaceID), let detail = Self.workspaceDetail(workspaceID, in: overview) else {
            logCycleMetric(target: "none", success: false)
            return
        }
        let cycleSession = validCycleSession(workspaceID: workspaceID)
        let targetResolutionStartedAt = Date()
        let browserCycleState = await browserSessions.trackedBrowserCycleState(workspaceID: workspaceID, detail: detail)
        let openTerminalSessionIDs = Set(panelCoordinator.openTerminalSessionIDs(workspaceID: workspaceID))

        // Cycle over the same base targets the numbered shortcuts use, limited to running
        // windows (open browsers, running processes/terminals, agents) and ordered by MRU
        // at the start of the burst — not launch actions.
        let targets = Self.cycleWindowTargets(
            detail: detail, browserSessions: browserCycleState.openBrowserSessions, openTerminalSessionIDs: openTerminalSessionIDs)
        let targetResolutionMS = windowShortcutElapsedMS(since: targetResolutionStartedAt)
        let resolutionDetail =
            "target_resolution_ms=\(targetResolutionMS) client_db_lookup_ms=\(browserCycleState.clientDBLookupMS) chrome_applescript_ms=\(browserCycleState.chromeAppleScriptMS) tracked_browser_windows=\(browserCycleState.trackedWindowCount) tracked_browser_tabs=\(browserCycleState.trackedTabCount) open_terminal_panes=\(openTerminalSessionIDs.count)"
        guard !targets.isEmpty else {
            logCycleMetric(target: "none", success: false, detail: resolutionDetail)
            return
        }

        let cursorKeys = targets.map { Self.cycleCursorKey(for: $0, detail: detail) }
        let cursor = windowNavigationCursorByWorkspace[workspaceID]
        let frontmostBrowserURL = (preferredTerminalSessionID?.isEmpty == false) ? nil : browserCycleState.frontmostURL
        let configuredBrowserTargetURLs = BrowserSessionCoordinator.browserSessionTargetURLs(resolvedSessions: detail.config.resolvedBrowserSessions)
        let currentIndex = Self.cycleCurrentIndex(
            targets: targets, detail: detail, focusedTerminalSessionID: preferredTerminalSessionID, frontmostBrowserURL: frontmostBrowserURL,
            browserTargetURLs: configuredBrowserTargetURLs, cursorKeys: cursorKeys, cursor: cursor)
        if let currentIndex { rememberWindowNavigationCursor(cursorKeys[currentIndex], workspaceID: workspaceID, preserveWindowCycleSession: true) }
        let ordering = WorkspaceWindowCycle.cycleOrdering(
            cursors: cursorKeys, currentIndex: currentIndex, session: cycleSession,
            recentCursors: windowNavigationRecentCursorsByWorkspace[workspaceID] ?? [])
        let orderedTargets = ordering.indices.map { targets[$0] }
        let orderedCursors = ordering.indices.map { cursorKeys[$0] }
        guard !orderedTargets.isEmpty else {
            logCycleMetric(target: "none", success: false, detail: resolutionDetail)
            return
        }
        let startIndex = WorkspaceWindowCycle.nextIndex(orderedCount: orderedTargets.count, orderedCurrentIndex: ordering.currentIndex, delta: delta)

        // Cycling closes the palette for every target it can land on, browser sessions included,
        // because the palette is a transient panel over whatever the cycle is navigating to. It
        // closes before the focus work rather than after: focusing a browser activates Chrome, and
        // an open palette resigning key to Chrome mid-await would run the ordinary dismissal, whose
        // return-focus restore would take the front straight back from the app just focused.
        commandPalette.dismissCommandPaletteForBuiltInWindowNavigation()

        var didFocus = false
        var resolvedIndex = startIndex
        for attempt in 0..<orderedTargets.count {
            let candidateIndex = (startIndex + (attempt * delta) + (orderedTargets.count * 4)) % orderedTargets.count
            let resolution = Self.windowShortcutTargetResolution(
                orderedTargets[candidateIndex], workspaceID: workspaceID, detail: detail, overview: overview)
            if await executeWindowFocusResolution(
                resolution, requestID: requestID, preferredTarget: orderedTargets[candidateIndex], preferredDetail: detail,
                preserveWindowCycleSession: true)
            {
                didFocus = true
                resolvedIndex = candidateIndex
                break
            }
        }
        guard didFocus else {
            logCycleMetric(target: Self.cycleDebugName(for: orderedTargets[startIndex], detail: detail), success: false, detail: resolutionDetail)
            return
        }

        windowNavigationCursorByWorkspace[workspaceID] = orderedCursors[resolvedIndex]
        windowNavigationCycleSessionByWorkspace[workspaceID] = WorkspaceWindowCycle.CycleSession(
            orderedCursors: orderedCursors, currentIndex: resolvedIndex, lastUsedAt: Date())
        logCycleMetric(target: Self.cycleDebugName(for: orderedTargets[resolvedIndex], detail: detail), success: true, detail: resolutionDetail)
    }

    nonisolated static func cycleWindowTargets(
        detail: SpacesDeviceWorkspaceDetailViewModel, browserSessions: [BrowserSession], openTerminalSessionIDs: Set<String>
    ) -> [WorkspaceRunShortcutTarget] {
        workspaceShortcutTargets(detail: detail, browserSessions: browserSessions).filter { target in
            switch target.kind {
            case .browser: return true
            case .process, .window, .agent:
                guard let sessionID = cycleTargetSessionID(for: target, detail: detail), !sessionID.isEmpty else { return false }
                return openTerminalSessionIDs.contains(sessionID)
            case .missingConfiguredProcess: return false
            }
        }
    }

    private func validCycleSession(workspaceID: String) -> WorkspaceWindowCycle.CycleSession? {
        guard let session = windowNavigationCycleSessionByWorkspace[workspaceID] else { return nil }
        guard Date().timeIntervalSince(session.lastUsedAt) <= WorkspaceWindowCycle.cycleSessionTimeout else {
            windowNavigationCycleSessionByWorkspace.removeValue(forKey: workspaceID)
            return nil
        }
        return session
    }

    /// Stable per-target identity used to remember the cursor and preserve cycle order.
    nonisolated static func cycleCursorKey(for target: WorkspaceRunShortcutTarget, detail: SpacesDeviceWorkspaceDetailViewModel) -> String {
        switch target.kind {
        case .browser: return "browser:\(target.targetURL ?? "")"
        case .process: return "process:\(target.processID ?? "")"
        case .window: return "terminal:\(cycleTargetSessionID(for: target, detail: detail) ?? String(target.windowListIndex ?? -1))"
        case .agent: return "agent:\(target.agentWindow?.id ?? "")"
        case .missingConfiguredProcess: return "missing:\(target.processKey ?? "")"
        }
    }

    nonisolated private static func cycleTargetSessionID(for target: WorkspaceRunShortcutTarget, detail: SpacesDeviceWorkspaceDetailViewModel)
        -> String?
    {
        switch target.kind {
        case .process: return detail.processRows.first(where: { ($0.processID ?? $0.id) == target.processID })?.sessionID
        case .window:
            guard let index = target.windowListIndex, detail.terminalRows.indices.contains(index) else { return nil }
            return detail.terminalRows[index].sessionID
        case .agent: return detail.codingAgentRows.first(where: { ($0.agentID ?? $0.id) == target.agentWindow?.id })?.sessionID
        case .browser, .missingConfiguredProcess: return nil
        }
    }

    private func rememberWindowNavigationFocus(
        resolution: DeviceWindowShortcutResolution, preferredTarget: WorkspaceRunShortcutTarget? = nil,
        preferredDetail: SpacesDeviceWorkspaceDetailViewModel? = nil, preserveWindowCycleSession: Bool = false
    ) {
        guard let workspaceID = Self.workspaceID(for: resolution) else { return }
        if let preferredTarget {
            let detail = preferredDetail ?? focusableWindowContext(workspaceID: workspaceID)?.detail
            if let detail,
                rememberWindowNavigationTargetIfCycleable(
                    preferredTarget, workspaceID: workspaceID, detail: detail, preserveWindowCycleSession: preserveWindowCycleSession)
            {
                return
            }
        }

        switch resolution {
        case .openURL(_, let targetURL):
            guard !targetURL.isEmpty else { return }
            rememberWindowNavigationCursor("browser:\(targetURL)", workspaceID: workspaceID, preserveWindowCycleSession: preserveWindowCycleSession)
        case .openTerminal(let request):
            rememberWindowNavigationTerminalSession(
                workspaceID: request.workspaceID, sessionID: request.sessionID, preserveWindowCycleSession: preserveWindowCycleSession)
        case .runProcess(_, let processKey, _):
            rememberWindowNavigationProcess(workspaceID: workspaceID, processKey: processKey, preserveWindowCycleSession: preserveWindowCycleSession)
        case .noWorkspace, .noMatch: return
        }
    }

    @discardableResult private func rememberWindowNavigationTargetIfCycleable(
        _ target: WorkspaceRunShortcutTarget, workspaceID: String, detail: SpacesDeviceWorkspaceDetailViewModel, preserveWindowCycleSession: Bool
    ) -> Bool {
        switch target.kind {
        case .browser: guard target.targetURL?.isEmpty == false else { return false }
        case .process, .window, .agent: guard Self.cycleTargetSessionID(for: target, detail: detail)?.isEmpty == false else { return false }
        case .missingConfiguredProcess: return false
        }
        rememberWindowNavigationCursor(
            Self.cycleCursorKey(for: target, detail: detail), workspaceID: workspaceID, preserveWindowCycleSession: preserveWindowCycleSession)
        return true
    }

    private func rememberWindowNavigationTerminalSession(workspaceID: String, sessionID: String, preserveWindowCycleSession: Bool) {
        guard !sessionID.isEmpty, let context = focusableWindowContext(workspaceID: workspaceID) else { return }
        let matches = context.targets.filter { Self.cycleTargetSessionID(for: $0, detail: context.detail) == sessionID }
        guard !matches.isEmpty else { return }
        let currentCursor = windowNavigationCursorByWorkspace[workspaceID]
        if let currentCursor, let target = matches.first(where: { Self.cycleCursorKey(for: $0, detail: context.detail) == currentCursor }),
            rememberWindowNavigationTargetIfCycleable(
                target, workspaceID: workspaceID, detail: context.detail, preserveWindowCycleSession: preserveWindowCycleSession)
        {
            return
        }
        let recentCursors = windowNavigationRecentCursorsByWorkspace[workspaceID] ?? []
        for cursor in recentCursors {
            if let target = matches.first(where: { Self.cycleCursorKey(for: $0, detail: context.detail) == cursor }),
                rememberWindowNavigationTargetIfCycleable(
                    target, workspaceID: workspaceID, detail: context.detail, preserveWindowCycleSession: preserveWindowCycleSession)
            {
                return
            }
        }
        if let target = matches.last {
            rememberWindowNavigationTargetIfCycleable(
                target, workspaceID: workspaceID, detail: context.detail, preserveWindowCycleSession: preserveWindowCycleSession)
        }
    }

    func noteWindowNavigationTerminalFocus(sessionID: String) {
        guard let workspaceID = clientWorkspaceID(forTerminalSession: sessionID) else { return }
        rememberWindowNavigationTerminalSession(workspaceID: workspaceID, sessionID: sessionID, preserveWindowCycleSession: false)
    }

    private func rememberWindowNavigationProcess(workspaceID: String, processKey: String, preserveWindowCycleSession: Bool) {
        guard let context = focusableWindowContext(workspaceID: workspaceID) else { return }
        let target = context.targets.first { target in
            guard target.kind == .process, let processID = target.processID,
                let row = context.detail.processRows.first(where: { ($0.processID ?? $0.id) == processID })
            else { return false }
            return Self.normalizedRunRowName(row.name) == Self.normalizedRunRowName(processKey)
        }
        if let target {
            rememberWindowNavigationTargetIfCycleable(
                target, workspaceID: workspaceID, detail: context.detail, preserveWindowCycleSession: preserveWindowCycleSession)
        }
    }

    private func rememberWindowNavigationCursor(_ cursor: WorkspaceWindowCycle.Cursor, workspaceID: String, preserveWindowCycleSession: Bool) {
        guard !cursor.isEmpty else { return }
        windowNavigationCursorByWorkspace[workspaceID] = cursor
        var cursors = windowNavigationRecentCursorsByWorkspace[workspaceID] ?? []
        cursors.removeAll { $0 == cursor }
        cursors.insert(cursor, at: 0)
        if cursors.count > Self.maxWindowNavigationRecentCursorCount { cursors.removeLast(cursors.count - Self.maxWindowNavigationRecentCursorCount) }
        windowNavigationRecentCursorsByWorkspace[workspaceID] = cursors
        if !preserveWindowCycleSession { windowNavigationCycleSessionByWorkspace.removeValue(forKey: workspaceID) }
    }

    nonisolated private static func workspaceID(for resolution: DeviceWindowShortcutResolution) -> String? {
        switch resolution {
        case .openURL(let workspaceID, _), .runProcess(let workspaceID, _, _): return workspaceID
        case .openTerminal(let request): return request.workspaceID
        case .noWorkspace, .noMatch: return nil
        }
    }

    /// Short name for a target, used in the `window_cycle` perf line the E2E parses; matches
    /// the orchestrator's `kind:name` shape (e.g. `process:web`, `terminal:shell`).
    nonisolated private static func cycleDebugName(for target: WorkspaceRunShortcutTarget, detail: SpacesDeviceWorkspaceDetailViewModel) -> String {
        switch target.kind {
        case .browser: return "browser:\(target.targetURL ?? "")"
        case .process:
            let name = target.processID.flatMap { id in detail.processRows.first(where: { ($0.processID ?? $0.id) == id })?.name }
            return "process:\(name ?? target.processID ?? "")"
        case .window:
            let title = target.windowListIndex.flatMap { detail.terminalRows.indices.contains($0) ? detail.terminalRows[$0].title : nil }
            return "terminal:\(title ?? "")"
        case .agent: return "agent:\(target.agentWindow?.effectiveLabel ?? target.agentWindow?.id ?? "")"
        case .missingConfiguredProcess: return "process:\(target.processKey ?? "")"
        }
    }

    nonisolated private static func cycleCurrentIndex(
        targets: [WorkspaceRunShortcutTarget], detail: SpacesDeviceWorkspaceDetailViewModel, focusedTerminalSessionID: String?,
        frontmostBrowserURL: String?, browserTargetURLs: [String], cursorKeys: [String], cursor: String?
    ) -> Int? {
        if let focusedTerminalSessionID, !focusedTerminalSessionID.isEmpty {
            let matches = targets.indices.filter { cycleTargetSessionID(for: targets[$0], detail: detail) == focusedTerminalSessionID }
            if !matches.isEmpty {
                if let cursor, let match = matches.first(where: { cursorKeys[$0] == cursor }) { return match }
                return matches.last
            }
        }
        if let frontmostBrowserURL, !frontmostBrowserURL.isEmpty {
            let matches = targets.indices.compactMap { index -> (offset: Int, matchLength: Int)? in
                guard targets[index].kind == .browser, let targetURL = targets[index].targetURL, !targetURL.isEmpty else { return nil }
                let siblingTargetURLs = BrowserSessionCoordinator.browserSessionSiblingTargetURLs(targetURL: targetURL, targetURLs: browserTargetURLs)
                guard
                    let matchLength = BrowserSessionCoordinator.browserObservedURLMatchLength(
                        frontmostBrowserURL, targetURL: targetURL, siblingTargetURLs: siblingTargetURLs, assignedPorts: detail.assignedPorts)
                else { return nil }
                return (index, matchLength)
            }
            if !matches.isEmpty {
                if let cursor, let match = matches.first(where: { cursorKeys[$0.offset] == cursor }) { return match.offset }
                return matches.max(by: { $0.matchLength < $1.matchLength })?.offset
            }
        }
        if let cursor { return cursorKeys.firstIndex(of: cursor) }
        return nil
    }

    @objc private nonisolated func handleSelectWorkspaceDetailIPC(_ notification: Notification) {
        let object = notification.object as? String
        guard let workspaceID = notification.userInfo?[IPCNotification.workspaceIDUserInfoKey] as? String else { return }
        Task { @MainActor [weak self, object, workspaceID] in
            guard let self, self.matchesProfileIPCObject(object) else { return }
            guard let (_, workspace) = self.findWorkspace(id: workspaceID) else {
                self.logWorkspaceDetailIPC("workspace_not_found id=\(workspaceID)")
                return
            }
            self.logWorkspaceDetailIPC("selecting id=\(workspaceID) title=\(workspace.displayName)")
            // Drop a full-pane alerts view so the selection below resolves to the workspace instead of
            // `refreshSelection` bouncing back to alerts; a shown workspace/compatibility pane is untouched.
            // Left as a background presentation: this only clears the way, and the selection it makes
            // room for is what carries the navigation — `selectWorkspace` lands on the outline row whose
            // selection change presents the workspace pane as `.userNavigation`.
            if case .alerts = self.detailPane { self.presentDetailPane(.none) }
            self.showingSettings = false
            self.selectWorkspace(workspace)
            self.refreshSelection()
            if let window = self.window { self.revealTargetedHotkeyWindow(window) }
            self.logWorkspaceDetailIPC("selected id=\(workspaceID) title=\(workspace.displayName)")
        }
    }

    @objc private nonisolated func handleOpenWorkspaceTerminalIPC(_ notification: Notification) {
        let object = notification.object as? String
        guard let workspaceID = notification.userInfo?[IPCNotification.workspaceIDUserInfoKey] as? String else { return }
        Task { @MainActor [weak self, object, workspaceID] in
            guard let self, self.matchesProfileIPCObject(object) else { return }
            self.openWorkspaceTerminal(workspaceID: workspaceID, route: .ipc)
        }
    }

    @objc private nonisolated func handleOpenWorkspaceEditorIPC(_ notification: Notification) {
        let object = notification.object as? String
        guard let workspaceID = notification.userInfo?[IPCNotification.workspaceIDUserInfoKey] as? String else { return }
        Task { @MainActor [weak self, object, workspaceID] in
            guard let self, self.matchesProfileIPCObject(object) else { return }
            self.openWorkspaceEditor(workspaceID: workspaceID)
        }
    }

    @objc private nonisolated func handleRunWorkspaceProcessIPC(_ notification: Notification) {
        let object = notification.object as? String
        guard let workspaceID = notification.userInfo?[IPCNotification.workspaceIDUserInfoKey] as? String else { return }
        guard let processName = notification.userInfo?[IPCNotification.workspaceTargetNameUserInfoKey] as? String else { return }
        Task { @MainActor [weak self, object, workspaceID, processName] in
            guard let self, self.matchesProfileIPCObject(object) else { return }
            self.runWorkspaceProcess(workspaceID: workspaceID, processName: processName)
        }
    }

    @objc private nonisolated func handleStopWorkspaceProcessIPC(_ notification: Notification) {
        let object = notification.object as? String
        guard let workspaceID = notification.userInfo?[IPCNotification.workspaceIDUserInfoKey] as? String else { return }
        guard let processName = notification.userInfo?[IPCNotification.workspaceTargetNameUserInfoKey] as? String else { return }
        Task { @MainActor [weak self, object, workspaceID, processName] in
            guard let self, self.matchesProfileIPCObject(object) else { return }
            self.stopWorkspaceProcess(workspaceID: workspaceID, processName: processName)
        }
    }

    @objc private nonisolated func handleRestartWorkspaceProcessIPC(_ notification: Notification) {
        let object = notification.object as? String
        guard let workspaceID = notification.userInfo?[IPCNotification.workspaceIDUserInfoKey] as? String else { return }
        guard let processName = notification.userInfo?[IPCNotification.workspaceTargetNameUserInfoKey] as? String else { return }
        Task { @MainActor [weak self, object, workspaceID, processName] in
            guard let self, self.matchesProfileIPCObject(object) else { return }
            self.restartWorkspaceProcess(workspaceID: workspaceID, processName: processName)
        }
    }

    @objc private nonisolated func handleOpenTerminalSessionWindowIPC(_ notification: Notification) {
        let object = notification.object as? String
        guard let sessionID = notification.userInfo?[IPCNotification.terminalSessionIDUserInfoKey] as? String else { return }
        guard
            let focusIntent = TerminalPaneService.terminalOpenFocusIntent(
                ipcRawValue: notification.userInfo?[IPCNotification.terminalOpenFocusIntentUserInfoKey] as? String)
        else { return }
        let modeRawValue = notification.userInfo?[IPCNotification.terminalAttachmentModeUserInfoKey] as? String
        let mode = modeRawValue.flatMap(TerminalAttachmentMode.init(rawValue:)) ?? .owner
        let openIntent = TerminalPaneOpenIntent(
            focus: focusIntent,
            replacesSessionID: Self.trimmedNonEmpty(notification.userInfo?[IPCNotification.terminalOpenReplacesSessionIDUserInfoKey] as? String))
        let requestID = notification.userInfo?[IPCNotification.focusRequestIDUserInfoKey] as? String
        Task { @MainActor [weak self, object, sessionID, mode, openIntent, requestID] in
            guard let self else { return }
            guard self.matchesProfileIPCObject(object) else { return }
            TerminalPerformance.logMetric(
                "terminal_window_open_ipc", target: "session=\(sessionID)", elapsedMS: 0, success: true,
                detail:
                    "mode=\(mode.rawValue) focus=\(openIntent.focus.rawValue) replaces=\(openIntent.replacesSessionID ?? "-")\(requestID.map { " request_id=\($0)" } ?? "")"
            )
            await self.openTerminalSessionPane(sessionID: sessionID, mode: mode, openIntent: openIntent, requestID: requestID)
        }
    }

    // MARK: - Spaces URL scheme (`spaces://`)

    /// System entry point for the registered `spaces` URL scheme (declared in `CFBundleURLTypes`).
    /// Terminal deep links focus a session; a pairing link (iOS-only flow) is redirected loudly
    /// instead of being silently dropped; anything else is an unrecognized link.
    public func application(_ application: NSApplication, open urls: [URL]) { for url in urls { handleIncomingSpacesURL(url) } }

    private func handleIncomingSpacesURL(_ url: URL) {
        if let link = SpacesTerminalDeepLink.parse(url) {
            handleTerminalDeepLink(link)
            return
        }
        if url.scheme == SpacesDevicePairingLink.scheme, url.host == SpacesDevicePairingLink.host {
            presentSpacesLinkAlert(
                title: "Pair from your phone",
                message: "Pairing links open in the Spaces app on your iPhone or iPad, not on this Mac. Scan or tap the link there to pair a device.")
            return
        }
        presentSpacesLinkAlert(title: "Unrecognized Spaces link", message: "Spaces didn't recognize “\(url.absoluteString)”.")
    }

    /// Where a `spaces://terminal/…` deep link's session lives. A link with no `device` (or the local
    /// device id) is `local`; any other paired device id is `remote`. The classification is a pure
    /// function of the link so it can be exercised without an AppKitController instance.
    enum TerminalDeepLinkTarget: Equatable {
        case local(sessionID: String)
        case remote(sessionID: String, deviceID: String)
    }

    nonisolated static func terminalDeepLinkTarget(for link: SpacesTerminalDeepLink) -> TerminalDeepLinkTarget {
        if let deviceID = link.deviceID, deviceID != SpacesPairedDeviceRecord.localDeviceID {
            return .remote(sessionID: link.sessionID, deviceID: deviceID)
        }
        return .local(sessionID: link.sessionID)
    }

    /// Focuses the terminal session named by a `spaces://terminal/…` deep link. Shared by the OS URL
    /// handler and in-terminal `spaces://` clicks so both take one path. A link with no `device` (or
    /// the local device id) opens the pane here on the exact route `terminal show` uses (owner mode);
    /// a device-qualified link for another paired device opens that session's remote-attached pane on
    /// the same path a sidebar/window open takes. An unknown session is surfaced loudly.
    func handleTerminalDeepLink(_ link: SpacesTerminalDeepLink) {
        switch Self.terminalDeepLinkTarget(for: link) {
        case .local(let sessionID):
            let focusRequestID = UUID().uuidString
            Task { @MainActor [weak self] in
                guard let self else { return }
                let opened = await self.openTerminalSessionPane(sessionID: sessionID, mode: .owner, openIntent: .focused, requestID: focusRequestID)
                if !opened { self.presentTerminalDeepLinkUnknownSessionAlert(sessionID: sessionID) }
            }
        case .remote(let sessionID, let deviceID): openRemoteTerminalDeepLink(sessionID: sessionID, deviceID: deviceID)
        }
    }

    /// Opens (or focuses) a device-qualified deep link's session on its paired remote device, reusing
    /// the same remote-attached pane path a sidebar or window open takes. Resolves the paired device
    /// record, then the session on that device (its loaded overview first, else a Device API overview
    /// query), and opens the pane with the session's owning device pinned so it attaches remotely. An
    /// unpaired/unreachable device or a session the device doesn't have surfaces a loud, specific alert.
    private func openRemoteTerminalDeepLink(sessionID: String, deviceID: String) {
        guard let device = deviceForMutation(deviceID: deviceID) else {
            presentTerminalDeepLinkUnknownDeviceAlert(deviceID: deviceID)
            return
        }
        let focusRequestID = UUID().uuidString
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let match = await self.resolveRemoteTerminalSessionMatch(sessionID: sessionID, device: device) else {
                self.presentTerminalDeepLinkRemoteSessionNotFoundAlert(sessionID: sessionID, deviceName: device.name)
                return
            }
            let opened = await self.openTerminalSessionPane(
                sessionID: sessionID, mode: .owner, openIntent: .focused, requestID: focusRequestID,
                resolvedRequest: TerminalPaneService.terminalSessionPaneOpenRequest(from: match))
            if !opened { self.presentTerminalDeepLinkRemoteSessionNotFoundAlert(sessionID: sessionID, deviceName: device.name) }
        }
    }

    /// Resolves a session's overview summary on a specific paired device: the device's loaded overview
    /// when it already carries the session, otherwise a fresh off-main Device API overview query (the
    /// same seam the cold local resolve uses). Returns nil when that device has no such session.
    private func resolveRemoteTerminalSessionMatch(sessionID: String, device: SpacesPairedDeviceRecord) async -> TerminalSessionSummaryMatch? {
        if let summary = deviceSection(id: device.id)?.overview?.sessions.first(where: { $0.id == sessionID }) {
            return TerminalSessionSummaryMatch(device: device, summary: summary)
        }
        let clientApp = SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)
        return await Self.resolveSessionSummaryMatchOffMain(sessionID: sessionID, device: device, clientApp: clientApp)
    }

    private func presentTerminalDeepLinkUnknownDeviceAlert(deviceID: String) {
        if let pairedDevice = try? clientDatabase().pairedDevice(id: deviceID) {
            presentSpacesLinkAlert(
                title: "Device unavailable",
                message: "Spaces can't reach “\(pairedDevice.name)” right now. Make sure it's connected, then open the link again.")
        } else {
            presentSpacesLinkAlert(title: "Unknown device", message: "This link points to a device (\(deviceID)) that isn't paired with this Mac.")
        }
    }

    private func presentTerminalDeepLinkRemoteSessionNotFoundAlert(sessionID: String, deviceName: String) {
        presentSpacesLinkAlert(
            title: "Terminal session not found",
            message: "Spaces couldn't find a terminal session with id “\(sessionID)” on “\(deviceName)”. It may have already exited.")
    }

    private func presentTerminalDeepLinkUnknownSessionAlert(sessionID: String) {
        presentSpacesLinkAlert(
            title: "Terminal session not found",
            message: "Spaces couldn't find a terminal session with id “\(sessionID)” on this Mac. It may have already exited.")
    }

    private func presentSpacesLinkAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private nonisolated func handleCloseTerminalSessionWindowIPC(_ notification: Notification) {
        let object = notification.object as? String
        guard let sessionID = notification.userInfo?[IPCNotification.terminalSessionIDUserInfoKey] as? String else { return }
        guard
            let disposition = TerminalPaneService.terminalPaneCloseDisposition(
                ipcRawValue: notification.userInfo?[IPCNotification.terminalCloseDispositionUserInfoKey] as? String)
        else { return }
        let sessionIsTerminating = (notification.userInfo?[IPCNotification.terminalSessionIsTerminatingUserInfoKey] as? String) == "true"
        Task { @MainActor [weak self, object, sessionID, sessionIsTerminating, disposition] in
            guard let self, self.matchesProfileIPCObject(object) else { return }
            TerminalPerformance.logMetric(
                "terminal_window_close_ipc", target: "session=\(sessionID)", elapsedMS: 0, success: true,
                detail: "terminating=\(sessionIsTerminating ? 1 : 0) disposition=\(disposition.rawValue)")
            self.terminalPanes.closeTerminalSessionPane(sessionID: sessionID, sessionIsTerminating: sessionIsTerminating, disposition: disposition)
        }
    }

    @objc private nonisolated func handleDumpTerminalSessionWindowStateIPC(_ notification: Notification) {
        let object = notification.object as? String
        guard let sessionID = notification.userInfo?[IPCNotification.terminalSessionIDUserInfoKey] as? String else { return }
        guard let outputPath = notification.userInfo?[IPCNotification.outputPathUserInfoKey] as? String else { return }
        let modeRawValue = notification.userInfo?[IPCNotification.terminalAttachmentModeUserInfoKey] as? String
        let mode = modeRawValue.flatMap(TerminalAttachmentMode.init(rawValue:))
        Task { @MainActor [weak self, object, sessionID, outputPath, mode] in
            guard let self, self.matchesProfileIPCObject(object) else { return }
            self.dumpTerminalSessionPaneState(sessionID: sessionID, mode: mode, outputPath: outputPath)
        }
    }

    @objc private nonisolated func handleFocusTerminalSessionWindowIPC(_ notification: Notification) {
        let object = notification.object as? String
        guard let sessionID = notification.userInfo?[IPCNotification.terminalSessionIDUserInfoKey] as? String else { return }
        let requestID = notification.userInfo?[IPCNotification.focusRequestIDUserInfoKey] as? String
        Task { @MainActor [weak self, object, sessionID, requestID] in
            guard let self, self.matchesProfileIPCObject(object) else { return }
            TerminalPerformance.logMetric(
                "terminal_window_focus_ipc_received", target: "session=\(sessionID)", elapsedMS: 0, success: true,
                detail: requestID.map { "request_id=\($0)" } ?? "")
            await self.focusTerminalSessionPane(sessionID: sessionID, requestID: requestID)
        }
    }

    @objc private nonisolated func handlePerformTerminalSessionWindowShortcutIPC(_ notification: Notification) {
        let object = notification.object as? String
        guard let sessionID = notification.userInfo?[IPCNotification.terminalSessionIDUserInfoKey] as? String else { return }
        guard let action = notification.userInfo?[IPCNotification.terminalShortcutActionUserInfoKey] as? String else { return }
        let text = notification.userInfo?[IPCNotification.terminalShortcutTextUserInfoKey] as? String
        Task { @MainActor [weak self, object, sessionID, action, text] in
            guard let self, self.matchesProfileIPCObject(object) else { return }
            self.performTerminalSessionPaneShortcut(sessionID: sessionID, action: action, text: text)
        }
    }

    private func matchesProfileIPCObject(_ object: String?) -> Bool { object == ipcNotificationObject }

    private func dumpTerminalSessionPaneState(sessionID: String, mode: TerminalAttachmentMode?, outputPath: String) {
        let requestedMode = mode?.rawValue ?? "any"
        let content = panelCoordinator.content(forSessionID: sessionID)
        content?.debugRefreshStateForTesting(skipOwnerAttach: mode == .viewer)
        let debugState = content?.debugStateDump()
        let payload = TerminalSessionWindowStateDump(
            sessionID: sessionID, requestedMode: requestedMode, found: content != nil, windowTitle: debugState?.windowTitle,
            rendererSummary: debugState?.rendererSummary, renderedOutput: debugState?.renderedOutput,
            visibleSurfaceOutput: debugState?.visibleSurfaceOutput, surfaceSelectionText: debugState?.surfaceSelectionText,
            summary: debugState?.summary, state: debugState?.state, showsTerminalSurface: debugState?.showsTerminalSurface,
            showsTextRenderer: debugState?.showsTextRenderer, didClose: debugState?.didCloseWindow,
            windowNumber: content?.contentView.window?.windowNumber, surfaceColumns: debugState?.surfaceColumns, surfaceRows: debugState?.surfaceRows,
            windowIsKey: debugState?.windowIsKey, firstResponderTypeName: debugState?.firstResponderTypeName,
            searchVisible: debugState?.searchVisible, searchQuery: debugState?.searchQuery, searchTotal: debugState?.searchTotal,
            searchSelected: debugState?.searchSelected, attachmentMode: debugState?.attachmentMode, takeoverPending: debugState?.takeoverPending,
            takeoverButtonVisible: debugState?.takeoverButtonVisible, takeoverButtonEnabled: debugState?.takeoverButtonEnabled,
            takeoverMessage: debugState?.takeoverMessage)
        writeTerminalSessionWindowStateDump(payload, to: outputPath)
    }

    private func performTerminalSessionPaneShortcut(sessionID: String, action: String, text: String?) {
        panelCoordinator.content(forSessionID: sessionID)?.performShortcutForTesting(action: action, text: text)
    }

    private func writeTerminalSessionWindowStateDump(_ payload: TerminalSessionWindowStateDump, to outputPath: String) {
        let url = URL(fileURLWithPath: outputPath)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(payload)
            try data.write(to: url, options: [.atomic])
        } catch {}
    }

    struct TerminalSessionSummaryMatch: Sendable, Equatable {
        let device: SpacesPairedDeviceRecord
        let summary: SpacesDeviceTerminalSessionSummary
    }

    typealias TerminalSessionOverviewResolver = @Sendable (DeviceRequestContext) throws -> SpacesDeviceOverviewResolution

    /// The overview session summary for a session and the device that owns it,
    /// when the session is currently surfaced in a loaded device overview.
    /// Internal rather than `private`: `TerminalPaneService.makeTerminalSessionStateModel` and
    /// `TerminalPaneService.makeTerminalPaneContent` also need this to resolve a session's owning device.
    func terminalSessionSummaryMatch(sessionID: String) -> TerminalSessionSummaryMatch? {
        for section in deviceModel.deviceSections {
            guard let summary = section.overview?.sessions.first(where: { $0.id == sessionID }) else { continue }
            guard let device = deviceForMutation(deviceID: section.deviceID) else { continue }
            return TerminalSessionSummaryMatch(device: device, summary: summary)
        }
        return nil
    }

    /// The device that owns a terminal session: its overview's device, the device
    /// of the workspace that carries it, or the local device as a last resort.
    /// Ownership is read ungated — a session on an unreachable device still belongs to that
    /// device, and refusing to name it here would drop through to the local-device fallback and
    /// read another machine's session from this Mac. Acting on the session is gated separately.
    /// Internal rather than `private`: `TerminalPaneService.makeTerminalSessionStateModel` also needs
    /// this to resolve a session's owning device.
    func terminalSessionOwningDevice(sessionID: String) -> SpacesPairedDeviceRecord? {
        if let match = terminalSessionSummaryMatch(sessionID: sessionID) { return match.device }
        if let workspaceID = clientWorkspaceID(forTerminalSession: sessionID), let deviceID = deviceID(forWorkspaceID: workspaceID) {
            return deviceOwning(deviceID: deviceID)
        }
        return deviceModel.localPairedDevice
    }

    /// Reads a session's real launch configuration straight from its owning device when the
    /// session is not yet in any loaded overview.
    ///
    /// An `openTerminalSessionWindow`/focus IPC can arrive before the sidebar surfaces a
    /// just-created session: on a cold launch the IPC observers are registered before the
    /// initial sidebar load populates `localPairedDevice`, and a TerminalService/spacese2e
    /// session can be created while the overview subscription is still stale. In both cases
    /// the loaded overview lacks the session. Rather than fabricate a placeholder
    /// shell/command — which the later Device API state payload never corrects, since it
    /// carries only title/cwd/runtime — this bootstraps the local device when it is unloaded,
    /// then fetches a fresh overview off the main actor to read the session's persisted
    /// shell/command/title, matching the launch configuration the old DB-backed path read directly.
    private func resolveSessionSummaryMatch(sessionID: String) async -> TerminalSessionSummaryMatch? {
        let clientApp = SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)
        if deviceModel.localPairedDevice == nil {
            let bootstrapStartedAt = Date()
            let device = await Task.detached(
                priority: .userInitiated, operation: { try? SpacesDeviceClient.bootstrapLocalDevice(clientApp: clientApp) }
            ).value
            logPerfMetric(
                "terminal_session_resolve_bootstrap", target: "session=\(sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: bootstrapStartedAt), success: device != nil)
            guard let device else { return nil }
            deviceModel.localPairedDevice = device
            deviceModel.localDeviceID = device.id
        }
        guard let device = terminalSessionOwningDevice(sessionID: sessionID) else { return nil }
        let overviewStartedAt = Date()
        let match = await Self.resolveSessionSummaryMatchOffMain(sessionID: sessionID, device: device, clientApp: clientApp)
        logPerfMetric(
            "terminal_session_resolve_overview", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: overviewStartedAt),
            success: match != nil)
        return match
    }

    nonisolated static func resolveSessionSummaryMatchOffMain(
        sessionID: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp,
        resolveOverview: @escaping TerminalSessionOverviewResolver = { context in try SpacesDeviceClient.resolveOverview(context: context) }
    ) async -> TerminalSessionSummaryMatch? {
        await Task.detached(priority: .userInitiated) {
            guard
                let summary = try? resolveOverview(DeviceRequestContext(device: device, clientApp: clientApp)).overview?.overview.sessions.first(
                    where: { $0.id == sessionID })
            else { return nil }
            return TerminalSessionSummaryMatch(device: device, summary: summary)
        }.value
    }

    /// Resolves a session's pane open request. An open/focus IPC can arrive before the
    /// sidebar surfaces a just-created session (cold launch, spacese2e-created
    /// sessions), so when no loaded overview knows the session this falls back to
    /// `resolveSessionSummaryMatch`'s off-main cold overview fetch.
    private func resolveTerminalSessionPaneOpenRequest(sessionID: String) async -> DeviceTerminalOpenRequest? {
        // A loaded-overview request built from a workspace row that predates the session's
        // overview entry lacks the real shell/command; fall through to the cold fetch so
        // the pane's seeded launch config never shows a placeholder.
        if let workspaceID = clientWorkspaceID(forTerminalSession: sessionID),
            let request = paneOpenRequest(workspaceID: workspaceID, sessionID: sessionID), request.shell != nil
        {
            return request
        }
        guard let match = await resolveSessionSummaryMatch(sessionID: sessionID) else { return nil }
        return TerminalPaneService.terminalSessionPaneOpenRequest(from: match)
    }

    /// Opens (or focuses) the session's pane and, for an owner-mode open, reclaims owner
    /// attachment. `mode` carries the intent of the `openTerminalSessionWindow` IPC: an
    /// owner open (e.g. `spaces terminal show`) must preempt a different active owner (a
    /// mobile client that took the session over), so it calls `requestOwnershipIfNeeded()`
    /// after the pane opens. The pane's own attach otherwise stays a viewer when another
    /// client owns, which would leave ownership unchanged. Emits the `terminal_window_summon`
    /// perf metric the E2E harness parses.
    /// `focusIntent` is independent of `mode`: a `.withoutFocus` open still reclaims owner attachment,
    /// it just installs (or leaves) the pane without selecting its tab, fronting its panel, or moving
    /// the caret, so a programmatic launch does not take the window the user is working in.
    /// `resolvedRequest`, when provided, skips the internal session→device resolution: the remote
    /// deep-link open resolves the request against the link's explicitly named device (so it never
    /// falls back to the local device the way the session-id-only resolve does) and hands it in here,
    /// reusing this one open/focus + owner-reclaim + metric path.
    ///
    /// Internal (not private) so a test can drive the `retried_after_reload` gate directly with a
    /// non-focusing `openIntent`: every production caller opens focused, and a focusing refusal here
    /// shows a real modal alert, which a unit test process must never trigger.
    @discardableResult func openTerminalSessionPane(
        sessionID: String, mode: TerminalAttachmentMode, openIntent: TerminalPaneOpenIntent, requestID: String? = nil,
        resolvedRequest: DeviceTerminalOpenRequest? = nil
    ) async -> Bool {
        let startedAt = Date()
        let focusIntent = openIntent.focus
        let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
        let modeDetail = "mode=\(mode.rawValue) focus=\(focusIntent.rawValue)"
        // The invariant for a replacement's open, enforced here and nowhere else: it either claims the
        // pane its restart is holding or releases it, exactly once, on every path out of this function.
        // Every failure exit below funnels through this one `defer` rather than cleaning up for itself,
        // because the ways an open can fail are open-ended (the session may not resolve yet, its device
        // may refuse the install, its content may fail to build) and a path that forgot to release would
        // strand the terminated predecessor on screen with nothing left able to close it: the daemon
        // consumed the reservation when it launched the replacement, and overview pruning skips held
        // panes. Only an open that actually claimed the pane settles the hold: an open that succeeded by
        // installing a fresh pane (the predecessor's was closed by the user before the restart, so there
        // was nothing to claim) leaves the hold untouched and still owing a release, which is why the
        // test below is on the action taken rather than on the open having worked.
        var openAction: TerminalPaneService.TerminalPaneOpenAction?
        defer {
            if let orphaned = TerminalPaneService.heldPredecessorSessionToRelease(replacesSessionID: openIntent.replacesSessionID, openAction: openAction)
            {
                panelCoordinator.releasePaneHeldForReplacement(sessionID: orphaned)
            }
        }
        let reusedExistingPane = panelCoordinator.placement(forSessionID: sessionID) != nil
        // Re-showing the pane the user is already focused in and owns is a foreground-and-focus, so it also
        // skips resolving the request: resolution only exists to install or re-target a pane. A
        // non-focusing open has nothing to foreground, so it never takes this shortcut.
        if focusIntent == .focus, reusedExistingPane, panelCoordinator.refocusFocusedTerminalPane(forSessionID: sessionID) {
            logPerfMetric(
                "terminal_window_summon", target: "session=\(sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true,
                detail: "\(modeDetail) reused=1 route=pane refocus=1\(requestDetail)")
            return true
        }
        let resolved: DeviceTerminalOpenRequest?
        if let resolvedRequest { resolved = resolvedRequest } else { resolved = await resolveTerminalSessionPaneOpenRequest(sessionID: sessionID) }
        guard let request = resolved else {
            logPerfMetric(
                "terminal_window_summon", target: "session=\(sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false,
                detail: "\(modeDetail) route=pane reason=resolve_nil\(requestDetail)")
            return false
        }
        // The open resolves the workspace's scope through the sidebar's index. A request for a
        // just-created workspace whose index entry has not landed yet is refused for exactly that reason
        // (`workspaceScope(forWorkspaceID:)` nil), so wait for the app's next snapshot and try once more;
        // the miss can equally be in the request's own resolution, so a request this function resolved is
        // resolved again (one handed in by the caller is already pinned to its device and is reused as
        // is). A request whose scope is already present was refused for something else entirely: an
        // unreachable or incompatible device (which already showed its own modal for a focusing intent)
        // or a content-construction failure. Retrying either would only repeat the same refusal, and for
        // the device case, its modal a second time.
        var attempt = panelCoordinator.openOrFocusTerminalPane(request, openIntent: openIntent)
        var retriedAfterReload = false
        if attempt == nil, panelCoordinator.workspaceScope(forWorkspaceID: request.workspaceID) == nil {
            retriedAfterReload = true
            await sidebar.reloadAwaitingFreshSnapshot()
            var retryRequest = request
            if resolvedRequest == nil, let reresolved = await resolveTerminalSessionPaneOpenRequest(sessionID: sessionID) {
                retryRequest = reresolved
            }
            attempt = panelCoordinator.openOrFocusTerminalPane(retryRequest, openIntent: openIntent)
        }
        let retryDetail = retriedAfterReload ? " retried_after_reload=1" : ""
        guard let action = attempt else {
            logPerfMetric(
                "terminal_window_summon", target: "session=\(sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false,
                detail: "\(modeDetail) route=pane reason=pane_open_failed\(requestDetail)\(retryDetail)")
            return false
        }
        openAction = action
        if mode == .owner { panelCoordinator.content(forSessionID: sessionID)?.requestOwnershipIfNeeded() }
        logPerfMetric(
            "terminal_window_summon", target: "session=\(sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true,
            detail: "\(modeDetail) reused=\(reusedExistingPane ? 1 : 0) route=pane\(requestDetail)\(retryDetail)")
        return true
    }

    /// Focuses a session's pane (opening it when needed) for the focus IPC, emitting the
    /// `terminal_window_focus_ipc` metric the E2E harness correlates by request id.
    private func focusTerminalSessionPane(sessionID: String, requestID: String?) async {
        let startedAt = Date()
        let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
        // Focus must not preempt a different active owner (matching the pre-rework focus
        // path); only the owner-mode open IPC reclaims ownership.
        let focused = await openTerminalSessionPane(sessionID: sessionID, mode: .viewer, openIntent: .focused, requestID: requestID)
        logPerfMetric(
            "terminal_window_focus_ipc", target: "session=\(sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: focused,
            detail: "route=pane\(requestDetail)")
    }

    /// Internal rather than `private`: `TerminalPaneService.createTerminalSessionForPane` also needs this
    /// to resolve the pane open request for the session its mutation just started.
    func terminalOpenRequest(fromMutationResponse response: SpacesDeviceAPIResponse, workspaceID: String) -> DeviceTerminalOpenRequest? {
        guard let sessionID = response.sessionID else { return nil }
        return Self.deviceTerminalOpenRequest(
            workspaceID: workspaceID, sessionID: sessionID, overview: response.overview ?? overview(forWorkspaceID: workspaceID))
    }

    /// Start Agent's background terminal is opened from the mutation's explicit launched-session
    /// payload, not by re-resolving the refreshed overview. A fast-exiting command can disappear from
    /// `overview.sessions` before the response is built even though the user still needs that
    /// terminal's pane and failure output.
    nonisolated static func startedWorkspaceCommandPaneOpenRequest(deviceID: String, response: SpacesDeviceAPIResponse) -> DeviceTerminalOpenRequest?
    {
        guard let launchedTerminalSession = response.launchedTerminalSession else { return nil }
        return TerminalPaneService.terminalSessionPaneOpenRequest(summary: launchedTerminalSession, deviceID: deviceID)
    }

    nonisolated private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Asks the owning daemon to stop the ad hoc terminal behind a pane the user just closed. The daemon
    /// terminates it only when it is an ad hoc shell sitting at a bare prompt with no surviving owner
    /// attachment, and otherwise keeps it recoverable in the sidebar, so no session-kind gate is applied
    /// here: the client's view of a session's kind comes from overview rows, which an exited coding-agent
    /// row keeps claiming long after the agent is gone.
    func stopAdHocBuiltInTerminalSessionIfBareShell(sessionID: String, closedPaneOwnedOrEnded: Bool) {
        guard
            TerminalPaneService.shouldRequestAdHocBareShellStopOnPaneClose(
                closedPaneOwnedOrEnded: closedPaneOwnedOrEnded, isAppTerminatingAndKeepingSessions: keepsTerminalSessionsRunningDuringTermination)
        else { return }
        guard let workspaceID = clientWorkspaceID(forTerminalSession: sessionID), let device = deviceForWorkspaceMutation(workspaceID: workspaceID)
        else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Self.deviceMutation(device: device) { device in
                try SpacesDeviceClient.stopWorkspaceTerminalIfBareShell(
                    workspaceID: workspaceID, sessionID: sessionID,
                    context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
            }
            // Only a session the daemon actually terminated changed any row; a kept session leaves the
            // sidebar exactly as it was, so reloading for it would be pure churn on every pane close.
            guard case .success(let response) = result, response.terminatedTerminalSession == true else { return }
            self.requestSidebarReload()
        }
    }

    private func logWorkspaceDetailIPC(_ message: String) {
        guard ProcessInfo.processInfo.environment["DEBUG"] == "1" else { return }
        // Manual real-system E2E uses these lines to confirm the helper-driven
        // workspace-detail selection request was accepted by the running app.
        fputs("spaces: workspace_detail_ipc \(message)\n", stderr)
    }

    private func setupAppActivationObservers() {
        appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.attemptDesktopControlRecoveryIfNeeded()
                self.logHotkeyDebug("app_did_become_active \(self.hotkeyWindowStateSummary())")
                if let profile = self.activeWindowShortcutProfile {
                    let routeElapsedMS = profile.routeCompletedAt.map { self.windowShortcutElapsedMS(since: $0) } ?? -1
                    self.logWindowShortcutProfile(
                        "stage=app_became_active index=\(profile.index) elapsed_ms=\(self.windowShortcutElapsedMS(since: profile.startedAt)) route_gap_ms=\(routeElapsedMS)"
                    )
                    self.activeWindowShortcutProfile = nil
                }
                self.flushDeferredSidebarReloadsIfNeeded()
                // Catch up on any database change whose IPC signal was missed while
                // the app was suspended in the background. Reactivation is the one
                // point that state could be stale, and the reload no-ops the outline
                // rebuild when nothing changed, so this stays cheap and flicker-free.
                if self.didStartBackgroundServices { self.sidebar.handleDatabaseDidChange() }
            }
        }
        appDidResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.logHotkeyDebug("app_did_resign_active \(self.hotkeyWindowStateSummary())")
                if self.commandPalette.commandPalettePanel?.isVisible == true { self.commandPalette.dismissCommandPalette() }
                guard let profile = self.activeWindowShortcutProfile else { return }
                let routeElapsedMS = profile.routeCompletedAt.map { self.windowShortcutElapsedMS(since: $0) } ?? -1
                self.logWindowShortcutProfile(
                    "stage=app_resigned_active index=\(profile.index) elapsed_ms=\(self.windowShortcutElapsedMS(since: profile.startedAt)) route_gap_ms=\(routeElapsedMS)"
                )
                self.activeWindowShortcutProfile = nil
            }
        }
    }

    private func setupWorkspaceApplicationObservers() {
        workspaceDidTerminateApplicationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let terminatedPID = application.map(\.processIdentifier)
            MainActor.assumeIsolated {
                guard let self else { return }
                guard
                    Self.shouldAttemptDesktopControlRecovery(
                        passiveOwnerPID: self.passiveDesktopControlOwner?.pid, terminatedApplicationPID: terminatedPID)
                else { return }
                self.attemptDesktopControlRecoveryIfNeeded()
            }
        }
    }

    /// Flushes a deferred sidebar reload when text editing ends. The reload guard
    /// is also false while any text input is focused, and database/worktree
    /// changes that arrive then are only held; without the removed metadata poll,
    /// ending editing (tab/click out while staying in the app) must flush so the
    /// sidebar does not stay stale until an unrelated reload. Runs on the next
    /// run-loop turn so the first responder has settled before the guard re-checks.
    private func setupTextInputDidEndEditingObserver() {
        textInputDidEndEditingObserver = NotificationCenter.default.addObserver(forName: NSText.didEndEditingNotification, object: nil, queue: .main)
        { [weak self] _ in Self.scheduleAfterNextRunLoopTurn { self?.flushDeferredSidebarReloadsIfNeeded() } }
    }

    /// Flushes sidebar reloads that were deferred because the user was mid-edit.
    /// Reload triggers (the daemon's `databaseDidChange`) are one-shot, so this
    /// runs at natural idle points (forms closing, app re-activation) in place of
    /// the old poll re-check.
    func flushDeferredSidebarReloadsIfNeeded() { sidebar.flushPendingDatabaseReloadIfNeeded() }

    /// Observes the app's effective light/dark appearance so an OS-driven flip — the user changing the
    /// system theme while the appearance setting follows the system — re-themes the daemon-rendered
    /// terminals. Those terminals run in `spacesd`, which has no `NSApp`, so per-view
    /// `viewDidChangeEffectiveAppearance` recolors app chrome but cannot reach them; without this they
    /// would keep the stale variant until reopened. The handler re-runs the same resolved-value broadcast
    /// the settings picker uses, and per-pane dedupe (seeded from attach) makes a redundant trigger free.
    ///
    /// It cannot fire-loop with `applyAppAppearance`'s `NSApp.appearance` assignment: the broadcast only
    /// reads `effectiveAppearance` and sends `setAppearance` to open panes — it never assigns
    /// `NSApp.appearance` — so it provokes no further appearance change here. KVO delivers on the main
    /// thread that mutated `effectiveAppearance`, so `assumeIsolated` is safe.
    private func setupAppEffectiveAppearanceObserver() {
        appEffectiveAppearanceObservation = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.broadcastResolvedAppAppearance() }
        }
    }

    func canReloadAfterBackgroundWorkspaceRefresh() -> Bool {
        !projectForms.projectHasUnsavedChanges && projectForms.activeAddWorkspaceFormTag == nil && projectForms.activeAddProjectFormTag == nil
            && !isTextInputFocused()
    }

    struct LocalDeviceSidebarSnapshot: Sendable {
        let projects: [ProjectSummary]
        let workspacesByProject: [String: [WorkspaceSummary]]
        let workspaceRuntimeStatusByID: [String: WorkspaceRuntimeStatus]
        let alertsGroups: [AlertsGroup]
        let localDeviceID: String
        let localDeviceName: String
        let localPairedDevice: SpacesPairedDeviceRecord
        let localDeviceOverview: SpacesDeviceOverviewPayload
        let localDaemonStatus: TerminalServiceDaemonStatus?
        let localCompatibility: SpacesWireCompatibility?
        // Non-nil when the local daemon could not be reached for this snapshot. Carries the failure
        // reason so the sidebar can render the local device as offline (mirroring remote devices)
        // instead of failing the whole snapshot. The overview falls back to an empty payload.
        let localOfflineMessage: String?
    }

    enum SidebarReloadPayload: Sendable {
        case terminalOverview(LocalDeviceSidebarSnapshot)
        case fullSnapshot(SidebarDataSnapshot)
    }

    /// The sidebar groups projects under per-device header rows when more than one device is paired, or
    /// when any section is not loaded so its caption — the only surface for an unreachable daemon's
    /// reason, its recovery button, and the "loading…" that button puts it in — still has a header row to render
    /// in. A single loaded device stays a flat project list. Pure so the single-unloaded-device rule is
    /// directly testable.
    nonisolated static func sidebarShowsDeviceHeaders(deviceCount: Int, hasUnloadedSection: Bool) -> Bool { deviceCount > 1 || hasUnloadedSection }

    /// Maps the local device's snapshot reachability to a sidebar load state. A non-nil offline message
    /// (the local daemon could not be reached) renders the local device as offline, exactly like a remote
    /// device that fails to load; otherwise the device is loaded. Keeping this pure makes the
    /// parity-with-remote contract directly testable.
    nonisolated static func localDeviceLoadState(offlineMessage: String?) -> SidebarDeviceLoadState { offlineMessage.map { .offline($0) } ?? .loaded }

    /// Whether a just-received local device snapshot is authoritative enough to prune open local panes
    /// against its overview's retained keep-set. Pruning may run only against a reachable, wire-compatible
    /// local daemon: an offline daemon (`.offline` load state) or a reachable-but-incompatible one (a
    /// non-`.compatible` verdict) carries only an empty placeholder overview, mirroring the remote path's
    /// `load.overview == nil` branch that must not prune. Absence of a real overview is never evidence a
    /// session's product row was removed, so this guard protects the never-prune-without-an-authoritative-
    /// overview invariant. Pure so that invariant is directly testable.
    nonisolated static func localSnapshotAuthorizesPanePrune(loadState: SidebarDeviceLoadState, compatibility: SpacesWireCompatibility?) -> Bool {
        loadState == .loaded && compatibility?.isCompatible != false
    }

    /// The flat, id-keyed sidebar data: the union of every device section's rows, whatever each device's
    /// load state is. An unreachable device keeps everything it last reported listed for the whole
    /// outage — no grace period — so the user can keep browsing it, and so the id-based lookups that read
    /// this merged data (which device owns a workspace, which overview a row belongs to) keep resolving
    /// its rows instead of treating them as unknown. Project/workspace ids are globally unique, so the
    /// union never collides. Pure so the "an offline device is still merged" rule is directly testable.
    ///
    /// A workspace whose delete is in flight stays in this data: it keeps its sidebar row, which renders
    /// marked as deleting (see `sidebarWorkspaceRowState`) until the mutation resolves, rather than
    /// disappearing and — because the owning daemon still reports it — coming back on the next refresh.
    nonisolated static func mergedSidebarData(sections: [DeviceSection]) -> (
        projects: [ProjectSummary], workspacesByProject: [String: [WorkspaceSummary]], workspaceRuntimeStatusByID: [String: WorkspaceRuntimeStatus],
        alertsGroups: [AlertsGroup]
    ) {
        var mergedProjects: [ProjectSummary] = []
        var mergedWorkspaces: [String: [WorkspaceSummary]] = [:]
        var mergedRuntime: [String: WorkspaceRuntimeStatus] = [:]
        var mergedAlerts: [AlertsGroup] = []
        for section in sections {
            mergedProjects.append(contentsOf: section.projects)
            mergedWorkspaces.merge(section.workspacesByProject) { current, _ in current }
            mergedRuntime.merge(section.workspaceRuntimeStatusByID) { current, _ in current }
            mergedAlerts.append(contentsOf: section.alertsGroups)
        }
        return (mergedProjects, mergedWorkspaces, mergedRuntime, mergedAlerts)
    }

    /// How a sidebar workspace row renders and responds while its delete mutation runs. A delete takes
    /// seconds on the owning daemon (it stops the workspace, then removes the git worktree), so the row
    /// stays listed and is marked for that whole window instead of vanishing and reappearing on the next
    /// overview refresh: dimmed, carrying a progress indicator, its runtime-target children hidden, and
    /// inert — no selection, no context menu, no expansion. It leaves the sidebar exactly once, when the
    /// post-delete overview stops carrying it.
    struct SidebarWorkspaceRowState: Equatable, Sendable {
        /// Row opacity. Assigned independently of the owning device's dimming, which uses the same value,
        /// so a marked row under an unreachable device is dimmed once rather than twice.
        let alpha: CGFloat
        let showsDeletingProgress: Bool
        /// Whether the row's runtime targets are listed as children at all. False while deleting, so the
        /// children are hidden whatever the user's expansion state — there is nothing to do under a row
        /// that is going away — and the expansion state itself is left untouched, so a failed delete
        /// restores exactly what the user had open.
        let listsRuntimeTargetChildren: Bool
        /// Whether the row accepts selection, its context menu, and expansion.
        let isInteractive: Bool
    }

    /// Whether a workspace's row is marked as deleting: the union of the deletes this app issued
    /// (`workspaceIDsPendingDeletion`) and the teardowns the owning daemon reports running
    /// (`deviceOverview.workspaceIDsWithTeardownInFlight`). A delete started on the iPhone — or a project
    /// delete taking its workspaces with it — has to mark the row here too, rather than leaving it looking
    /// ordinary and actionable while its worktree is being removed. `deviceOverview` is whatever
    /// `deviceSections` has installed for the workspace's owning device, `nil` when that device has none
    /// (offline, not yet loaded, or a wire-incompatible placeholder), which reports only the local set.
    /// Pure so the union is directly testable without a live `AppKitController`.
    nonisolated static func isWorkspaceMarkedDeleting(
        workspaceID: String, pendingDeletionWorkspaceIDs: Set<String>, deviceOverview: SpacesDeviceOverviewPayload?
    ) -> Bool { pendingDeletionWorkspaceIDs.contains(workspaceID) || deviceOverview?.workspaceIDsWithTeardownInFlight.contains(workspaceID) == true }

    /// `isWorkspaceMarkedDeleting` against this controller's live state: the local pending set and the
    /// overview installed for the workspace's owning device.
    func isWorkspaceMarkedDeleting(_ workspaceID: String) -> Bool {
        let deviceOverview = deviceID(forWorkspaceID: workspaceID).flatMap { deviceSection(id: $0)?.overview }
        return Self.isWorkspaceMarkedDeleting(
            workspaceID: workspaceID, pendingDeletionWorkspaceIDs: workspaceDeletion.workspaceIDsPendingDeletion, deviceOverview: deviceOverview)
    }

    /// The row treatment for a workspace, keyed on whether its delete is in flight. Pure so the
    /// marked-row contract is directly testable.
    nonisolated static func sidebarWorkspaceRowState(isPendingDeletion: Bool) -> SidebarWorkspaceRowState {
        guard isPendingDeletion else {
            return SidebarWorkspaceRowState(alpha: 1, showsDeletingProgress: false, listsRuntimeTargetChildren: true, isInteractive: true)
        }
        return SidebarWorkspaceRowState(
            alpha: unreachableDeviceAlpha, showsDeletingProgress: true, listsRuntimeTargetChildren: false, isInteractive: false)
    }

    /// The row treatment for a project row, keyed on the workspace its row stands in for. A non-git
    /// project owns exactly one workspace and has no `.workspace` row of its own — the project row is that
    /// workspace's row — so it renders and responds to the workspace's marked state. A git project row
    /// stands in for no workspace (`nil`) and is never marked: its own workspaces carry their marks.
    /// Pure so the stand-in contract is directly testable.
    nonisolated static func sidebarProjectRowState(standInWorkspaceIsPendingDeletion: Bool?) -> SidebarWorkspaceRowState {
        sidebarWorkspaceRowState(isPendingDeletion: standInWorkspaceIsPendingDeletion == true)
    }

    /// The opacity a row inherits from its owning device's load state. A device that is not loaded —
    /// unreachable, or reconnecting after an outage — keeps its rows listed but dimmed, so the subtree
    /// reads as browsable-but-not-actionable. This is the same treatment the add-project device picker
    /// gives an offline device; status is carried by the dimming plus the section caption, never by an
    /// extra per-row icon. Pure so the rule is directly testable.
    nonisolated static func sidebarRowAlpha(loadState: SidebarDeviceLoadState) -> CGFloat { loadState == .loaded ? 1 : unreachableDeviceAlpha }

    /// The dimming every listed-but-not-actionable row shares: an unreachable device's rows, its
    /// add-project picker row, and a workspace row marked as deleting.
    nonisolated static let unreachableDeviceAlpha: CGFloat = 0.55

    enum BackgroundRefreshFailureAction: Equatable {
        case deferredSetup
        case logOnly
    }

    /// Holds a click closure and serves as the NSGestureRecognizer target for clickable row views.
    /// Not private: `ProjectFormsController`'s device/source rows use this from a different file in
    /// the same module (cross-file `private` isn't visible).
    @MainActor final class ClickTarget: NSObject {
        let action: () async -> Void
        init(_ action: @escaping () async -> Void) { self.action = action }
        @objc func clicked(_ sender: NSGestureRecognizer) { Task { await self.action() } }
    }

    // Not private: `ProjectFormsController` associates click targets with this key from a different
    // file in the same module (cross-file `private` isn't visible).
    static var clickTargetAssocKey: UInt8 = 0

    private func presentTerminalQuitDialog(liveSessionCount: Int) -> TerminalQuitDialogChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit Spaces?"
        let sessionWord = liveSessionCount == 1 ? "terminal session is" : "terminal sessions are"
        alert.informativeText =
            "\(liveSessionCount) \(sessionWord) still running. Quit and keep them running, stop all terminal sessions before quitting, or cancel."

        let keepButton = alert.addButton(withTitle: "Quit and Keep Running")
        keepButton.keyEquivalent = "\r"
        keepButton.keyEquivalentModifierMask = []
        alert.addButton(withTitle: "Stop All and Quit")
        let cancelButton = alert.addButton(withTitle: "Cancel")
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: return .keepRunning
        case .alertSecondButtonReturn: return .stopAll
        default: return .cancel
        }
    }

    private func prewarmTerminalServiceAfterStartup() {
        Task.detached(priority: .utility) {
            do {
                _ = try TerminalService.ensureRunning(timeout: 5)
                Task { @MainActor [weak self] in self?.logStartupProfile("terminal_service_prewarmed") }
            } catch { if Self.hotkeyDebugEnabled() { fputs("spaces: spacesd prewarm failed: \(error)\n", stderr) } }
        }
    }

    nonisolated private static func startupProfileEnabled() -> Bool { ProcessInfo.processInfo.environment["SPACES_STARTUP_PROFILE"] == "1" }

    nonisolated private static func startupElapsedMS() -> Int { Int((ProcessInfo.processInfo.systemUptime - startupProfileBaselineUptime) * 1000) }

    func logStartupProfile(_ stage: String, details: String = "") {
        guard Self.startupProfileEnabled() else { return }
        let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - startupProfileStartTime) * 1000)
        let suffix = details.isEmpty ? "" : " \(details)"
        fputs("spaces: startup stage=\(stage) elapsed_ms=\(elapsedMS)\(suffix)\n", stderr)
    }

    nonisolated private static func logStartupSnapshotProfile(_ stage: String, details: String = "") {
        guard startupProfileEnabled() else { return }
        let suffix = details.isEmpty ? "" : " \(details)"
        fputs("spaces: startup stage=\(stage) elapsed_ms=\(startupElapsedMS())\(suffix)\n", stderr)
    }

    // Not private: `ShortcutsController`'s shortcut monitor calls this from a different file in the
    // same module (cross-file `private` isn't visible).
    func recordStartupInteraction(kind: String) {
        guard !didLogFirstStartupInteraction else { return }
        didLogFirstStartupInteraction = true
        logStartupProfile("first_interaction", details: "kind=\(kind)")
    }

    nonisolated private static func hotkeyDebugEnabled() -> Bool { ProcessInfo.processInfo.environment["DEBUG"] == "1" }

    nonisolated private static func hotkeyDebugLogPath() -> String { NSTemporaryDirectory().appending("/spaces-hotkey-debug.log") }

    func logHotkeyDebug(_ message: String) {
        guard Self.hotkeyDebugEnabled() else { return }
        let line = "spaces: hotkey_debug \(message)\n"
        fputs(line, stderr)
        guard let data = line.data(using: .utf8) else { return }
        let path = Self.hotkeyDebugLogPath()
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch { try? handle.close() }
    }

    func hotkeyWindowStateSummary() -> String {
        let mainVisible = effectiveMainWindowVisibilityForHotkeyState() ? 1 : 0
        let mainMini = window?.isMiniaturized == true ? 1 : 0
        let mainKey = window?.isKeyWindow == true ? 1 : 0
        let paletteVisible = commandPalette.commandPalettePanel?.isVisible == true ? 1 : 0
        let paletteKey = commandPalette.commandPalettePanel?.isKeyWindow == true ? 1 : 0
        let auxiliaryVisible = commandPalette.commandPalettePanel?.isVisible == true ? 1 : 0
        return
            "app_active=\(NSApp.isActive ? 1 : 0) app_hidden=\(NSApp.isHidden ? 1 : 0) main_visible=\(mainVisible) main_key=\(mainKey) main_mini=\(mainMini) palette_exists=\(commandPalette.commandPalettePanel == nil ? 0 : 1) palette_visible=\(paletteVisible) palette_key=\(paletteKey) auxiliary_visible=\(auxiliaryVisible)"
    }

    func rawMainWindowVisibility() -> Bool { window?.isVisible == true && window?.isMiniaturized != true }

    func activateReturnApplication(processIdentifier: pid_t) {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else { return }
        application.activate(options: [])
    }

    private func activateCurrentApplicationForTargetedReveal() { NSApp.activate(ignoringOtherApps: true) }

    private func effectiveMainWindowVisibilityForHotkeyState() -> Bool {
        Self.effectiveMainWindowVisibilityForHotkeyState(
            rawMainWindowIsVisible: rawMainWindowVisibility(),
            commandPaletteMainWindowVisibility: commandPalette.commandPaletteMainWindowVisibility
                ?? commandPalette.pendingCommandPalettePresentation?.mainWindowWasVisible)
    }

    /// Agent-state tints resolve through `SidebarAttentionStatus.indicatorColor` — the one runtime-state color
    /// vocabulary — so an alert reads in the same color as the sidebar row it came from. `terminal` is an
    /// identity tint for the terminal glyph, not a state, so it keeps its own color.
    static func alertsIconColor(_ tint: AlertsIconTint) -> NSColor {
        switch tint {
        case .terminal: .systemGreen
        case .warning: SidebarAttentionStatus.blocked.indicatorColor
        case .done: SidebarAttentionStatus.done.indicatorColor
        }
    }

    nonisolated static func alertsAttentionAgentWindows(_ agentWindows: [AgentWindowRecord]) -> [AgentWindowRecord] {
        agentWindows.filter { $0.status == .waiting || $0.status == .done }
    }

    nonisolated static func deviceMutation(
        device: SpacesPairedDeviceRecord, operation: @Sendable @escaping (SpacesPairedDeviceRecord) throws -> SpacesDeviceAPIResponse
    ) async -> Result<SpacesDeviceAPIResponse, Error> {
        await Task.detached(priority: .userInitiated) { do { return .success(try operation(device)) } catch { return .failure(error) } }.value
    }

    /// Whether a failed `deviceMutation` leaves its outcome unknown, so `deleteWorkspace` has to
    /// reconcile against fresh overviews (`WorkspaceDeletionReconciler`) instead of reporting the
    /// failure outright.
    ///
    /// Only a refusal from the daemon is definitive, and it takes two things to prove one. First a Device
    /// API error code, which `SpacesDeviceClientError` attaches exactly where it turns an `ok: false`
    /// response into `.requestRejected`: every other failure this request can throw carries none — a
    /// client-side timeout (`archiveWorkspace` allows 60s, well short of what the daemon's own teardown
    /// queue can take once it is stopping the workspace, removing its worktree, and dropping its record),
    /// an unreachable host, a certificate pin mismatch — and none of those says anything about whether
    /// the daemon accepted the delete.
    ///
    /// Second, the code has to be a verdict on the request (`SpacesDeviceErrorCode.isRequestVerdict`)
    /// rather than a report of something going wrong. A delete that succeeded and then failed while
    /// building its refreshed overview answers with a coded `internalError`, and reading that as a refusal
    /// would restore a row for a workspace that is already gone.
    ///
    /// Mirrors `SpacesMobileAppModel.isIndeterminateDeleteOutcome` on iOS; both share the verdict list.
    nonisolated static func isIndeterminateDeleteOutcome(_ error: Error) -> Bool {
        guard let code = (error as? any SpacesDeviceErrorCodeProviding)?.spacesDeviceErrorCode else { return true }
        return !code.isRequestVerdict
    }

    /// The delete landed, but the branch-deletion report existed only in the response that was lost —
    /// reconciliation (or, once deferred, the next installed overview) can prove the workspace is gone,
    /// not what happened to branches the user explicitly asked to delete. Shared verbatim between the
    /// immediate `.gone` verdict in `deleteWorkspace` and `WorkspaceDeletionCoordinator.resolveAwaitingWorkspaceDeletions`,
    /// so both paths report the exact same thing rather than two copies of the same sentence drifting apart.
    static let workspaceDeletionBranchOutcomeUnknownMessage =
        "Deleted the workspace, but the connection dropped before the branch-deletion result arrived. Check the branch in the repository."

    /// Refetches `device`'s overview for `WorkspaceDeletionReconciler`, discarding the specific
    /// failure: a reconciliation refetch that fails is inconclusive rather than proof of anything, so
    /// the reconciler just tries again on its next attempt.
    nonisolated private static func deviceOverviewFetch(device: SpacesPairedDeviceRecord) async -> SpacesDeviceOverviewPayload? {
        await Task.detached(priority: .userInitiated) {
            (try? SpacesDeviceClient.overview(
                context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))))?
                .overview
        }.value
    }

    // Browser rows stay visible even when the workspace is stopped so the Run tab
    // remains a stable launch surface for configured browser sessions.
    nonisolated static func shouldShowConfiguredBrowserSessions(workspaceIsRunning _: Bool) -> Bool { true }

    nonisolated static func shouldShowWorkspaceSetupPanel(status: WorkspaceSetupStatus) -> Bool { status != .succeeded }

    nonisolated static func shouldShowWorkspaceSetupScriptEditor(status: WorkspaceSetupStatus) -> Bool { status == .failed }

    nonisolated static func shouldRequestNormalWorkspaceDetailRefresh(setupStatus: WorkspaceSetupStatus) -> Bool { setupStatus == .succeeded }

    // ISO8601DateFormatter construction is expensive and this is shared by the `nonisolated`
    // overview-mapping helpers below (agentWindows, deviceTerminalWindows), which run off the main
    // actor. ISO8601DateFormatter is documented thread-safe, so a single nonisolated instance is
    // safe to reuse instead of allocating a fresh formatter per call. `AlertsController` keeps its
    // own identical instance for its overview-mapping helper (`buildOverviewAlertsGroups`), and
    // `TerminalPaneService` keeps an instance-scoped one for its pane factory, rather than
    // reaching back into this one.
    nonisolated(unsafe) private static let staticISO8601Formatter = ISO8601DateFormatter()

    private enum LocalDeviceSnapshotPurpose: Sendable {
        case launch
        case refresh
    }

    /// The cold launch owns the one unconditional identity bootstrap for this app run. Later full
    /// snapshots use the stored local device and bootstrap only when credentials or endpoint recovery
    /// genuinely require it.
    nonisolated static func initialSidebarDataSnapshot() async -> Result<SidebarDataSnapshot, Error> { await sidebarDataSnapshot(purpose: .launch) }

    nonisolated static func refreshedSidebarDataSnapshot() async -> Result<SidebarDataSnapshot, Error> {
        await sidebarDataSnapshot(purpose: .refresh)
    }

    /// The terminal signal's narrow loader: the same authoritative local-device payload a full snapshot
    /// applies, without reading app config or touching any remote section.
    nonisolated static func localDeviceOverviewSnapshot() async -> Result<LocalDeviceSidebarSnapshot, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let database = try SpacesClientDatabase.defaultDatabase()
                let clientApp = SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)
                return .success(try loadLocalDeviceSidebarSnapshot(database: database, clientApp: clientApp, purpose: .refresh))
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func sidebarDataSnapshot(purpose: LocalDeviceSnapshotPurpose) async -> Result<SidebarDataSnapshot, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let snapshotStartedAt = ProcessInfo.processInfo.systemUptime
                let config = try clientAppConfig()
                logStartupSnapshotProfile("sidebar_snapshot_config_ready")
                let database = try SpacesClientDatabase.defaultDatabase()
                let clientApp = SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)
                let local = try loadLocalDeviceSidebarSnapshot(database: database, clientApp: clientApp, purpose: purpose)
                logStartupSnapshotProfile(
                    "sidebar_snapshot_complete", details: "total_ms=\(Int((ProcessInfo.processInfo.systemUptime - snapshotStartedAt) * 1000))")
                return .success(.init(config: config, local: local))
            } catch { return .failure(error) }
        }.value
    }

    /// Builds the local device slice shared by cold launch, ordinary full refreshes, and the terminal-only
    /// refresh lane. Only reachability failures become an offline placeholder; reachable authorization,
    /// persistence, migration, and decode errors remain load failures.
    nonisolated private static func loadLocalDeviceSidebarSnapshot(
        database: SpacesClientDatabase, clientApp: SpacesDeviceClientApp, purpose: LocalDeviceSnapshotPurpose
    ) throws -> LocalDeviceSidebarSnapshot {
        let localDevice: SpacesPairedDeviceRecord
        let bootstrapOfflineMessage: String?
        do {
            switch purpose {
            case .launch: localDevice = try SpacesDeviceClient.bootstrapLocalDevice(database: database, clientApp: clientApp)
            case .refresh: localDevice = try SpacesDeviceClient.localDeviceForSidebarRefresh(database: database, clientApp: clientApp)
            }
            bootstrapOfflineMessage = nil
        } catch {
            guard SpacesDeviceClient.isLocalDaemonUnreachableError(error),
                let storedLocalDevice = try? database.pairedDevice(id: SpacesPairedDeviceRecord.localDeviceID)
            else { throw error }
            localDevice = storedLocalDevice
            bootstrapOfflineMessage = error.localizedDescription
        }

        let resolvedDevice: SpacesPairedDeviceRecord
        let localDaemonStatus: TerminalServiceDaemonStatus?
        let localCompatibility: SpacesWireCompatibility?
        let localOverview: SpacesDeviceOverviewPayload
        let localOfflineMessage: String?
        if let bootstrapOfflineMessage {
            resolvedDevice = localDevice
            localDaemonStatus = nil
            localCompatibility = nil
            localOverview = SpacesDeviceOverviewPayload.offlinePlaceholder
            localOfflineMessage = bootstrapOfflineMessage
        } else {
            do {
                let resolution = try SpacesDeviceClient.resolveOverview(context: DeviceRequestContext(device: localDevice, clientApp: clientApp))
                // Endpoint recovery can bootstrap a different live port. Carry that refreshed record into
                // the UI so later actions do not keep dialing the stale address that provoked recovery.
                if let device = resolution.overview?.device {
                    resolvedDevice = device
                } else {
                    // Endpoint recovery persists the refreshed record even when a wire-incompatible
                    // daemon cannot return a decodable overview. Adopt that live identity so the
                    // compatibility block's remedy does not keep dialing the stale pre-recovery port.
                    guard let storedDevice = try database.pairedDevice(id: localDevice.id) else {
                        throw SpacesDeviceClientError.missingLocalBootstrap
                    }
                    resolvedDevice = storedDevice
                }
                localDaemonStatus = resolution.daemonStatus
                localCompatibility = resolution.compatibility
                localOverview = resolution.overview?.overview ?? SpacesDeviceOverviewPayload.offlinePlaceholder
                localOfflineMessage = nil
            } catch {
                guard SpacesDeviceClient.isLocalDaemonUnreachableError(error) else { throw error }
                resolvedDevice = localDevice
                localDaemonStatus = nil
                localCompatibility = nil
                localOverview = SpacesDeviceOverviewPayload.offlinePlaceholder
                localOfflineMessage = error.localizedDescription
            }
        }

        let collapseStates = (try? database.projectCollapseStates(deviceID: resolvedDevice.id)) ?? [:]
        // Not DeviceSectionContent.derive: the two profile events below time the mapping and alerts phases separately.
        let mapped = deviceSidebarData(from: localOverview, deviceID: resolvedDevice.id, projectCollapseStates: collapseStates)
        let workspaceCount = mapped.workspacesByProject.values.reduce(0) { $0 + $1.count }
        logStartupSnapshotProfile(
            "sidebar_snapshot_local_device_ready",
            details: "device=\(resolvedDevice.name) project_count=\(mapped.projects.count) workspace_count=\(workspaceCount)")
        let alertsGroups = AlertsController.buildOverviewAlertsGroups(from: localOverview, deviceID: resolvedDevice.id, deviceName: resolvedDevice.name)
        logStartupSnapshotProfile(
            "sidebar_snapshot_alerts_ready", details: "group_count=\(alertsGroups.count) item_count=\(alertsGroups.reduce(0) { $0 + $1.items.count })"
        )
        return LocalDeviceSidebarSnapshot(
            projects: mapped.projects, workspacesByProject: mapped.workspacesByProject, workspaceRuntimeStatusByID: mapped.workspaceRuntimeStatusByID,
            alertsGroups: alertsGroups, localDeviceID: resolvedDevice.id, localDeviceName: resolvedDevice.name, localPairedDevice: resolvedDevice,
            localDeviceOverview: localOverview, localDaemonStatus: localDaemonStatus, localCompatibility: localCompatibility,
            localOfflineMessage: localOfflineMessage)
    }

    nonisolated static func deviceSidebarData(
        from overview: SpacesDeviceOverviewPayload, deviceID: String, projectCollapseStates: [String: Bool] = [:]
    ) -> (projects: [ProjectSummary], workspacesByProject: [String: [WorkspaceSummary]], workspaceRuntimeStatusByID: [String: WorkspaceRuntimeStatus])
    {
        let model = SpacesDeviceOverviewViewModel(overview: overview)
        let projects = model.projects.map {
            ProjectSummary(
                id: $0.id, name: $0.name, dir: $0.dir, isGitRepo: $0.isGitRepo, defaultBranch: $0.defaultBranch, isHidden: $0.isHidden,
                isCollapsed: projectCollapseStates[$0.id] ?? false, deviceID: deviceID)
        }
        let workspacesByProject = model.workspacesByProject.mapValues { workspaces in
            workspaces.map {
                WorkspaceSummary(
                    id: $0.id, branch: $0.branch, baseBranch: $0.baseBranch, dir: $0.dir, isRunning: $0.isRunning, isHidden: $0.isHidden,
                    isDefault: $0.isDefault, notes: $0.notes, deviceID: deviceID)
            }
        }
        let workspaceRuntimeStatusByID = model.workspaceRuntimeStatusByID.mapValues { runtime in
            WorkspaceRuntimeStatus(
                workspaceID: runtime.workspaceID, lifecycleState: WorkspaceLifecycleState(isRunning: runtime.lifecycleState == .running),
                runtimeHealth: .healthy, hasTrackedRuntimeIndicators: runtime.hasTrackedRuntimeIndicators,
                runningProcessCount: runtime.runningProcessCount, exitedProcessCount: runtime.exitedProcessCount,
                waitingAgentWindowCount: runtime.waitingAgentWindowCount, missingConfiguredProcessCount: runtime.missingConfiguredProcessCount,
                missingConfiguredBrowserSessionCount: runtime.missingConfiguredBrowserSessionCount)
        }

        return (projects, workspacesByProject, workspaceRuntimeStatusByID)
    }

    struct SidebarProjectActions: Equatable, Sendable {
        let showsSettings: Bool
        let showsAddWorkspace: Bool
    }

    nonisolated static func sidebarProjectActions(isGitRepo: Bool) -> SidebarProjectActions {
        let actions = SpacesDeviceProjectActions(isGitRepo: isGitRepo)
        return SidebarProjectActions(showsSettings: actions.showsSettings, showsAddWorkspace: actions.showsAddWorkspace)
    }

    // Not private: also used by `ProjectFormsController`'s project-settings conversions from a
    // different file in the same module (cross-file `private` isn't visible).
    nonisolated static func localServiceDefinition(from port: SpacesDeviceServiceDefinition) -> ServiceDefinition {
        ServiceDefinition(id: port.id, name: port.name)
    }

    // Not private: also used by `ProjectFormsController`'s project-settings conversions from a
    // different file in the same module (cross-file `private` isn't visible).
    nonisolated static func deviceServiceDefinition(from port: ServiceDefinition) -> SpacesDeviceServiceDefinition {
        SpacesDeviceServiceDefinition(id: port.id, name: port.name)
    }

    // Not private: also used by `ProjectFormsController`'s project-settings conversions from a
    // different file in the same module (cross-file `private` isn't visible).
    nonisolated static func localProcessTemplate(from process: SpacesDeviceProcessTemplate) -> ProcessTemplate {
        ProcessTemplate(
            id: process.id, name: process.name, command: process.command, kind: process.kind,
            onExit: ProcessExitAction(rawValue: process.onExit) ?? .none)
    }

    // Not private: also used by `ProjectFormsController`'s project-settings conversions from a
    // different file in the same module (cross-file `private` isn't visible).
    nonisolated static func deviceProcessTemplate(from process: ProcessTemplate) -> SpacesDeviceProcessTemplate {
        SpacesDeviceProcessTemplate(id: process.id, name: process.name, command: process.command, kind: process.kind, onExit: process.onExit.rawValue)
    }

    nonisolated static func localBrowserSession(from session: SpacesDeviceBrowserSession) -> BrowserSession {
        BrowserSession(name: session.name, url: session.url)
    }

    // Not private: also used by `ProjectFormsController`'s project-settings conversions from a
    // different file in the same module (cross-file `private` isn't visible).
    nonisolated static func deviceBrowserSession(from session: BrowserSession) -> SpacesDeviceBrowserSession {
        SpacesDeviceBrowserSession(name: session.name, url: session.url)
    }

    nonisolated static func localWorkspaceSettings(from config: SpacesDeviceWorkspaceConfig) -> WorkspaceSettings {
        WorkspaceSettings(
            stopScript: config.stopScript, ports: config.ports.map(localServiceDefinition(from:)),
            processes: config.processes.map(localProcessTemplate(from:)), browserSessions: config.browserSessions.map(localBrowserSession(from:)))
    }

    nonisolated private static func deviceWorkspaceConfig(
        from settings: WorkspaceSettings, resolvedBrowserSessions: [SpacesDeviceBrowserSession] = []
    ) -> SpacesDeviceWorkspaceConfig {
        SpacesDeviceWorkspaceConfig(
            stopScript: settings.stopScript, ports: settings.ports.map(deviceServiceDefinition(from:)),
            processes: settings.processes.map(deviceProcessTemplate(from:)),
            browserSessions: settings.browserSessions.map(deviceBrowserSession(from:)), resolvedBrowserSessions: resolvedBrowserSessions)
    }

    nonisolated private static func localSetupStatus(from status: SpacesDeviceWorkspaceSetupStatus) -> WorkspaceSetupStatus {
        switch status {
        case .pending: return .pending
        case .running: return .running
        case .succeeded: return .succeeded
        case .failed: return .failed
        }
    }

    nonisolated private static func localSetupState(from state: SpacesDeviceWorkspaceSetupState?) -> WorkspaceSetupState {
        guard let state else { return WorkspaceSetupState(status: .succeeded, errorMessage: nil, startedAt: nil, finishedAt: nil) }
        return WorkspaceSetupState(
            status: localSetupStatus(from: state.status), errorMessage: state.errorMessage, startedAt: state.startedAt, finishedAt: state.finishedAt,
            exitCode: state.exitCode, logPath: state.logPath)
    }

    nonisolated private static func runningState(from state: SpacesDeviceRunState) -> RunningProcessState {
        switch state {
        case .notStarted: return .idle
        case .running: return .running
        case .exited: return .exited
        }
    }

    nonisolated private static func statusKind(from state: SpacesDeviceRunState) -> RowPrimitives.StatusKind {
        switch state {
        case .notStarted: return .idle
        case .running: return .running
        case .exited: return .exited
        }
    }

    // Not private: `AlertsController.buildOverviewAlertsGroups` calls this from a different file in
    // the same module (cross-file `private` isn't visible), mirroring `agentWindows(from:)` below.
    nonisolated static func agentStatus(from state: SpacesDeviceCodingAgentActivityState) -> AgentWindowStatus {
        switch state {
        case .idle: return .idle
        case .spinning: return .spinning
        case .waiting: return .waiting
        case .done: return .done
        case .exited: return .exited
        }
    }

    nonisolated static func runningProcesses(from rows: [SpacesDeviceWorkspaceProcessRow]) -> [RunningProcessRecord] {
        rows.compactMap { row in
            guard row.runState != .notStarted || row.processID != nil || row.sessionID != nil else { return nil }
            return RunningProcessRecord(
                id: row.processID ?? row.id, workspaceID: row.workspaceID, templateID: row.templateID, templateName: row.name, command: row.command,
                runtimeTargetID: nil, terminalApp: nil, terminalTarget: row.sessionID.map { TerminalTargetRecord(trackingID: $0) }, pid: nil,
                status: runningState(from: row.runState), logPath: nil, lastOutputAt: nil, startedAt: nil, exitedAt: nil)
        }
    }

    nonisolated static func agentWindows(from rows: [SpacesDeviceWorkspaceCodingAgentRow]) -> [AgentWindowRecord] {
        let now = staticISO8601Formatter.string(from: Date())
        return rows.compactMap { row in
            guard row.agentID != nil || row.sessionID != nil || row.runState != .notStarted else { return nil }
            return AgentWindowRecord(
                id: row.agentID ?? row.id, workspaceID: row.workspaceID, provider: .spaces, label: row.name,
                terminalTarget: row.sessionID.map { TerminalTargetRecord(trackingID: $0) }, status: agentStatus(from: row.activityState),
                createdAt: now, updatedAt: now)
        }
    }

    nonisolated static func deviceTerminalWindows(from rows: [SpacesDeviceWorkspaceTerminalRow]) -> [WindowRecord] {
        let now = staticISO8601Formatter.string(from: Date())
        return rows.enumerated().map { index, row in
            WindowRecord(
                id: row.id, workspaceID: row.workspaceID, app: "Spaces", name: row.title, detail: row.liveTitle, terminalTrackingID: row.sessionID,
                role: "terminal", orderIndex: index, lastSeenAt: now)
        }
    }

    nonisolated static func shouldRefreshVisibleWorkspaceDetail(
        selectedWorkspaceID: String?, showingAlerts: Bool, showingSettings: Bool, workspaceExists: Bool, mainWindowIsFocused: Bool,
        commandPaletteIsVisible: Bool
    ) -> Bool {
        guard selectedWorkspaceID != nil else { return false }
        guard !showingAlerts, !showingSettings else { return false }
        guard workspaceExists else { return false }
        return mainWindowIsFocused || commandPaletteIsVisible
    }

    /// Whether the workspace lifecycle controls (sidebar row context menu, detail footer) should offer
    /// Start, alongside Restart/Stop when the workspace is already running.
    ///
    /// `isRunning` turns true the instant an ad hoc terminal or coding-agent session starts
    /// (`markWorkspaceRunningIfNeeded`, called from `launchWorkspaceCommandSession` and
    /// `reserveWorkspaceTerminalLaunchUnlocked`), which is not the same as the workspace's configured
    /// processes being fully up: a workspace can be `isRunning` from ad hoc runtime alone with every
    /// configured process still missing. Gating Start purely on `isRunning` (as both surfaces did before
    /// this) hid it exactly in that state and left Restart, which tears down the ad hoc terminal or agent
    /// session, as the only reachable action, the opposite of Start's convergent contract, which leaves
    /// them untouched.
    nonisolated static func workspaceLifecycleControlsOfferStart(isRunning: Bool, missingConfiguredProcessCount: Int) -> Bool {
        !isRunning || missingConfiguredProcessCount > 0
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
            case agent
        }

        let kind: Kind
        let processID: String?
        let windowListIndex: Int?
        let targetURL: String?
        let processKey: String?
        let agentWindow: AgentWindowRecord?
    }

    struct WorkspaceRuntimeTargetIndex: Sendable {
        let orderedTargets: [WorkspaceRunShortcutTarget]
        let targetsByProcessID: [String: WorkspaceRunShortcutTarget]
        let targetsByTerminalSessionID: [String: WorkspaceRunShortcutTarget]
        let targetsByAgentID: [String: WorkspaceRunShortcutTarget]
        let targetsByURL: [String: WorkspaceRunShortcutTarget]
        let shortcutIndices: WorkspaceDetailShortcutIndices

        init(
            browserSessions: [BrowserSession], processEntries: [WorkspaceRunProcessEntry], processesByID: [String: RunningProcessRecord],
            agentWindows: [AgentWindowRecord]
        ) {
            let orderedTargets = AppKitController.orderedWorkspaceRunShortcutTargets(
                browserSessions: browserSessions, processEntries: processEntries, processesByID: processesByID, agentWindows: agentWindows)
            self.orderedTargets = orderedTargets

            var targetsByProcessID: [String: WorkspaceRunShortcutTarget] = [:]
            var targetsByTerminalSessionID: [String: WorkspaceRunShortcutTarget] = [:]
            var targetsByAgentID: [String: WorkspaceRunShortcutTarget] = [:]
            var targetsByURL: [String: WorkspaceRunShortcutTarget] = [:]
            var browserSessionsByURL: [String: Int] = [:]
            var processesByName: [String: Int] = [:]
            var codingAgentsByName: [String: Int] = [:]
            var codingAgentsByIdentity: [String: Int] = [:]

            for (offset, target) in orderedTargets.enumerated() {
                let index = offset + 1
                switch target.kind {
                case .browser:
                    if let targetURL = target.targetURL, !targetURL.isEmpty {
                        targetsByURL[targetURL, default: target] = target
                        if index <= 10 { browserSessionsByURL[targetURL] = index }
                    }
                case .process:
                    if let processID = target.processID, let process = processesByID[processID] {
                        targetsByProcessID[processID, default: target] = target
                        if let sessionID = process.terminalTrackingID, !sessionID.isEmpty {
                            targetsByTerminalSessionID[sessionID, default: target] = target
                        }
                        if index <= 10 { processesByName[process.templateName] = index }
                    }
                case .missingConfiguredProcess:
                    if let processKey = target.processKey, !processKey.isEmpty, index <= 10 { processesByName[processKey] = index }
                case .agent:
                    if let agentWindow = target.agentWindow {
                        targetsByAgentID[agentWindow.id, default: target] = target
                        if let sessionID = agentWindow.terminalTrackingID, !sessionID.isEmpty {
                            targetsByTerminalSessionID[sessionID, default: target] = target
                        }
                        if index <= 10 {
                            if let label = agentWindow.label, !label.isEmpty { codingAgentsByName[label] = index }
                            codingAgentsByIdentity[AppKitController.codingAgentShortcutIdentity(agentWindowID: agentWindow.id)] = index
                        }
                    }
                case .window: break
                }
            }

            self.targetsByProcessID = targetsByProcessID
            self.targetsByTerminalSessionID = targetsByTerminalSessionID
            self.targetsByAgentID = targetsByAgentID
            self.targetsByURL = targetsByURL
            shortcutIndices = WorkspaceDetailShortcutIndices(
                browserSessionsByURL: browserSessionsByURL, processesByName: processesByName, codingAgentsByName: codingAgentsByName,
                codingAgentsByIdentity: codingAgentsByIdentity)
        }
    }

    struct DeviceTerminalOpenRequest: Sendable, Equatable {
        /// The workspace whose panel hosts this pane. Every terminal session is
        /// workspace-owned, so this always resolves.
        let workspaceID: String
        /// The owning device, when it can't be derived from `workspaceID` alone (global-window
        /// panes mix devices, so the descriptor carries deviceID directly). `nil` resolves the
        /// device from `workspaceID`.
        let deviceID: String?
        let sessionID: String
        let title: String
        let workingDirectory: String
        let kind: TerminalSessionKind
        /// Shell and launch command from the overview summary, threaded through so the
        /// seeded launch configuration shows the session's real shell/command rather than a
        /// placeholder. `nil` when the request is built from a row that predates the
        /// session's overview entry; the open path then falls back to the loaded summary.
        let shell: String?
        let command: String?
        let initialState: TerminalSessionState?
        let servicePID: Int32?
        let childPID: Int32?
        let createdAt: String?
        let updatedAt: String?
        let preparedCredentials: DeviceTerminalSessionStateModel.PreparedCredentials?
        /// For the local device, the daemon's current Device API endpoint re-resolved off the main actor
        /// during preparation (the same per-request resolution the CLI does), which also ensures the
        /// daemon is running. The pane's state model seeds its request client and subscription stream from
        /// this instead of the possibly-stale stored `paired_devices` row, so the model's first control
        /// connect — which runs synchronously on the main actor — targets a live port and never blocks the
        /// UI on a dead one (issue #185). `nil` for remote devices (stable port) and until preparation runs.
        let resolvedLocalDevice: SpacesPairedDeviceRecord?

        init(
            workspaceID: String, deviceID: String? = nil, sessionID: String, title: String, workingDirectory: String, kind: TerminalSessionKind,
            shell: String? = nil, command: String? = nil, initialState: TerminalSessionState? = nil, servicePID: Int32? = nil, childPID: Int32? = nil,
            createdAt: String? = nil, updatedAt: String? = nil, preparedCredentials: DeviceTerminalSessionStateModel.PreparedCredentials? = nil,
            resolvedLocalDevice: SpacesPairedDeviceRecord? = nil
        ) {
            self.workspaceID = workspaceID
            self.deviceID = deviceID
            self.sessionID = sessionID
            self.title = title
            self.workingDirectory = workingDirectory
            self.kind = kind
            self.shell = shell
            self.command = command
            self.initialState = initialState
            self.servicePID = servicePID
            self.childPID = childPID
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.preparedCredentials = preparedCredentials
            self.resolvedLocalDevice = resolvedLocalDevice
        }

        func prepared(credentials: DeviceTerminalSessionStateModel.PreparedCredentials, resolvedLocalDevice: SpacesPairedDeviceRecord?)
            -> DeviceTerminalOpenRequest
        {
            DeviceTerminalOpenRequest(
                workspaceID: workspaceID, deviceID: deviceID, sessionID: sessionID, title: title, workingDirectory: workingDirectory, kind: kind,
                shell: shell, command: command, initialState: initialState, servicePID: servicePID, childPID: childPID, createdAt: createdAt,
                updatedAt: updatedAt, preparedCredentials: credentials, resolvedLocalDevice: resolvedLocalDevice)
        }
    }

    /// A device-agnostic window-focus target resolved from the overview. The dispatcher
    /// focuses the client's window for the target; only two leaves vary by where the
    /// workspace's daemon runs: browser URLs may need remote-service routing, and terminal
    /// windows use native sessions locally vs Device API mirrors remotely.
    enum DeviceWindowShortcutResolution: Sendable, Equatable {
        case openURL(workspaceID: String, targetURL: String)
        case openTerminal(DeviceTerminalOpenRequest)
        case runProcess(workspaceID: String, processKey: String, processTemplateID: String?)
        case noWorkspace
        case noMatch
    }

    struct WorkspaceDetailShortcutIndices: Sendable {
        let browserSessionsByURL: [String: Int]
        let processesByName: [String: Int]
        let codingAgentsByName: [String: Int]
        let codingAgentsByIdentity: [String: Int]
    }

    enum RunningWorkspaceProcessEditDecision: Equatable, Sendable {
        case applyImmediately
        case confirmRestart(processNames: [String])
    }

    enum WorkspacePathAction: String, Sendable {
        case openEditor
        case revealInFinder

        var title: String {
            switch self {
            case .openEditor: "Open Editor"
            case .revealInFinder: "Reveal in Finder"
            }
        }
    }

    final class WorkspacePathActionContext {
        let workspaceID: String
        let path: String

        init(workspaceID: String, path: String) {
            self.workspaceID = workspaceID
            self.path = path
        }
    }

    nonisolated static func remoteWorkspacePathActionErrorMessage(action: WorkspacePathAction, deviceName: String) -> String {
        "\(action.title) requires a workspace path on this Mac. \(deviceName) workspaces live on the selected daemon; use an SSH-capable workflow for that remote path."
    }

    nonisolated static func processTemplateKey(for template: ProcessTemplate) -> String {
        template.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated static func runningWorkspaceProcessEditDecision(previous: [ProcessTemplate], updated: [ProcessTemplate])
        -> RunningWorkspaceProcessEditDecision
    {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let changedProcessNames = updated.compactMap { updatedTemplate -> String? in
            guard let previousTemplate = previousByID[updatedTemplate.id] else { return nil }
            guard previousTemplate.command != updatedTemplate.command else { return nil }
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

    nonisolated static func codingAgentShortcutIdentity(agentWindowID: String) -> String { "agent:\(agentWindowID)" }

    nonisolated static func agentTerminalTrackingKeys(for record: AgentWindowRecord) -> Set<String> {
        var keys = Set<String>()
        if let trackingKey = record.terminalTrackingKey, !trackingKey.isEmpty { keys.insert(trackingKey) }
        if record.provider == .spaces, let sessionID = record.terminalTrackingID, !sessionID.isEmpty {
            keys.insert(TerminalTrackingIdentity.session(sessionID).trackingKey)
        }
        return keys
    }

    nonisolated static func preferredTerminalWindowsByTrackingKey(_ windows: [WindowRecord]) -> [String: WindowRecord] {
        windows.reduce(into: [:]) { result, window in
            guard window.roleValue == .terminal, let trackingKey = window.terminalTrackingKey else { return }
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
            guard window.roleValue == .terminal, let targetID = window.terminalTrackingKey else { return }
            let existingOrder = result[targetID] ?? Int.max
            result[targetID] = min(existingOrder, window.orderIndex)
        }
        func processOrder(_ process: RunningProcessRecord) -> Int {
            if let targetID = process.terminalTrackingKey, let order = terminalOrderByTargetID[targetID] { return order }
            return Int.max
        }
        let processesByTerminalID: [String: [RunningProcessRecord]] = {
            var map: [String: [RunningProcessRecord]] = [:]
            for process in processes {
                guard let targetID = process.terminalTrackingKey else { continue }
                map[targetID, default: []].append(process)
            }
            for (targetID, list) in map {
                map[targetID] = list.sorted { lhs, rhs in
                    let lhsOrder = processOrder(lhs)
                    let rhsOrder = processOrder(rhs)
                    if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                    return lhs.templateName.localizedStandardCompare(rhs.templateName) == .orderedAscending
                }
            }
            return map
        }()
        let agentTerminalIDs = Set(agentWindows.flatMap { agentTerminalTrackingKeys(for: $0) })
        let eligibleProcesses = processes.filter { process in !(process.terminalTrackingKey.map(agentTerminalIDs.contains) ?? false) }
        let agentClaimedProcessKeys = Set(
            processes.filter { process in process.terminalTrackingKey.map(agentTerminalIDs.contains) ?? false }.map {
                processRuntimeKey(name: $0.templateName)
            })
        var processQueuesByKey: [String: [RunningProcessRecord]] = [:]
        for process in eligibleProcesses { processQueuesByKey[processRuntimeKey(name: process.templateName), default: []].append(process) }
        for (key, list) in processQueuesByKey {
            processQueuesByKey[key] = list.sorted { lhs, rhs in
                let lhsOrder = processOrder(lhs)
                let rhsOrder = processOrder(rhs)
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

        for (windowIdx, window) in windows.enumerated() where window.roleValue != .browser {
            let windowProcesses: [RunningProcessRecord]
            if window.roleValue == .terminal {
                windowProcesses = window.terminalTrackingKey.flatMap { processesByTerminalID[$0] } ?? []
            } else {
                windowProcesses = []
            }
            let isAgentClaimedWindow = window.terminalTrackingKey.map(agentTerminalIDs.contains) ?? false
            let nonAgentWindowProcesses = windowProcesses.filter { process in !(process.terminalTrackingKey.map(agentTerminalIDs.contains) ?? false) }
            if isAgentClaimedWindow && (window.roleValue != .terminal || windowProcesses.isEmpty) { continue }
            if window.roleValue == .terminal, !nonAgentWindowProcesses.isEmpty {
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
        agentWindows: [AgentWindowRecord]
    ) -> [WorkspaceRunShortcutTarget] {
        var targets: [WorkspaceRunShortcutTarget] = []

        for session in browserSessions {
            guard let targetURL = session.url, !targetURL.isEmpty else { continue }
            targets.append(
                WorkspaceRunShortcutTarget(
                    kind: .browser, processID: nil, windowListIndex: nil, targetURL: targetURL, processKey: nil, agentWindow: nil))
        }

        // Row families are grouped: browser sessions, then configured processes, then coding agents, then
        // ad hoc terminals. `processEntries` interleaves configured processes with ad hoc terminal windows
        // in one list, so it is walked twice — configured processes here, terminal windows after the agents
        // — to keep each family contiguous. Order within a family is the order `processEntries` already
        // established (config order for configured processes, window order for terminals).
        for entry in processEntries {
            switch entry.kind {
            case .process:
                guard let processID = entry.processID, processesByID[processID] != nil else { continue }
                targets.append(
                    WorkspaceRunShortcutTarget(
                        kind: .process, processID: processID, windowListIndex: nil, targetURL: nil, processKey: nil, agentWindow: nil))
            case .missingConfiguredProcess:
                guard let processKey = entry.processKey else { continue }
                targets.append(
                    WorkspaceRunShortcutTarget(
                        kind: .missingConfiguredProcess, processID: nil, windowListIndex: nil, targetURL: nil, processKey: processKey,
                        agentWindow: nil))
            case .window: continue
            }
        }

        for agentWindow in agentWindows {
            targets.append(
                WorkspaceRunShortcutTarget(
                    kind: .agent, processID: nil, windowListIndex: nil, targetURL: nil, processKey: nil, agentWindow: agentWindow))
        }

        for entry in processEntries {
            guard case .window = entry.kind, let windowListIndex = entry.windowListIndex else { continue }
            targets.append(
                WorkspaceRunShortcutTarget(
                    kind: .window, processID: nil, windowListIndex: windowListIndex, targetURL: nil, processKey: nil, agentWindow: nil))
        }

        return targets
    }

    nonisolated static func deviceWindowShortcutResolution(index: Int, selectedWorkspaceID: String?, overview: SpacesDeviceOverviewPayload)
        -> DeviceWindowShortcutResolution
    {
        guard let selectedWorkspaceID else { return .noWorkspace }
        guard index > 0 else { return .noMatch }
        guard let deviceWorkspace = overview.workspaces.first(where: { $0.id == selectedWorkspaceID }) else { return .noWorkspace }

        let detail = SpacesDeviceWorkspaceDetailViewModel(workspace: deviceWorkspace)
        let targets = workspaceShortcutTargets(detail: detail, browserSessions: detail.config.resolvedBrowserSessions.map(localBrowserSession(from:)))
        guard targets.indices.contains(index - 1) else { return .noMatch }
        return windowShortcutTargetResolution(targets[index - 1], workspaceID: selectedWorkspaceID, detail: detail, overview: overview)
    }

    /// The ordered focusable targets for a workspace (browsers, configured/running
    /// processes, ad hoc terminals, agents). Numbered shortcuts use this order directly;
    /// window cycling uses this as the base target set before applying MRU order.
    nonisolated static func workspaceShortcutTargets(detail: SpacesDeviceWorkspaceDetailViewModel, browserSessions: [BrowserSession])
        -> [WorkspaceRunShortcutTarget]
    {
        let windows = deviceTerminalWindows(from: detail.terminalRows)
        let processes = runningProcesses(from: detail.processRows)
        let agentWindows = agentWindows(from: detail.codingAgentRows)
        let settings = localWorkspaceSettings(from: detail.config)
        let processEntries = orderedWorkspaceRunProcessEntries(
            configuredProcesses: settings.processes, windows: windows, processes: processes, agentWindows: agentWindows)
        let processesByID = Dictionary(uniqueKeysWithValues: processes.map { ($0.id, $0) })
        return workspaceRuntimeTargetIndex(
            browserSessions: browserSessions, processEntries: processEntries, processesByID: processesByID, agentWindows: agentWindows
        ).orderedTargets
    }

    /// Maps a single focusable target to a device-agnostic focus resolution.
    nonisolated static func windowShortcutTargetResolution(
        _ target: WorkspaceRunShortcutTarget, workspaceID: String, detail: SpacesDeviceWorkspaceDetailViewModel, overview: SpacesDeviceOverviewPayload
    ) -> DeviceWindowShortcutResolution {
        switch target.kind {
        case .browser:
            guard let targetURL = target.targetURL, !targetURL.isEmpty else { return .noMatch }
            return .openURL(workspaceID: workspaceID, targetURL: targetURL)
        case .process:
            guard let processID = target.processID, let row = detail.processRows.first(where: { ($0.processID ?? $0.id) == processID }),
                let sessionID = row.sessionID
            else { return .noMatch }
            return .openTerminal(
                deviceTerminalOpenRequest(workspaceID: workspaceID, sessionID: sessionID, overview: overview)
                    ?? DeviceTerminalOpenRequest(
                        workspaceID: workspaceID, sessionID: sessionID, title: row.name, workingDirectory: detail.dir, kind: .process))
        case .window:
            guard let windowListIndex = target.windowListIndex, detail.terminalRows.indices.contains(windowListIndex),
                let sessionID = detail.terminalRows[windowListIndex].sessionID
            else { return .noMatch }
            let row = detail.terminalRows[windowListIndex]
            return .openTerminal(
                deviceTerminalOpenRequest(workspaceID: workspaceID, sessionID: sessionID, overview: overview)
                    ?? DeviceTerminalOpenRequest(
                        workspaceID: workspaceID, sessionID: sessionID, title: row.title, workingDirectory: row.workingDirectory, kind: .shell))
        case .missingConfiguredProcess:
            guard let processKey = target.processKey else { return .noMatch }
            let processTemplateID = detail.config.processes.first { normalizedRunRowName($0.name ?? "") == normalizedRunRowName(processKey) }?.id
            return .runProcess(workspaceID: workspaceID, processKey: processKey, processTemplateID: processTemplateID)
        case .agent:
            guard let agentWindow = target.agentWindow, let row = detail.codingAgentRows.first(where: { ($0.agentID ?? $0.id) == agentWindow.id }),
                let sessionID = row.sessionID
            else { return .noMatch }
            return .openTerminal(
                deviceTerminalOpenRequest(workspaceID: workspaceID, sessionID: sessionID, overview: overview)
                    ?? DeviceTerminalOpenRequest(
                        workspaceID: workspaceID, sessionID: sessionID, title: row.name, workingDirectory: detail.dir, kind: .agent))
        }
    }

    nonisolated static func deviceTerminalOpenRequest(
        workspaceID fallbackWorkspaceID: String, sessionID: String, overview: SpacesDeviceOverviewPayload?
    ) -> DeviceTerminalOpenRequest? {
        let session = overview?.sessions.first { $0.id == sessionID }
        if let session {
            return DeviceTerminalOpenRequest(
                workspaceID: session.workspaceID, sessionID: session.id, title: session.title, workingDirectory: session.workingDirectory,
                kind: terminalSessionKind(rowKind: session.rowKind), shell: session.shell, command: session.command, initialState: session.state,
                servicePID: session.servicePID, childPID: session.childPID, createdAt: session.createdAt, updatedAt: session.updatedAt)
        }
        guard let workspace = overview?.workspaces.first(where: { $0.id == fallbackWorkspaceID }),
            let row = workspace.terminalRows.first(where: { $0.sessionID == sessionID })
        else { return nil }
        return DeviceTerminalOpenRequest(
            workspaceID: fallbackWorkspaceID, sessionID: sessionID, title: row.title, workingDirectory: row.workingDirectory, kind: .shell)
    }

    /// Builds the terminal-open request for an automation run, dispatching on the run's persisted kind.
    ///
    /// Dispatches on the RUN's own kind, not the automation's current kind: an automation's kind can be edited
    /// once its runs are terminal, but a retained historical run keeps the session shape it actually ran with,
    /// so a script run whose automation later became Agent must still open as a script pane (and vice versa).
    ///
    /// Automation sessions are workspace-bound. A live one resolves its complete persisted metadata from the
    /// overview; an ended replay uses the selected workspace and stored command metadata.
    nonisolated static func automationRunTerminalOpenRequest(
        deviceID: String, sessionID: String, run: TerminalServiceAutomationRunSummary, automation: TerminalServiceAutomationSummary?,
        overview: SpacesDeviceOverviewPayload?, loginShell: String
    ) -> DeviceTerminalOpenRequest? {
        let initialState: TerminalSessionState = AutomationRunStatus(rawValue: run.status) == .running ? .running : .exited
        // A retained run reopens in the workspace its terminal session was launched from. The automation
        // can later be edited to target another workspace, which must not move historical replay.
        guard let workspaceID = run.workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines), !workspaceID.isEmpty else { return nil }
        guard let resolved = deviceTerminalOpenRequest(workspaceID: workspaceID, sessionID: sessionID, overview: overview) else {
            return DeviceTerminalOpenRequest(
                workspaceID: workspaceID, deviceID: deviceID, sessionID: sessionID, title: automation?.name ?? "Automation", workingDirectory: "",
                kind: run.kind == AutomationKind.agent.rawValue ? .agent : .automation, shell: loginShell,
                command: run.kind == AutomationKind.agent.rawValue ? automation?.agentCommand : automation?.script, initialState: initialState)
        }
        return DeviceTerminalOpenRequest(
            workspaceID: resolved.workspaceID, deviceID: deviceID, sessionID: sessionID, title: resolved.title,
            workingDirectory: resolved.workingDirectory, kind: resolved.kind, shell: resolved.shell, command: resolved.command,
            initialState: resolved.initialState ?? initialState, servicePID: resolved.servicePID, childPID: resolved.childPID,
            createdAt: resolved.createdAt, updatedAt: resolved.updatedAt)
    }

    /// Internal rather than `private`: `TerminalPaneService` also needs this to resolve a session
    /// summary's kind for its launch configuration, pane-open request, and overview-scan helpers.
    nonisolated static func terminalSessionKind(rowKind: SpacesDeviceTerminalSessionRowKind) -> TerminalSessionKind {
        switch rowKind {
        case .process: .process
        case .agent: .agent
        case .liveSession: .shell
        }
    }

    nonisolated static func workspaceDetailShortcutIndices(
        browserSessions: [BrowserSession], processEntries: [WorkspaceRunProcessEntry], processesByID: [String: RunningProcessRecord],
        agentWindows: [AgentWindowRecord]
    ) -> WorkspaceDetailShortcutIndices {
        workspaceRuntimeTargetIndex(
            browserSessions: browserSessions, processEntries: processEntries, processesByID: processesByID, agentWindows: agentWindows
        ).shortcutIndices
    }

    nonisolated static func workspaceRuntimeTargetIndex(
        browserSessions: [BrowserSession], processEntries: [WorkspaceRunProcessEntry], processesByID: [String: RunningProcessRecord],
        agentWindows: [AgentWindowRecord]
    ) -> WorkspaceRuntimeTargetIndex {
        WorkspaceRuntimeTargetIndex(
            browserSessions: browserSessions, processEntries: processEntries, processesByID: processesByID, agentWindows: agentWindows)
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
            // `.waiting` and `.ready` never reach here — `statusKind(for:)` above never produces them —
            // so they rank with the other not-running states rather than inventing a process meaning.
            case .idle, .waiting, .ready: return 0
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
        let appMenu = NSMenu(title: "Spaces")
        let updateItem = NSMenuItem(
            title: "Check for Updates...", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = updaterController
        updateItem.isEnabled = updaterController != nil
        appMenu.addItem(updateItem)
        let versionItem = NSMenuItem(title: "Version \(AppVersion.short)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        appMenu.addItem(versionItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Spaces", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        // Find targets the focused terminal pane. The pane view controller is not an
        // NSResponder, so these dispatch through the delegate's find actions (the app
        // delegate terminates the menu's responder-chain search), which resolve the
        // pane owning the key window's first responder.
        let findItem = editMenu.addItem(withTitle: "Find", action: #selector(AppKitController.findInTerminalPane(_:)), keyEquivalent: "f")
        findItem.tag = NSTextFinder.Action.showFindInterface.rawValue
        let findNextItem = editMenu.addItem(
            withTitle: "Find Next", action: #selector(AppKitController.findNextInTerminalPane(_:)), keyEquivalent: "g")
        findNextItem.tag = NSTextFinder.Action.nextMatch.rawValue
        let findPreviousItem = editMenu.addItem(
            withTitle: "Find Previous", action: #selector(AppKitController.findPreviousInTerminalPane(_:)), keyEquivalent: "g")
        findPreviousItem.keyEquivalentModifierMask = [.command, .shift]
        findPreviousItem.tag = NSTextFinder.Action.previousMatch.rawValue
        let useSelectionForFindItem = editMenu.addItem(
            withTitle: "Use Selection for Find", action: #selector(AppKitController.useSelectionForFindInTerminalPane(_:)), keyEquivalent: "e")
        useSelectionForFindItem.tag = NSTextFinder.Action.setSearchString.rawValue
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    /// The terminal pane owning the key window's first responder — the target of the
    /// Edit menu's Find actions.
    private func focusedTerminalPaneContentForMenuAction() -> (any TerminalPaneContentHosting)? {
        panelCoordinator.contentOwning(responder: NSApp.keyWindow?.firstResponder) as? any TerminalPaneContentHosting
    }

    public func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(findInTerminalPane(_:)), #selector(findNextInTerminalPane(_:)), #selector(findPreviousInTerminalPane(_:)),
            #selector(useSelectionForFindInTerminalPane(_:)):
            return focusedTerminalPaneContentForMenuAction()?.canPerformFindActions == true
        default: return true
        }
    }

    @objc func findInTerminalPane(_ sender: Any?) { focusedTerminalPaneContentForMenuAction()?.find(sender) }

    @objc func findNextInTerminalPane(_ sender: Any?) { focusedTerminalPaneContentForMenuAction()?.findNext(sender) }

    @objc func findPreviousInTerminalPane(_ sender: Any?) { focusedTerminalPaneContentForMenuAction()?.findPrevious(sender) }

    @objc func useSelectionForFindInTerminalPane(_ sender: Any?) { focusedTerminalPaneContentForMenuAction()?.useSelectionForFind(sender) }

    /// Creates and shows the NSWindow shell (size, title, center, delegate, makeKeyAndOrderFront) without setting content.
    private func buildShellWindow() {
        let rect = NSRect(x: 200, y: 200, width: 1100, height: 700)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        // AppKit releases a titled, closable window on close by default, which would deallocate the
        // window this controller still strongly references. Close is intercepted below as hide (see
        // windowShouldClose), but a programmatic close() must also never deallocate it.
        window.isReleasedWhenClosed = false
        window.title = "Spaces"
        // No window title or titlebar chrome: the titlebar strip keeps its native
        // behavior (traffic lights, dragging, double-click zoom) and the panel tab
        // strip joins it as a titlebar accessory — the supported way to put
        // interactive views in that row. Content placed under the titlebar with a
        // full-size content view never reliably receives left-clicks there (the
        // titlebar's own event handling wins), so content stays below it.
        window.titleVisibility = .hidden
        window.setAccessibilityIdentifier("spaces-main-window")
        window.backgroundColor = sidebar.sidebarPanelBackgroundColor()
        window.titlebarAppearsTransparent = true
        window.center()
        window.delegate = self
        Self.configureWorkspacePanelTabStripAccessory(panelTabStripAccessory)
        panelTabStripAccessory.view = panelTabStripView
        window.addTitlebarAccessoryViewController(panelTabStripAccessory)
        panelTabStripAccessory.isHidden = true
        presentWindowIfAllowed(window)
    }

    static func configureWorkspacePanelTabStripAccessory(_ accessory: NSTitlebarAccessoryViewController) { accessory.layoutAttribute = .left }

    private func ensureMainWindowVisible() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        prepareWindowForActiveSpaceSummon(window)
        presentWindowIfAllowed(window, forceOrderFront: true)
    }

    private func presentWindowIfAllowed(_ window: NSWindow, forceOrderFront: Bool = false) {
        if Self.isRunningUnderXCTest { return }
        NSApp.activate(ignoringOtherApps: true)
        if forceOrderFront { window.orderFrontRegardless() }
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
        content.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor), splitView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: content.topAnchor), splitView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        // The desktop-control indicator lives in the sidebar top bar, which only now
        // exists — sync it with the lease state resolved during launch.
        refreshDesktopControlStatusUI()
    }

    private func makeLeftPane() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        bindAppearanceReactiveLayer(container) { [weak self] view in view.layer?.backgroundColor = self?.sidebar.sidebarPanelBackgroundColor().cgColor }

        let topBarRow = sidebar.makeSidebarTopBarRow()
        topBarRow.translatesAutoresizingMaskIntoConstraints = false

        let sectionHeader = sidebarSectionHeader(
            title: "Projects",
            actions: [
                (
                    symbol: "line.3.horizontal.decrease.circle", tooltip: "Filter workspaces",
                    action: #selector(WorkspaceVisibilityController.showWorkspaceVisibilityDialog), target: workspaceVisibility
                ),
                (symbol: "plus", tooltip: "New project", action: #selector(addProject), target: nil),
            ])
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
        sidebar.attachOutlineView(outlineView)

        scroll.documentView = outlineView

        let alertsRow = sidebar.makeAlertsSidebarRow()
        alertsRow.translatesAutoresizingMaskIntoConstraints = false

        let automationsRow = sidebar.makeAutomationsSidebarRow()
        automationsRow.translatesAutoresizingMaskIntoConstraints = false

        // The app identity row (logo, name, devices/settings/reload) is the sidebar's
        // footer; the Alerts row leads the content, which starts just below the
        // titlebar strip.
        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(alertsRow)
        container.addSubview(automationsRow)
        container.addSubview(sectionHeader)
        container.addSubview(scroll)
        container.addSubview(footerSeparator)
        container.addSubview(topBarRow)

        NSLayoutConstraint.activate([
            alertsRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            alertsRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            alertsRow.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),

            automationsRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            automationsRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            automationsRow.topAnchor.constraint(equalTo: alertsRow.bottomAnchor, constant: 2),

            sectionHeader.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            sectionHeader.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            sectionHeader.topAnchor.constraint(equalTo: automationsRow.bottomAnchor, constant: 10),

            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sectionHeader.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: footerSeparator.topAnchor),

            footerSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            topBarRow.topAnchor.constraint(equalTo: footerSeparator.bottomAnchor, constant: 2),
            topBarRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            topBarRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            topBarRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            // Same strip height as the right panel's footer so the two separators
            // meet in one line across the window.
            topBarRow.heightAnchor.constraint(equalToConstant: 26),
        ])

        return container
    }

    /// A paired device is usable when its auth token secret is present and its record carries the
    /// daemon's pinned TLS certificate fingerprint (non-secret record data).
    nonisolated static func pairedDeviceHasRequiredCredentials(device: SpacesPairedDeviceRecord) -> Bool {
        let hasToken = (try? SpacesDeviceCredentialStore.hasToken(deviceID: device.id)) ?? false
        return hasToken && !device.certificateFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc func alertsRowClicked() { alerts.showAlertsDetail(presentation: .userNavigation) }

    // MARK: - Automations

    @objc func automationsRowClicked() { automations.showAutomationsDetail() }
    func showAutomationsDetail() { automations.showAutomationsDetail() }
    func updateAutomationsSidebarRow() { sidebar.updateAutomationsSidebarRow() }

    /// The per-device automation slices for the pane and sidebar row: every device section mapped to its
    /// overview's automations/runs, with unreachable sections marked (never dropped) so the pane can surface
    /// them. Local daemon and paired devices are treated identically.
    func automationDeviceInputs() -> [AutomationDeviceInput] {
        deviceModel.deviceSections.map { section in
            let isReachable = section.loadState == .loaded
            let offlineMessage: String? = if case .offline(let message) = section.loadState { message } else { nil }
            return AutomationDeviceInput(
                deviceID: section.deviceID, deviceName: section.displayName, isLocal: section.isLocal, isReachable: isReachable,
                offlineMessage: offlineMessage, automations: section.overview?.automations ?? [], runs: section.overview?.automationRuns ?? [],
                timeZoneIdentifier: section.overview?.daemonStatus.timeZoneIdentifier)
        }
    }

    /// The paired-device record to send an automation Device API command to. Mirrors `deviceForMutation`:
    /// the local id resolves to the local record, any other to its loaded section record.
    func automationDeviceRecord(deviceID: String) -> SpacesPairedDeviceRecord? {
        deviceID == deviceModel.localDeviceID ? deviceModel.localPairedDevice : deviceRecord(forDeviceID: deviceID)
    }

    func isRemoteAutomationDevice(deviceID: String) -> Bool { deviceID != deviceModel.localDeviceID }

    /// The summary for one automation on one device, read from that device's loaded overview.
    func automationSummary(deviceID: String, automationID: String) -> TerminalServiceAutomationSummary? {
        deviceSection(id: deviceID)?.overview?.automations.first { $0.id == automationID }
    }

    /// Builds wire fields from a summary, optionally overriding `enabled` (used by the enable toggle).
    static func automationFields(from summary: TerminalServiceAutomationSummary, enabled: Bool? = nil) -> TerminalServiceAutomationFields {
        TerminalServiceAutomationFields(
            name: summary.name, enabled: enabled ?? summary.enabled, triggerKind: summary.triggerKind, cronExpression: summary.cronExpression,
            kind: summary.kind, script: summary.script, agentCommand: summary.agentCommand, agentPrompt: summary.agentPrompt,
            workspaceID: summary.workspaceID, timeoutSeconds: summary.timeoutSeconds, concurrencyPolicy: summary.concurrencyPolicy,
            missedRunPolicy: summary.missedRunPolicy)
    }

    /// Opens or focuses an automation run's workspace pane: a live pane for a running run, or the read-only
    /// transcript replay for an ended one. Live metadata resolves from the overview; replay uses the run
    /// summary's persisted original workspace so retargeting an automation never moves its history.
    func openAutomationRunTerminal(deviceID: String, run: TerminalServiceAutomationRunSummary) {
        guard let sessionID = run.terminalSessionID else {
            showError(Self.terminalSessionNotFoundError())
            return
        }
        let automation = automationSummary(deviceID: deviceID, automationID: run.automationID)
        let loginShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard
            let request = Self.automationRunTerminalOpenRequest(
                deviceID: deviceID, sessionID: sessionID, run: run, automation: automation, overview: deviceSection(id: deviceID)?.overview,
                loginShell: loginShell)
        else {
            showError(Self.terminalSessionNotFoundError())
            return
        }
        _ = panelCoordinator.openOrFocusTerminalPane(request, openIntent: .focused)
    }

    /// Opens an automation run's attributed coding-agent terminal session, device-qualified so a remote run's
    /// agent resolves on its own device. The agent runs in a workspace, so the request is resolved from that
    /// device's overview when the session is present (for the real shell/command/state) and synthesized
    /// otherwise. It opens or focuses a normal pane in the persisted workspace, matching the run's own
    /// terminal behavior.
    func openAutomationAgentSession(deviceID: String, agent: TerminalServiceAutomationAgentSummary) {
        let workspaceID = agent.workspaceID ?? ""
        let overview = deviceSection(id: deviceID)?.overview
        let loginShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let resolved = Self.deviceTerminalOpenRequest(workspaceID: workspaceID, sessionID: agent.terminalSessionID, overview: overview)
        let request = DeviceTerminalOpenRequest(
            workspaceID: resolved?.workspaceID ?? workspaceID, deviceID: deviceID, sessionID: agent.terminalSessionID,
            title: resolved?.title ?? agent.title ?? "Agent", workingDirectory: resolved?.workingDirectory ?? "", kind: resolved?.kind ?? .agent,
            shell: resolved?.shell ?? loginShell, command: resolved?.command,
            initialState: resolved?.initialState ?? (agent.live ? .running : .exited), servicePID: resolved?.servicePID, childPID: resolved?.childPID,
            createdAt: resolved?.createdAt, updatedAt: resolved?.updatedAt)
        _ = panelCoordinator.openOrFocusTerminalPane(request, openIntent: .focused)
    }

    /// One workspace the editor's Agent form can target, sourced from the sidebar's loaded overview model.
    struct AutomationWorkspaceChoice: Sendable, Equatable {
        let workspaceID: String
        /// "<project> / <workspace>" so the same branch name across projects stays distinguishable.
        let label: String
    }

    /// The workspaces available to an `agent`-kind automation on a device, read from the sidebar's already
    /// loaded project/workspace model (the same source the sidebar renders), so the editor adds no new fetch
    /// path. Ordered by the sidebar's project order, visible (non-archived, non-hidden) workspaces only.
    /// `preservingWorkspaceID` keeps an automation's stored target in the list even when that workspace has
    /// since been hidden (by its own flag or by its project's), so editing an unrelated field never silently
    /// retargets it (see
    /// `AutomationsViewModel.workspaceChoices`); the hidden target's real name is resolved through
    /// `findWorkspace`, which includes hidden workspaces.
    func automationWorkspaceChoices(deviceID: String, preservingWorkspaceID: String? = nil) -> [AutomationWorkspaceChoice] {
        let visible = deviceProjects(deviceID: deviceID).flatMap { project in
            visibleWorkspaces(projectID: project.id).map { workspace in
                AutomationsViewModel.WorkspaceChoice(workspaceID: workspace.id, label: "\(project.name) / \(workspace.displayName)")
            }
        }
        let merged = AutomationsViewModel.workspaceChoices(visible: visible, preservingWorkspaceID: preservingWorkspaceID) { workspaceID in
            guard let (project, workspace) = findWorkspace(id: workspaceID) else { return nil }
            return "\(project.name) / \(workspace.displayName)"
        }
        return merged.map { AutomationWorkspaceChoice(workspaceID: $0.workspaceID, label: $0.label) }
    }

    /// The status glyph name and tint for a settled (non-spinning) agent status. Single source of truth shared
    /// by `windowRow`'s indicator, the alerts rows built on it, and the automations run agent chips so agent
    /// state reads identically. The active states borrow `SidebarAttentionStatus.indicatorColor` so a dot never
    /// disagrees with the sidebar row for the same agent; the settled-neutral states stay label-gray.
    static func agentStatusSymbolAndColor(_ status: AgentWindowStatus) -> (symbol: String, color: NSColor) {
        switch status {
        case .waiting: ("exclamationmark.triangle.fill", SidebarAttentionStatus.blocked.indicatorColor)
        case .done: ("circle.fill", SidebarAttentionStatus.done.indicatorColor)
        // Agent gone, terminal alive: hollow dimmed dot, distinct from idle's filled dot.
        case .exited: ("circle", .tertiaryLabelColor)
        case .spinning, .idle: ("circle.fill", .tertiaryLabelColor)
        }
    }

    /// A compact agent status indicator — a spinner for a working agent, a tinted dot otherwise — matching the
    /// agent state shown in window rows. Reused by the automations runs tab's attributed-agent chips.
    static func agentStatusIndicator(_ status: AgentWindowStatus) -> NSView {
        if status == .spinning {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .mini
            spinner.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([spinner.widthAnchor.constraint(equalToConstant: 10), spinner.heightAnchor.constraint(equalToConstant: 10)])
            spinner.startAnimation(nil)
            return spinner
        }
        let (symbol, color) = agentStatusSymbolAndColor(status)
        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: status.rawValue)
        imageView.contentTintColor = color
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([imageView.widthAnchor.constraint(equalToConstant: 10), imageView.heightAnchor.constraint(equalToConstant: 10)])
        return imageView
    }

    private func makeRightPane() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        bindAppearanceReactiveLayer(container) { [weak self] view in view.layer?.backgroundColor = self?.sidebar.sidebarPanelBackgroundColor().cgColor }

        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.wantsLayer = true
        bindAppearanceReactiveLayer(detailContainer) { [weak self] view in view.layer?.backgroundColor = self?.sidebar.sidebarPanelBackgroundColor().cgColor }

        // The right panel's own footer strip: workspace details for the selected
        // workspace (populated by the detail paths), empty otherwise.
        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        footer.translatesAutoresizingMaskIntoConstraints = false
        workspaceDetailFooterRow = footer

        container.addSubview(detailContainer)
        container.addSubview(footerSeparator)
        container.addSubview(footer)
        NSLayoutConstraint.activate([
            detailContainer.topAnchor.constraint(equalTo: container.topAnchor),
            detailContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            detailContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            detailContainer.bottomAnchor.constraint(equalTo: footerSeparator.topAnchor),
            footerSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.topAnchor.constraint(equalTo: footerSeparator.bottomAnchor, constant: 2),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2), footer.heightAnchor.constraint(equalToConstant: 26),
        ])
        showPlaceholder()
        return container
    }

    func reloadData(forceRemoteRefresh: Bool = false, bypassesBackoff: Bool? = nil) {
        sidebar.requestSidebarReload(forceRemoteRefresh: forceRemoteRefresh, bypassesBackoff: bypassesBackoff)
    }

    // MARK: - Sidebar forwarders
    // Thin pass-throughs that keep widely-used sidebar entry points callable from
    // host code without rewiring dozens of call sites. The implementations live on
    // `sidebar` (SidebarController).
    func requestSidebarReload(failurePlaceholderMessage: String? = nil, forceRemoteRefresh: Bool = false, bypassesBackoff: Bool? = nil) {
        sidebar.requestSidebarReload(
            failurePlaceholderMessage: failurePlaceholderMessage, forceRemoteRefresh: forceRemoteRefresh, bypassesBackoff: bypassesBackoff)
    }
    func findWorkspace(id: String) -> (ProjectSummary, WorkspaceSummary)? { sidebar.findWorkspace(id: id) }
    func deviceRecord(forDeviceID deviceID: String) -> SpacesPairedDeviceRecord? { sidebar.deviceRecord(forDeviceID: deviceID) }
    func deviceSection(id deviceID: String) -> DeviceSection? { sidebar.deviceSection(id: deviceID) }
    /// The device label to render for `deviceID` wherever the New Project flow names a target device.
    /// Prefers the loaded section's `displayName` (so the local device reads "Local"); the fallback
    /// mirrors the old `?? localDeviceName` sites it replaces, which only ever missed a section for the
    /// local device, so it resolves to "Local" directly rather than the stored machine name.
    func deviceDisplayName(id deviceID: String) -> String { deviceSection(id: deviceID)?.displayName ?? "Local" }
    func visibleWorkspaces(projectID: String) -> [WorkspaceSummary] { sidebar.visibleWorkspaces(projectID: projectID) }
    func deviceProjects(deviceID: String) -> [ProjectSummary] { sidebar.deviceProjects(deviceID: deviceID) }
    func selectWorkspace(_ workspace: WorkspaceSummary) { sidebar.selectWorkspace(workspace) }
    func orderedSidebarWorkspaces() -> [WorkspaceSummary] { sidebar.orderedSidebarWorkspaces() }
    func navigateSidebarSelection(direction: Int) -> Bool { sidebar.navigateSidebarSelection(direction: direction) }
    func toggleProjectExpanded(projectID: String) { sidebar.toggleProjectExpanded(projectID: projectID) }
    func canPreserveDetailPaneAfterSidebarReload() -> Bool { sidebar.canPreserveDetailPaneAfterSidebarReload() }
    func rebuildFlatSidebarData() { sidebar.rebuildFlatSidebarData() }
    /// Rebuilds the whole outline for a change the row diff does not model; see the sidebar's own method.
    func fullReloadSidebarOutline() { sidebar.fullReloadSidebarOutline() }
    func updateAlertsSidebarBadge() { sidebar.updateAlertsSidebarBadge() }
    func updateAlertsRowAppearance() {
        sidebar.updateAlertsRowAppearance()
        // The Alerts and Automations rows share a mutually-exclusive selection highlight, so refresh both
        // whenever the detail pane changes.
        sidebar.updateAutomationsRowAppearance()
    }
    func refreshSidebarSelectionRows(previousProjectID: String?, currentProjectID: String?, previousWorkspaceID: String?, currentWorkspaceID: String?)
    {
        sidebar.refreshSidebarSelectionRows(
            previousProjectID: previousProjectID, currentProjectID: currentProjectID, previousWorkspaceID: previousWorkspaceID,
            currentWorkspaceID: currentWorkspaceID)
    }
    func startBackgroundServicesIfNeeded() {
        guard !didStartBackgroundServices else { return }
        didStartBackgroundServices = true
        sidebar.startRemoteOverviewSubscriptions()
    }

    nonisolated static func scheduleAfterNextRunLoopTurn(_ action: @escaping @MainActor () -> Void) {
        RunLoop.main.perform { Task { @MainActor in action() } }
    }

    /// Whether launch should block on the Chrome Automation permission screen. Spaces focuses
    /// browser sessions by scripting Chrome, so a denied or not-yet-decided grant blocks the main
    /// UI. An `unavailable` reading (Chrome not installed / permission unverifiable) does not block
    /// — there is nothing to grant — and a `granted` reading proceeds straight to the workspace UI.
    static func requiresChromeAutomationSetup(_ status: ChromeAutomationStatus) -> Bool {
        switch status {
        case .denied, .notDetermined: return true
        case .granted, .unavailable: return false
        }
    }

    /// Builds the main split-view content and kicks off the initial sidebar load. Shared by the
    /// normal launch path and the setup flow's completion handler.
    private func presentMainWorkspaceUI() {
        setupFlowController?.stop()
        setupFlowController = nil
        buildMainWindowContent()
        logStartupProfile("main_content_ready")
        showLoadingPlaceholder(message: "Loading projects and workspaces...", detail: "Spaces is preparing your workspace data.")
        logStartupProfile("loading_placeholder_ready")
        Task { @MainActor [weak self] in await self?.sidebar.loadInitialSidebarData() }
    }

    /// Presents the launch setup flow and advances to the workspace UI once its pending steps are
    /// done. The flow decides internally which steps are pending; when none are, it completes
    /// immediately and the user never sees it.
    private func enterSetupFlow() {
        logStartupProfile("setup_flow_started")
        setupFlowController?.stop()
        let controller = SetupFlowController(host: self, database: try? clientDatabase())
        setupFlowController = controller
        // Capture `controller` weakly: it owns `onComplete`, so a strong capture would retain the
        // controller (and its view hierarchy) past the point where `presentMainWorkspaceUI` clears
        // `setupFlowController`, leaking a setup controller each time the flow is shown.
        controller.onComplete = { [weak self, weak controller] in
            guard let self, let controller, self.setupFlowController === controller else { return }
            self.logStartupProfile("setup_flow_complete")
            self.presentMainWorkspaceUI()
        }
        // Install the setup content before starting the flow, never after: with no pending step the
        // flow completes inside `begin()`, and its completion handler makes the workspace UI the
        // window's content. Assigning here afterwards would cover it with an empty setup container.
        window.contentView = controller.view
        controller.begin()
    }

    /// Background-refresh failures are always logged rather than routed to the launch setup flow,
    /// which runs once before the workspace UI opens and never reopens over it. Retained so call
    /// sites that previously short-circuited on a deferred-setup requirement keep a single,
    /// explicit no-op.
    func handleDeferredSetupRequirementIfNeeded(_ error: Error) -> Bool {
        _ = error
        return false
    }

    static func backgroundRefreshFailureAction(for error: Error) -> BackgroundRefreshFailureAction {
        _ = error
        return .logOnly
    }

    func handleBackgroundRefreshFailure(_ error: Error, source: String) {
        switch Self.backgroundRefreshFailureAction(for: error) {
        case .deferredSetup: _ = handleDeferredSetupRequirementIfNeeded(error)
        case .logOnly: logBackgroundRefreshFailure(error, source: source)
        }
    }

    private func logBackgroundRefreshFailure(_ error: Error, source: String) {
        guard ProcessInfo.processInfo.environment["DEBUG"] == "1" else { return }
        fputs("spaces: background_refresh_failure source=\(source) error=\(String(describing: error))\n", stderr)
    }

    /// The id of the device that owns a workspace/project, or nil when no loaded device
    /// section contains that row. These give every action its per-row device context so it
    /// routes to the daemon that actually hosts the workspace. The miss is deliberately
    /// visible: an unresolved id means "we do not know which daemon owns this", which is
    /// never the same thing as "the local daemon owns this" — resolving it to the local
    /// device would run local endpoints, credentials, paths, and panel state against a
    /// row that lives on another machine.
    func deviceID(forWorkspaceID workspaceID: String) -> String? { findWorkspace(id: workspaceID)?.0.deviceID }

    // Not private: also used by `ProjectFormsController`'s add-workspace flow from a different file
    // in the same module (cross-file `private` isn't visible).
    func deviceID(forProjectID projectID: String) -> String? { deviceModel.projects.first(where: { $0.id == projectID })?.deviceID }

    /// Internal rather than `private`: `BrowserSessionCoordinator.workspaceServiceForwards` also needs
    /// this to decide whether a workspace's services can have a live SSH forward.
    func isRemoteDeviceID(_ deviceID: String) -> Bool {
        deviceSection(id: deviceID).map { !$0.isLocal } ?? (deviceID != SpacesPairedDeviceRecord.localDeviceID)
    }

    func isLocalWorkspace(_ workspace: WorkspaceSummary) -> Bool { workspace.deviceID == SpacesPairedDeviceRecord.localDeviceID }

    /// The device that owns the current selection, so mutations route to the
    /// daemon that actually hosts the selected workspace/project rather than
    /// always defaulting to the local device.
    // Not private: also used by `ProjectFormsController`'s project-settings save path from a
    // different file in the same module (cross-file `private` isn't visible).
    func selectedRowDeviceID() -> String? {
        if let selectedWorkspaceID, let (project, _) = findWorkspace(id: selectedWorkspaceID) { return project.deviceID }
        if let selectedProjectID, let project = deviceModel.projects.first(where: { $0.id == selectedProjectID }) { return project.deviceID }
        return nil
    }

    /// The device a selection-driven daemon action targets. With nothing selected the action
    /// belongs to this Mac, so the local id stands in and is gated like any other.
    func deviceForDaemonStateMutation() -> SpacesPairedDeviceRecord? {
        deviceForMutation(deviceID: selectedRowDeviceID() ?? SpacesPairedDeviceRecord.localDeviceID)
    }

    /// The paired-device record a device id names, whatever that device's load state is.
    /// Read paths must resolve the true owner even during an outage: falling through to the
    /// local record would dial this Mac for another machine's rows.
    private func deviceOwning(deviceID: String) -> SpacesPairedDeviceRecord? {
        if deviceID == SpacesPairedDeviceRecord.localDeviceID { return deviceModel.localPairedDevice }
        return deviceRecord(forDeviceID: deviceID)
    }

    /// Resolves the paired-device record for a mutation target by owning-device id, refusing any
    /// device that cannot service a daemon-backed action. An unreachable device keeps its section
    /// (and therefore its record) for the whole outage so its rows stay browsable, so resolution
    /// alone is not permission to act: this is the chokepoint where "browse, don't act" is enforced,
    /// and every caller surfaces the nil as an error rather than dialling a daemon that is not there.
    /// Nil therefore means either that no loaded section claims the id (unknown or still loading) or
    /// that its device is unreachable; `deviceUnavailableError` tells those two apart for the message.
    /// Internal rather than `private`: `TerminalPaneService.prepareTerminalPaneOpenRequest` and
    /// `TerminalPaneService.makeTerminalPaneContent` also need this to resolve a mutation target.
    func deviceForMutation(deviceID: String) -> SpacesPairedDeviceRecord? {
        guard Self.deviceAcceptsDaemonActions(deviceID: deviceID, loadState: deviceSection(id: deviceID)?.loadState) else { return nil }
        return deviceOwning(deviceID: deviceID)
    }

    /// The device that owns a specific workspace, so per-workspace mutations route
    /// to the daemon that actually hosts it rather than the currently selected
    /// row's device. Clicking a row button or invoking a context menu does not
    /// change the outline selection, so these actions must resolve their target
    /// from the workspace ID they carry, not the selection.
    func deviceForWorkspaceMutation(workspaceID: String) -> SpacesPairedDeviceRecord? {
        guard let deviceID = deviceID(forWorkspaceID: workspaceID) else { return nil }
        return deviceForMutation(deviceID: deviceID)
    }

    /// The device that owns a specific project, for the same reason as the workspace variant above:
    /// a project-scoped action carries its project id and must route by that, not by the selection.
    func deviceForProjectMutation(projectID: String) -> SpacesPairedDeviceRecord? {
        guard let deviceID = deviceID(forProjectID: projectID) else { return nil }
        return deviceForMutation(deviceID: deviceID)
    }

    /// Whether a device can service an action that needs its daemon, given the load state of the
    /// sidebar section that claims it — `nil` when no section claims it at all.
    ///
    /// An unreachable device's rows stay listed and readable, but everything behind them is refused
    /// up front instead of dialled and failed — the user browses the subtree and acts on it once the
    /// device returns. A section that has not finished loading is equally not actionable: its record
    /// may not be installed yet.
    ///
    /// "No section yet" is a different fact from "the device is offline", and the two ids part ways
    /// there. This Mac is actionable before any section exists: it is the machine the app is running
    /// on, its record comes from `bootstrapLocalDevice` rather than from a sidebar load, and an
    /// `openTerminalSessionWindow`/focus IPC routinely arrives on a cold launch before the first
    /// sidebar snapshot — refusing then would fail a pane open the app explicitly supports. A remote
    /// id that no section claims is genuinely unknown: nothing has told the app that device exists,
    /// so there is no daemon to dial and it stays refused. Pure so the rule is directly testable and
    /// so the refusing chokepoint and the controls that disable themselves ahead of it can never
    /// disagree.
    nonisolated static func deviceAcceptsDaemonActions(deviceID: String, loadState: SidebarDeviceLoadState?) -> Bool {
        guard let loadState else { return deviceID == SpacesPairedDeviceRecord.localDeviceID }
        return loadState == .loaded
    }

    /// Whether the daemon-backed controls for a workspace's row should be offered. An id no section
    /// claims has no daemon to act on either, so it reads as not actionable.
    func deviceAcceptsDaemonActions(forWorkspaceID workspaceID: String) -> Bool {
        deviceID(forWorkspaceID: workspaceID).map(deviceAcceptsDaemonActions(forDeviceID:)) ?? false
    }

    func deviceAcceptsDaemonActions(forDeviceID deviceID: String) -> Bool {
        Self.deviceAcceptsDaemonActions(deviceID: deviceID, loadState: deviceSection(id: deviceID)?.loadState)
    }

    /// Whether the daemon a pane for this request would attach to can service that attach. The
    /// request's pinned `deviceID` wins over the workspace lookup, matching
    /// `prepareTerminalPaneOpenRequest`: a cold-resolved or deep-linked request names its owning
    /// device directly, and its workspace may not be listed in the sidebar yet.
    func deviceAcceptsDaemonActions(forTerminalOpenRequest request: DeviceTerminalOpenRequest) -> Bool {
        guard let deviceID = request.deviceID ?? deviceID(forWorkspaceID: request.workspaceID) else { return false }
        return deviceAcceptsDaemonActions(forDeviceID: deviceID)
    }

    /// Whether a device crossing into or out of its actionable state must rebuild the workspace detail
    /// currently on screen. `disableWhenDeviceCannotAct` decides a control's availability while the
    /// detail is being built, so a retained pane keeps whatever it was built with: a device that goes
    /// offline underneath it would keep offering actions that are now refused, and one that comes back
    /// would keep withholding actions that work until the user reselected the row.
    ///
    /// Gated on an actual change in actionability, not on any load-state report: an unreachable device
    /// is re-reported with the same state on every probe for the whole outage, and rebuilding the
    /// detail each time would throw away the user's scroll position and focus repeatedly. A reason-only
    /// change (`.offline(a)` to `.offline(b)`) changes nothing a control does, so it does not qualify
    /// either. Pure so the "transition, not poll" rule is directly testable.
    nonisolated static func shouldRebuildWorkspaceDetailForDeviceLoadStateChange(
        visibleDetailWorkspaceDeviceID: String?, deviceID: String, previousLoadState: SidebarDeviceLoadState, newLoadState: SidebarDeviceLoadState
    ) -> Bool {
        guard visibleDetailWorkspaceDeviceID == deviceID else { return false }
        return deviceAcceptsDaemonActions(deviceID: deviceID, loadState: previousLoadState)
            != deviceAcceptsDaemonActions(deviceID: deviceID, loadState: newLoadState)
    }

    /// The device owning the workspace whose detail pane is on screen, or nil when the detail shows
    /// anything else. Read at the moment a device's load state moves, to decide whether that pane's
    /// daemon-backed controls are now wrong. Taken from the pane rather than from the sidebar data, so
    /// it still answers while that device's rows are missing — which is exactly when its load state
    /// moved.
    func visibleWorkspaceDetailDeviceID() -> String? { detailPane.workspaceDeviceID }

    /// The tooltip a control disabled by an outage carries, naming the device the way the sidebar rows
    /// and the add-project device picker do. Nil for any other state — a device that is merely still
    /// loading is not offline, so its controls keep their own tooltips rather than claiming an outage.
    func unreachableDeviceTooltip(forDeviceID deviceID: String) -> String? {
        guard let section = deviceSection(id: deviceID), section.loadState.isOffline else { return nil }
        return "\(section.displayName) is offline"
    }

    func unreachableDeviceTooltip(forWorkspaceID workspaceID: String) -> String? {
        deviceID(forWorkspaceID: workspaceID).flatMap(unreachableDeviceTooltip(forDeviceID:))
    }

    /// Internal rather than `private`: `TerminalPaneService.makeTerminalSessionStateModel` and
    /// `TerminalPaneService.makeTerminalPaneContent` also need this for a device lookup that fails
    /// for a reason other than a known offline section.
    static func deviceNotLoadedError() -> NSError {
        NSError(
            domain: "Spaces", code: 1001,
            userInfo: [
                NSLocalizedDescriptionKey: "Spaces has not finished loading.",
                NSLocalizedRecoverySuggestionErrorKey: "Wait for Spaces to load, or reload Spaces, and try again.",
            ])
    }

    /// Raised when an action needs a device's daemon and that device is unreachable. An outage leaves
    /// the device's rows on screen, so the refusal has to name the device and say it is offline; the
    /// not-loaded error would describe a state the user can plainly see they are not in.
    /// A remote device is recovered by reconnecting to it, but this Mac cannot be reconnected to
    /// itself — its daemon is simply not running, and Devices settings carries the action that
    /// relaunches it. Telling a user to reconnect their own Mac sends them looking for a control
    /// that does not exist.
    nonisolated static func deviceUnreachableError(deviceName: String, isLocal: Bool) -> NSError {
        NSError(
            domain: "Spaces", code: 1003,
            userInfo: [
                NSLocalizedDescriptionKey: "\(deviceName) is offline.",
                NSLocalizedRecoverySuggestionErrorKey: isLocal ? "Restart the local daemon and try again." : "Reconnect it and try again.",
            ])
    }

    /// The error for a device that cannot service a daemon-backed action, telling apart the two ways
    /// `deviceForMutation` refuses: an unreachable section names its device and says offline, while an
    /// id no section claims — or one whose section is still loading — is genuinely a not-loaded state.
    /// Internal rather than `private`: `TerminalPaneService.prepareTerminalPaneOpenRequest` also needs
    /// this to refuse an open whose owning device cannot service a daemon-backed attach.
    func deviceUnavailableError(deviceID: String?) -> NSError {
        guard let deviceID, let section = deviceSection(id: deviceID), section.loadState.isOffline else { return Self.deviceNotLoadedError() }
        return Self.deviceUnreachableError(deviceName: section.displayName, isLocal: section.isLocal)
    }

    /// Surfaces why a per-workspace daemon action could not resolve its device.
    func showWorkspaceDeviceUnavailableError(workspaceID: String) {
        showError(deviceUnavailableError(deviceID: deviceID(forWorkspaceID: workspaceID)))
    }

    /// Surfaces why a per-project daemon action could not resolve its device.
    func showProjectDeviceUnavailableError(projectID: String) { showError(deviceUnavailableError(deviceID: deviceID(forProjectID: projectID))) }

    /// Surfaces why a pane could not be opened for a terminal target, naming the device the request
    /// pinned rather than re-deriving it from a workspace the sidebar may not list.
    func showTerminalOpenRequestDeviceUnavailableError(_ request: DeviceTerminalOpenRequest, focusIntent: TerminalOpenFocusIntent) {
        terminalPanes.reportTerminalPaneOpenFailure(
            deviceUnavailableError(deviceID: request.deviceID ?? deviceID(forWorkspaceID: request.workspaceID)), focusIntent: focusIntent)
    }

    /// Surfaces why a selection-driven daemon action could not resolve its device.
    func showSelectedDeviceUnavailableError() {
        showError(deviceUnavailableError(deviceID: selectedRowDeviceID() ?? SpacesPairedDeviceRecord.localDeviceID))
    }

    /// Raised when a terminal window is opened by id but neither the caller nor a fresh
    /// device overview knows the session, so its real launch configuration cannot be read.
    /// Internal rather than `private`: `TerminalPaneService.makeTerminalSessionStateModel` also needs
    /// this when a session unknown to both the caller and a fresh overview lookup has no launch
    /// configuration to seed the state model with.
    static func terminalSessionNotFoundError() -> NSError {
        NSError(
            domain: "Spaces", code: 1002,
            userInfo: [
                NSLocalizedDescriptionKey: "That terminal session is no longer available.",
                NSLocalizedRecoverySuggestionErrorKey: "Reload Spaces and try again.",
            ])
    }

    func showDeviceNotLoadedError() { showError(Self.deviceNotLoadedError()) }

    // Not private: also used by `ProjectFormsController`'s project-settings dialog from a different
    // file in the same module (cross-file `private` isn't visible).
    func deviceProjectSummary(projectID: String) -> SpacesDeviceProjectSummary? {
        // Search every device section's overview, not just the local one, so detail
        // and config flows resolve projects that live on a remote device.
        for section in deviceModel.deviceSections { if let project = section.overview?.projects.first(where: { $0.id == projectID }) { return project } }
        return nil
    }

    func deviceWorkspaceSummary(workspaceID: String) -> SpacesDeviceWorkspaceSummary? {
        for section in deviceModel.deviceSections { if let workspace = section.overview?.workspaces.first(where: { $0.id == workspaceID }) { return workspace } }
        return nil
    }

    /// Hands each open pane whose runtime target just swapped sessions over to the replacement, before
    /// pruning would close it for naming a session the device no longer retains.
    ///
    /// This is the client half of restart pane reuse. The daemon serving the restart is the Device API's,
    /// which has no opener to any client, so the replacement's open — the message that normally names the
    /// pane to take over — is never posted; the refreshed overview carries the same pairing. Runs on every
    /// authoritative overview, from all three of its call sites, since a restart on one client has to move
    /// the pane on every other client watching that device.
    func retargetReplacedTerminalPanes(previousOverview: SpacesDeviceOverviewPayload?, overview: SpacesDeviceOverviewPayload, deviceID: String) {
        for replacement in TerminalSessionReplacementDiff.replacements(previous: previousOverview, current: overview) {
            // An overview is authoritative only for its own device. A workspace the sidebar attributes
            // elsewhere is one this overview has no standing to move panes for.
            guard self.deviceID(forWorkspaceID: replacement.workspaceID) == deviceID,
                let request = paneOpenRequest(workspaceID: replacement.workspaceID, sessionID: replacement.replacementSessionID)
            else { continue }
            panelCoordinator.retargetPaneForReplacement(replacedSessionID: replacement.replacedSessionID, request: request)
        }
    }

    /// Every overview-install path calls this before it discards the prior workspace catalog. The
    /// overview is the authority for whether an Editor recovery document still has a workspace to
    /// belong to; this shared reconciliation also fences any queued write that has not reached SQLite.
    func removeCodePaneRecoveryStateForDeletedWorkspaces(deviceID: String, liveWorkspaceIDs: Set<String>, previousWorkspaceIDs: Set<String>) {
        guard let database = try? clientDatabase() else { return }
        let storageKey = ClientCodePaneWorkspaceStateStorage.storageKey(deviceID: deviceID)
        CodePaneWorkspaceStateCache.deleteStateForMissingWorkspaces(
            storageKey: storageKey, liveWorkspaceIDs: liveWorkspaceIDs, previousWorkspaceIDs: previousWorkspaceIDs,
            persistedWorkspaceIDs: { (try? database.codePaneWorkspaceIDs(deviceID: deviceID)) ?? [] },
            delete: { workspaceID in try? database.deleteCodePaneWorkspaceState(deviceID: deviceID, workspaceID: workspaceID) })
    }

    private func applyDeviceOverview(
        _ overview: SpacesDeviceOverviewPayload, deviceID: String, epoch: Int, selectedProjectID preferredProjectID: String? = nil,
        selectedWorkspaceID preferredWorkspaceID: String? = nil, preserveDetailPane: Bool = false
    ) {
        let shouldPreserveDetailPane = preserveDetailPane && canPreserveDetailPaneAfterSidebarReload()
        // The mutation's overview belongs to the device that issued it (`deviceID`, threaded from the
        // call site). Update only that device's section and re-merge so the other devices' rows stay
        // intact. The originating device is passed explicitly rather than inferred from the current
        // selection: a mutation that clears the selection (e.g. a remote project delete) would
        // otherwise fall through to the local device and install a remote overview — and its
        // pane-prune keep-set — into the local section.
        // Captured before the section is overwritten: the pairing between an ended session and the one
        // that replaced it exists only in the difference between these two overviews.
        if deviceID == SpacesPairedDeviceRecord.localDeviceID { deviceModel.localOverviewInstallGeneration += 1 }
        let previousOverview = deviceSection(id: deviceID)?.overview
        let liveWorkspaceIDs = Set(overview.workspaces.map(\.id))
        removeCodePaneRecoveryStateForDeletedWorkspaces(
            deviceID: deviceID, liveWorkspaceIDs: liveWorkspaceIDs, previousWorkspaceIDs: Set(previousOverview?.workspaces.map(\.id) ?? []))
        let collapseStates = (try? SpacesClientDatabase.defaultDatabase().projectCollapseStates(deviceID: deviceID)) ?? [:]
        if let index = deviceModel.deviceSections.firstIndex(where: { $0.deviceID == deviceID }) {
            let content = DeviceSectionContent.derive(
                from: overview, deviceID: deviceID, deviceName: deviceModel.deviceSections[index].deviceName, projectCollapseStates: collapseStates)
            deviceModel.deviceSections[index].projects = content.projects
            deviceModel.deviceSections[index].workspacesByProject = content.workspacesByProject
            deviceModel.deviceSections[index].workspaceRuntimeStatusByID = content.workspaceRuntimeStatusByID
            deviceModel.deviceSections[index].overview = overview
            // Rebuild for every section, not just local: this overview is authoritative for `deviceID`
            // regardless of origin, and alerts groups carry visibility (`isFromHiddenWorkspace`), so a
            // remote mutation response must refresh them too or the alerts pane/badge/palette show stale
            // visibility until the next remote push (which already rebuilds via `applyRemoteDeviceSection`).
            deviceModel.deviceSections[index].alertsGroups = content.alertsGroups
        }
        // A mutation can change what the palette may list (a hide/unhide changes row visibility), and a
        // remote mutation never touches the local database, so no snapshot reload arrives to invalidate
        // the palette's cached items (`applySidebarDataSnapshot` covers only local changes). Invalidate
        // here so the next palette open rebuilds from this overview.
        commandPalette.invalidateCommandPaletteCache()
        retargetReplacedTerminalPanes(previousOverview: previousOverview, overview: overview, deviceID: deviceID)
        // This is an authoritative overview for `deviceID`: close any open pane whose session it no
        // longer retains (its product row was removed, possibly from another device), so the pane cannot
        // outlive the daemon's transcript garbage-collection. The keep-set is the daemon's own published
        // retention rule (`overview.retainedTerminalSessionIDs`), so an ended session still held by any
        // product row — including a `runtime_targets` row after its shell exits — stays open for scrollback.
        //
        // Pruning is skipped when `epoch` (captured by the caller before this mutation's daemon dispatch,
        // not here) predates a pane replacement: the response this overview came from was requested before
        // the replacement claimed its pane, so this keep-set cannot name the replacement session and
        // pruning against it would close the pane that was just claimed. The retarget above runs
        // unconditionally regardless, since it is safe on stale data (see the local/remote apply sites in
        // `SidebarController` for the full reasoning) and dropping it would permanently lose a pairing this
        // overview was the only carrier of. The activity that bumped the epoch also changed the daemon's
        // own state, so the next overview (mutation response, poll, or push) prunes normally, which is
        // what makes a skipped prune self-heal rather than need a retry of its own.
        if epoch == panelCoordinator.paneReplacementEpoch {
            panelCoordinator.pruneOpenPanes(deviceID: deviceID, catalogSessionIDs: OpenPanePruning.referencedTerminalSessionIDs(overview: overview))
        }
        // Unlike the terminal prune above, this runs unconditionally (see the local/remote apply sites
        // in `SidebarController` for the full reasoning): a code pane has no session for a
        // pane-replacement race to protect, so gating this on the same epoch would let a workspace
        // deletion this mutation response reports go unpruned indefinitely whenever it lands mid-race —
        // there is no guaranteed follow-up overview the way the terminal prune's self-heal relies on.
        // The keep-set is workspace ids from this overview: a workspace absent from `overview.workspaces`
        // was deleted, not merely hidden (a hidden workspace stays listed with `isHidden` set). A
        // reported orphaned global pane (the Editor pointed at the just-deleted workspace) is retargeted
        // or closed right after, rather than left stranded pointing at nothing.
        if let orphan = panelCoordinator.pruneOpenCodePanes(deviceID: deviceID, liveWorkspaceIDs: Set(overview.workspaces.map(\.id))) {
            resolveOrphanedGlobalEditorPane(excluding: orphan.workspaceID)
        }
        // Same overview this device's prune just consumed carries this device's agent rows too, so a
        // code pane's assigned-agent dropdown stays current with whatever just spawned/exited.
        panelCoordinator.updateCodePaneAgents(deviceID: deviceID, hosting: self)
        if deviceID != deviceModel.localDeviceID, let device = deviceRecord(forDeviceID: deviceID) {
            browserSessions.reconcileRemoteBrowserForwards(device: device, overview: overview)
        }
        rebuildFlatSidebarData()
        if let preferredWorkspaceID, findWorkspace(id: preferredWorkspaceID) != nil {
            selectedWorkspaceID = preferredWorkspaceID
            Self.setClientActiveWorkspaceID(preferredWorkspaceID)
            selectedProjectID = findWorkspace(id: preferredWorkspaceID)?.0.id ?? preferredProjectID
        } else if let preferredProjectID, deviceModel.projects.contains(where: { $0.id == preferredProjectID }) {
            selectedProjectID = preferredProjectID
            selectedWorkspaceID = nil
        }
        fullReloadSidebarOutline()
        if !shouldPreserveDetailPane { refreshSelection() }
        updateAlertsSidebarBadge()
        if showingAlerts { alerts.showAlertsDetail() }
        if showingAutomations { showAutomationsDetail() }
    }

    /// `epoch` is `panelCoordinator.paneReplacementEpoch` as the caller read it before dispatching the
    /// mutation to the daemon (an `await Self.deviceMutation` detaches; a plain `try SpacesDeviceClient...`
    /// call is synchronous on the main actor and cannot race a claim, so its callers capture immediately
    /// before the call rather than earlier). Threaded to `applyDeviceOverview` so a claim that lands while
    /// the request is in flight fences only that apply's prune, matching the pull/push path's
    /// `capturedEpoch`/`epoch` (see `SidebarController.startRemoteOverviewPull` and
    /// `applyRemoteDeviceSection`).
    func applyDeviceMutationResponse(
        _ response: SpacesDeviceAPIResponse, deviceID: String, epoch: Int, selectedProjectID preferredProjectID: String? = nil,
        selectedWorkspaceID preferredWorkspaceID: String? = nil
    ) {
        if let overview = response.overview {
            applyDeviceOverview(
                overview, deviceID: deviceID, epoch: epoch, selectedProjectID: preferredProjectID, selectedWorkspaceID: preferredWorkspaceID,
                preserveDetailPane: false)
        } else {
            if let preferredWorkspaceID { selectedWorkspaceID = preferredWorkspaceID }
            if let preferredWorkspaceID { Self.setClientActiveWorkspaceID(preferredWorkspaceID) }
            if let preferredProjectID { selectedProjectID = preferredProjectID }
            requestSidebarReload()
        }
    }

    func updateDeviceWorkspaceConfig(workspaceID: String, update: (inout WorkspaceSettings) -> Void) throws {
        // Route to the daemon that owns this workspace, not the current sidebar
        // selection: free-standing surfaces (the workspace settings dialog) can outlive
        // a selection change, and misrouting would hit the wrong daemon or fail to find
        // the workspace.
        guard let device = deviceForWorkspaceMutation(workspaceID: workspaceID) else {
            throw deviceUnavailableError(deviceID: deviceID(forWorkspaceID: workspaceID))
        }
        guard let workspace = deviceWorkspaceSummary(workspaceID: workspaceID) else {
            throw WorkspaceError.invalidArgument(message: "Workspace not found.")
        }
        var settings = Self.localWorkspaceSettings(from: workspace.config)
        update(&settings)
        // No `await` between this capture and the apply below (this call is a synchronous, main-actor
        // `try`, not a detached `deviceMutation`), so no claim can land in between.
        let epoch = panelCoordinator.paneReplacementEpoch
        let response = try SpacesDeviceClient.updateWorkspaceConfig(
            workspaceID: workspaceID,
            config: Self.deviceWorkspaceConfig(from: settings, resolvedBrowserSessions: workspace.config.resolvedBrowserSessions),
            context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
        applyDeviceMutationResponse(response, deviceID: device.id, epoch: epoch, selectedWorkspaceID: workspaceID)
    }

    /// Re-resolves the detail pane from the current selection after device data changed. This is
    /// reconciliation, never navigation: reloads are event-driven (a bell, an agent event, a poll), so a
    /// pass that resolves nothing must leave the user where they are rather than move them. Alerts is
    /// reached only from what the user reaches for — the sidebar's Alerts row, its shortcut, leader
    /// navigation past the first workspace — and from the launch landing in `loadInitialSidebarData`,
    /// which is why it is presented here only when it is already the pane on screen.
    func refreshSelection() {
        if showingAlerts {
            alerts.showAlertsDetail()
            return
        }
        if showingAutomations {
            showAutomationsDetail()
            return
        }
        if let selectedWorkspaceID {
            // A selection that resolves but is no longer effectively visible — its own flag or its
            // project's was set by another client and arrived through an overview refresh — falls
            // through to the drop logic below, the same as one that no longer resolves: the sidebar has
            // no row for it, so re-showing its detail would resurrect a pane with nothing behind it.
            // Outage retention is unaffected: an offline device's retained rows keep their last live
            // flags, so nothing reads as hidden merely because its device stopped answering.
            if let (project, workspace) = findWorkspace(id: selectedWorkspaceID), SidebarVisibility.isVisibleWorkspace(workspace, inProject: project)
            {
                showWorkspaceDetail(project: project, workspace: workspace)
                return
            }
        }
        // With nothing else selected, surface a compatibility block so the user can act on it: the
        // remote device whose block was opened from its caption button (which has no workspace to
        // select), otherwise the local daemon if it is incompatible.
        if let blockDeviceID = visibleCompatibilityBlockDeviceID, let verdict = deviceCompatibility(forDeviceID: blockDeviceID), !verdict.isCompatible
        {
            showCompatibilityBlock(deviceID: blockDeviceID, verdict: verdict)
            return
        }
        if let verdict = deviceCompatibility(forDeviceID: deviceModel.localDeviceID), !verdict.isCompatible {
            showCompatibilityBlock(deviceID: deviceModel.localDeviceID, verdict: verdict)
            return
        }
        let paneDeviceID = detailPane.workspaceDeviceID
        guard
            Self.unresolvedSelectionDropsWorkspacePane(
                pane: detailPane, hasSelectedWorkspace: selectedWorkspaceID != nil,
                paneDeviceLoadState: paneDeviceID.flatMap { deviceSection(id: $0)?.loadState },
                paneDeviceCompatibility: paneDeviceID.flatMap { deviceCompatibility(forDeviceID: $0) })
        else { return }
        // The selection goes with the pane. Left pointing at a workspace nothing lists, it would fail to
        // resolve on every later reload and rebuild this placeholder each time. The outline's own
        // selection goes too: when the row still exists (a pending deletion the daemon later rejects),
        // a row left visually selected would swallow the next click on it — an already-selected row
        // emits no selection change — leaving this placeholder stuck until some other row is selected.
        let previousProjectID = selectedProjectID
        let previousWorkspaceID = selectedWorkspaceID
        selectedProjectID = nil
        selectedWorkspaceID = nil
        // Suppressed so the outline delegate does not classify this programmatic deselection as the user
        // clicking empty space — its no-selection branch presents as `.userNavigation`, which would close
        // an open form window over a background reload.
        suppressOutlineSelectionChanges = true
        outlineView.deselectAll(nil)
        suppressOutlineSelectionChanges = false
        refreshSidebarSelectionRows(
            previousProjectID: previousProjectID, currentProjectID: nil, previousWorkspaceID: previousWorkspaceID, currentWorkspaceID: nil)
        showPlaceholder()
    }

    /// Whether a reconcile that resolved no selection has to take down the workspace pane on screen.
    /// Everything else is left alone — reconciliation does not navigate — so this decides the one case
    /// that cannot be left: a workspace pane with nothing behind it.
    ///
    /// It comes down twice. `hasSelectedWorkspace == false` means the selection was cleared deliberately
    /// (the user clicked empty space, or collapsed the project holding the selected workspace), so the
    /// pane has no reason left to be there. With a selection that failed to resolve, the owning device
    /// decides: an offline or wire-incompatible daemon answers with an empty placeholder overview, so
    /// its rows vanishing during a restart is not evidence of a deletion and tearing a focused terminal
    /// out of the container over it would be wrong. Only a device that is answering and wire-compatible
    /// — the same authority rule that gates pane pruning — is believed when it stops listing a
    /// workspace, and a device gone from the sidebar entirely can never bring one back.
    nonisolated static func unresolvedSelectionDropsWorkspacePane(
        pane: DetailPane, hasSelectedWorkspace: Bool, paneDeviceLoadState: SidebarDeviceLoadState?, paneDeviceCompatibility: SpacesWireCompatibility?
    ) -> Bool {
        guard pane.workspaceID != nil else { return false }
        guard hasSelectedWorkspace else { return true }
        guard let paneDeviceLoadState else { return true }
        return localSnapshotAuthorizesPanePrune(loadState: paneDeviceLoadState, compatibility: paneDeviceCompatibility)
    }

    /// Setup progress is polled back from the owning daemon, and an unreachable device's rows stay
    /// listed for the whole outage, so the timer runs only while that device can service the poll —
    /// the same predicate that decides whether its actions are offered at all.
    private func startWorkspaceSetupDetailRefreshTimerIfNeeded(workspaceID: String) {
        guard deviceAcceptsDaemonActions(forWorkspaceID: workspaceID) else {
            stopWorkspaceSetupDetailRefreshTimer()
            return
        }
        if workspaceSetupDetailRefreshWorkspaceID == workspaceID, workspaceSetupDetailRefreshTimer != nil { return }
        stopWorkspaceSetupDetailRefreshTimer()
        workspaceSetupDetailRefreshWorkspaceID = workspaceID
        workspaceSetupDetailRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshWorkspaceSetupDetailIfVisible(workspaceID: workspaceID) }
        }
    }

    func stopWorkspaceSetupDetailRefreshTimer() {
        workspaceSetupDetailRefreshTimer?.invalidate()
        workspaceSetupDetailRefreshTimer = nil
        workspaceSetupDetailRefreshWorkspaceID = nil
    }

    private func refreshWorkspaceSetupDetailIfVisible(workspaceID: String) {
        guard selectedWorkspaceID == workspaceID, !showingAlerts, !showingSettings, findWorkspace(id: workspaceID) != nil,
            deviceAcceptsDaemonActions(forWorkspaceID: workspaceID)
        else {
            stopWorkspaceSetupDetailRefreshTimer()
            return
        }
        guard deviceForDaemonStateMutation() != nil else {
            stopWorkspaceSetupDetailRefreshTimer()
            showSelectedDeviceUnavailableError()
            return
        }
        // Live setup progress for a remote workspace must bypass the remote overview
        // freshness gate, or its logs/status/completion update only at the metadata
        // interval. A local setup needs no forced remote fetch. This poll is not the
        // user asking for any specific device, so it must never clear a device's
        // failure backoff — it repeats every 0.75s for the whole duration of the setup,
        // and clearing backoff on every tick would redial every unrelated offline
        // device that fast, defeating the backoff entirely (see `startRemoteOverviewPull`).
        requestSidebarReload(forceRemoteRefresh: deviceID(forWorkspaceID: workspaceID).map(isRemoteDeviceID) == true, bypassesBackoff: false)
    }

    /// Records which single content the detail pane is showing. The `show*` methods render the pane;
    /// switching away from a workspace also clears the workspace-only titlebar tab strip, and the user
    /// navigating to different content dismisses the free-standing add/settings form windows.
    func presentDetailPane(_ pane: DetailPane, presentation: DetailPanePresentation = .backgroundRefresh) {
        if Self.detailPanePresentationDismissesFormWindows(current: detailPane, presented: pane, presentation: presentation) {
            projectForms.clearActiveAddFormStateAndCloseWindows()
        }
        detailPane = pane
        if pane.workspaceID == nil { hideWorkspacePanelTabStrip() }
        if pane.compatibilityBlockDeviceID == nil { visibleCompatibilityBlockRemedy = nil }
        // Whatever pane replaces alerts takes its views out of the detail container, so what the alerts
        // pane was rendered from stops describing anything on screen and must not be reused to skip a
        // later render.
        if !pane.isAlerts { alerts.invalidateRenderedAlertsDetail() }
    }

    /// Whether this presentation dismisses the open New Project / New Workspace / project settings
    /// windows. Both conditions are required: the user has to be the one asking for a different pane
    /// (`DetailPanePresentation`), and the pane has to actually move out from under the form.
    ///
    /// A background refresh never dismisses, however much it changes — inferring intent from the
    /// content alone would close a form on a device turning wire-incompatible, on its recovery, on a
    /// failed reload's error placeholder, and on the selected workspace being deleted elsewhere. Nor
    /// does re-presenting the same content on a user action: clicking the Alerts row while Alerts is
    /// already showing moves nothing.
    nonisolated static func detailPanePresentationDismissesFormWindows(
        current: DetailPane, presented: DetailPane, presentation: DetailPanePresentation
    ) -> Bool {
        guard presentation == .userNavigation else { return false }
        return presented != current
    }

    private func hideWorkspacePanelTabStrip() {
        panelTabStripView.releaseTabBar()
        panelTabStripView.isHidden = true
        panelTabStripAccessory.isHidden = true
    }

    private func showWorkspacePanelTabStrip() {
        panelTabStripView.isHidden = false
        panelTabStripAccessory.isHidden = false
    }

    private var usesContentWorkspacePanelTabStrip: Bool { mainWindowIsFullScreen || window?.styleMask.contains(.fullScreen) == true }

    private func visibleWorkspacePanelView() -> WorkspacePanelView? {
        guard visibleDetailWorkspaceID != nil else { return nil }
        return detailContainer.subviews.compactMap { $0 as? WorkspacePanelView }.first
    }

    private func showWorkspacePanelTabStrip(for panelView: WorkspacePanelView) {
        if usesContentWorkspacePanelTabStrip {
            panelTabStripView.releaseTabBar()
            panelTabStripView.isHidden = true
            panelTabStripAccessory.isHidden = true
            panelView.useBuiltInTabBar()
        } else {
            panelView.adoptExternalTabBar(panelTabStripView.tabBar)
            showWorkspacePanelTabStrip()
        }
    }

    private func updateVisibleWorkspacePanelTabStripPresentation() {
        guard let panelView = visibleWorkspacePanelView() else {
            hideWorkspacePanelTabStrip()
            return
        }
        showWorkspacePanelTabStrip(for: panelView)
        panelTabStripView.sidebarWidth = splitView?.arrangedSubviews.first?.frame.width ?? panelTabStripView.sidebarWidth
    }

    func showPlaceholder(message: String = "Select a project or workspace.", presentation: DetailPanePresentation = .backgroundRefresh) {
        stopWorkspaceSetupDetailRefreshTimer()
        presentDetailPane(.none, presentation: presentation)
        showingSettings = false
        updateAlertsRowAppearance()
        shortcuts.activeShortcutCaptureSetting = nil
        clearWorkspaceDetailFooter()
        for view in detailContainer.subviews { view.removeFromSuperview() }
        let placeholder = NSTextField(labelWithString: message)
        placeholder.font = Typography.emptyStateTitle
        placeholder.textColor = .secondaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: detailContainer.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: detailContainer.centerYAnchor),
        ])
    }

    /// Wire-protocol verdict for a device section, or `nil` if the device hasn't been handshaken yet.
    func deviceCompatibility(forDeviceID deviceID: String) -> SpacesWireCompatibility? { deviceSection(id: deviceID)?.compatibility }

    func deviceDaemonStatus(forDeviceID deviceID: String) -> TerminalServiceDaemonStatus? { deviceSection(id: deviceID)?.daemonStatus }

    /// Whether a device needing `remedy` gets a block at all. The block is the surface for a device the
    /// app cannot use, so every remedy that only arises from an incompatible verdict is always shown.
    ///
    /// `.applyStagedUpdate` is the one remedy a compatible device can carry, and it takes both conditions
    /// to render. Spaces applies a staged update by itself the moment it sees it
    /// (`maybeRequestSilentDaemonHandoff`) and the device comes back on the new build seconds later, so
    /// blocking the pane on it would report work already under way — the block appears only once that
    /// request has demonstrably not landed. Even then it is withheld from a compatible device: everything
    /// on that device still works, and a full-pane block is reserved for a device that is genuinely
    /// blocked. There, the one dialog is the whole surface and the sidebar's "update pending" caption
    /// remains, still true.
    nonisolated static func shouldRenderCompatibilityBlock(
        remedy: CompatibilityBlockView.BlockRemedy, verdictIsCompatible: Bool, stagedApplyDidNotLand: Bool
    ) -> Bool {
        if case .applyStagedUpdate = remedy { return stagedApplyDidNotLand && !verdictIsCompatible }
        return true
    }

    /// Renders the full-pane compatibility block for a device that needs one, with the guidance or
    /// action its remedy calls for. Switching to a compatible device in the sidebar leaves it.
    func showCompatibilityBlock(deviceID: String, verdict: SpacesWireCompatibility, presentation: DetailPanePresentation = .backgroundRefresh) {
        let status = deviceDaemonStatus(forDeviceID: deviceID)
        guard let remedy = CompatibilityBlockView.blockRemedy(verdict: verdict, status: status),
            Self.shouldRenderCompatibilityBlock(
                remedy: remedy, verdictIsCompatible: verdict.isCompatible,
                stagedApplyDidNotLand: daemonUpdate.stagedApplyDidNotLand(deviceID: deviceID, status: status))
        else {
            // A device with no remedy — or one whose staged update needs no blocking surface — needs no
            // block, so leave the detail pane exactly as it is rather than clearing it out for a
            // surface that would have nothing to say.
            return
        }
        visibleCompatibilityBlockRemedy = remedy

        stopWorkspaceSetupDetailRefreshTimer()
        presentDetailPane(.compatibilityBlock(deviceID: deviceID), presentation: presentation)
        showingSettings = false
        updateAlertsRowAppearance()
        shortcuts.activeShortcutCaptureSetting = nil
        // Clear any prior workspace/project selection so refreshSelection and shortcuts target the block,
        // not the previously-selected workspace. Suppress the change handler so deselecting does not run
        // showPlaceholder() and replace the block we are about to render.
        let previousProjectID = selectedProjectID
        let previousWorkspaceID = selectedWorkspaceID
        selectedProjectID = nil
        selectedWorkspaceID = nil
        suppressOutlineSelectionChanges = true
        outlineView.deselectAll(nil)
        suppressOutlineSelectionChanges = false
        refreshSidebarSelectionRows(
            previousProjectID: previousProjectID, currentProjectID: nil, previousWorkspaceID: previousWorkspaceID, currentWorkspaceID: nil)
        clearWorkspaceDetailFooter()
        for view in detailContainer.subviews { view.removeFromSuperview() }

        let isLocalDevice = deviceID == SpacesPairedDeviceRecord.localDeviceID
        let offersCheckForUpdates = Self.shouldOfferCheckForUpdatesAction(isLocalDevice: isLocalDevice, updaterAvailable: updaterController != nil)
        let canUpdateOverSSH = Self.shouldOfferUpdateOverSSH(
            isLocalDevice: isLocalDevice, isLinuxDaemon: status?.isLinuxDaemon == true,
            hasSSHDetails: Self.hasSSHDetails(deviceRecord(forDeviceID: deviceID)))
        let block = CompatibilityBlockView(
            remedy: remedy, deviceName: deviceSection(id: deviceID)?.deviceName ?? deviceID, isLocalDevice: isLocalDevice,
            isLinuxDaemon: status?.isLinuxDaemon == true, canUpdateOverSSH: canUpdateOverSSH,
            isUpdatingOverSSH: daemonUpdate.daemonSSHUpdateInProgressDeviceIDs.contains(deviceID),
            onRetryStagedApply: remedy.offersStagedApplyRetry ? { [weak self] in self?.daemonUpdate.retryStagedApply(deviceID: deviceID) } : nil,
            onCheckForUpdates: offersCheckForUpdates ? { [weak self] in self?.updaterController?.checkForUpdates(nil) } : nil,
            onUpdateOverSSH: canUpdateOverSSH ? { [weak self] in self?.daemonUpdate.updateRemoteDaemonOverSSH(deviceID: deviceID) } : nil)
        block.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(block)
        NSLayoutConstraint.activate([
            block.centerXAnchor.constraint(equalTo: detailContainer.centerXAnchor),
            block.centerYAnchor.constraint(equalTo: detailContainer.centerYAnchor),
            block.leadingAnchor.constraint(greaterThanOrEqualTo: detailContainer.leadingAnchor, constant: 24),
            block.trailingAnchor.constraint(lessThanOrEqualTo: detailContainer.trailingAnchor, constant: -24),
            block.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])
    }

    /// Pure eligibility for the compatibility block's "Check for Updates…" action, factored out so it's
    /// testable without AppKit or a Sparkle instance. It is offered only for this Mac's own daemon — a
    /// remote device's Spaces install can't be checked/updated from here — and only when Sparkle has an
    /// updater to drive (a dev build launched outside an app bundle has none; see `updaterController`).
    nonisolated static func shouldOfferCheckForUpdatesAction(isLocalDevice: Bool, updaterAvailable: Bool) -> Bool {
        isLocalDevice && updaterAvailable
    }

    /// Pure eligibility for the compatibility block's "Update over SSH" action. Linux only: a Mac has no
    /// headless installer artifact to run, and a remote Mac's staged update already applies over the
    /// Device API. It needs a device the client can actually reach over SSH, which a link-paired record
    /// (no stored `sshHost`) cannot promise, and it is never offered for this Mac's own daemon.
    nonisolated static func shouldOfferUpdateOverSSH(isLocalDevice: Bool, isLinuxDaemon: Bool, hasSSHDetails: Bool) -> Bool {
        !isLocalDevice && isLinuxDaemon && hasSSHDetails
    }

    /// Whether a paired-device record carries an SSH host to run the installer against.
    nonisolated static func hasSSHDetails(_ device: SpacesPairedDeviceRecord?) -> Bool {
        guard let host = device?.sshHost else { return false }
        return !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func showLoadingPlaceholder(message: String, detail: String?) {
        stopWorkspaceSetupDetailRefreshTimer()
        // A visible compatibility block survives the loading placeholder: the reload behind this loading
        // state re-resolves back to the block. Only a workspace or alerts pane is cleared.
        if case .compatibilityBlock = detailPane {} else { presentDetailPane(.none) }
        showingSettings = false
        updateAlertsRowAppearance()
        shortcuts.activeShortcutCaptureSetting = nil
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
        title.font = Typography.emptyStateTitle
        title.textColor = .labelColor
        stack.addArrangedSubview(title)

        if let detail, !detail.isEmpty {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = Typography.rowDetail
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

    // MARK: - Transient overlays forwarders
    // Thin pass-throughs for the operation-progress HUD and window-issue toast/modal.
    // The implementations live on `overlays` (TransientOverlaysController).
    func showOperationProgressOverlay(message: String, detail: String, context: TransientOverlaysController.OperationProgressContext) {
        overlays.showOperationProgressOverlay(message: message, detail: detail, context: context)
    }
    func hideOperationProgressOverlay() { overlays.hideOperationProgressOverlay() }
    func showWindowIssueToast(title: String, detail: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        overlays.showWindowIssueToast(title: title, detail: detail, actionTitle: actionTitle, action: action)
    }
    func showWindowIssueModal(title: String, detail: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        overlays.showWindowIssueModal(title: title, detail: detail, actionTitle: actionTitle, action: action)
    }
    func writeWindowIssueModalAck(to outputPath: String) { overlays.writeWindowIssueModalAck(to: outputPath) }

    enum SettingsSection: String, CaseIterable {
        case general
        case shortcuts
        case devices
        case codingAgents
        case mcp

        var title: String {
            switch self {
            case .general: "General"
            case .shortcuts: "Shortcuts"
            case .devices: "Devices"
            case .codingAgents: "Coding Agents"
            case .mcp: "MCP"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .shortcuts: "keyboard"
            case .devices: "desktopcomputer.and.macbook"
            case .codingAgents: "chevron.left.forwardslash.chevron.right"
            case .mcp: "puzzlepiece.extension"
            }
        }
    }

    func settingsHairlineDivider() -> NSView {
        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        bindAppearanceReactiveLayer(divider) { [weak self] view in
            view.layer?.backgroundColor = self?.sidebar.sidebarCardBorderColor(isSelected: false).cgColor
        }
        return divider
    }

    @objc func closeSettingsWindow() { settings.closeSettingsWindow() }

    /// Closing the main window (the red traffic-light button, or a programmatic `performClose`) hides it
    /// instead of tearing it down: Spaces keeps running with its hotkeys, panel windows, and background
    /// services, and `applicationShouldHandleReopen` brings the same window back. Every other window this
    /// controller is delegate for (add-project/add-workspace/project-settings/workspace-settings/settings)
    /// keeps AppKit's normal close behavior; their cleanup lives in `windowWillClose` above.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window else { return true }
        window.orderOut(nil)
        return false
    }

    public func windowWillClose(_ notification: Notification) {
        let closingWindow = notification.object as? NSWindow
        if projectForms.handleWindowWillClose(closingWindow) { return }
        if closingWindow === workspaceSettingsWindow {
            workspaceSettingsWorkspaceID = nil
            return
        }
        guard closingWindow === settings.settingsWindow else { return }
        showingSettings = false
        shortcuts.shortcutButtonsBySetting.removeAll()
        shortcuts.activeShortcutCaptureSetting = nil
        settings.handleSettingsWindowClosed()
    }

    public func windowWillEnterFullScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        mainWindowIsFullScreen = true
        updateVisibleWorkspacePanelTabStripPresentation()
    }

    public func windowDidEnterFullScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        mainWindowIsFullScreen = true
        updateVisibleWorkspacePanelTabStripPresentation()
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        mainWindowIsFullScreen = false
        updateVisibleWorkspacePanelTabStripPresentation()
    }

    func buildShortcutRowsContainer() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = UIRadius.compact
        container.layer?.borderWidth = 1
        container.layer?.masksToBounds = true
        bindAppearanceReactiveLayer(container) { [weak self] view in view.layer?.borderColor = self?.sidebar.sidebarCardBorderColor(isSelected: false).cgColor
        }

        let captureWidth: CGFloat = 140
        let rowHeight: CGFloat = 28
        let hPad: CGFloat = 10
        let vPad: CGFloat = 4
        var previousBottom: NSLayoutYAxisAnchor = container.topAnchor

        for (i, setting) in ShortcutsController.ShortcutSetting.settingsPanelCases.enumerated() {
            if i > 0 {
                let sep = NSView()
                sep.translatesAutoresizingMaskIntoConstraints = false
                sep.wantsLayer = true
                bindAppearanceReactiveLayer(sep) { [weak self] view in
                    view.layer?.backgroundColor = self?.sidebar.sidebarCardBorderColor(isSelected: false).withAlphaComponent(0.5).cgColor
                }
                container.addSubview(sep)
                NSLayoutConstraint.activate([
                    sep.leadingAnchor.constraint(equalTo: container.leadingAnchor), sep.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    sep.topAnchor.constraint(equalTo: previousBottom), sep.heightAnchor.constraint(equalToConstant: 1),
                ])
                previousBottom = sep.bottomAnchor
            }

            let titleLabel = NSTextField(labelWithString: setting.label)
            titleLabel.font = Typography.rowDetail
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let captureButton = NSButton(title: "", target: shortcuts, action: #selector(ShortcutsController.beginShortcutCapture(_:)))
            captureButton.identifier = NSUserInterfaceItemIdentifier(setting.settingKey)
            captureButton.isBordered = false
            captureButton.alignment = .center
            captureButton.font = Typography.monoBody
            captureButton.translatesAutoresizingMaskIntoConstraints = false
            shortcuts.updateShortcutCaptureButtonText(captureButton, text: shortcuts.shortcutCaptureButtonTitle(setting: setting), active: false)
            shortcuts.styleShortcutCaptureButton(captureButton, active: false)
            captureButton.widthAnchor.constraint(equalToConstant: captureWidth).isActive = true
            shortcuts.shortcutButtonsBySetting[setting.settingKey] = captureButton

            let resetButton = actionButton(
                title: "Reset", symbol: nil, tooltip: "Reset to default shortcut", action: #selector(ShortcutsController.resetShortcutSetting(_:)),
                primary: false, target: shortcuts)
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

    public func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? { projectForms.fieldEditor(for: sender, client: client) }

    func presentFormWindow(existing: NSWindow?, header: NSView, hosting stack: NSStackView) -> NSWindow {
        let root = NSView()
        root.wantsLayer = true
        bindAppearanceReactiveLayer(root) { [weak self] view in view.layer?.backgroundColor = self?.sidebar.sidebarPanelBackgroundColor().cgColor }

        let headerDivider = settingsHairlineDivider()
        let body = NSView()

        for view in [header, headerDivider, body] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor), header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor), header.heightAnchor.constraint(equalToConstant: 52),

            headerDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor), headerDivider.topAnchor.constraint(equalTo: header.bottomAnchor),
            headerDivider.heightAnchor.constraint(equalToConstant: 1),

            body.leadingAnchor.constraint(equalTo: root.leadingAnchor), body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.topAnchor.constraint(equalTo: headerDivider.bottomAnchor), body.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            // The window's resize floor, expressed on `body` (edge-pinned, autolayout) so it reaches the
            // window through constraints. `minSize` alone does not hold: with an autolayout content view,
            // AppKit derives the window's limits from the content constraints, and every form row is
            // deliberately compressible (wrapping hints, truncating fields), so without these the user can
            // squeeze the window far below `minSize` — and the squeezed frame then persists, because the
            // window is reused across presents. Required constraints also push an already-squeezed reused
            // window back out to the floor on the next present.
            body.widthAnchor.constraint(greaterThanOrEqualToConstant: 520), body.heightAnchor.constraint(greaterThanOrEqualToConstant: 400),
        ])
        showScrollableDetailStack(stack, in: body)

        let window: NSWindow
        if let existing {
            window = existing
        } else {
            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 640), styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            created.titlebarAppearsTransparent = true
            created.titleVisibility = .hidden
            created.isMovableByWindowBackground = true
            created.isReleasedWhenClosed = false
            created.minSize = NSSize(width: 520, height: 480)
            // Bound the width so long content (paths, commands) can't stretch the
            // form into an unreadable wide layout; it stays tall-and-scrollable.
            created.maxSize = NSSize(width: 720, height: 100_000)
            created.standardWindowButton(.miniaturizeButton)?.isHidden = true
            created.standardWindowButton(.zoomButton)?.isHidden = true
            created.standardWindowButton(.closeButton)?.isHidden = true
            created.delegate = self
            created.center()
            window = created
        }
        window.contentView = root
        // Enforce the width bound on every present, including a window reused from a
        // wider session, so long content never leaves the form stretched.
        if window.frame.width > 720 {
            let contentHeight = window.contentRect(forFrameRect: window.frame).height
            window.setContentSize(NSSize(width: 680, height: contentHeight))
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    /// Header close buttons built by `buildFormWindowHeader` bind their target to the host (see
    /// `iconButton`), so the automation editor's close routes through this forwarder.
    @objc func closeAutomationEditorWindow() { automationEditor.closeWindow() }

    private func prepareWorkspaceDetailContainer(workspaceID: String, deviceID: String, presentation: DetailPanePresentation) {
        presentDetailPane(.workspace(id: workspaceID, deviceID: deviceID), presentation: presentation)
        showingSettings = false
        updateAlertsRowAppearance()
        shortcuts.activeShortcutCaptureSetting = nil
        workspaceSetupLogTextView = nil
        // Only the workspace-panel detail shows the titlebar tab strip; the panel
        // branch of `showWorkspaceDetail` re-reveals it.
        hideWorkspacePanelTabStrip()
        for view in detailContainer.subviews { view.removeFromSuperview() }
        detailContainer.wantsLayer = true
        bindAppearanceReactiveLayer(detailContainer) { [weak self] view in view.layer?.backgroundColor = self?.sidebar.sidebarPanelBackgroundColor().cgColor }
        // Every workspace-detail surface (panel, loading, setup) shares the footer
        // strip with the workspace's identity and actions.
        if let (_, workspace) = findWorkspace(id: workspaceID) {
            populateWorkspaceDetailFooter(workspace: workspace)
        } else {
            clearWorkspaceDetailFooter()
        }
    }

    func showWorkspaceDetail(project: ProjectSummary, workspace: WorkspaceSummary, presentation: DetailPanePresentation = .backgroundRefresh) {
        // Fully blocked, scoped to the owning device: if its daemon is wire-incompatible, the only
        // detail surface is the compatibility banner. Other devices' workspaces stay usable.
        // The owning device comes from the row's own project (callers always pass the pair the
        // sidebar resolved together), so the panel scope below can never key off a stale id.
        let workspaceDeviceID = project.deviceID
        if let verdict = deviceCompatibility(forDeviceID: workspaceDeviceID), !verdict.isCompatible {
            showCompatibilityBlock(deviceID: workspaceDeviceID, verdict: verdict, presentation: presentation)
            return
        }
        // Accepted, deliberate consequence: this `return` exits before `lastPresentedWorkspaceDetailID`
        // is updated below, so a blocked selection never touches it. That is intentional — a
        // compatibility block presents a banner, not `workspace`, so no monitor should retarget its
        // code pane to a workspace nothing ever actually showed. Accepted residue: if the very first
        // workspace selected this launch is blocked, `lastPresentedWorkspaceDetailID` stays `nil`
        // through it, so the first compatible workspace picked afterward is treated as this launch's
        // very first selection (the `nil` guard below) and skips its own monitor retarget too — one
        // skipped retarget that self-heals on the next selection change. The ordinary mid-session case
        // (a compatible workspace, then a blocked one, then another compatible workspace) is already
        // handled correctly: the first compatible selection already recorded
        // `lastPresentedWorkspaceDetailID`, so the blocked visit in between leaves it untouched and the
        // later compatible selection still retargets against it.
        // Captured before any branch below presents `workspace.id`: every remaining branch (the
        // loading placeholder, the setup detail, or the full panel — including its own
        // same-workspace fast path further down) ends up presenting this workspace, so this one
        // comparison, made once here, covers all of them instead of needing to be repeated per
        // branch. Read from `lastPresentedWorkspaceDetailID` rather than `visibleDetailWorkspaceID`:
        // the latter is derived from `detailPane`, which goes `nil` the moment the user detours
        // through Alerts or Automations, even though that detour does not change which workspace
        // they last selected — comparing against it would silently skip the retarget on an
        // A → Alerts → B sequence. `nil` means nothing has been presented yet this launch
        // (`lastPresentedWorkspaceDetailID` starts `nil`, just as `detailPane` starts `.none`),
        // which must never retarget a monitor — it stays on its persisted workspace until a real
        // selection change, not merely the first workspace this session shows.
        let previousWorkspaceID = lastPresentedWorkspaceDetailID
        lastPresentedWorkspaceDetailID = workspace.id
        if let previousWorkspaceID, previousWorkspaceID != workspace.id {
            // Every global panel window's code pane is a workspace-following review monitor: the
            // sidebar selecting a different workspace retargets its diff to match, in `.diff`
            // mode, discarding whatever it held in memory for the old workspace. A code pane in
            // the workspace's own panel (below) is untouched by this — it belongs to that one
            // workspace and never retargets.
            panelCoordinator.retargetGlobalWindowCodePanes(toDeviceID: workspaceDeviceID, workspaceID: workspace.id)
        }
        // This workspace's device is compatible; every branch below presents the workspace pane
        // (`prepareWorkspaceDetailContainer`), which replaces any prior device's compatibility block.
        guard let deviceWorkspaceSummary = deviceWorkspaceSummary(workspaceID: workspace.id) else {
            prepareWorkspaceDetailContainer(workspaceID: workspace.id, deviceID: workspaceDeviceID, presentation: presentation)
            showWorkspaceDetailLoadingPlaceholder(workspace: workspace)
            requestSidebarReload()
            return
        }
        let deviceWorkspace = SpacesDeviceWorkspaceDetailViewModel(workspace: deviceWorkspaceSummary)
        let setupState = Self.localSetupState(from: deviceWorkspace.setupState)
        if !Self.shouldRequestNormalWorkspaceDetailRefresh(setupStatus: setupState.status) {
            prepareWorkspaceDetailContainer(workspaceID: workspace.id, deviceID: workspaceDeviceID, presentation: presentation)
            showWorkspaceSetupDetail(project: project, workspace: workspace, setupState: setupState, logTail: deviceWorkspace.setupState?.logTail)
            return
        }
        stopWorkspaceSetupDetailRefreshTimer()

        // The right panel is the workspace's panel (tabs of terminal panes) and
        // nothing else; workspace identity and actions live in the footer strip below.
        let scope = PanelScope.workspace(deviceID: workspaceDeviceID, workspaceID: workspace.id)
        panelCoordinator.restoreLayoutIfNeeded(scope: scope, focusIntent: .focus)
        let panelView = panelCoordinator.panelView(for: scope)
        // Overview ticks land here every few seconds. When this workspace's panel is
        // already the visible detail, tearing it down and re-adding it would dismiss
        // transient chrome hanging off it (the tab rename editor) and churn layout —
        // only the footer's status needs refreshing.
        if panelView.superview === detailContainer, visibleDetailWorkspaceID == workspace.id {
            populateWorkspaceDetailFooter(workspace: workspace)
            // The tab strip titles derive from runtime-target names, which an overview
            // tick can rename without touching the layout; refresh them in place since
            // this fast path skips the panel re-render.
            panelCoordinator.refreshTabTitles(scope: scope)
            return
        }
        prepareWorkspaceDetailContainer(workspaceID: workspace.id, deviceID: workspaceDeviceID, presentation: presentation)
        showWorkspacePanelTabStrip(for: panelView)
        panelTabStripView.sidebarWidth = splitView?.arrangedSubviews.first?.frame.width ?? panelTabStripView.sidebarWidth
        panelView.removeFromSuperview()
        // Sized before it joins the window: a terminal pane inside rebuilds its evicted mirror surface
        // during `addSubview` and forces a layout pass from there, which is ahead of the edge
        // constraints below. Without a plausible frame that pass solves the panel to its fitting size
        // and the pane measures a grid a fraction of the real one.
        panelView.frame = detailContainer.bounds
        detailContainer.addSubview(panelView)
        NSLayoutConstraint.activate([
            panelView.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            panelView.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            panelView.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            panelView.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
        panelCoordinator.restoreSelection(scope: scope)
        detailContainer.layoutSubtreeIfNeeded()
    }

    /// Everything `populateWorkspaceDetailFooter` draws, so a refresh that would draw the same strip can
    /// leave it alone. The focused-pane label is deliberately absent: it tracks the focused terminal's
    /// live title, which moves on its own, and is written in place instead.
    struct WorkspaceDetailFooterSignature: Equatable {
        let workspaceID: String
        let displayName: String
        let branch: String
        let directory: String
        let notes: String
        let isLifecycleRunning: Bool
        let isRunning: Bool
        let offersStart: Bool
        let warningSummary: String?
        let deviceAcceptsDaemonActions: Bool
        let unreachableDeviceTooltip: String?
    }

    /// Fills the right panel's footer strip with the selected workspace's identity and
    /// actions — status dot, name, branch, directory, notes, runtime warning, and the
    /// launch/restart, stop, and overflow controls.
    private func populateWorkspaceDetailFooter(workspace: WorkspaceSummary) {
        guard let footer = workspaceDetailFooterRow else { return }
        let runtimeStatus =
            deviceModel.workspaceRuntimeStatusByID[workspace.id]
            ?? WorkspaceRuntimeStatus(
                workspaceID: workspace.id, lifecycleState: WorkspaceLifecycleState(isRunning: workspace.isRunning), runtimeHealth: .healthy,
                hasTrackedRuntimeIndicators: false, runningProcessCount: 0, exitedProcessCount: 0, waitingAgentWindowCount: 0,
                missingConfiguredProcessCount: 0, missingConfiguredBrowserSessionCount: 0)
        let isLifecycleRunning = runtimeStatus.lifecycleState == .running
        let offersStart = Self.workspaceLifecycleControlsOfferStart(
            isRunning: workspace.isRunning, missingConfiguredProcessCount: runtimeStatus.missingConfiguredProcessCount)
        // Git workspaces are named after their branch, so a branch label matching the
        // name would just duplicate it.
        let branch = (workspace.branch ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = (workspace.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let signature = WorkspaceDetailFooterSignature(
            workspaceID: workspace.id, displayName: workspace.displayName, branch: branch, directory: workspace.dir, notes: notes,
            isLifecycleRunning: isLifecycleRunning, isRunning: workspace.isRunning, offersStart: offersStart,
            warningSummary: runtimeStatus.warningSummary, deviceAcceptsDaemonActions: deviceAcceptsDaemonActions(forWorkspaceID: workspace.id),
            unreachableDeviceTooltip: unreachableDeviceTooltip(forWorkspaceID: workspace.id))
        // Overview ticks land here many times a second while a terminal streams, and the strip is rebuilt
        // from scratch, which destroys the button under the pointer between mouse-down and mouse-up. A
        // refresh that would draw the same strip touches no view; the focused-pane label is the one thing
        // that moves on its own, so it is refreshed in place.
        if signature == renderedWorkspaceFooterSignature {
            refreshWorkspaceFooterFocusedPane(workspaceID: workspace.id)
            return
        }
        clearWorkspaceDetailFooter()
        let accentColor = sidebar.sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))

        let statusDot = NSImageView()
        statusDot.image = NSImage(
            systemSymbolName: isLifecycleRunning ? "circle.fill" : "circle", accessibilityDescription: isLifecycleRunning ? "Running" : "Stopped")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .regular))
        statusDot.contentTintColor = isLifecycleRunning ? accentColor : .tertiaryLabelColor
        statusDot.toolTip = isLifecycleRunning ? "Running" : "Stopped"
        statusDot.setContentHuggingPriority(.required, for: .horizontal)
        footer.addArrangedSubview(statusDot)

        let titleLabel = NSTextField(labelWithString: workspace.displayName)
        titleLabel.font = Typography.compactTitle
        titleLabel.textColor = sidebar.sidebarPrimaryTextColor(isSelected: false)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityIdentifier("workspace-detail-title-label")
        footer.addArrangedSubview(titleLabel)

        if let warningSummary = runtimeStatus.warningSummary {
            let warningIcon = NSImageView()
            warningIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Status warning")?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
            warningIcon.contentTintColor = .systemOrange
            warningIcon.toolTip = warningSummary
            warningIcon.setContentHuggingPriority(.required, for: .horizontal)
            footer.addArrangedSubview(warningIcon)
        }

        if !branch.isEmpty, branch != workspace.displayName {
            let branchIcon = NSImageView()
            branchIcon.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Branch")?.withSymbolConfiguration(
                .init(pointSize: 9, weight: .regular))
            branchIcon.contentTintColor = .tertiaryLabelColor
            branchIcon.setContentHuggingPriority(.required, for: .horizontal)
            let branchLabel = NSTextField(labelWithString: branch)
            branchLabel.font = Typography.metadata
            branchLabel.textColor = .secondaryLabelColor
            branchLabel.lineBreakMode = .byTruncatingTail
            branchLabel.setAccessibilityIdentifier("workspace-detail-branch")
            footer.addArrangedSubview(branchIcon)
            footer.addArrangedSubview(branchLabel)
            footer.setCustomSpacing(3, after: branchIcon)
        }

        let dirLabel = NSTextField(labelWithString: workspace.dir)
        dirLabel.font = Typography.monoCaption
        dirLabel.textColor = .tertiaryLabelColor
        dirLabel.lineBreakMode = .byTruncatingMiddle
        dirLabel.toolTip = workspace.dir
        // Selectable so the path can be copied with ⌘C straight from the footer.
        dirLabel.isSelectable = true
        dirLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dirLabel.setAccessibilityIdentifier("workspace-detail-dir")
        footer.addArrangedSubview(dirLabel)

        // The focused pane's identity (panes carry no header of their own), kept in
        // sync by the panel coordinator. ⌘W closes it.
        let paneLabel = NSTextField(labelWithString: "")
        paneLabel.font = Typography.metadataEmphasis
        paneLabel.textColor = .secondaryLabelColor
        paneLabel.lineBreakMode = .byTruncatingTail
        paneLabel.setAccessibilityIdentifier("workspace-detail-focused-pane")
        workspaceFooterPaneLabel = paneLabel
        workspaceFooterWorkspaceID = workspace.id
        footer.addArrangedSubview(paneLabel)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        footer.addArrangedSubview(spacer)
        refreshWorkspaceFooterFocusedPane(workspaceID: workspace.id)

        // Everything below writes through the owning daemon, so an unreachable device's footer reads
        // its workspace but offers no action that would only raise an error dialog. The overflow button
        // stays enabled: its menu also carries the path actions, which need nothing from the daemon.
        let notesButton = footerActionButton(
            symbol: "note.text", tooltip: notes.isEmpty ? "Add notes" : notes, action: #selector(showWorkspaceNotesEditor(_:)))
        notesButton.contentTintColor = notes.isEmpty ? .tertiaryLabelColor : accentColor
        notesButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        notesButton.setAccessibilityIdentifier("workspace-detail-notes")
        disableWhenDeviceCannotAct(notesButton, workspaceID: workspace.id)
        footer.addArrangedSubview(notesButton)

        // `isRunning` turns true the moment an ad hoc terminal or agent session starts and says nothing
        // about whether a configured process is actually running, so the running case can still owe Start:
        // offered here alongside Restart/Stop instead of being replaced by them, matching the sidebar row's
        // context menu (see `workspaceLifecycleControlsOfferStart`).
        if offersStart, workspace.isRunning {
            let startButton = footerActionButton(symbol: "play.circle", tooltip: "Start", action: #selector(launchWorkspace(_:)))
            startButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
            startButton.setAccessibilityIdentifier("workspace-detail-start")
            disableWhenDeviceCannotAct(startButton, workspaceID: workspace.id)
            footer.addArrangedSubview(startButton)
        }

        // Lifecycle actions follow the workspace's state, matching the sidebar row's context menu: a stopped
        // workspace can only be started, so it offers Launch alone; a running one offers Restart and Stop.
        let launchOrRestartButton = footerActionButton(
            symbol: workspace.isRunning ? "arrow.clockwise.circle" : "play.circle", tooltip: workspace.isRunning ? "Restart" : "Launch",
            action: workspace.isRunning ? #selector(restartWorkspace(_:)) : #selector(launchWorkspace(_:)))
        launchOrRestartButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        launchOrRestartButton.setAccessibilityIdentifier("workspace-detail-launch-restart")
        disableWhenDeviceCannotAct(launchOrRestartButton, workspaceID: workspace.id)
        footer.addArrangedSubview(launchOrRestartButton)

        if workspace.isRunning {
            let stopButton = footerActionButton(symbol: "stop.circle", tooltip: "Stop", action: #selector(stopWorkspace(_:)))
            stopButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
            stopButton.setAccessibilityIdentifier("workspace-detail-stop")
            disableWhenDeviceCannotAct(stopButton, workspaceID: workspace.id)
            footer.addArrangedSubview(stopButton)
        }

        let overflowButton = footerActionButton(symbol: "ellipsis.circle", tooltip: "More actions", action: #selector(showWorkspaceOverflowMenu(_:)))
        overflowButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        overflowButton.setAccessibilityIdentifier("workspace-detail-overflow")
        footer.addArrangedSubview(overflowButton)
        renderedWorkspaceFooterSignature = signature
    }

    /// Takes a detail-pane control out of service while the workspace's device cannot reach its
    /// daemon, dimming it to the opacity an unreachable device's rows carry and naming the device in
    /// its tooltip — the same treatment the sidebar rows and the add-project device picker use. The
    /// detail pane is not dimmed as a whole, so the control carries the dimming itself. This only
    /// ever removes availability, so a control the caller already disabled for its own reason (a
    /// setup that is already running) stays disabled whatever order the two are applied in.
    func disableWhenDeviceCannotAct(_ control: NSControl, workspaceID: String) {
        guard !deviceAcceptsDaemonActions(forWorkspaceID: workspaceID) else { return }
        control.isEnabled = false
        control.alphaValue = Self.unreachableDeviceAlpha
        if let tooltip = unreachableDeviceTooltip(forWorkspaceID: workspaceID) { control.toolTip = tooltip }
    }

    /// The device-scoped counterpart, for a control that targets a device rather than a workspace
    /// (creating a workspace in a project, which has no workspace to resolve from yet). It sets no
    /// opacity of its own: its caller is a sidebar row button, and the row already carries the
    /// owning device's dimming, so dimming again would compound into a barely visible control.
    func disableWhenDeviceCannotAct(_ control: NSControl, deviceID: String) {
        guard !deviceAcceptsDaemonActions(forDeviceID: deviceID) else { return }
        control.isEnabled = false
        if let tooltip = unreachableDeviceTooltip(forDeviceID: deviceID) { control.toolTip = tooltip }
    }

    private func footerActionButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?.withSymbolConfiguration(
                .init(pointSize: 12, weight: .regular)) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .inline
        button.isBordered = false
        button.toolTip = tooltip
        button.contentTintColor = .secondaryLabelColor
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func clearWorkspaceDetailFooter() {
        workspaceNotesPopover?.close()
        workspaceNotesPopover = nil
        workspaceFooterWorkspaceID = nil
        renderedWorkspaceFooterSignature = nil
        guard let footer = workspaceDetailFooterRow else { return }
        for view in footer.arrangedSubviews {
            footer.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    /// Syncs the footer's focused-pane title with the workspace panel; called by the
    /// panel coordinator on layout and title changes.
    func refreshWorkspaceFooterFocusedPane(workspaceID: String) {
        guard workspaceFooterWorkspaceID == workspaceID, let paneLabel = workspaceFooterPaneLabel else { return }
        // A workspace with no known owning device has no panel scope, so it has no focused
        // pane to name — the label clears rather than reporting the local device's pane.
        let info = deviceID(forWorkspaceID: workspaceID).flatMap { panelCoordinator.focusedPaneInfo(deviceID: $0, workspaceID: workspaceID) }
        paneLabel.stringValue = info?.title ?? ""
        paneLabel.isHidden = info == nil
    }

    /// Opens the notes editor in a popover anchored to the footer's notes button.
    /// Saving routes through the same workspace-metadata mutation the detail header's
    /// inline editor used.
    @objc private func showWorkspaceNotesEditor(_ sender: NSButton) {
        guard let workspaceID = sender.identifier?.rawValue, let (_, workspace) = findWorkspace(id: workspaceID) else { return }
        workspaceNotesPopover?.close()

        let textView = makeEditableTextView()
        textView.string = workspace.notes ?? ""
        textView.font = Typography.rowDetail
        textView.setAccessibilityIdentifier("workspace-detail-notes-input")
        textView.onSave = { [weak self, weak textView] in
            guard let self, let textView else { return }
            self.saveWorkspaceNotes(workspaceID: workspaceID, text: textView.string)
        }
        textView.onCancel = { [weak self] in
            self?.workspaceNotesPopover?.close()
            self?.workspaceNotesPopover = nil
        }
        let scrollView = scrollableTextView(
            textView, height: 88, inputBackgroundColor: sidebar.sidebarThemeColor(light: (235, 233, 225), dark: (10, 15, 17)),
            borderColor: sidebar.sidebarCardBorderColor(isSelected: false))

        let saveButton = NSButton(title: "Save (⌘↩)", target: self, action: #selector(saveWorkspaceNotesFromPopover(_:)))
        saveButton.controlSize = .small
        saveButton.bezelStyle = .rounded
        saveButton.setAccessibilityIdentifier("workspace-detail-notes-save")
        workspaceNotesEditorTextView = textView
        workspaceNotesEditorWorkspaceID = workspaceID

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(label(text: "Notes"))
        stack.addArrangedSubview(scrollView)
        stack.addArrangedSubview(saveButton)

        let content = NSViewController()
        let contentView = NSView()
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12), scrollView.widthAnchor.constraint(equalToConstant: 320),
        ])
        content.view = contentView

        let popover = NSPopover()
        popover.contentViewController = content
        popover.behavior = .transient
        workspaceNotesPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        window?.makeFirstResponder(textView)
    }

    @objc private func saveWorkspaceNotesFromPopover(_ sender: NSButton) {
        guard let workspaceID = workspaceNotesEditorWorkspaceID, let textView = workspaceNotesEditorTextView else { return }
        saveWorkspaceNotes(workspaceID: workspaceID, text: textView.string)
    }

    private func saveWorkspaceNotes(workspaceID: String, text: String) {
        do {
            guard let device = deviceForDaemonStateMutation() else {
                showSelectedDeviceUnavailableError()
                return
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let epoch = panelCoordinator.paneReplacementEpoch
            let response = try SpacesDeviceClient.updateWorkspaceMetadata(
                workspaceID: workspaceID, notes: trimmed.isEmpty ? nil : trimmed, updatesNotes: true,
                context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
            workspaceNotesPopover?.close()
            workspaceNotesPopover = nil
            applyDeviceMutationResponse(response, deviceID: device.id, epoch: epoch, selectedWorkspaceID: workspaceID)
        } catch { showError(error) }
    }

    private func showWorkspaceDetailLoadingPlaceholder(workspace: WorkspaceSummary) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        stack.addArrangedSubview(spinner)

        let title = NSTextField(labelWithString: "Loading \(workspace.displayName)...")
        title.font = Typography.emptyStateTitle
        title.textColor = .labelColor
        stack.addArrangedSubview(title)

        let workspaceDeviceName = deviceModel.deviceSections.first(where: { $0.deviceID == workspace.deviceID })?.deviceName ?? deviceModel.localDeviceName
        let detail = NSTextField(labelWithString: "Spaces is loading workspace details from \(workspaceDeviceName).")
        detail.font = Typography.rowDetail
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        stack.addArrangedSubview(detail)

        detailContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: detailContainer.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: detailContainer.centerYAnchor),
        ])
    }

    private func showWorkspaceSetupDetail(project: ProjectSummary, workspace: WorkspaceSummary, setupState: WorkspaceSetupState, logTail: String?) {
        if setupState.status == .running {
            startWorkspaceSetupDetailRefreshTimerIfNeeded(workspaceID: workspace.id)
        } else {
            stopWorkspaceSetupDetailRefreshTimer()
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: workspace.displayName)
        titleLabel.font = Typography.pageTitle
        titleLabel.textColor = sidebar.sidebarPrimaryTextColor(isSelected: false)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setAccessibilityIdentifier("workspace-detail-title-label")

        let statusIcon = NSImageView()
        statusIcon.image = NSImage(
            systemSymbolName: workspaceSetupStatusSymbol(setupState.status), accessibilityDescription: workspaceSetupStatusTitle(setupState.status))
        statusIcon.contentTintColor = workspaceSetupStatusColor(setupState.status)
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        statusIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let statusLabel = NSTextField(labelWithString: workspaceSetupStatusTitle(setupState.status))
        statusLabel.font = Typography.controlLabel
        statusLabel.textColor = workspaceSetupStatusColor(setupState.status)

        let headerRow = NSStackView(views: [titleLabel, NSView(), statusIcon, statusLabel])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8

        let dirField = NSTextField(string: workspace.dir)
        dirField.font = Typography.monoMetadata
        dirField.textColor = .tertiaryLabelColor
        dirField.lineBreakMode = .byTruncatingMiddle
        dirField.isEditable = false
        dirField.isSelectable = true
        dirField.drawsBackground = false
        dirField.isBordered = false
        dirField.setAccessibilityIdentifier("workspace-detail-dir")

        let headerStack = NSStackView(views: [headerRow, dirField])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 4
        stack.addArrangedSubview(headerStack)
        constrainFormFieldToFillWidth(headerRow, in: headerStack)
        constrainFormFieldToFillWidth(dirField, in: headerStack)
        constrainFormFieldToFillWidth(headerStack, in: stack)

        let runButton = actionButton(
            title: setupState.status == .failed ? "Retry Setup" : "Run Setup", symbol: setupState.status == .failed ? "arrow.clockwise" : "play",
            tooltip: "Run workspace setup", action: #selector(runWorkspaceSetupFromDetail(_:)), primary: setupState.status != .running, target: self)
        runButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        runButton.isEnabled = setupState.status != .running
        runButton.setAccessibilityIdentifier("workspace-setup-run")
        // Running setup and opening a terminal both run on the owning daemon; Reveal and Copy Log below
        // read what is already on this Mac, so they stay available through an outage.
        disableWhenDeviceCannotAct(runButton, workspaceID: workspace.id)

        let terminalButton = actionButton(
            title: "Terminal", symbol: "terminal", tooltip: "Open a workspace terminal", action: #selector(openWorkspaceTerminal(_:)), primary: false,
            target: self)
        terminalButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        terminalButton.setAccessibilityIdentifier("workspace-setup-terminal")
        disableWhenDeviceCannotAct(terminalButton, workspaceID: workspace.id)

        let revealButton = actionButton(
            title: "Reveal", symbol: "folder", tooltip: "Reveal workspace in Finder", action: #selector(revealDirectoryInFinder(_:)), primary: false,
            target: self)
        revealButton.identifier = NSUserInterfaceItemIdentifier(workspace.dir)
        revealButton.isEnabled = isLocalWorkspace(workspace)
        revealButton.setAccessibilityIdentifier("workspace-setup-reveal")

        let hasLogTail = logTail?.isEmpty == false
        let hasLocalLogFile = isLocalWorkspace(workspace) && setupState.logPath?.isEmpty == false

        // Copy reflects the displayed log content so it works for remote workspaces too; Open opens
        // the log file on disk, which is only reachable for a local workspace.
        let copyLogButton = actionButton(
            title: "Copy Log", symbol: "doc.on.doc", tooltip: "Copy setup log", action: #selector(copyWorkspaceSetupLog(_:)), primary: false,
            target: self)
        copyLogButton.isEnabled = hasLogTail
        copyLogButton.setAccessibilityIdentifier("workspace-setup-copy-log")

        let openLogButton = actionButton(
            title: "Open Log", symbol: "doc.text.magnifyingglass", tooltip: "Open setup log", action: #selector(openWorkspaceSetupLog(_:)),
            primary: false, target: self)
        openLogButton.identifier = NSUserInterfaceItemIdentifier(setupState.logPath ?? "")
        openLogButton.isEnabled = hasLocalLogFile
        openLogButton.setAccessibilityIdentifier("workspace-setup-open-log")

        let actionRow = NSStackView(views: [runButton, terminalButton, revealButton, copyLogButton, openLogButton])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8

        let statusContent = NSStackView()
        statusContent.orientation = .vertical
        statusContent.alignment = .leading
        statusContent.spacing = 8
        statusContent.addArrangedSubview(workspaceSetupMetadataRows(setupState))
        statusContent.addArrangedSubview(actionRow)
        let logView = workspaceSetupLogTailView(content: logTail)
        statusContent.addArrangedSubview(logView)
        constrainFormFieldToFillWidth(logView, in: statusContent)

        let statusCard = formSectionCard(
            icon: nil, title: "Workspace Setup", subtitle: workspaceSetupPanelSubtitle(setupState.status),
            iconColor: workspaceSetupStatusColor(setupState.status), contentViews: [statusContent])
        stack.addArrangedSubview(statusCard)
        constrainFormFieldToFillWidth(statusCard, in: stack)

        if Self.shouldShowWorkspaceSetupScriptEditor(status: setupState.status) {
            let activeProjectConfig = deviceProjectSummary(projectID: project.id)?.config
            let setupScriptSection = ScriptSection(
                title: "Setup Script", editAccessibilityIdentifier: "setup-script-edit", formAccessibilityPrefix: "project-setup-script",
                value: activeProjectConfig?.setupScript ?? "", subtitle: "Edit the project setup script, then run setup again.")
            setupScriptSection.onCommit = { [weak self] value in
                guard let self else { return }
                do {
                    // Saving the script writes it through the owning daemon, so it goes through the
                    // mutation chokepoint: an unreachable device keeps the editor readable and refuses
                    // only the commit.
                    if let device = deviceForMutation(deviceID: project.deviceID), let current = deviceProjectSummary(projectID: project.id)?.config {
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        let updated = SpacesDeviceProjectConfig(
                            setupScript: trimmed.isEmpty ? nil : value, stopScript: current.stopScript, ports: current.ports,
                            processes: current.processes, browserSessions: current.browserSessions)
                        let epoch = panelCoordinator.paneReplacementEpoch
                        let response = try SpacesDeviceClient.updateProjectConfig(
                            projectID: project.id, config: updated,
                            context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
                        applyDeviceMutationResponse(response, deviceID: device.id, epoch: epoch, selectedWorkspaceID: workspace.id)
                    } else {
                        showError(deviceUnavailableError(deviceID: project.deviceID))
                    }
                } catch { showError(error) }
            }
            stack.addArrangedSubview(setupScriptSection.view)
            constrainFormFieldToFillWidth(setupScriptSection.view, in: stack)
        }

        showScrollableDetailStack(stack, in: detailContainer)
        detailContainer.layoutSubtreeIfNeeded()
    }

    private func workspaceSetupMetadataRows(_ state: WorkspaceSetupState) -> NSView {
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        rows.addArrangedSubview(workspaceSetupMetadataRow(label: "Status", value: workspaceSetupStatusTitle(state.status)))
        if let startedAt = state.startedAt, !startedAt.isEmpty {
            rows.addArrangedSubview(workspaceSetupMetadataRow(label: "Started", value: startedAt))
        }
        if let finishedAt = state.finishedAt, !finishedAt.isEmpty {
            rows.addArrangedSubview(workspaceSetupMetadataRow(label: "Finished", value: finishedAt))
        }
        if let exitCode = state.exitCode { rows.addArrangedSubview(workspaceSetupMetadataRow(label: "Exit", value: String(exitCode))) }
        if let message = state.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            rows.addArrangedSubview(workspaceSetupMetadataRow(label: "Error", value: message, valueColor: .systemRed))
        }
        if let logPath = state.logPath?.trimmingCharacters(in: .whitespacesAndNewlines), !logPath.isEmpty {
            rows.addArrangedSubview(workspaceSetupMetadataRow(label: "Log", value: logPath))
        }
        return rows
    }

    private func workspaceSetupMetadataRow(label: String, value: String, valueColor: NSColor = .secondaryLabelColor) -> NSView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = Typography.metadataTitle
        labelField.textColor = .tertiaryLabelColor
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.widthAnchor.constraint(equalToConstant: 62).isActive = true
        labelField.setContentHuggingPriority(.required, for: .horizontal)

        let valueField = NSTextField(labelWithString: value)
        valueField.font = label == "Log" ? Typography.monoMetadata : Typography.metadata
        valueField.textColor = valueColor
        valueField.lineBreakMode = .byTruncatingMiddle
        valueField.maximumNumberOfLines = 2
        valueField.translatesAutoresizingMaskIntoConstraints = false
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [labelField, valueField])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    private func workspaceSetupLogTailView(content: String?) -> NSView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = Typography.monoMetadata
        let text = content ?? ""
        textView.string = text.isEmpty ? "No setup log output." : text
        textView.setAccessibilityIdentifier("workspace-setup-log-tail")
        workspaceSetupLogTextView = textView
        let scrollView = scrollableTextView(
            textView, height: 240, inputBackgroundColor: sidebar.sidebarThemeColor(light: (235, 233, 225), dark: (10, 15, 17)),
            borderColor: sidebar.sidebarCardBorderColor(isSelected: false))
        Task { @MainActor [weak textView] in textView?.scrollToEndOfDocument(nil) }
        return scrollView
    }

    private func workspaceSetupPanelSubtitle(_ status: WorkspaceSetupStatus) -> String {
        switch status {
        case .pending: return "Run setup before using configured processes, coding agents, or browser sessions."
        case .running: return "Setup is running. The log refreshes while output is written."
        case .failed: return "Fix the setup script or workspace files, then retry setup."
        case .succeeded: return "Setup completed."
        }
    }

    private func workspaceSetupStatusTitle(_ status: WorkspaceSetupStatus) -> String {
        switch status {
        case .pending: return "Setup Pending"
        case .running: return "Setup Running"
        case .succeeded: return "Setup Complete"
        case .failed: return "Setup Failed"
        }
    }

    private func workspaceSetupStatusSymbol(_ status: WorkspaceSetupStatus) -> String {
        switch status {
        case .pending: return "hourglass"
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func workspaceSetupStatusColor(_ status: WorkspaceSetupStatus) -> NSColor {
        switch status {
        case .pending: return .secondaryLabelColor
        case .running: return sidebar.sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
        case .succeeded: return .systemGreen
        case .failed: return .systemRed
        }
    }

    static func makeInlineEditorSlot(label: NSView, editor: NSView) -> NSView {
        let slot = NSView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        slot.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slot.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for subview in [label, editor] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            slot.addSubview(subview)
            NSLayoutConstraint.activate([
                subview.leadingAnchor.constraint(equalTo: slot.leadingAnchor), subview.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
                subview.topAnchor.constraint(equalTo: slot.topAnchor), subview.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
            ])
        }

        return slot
    }

    private func label(text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Typography.compactTitle
        label.textColor = .secondaryLabelColor
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

    /// Row text for a terminal row: its stable name, described by the live title its program reported
    /// (nothing when it reported none). Both arrive stripped of the `*`/`-` prefixes tracked window
    /// names historically carried.
    nonisolated static func terminalFallbackRowText(name: String?, detail: String?, app _: String) -> (label: String, detail: String?) {
        let cleanedName = name?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
            of: #"^[*-]\s*"#, with: "", options: .regularExpression)
        let cleanedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
            of: #"^[*-]\s*"#, with: "", options: .regularExpression)
        return (cleanedName?.isEmpty == false ? cleanedName! : "Terminal", cleanedDetail?.isEmpty == false ? cleanedDetail : nil)
    }

    /// The command palette describes a named terminal with program-provided title state first, then
    /// the generic foreground command the daemon already included in its overview. It deliberately
    /// performs no process inspection and has no launch-command or shell fallback.
    nonisolated static func terminalPaletteSecondaryLabel(
        liveTitle: String?, sessionID: String?, sessionsByID: [String: SpacesDeviceTerminalSessionSummary]
    )
        -> String?
    {
        if let liveTitle = liveTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !liveTitle.isEmpty { return liveTitle }
        guard let sessionID,
            let command = sessionsByID[sessionID]?.foregroundCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
            !command.isEmpty
        else { return nil }
        return command
    }

    func windowRow(
        icon: String, iconColor: NSColor, label: String, detail: String? = nil, shortcut: String, processStatus: RunningProcessState? = nil,
        agentStatus: AgentWindowStatus? = nil, automationID: String? = nil, trailingAccessory: NSView? = nil, action: (() async -> Void)? = nil
    ) -> ClickableRowView {
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
        labelField.font = detail == nil ? Typography.rowDetail : Typography.compactTitle
        labelField.textColor = .labelColor
        labelField.lineBreakMode = .byTruncatingTail
        labelField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        labelField.setContentCompressionResistancePriority(.required, for: .horizontal)

        let detailField = NSTextField(labelWithString: detail ?? "")
        if let automationID { detailField.setAccessibilityIdentifier("\(automationID)-detail") }
        detailField.font = Typography.metadata
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        detailField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailField.isHidden = detail == nil
        container.labelField = labelField
        container.detailField = detailField

        let badge = NSTextField(labelWithString: shortcut)
        badge.font = Typography.monoBadge
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
                let (statusIconName, statusColor) = Self.agentStatusSymbolAndColor(agentStatus)
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
        fputs("spaces: window_row_click \(message)\n", stderr)
    }

    /// Editors offered in settings: the built-in Editor first (always available, needs nothing
    /// installed), then the external editors installed on this Mac. Detection and launch of the
    /// external editors both key off the bundle identifier so an app rename (e.g. Windsurf → Devin
    /// Desktop) does not require a path or display-name update here.
    func installedEditorOptions() -> [EditorPreference] { [.builtin] + [.vscode, .devin, .zed].filter(isEditorInstalled) }

    private func isEditorInstalled(_ editor: EditorPreference) -> Bool {
        guard let bundleID = editor.bundleIdentifier else { return false }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    private func sidebarSectionHeader(title: String, actions: [(symbol: String, tooltip: String, action: Selector, target: AnyObject?)]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = Typography.metadataTitle
        label.textColor = .secondaryLabelColor

        stack.addArrangedSubview(label)
        stack.addArrangedSubview(NSView())
        for action in actions {
            // `sidebarRowIconButton` always targets the host; an explicit `target` here overrides that for
            // an action owned by a standalone controller (e.g. the workspace-visibility filter button).
            let button = sidebarRowIconButton(symbol: action.symbol, tooltip: action.tooltip, action: action.action)
            if let target = action.target { button.target = target }
            stack.addArrangedSubview(button)
        }

        return stack
    }

    func sidebarRowIconButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.isBordered = false
        button.imageScaling = .scaleNone
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?.withSymbolConfiguration(
            .init(pointSize: 12, weight: .semibold))
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 18), button.heightAnchor.constraint(equalToConstant: 18)])
        return button
    }

    /// The right-edge disclosure chevron for collapsible sidebar rows (projects and
    /// workspaces). Points down when expanded and right when collapsed. Rendered as a
    /// button so a click toggles expansion without also triggering the row's own
    /// mouse-down handling (project row-toggle or workspace selection).
    func sidebarRowChevronButton(expanded: Bool, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.isBordered = false
        button.imageScaling = .scaleNone
        button.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: tooltip)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        button.contentTintColor = .tertiaryLabelColor
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 16), button.heightAnchor.constraint(equalToConstant: 16)])
        return button
    }

    @objc func toggleSidebarProjectDisclosure(_ sender: NSButton) {
        guard let projectID = sender.identifier?.rawValue else { return }
        sidebar.toggleProjectExpanded(projectID: projectID)
    }

    @objc func toggleSidebarWorkspaceDisclosure(_ sender: NSButton) {
        guard let workspaceID = sender.identifier?.rawValue else { return }
        sidebar.toggleWorkspaceExpanded(workspaceID: workspaceID)
    }

    @objc func reloadTapped() {
        // An explicit reload should refresh remotes immediately, bypassing the
        // per-device freshness gate in loadRemoteDeviceSections.
        reloadData(forceRemoteRefresh: true)
    }

    func clientDatabase() throws -> SpacesClientDatabase { try SpacesClientDatabase.defaultDatabase() }

    func macPairedDevices() -> [SpacesPairedDeviceRecord] {
        guard let database = try? clientDatabase() else { return [] }
        return ((try? database.pairedDevices()) ?? []).filter { $0.id != SpacesPairedDeviceRecord.localDeviceID }
    }

    @objc func showSettings() { settings.openSettings(section: .general) }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func openWorkspaceEditor(_ sender: NSButton) {
        guard let workspaceID = sender.identifier?.rawValue else { return }
        openWorkspaceEditor(workspaceID: workspaceID)
    }

    @objc private func openWorkspaceTerminal(_ sender: NSButton) {
        guard let workspaceID = sender.identifier?.rawValue else { return }
        sender.isEnabled = false
        openWorkspaceTerminal(workspaceID: workspaceID, route: .button) { sender.isEnabled = true }
    }

    @objc private func runWorkspaceSetupFromDetail(_ sender: NSButton) {
        guard let workspaceID = sender.identifier?.rawValue else { return }
        sender.isEnabled = false
        Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            guard let device = deviceForDaemonStateMutation() else {
                sender?.isEnabled = true
                showSelectedDeviceUnavailableError()
                return
            }
            let epoch = self.panelCoordinator.paneReplacementEpoch
            let result = await Self.deviceMutation(device: device) { device in
                try SpacesDeviceClient.runWorkspaceSetup(
                    workspaceID: workspaceID,
                    context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
            }
            sender?.isEnabled = true
            switch result {
            // The response's overview belongs to the device the mutation was sent to, so it is
            // installed into that device's section — re-resolving from the workspace id could
            // name a different device and prune its panes against a foreign keep-set.
            case .success(let response): applyDeviceMutationResponse(response, deviceID: device.id, epoch: epoch, selectedWorkspaceID: workspaceID)
            case .failure(let error): showError(error)
            }
        }
    }

    @objc private func copyWorkspaceSetupLog(_ sender: Any) {
        // Copy the displayed setup-log content so this works for remote workspaces, whose log file
        // is not reachable from the client by path.
        let contents = workspaceSetupLogTextView?.string ?? ""
        guard !contents.isEmpty, contents != "No setup log output." else { return }
        copyToPasteboard(contents)
    }

    @objc private func openWorkspaceSetupLog(_ sender: Any) {
        guard let path = Self.senderIdentifier(sender), !path.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: false))
    }

    @objc private func openWorkspaceFinder(_ sender: NSButton) {
        guard let workspaceID = sender.identifier?.rawValue else { return }
        openWorkspaceFinder(workspaceID: workspaceID)
    }

    // Thin @objc forwarders to `ProjectFormsController`: each stays here because it is reached by
    // selector (menu item, sidebar button, or the responder chain with `target: nil`), and a selector
    // target must be a live Objective-C object the caller already holds a reference to.
    @objc private func addProject() { projectForms.addProject() }

    @objc func addWorkspace(_ sender: NSButton) { projectForms.addWorkspace(sender) }

    @objc func showProjectSettings(_ sender: NSButton) { projectForms.showProjectSettings(sender) }

    public func control(
        _ control: NSControl, textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String] {
        projectForms.directoryPathCompletions(for: control, words: words, indexOfSelectedItem: index)
    }

    public func controlTextDidChange(_ obj: Notification) {
        guard let changedField = obj.object as? NSTextField else { return }
        if changedField === commandPalette.commandPaletteSearchField {
            logHotkeyDebug("search_change query=\(changedField.stringValue)")
            commandPalette.applyCommandPaletteFilter()
            return
        }
        _ = projectForms.handleControlTextDidChange(changedField)
    }

    public func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let comboBox = notification.object as? NSComboBox else { return }
        projectForms.handleComboBoxSelectionDidChange(comboBox)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let textField = control as? NSTextField else { return false }
        if textField === commandPalette.commandPaletteSearchField {
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                commandPalette.moveCommandPaletteSelection(delta: 1)
                return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                commandPalette.moveCommandPaletteSelection(delta: -1)
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                commandPalette.executeSelectedCommandPaletteItem()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                commandPalette.dismissCommandPalette()
                return true
            }
        }
        if textField === devicePairing.renamingClientDeviceField {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                devicePairing.commitClientDeviceRename(deviceID: textField.identifier?.rawValue ?? "", newName: textField.stringValue)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                devicePairing.cancelClientDeviceRename()
                return true
            }
            return false
        }
        if textField === sidebar.renamingRuntimeTargetField {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                sidebar.commitRuntimeTargetRename(newTitle: textField.stringValue)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                sidebar.cancelRuntimeTargetRename()
                return true
            }
            return false
        }
        return false
    }

    @objc private func launchWorkspace(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        sender.isEnabled = false
        Task { @MainActor [weak self, weak sender] in
            await self?.performLaunchWorkspace(id: id)
            sender?.isEnabled = true
        }
    }

    /// Sender-free entry point for the sidebar workspace row's right-click menu, which fires from
    /// an `NSMenuItem` rather than the footer's `NSButton`.
    func launchWorkspace(id: String) { Task { @MainActor [weak self] in await self?.performLaunchWorkspace(id: id) } }

    private func performLaunchWorkspace(id: String) async {
        guard let device = deviceForWorkspaceMutation(workspaceID: id) else {
            showWorkspaceDeviceUnavailableError(workspaceID: id)
            return
        }
        let epoch = panelCoordinator.paneReplacementEpoch
        let result = await Self.deviceMutation(device: device) { device in
            try SpacesDeviceClient.launchWorkspace(
                workspaceID: id,
                context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
        }
        switch result {
        // The overview in the response is the one this device just published, so it is applied to
        // that device's section (`device.id`) rather than re-resolved from the workspace id.
        case .success(let response): applyDeviceMutationResponse(response, deviceID: device.id, epoch: epoch, selectedWorkspaceID: id)
        case .failure(let error): showError(error)
        }
    }

    @objc private func restartWorkspace(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        sender.isEnabled = false
        Task { @MainActor [weak self, weak sender] in
            await self?.performRestartWorkspace(id: id)
            sender?.isEnabled = true
        }
    }

    func restartWorkspace(id: String) { Task { @MainActor [weak self] in await self?.performRestartWorkspace(id: id) } }

    private func performRestartWorkspace(id: String) async {
        let browserSessionTargetURLs = browserSessions.configuredBrowserSessionTargetURLsForTeardown(workspaceID: id)
        guard let device = deviceForWorkspaceMutation(workspaceID: id) else {
            showWorkspaceDeviceUnavailableError(workspaceID: id)
            return
        }
        let epoch = panelCoordinator.paneReplacementEpoch
        let result = await Self.deviceMutation(device: device) { device in
            try SpacesDeviceClient.restartWorkspace(
                workspaceID: id,
                context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
        }
        switch result {
        case .success(let response):
            // Restart goes through the daemon stop path; the daemon does not own the
            // client-side Chrome browser-session tabs, so close them here too for a clean
            // restarted state (a later browser focus then opens fresh tabs).
            self.browserSessions.closeLocalBrowserSessionWindows(workspaceID: id, configuredBrowserSessionTargetURLs: browserSessionTargetURLs)
            self.closeWorkspacePanes(workspaceID: id)
            applyDeviceMutationResponse(response, deviceID: device.id, epoch: epoch, selectedWorkspaceID: id)
        case .failure(let error): showError(error)
        }
    }

    @objc private func stopWorkspace(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        sender.isEnabled = false
        Task { @MainActor [weak self, weak sender] in
            await self?.performStopWorkspace(id: id)
            sender?.isEnabled = true
        }
    }

    func stopWorkspace(id: String) { Task { @MainActor [weak self] in await self?.performStopWorkspace(id: id) } }

    private func performStopWorkspace(id: String) async {
        let browserSessionTargetURLs = browserSessions.configuredBrowserSessionTargetURLsForTeardown(workspaceID: id)
        guard let device = deviceForWorkspaceMutation(workspaceID: id) else {
            showWorkspaceDeviceUnavailableError(workspaceID: id)
            return
        }
        let epoch = panelCoordinator.paneReplacementEpoch
        let result = await Self.deviceMutation(device: device) { device in
            try SpacesDeviceClient.stopWorkspace(
                workspaceID: id,
                context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
        }
        switch result {
        case .success(let response):
            self.browserSessions.closeLocalBrowserSessionWindows(workspaceID: id, configuredBrowserSessionTargetURLs: browserSessionTargetURLs)
            self.closeWorkspacePanes(workspaceID: id)
            applyDeviceMutationResponse(response, deviceID: device.id, epoch: epoch, selectedWorkspaceID: id)
        case .failure(let error): showError(error)
        }
    }

    /// Closes the workspace's open terminal and code panes after the owning daemon confirms a
    /// workspace stop/restart/delete. The terminal sessions are already being stopped by that
    /// mutation, so pane teardown skips the client-detach cleanup path; a code pane has no session to
    /// stop, so it is a pure layout edit either way. Internal rather than `private`: also called from
    /// `WorkspaceDeletionCoordinator.resolveAwaitingWorkspaceDeletions`, which performs the same cleanup
    /// for a delete confirmed by a deferred resolution rather than `deleteWorkspace`'s own response.
    func closeWorkspacePanes(workspaceID: String) {
        panelCoordinator.closeTerminalPanes(workspaceID: workspaceID, sessionIsTerminating: true)
        panelCoordinator.closeCodePanes(workspaceID: workspaceID)
    }

    @objc private func deleteWorkspace(_ sender: Any) {
        guard let id = Self.senderIdentifier(sender) else { return }
        deleteWorkspace(id: id, sender: sender)
    }

    /// Deletes a workspace by id, so the detail ⋯ overflow menu and the sidebar row's right-click menu
    /// share one confirmation and teardown path. `sender` is only used to disable the originating button
    /// while the mutation is in flight; a menu item passes none.
    func deleteWorkspace(id: String, sender: Any? = nil) {
        guard let (project, workspace) = findWorkspace(id: id) else { return }
        if workspace.isDefault {
            showInfoMessage(
                title: "Default Workspace",
                message: "Default workspaces cannot be deleted. Delete the project instead to remove all of its workspaces.")
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete workspace?"
        alert.informativeText =
            "Are you sure you want to delete \"\(workspace.displayName)\"? This stops all running processes, removes its git worktree, and removes the workspace and its settings from Spaces."
        let deleteLocalBranchCheckbox = NSButton(checkboxWithTitle: "Delete local branch", target: nil, action: nil)
        let deleteRemoteBranchCheckbox = NSButton(checkboxWithTitle: "Delete remote branch", target: nil, action: nil)
        if project.isGitRepo, let branch = workspace.branch, !branch.isEmpty {
            deleteLocalBranchCheckbox.title = "Delete local branch (\(branch))"
            deleteRemoteBranchCheckbox.title = "Delete remote branch (\(branch))"
            let checkboxStack = NSStackView(views: [deleteLocalBranchCheckbox, deleteRemoteBranchCheckbox])
            checkboxStack.orientation = .vertical
            checkboxStack.alignment = .leading
            checkboxStack.spacing = 6
            checkboxStack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
            checkboxStack.frame = NSRect(origin: .zero, size: checkboxStack.fittingSize)

            let accessoryFrame = NSRect(origin: .zero, size: checkboxStack.fittingSize)
            let accessoryView = NSView(frame: accessoryFrame)
            accessoryView.addSubview(checkboxStack)
            alert.accessoryView = accessoryView
        }
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let deleteLocalBranch = project.isGitRepo && deleteLocalBranchCheckbox.state == .on
        let deleteRemoteBranch = project.isGitRepo && deleteRemoteBranchCheckbox.state == .on
        let button = sender as? NSButton
        let browserSessionTargetURLs = browserSessions.configuredBrowserSessionTargetURLsForTeardown(workspaceID: id)
        // Route the delete to the daemon that owns the workspace's project rather than the local
        // device, so a remote workspace is deleted where it actually lives.
        let device = deviceForMutation(deviceID: project.deviceID)
        workspaceDeletion.beginPendingWorkspaceDeletion(workspaceID: id, projectID: project.id)
        button?.isEnabled = false
        showOperationProgressOverlay(
            message: "Deleting workspace...", detail: "Stopping runtime state and cleaning up workspace files.", context: .workspace(id))
        Task { @MainActor [weak self, weak button] in
            guard let self else { return }
            defer { hideOperationProgressOverlay() }
            if let device {
                let epoch = self.panelCoordinator.paneReplacementEpoch
                let result = await Self.deviceMutation(device: device) { device in
                    try SpacesDeviceClient.archiveWorkspace(
                        workspaceID: id, deleteLocalBranch: deleteLocalBranch, deleteRemoteBranch: deleteRemoteBranch,
                        context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
                }
                switch result {
                case .success(let response):
                    button?.isEnabled = true
                    self.browserSessions.closeLocalBrowserSessionWindows(workspaceID: id, configuredBrowserSessionTargetURLs: browserSessionTargetURLs)
                    self.closeWorkspacePanes(workspaceID: id)
                    // Install the post-delete overview first, then clear the marking: the workspace is
                    // already absent from that overview, so its row leaves the sidebar exactly once.
                    //
                    // Accepted risk: a remote overview pull that began before this response can land after
                    // the marking clears and re-add the row for one refresh cycle. That needs a pull in
                    // flight inside the seconds-wide delete window, shows a ghost row the next pull
                    // removes, and the fix — a mutation-generation fence across every overview install
                    // path like the iOS model's — is disproportionate to a self-healing flicker.
                    applyDeviceMutationResponse(response, deviceID: device.id, epoch: epoch, selectedProjectID: project.id)
                    self.workspaceDeletion.endPendingWorkspaceDeletion(workspaceID: id)
                    // The daemon only sends a notice when branch deletion did not go as asked (a protected
                    // branch, no recorded branch, or a git failure), so any dialog here is reporting a
                    // problem; a clean delete, including branch boxes ticked with clean outcomes, stays silent.
                    if let notice = response.mutationNotice, !notice.isEmpty { self.showInfoMessage(title: "Deleted workspace", message: notice) }
                case .failure(let error):
                    guard Self.isIndeterminateDeleteOutcome(error) else {
                        // The daemon answered and refused: the workspace was never touched, so the row
                        // goes back to normal — its expansion state included — and the reload re-syncs
                        // whatever the daemon did get through.
                        self.workspaceDeletion.endPendingWorkspaceDeletion(workspaceID: id)
                        requestSidebarReload()
                        button?.isEnabled = true
                        showError(error)
                        return
                    }
                    // The delete's fate is unknown — the daemon may still be tearing the workspace down
                    // (see `isIndeterminateDeleteOutcome`). Un-marking and reporting failure here would
                    // let the user retry-delete a workspace that is already doomed. Reconcile against
                    // fresh overviews instead: every overview that resolves is applied through the same
                    // path a mutation response takes, so the row already reflects reality by the time the
                    // marking clears. If the workspace stops appearing, treat the delete as successful and
                    // surface no error; only report the failure once the reconciliation budget is spent
                    // and the workspace is still listed.
                    let reconciler = WorkspaceDeletionReconciler()
                    // `fetchOverview` detaches per attempt, so the epoch is re-captured before each dial
                    // (not once for the whole reconciliation) and read back by `applyOverview`, which the
                    // reconciler always calls synchronously right after that attempt's fetch resolves.
                    var epochAtLastFetch = self.panelCoordinator.paneReplacementEpoch
                    let outcome = await reconciler.reconcile(
                        workspaceID: id,
                        fetchOverview: { [weak self] in
                            epochAtLastFetch = self?.panelCoordinator.paneReplacementEpoch ?? epochAtLastFetch
                            return await Self.deviceOverviewFetch(device: device)
                        },
                        applyOverview: { [weak self] overview in
                            self?.applyDeviceOverview(overview, deviceID: device.id, epoch: epochAtLastFetch, selectedProjectID: project.id)
                        })
                    // The mutation call itself is done either way, so its button re-enables now — the row
                    // stays inert through the pending-deletion marking, not a stuck in-flight button.
                    button?.isEnabled = true
                    switch outcome {
                    case .unknown:
                        // Every reconciliation refetch failed outright — the transport never answered, so
                        // neither `.present` nor `.gone` is provable and un-marking the row here would be a
                        // guess dressed up as a verdict. Keep the pending-deletion marking (the row stays
                        // inert) and hold the error and this delete's context until a real overview for
                        // this device installs through any path — a background poll, a later reload, or
                        // any other mutation's response — and resolves it
                        // (`WorkspaceDeletionCoordinator.resolveAwaitingWorkspaceDeletions`).
                        self.workspaceDeletion.deferResolution(
                            workspaceID: id, deviceID: device.id, error: error, branchDeletionRequested: deleteLocalBranch || deleteRemoteBranch,
                            browserSessionTargetURLs: browserSessionTargetURLs,
                            overviewInstallGenerationAtDefer: self.deviceModel.deviceSections.first(where: { $0.deviceID == device.id })?
                                .overviewInstallGeneration ?? 0)
                    case .present:
                        // An overview resolved and still lists the workspace: the row goes back to normal
                        // and the held error is real.
                        self.workspaceDeletion.endPendingWorkspaceDeletion(workspaceID: id)
                        requestSidebarReload()
                        showError(error)
                    case .gone:
                        // Reconciliation confirmed the delete landed, so the workspace gets the same client
                        // cleanup a direct success performs — otherwise its browser windows would outlive it
                        // indefinitely.
                        self.workspaceDeletion.endPendingWorkspaceDeletion(workspaceID: id)
                        self.browserSessions.closeLocalBrowserSessionWindows(workspaceID: id, configuredBrowserSessionTargetURLs: browserSessionTargetURLs)
                        self.closeWorkspacePanes(workspaceID: id)
                        if deleteLocalBranch || deleteRemoteBranch {
                            // The delete landed, but the branch-deletion report existed only in the response
                            // that was lost — reconciliation can prove the workspace is gone, not what
                            // happened to branches the user explicitly asked to delete. Say so rather than
                            // silently succeeding.
                            self.showInfoMessage(title: "Deleted workspace", message: Self.workspaceDeletionBranchOutcomeUnknownMessage)
                        }
                    }
                }
            } else {
                self.workspaceDeletion.endPendingWorkspaceDeletion(workspaceID: id)
                button?.isEnabled = true
                showDeviceNotLoadedError()
            }
        }
    }

    @objc func copyDirectoryPath(_ sender: Any) {
        guard let path = Self.senderIdentifier(sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    /// Reveals a workspace directory from the detail Reveal button or the sidebar row menu.
    @objc func revealDirectoryInFinder(_ sender: Any) {
        if let context = Self.senderWorkspacePathActionContext(sender) {
            if showRemoteWorkspacePathActionErrorIfNeeded(.revealInFinder, workspaceID: context.workspaceID) { return }
            revealPathInFinder(context.path)
            return
        }
        if showRemoteWorkspacePathActionErrorIfNeeded(.revealInFinder) { return }
        guard let path = Self.senderIdentifier(sender) else { return }
        revealPathInFinder(path)
    }

    /// Reveals a path and reports a reveal macOS refused, most often a worktree deleted outside
    /// Spaces whose row survives until the next discovery scan retires it. Spaces does not hide
    /// itself for a Finder reveal, so nothing else would explain the absent Finder window: a
    /// discarded `false` here reads as the click having done nothing at all.
    private func revealPathInFinder(_ path: String) {
        guard !NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") else { return }
        showError(WorkspaceError.invalidArgument(message: Self.finderRevealFailureMessage(path: path)))
    }

    /// Accepts the `identifier.rawValue` from either an `NSMenuItem` or any
    /// `NSControl` (buttons, popup buttons). Used so the same @objc action
    /// works whether it's fired from a dir-row button or a ⋯ menu item.
    static func senderIdentifier(_ sender: Any) -> String? {
        if let menuItem = sender as? NSMenuItem { return menuItem.identifier?.rawValue }
        if let control = sender as? NSControl { return control.identifier?.rawValue }
        return nil
    }

    /// Accepts the per-row workspace path context from menu items whose action must resolve
    /// remote/local state against the clicked workspace rather than the current selection.
    static func senderWorkspacePathActionContext(_ sender: Any) -> WorkspacePathActionContext? {
        if let menuItem = sender as? NSMenuItem { return menuItem.representedObject as? WorkspacePathActionContext }
        return nil
    }

    /// Stock `NSMenu` for the workspace detail ⋯ overflow. Items carry the
    /// workspace path (for Copy/Reveal) or workspace ID (for Archive/Hide) in their
    /// `identifier.rawValue`. Reveal also carries the workspace id in
    /// `representedObject` so remote/local gating resolves the action target itself.
    /// `daemonActionsEnabled` is false while the owning device cannot service its daemon: the
    /// menu keeps its shape — the items stay listed so the menu does not reshuffle mid-outage —
    /// and only the ones that need the daemon are disabled. Auto-enabling is off so those
    /// decisions are the menu's own rather than AppKit's responder-chain guess.
    static func makeWorkspaceOverflowMenu(workspaceID: String, path: String, target: AnyObject?, isLocalDevice: Bool, daemonActionsEnabled: Bool)
        -> NSMenu
    {
        let menu = NSMenu()
        menu.autoenablesItems = false

        func addItem(
            title: String, symbol: String?, action: Selector, keyEquivalent: String, modifiers: NSEvent.ModifierFlags, identifier: String,
            representedObject: Any? = nil, isEnabled: Bool = true
        ) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
            item.keyEquivalentModifierMask = modifiers
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
            item.representedObject = representedObject
            item.target = target
            item.isEnabled = isEnabled
            if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            menu.addItem(item)
        }

        addItem(
            title: "Copy path", symbol: "doc.on.doc", action: #selector(AppKitController.copyDirectoryPath(_:)), keyEquivalent: "", modifiers: [],
            identifier: path)
        // Reveal in Finder needs a path on this Mac, so it is offered only for
        // local-device workspaces; remote workspaces live on another daemon.
        if isLocalDevice {
            addItem(
                title: "Reveal in Finder", symbol: "folder", action: #selector(AppKitController.revealDirectoryInFinder(_:)), keyEquivalent: "f",
                modifiers: [.command, .shift], identifier: path, representedObject: WorkspacePathActionContext(workspaceID: workspaceID, path: path))
        }
        menu.addItem(.separator())
        addItem(
            title: "Delete…", symbol: "trash", action: #selector(AppKitController.deleteWorkspace(_:)), keyEquivalent: "", modifiers: [],
            identifier: workspaceID, isEnabled: daemonActionsEnabled)
        return menu
    }

    @objc private func showWorkspaceOverflowMenu(_ sender: NSButton) {
        guard let workspaceID = sender.identifier?.rawValue, let workspace = deviceModel.workspaceIndex[workspaceID]?.workspace else { return }
        let menu = Self.makeWorkspaceOverflowMenu(
            workspaceID: workspaceID, path: workspace.dir, target: self, isLocalDevice: isLocalWorkspace(workspace),
            daemonActionsEnabled: deviceAcceptsDaemonActions(forWorkspaceID: workspaceID))
        let origin = NSPoint(x: 0, y: sender.bounds.maxY + 4)
        menu.popUp(positioning: nil, at: origin, in: sender)
    }

    func showError(_ error: Error) {
        if showLocalDaemonCompatibilityBlockIfNeeded(error) { return }
        let alert = NSAlert(error: error)
        alert.runModal()
    }

    nonisolated static func shouldShowLocalDaemonCompatibilityBlock(for error: Error) -> Bool {
        if let terminalError = error as? TerminalServiceError, case .daemonWireIncompatible = terminalError { return true }
        return false
    }

    @discardableResult func showLocalDaemonCompatibilityBlockIfNeeded(_ error: Error) -> Bool {
        if Self.shouldShowLocalDaemonCompatibilityBlock(for: error), let terminalError = error as? TerminalServiceError,
            case .daemonWireIncompatible(let incompatibility) = terminalError
        {
            showLocalDaemonCompatibilityBlock(incompatibility)
            return true
        }
        return false
    }

    private func showLocalDaemonCompatibilityBlock(_ incompatibility: TerminalServiceDaemonWireIncompatibility) {
        let storedLocalDevice = deviceModel.localPairedDevice ?? (try? clientDatabase().pairedDevice(id: SpacesPairedDeviceRecord.localDeviceID))
        if let storedLocalDevice {
            deviceModel.localPairedDevice = storedLocalDevice
            deviceModel.localDeviceID = storedLocalDevice.id
            deviceModel.localDeviceName = storedLocalDevice.name
        }
        if let index = deviceModel.deviceSections.firstIndex(where: { $0.deviceID == deviceModel.localDeviceID }) {
            deviceModel.deviceSections[index].device = storedLocalDevice ?? deviceModel.deviceSections[index].device
            deviceModel.deviceSections[index].daemonStatus = incompatibility.status
            deviceModel.deviceSections[index].compatibility = incompatibility.verdict
            deviceModel.deviceSections[index].projects = []
            deviceModel.deviceSections[index].workspacesByProject = [:]
            deviceModel.deviceSections[index].workspaceRuntimeStatusByID = [:]
            deviceModel.deviceSections[index].alertsGroups = []
            deviceModel.deviceSections[index].overview = nil
            deviceModel.deviceSections[index].loadState = .loaded
        } else {
            deviceModel.deviceSections.insert(
                DeviceSection(
                    deviceID: deviceModel.localDeviceID, deviceName: deviceModel.localDeviceName, isLocal: true, loadState: .loaded, device: storedLocalDevice, overview: nil,
                    daemonStatus: incompatibility.status, compatibility: incompatibility.verdict), at: 0)
        }
        rebuildFlatSidebarData()
        fullReloadSidebarOutline()
        // This is the cold-start path: local bootstrap failed wire-incompatible before any
        // `TerminalServiceDaemonStatus` could land through a snapshot, so none of the usual
        // silent-apply call sites (`applySidebarDataSnapshot`, remote pull/push) ever ran for
        // this device. If a staged update is what made the daemon incompatible, launching the
        // app must itself request the apply here, or `shouldRenderCompatibilityBlock` withholds
        // the block for `.applyStagedUpdate` on the premise that a handoff is already under way
        // while nothing has asked for one, leaving the loading placeholder up indefinitely.
        daemonUpdate.maybeRequestSilentDaemonHandoff(deviceID: deviceModel.localDeviceID, status: incompatibility.status)
        showCompatibilityBlock(deviceID: deviceModel.localDeviceID, verdict: incompatibility.verdict)
        if let window { revealTargetedHotkeyWindow(window) }
    }

    /// Internal rather than `private`: also called from
    /// `WorkspaceDeletionCoordinator.resolveAwaitingWorkspaceDeletions` to surface a deferred delete's
    /// held-back error or lost branch-outcome notice.
    func showInfoMessage(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func showRemoteWorkspacePathActionErrorIfNeeded(_ action: WorkspacePathAction, workspaceID: String? = nil) -> Bool {
        // Editor/Finder actions need a path on this Mac; gate them when the affected
        // workspace lives on a remote device. The action carries its own workspace
        // id, which can differ from the selected row, so resolve the owning device
        // from it and use the selection only for path-based callers that name no workspace.
        let targetDeviceID: String?
        if let workspaceID {
            // No loaded section claims this workspace, so we cannot tell whether its path is on
            // this Mac. Refuse the action instead of pointing Finder/the editor at a path that
            // belongs to another machine.
            guard let resolved = deviceID(forWorkspaceID: workspaceID) else {
                showDeviceNotLoadedError()
                return true
            }
            targetDeviceID = resolved
        } else {
            targetDeviceID = selectedRowDeviceID()
        }
        guard let targetDeviceID, let section = deviceModel.deviceSections.first(where: { $0.deviceID == targetDeviceID }), !section.isLocal else { return false }
        showError(WorkspaceError.invalidArgument(message: Self.remoteWorkspacePathActionErrorMessage(action: action, deviceName: section.deviceName)))
        return true
    }

    /// The configured editor resolved to a launchable CLI, carrying the per-family data a
    /// remote open needs: VS Code-family editors keep their `EditorRemoteSSHSupport` (for
    /// extension detection); Zed needs only its CLI path because remoting is built in.
    private enum EditorLaunchTarget {
        case vscode(editor: EditorPreference, support: EditorRemoteSSHSupport)
        case zed(editor: EditorPreference, cliExecutablePath: String)

        var cliExecutablePath: String {
            switch self {
            case .vscode(_, let support): return support.cliExecutableURL.path
            case .zed(_, let cli): return cli
            }
        }
    }

    /// The single dispatch point for every "open editor" action (⌘⌥E, the sidebar's "Open in
    /// Editor" item, the command palette): resolves the configured `EditorPreference` — `.builtin`
    /// when unset, since that is the default — and either focuses the global Editor window in-process
    /// or launches the configured external editor. Returns whether the open succeeded (errors are
    /// still presented here, exactly as before).
    ///
    /// The builtin branch keys the Editor window synchronously, so ANY entry point that runs while
    /// the command palette is key must dismiss the palette first: an open palette resigning key
    /// mid-open would run its ORDINARY dismissal, whose return-focus restore would pull key straight
    /// back from the Editor. That dismiss-before-open (and restore-on-failure) contract is centralized
    /// in `commandPalette.withPaletteDismissedForBuiltInOpen`, which no-ops when the palette isn't
    /// visible, so every caller gets it for free without needing to know whether the palette is
    /// involved.
    ///
    /// The external-editor branch below keeps its own, different contract: it dismisses the palette
    /// only AFTER a successful launch (see its comment), since a declined or failed external launch
    /// should leave the palette open rather than silently closing it.
    @discardableResult func openWorkspaceEditor(workspaceID: String) -> Bool {
        do {
            guard let (project, workspace) = findWorkspace(id: workspaceID) else {
                throw WorkspaceError.invalidArgument(message: "Workspace not found.")
            }
            let editor = try clientAppConfig().editor ?? .builtin
            if editor == .builtin {
                // The coordinator reports false when no Editor exists and its creation door is
                // closed (e.g. the workspace's device is unreachable) — that is a failed open, and
                // `withPaletteDismissedForBuiltInOpen` restores the palette's return focus for it.
                return commandPalette.withPaletteDismissedForBuiltInOpen {
                    self.panelCoordinator.openOrFocusGlobalEditorWindow(deviceID: project.deviceID, workspaceID: workspaceID)
                }
            }
            let target = try resolveEditorLaunch(editor)
            // The owning device comes from the row the workspace was found in, so the
            // remote/local branch below can never run the local path for a remote workspace.
            let deviceID = project.deviceID
            if isRemoteDeviceID(deviceID) {
                // A remote launch dials the paired device directly over SSH — the editor's own
                // connection, entirely outside this Mac's daemon session with that device — but
                // `deviceAcceptsDaemonActions` is still the only signal Spaces has for whether the
                // device is currently reachable at all. Attempting the launch anyway while it is
                // offline just trades a clear "device offline" message for a confusing failure
                // buried inside the editor's own SSH handshake, so this is gated the same way the
                // code-pane creation door is (`PanelCoordinator.mayCreateCodePane`). A local launch
                // needs no such check: it runs the editor CLI directly with no daemon involved, and
                // this Mac's own daemon being down is the separate, already-handled case in
                // `deviceUnreachableError`'s `isLocal` branch.
                guard deviceAcceptsDaemonActions(forDeviceID: deviceID) else {
                    showWorkspaceDeviceUnavailableError(workspaceID: workspaceID)
                    return false
                }
                guard let device = deviceRecord(forDeviceID: deviceID), let sshHost = device.sshHost?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !sshHost.isEmpty
                else { throw WorkspaceError.invalidArgument(message: "Remote editor launch requires SSH settings for the paired device.") }
                switch target {
                case .vscode(let editor, let support):
                    // The user can decline the SSH-remote extension install this prompts for; that
                    // cancellation is itself a failure to open, not an error to present (the prompt
                    // already explained the choice), so it reports false like any other non-open.
                    guard ensureRemoteSSHCapability(editor: editor, support: support) else { return false }
                    try EditorLauncher.openRemoteVSCode(
                        cliExecutablePath: support.cliExecutableURL.path, sshHost: sshHost, sshUser: device.sshUser, sshPort: device.sshPort,
                        directory: workspace.dir)
                case .zed(_, let cliExecutablePath):
                    try EditorLauncher.openRemoteZed(
                        cliExecutablePath: cliExecutablePath, sshHost: sshHost, sshUser: device.sshUser, sshPort: device.sshPort,
                        directory: workspace.dir)
                }
            } else {
                try EditorLauncher.open(cliExecutablePath: target.cliExecutablePath, directory: workspace.dir)
            }
            reloadData()
            // The palette is dismissed without its return-focus restore so closing it cannot pull
            // focus back from the editor. When the palette was the only visible Spaces window,
            // that leaves no Spaces window on screen: accepted, because the palette closes for
            // every action it takes and the main window was already hidden before the editor was
            // asked for.
            commandPalette.dismissCommandPaletteForBuiltInWindowNavigation()
            return true
        } catch {
            showError(error)
            return false
        }
    }

    /// Resolves an external editor preference (never `.builtin`, intercepted by the caller before this
    /// runs) to a launchable CLI from its installed bundle, throwing a clear error when it is not
    /// installed.
    private func resolveEditorLaunch(_ editor: EditorPreference) throws -> EditorLaunchTarget {
        guard let bundleID = editor.bundleIdentifier else { throw WorkspaceError.configError(message: "Preferred editor is not configured.") }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw WorkspaceError.invalidArgument(message: "\(editor.displayName) is not installed.")
        }
        switch editor.family {
        case .vscode:
            guard let support = EditorRemoteSSHSupport(appBundleURL: appURL) else {
                throw WorkspaceError.invalidArgument(message: "\(editor.displayName) is not installed.")
            }
            return .vscode(editor: editor, support: support)
        case .zed:
            let cli = appURL.appendingPathComponent("Contents/MacOS/cli")
            guard FileManager.default.isExecutableFile(atPath: cli.path) else {
                throw WorkspaceError.invalidArgument(message: "\(editor.displayName) is not installed.")
            }
            return .zed(editor: editor, cliExecutablePath: cli.path)
        }
    }

    /// Ensures the editor can resolve a `vscode-remote://ssh-remote+` workspace before a
    /// remote open. Returns true to proceed. When the editor ships no SSH-remote extension
    /// (stock VS Code), prompts the user to install one and returns true only after a
    /// successful install; the forks bundle their own, so this passes for them.
    private func ensureRemoteSSHCapability(editor: EditorPreference, support: EditorRemoteSSHSupport) -> Bool {
        if support.hasRemoteSSHExtension(homeDirectory: FileManager.default.homeDirectoryForCurrentUser) { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(editor.displayName) needs the Remote-SSH extension"
        guard let extensionID = editor.installableRemoteSSHExtensionID else {
            alert.informativeText = "Install an SSH-remote extension in \(editor.displayName) to open remote workspaces over SSH."
            alert.runModal()
            return false
        }
        alert.informativeText =
            "Opening a remote workspace runs it over SSH inside \(editor.displayName), which needs its Remote-SSH extension. Install it now?"
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            try EditorLauncher.installRemoteSSHExtension(cliExecutablePath: support.cliExecutableURL.path, extensionID: extensionID)
            return true
        } catch {
            showError(error)
            return false
        }
    }

    // Not private: `ShortcutsController`'s shortcut monitor references `.shortcut` from a different
    // file in the same module (cross-file `private` isn't visible).
    enum WorkspaceTerminalOpenRoute: String {
        case button
        case shortcut
        case ipc
    }

    // Not private: `ShortcutsController`'s shortcut monitor calls this from a different file in the
    // same module (cross-file `private` isn't visible).
    func openWorkspaceTerminal(workspaceID: String, route: WorkspaceTerminalOpenRoute, completion: (() -> Void)? = nil) {
        guard beginNewTerminalSessionCreation(workspaceID: workspaceID) else {
            completion?()
            return
        }
        let startedAt = Date()
        terminalPanes.createTerminalSessionForPane(workspaceID: workspaceID) { [weak self] request in
            guard let self else { return }
            defer {
                self.finishNewTerminalSessionCreation(workspaceID: workspaceID)
                completion?()
            }
            guard let request else {
                logPerfMetric(
                    "workspace_terminal_open_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                    success: false, detail: "route=\(route.rawValue)")
                return
            }
            panelCoordinator.openSessionInNewTab(request)
            logPerfMetric(
                "workspace_terminal_open_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true,
                detail: "route=\(route.rawValue)")
        }
    }

    private func runWorkspaceProcess(workspaceID: String, processName: String) {
        let startedAt = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let device = deviceForWorkspaceMutation(workspaceID: workspaceID) {
                let epoch = self.panelCoordinator.paneReplacementEpoch
                let result = await Self.deviceMutation(device: device) { device in
                    try SpacesDeviceClient.runWorkspaceProcess(
                        workspaceID: workspaceID, processKey: processName, processTemplateID: nil,
                        context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
                }
                switch result {
                case .success(let response):
                    logPerfMetric(
                        "workspace_process_launch_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                        success: true, detail: "route=ipc name=\(processName)")
                    applyDeviceMutationResponse(response, deviceID: device.id, epoch: epoch, selectedWorkspaceID: workspaceID)
                case .failure(let error):
                    logPerfMetric(
                        "workspace_process_launch_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                        success: false, detail: "route=ipc name=\(processName)")
                    showError(error)
                }
                return
            }
            logPerfMetric(
                "workspace_process_launch_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                success: false, detail: "route=ipc name=\(processName)")
            showWorkspaceDeviceUnavailableError(workspaceID: workspaceID)
        }
    }

    private func stopWorkspaceProcess(workspaceID: String, processName: String) {
        let startedAt = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let device = deviceForWorkspaceMutation(workspaceID: workspaceID) {
                    let epoch = self.panelCoordinator.paneReplacementEpoch
                    let response = try SpacesDeviceClient.stopWorkspaceProcess(
                        workspaceID: workspaceID, processID: nil, processKey: processName, processTemplateID: nil,
                        context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
                    logPerfMetric(
                        "workspace_process_stop_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                        success: true, detail: "route=ipc name=\(processName)")
                    applyDeviceMutationResponse(response, deviceID: device.id, epoch: epoch, selectedWorkspaceID: workspaceID)
                    return
                }
                logPerfMetric(
                    "workspace_process_stop_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                    success: false, detail: "route=ipc name=\(processName)")
                showWorkspaceDeviceUnavailableError(workspaceID: workspaceID)
            } catch {
                logPerfMetric(
                    "workspace_process_stop_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                    success: false, detail: "route=ipc name=\(processName)")
                showError(error)
            }
        }
    }

    private func restartWorkspaceProcess(workspaceID: String, processName: String) {
        let startedAt = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let device = deviceForWorkspaceMutation(workspaceID: workspaceID) {
                    let epoch = self.panelCoordinator.paneReplacementEpoch
                    let response = try SpacesDeviceClient.restartWorkspaceProcess(
                        workspaceID: workspaceID, processID: nil, processKey: processName, processTemplateID: nil,
                        context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
                    logPerfMetric(
                        "workspace_process_restart_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                        success: true, detail: "route=ipc name=\(processName)")
                    applyDeviceMutationResponse(response, deviceID: device.id, epoch: epoch, selectedWorkspaceID: workspaceID)
                    return
                }
                logPerfMetric(
                    "workspace_process_restart_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                    success: false, detail: "route=ipc name=\(processName)")
                showWorkspaceDeviceUnavailableError(workspaceID: workspaceID)
            } catch {
                logPerfMetric(
                    "workspace_process_restart_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                    success: false, detail: "route=ipc name=\(processName)")
                showError(error)
            }
        }
    }

    // Not private: `ShortcutsController`'s shortcut monitor calls this from a different file in the
    // same module (cross-file `private` isn't visible).
    func openWorkspaceFinder(workspaceID: String) {
        if showRemoteWorkspacePathActionErrorIfNeeded(.revealInFinder, workspaceID: workspaceID) { return }
        guard let (_, workspace) = findWorkspace(id: workspaceID) else { return }
        let url = URL(fileURLWithPath: workspace.dir, isDirectory: true)
        guard NSWorkspace.shared.open(url) else {
            showError(WorkspaceError.invalidArgument(message: Self.finderRevealFailureMessage(path: workspace.dir)))
            return
        }
    }

    /// One message for every Finder reveal entry point: the keyboard shortcut, the workspace
    /// detail Reveal button, and the sidebar row menu.
    nonisolated static func finderRevealFailureMessage(path: String) -> String { "Spaces could not reveal \(path) in Finder." }

    private func normalizePath(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }

    private func setupMouseFocusMonitor() {
        // A click inside a terminal surface is consumed by that surface, so `PaneView` never sees the
        // mouseDown and the focused-pane indicator would otherwise update only once the user starts typing
        // (the keyDown path below). Sync the focused pane after each left click settles the first responder.
        //
        // This fires on mouseUP, not mouseDOWN: a focus change rebuilds the pane tree (PaneTreeView.render
        // re-parents every surface view), and doing that between the surface's mouseDown and mouseUp yanks
        // the surface out of the hierarchy so AppKit never delivers the mouseUp. The terminal would then miss
        // its mouse-release and stay stuck in a selection drag on every hover. Waiting for mouseUp lets the
        // surface complete its press→release pair before the rebuild; the async hop defers the rebuild past
        // this event's own delivery so the release still lands.
        mouseFocusMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                guard let self, let content = self.panelCoordinator.contentOwning(responder: NSApp.keyWindow?.firstResponder) else { return }
                self.panelCoordinator.noteContentFocused(content)
            }
            return event
        }
    }

    private func releaseLaunchLeases() {
        desktopControlLease?.release()
        desktopControlLease = nil
        appOwnerLease.release()
    }

    private func attemptDesktopControlRecoveryIfNeeded() {
        guard desktopControlLease == nil else { return }
        do {
            switch try SpacesLeaseCoordinator.acquireDesktopControlLease(profile: launchProfile) {
            case .acquired(let lease):
                desktopControlLease = lease
                passiveDesktopControlOwner = nil
                shortcuts.setupGlobalHotkey()
                refreshDesktopControlStatusUI()
            case .busy(let owner):
                passiveDesktopControlOwner = owner
                refreshDesktopControlStatusUI()
            }
        } catch { logHotkeyDebug("desktop_control_recovery_failed error=\(error.localizedDescription)") }
    }

    /// The titlebar is hidden, so the passive desktop-control state surfaces as a
    /// warning icon in the sidebar top bar instead of the window subtitle.
    private func refreshDesktopControlStatusUI() {
        guard let statusIcon = sidebar.desktopControlStatusIcon else { return }
        statusIcon.isHidden = passiveDesktopControlOwner == nil
        statusIcon.toolTip = "Global shortcuts unavailable while another Spaces instance owns desktop control."
    }

    nonisolated static func shouldAttemptDesktopControlRecovery(passiveOwnerPID: Int32?, terminatedApplicationPID: Int32?) -> Bool {
        guard let passiveOwnerPID, let terminatedApplicationPID else { return false }
        return passiveOwnerPID == terminatedApplicationPID
    }

    /// ⌘W closes the active panel's focused pane — the last pane of a tab takes the
    /// tab with it, and a global panel window's last tab closes the window. In the
    /// main window it targets the selected workspace's panel; with no pane to close,
    /// ⌘W keeps its default behavior.
    // Not private: `ShortcutsController`'s shortcut monitor calls this from a different file in the
    // same module (cross-file `private` isn't visible).
    func handleClosePaneShortcut(event: NSEvent) -> Bool {
        guard
            Self.isClosePaneShortcut(
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                eventModifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        else { return false }
        if let panelWindowID = panelCoordinator.panelWindowID(forWindow: NSApp.keyWindow) {
            return panelCoordinator.closeFocusedPane(scope: .globalWindow(panelWindowID: panelWindowID))
        }
        guard NSApp.keyWindow === window, let workspaceID = selectedWorkspaceID, let deviceID = deviceID(forWorkspaceID: workspaceID) else {
            return false
        }
        return panelCoordinator.closeFocusedPane(scope: .workspace(deviceID: deviceID, workspaceID: workspaceID))
    }

    /// Plain ⌘W — no other chord modifiers, so terminal/app chords like ⌘⇧W or ⌥⌘W
    /// stay untouched.
    nonisolated static func isClosePaneShortcut(charactersIgnoringModifiers: String?, eventModifiers: NSEvent.ModifierFlags) -> Bool {
        guard charactersIgnoringModifiers?.lowercased() == "w" else { return false }
        return eventModifiers.intersection([.command, .option, .control, .shift]) == .command
    }

    enum NewTabShortcutAction: Equatable, Sendable { case presentPicker, consume, pass }

    /// ⌘T gating: present only when the main window is key with a workspace selected.
    /// While the session picker is up the chord is consumed so re-press is an explicit
    /// no-op; in a global panel window it is consumed so it can't fall through to the
    /// focused pane; other focused text inputs (rename editors) keep the chord.
    nonisolated static func newTabShortcutAction(
        sessionPickerIsActive: Bool, textInputIsFocused: Bool, keyWindowIsPanelWindow: Bool, keyWindowIsMainWindow: Bool, selectedWorkspaceID: String?
    ) -> NewTabShortcutAction {
        if sessionPickerIsActive { return .consume }
        if textInputIsFocused { return .pass }
        if keyWindowIsPanelWindow { return .consume }
        guard keyWindowIsMainWindow, selectedWorkspaceID != nil else { return .pass }
        return .presentPicker
    }

    /// ⌘T (configurable): opens the session-picker new-tab flow. Placed ahead of the
    /// `isTextInputFocused()` early-return in `setupShortcutMonitor` so the chord still
    /// reaches this gate while the command-palette search field is focused; see
    /// `newTabShortcutAction` for the full disposition table.
    // Not private: `ShortcutsController`'s shortcut monitor calls this from a different file in the
    // same module (cross-file `private` isn't visible).
    func handleNewTabSessionPickerShortcut(event: NSEvent) -> Bool {
        guard let newTabShortcutSpec = shortcuts.newTabShortcutSpec, shortcuts.matches(event: event, spec: newTabShortcutSpec) else { return false }
        switch Self.newTabShortcutAction(
            sessionPickerIsActive: commandPalette.sessionPickerContext != nil, textInputIsFocused: isTextInputFocused(),
            keyWindowIsPanelWindow: panelCoordinator.panelWindowID(forWindow: NSApp.keyWindow) != nil,
            keyWindowIsMainWindow: NSApp.keyWindow === window, selectedWorkspaceID: selectedWorkspaceID)
        {
        case .pass: return false
        case .consume: return true
        case .presentPicker:
            guard let workspaceID = selectedWorkspaceID, let deviceID = deviceID(forWorkspaceID: workspaceID) else { return false }
            presentNewTabSessionPicker(scope: .workspace(deviceID: deviceID, workspaceID: workspaceID))
            return true
        }
    }

    // Not private: `ShortcutsController`'s shortcut monitor calls this from a different file in the
    // same module (cross-file `private` isn't visible).
    func isTextInputFocused() -> Bool {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return false }
        if let textView = window.firstResponder as? NSTextView { return textView.isEditable || textView.isFieldEditor }
        return false
    }

    // Not private: `ShortcutsController`'s shortcut monitor calls this from a different file in the
    // same module (cross-file `private` isn't visible).
    func handleFocusedTextInputShortcut(event: NSEvent) -> Bool {
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

    /// Whether clearing the outline selection should fall back to the detail placeholder.
    ///
    /// Alerts and Automations both clear the outline selection while presenting themselves, and that
    /// `deselectAll` re-enters `outlineViewSelectionDidChange` synchronously. Presenting the placeholder
    /// from there resets the detail pane to `.none` underneath the pane that just opened, which leaves
    /// the pane rendered but no longer identified as showing. Sidebar arrow navigation reads those pane
    /// flags to know where the selection currently sits, so it then has neither a pane nor a selected
    /// row to move from and stops responding.
    nonisolated static func sidebarClearedSelectionPresentsPlaceholder(showingAlerts: Bool, showingAutomations: Bool) -> Bool {
        !showingAlerts && !showingAutomations
    }

    nonisolated static func sidebarArrowSelectionTarget(
        visibleWorkspaceIDsByProject: [(projectID: String, workspaceIDs: [String])], hiddenWorkspaceIDs: [String], selectedProjectID: String?,
        selectedWorkspaceID: String?, showingAlerts: Bool, showingAutomations: Bool, direction: Int
    ) -> SidebarArrowSelectionTarget? {
        guard direction == -1 || direction == 1 else { return nil }
        let visibleWorkspaceIDs = visibleWorkspaceIDsByProject.flatMap(\.workspaceIDs) + hiddenWorkspaceIDs
        // Top-level row order is Alerts ↔ Automations ↔ first workspace; the Automations row is always present.
        if showingAlerts { return direction > 0 ? .automations : nil }
        if showingAutomations {
            guard direction > 0 else { return .alerts }
            guard let firstWorkspaceID = visibleWorkspaceIDs.first else { return nil }
            return .workspace(firstWorkspaceID)
        }
        if let selectedWorkspaceID, let currentIndex = visibleWorkspaceIDs.firstIndex(of: selectedWorkspaceID) {
            let targetIndex = currentIndex + direction
            if targetIndex < 0 { return .automations }
            guard targetIndex < visibleWorkspaceIDs.count else { return nil }
            return .workspace(visibleWorkspaceIDs[targetIndex])
        }
        guard let selectedProjectID, let projectIndex = visibleWorkspaceIDsByProject.firstIndex(where: { $0.projectID == selectedProjectID }) else {
            return nil
        }
        if direction < 0 {
            let priorProjects = visibleWorkspaceIDsByProject[..<projectIndex].reversed()
            for project in priorProjects { if let workspaceID = project.workspaceIDs.last { return .workspace(workspaceID) } }
            return .automations
        }
        for project in visibleWorkspaceIDsByProject[(projectIndex + 1)...] {
            if let workspaceID = project.workspaceIDs.first { return .workspace(workspaceID) }
        }
        if let hiddenWorkspaceID = hiddenWorkspaceIDs.first { return .workspace(hiddenWorkspaceID) }
        return nil
    }

    /// The ⌘⌥E shortcut and every other "open editor" entry point (sidebar "Open in Editor", palette)
    /// resolve "which workspace" the same way: a focused tracked Chrome window, else the app's selected
    /// workspace, else the daemon's last-active workspace.
    // Not private: `ShortcutsController.handleGlobalHotkey` calls this from a different file in the
    // same module (cross-file `private` isn't visible).
    func openGlobalEditorFromHotkey() {
        guard let workspaceID = globalEditorWorkspaceID() else { return }
        openWorkspaceEditor(workspaceID: workspaceID)
    }

    private func globalEditorWorkspaceID() -> String? {
        if let workspaceID = clientWorkspaceIDForFocusedWindow() { return workspaceID }
        if NSApp.isActive, let selectedWorkspaceID { return selectedWorkspaceID }
        if let workspaceID = clientActiveWorkspaceID() { return workspaceID }
        return nil
    }

    /// Retargets the Editor window's orphaned pane — one `pruneOpenCodePanes` reports still pointed at
    /// `goneWorkspaceID` after that workspace left a device's overview — to the workspace ⌘⌥E would open
    /// next, or closes the window outright when no workspace remains anywhere to show. The Editor must
    /// not simply keep pointing at the gone workspace: every bridge call it makes would fail.
    func resolveOrphanedGlobalEditorPane(excluding goneWorkspaceID: String) {
        if let fallback = globalEditorFallbackWorkspaceID(excluding: goneWorkspaceID, allowedWorkspaceKeys: nil) {
            panelCoordinator.retargetGlobalWindowCodePanes(toDeviceID: fallback.deviceID, workspaceID: fallback.workspaceID)
        } else {
            panelCoordinator.closeGlobalEditorCodePane()
        }
    }

    /// Mirrors `globalEditorWorkspaceID`'s own chain (focused tracked window, selected workspace,
    /// daemon's last-active workspace) but skips a candidate that names `goneWorkspaceID` or no longer
    /// exists, falling through to the next link exactly as the task's "same chain" rule asks. Reads
    /// `deviceSections` rather than `findWorkspace`/`projects`: the overview-apply call sites that feed
    /// `resolveOrphanedGlobalEditorPane` update `deviceSections` before pruning but rebuild the flat
    /// sidebar data (what `findWorkspace` reads) only afterward, so `findWorkspace` would still report
    /// the just-deleted workspace as present.
    /// When every chain candidate is itself unusable, falls through to the first workspace found on any
    /// device — otherwise a stray cached selection elsewhere could close the Editor while other
    /// workspaces are still open. Nil only when no workspace exists anywhere.
    /// `allowedWorkspaceKeys` constrains startup restoration to workspaces whose device overview is
    /// loaded; the live deletion path passes nil because its already-open Editor follows the ordinary
    /// device availability behavior.
    func globalEditorFallbackWorkspaceID(excluding goneWorkspaceID: String?, allowedWorkspaceKeys: Set<PanelLayoutEngine.WorkspaceKey>?) -> (
        deviceID: String, workspaceID: String
    )? {
        func candidate(_ workspaceID: String?) -> (deviceID: String, workspaceID: String)? {
            guard let workspaceID, workspaceID != goneWorkspaceID else { return nil }
            guard let section = deviceModel.deviceSections.first(where: { $0.workspacesByProject.values.contains { $0.contains { $0.id == workspaceID } } })
            else { return nil }
            if let allowedWorkspaceKeys, !allowedWorkspaceKeys.contains(.init(deviceID: section.deviceID, workspaceID: workspaceID)) { return nil }
            return (section.deviceID, workspaceID)
        }
        if let match = candidate(clientWorkspaceIDForFocusedWindow()) { return match }
        if NSApp.isActive, let match = candidate(selectedWorkspaceID) { return match }
        if let match = candidate(clientActiveWorkspaceID()) { return match }
        for section in deviceModel.deviceSections {
            for workspaces in section.workspacesByProject.values {
                if let workspace = workspaces.first(where: { workspace in
                    workspace.id != goneWorkspaceID
                        && (allowedWorkspaceKeys?.contains(.init(deviceID: section.deviceID, workspaceID: workspace.id)) ?? true)
                }) {
                    return (section.deviceID, workspace.id)
                }
            }
        }
        return nil
    }

    /// Which pane a summon should select. A focused tracked workspace window is an explicit signal to
    /// switch to that workspace; without one the summon carries no view intent, so `nil` means keep
    /// whatever pane was already visible rather than switching the user's view for them.
    nonisolated static func activationSelectionTarget(focusedWorkspaceID: String?) -> SidebarArrowSelectionTarget? {
        guard let focusedWorkspaceID else { return nil }
        return .workspace(focusedWorkspaceID)
    }

    /// The macOS client's app config is just the editor preference (client-local in the client
    /// database). The port range is daemon-owned and never read by the GUI, so it carries a
    /// placeholder rather than a daemon-DB read — keeping config sourcing off the orchestrator.
    nonisolated static func clientAppConfig() throws -> AppConfig {
        let editor = try SpacesClientDatabase.defaultDatabase().setting(key: ClientSettingsKey.appEditor).flatMap(EditorPreference.init(rawValue:))
        return AppConfig(editor: editor, portRange: .default)
    }

    private func clientAppConfig() throws -> AppConfig {
        let editor = try clientDatabase().setting(key: ClientSettingsKey.appEditor).flatMap(EditorPreference.init(rawValue:))
        return AppConfig(editor: editor, portRange: .default)
    }

    private func clientActiveWorkspaceID() -> String? { try? clientDatabase().setting(key: ClientSettingsKey.activeWorkspaceID) }

    nonisolated static func setClientActiveWorkspaceID(_ workspaceID: String?) {
        try? SpacesClientDatabase.setDefaultSetting(key: ClientSettingsKey.activeWorkspaceID, value: workspaceID)
    }

    func performWindowFocus(_ request: WindowFocusRequest) async {
        guard await executeWindowFocus(request) else { return }
        reloadData()
    }

    /// Resolves an explicit focus request against its workspace's overview and focuses the
    /// client's window for it, returning whether a target was focused. Shared by the command
    /// palette and attention-item focus. A missing window is reopened by the executor itself,
    /// so there is no separate recovery prompt.
    func executeWindowFocus(_ request: WindowFocusRequest) async -> Bool {
        guard let overview = overview(forWorkspaceID: request.workspaceID) else { return false }
        let targetContext = Self.windowFocusTarget(for: request, overview: overview)
        return await executeWindowFocusResolution(
            Self.windowFocusResolution(for: request, overview: overview), preferredTarget: targetContext?.target,
            preferredDetail: targetContext?.detail)
    }

    // Not private: `ShortcutsController`'s shortcut monitor calls this from a different file in the
    // same module (cross-file `private` isn't visible).
    func runWindowShortcut(index: Int, startedAt: Date) async {
        activeWindowShortcutProfile = WindowShortcutProfile(index: index, startedAt: startedAt)
        logWindowShortcutProfile("stage=received index=\(index) alerts=\(showingAlerts ? 1 : 0)")
        let shortcutDispatchMS = windowShortcutElapsedMS(since: startedAt)
        let resolutionStartedAt = Date()
        let resolutionContext = windowShortcutResolutionContext(index: index)
        let targetResolutionMS = windowShortcutElapsedMS(since: resolutionStartedAt)
        await dispatchWindowShortcut(
            resolutionContext, index: index, startedAt: startedAt, shortcutDispatchMS: shortcutDispatchMS, targetResolutionMS: targetResolutionMS)
    }

    /// Resolves a window-shortcut press to a device-agnostic focus target. Alerts focus
    /// uses the clicked attention item; otherwise the target is reconstructed from the
    /// selected workspace's overview — the same path for local and remote workspaces.
    private func windowShortcutResolutionContext(index: Int) -> WindowFocusResolutionContext {
        if showingAlerts {
            guard let request = alerts.alertsFocusRequest(for: index) else {
                return WindowFocusResolutionContext(resolution: .noMatch, target: nil, detail: nil)
            }
            guard let overview = overview(forWorkspaceID: request.workspaceID) else {
                return WindowFocusResolutionContext(resolution: .noMatch, target: nil, detail: nil)
            }
            let targetContext = Self.windowFocusTarget(for: request, overview: overview)
            return WindowFocusResolutionContext(
                resolution: Self.windowFocusResolution(for: request, overview: overview), target: targetContext?.target, detail: targetContext?.detail
            )
        }
        guard let selectedWorkspaceID else { return WindowFocusResolutionContext(resolution: .noWorkspace, target: nil, detail: nil) }
        guard let overview = overview(forWorkspaceID: selectedWorkspaceID) else {
            return WindowFocusResolutionContext(resolution: .noWorkspace, target: nil, detail: nil)
        }
        guard index > 0 else { return WindowFocusResolutionContext(resolution: .noMatch, target: nil, detail: nil) }
        guard let deviceWorkspace = overview.workspaces.first(where: { $0.id == selectedWorkspaceID }) else {
            return WindowFocusResolutionContext(resolution: .noWorkspace, target: nil, detail: nil)
        }
        let detail = SpacesDeviceWorkspaceDetailViewModel(workspace: deviceWorkspace)
        let targets = Self.workspaceShortcutTargets(
            detail: detail, browserSessions: detail.config.resolvedBrowserSessions.map(Self.localBrowserSession(from:)))
        guard targets.indices.contains(index - 1) else { return WindowFocusResolutionContext(resolution: .noMatch, target: nil, detail: detail) }
        let target = targets[index - 1]
        return WindowFocusResolutionContext(
            resolution: Self.windowShortcutTargetResolution(target, workspaceID: selectedWorkspaceID, detail: detail, overview: overview),
            target: target, detail: detail)
    }

    /// The overview for the daemon that owns `workspaceID` (local or remote), or nil when
    /// the workspace has no known owning device or that device's section carries no
    /// overview. Callers must treat nil as "we cannot describe this workspace" and do
    /// nothing: substituting the local device's overview would resolve another machine's
    /// workspace/session ids against this Mac's rows and act on whatever happened to match.
    func overview(forWorkspaceID workspaceID: String) -> SpacesDeviceOverviewPayload? {
        guard let deviceID = deviceID(forWorkspaceID: workspaceID) else { return nil }
        return deviceSection(id: deviceID)?.overview
    }

    /// Maps an explicit alerts/command-palette focus request to the same device-agnostic
    /// target the numbered-shortcut path produces, so both flow through one dispatcher.
    nonisolated static func windowFocusResolution(for request: WindowFocusRequest, overview: SpacesDeviceOverviewPayload)
        -> DeviceWindowShortcutResolution
    {
        switch request {
        case .workspaceBrowserSession(let workspaceID, let targetURL): return .openURL(workspaceID: workspaceID, targetURL: targetURL)
        case .workspaceProcess(let workspaceID, let processID):
            guard let detail = workspaceDetail(workspaceID, in: overview),
                let row = detail.processRows.first(where: { ($0.processID ?? $0.id) == processID }), let sessionID = row.sessionID
            else { return .noMatch }
            return openTerminalResolution(
                workspaceID: workspaceID, sessionID: sessionID, fallbackTitle: row.name, fallbackDir: detail.dir, fallbackKind: .process,
                overview: overview)
        case .workspaceWindow(let workspaceID, let index):
            guard let detail = workspaceDetail(workspaceID, in: overview), detail.terminalRows.indices.contains(index - 1),
                let sessionID = detail.terminalRows[index - 1].sessionID
            else { return .noMatch }
            let row = detail.terminalRows[index - 1]
            return openTerminalResolution(
                workspaceID: workspaceID, sessionID: sessionID, fallbackTitle: row.title, fallbackDir: row.workingDirectory, fallbackKind: .shell,
                overview: overview)
        case .workspaceMissingConfiguredProcess(let workspaceID, let processKey):
            let templateID = workspaceDetail(workspaceID, in: overview)?.config.processes.first {
                normalizedRunRowName($0.name ?? "") == normalizedRunRowName(processKey)
            }?.id
            return .runProcess(workspaceID: workspaceID, processKey: processKey, processTemplateID: templateID)
        case .agentWindow(let record):
            guard let detail = workspaceDetail(record.workspaceID, in: overview),
                let row = detail.codingAgentRows.first(where: { ($0.agentID ?? $0.id) == record.id }), let sessionID = row.sessionID
            else { return .noMatch }
            return openTerminalResolution(
                workspaceID: record.workspaceID, sessionID: sessionID, fallbackTitle: row.name, fallbackDir: detail.dir, fallbackKind: .agent,
                overview: overview)
        case .terminalSession(let workspaceID, let sessionID):
            guard let session = overview.sessions.first(where: { $0.id == sessionID }) else { return .noMatch }
            return openTerminalResolution(
                workspaceID: workspaceID, sessionID: sessionID, fallbackTitle: session.title, fallbackDir: session.workingDirectory,
                fallbackKind: terminalSessionKind(rowKind: session.rowKind), overview: overview)
        }
    }

    nonisolated private static func windowFocusTarget(for request: WindowFocusRequest, overview: SpacesDeviceOverviewPayload) -> (
        target: WorkspaceRunShortcutTarget, detail: SpacesDeviceWorkspaceDetailViewModel
    )? {
        guard let detail = workspaceDetail(request.workspaceID, in: overview) else { return nil }
        let targets = workspaceShortcutTargets(detail: detail, browserSessions: detail.config.resolvedBrowserSessions.map(localBrowserSession(from:)))
        let target: WorkspaceRunShortcutTarget?
        switch request {
        case .workspaceBrowserSession(_, let targetURL): target = targets.first { $0.kind == .browser && $0.targetURL == targetURL }
        case .workspaceProcess(_, let processID): target = targets.first { $0.kind == .process && $0.processID == processID }
        case .workspaceWindow(_, let index): target = targets.first { $0.kind == .window && $0.windowListIndex == index - 1 }
        case .workspaceMissingConfiguredProcess(_, let processKey):
            target = targets.first {
                $0.kind == .missingConfiguredProcess && normalizedRunRowName($0.processKey ?? "") == normalizedRunRowName(processKey)
            }
        case .agentWindow(let record): target = targets.first { $0.kind == .agent && $0.agentWindow?.id == record.id }
        // A bell alert's session isn't one of the workspace's numbered run-shortcut targets, so it
        // has no run-shortcut target to resolve.
        case .terminalSession: target = nil
        }
        guard let target else { return nil }
        return (target, detail)
    }

    /// Builds an `.openTerminal` target for a session, preferring live session-catalog
    /// metadata from the overview and falling back to the row's own title/dir when the
    /// session has not yet surfaced in the catalog (e.g. a just-started process).
    nonisolated private static func openTerminalResolution(
        workspaceID: String, sessionID: String, fallbackTitle: String, fallbackDir: String, fallbackKind: TerminalSessionKind,
        overview: SpacesDeviceOverviewPayload
    ) -> DeviceWindowShortcutResolution {
        .openTerminal(
            deviceTerminalOpenRequest(workspaceID: workspaceID, sessionID: sessionID, overview: overview)
                ?? DeviceTerminalOpenRequest(
                    workspaceID: workspaceID, sessionID: sessionID, title: fallbackTitle, workingDirectory: fallbackDir, kind: fallbackKind))
    }

    /// Internal rather than `private`: `BrowserSessionCoordinator.browserSessionTargetURLs` also needs
    /// this to look up a workspace's configured browser sessions from an overview.
    nonisolated static func workspaceDetail(_ workspaceID: String, in overview: SpacesDeviceOverviewPayload)
        -> SpacesDeviceWorkspaceDetailViewModel?
    { overview.workspaces.first(where: { $0.id == workspaceID }).map(SpacesDeviceWorkspaceDetailViewModel.init) }

    /// The single window-shortcut dispatcher for every device. It executes the resolved
    /// target, then applies the window-shortcut profiling. The focus work itself lives in
    /// `executeWindowFocusResolution` so the cycle and command-palette paths reuse it.
    private func dispatchWindowShortcut(
        _ context: WindowFocusResolutionContext, index: Int, startedAt: Date, shortcutDispatchMS: Int, targetResolutionMS: Int
    ) async {
        let routeStartedAt = Date()
        let resolution = context.resolution
        let kind = Self.windowShortcutKind(for: resolution)
        guard await executeWindowFocusResolution(resolution, preferredTarget: context.target, preferredDetail: context.detail) else {
            logWindowShortcutProfile("stage=aborted index=\(index) kind=\(kind) elapsed_ms=\(windowShortcutElapsedMS(since: startedAt))")
            logPerfMetric(
                "window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false,
                detail:
                    "kind=\(kind) shortcut_dispatch_ms=\(shortcutDispatchMS) target_resolution_ms=\(targetResolutionMS) route_ms=\(windowShortcutElapsedMS(since: routeStartedAt))"
            )
            activeWindowShortcutProfile = nil
            return
        }
        let routeMS = windowShortcutElapsedMS(since: routeStartedAt)
        logWindowShortcutProfile("stage=route_done index=\(index) kind=\(kind) elapsed_ms=\(routeMS)")
        logPerfMetric(
            "window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true,
            detail: "kind=\(kind) shortcut_dispatch_ms=\(shortcutDispatchMS) target_resolution_ms=\(targetResolutionMS) route_ms=\(routeMS)")
        activeWindowShortcutProfile = nil
    }

    private struct RoutedBrowserFocusTarget: Sendable {
        let targetURL: URL
        let siblingTargetURLs: [String]
    }

    /// Executes a resolved focus target on the client and reports whether a target was
    /// focused (the executor surfaces its own errors on failure). Shared by the
    /// numbered-shortcut, command-palette, and cycle focus paths so all three behave
    /// identically. Only two leaves depend on where the workspace's daemon runs: browser
    /// URLs may need remote-service routing before local Chrome focus, and terminal
    /// windows use native sessions locally vs Device API mirrors remotely.
    @discardableResult func executeWindowFocusResolution(
        _ resolution: DeviceWindowShortcutResolution, requestID: String? = nil, preferredTarget: WorkspaceRunShortcutTarget? = nil,
        preferredDetail: SpacesDeviceWorkspaceDetailViewModel? = nil, preserveWindowCycleSession: Bool = false
    ) async -> Bool {
        switch resolution {
        case .openURL(let workspaceID, let targetURL):
            guard URL(string: targetURL) != nil else {
                showError(WorkspaceError.invalidArgument(message: "Browser session URL is invalid."))
                return false
            }
            // Whether the URL needs remote-service routing depends on the owning device. With no
            // known owner there is no answer, and opening the raw URL would point this Mac's
            // Chrome at a localhost port that belongs to another machine's workspace.
            guard let workspaceDeviceID = deviceID(forWorkspaceID: workspaceID) else {
                showDeviceNotLoadedError()
                return false
            }
            let browserSessionTargetURLs = BrowserSessionCoordinator.browserSessionTargetURLs(
                workspaceID: workspaceID, targetURL: targetURL, overview: overview(forWorkspaceID: workspaceID))
            let siblingTargetURLs = BrowserSessionCoordinator.browserSessionSiblingTargetURLs(
                targetURL: targetURL, targetURLs: browserSessionTargetURLs)
            if isRemoteDeviceID(workspaceDeviceID) {
                guard let device = deviceForWorkspaceMutation(workspaceID: workspaceID) else {
                    showWorkspaceDeviceUnavailableError(workspaceID: workspaceID)
                    return false
                }
                guard let workspace = deviceWorkspaceSummary(workspaceID: workspaceID) else {
                    showError(WorkspaceError.invalidArgument(message: "Workspace not found on the selected device."))
                    return false
                }
                // Opening a missing workspace SSH forward and reconciling the Caddy route blocks (spawns
                // `ssh`, polls local ports and router config up to the timeout), so run it off the main
                // actor to keep the focus keypress from freezing the UI. The manager is `Sendable` and
                // serializes its own state, so the detached task can safely own the reconciliation.
                let manager = browserSessions.forwardManager
                let routeResult: Result<RoutedBrowserFocusTarget, Error> = await Task.detached(priority: .userInitiated) {
                    do {
                        let routedURL = try manager.routedURL(targetURL: targetURL, workspace: workspace, device: device)
                        let routedSiblingTargetURLs = try siblingTargetURLs.map {
                            try manager.routedURL(targetURL: $0, workspace: workspace, device: device).absoluteString
                        }
                        return .success(RoutedBrowserFocusTarget(targetURL: routedURL, siblingTargetURLs: routedSiblingTargetURLs))
                    } catch { return .failure(error) }
                }.value
                switch routeResult {
                case .success(let routedTarget):
                    browserSessions.refreshVisibleServicePortDisplays(deviceID: device.id)
                    guard
                        await browserSessions.focusLocalChromeTab(
                            workspaceID: workspaceID, targetURL: routedTarget.targetURL.absoluteString,
                            siblingTargetURLs: routedTarget.siblingTargetURLs)
                    else {
                        browserSessions.showBrowserSessionFocusFailureError()
                        return false
                    }
                case .failure(let error):
                    showError(error)
                    return false
                }
            } else {
                guard await browserSessions.focusLocalChromeTab(workspaceID: workspaceID, targetURL: targetURL, siblingTargetURLs: siblingTargetURLs)
                else {
                    browserSessions.showBrowserSessionFocusFailureError()
                    return false
                }
            }
            Self.setClientActiveWorkspaceID(workspaceID)
            rememberWindowNavigationFocus(
                resolution: resolution, preferredTarget: preferredTarget, preferredDetail: preferredDetail,
                preserveWindowCycleSession: preserveWindowCycleSession)
            return true
        case .openTerminal(let request):
            guard await openOrFocusTerminalTarget(request, requestID: requestID) else { return false }
            rememberWindowNavigationFocus(
                resolution: resolution, preferredTarget: preferredTarget, preferredDetail: preferredDetail,
                preserveWindowCycleSession: preserveWindowCycleSession)
            return true
        case .runProcess(let workspaceID, let processKey, let processTemplateID):
            guard
                await runTerminalSessionMutationAndOpenPane(
                    workspaceID: workspaceID,
                    operation: { device in
                        try SpacesDeviceClient.runWorkspaceProcess(
                            workspaceID: workspaceID, processKey: processKey, processTemplateID: processTemplateID,
                            context: DeviceRequestContext(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
                    })
            else { return false }
            rememberWindowNavigationFocus(
                resolution: resolution, preferredTarget: preferredTarget, preferredDetail: preferredDetail,
                preserveWindowCycleSession: preserveWindowCycleSession)
            return true
        case .noWorkspace, .noMatch: return false
        }
    }

    @discardableResult private func openOrFocusTerminalTarget(_ request: DeviceTerminalOpenRequest, requestID: String? = nil) async -> Bool {
        let startedAt = Date()
        let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
        var requestResolveMS = 0
        var existingPaneFocusMS = 0
        var paneOpenMS = 0
        var ownershipRequestMS = 0
        var focusObservationMS = 0
        var focusObserved = false
        var retriedAfterReload = false
        func logTerminalPaneFocus(success: Bool, reason: String = "") {
            let reasonDetail = reason.isEmpty ? "" : " reason=\(reason)"
            let retryDetail = retriedAfterReload ? " retried_after_reload=1" : ""
            logPerfMetric(
                "terminal_pane_focus", target: "session=\(request.sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: success,
                detail:
                    "request_resolution_ms=\(requestResolveMS) existing_pane_focus_ms=\(existingPaneFocusMS) pane_open_ms=\(paneOpenMS) ownership_request_ms=\(ownershipRequestMS) focus_observation_ms=\(focusObservationMS) focus_observed=\(focusObserved ? 1 : 0)\(requestDetail)\(reasonDetail)\(retryDetail)"
            )
        }
        // Window-focus terminal targets are always workspace-backed (they come from a
        // workspace's run-target list), so a workspace whose owning device is unknown is a not-loaded
        // state. Reachability is deliberately not required here, because this entry point covers both
        // focusing an existing pane (client-side, and available through an outage — that pane renders
        // as disconnected) and opening one that does not exist yet. Only the latter needs the daemon,
        // and it is refused inside `openOrFocusTerminalPane`, which is where the two are told apart
        // once the workspace's persisted layout has been adopted; the resolutions that create a
        // session are gated at their own mutations.
        guard deviceID(forWorkspaceID: request.workspaceID) != nil else {
            showDeviceNotLoadedError()
            logTerminalPaneFocus(success: false, reason: "device_not_loaded")
            return false
        }
        Self.setClientActiveWorkspaceID(request.workspaceID)
        // A row-built resolution can predate the session's overview entry and lack the
        // real shell/command. Only recover that metadata when opening a new pane: an
        // already-open pane already has its state model and can focus entirely client-side.
        let existingPaneBeforeResolution = panelCoordinator.placement(forSessionID: request.sessionID) != nil
        let requestResolveStartedAt = Date()
        var openRequest: DeviceTerminalOpenRequest
        let needsColdResolution = Self.terminalOpenRequestNeedsColdResolution(request, hasExistingPane: existingPaneBeforeResolution)
        if needsColdResolution {
            openRequest = await resolveTerminalSessionPaneOpenRequest(sessionID: request.sessionID) ?? request
        } else {
            openRequest = request
        }
        requestResolveMS = windowShortcutElapsedMS(since: requestResolveStartedAt)
        let reusedExistingPane = existingPaneBeforeResolution || panelCoordinator.placement(forSessionID: openRequest.sessionID) != nil
        let paneFocusStartedAt = Date()
        // The open resolves the workspace's scope through the sidebar's index. A request for a
        // just-created workspace whose index entry has not landed yet is refused for exactly that reason
        // (`workspaceScope(forWorkspaceID:)` nil), so wait for the app's next snapshot and try once more,
        // redoing the cold resolution when this request needed one, since the miss can be in either. A
        // request whose scope is already present was refused for something else entirely: an unreachable
        // or incompatible device (which already showed its own modal, since this focusing entry point is
        // always a focusing intent) or a content-construction failure. Retrying either would only repeat
        // the same refusal and its modal a second time.
        var openedPane = panelCoordinator.openOrFocusTerminalPane(openRequest, openIntent: .focused) != nil
        if !openedPane, panelCoordinator.workspaceScope(forWorkspaceID: openRequest.workspaceID) == nil {
            retriedAfterReload = true
            await sidebar.reloadAwaitingFreshSnapshot()
            if needsColdResolution { openRequest = await resolveTerminalSessionPaneOpenRequest(sessionID: request.sessionID) ?? openRequest }
            openedPane = panelCoordinator.openOrFocusTerminalPane(openRequest, openIntent: .focused) != nil
        }
        guard openedPane else {
            if reusedExistingPane {
                existingPaneFocusMS = windowShortcutElapsedMS(since: paneFocusStartedAt)
            } else {
                paneOpenMS = windowShortcutElapsedMS(since: paneFocusStartedAt)
            }
            logTerminalPaneFocus(success: false, reason: "pane_open_failed")
            return false
        }
        if reusedExistingPane {
            existingPaneFocusMS = windowShortcutElapsedMS(since: paneFocusStartedAt)
        } else {
            paneOpenMS = windowShortcutElapsedMS(since: paneFocusStartedAt)
        }
        // Focusing a workspace terminal target (sidebar row, numbered shortcut, window
        // cycle, `focus-workspace-process`) is an owner-intent action: the user wants to
        // interact. Reclaim ownership like the owner-mode open IPC does, so a pane that was
        // closed and reopened (or is currently a viewer) reattaches as owner instead of the
        // takeover shell. The viewer-only `focusTerminalSessionWindow` IPC takes the
        // separate `openTerminalSessionPane(mode:.viewer)` path and never lands here.
        let ownershipStartedAt = Date()
        panelCoordinator.content(forSessionID: openRequest.sessionID)?.requestOwnershipIfNeeded()
        ownershipRequestMS = windowShortcutElapsedMS(since: ownershipStartedAt)
        let focusObservationStartedAt = Date()
        await Task.yield()
        focusObserved = panelCoordinator.focusedSessionID() == openRequest.sessionID
        focusObservationMS = windowShortcutElapsedMS(since: focusObservationStartedAt)
        logTerminalPaneFocus(success: true)
        if let requestID, !requestID.isEmpty {
            logPerfMetric(
                "terminal_window_focus_ipc", target: "session=\(openRequest.sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                success: true,
                detail:
                    "route=pane request_resolution_ms=\(requestResolveMS) existing_pane_focus_ms=\(existingPaneFocusMS) pane_open_ms=\(paneOpenMS) ownership_request_ms=\(ownershipRequestMS) focus_observation_ms=\(focusObservationMS) focus_observed=\(focusObserved ? 1 : 0) request_id=\(requestID)"
            )
            if focusObserved {
                logPerfMetric(
                    "terminal_window_focus_observed", target: "session=\(openRequest.sessionID)",
                    elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true, detail: "route=pane request_id=\(requestID)")
            }
        }
        return true
    }

    nonisolated static func terminalOpenRequestNeedsColdResolution(_ request: DeviceTerminalOpenRequest, hasExistingPane: Bool) -> Bool {
        !hasExistingPane && request.shell == nil
    }

    /// Runs a workspace terminal-session mutation (start a configured process / launch a
    /// coding agent) and returns the open request for the session it produced, applying the
    /// response to local state along the way. Placement is the caller's decision: the window
    /// shortcut path opens/focuses the pane, while the session picker lands it at the picker's
    /// split or new tab.
    func runTerminalSessionMutation(workspaceID: String, operation: @Sendable @escaping (SpacesPairedDeviceRecord) throws -> SpacesDeviceAPIResponse)
        async -> DeviceTerminalOpenRequest?
    {
        guard let device = deviceForWorkspaceMutation(workspaceID: workspaceID) else {
            showWorkspaceDeviceUnavailableError(workspaceID: workspaceID)
            return nil
        }
        let epoch = panelCoordinator.paneReplacementEpoch
        switch await Self.deviceMutation(device: device, operation: operation) {
        case .success(let response):
            applyDeviceMutationResponse(response, deviceID: device.id, epoch: epoch, selectedWorkspaceID: workspaceID)
            return terminalOpenRequest(fromMutationResponse: response, workspaceID: workspaceID)
        case .failure(let error):
            showError(error)
            return nil
        }
    }

    private func runTerminalSessionMutationAndOpenPane(
        workspaceID: String, operation: @Sendable @escaping (SpacesPairedDeviceRecord) throws -> SpacesDeviceAPIResponse
    ) async -> Bool {
        guard let request = await runTerminalSessionMutation(workspaceID: workspaceID, operation: operation), await openOrFocusTerminalTarget(request)
        else { return false }
        return true
    }

    nonisolated private static func windowShortcutKind(for resolution: DeviceWindowShortcutResolution) -> String {
        switch resolution {
        case .openURL: return "browser"
        case .openTerminal: return "terminal"
        case .runProcess: return "process"
        case .noWorkspace, .noMatch: return "none"
        }
    }

    // Not private: `ShortcutsController`'s shortcut monitor calls this from a different file in the
    // same module (cross-file `private` isn't visible).
    func logWindowShortcutProfile(_ message: String) {
        guard ProcessInfo.processInfo.environment["DEBUG"] == "1" else { return }
        fputs("spaces: window_shortcut \(message)\n", stderr)
    }

    func captureHotkeyPerfContext() -> HotkeyPerfContext {
        HotkeyPerfContext(
            startedAt: Date(), appWasActive: NSApp.isActive, appWasHidden: NSApp.isHidden,
            mainWindowWasVisible: window?.isVisible == true && window?.isMiniaturized != true,
            paletteWasVisible: commandPalette.commandPalettePanel?.isVisible == true)
    }

    nonisolated static func commandPalettePresentationIsComplete(panelIsVisible: Bool, panelIsKey: Bool) -> Bool { panelIsVisible && panelIsKey }

    nonisolated static func shouldDismissCommandPaletteForToggle(panelIsVisible: Bool, panelIsFocused: Bool) -> Bool {
        panelIsVisible && panelIsFocused
    }

    nonisolated static func shouldUseFocusedBuiltInTerminalWindowForGlobalNavigation(appIsActive: Bool) -> Bool { appIsActive }

    nonisolated static func shouldUseFocusedChromeWindowForWorkspaceLookup(frontmostApplicationBundleIdentifier: String?) -> Bool {
        frontmostApplicationBundleIdentifier == "com.google.Chrome"
    }

    nonisolated static func activeWorkspaceIDForGlobalNavigation(appIsActive: Bool, activeWorkspaceID: String?) -> String? {
        appIsActive ? activeWorkspaceID : nil
    }

    nonisolated static func shouldReloadSidebarForTerminalOverviewSignal(
        didStartBackgroundServices: Bool, notificationObject: String?, profileObject: String
    ) -> Bool { didStartBackgroundServices && notificationObject == profileObject }

    nonisolated static func preferredWorkspaceIDForGlobalNavigation(
        focusedTerminalSessionWorkspaceID: String?, focusedWindowWorkspaceID: String?, activeWorkspaceID: String?
    ) -> GlobalNavigationWorkspaceResolution {
        if let focusedTerminalSessionWorkspaceID {
            return GlobalNavigationWorkspaceResolution(workspaceID: focusedTerminalSessionWorkspaceID, source: "focused_terminal_session")
        }
        if let focusedWindowWorkspaceID {
            return GlobalNavigationWorkspaceResolution(workspaceID: focusedWindowWorkspaceID, source: "focused_window")
        }
        if let activeWorkspaceID { return GlobalNavigationWorkspaceResolution(workspaceID: activeWorkspaceID, source: "active_workspace") }
        return GlobalNavigationWorkspaceResolution(workspaceID: nil, source: "none")
    }

    nonisolated static func shouldHideMainWindowForToggle(appIsHidden: Bool, mainWindowIsFocused: Bool) -> Bool {
        !appIsHidden && mainWindowIsFocused
    }

    nonisolated static func effectiveMainWindowVisibilityForHotkeyState(rawMainWindowIsVisible: Bool, commandPaletteMainWindowVisibility: Bool?)
        -> Bool
    { commandPaletteMainWindowVisibility ?? rawMainWindowIsVisible }

    func logHotkeyPerfMetric(_ metric: String, action: String, context: HotkeyPerfContext) {
        let target =
            "action=\(action) app_active_before=\(context.appWasActive ? 1 : 0) app_hidden_before=\(context.appWasHidden ? 1 : 0) main_visible_before=\(context.mainWindowWasVisible ? 1 : 0) palette_visible_before=\(context.paletteWasVisible ? 1 : 0)"
        logPerfMetric(metric, target: target, elapsedMS: windowShortcutElapsedMS(since: context.startedAt), success: true)
    }

    func logPerfMetric(_ metric: String, target: String, elapsedMS: Int, success: Bool, detail: String = "") {
        TerminalPerformance.logMetric(metric, target: target, elapsedMS: elapsedMS, success: success, detail: detail)
    }

    func windowShortcutElapsedMS(since start: Date) -> Int { max(Int(Date().timeIntervalSince(start) * 1000), 0) }

    func windowShortcutIndex(for event: NSEvent) -> Int? {
        guard let windowShortcutSpec = shortcuts.windowShortcutSpec else { return nil }
        return numberedWindowShortcutIndex(for: event, spec: windowShortcutSpec)
    }

    private func numberedWindowShortcutIndex(for event: NSEvent, spec: HotkeySpec) -> Int? {
        guard shortcuts.eventModifierCarbonFlags(event) == spec.modifiersCarbon else { return nil }
        let keyMap: [UInt16: Int] = [
            UInt16(kVK_ANSI_1): 1, UInt16(kVK_ANSI_2): 2, UInt16(kVK_ANSI_3): 3, UInt16(kVK_ANSI_4): 4, UInt16(kVK_ANSI_5): 5, UInt16(kVK_ANSI_6): 6,
            UInt16(kVK_ANSI_7): 7, UInt16(kVK_ANSI_8): 8, UInt16(kVK_ANSI_9): 9, UInt16(kVK_ANSI_0): 10,
        ]
        return keyMap[event.keyCode]
    }

    func windowShortcutBadgeText(index: Int) -> String {
        let keyText = index == 10 ? "0" : String(index)
        guard let windowShortcutSpec = shortcuts.windowShortcutSpec else { return "⌘\(keyText)" }
        return shortcuts.displayShortcut(windowShortcutSpec, keyText: keyText)
    }

    // Not private: `ShortcutsController`'s shortcut monitor calls this from a different file in the
    // same module (cross-file `private` isn't visible).
    func focusGlobalWindowNavigation(direction: Int) {
        let requestID = UUID().uuidString
        let startedAt = Date()
        guard let workspaceID = globalWindowNavigationWorkspaceID(requestID: requestID) else {
            logPerfMetric(
                "global_window_navigation", target: "workspace=nil", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false,
                detail: "direction=\(direction > 0 ? "next" : "previous") reason=no_workspace request_id=\(requestID)")
            return
        }
        let preferredFocusedBuiltInTerminalSessionID = focusedBuiltInTerminalSessionIDForGlobalNavigation()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.cycleWorkspaceWindow(
                workspaceID: workspaceID, delta: direction > 0 ? 1 : -1, preferredTerminalSessionID: preferredFocusedBuiltInTerminalSessionID,
                requestID: requestID)
            self.logPerfMetric(
                "global_window_navigation", target: "workspace=\(workspaceID)", elapsedMS: self.windowShortcutElapsedMS(since: startedAt),
                success: true, detail: "direction=\(direction > 0 ? "next" : "previous") request_id=\(requestID)")
        }
    }

    /// Resolves the workspace owning a terminal session from the overview (sessions and
    /// process/agent/terminal rows all carry both the session id and workspace id),
    /// replacing the orchestrator's daemon-DB lookup. Searches every paired device's
    /// overview so mirrored remote sessions resolve too.
    func clientWorkspaceID(forTerminalSession sessionID: String) -> String? {
        for overview in deviceModel.deviceSections.compactMap({ $0.overview }) {
            if let workspaceID = overview.sessions.first(where: { $0.id == sessionID })?.workspaceID { return workspaceID }
            for workspace in overview.workspaces
            where workspace.processRows.contains(where: { $0.sessionID == sessionID })
                || workspace.codingAgentRows.contains(where: { $0.sessionID == sessionID })
                || workspace.terminalRows.contains(where: { $0.sessionID == sessionID })
            { return workspace.id }
        }
        return nil
    }

    /// Resolves the workspace of the focused desktop window when it is a Chrome browser
    /// window, by matching the frontmost tab URL to a configured browser session in the
    /// overview. A focused built-in terminal is resolved earlier by its session id.
    func clientWorkspaceIDForFocusedWindow() -> String? {
        let chrome = ChromeAdapter()
        guard chrome.isAvailable(), let activeURL = (try? chrome.frontmostActiveTabURL()) ?? nil, !activeURL.isEmpty else { return nil }
        return BrowserSessionCoordinator.workspaceIDForObservedBrowserURL(activeURL, in: deviceModel.deviceSections.compactMap(\.overview))
    }

    /// Validates a process template before it is saved. Pure, client-local string
    /// validation (mirrors the orchestrator's `validateProcessTemplate`).
    nonisolated static func validateProcessTemplate(_ template: ProcessTemplate) throws {
        guard !template.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorkspaceError.invalidArgument(message: "Process command is required.")
        }
    }

    private func globalWindowNavigationWorkspaceID(requestID: String? = nil) -> String? {
        let startedAt = Date()
        let activeTerminalSessionStartedAt = Date()
        let focusedTerminalSessionID = focusedBuiltInTerminalSessionIDForGlobalNavigation()
        let activeTerminalSessionMS = windowShortcutElapsedMS(since: activeTerminalSessionStartedAt)

        var focusedTerminalSessionWorkspaceID: String?
        var focusedWindowWorkspaceID: String?
        var activeWorkspaceID: String?
        var terminalWorkspaceMS = 0
        var focusedWindowWorkspaceMS = 0
        var activeWorkspaceMS = 0
        var terminalWorkspaceSource = "skipped"
        var terminalWorkspaceStatus = "skipped"
        var focusedWindowWorkspaceStatus = "skipped"
        var activeWorkspaceStatus = "skipped"

        if let focusedTerminalSessionID {
            let lookupStartedAt = Date()
            focusedTerminalSessionWorkspaceID = clientWorkspaceID(forTerminalSession: focusedTerminalSessionID)
            terminalWorkspaceMS = windowShortcutElapsedMS(since: lookupStartedAt)
            terminalWorkspaceSource = "focused"
            terminalWorkspaceStatus = focusedTerminalSessionWorkspaceID == nil ? "miss" : "hit"
        }

        if focusedTerminalSessionWorkspaceID == nil {
            let lookupStartedAt = Date()
            focusedWindowWorkspaceID = clientWorkspaceIDForFocusedWindow()
            focusedWindowWorkspaceMS = windowShortcutElapsedMS(since: lookupStartedAt)
            focusedWindowWorkspaceStatus = focusedWindowWorkspaceID == nil ? "miss" : "hit"
        }

        if focusedTerminalSessionWorkspaceID == nil, focusedWindowWorkspaceID == nil {
            let lookupStartedAt = Date()
            activeWorkspaceID = clientActiveWorkspaceID()
            activeWorkspaceMS = windowShortcutElapsedMS(since: lookupStartedAt)
            activeWorkspaceStatus = activeWorkspaceID == nil ? "miss" : "hit"
        }

        let resolution = Self.preferredWorkspaceIDForGlobalNavigation(
            focusedTerminalSessionWorkspaceID: focusedTerminalSessionWorkspaceID, focusedWindowWorkspaceID: focusedWindowWorkspaceID,
            activeWorkspaceID: activeWorkspaceID)
        let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
        let detail =
            "selected_source=\(resolution.source) active_terminal_session=\(focusedTerminalSessionID == nil ? "miss" : "hit") active_terminal_session_ms=\(activeTerminalSessionMS) terminal_workspace=\(terminalWorkspaceStatus) terminal_workspace_source=\(terminalWorkspaceSource) terminal_workspace_ms=\(terminalWorkspaceMS) focused_window_workspace=\(focusedWindowWorkspaceStatus) focused_window_workspace_ms=\(focusedWindowWorkspaceMS) active_workspace=\(activeWorkspaceStatus) active_workspace_ms=\(activeWorkspaceMS)\(requestDetail)"
        logPerfMetric(
            "global_window_navigation_workspace_resolution", target: "workspace=\(resolution.workspaceID ?? "nil")",
            elapsedMS: windowShortcutElapsedMS(since: startedAt), success: resolution.workspaceID != nil, detail: detail)
        return resolution.workspaceID
    }

    /// The focused built-in terminal session for global navigation: the pane holding
    /// keyboard focus, only while Spaces is active (an inactive app's stale focus must
    /// not hijack cycling from unrelated apps).
    private func focusedBuiltInTerminalSessionIDForGlobalNavigation() -> String? {
        guard Self.shouldUseFocusedBuiltInTerminalWindowForGlobalNavigation(appIsActive: NSApp.isActive) else { return nil }
        return panelCoordinator.focusedSessionID()
    }

    nonisolated static func preferredWorkspaceIDForAppToggle(focusedTerminalSessionWorkspaceID: String?, focusedWindowWorkspaceID: String?) -> String?
    { focusedTerminalSessionWorkspaceID ?? focusedWindowWorkspaceID }

    /// Terminal panes live inside app windows (the main window and global panel
    /// windows), all hidden together by the app-wide hide; the only after-hide
    /// restoration is returning focus to the previously frontmost app.
    nonisolated static func shouldRestoreReturnApplicationAfterMainHide(returnApplicationProcessID: pid_t?) -> Bool {
        returnApplicationProcessID != nil
    }

    nonisolated static func returnApplicationProcessIDForAppToggle(frontmostApplicationProcessID: pid_t?, currentProcessID: pid_t) -> pid_t? {
        guard let frontmostApplicationProcessID, frontmostApplicationProcessID != currentProcessID else { return nil }
        return frontmostApplicationProcessID
    }

    nonisolated static func preferredWorkspaceIDForCommandPalette(
        selectedWorkspaceID: String?, focusedTerminalSessionWorkspaceID: String?, focusedWindowWorkspaceID: String?
    ) -> String? { selectedWorkspaceID ?? focusedTerminalSessionWorkspaceID ?? focusedWindowWorkspaceID }

    nonisolated static func shouldRestoreTerminalFocusAfterPaletteHide(returnTerminalSessionID: String?) -> Bool { returnTerminalSessionID != nil }

    /// A code pane has no session id, so it only wins the return-focus decision when the palette
    /// captured no terminal session either — terminal focus always takes precedence when both are
    /// somehow present (a focus request landing mid-selection could otherwise race the capture).
    nonisolated static func shouldRestoreCodePaneFocusAfterPaletteHide(returnTerminalSessionID: String?, returnCodePaneID: String?) -> Bool {
        returnTerminalSessionID == nil && returnCodePaneID != nil
    }

    nonisolated static func shouldRestoreReturnApplicationAfterPaletteHide(
        returnTerminalSessionID: String?, returnCodePaneID: String?, returnApplicationProcessID: pid_t?
    ) -> Bool { return returnTerminalSessionID == nil && returnCodePaneID == nil && returnApplicationProcessID != nil }

    nonisolated static func commandPaletteDismissShortcutMatches(
        charactersIgnoringModifiers: String?, modifiers: Set<HotkeyModifier>, selectedItemIsAlert: Bool, searchEditorCanCutSelectedText: Bool = false
    ) -> Bool {
        guard selectedItemIsAlert else { return false }
        guard !searchEditorCanCutSelectedText else { return false }
        guard charactersIgnoringModifiers?.lowercased() == "x" else { return false }
        return modifiers == [.cmd]
    }

    func toggleWindowFromHotkey() {
        guard let window else { return }
        let toggleStartedAt = Date()
        let perfContext = captureHotkeyPerfContext()
        logHotkeyDebug("toggle_window begin \(hotkeyWindowStateSummary())")
        if Self.shouldHideMainWindowForToggle(appIsHidden: NSApp.isHidden, mainWindowIsFocused: window.isKeyWindow) {
            logHotkeyDebug("toggle_window hide_main_only")
            let returnApplicationProcessID = appToggleReturnApplicationProcessID
            window.orderOut(nil)
            NSApp.hide(nil)
            if Self.shouldRestoreReturnApplicationAfterMainHide(returnApplicationProcessID: returnApplicationProcessID),
                let returnApplicationProcessID
            {
                let restoreStartedAt = Date()
                activateReturnApplication(processIdentifier: returnApplicationProcessID)
                logPerfMetric(
                    "toggle_window_return_application_focus", target: "pid=\(returnApplicationProcessID)",
                    elapsedMS: windowShortcutElapsedMS(since: restoreStartedAt), success: true)
            }
            appToggleReturnApplicationProcessID = nil
            logHotkeyPerfMetric("toggle_window", action: "hide", context: perfContext)
            return
        }
        let returnApplicationProcessID = Self.returnApplicationProcessIDForAppToggle(
            frontmostApplicationProcessID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            currentProcessID: ProcessInfo.processInfo.processIdentifier)
        let focusedTerminalSessionID = panelCoordinator.focusedSessionID()
        let focusedTerminalWorkspaceID: String?
        let selectionRefreshSource: String
        if let terminalSessionID = focusedTerminalSessionID {
            let lookupStartedAt = Date()
            focusedTerminalWorkspaceID = clientWorkspaceID(forTerminalSession: terminalSessionID)
            logPerfMetric(
                "toggle_window_terminal_workspace_lookup", target: "session=\(terminalSessionID)",
                elapsedMS: windowShortcutElapsedMS(since: lookupStartedAt), success: focusedTerminalWorkspaceID != nil)
            selectionRefreshSource = "terminal_session"
        } else {
            focusedTerminalWorkspaceID = nil
            selectionRefreshSource = "focused_window"
        }
        let focusedWindowWorkspaceID: String?
        if focusedTerminalWorkspaceID == nil {
            let focusedWindowLookupStartedAt = Date()
            focusedWindowWorkspaceID = clientWorkspaceIDForFocusedWindow()
            logPerfMetric(
                "toggle_window_focused_window_workspace_lookup", target: "frontmost_window",
                elapsedMS: windowShortcutElapsedMS(since: focusedWindowLookupStartedAt), success: focusedWindowWorkspaceID != nil)
        } else {
            focusedWindowWorkspaceID = nil
        }
        let focusedWorkspaceID = Self.preferredWorkspaceIDForAppToggle(
            focusedTerminalSessionWorkspaceID: focusedTerminalWorkspaceID, focusedWindowWorkspaceID: focusedWindowWorkspaceID)
        let revealStartedAt = Date()
        revealTargetedHotkeyWindow(window)
        logPerfMetric(
            "toggle_window_reveal_target", target: "main", elapsedMS: windowShortcutElapsedMS(since: revealStartedAt), success: true,
            detail: "app_active=\(NSApp.isActive ? 1 : 0)")
        logHotkeyDebug("toggle_window show_main focused_workspace=\(focusedWorkspaceID ?? "nil") \(hotkeyWindowStateSummary())")
        logPerfMetric("toggle_window_flow", target: "main", elapsedMS: windowShortcutElapsedMS(since: toggleStartedAt), success: true)
        logHotkeyPerfMetric("toggle_window", action: "show", context: perfContext)
        appToggleReturnApplicationProcessID = returnApplicationProcessID
        scheduleDeferredHotkeySelectionRefresh(focusedWorkspaceID: focusedWorkspaceID ?? nil, source: selectionRefreshSource)
    }

    func revealTargetedHotkeyWindow(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        if Self.shouldFocusVisibleTargetedHotkeyWindow(
            appIsActive: NSApp.isActive, windowIsVisible: window.isVisible, windowIsMiniaturized: window.isMiniaturized)
        {
            window.orderFront(nil)
            window.makeKey()
            return
        }
        if Self.shouldUseDirectTargetedHotkeyReveal(appIsActive: NSApp.isActive) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        if Self.shouldActivateAppForTargetedHotkeyReveal(appIsActive: NSApp.isActive) { activateCurrentApplicationForTargetedReveal() }
        prepareWindowForActiveSpaceSummon(window)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        Task { @MainActor [weak window] in
            await Task.yield()
            guard let window, window.isVisible, !window.isMiniaturized else { return }
            window.makeKeyAndOrderFront(nil)
        }
    }

    func prepareWindowForActiveSpaceSummon(_ window: NSWindow) {
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

    nonisolated static func shouldUseDirectTargetedHotkeyReveal(appIsActive: Bool) -> Bool { appIsActive }

    nonisolated static func shouldActivateAppForTargetedHotkeyReveal(appIsActive: Bool) -> Bool { !appIsActive }

    nonisolated static func shouldFocusVisibleTargetedHotkeyWindow(appIsActive: Bool, windowIsVisible: Bool, windowIsMiniaturized: Bool) -> Bool {
        appIsActive && windowIsVisible && !windowIsMiniaturized
    }

    nonisolated static func shouldActivateAppForCommandPalettePresentation(appIsActive: Bool) -> Bool { !appIsActive }

    private func scheduleDeferredHotkeySelectionRefresh(focusedWorkspaceID: String?, source: String) {
        deferredHotkeySelectionRefreshTask?.cancel()
        deferredHotkeySelectionRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            let refreshStartedAt = Date()
            self.refreshWorkspaceSelectionForActivation(focusedWorkspaceID: focusedWorkspaceID)
            self.logPerfMetric(
                "toggle_window_selection_refresh", target: "workspace=\(focusedWorkspaceID ?? "keep_current")",
                elapsedMS: self.windowShortcutElapsedMS(since: refreshStartedAt), success: true, detail: "source=\(source)")
        }
    }

    func refreshWorkspaceSelectionForActivation(focusedWorkspaceID: String?) {
        guard case .workspace(let targetWorkspaceID)? = Self.activationSelectionTarget(focusedWorkspaceID: focusedWorkspaceID) else {
            // No tracked focused window: the summon carries no view intent, so re-render the current pane
            // so its contents are fresh and change nothing about which pane is shown. `refreshSelection`
            // would re-resolve the pane from the selection, which is more than a summon is allowed to do.
            rerenderVisibleDetailPane()
            return
        }
        guard let (_, workspace) = findWorkspace(id: targetWorkspaceID) else { return }
        if selectedWorkspaceID == targetWorkspaceID, !showingAlerts, !showingSettings {
            refreshSelection()
            return
        }
        selectWorkspace(workspace)
    }

    /// Redraws the pane already on screen against current device state and resolves nothing else, so
    /// which pane is shown cannot change. Each case re-renders only while its own content still stands
    /// up; when it does not, the pane is left as it is for the next reload to reconcile.
    private func rerenderVisibleDetailPane() {
        switch detailPane {
        case .none: return
        case .alerts: alerts.showAlertsDetail()
        case .automations: showAutomationsDetail()
        case .workspace(let workspaceID, _):
            guard let (project, workspace) = findWorkspace(id: workspaceID) else { return }
            showWorkspaceDetail(project: project, workspace: workspace)
        case .compatibilityBlock(let deviceID):
            guard let verdict = deviceCompatibility(forDeviceID: deviceID), !verdict.isCompatible else { return }
            showCompatibilityBlock(deviceID: deviceID, verdict: verdict)
        }
    }

    public func splitViewDidResizeSubviews(_ notification: Notification) {
        // The titlebar tab strip starts at the right pane's leading edge; keep it in
        // step with divider drags.
        if let sidebarWidth = splitView?.arrangedSubviews.first?.frame.width, sidebarWidth > 0 { panelTabStripView.sidebarWidth = sidebarWidth }
    }

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
        if let focusedWindow = notification.object as? NSWindow {
            logHotkeyDebug("window_did_become_key class=\(type(of: focusedWindow)) title=\(focusedWindow.title) \(hotkeyWindowStateSummary())")
            if focusedWindow === commandPalette.commandPalettePanel { commandPalette.completePendingCommandPalettePresentationIfNeeded() }
        }
        guard !hasAppliedSplitViewWidth else { return }
        hasAppliedSplitViewWidth = true
        applySplitViewWidth()
    }

    public func windowDidResignKey(_ notification: Notification) {
        guard let resignedWindow = notification.object as? NSWindow else { return }
        logHotkeyDebug("window_did_resign_key class=\(type(of: resignedWindow)) title=\(resignedWindow.title) \(hotkeyWindowStateSummary())")
        if resignedWindow === commandPalette.commandPalettePanel, !commandPalette.isDismissingCommandPalette {
            commandPalette.dismissCommandPalette()
        }
    }

    @objc public func numberOfRows(in tableView: NSTableView) -> Int {
        guard tableView === commandPalette.commandPaletteTableView else { return 0 }
        return commandPalette.commandPaletteFilteredItems.count
    }

    @objc public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableView === commandPalette.commandPaletteTableView else { return nil }
        guard commandPalette.commandPaletteFilteredItems.indices.contains(row) else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("command-palette-cell")
        let cell =
            (tableView.makeView(withIdentifier: identifier, owner: self) as? CommandPaletteTableCellView)
            ?? {
                let cell = CommandPaletteTableCellView()
                cell.identifier = identifier
                cell.translatesAutoresizingMaskIntoConstraints = false
                return cell
            }()

        let item = commandPalette.commandPaletteFilteredItems[row]
        let shortcutText = row < 10 ? windowShortcutBadgeText(index: row + 1) : nil
        cell.update(item: item, isSelected: row == commandPalette.commandPaletteSelectedIndex, shortcutText: shortcutText) { [weak self] in
            self?.commandPalette.commandPaletteSelectedIndex = row
            self?.commandPalette.executeSelectedCommandPaletteItem()
        }
        return cell
    }

    @objc public func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView, tableView === commandPalette.commandPaletteTableView else { return }
        guard tableView.selectedRow >= 0 else { return }
        commandPalette.commandPaletteSelectedIndex = tableView.selectedRow
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<tableView.numberOfRows), columnIndexes: IndexSet(integer: 0))
    }

}

@MainActor private final class CommandPaletteRowView: NSView {
    private let shortcutContainer = NSView()
    private let statusContainer = NSView()
    private let workspaceField = NSTextField(labelWithString: "")
    private let branchContainer = NSStackView()
    private let branchIconView = NSImageView()
    private let branchField = NSTextField(labelWithString: "")
    private let alertsIndicatorView = NSImageView()
    private let labelField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let iconContainer = NSView()
    private var clickHandler: (() -> Void)?
    private var isSelectedState = false

    init(item: CommandPaletteItem, isSelected: Bool, onClick: @escaping () -> Void) {
        clickHandler = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        setContentHuggingPriority(.defaultHigh, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true

        let content = NSStackView()
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 7
        content.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        content.translatesAutoresizingMaskIntoConstraints = false
        content.detachesHiddenViews = true

        shortcutContainer.translatesAutoresizingMaskIntoConstraints = false
        shortcutContainer.setContentHuggingPriority(.required, for: .horizontal)
        shortcutContainer.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            shortcutContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 26),
            shortcutContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 14),
        ])

        statusContainer.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.setContentHuggingPriority(.required, for: .horizontal)
        statusContainer.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            statusContainer.widthAnchor.constraint(equalToConstant: 16), statusContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 14),
        ])

        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.setContentHuggingPriority(.required, for: .horizontal)
        iconContainer.setContentCompressionResistancePriority(.required, for: .horizontal)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        labelField.font = Typography.sectionTitle
        labelField.textColor = Theme.text
        labelField.lineBreakMode = .byTruncatingTail
        labelField.maximumNumberOfLines = 1

        detailField.font = Typography.monoMetadata
        detailField.textColor = Theme.muted
        detailField.lineBreakMode = .byTruncatingTail
        detailField.maximumNumberOfLines = 1

        workspaceField.font = Typography.captionTitle
        workspaceField.textColor = Theme.accentStrong
        workspaceField.lineBreakMode = .byTruncatingTail
        workspaceField.maximumNumberOfLines = 1

        branchContainer.orientation = .horizontal
        branchContainer.alignment = .centerY
        branchContainer.spacing = 4
        branchContainer.translatesAutoresizingMaskIntoConstraints = false
        branchContainer.setContentHuggingPriority(.required, for: .horizontal)
        branchContainer.setContentCompressionResistancePriority(.required, for: .horizontal)

        branchIconView.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Branch")
        branchIconView.contentTintColor = Theme.mutedSecondary
        branchIconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            branchIconView.widthAnchor.constraint(equalToConstant: 9), branchIconView.heightAnchor.constraint(equalToConstant: 9),
        ])

        branchField.font = Typography.monoCaption
        branchField.textColor = Theme.mutedSecondary
        branchField.lineBreakMode = .byTruncatingTail
        branchField.maximumNumberOfLines = 1

        branchContainer.addArrangedSubview(branchIconView)
        branchContainer.addArrangedSubview(branchField)

        alertsIndicatorView.image = NSImage(systemSymbolName: "bell.badge", accessibilityDescription: "Alerts notification")
        alertsIndicatorView.contentTintColor = Theme.red
        alertsIndicatorView.translatesAutoresizingMaskIntoConstraints = false
        alertsIndicatorView.setContentHuggingPriority(.required, for: .horizontal)
        alertsIndicatorView.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            alertsIndicatorView.widthAnchor.constraint(equalToConstant: 14), alertsIndicatorView.heightAnchor.constraint(equalToConstant: 14),
        ])

        let topTextRow = NSStackView()
        topTextRow.orientation = .horizontal
        topTextRow.alignment = .firstBaseline
        topTextRow.spacing = 5
        topTextRow.translatesAutoresizingMaskIntoConstraints = false
        topTextRow.addArrangedSubview(labelField)
        topTextRow.addArrangedSubview(detailField)

        let lowerTextRow = NSStackView()
        lowerTextRow.orientation = .horizontal
        lowerTextRow.alignment = .firstBaseline
        lowerTextRow.spacing = 5
        lowerTextRow.translatesAutoresizingMaskIntoConstraints = false
        lowerTextRow.addArrangedSubview(workspaceField)
        lowerTextRow.addArrangedSubview(branchContainer)
        lowerTextRow.addArrangedSubview(NSView())

        textStack.addArrangedSubview(topTextRow)
        textStack.addArrangedSubview(lowerTextRow)

        content.addArrangedSubview(statusContainer)
        content.addArrangedSubview(shortcutContainer)
        content.addArrangedSubview(iconContainer)
        content.addArrangedSubview(textStack)
        content.addArrangedSubview(NSView())
        content.addArrangedSubview(alertsIndicatorView)

        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor), content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor), content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        attachRowClickAction(to: self) { [weak self] in self?.clickHandler?() }
        update(item: item, isSelected: isSelected, shortcutText: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) not available") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 40) }

    func update(item: CommandPaletteItem, isSelected: Bool, shortcutText: String?, onClick: (() -> Void)? = nil) {
        if let onClick { clickHandler = onClick }
        isSelectedState = isSelected
        layer?.borderWidth = isSelected ? 1 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isSelected ? Theme.rowSelectedCard : .clear).cgColor
            layer?.borderColor = (isSelected ? Theme.rowSelectedCardBorder : NSColor.clear).cgColor
        }

        labelField.stringValue = item.label
        workspaceField.stringValue = item.workspaceContextText
        branchField.stringValue = item.workspaceBranch ?? ""
        branchContainer.isHidden = (item.workspaceBranch?.isEmpty ?? true)
        alertsIndicatorView.isHidden = !item.isAlertsAttention
        detailField.stringValue = item.detail ?? ""
        detailField.isHidden = (item.detail?.isEmpty ?? true)

        for view in shortcutContainer.subviews { view.removeFromSuperview() }
        if let shortcutText, !shortcutText.isEmpty {
            let shortcutView = RowPrimitives.shortcutChip(shortcutText)
            shortcutView.translatesAutoresizingMaskIntoConstraints = false
            shortcutContainer.addSubview(shortcutView)
            NSLayoutConstraint.activate([
                shortcutView.leadingAnchor.constraint(equalTo: shortcutContainer.leadingAnchor),
                shortcutView.trailingAnchor.constraint(equalTo: shortcutContainer.trailingAnchor),
                shortcutView.centerYAnchor.constraint(equalTo: shortcutContainer.centerYAnchor),
            ])
        }

        for view in iconContainer.subviews { view.removeFromSuperview() }
        let icon = RowPrimitives.typeIconTile(item.typeKind, symbol: item.iconSymbol, accessibilityLabel: item.label)
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor),
            icon.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor), icon.topAnchor.constraint(equalTo: iconContainer.topAnchor),
            icon.bottomAnchor.constraint(equalTo: iconContainer.bottomAnchor),
        ])

        for view in statusContainer.subviews { view.removeFromSuperview() }
        if let statusView = statusView(for: item.status) {
            statusContainer.addSubview(statusView)
            NSLayoutConstraint.activate([
                statusView.centerXAnchor.constraint(equalTo: statusContainer.centerXAnchor),
                statusView.centerYAnchor.constraint(equalTo: statusContainer.centerYAnchor),
            ])
        }
    }

    private func statusView(for status: CommandPaletteItem.Status) -> NSView? {
        guard let attentionStatus = status.attentionStatus else { return nil }
        if case .agent(.spinning) = status { return RowPrimitives.attentionSpinner(attentionStatus) }
        return RowPrimitives.attentionStatusDot(attentionStatus)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isSelectedState ? Theme.rowSelectedCard.cgColor : NSColor.clear.cgColor
            layer?.borderColor = isSelectedState ? Theme.rowSelectedCardBorder.cgColor : NSColor.clear.cgColor
        }
    }
}

@MainActor private final class CommandPaletteTableCellView: NSTableCellView {
    private var rowView: CommandPaletteRowView?

    func update(item: CommandPaletteItem, isSelected: Bool, shortcutText: String?, onClick: @escaping () -> Void) {
        if let rowView {
            rowView.update(item: item, isSelected: isSelected, shortcutText: shortcutText, onClick: onClick)
            return
        }

        let rowView = CommandPaletteRowView(item: item, isSelected: isSelected, onClick: onClick)
        rowView.update(item: item, isSelected: isSelected, shortcutText: shortcutText, onClick: onClick)
        addSubview(rowView)
        NSLayoutConstraint.activate([
            rowView.leadingAnchor.constraint(equalTo: leadingAnchor), rowView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowView.topAnchor.constraint(equalTo: topAnchor), rowView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.rowView = rowView
    }
}

extension SpacesDeviceOverviewPayload {
    /// Empty stand-in rendered for an offline or wire-incompatible device, which has no decodable
    /// overview. Its inline daemon status is never consulted — sidebar sections track live status
    /// separately — so it advertises the unknown protocol version rather than a fabricated match.
    /// `deviceAPIAddresses` is left at its `[]` default: this status describes no real device (there is
    /// nothing to query interfaces on), and `[]` is exactly the "reported nothing" value a client
    /// should treat as absence of information — the correct answer for a placeholder.
    fileprivate static let offlinePlaceholder = SpacesDeviceOverviewPayload(
        workspaces: [], sessions: [],
        daemonStatus: TerminalServiceDaemonStatus(
            version: "", installedVersion: nil, certificateFingerprint: nil, activeSessionCount: 0,
            protocolVersion: TerminalServiceDaemonStatus.unknownProtocolVersion))
}
