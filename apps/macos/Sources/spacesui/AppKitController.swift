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

private final class InlineWorkspaceEditorTextView: NSTextView {
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch Int(event.keyCode) {
        case kVK_Escape:
            onCancel?()
            return
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if flags == .command {
                onSave?()
                return
            }
        default: break
        }
        super.keyDown(with: event)
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return
        }
        super.doCommand(by: selector)
    }
}

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

    private final class MainThreadResultBox<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<T, Error>?

        func set(_ result: Result<T, Error>) {
            lock.lock()
            self.result = result
            lock.unlock()
        }

        func get() -> Result<T, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    enum AlertsIconTint: Sendable {
        case browser
        case terminal
        case code
        case success
        case warning
    }

    struct AlertsAttentionEntry: Sendable {
        let attentionID: String
        let icon: String
        let iconTint: AlertsIconTint
        let label: String
        let detail: String?
        let shortcut: String
        let processStatus: RunningProcessState?
        let agentStatus: AgentWindowStatus?
        let countsTowardBadge: Bool
        let eventDate: Date?
        let focusRequest: WindowFocusRequest?
    }

    struct AlertsGroup: Sendable {
        let projectName: String
        let workspaceID: String
        let workspaceName: String
        let workspaceBranch: String?
        let items: [AlertsAttentionEntry]
        var latestDate: Date? { items.compactMap(\.eventDate).max() }
    }

    struct MissingConfiguredProcessAlertsItem: Sendable, Equatable {
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
        case alerts
        case workspace(String)
    }

    enum TerminalQuitPolicy: Equatable, Sendable {
        case quitImmediately
        case promptForLiveSessions(count: Int)
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

    private struct PreparedGitProjectDiscardEntry {
        let id: UUID
        let task: Task<Result<Void, Error>, Never>
    }

    var window: NSWindow!
    private var splitView: NSSplitView?
    let outlineView = SidebarOutlineView()
    lazy var sidebar = SidebarController(host: self)
    let detailContainer = NSView()
    /// The right panel's footer strip: workspace details for the selected workspace.
    private weak var workspaceDetailFooterRow: NSStackView?
    private var workspaceNotesPopover: NSPopover?
    private weak var workspaceNotesEditorTextView: NSTextView?
    private var workspaceNotesEditorWorkspaceID: String?
    // workspaceShortcutFooterLabels removed — footer rebuilt on each refresh
    var projects: [ProjectSummary] = []
    var workspacesByProject: [String: [WorkspaceSummary]] = [:] { didSet { sidebar.invalidateVisibleWorkspacesCache() } }
    var workspaceRuntimeStatusByID: [String: WorkspaceRuntimeStatus] = [:]
    // The macOS app always loads its own local daemon first; these hold that local
    // device and act as the default target when no row is selected. Per-row device
    // context is resolved via deviceID(for…) helpers and the device sections.
    var localDeviceID = SpacesPairedDeviceRecord.localDeviceID
    var localDeviceName = "This Mac"
    var localPairedDevice: SpacesPairedDeviceRecord?
    var localDeviceOverview: SpacesDeviceOverviewPayload?
    var deviceSections: [DeviceSection] = []
    var alertsGroups: [AlertsGroup] = []
    var visibleDetailWorkspaceID: String?
    /// Device whose compatibility block is currently shown in the detail pane (when no workspace is
    /// selected). Lets the block survive background sidebar reloads instead of being replaced.
    var visibleCompatibilityBlockDeviceID: String?

    var selectedProjectID: String? { didSet { overlays.updateOperationProgressOverlayVisibility() } }
    var selectedWorkspaceID: String? { didSet { overlays.updateOperationProgressOverlayVisibility() } }
    var lastSelectedRow: Int = -1
    var suppressOutlineSelectionChanges = false
    // Clearing any reload blocker (unsaved project settings, an open add form) can
    // happen from several paths; flushing here covers them all so a deferred
    // database/worktree reload is never stranded once the user is idle again.
    private var projectHasUnsavedChanges = false { didSet { if oldValue, !projectHasUnsavedChanges { flushDeferredSidebarReloadsIfNeeded() } } }
    var showingSettings = false

    private var hotkeyHandler: EventHandlerRef?
    private var hotkeyRefs: [UInt32: EventHotKeyRef] = [:]
    var shortcutLeaderModifiers: Set<HotkeyModifier> = []
    private var pendingLeaderCaptureModifiers: Set<HotkeyModifier> = []
    private var toggleShortcutSpec: HotkeySpec?
    private var commandPaletteShortcutSpec: HotkeySpec?
    private var shortcutMonitor: Any?
    private var addWorkspaceShortcutSpec: HotkeySpec?
    private var reloadShortcutSpec: HotkeySpec?
    private var openEditorShortcutSpec: HotkeySpec?
    private var openTerminalShortcutSpec: HotkeySpec?
    private var openFinderShortcutSpec: HotkeySpec?
    private var openSettingsShortcutSpec: HotkeySpec?
    private var nextShortcutSpec: HotkeySpec?
    private var previousShortcutSpec: HotkeySpec?
    private var windowShortcutSpec: HotkeySpec?
    var shortcutButtonsBySetting: [String: NSButton] = [:]
    var activeShortcutCaptureSetting: ShortcutSetting?
    private var deferredHotkeySelectionRefreshTask: Task<Void, Never>?
    private var activeSpaceSummonCleanupTask: Task<Void, Never>?
    private var workspaceSetupDetailRefreshTimer: Timer?
    private var workspaceSetupDetailRefreshWorkspaceID: String?
    private weak var workspaceSetupLogTextView: NSTextView?
    lazy var commandPalette = CommandPaletteController(host: self)
    lazy var panelCoordinator: PanelCoordinator = {
        let coordinator = PanelCoordinator(host: self)
        coordinator.onLayoutChanged = { [weak self] scope, layout in self?.persistPanelLayout(scope: scope, layout: layout) }
        return coordinator
    }()
    /// Persisted `panel_windows` rows not yet reopened this launch (nil until first
    /// read). A row stays pending until every device its panes reference has a loaded
    /// overview, so an offline remote's windows return when the device does.
    var pendingPanelWindowRestores: [SpacesClientDatabase.PanelWindowRecord]?
    lazy var alerts = AlertsController(host: self)
    lazy var overlays = TransientOverlaysController(host: self)
    lazy var workspaceVisibility = WorkspaceVisibilityController(host: self)
    lazy var settings = SettingsController(host: self)
    lazy var devicePairing = DevicePairingController(host: self)
    private var addProjectWindow: NSWindow?
    private var addWorkspaceWindow: NSWindow?
    private var projectSettingsWindow: NSWindow?
    var projectSettingsProjectID: String?
    var workspaceSettingsWindow: NSWindow?
    var workspaceSettingsWorkspaceID: String?
    private var pathCompletionFieldEditor: PathCompletionTextView?
    private lazy var updaterController: SPUStandardUpdaterController? = {
        guard Self.isRunningFromAppBundle else { return nil }
        return SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }()
    /// Distributed IPC notifications observed while the app is running, paired with their `@objc` handlers.
    /// `self` is the observer for every one, so registration and teardown are uniform loops.
    private static let distributedIPCObservers: [(name: Notification.Name, selector: Selector)] = [
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
        (IPCNotification.runWorkspaceProcess, #selector(handleRunWorkspaceProcessIPC(_:))),
        (IPCNotification.stopWorkspaceProcess, #selector(handleStopWorkspaceProcessIPC(_:))),
        (IPCNotification.restartWorkspaceProcess, #selector(handleRestartWorkspaceProcessIPC(_:))),
        (IPCNotification.launchWorkspaceAgent, #selector(handleLaunchWorkspaceAgentIPC(_:))),
        (IPCNotification.openTerminalSessionWindow, #selector(handleOpenTerminalSessionWindowIPC(_:))),
        (IPCNotification.closeTerminalSessionWindow, #selector(handleCloseTerminalSessionWindowIPC(_:))),
        (IPCNotification.dumpTerminalSessionWindowState, #selector(handleDumpTerminalSessionWindowStateIPC(_:))),
        (IPCNotification.performTerminalSessionWindowShortcut, #selector(handlePerformTerminalSessionWindowShortcutIPC(_:))),
        (IPCNotification.focusTerminalSessionWindow, #selector(handleFocusTerminalSessionWindowIPC(_:))),
        (IPCNotification.databaseDidChange, #selector(handleDatabaseDidChangeIPC(_:))),
        (IPCNotification.deliverUserNotification, #selector(handleDeliverUserNotificationIPC(_:))),
    ]
    private var appDidBecomeActiveObserver: NSObjectProtocol?
    private var appDidResignActiveObserver: NSObjectProtocol?
    private var workspaceDidTerminateApplicationObserver: NSObjectProtocol?
    private var terminalAttachmentStateDidChangeObserver: NSObjectProtocol?
    private var textInputDidEndEditingObserver: NSObjectProtocol?
    private var didStartBackgroundServices = false
    private let browserSSHForwardManager = BrowserSSHForwardManager()
    private var remoteBrowserForwardRevisions: [String: Int] = [:]
    var chromeAutomationSetupController: ChromeAutomationSetupController?
    private var activeWindowShortcutProfile: WindowShortcutProfile?
    private let startupProfileStartTime = startupProfileBaselineUptime
    private var didLogFirstStartupInteraction = false
    private let launchProfile: SpacesProfile
    private let appOwnerLease: SpacesProcessLease
    private var desktopControlLease: SpacesProcessLease?
    private var passiveDesktopControlOwner: SpacesProcessLeaseOwner?
    private let ipcNotificationObject: String

    var configCache: AppConfig?
    private let defaultSplitViewWidth: CGFloat = 360
    private let shortcutLabelColumnWidth: CGFloat = 250
    private var isApplyingSplitViewWidth = false
    private var hasAppliedSplitViewWidth = false
    var activeAddWorkspaceFormTag: Int? { didSet { if oldValue != nil, activeAddWorkspaceFormTag == nil { flushDeferredSidebarReloadsIfNeeded() } } }
    var activeAddProjectFormTag: Int? { didSet { if oldValue != nil, activeAddProjectFormTag == nil { flushDeferredSidebarReloadsIfNeeded() } } }
    private var preparedGitProjectDiscardTasksByURL: [String: PreparedGitProjectDiscardEntry] = [:]
    private lazy var iso8601Formatter: ISO8601DateFormatter = ISO8601DateFormatter()

    var showingAlerts = false
    private var deferredExternalWindowHideTask: Task<Void, Never>?
    private var keepsTerminalSessionsRunningDuringTermination = false
    private var appToggleReturnApplicationProcessID: pid_t?
    private var terminalRuntimeControlDescriptorsBySessionID: [String: TerminalRuntimeControlDescriptor] = [:]

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

    struct TerminalRuntimeControlDescriptor: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case process
            case codingAgent
            case workspaceTerminal
        }

        let kind: Kind
        let deviceID: String?
        let workspaceID: String
        let sessionID: String
        let title: String
        let processID: String?
        let processTemplateID: String?
        let processKey: String?
        let agentID: String?
        let agentLauncherID: String?
        let agentLauncherName: String?
        let canRun: Bool
        let canStop: Bool
        let canRestart: Bool

        init(
            kind: Kind, deviceID: String? = nil, workspaceID: String, sessionID: String, title: String, processID: String?,
            processTemplateID: String?, processKey: String?, agentID: String?, agentLauncherID: String?, agentLauncherName: String?, canRun: Bool,
            canStop: Bool, canRestart: Bool
        ) {
            self.kind = kind
            self.deviceID = deviceID
            self.workspaceID = workspaceID
            self.sessionID = sessionID
            self.title = title
            self.processID = processID
            self.processTemplateID = processTemplateID
            self.processKey = processKey
            self.agentID = agentID
            self.agentLauncherID = agentLauncherID
            self.agentLauncherName = agentLauncherName
            self.canRun = canRun
            self.canStop = canStop
            self.canRestart = canRestart
        }
    }

    enum WindowFocusRequest: Sendable {
        case workspaceBrowserSession(workspaceID: String, targetURL: String)
        case workspaceWindow(workspaceID: String, index: Int)
        case workspaceProcess(workspaceID: String, processID: String)
        case workspaceMissingConfiguredProcess(workspaceID: String, processKey: String)
        case workspaceAgentLauncher(workspaceID: String, name: String)
        case agentWindow(AgentWindowRecord)

        var workspaceID: String {
            switch self {
            case .workspaceBrowserSession(let workspaceID, _), .workspaceWindow(let workspaceID, _), .workspaceProcess(let workspaceID, _),
                .workspaceMissingConfiguredProcess(let workspaceID, _), .workspaceAgentLauncher(let workspaceID, _):
                return workspaceID
            case .agentWindow(let record): return record.workspaceID
            }
        }
    }

    enum ExternalWindowAction: Sendable {
        case focus(hidesApp: Bool)
        case open(hidesApp: Bool)
    }

    private static let isRunningFromAppBundle = Bundle.main.bundleURL.pathExtension == "app"

    public init(launchContext: SpacesAppLaunchContext) {
        launchProfile = launchContext.profile
        appOwnerLease = launchContext.appOwnerLease
        ipcNotificationObject = launchContext.profile.ipcNotificationObject
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

    private lazy var hotkeyHandlerProc: EventHandlerUPP = { _, event, userData in
        guard let userData else { return noErr }
        let controller = Unmanaged<AppKitController>.fromOpaque(userData).takeUnretainedValue()
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        if status != noErr { return status }
        controller.logHotkeyDebug(
            "event_received id=\(hotKeyID.id) status=\(status) main_thread=\(Thread.isMainThread ? 1 : 0) \(controller.hotkeyWindowStateSummary())")
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                controller.logHotkeyDebug("event_dispatch_direct id=\(hotKeyID.id)")
                controller.handleGlobalHotkey(id: hotKeyID.id)
            }
        } else {
            Task { @MainActor in
                controller.logHotkeyDebug("event_dispatch_task id=\(hotKeyID.id)")
                controller.handleGlobalHotkey(id: hotKeyID.id)
            }
        }
        return noErr
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Self.applyPersistentTerminationPolicy()
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
        loadShortcutSpecs()
        logStartupProfile("shortcut_specs_loaded")
        setupGlobalHotkey()
        logStartupProfile("global_hotkeys_ready", details: "desktop_control=\(desktopControlLease == nil ? "passive" : "active")")
        setupShortcutMonitor()
        logStartupProfile("shortcut_monitor_ready")
        for observer in Self.distributedIPCObservers {
            DistributedNotificationCenter.default().addObserver(
                self, selector: observer.selector, name: observer.name, object: nil, suspensionBehavior: .deliverImmediately)
        }
        setupAppActivationObservers()
        setupWorkspaceApplicationObservers()
        setupTerminalAttachmentStateObserver()
        setupTextInputDidEndEditingObserver()
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionTerminator(Self.terminateBuiltInTerminalSession)
        logStartupProfile("ipc_observers_ready")
        Self.scheduleAfterNextRunLoopTurn { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.buildShellWindow()
                self.logStartupProfile("shell_window_ready")
                self.startWorkspaceUIAfterPermissionCheck()
                self.ensureMainWindowVisibleOnLaunch()
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

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let liveSessions = Self.liveBuiltInTerminalSessions()
        switch Self.terminalQuitPolicy(liveTerminalSessionCount: liveSessions.count) {
        case .quitImmediately:
            keepsTerminalSessionsRunningDuringTermination = true
            return .terminateNow
        case .promptForLiveSessions:
            switch presentTerminalQuitDialog(liveSessionCount: liveSessions.count) {
            case .keepRunning:
                keepsTerminalSessionsRunningDuringTermination = true
                return .terminateNow
            case .stopAll:
                keepsTerminalSessionsRunningDuringTermination = false
                let stoppedCount = Self.stopAllBuiltInTerminalSessions(liveSessions: liveSessions)
                guard stoppedCount == liveSessions.count else {
                    showError(WorkspaceError.invalidArgument(message: "Unable to stop all terminal sessions before quitting."))
                    return .terminateCancel
                }
                return .terminateNow
            case .cancel: return .terminateCancel
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        if let result = discardActiveAddProjectPreparedSourceSynchronouslyIfNeeded(), case .failure(let error) = result {
            NSLog("spaces: prepared add-project cleanup failed during termination: \(String(describing: error))")
        }
        deferredHotkeySelectionRefreshTask?.cancel()
        browserSSHForwardManager.stopAll()
        sidebar.cancelSidebarReloadTask()
        teardownGlobalHotkey()
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
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
        if let terminalAttachmentStateDidChangeObserver {
            NotificationCenter.default.removeObserver(terminalAttachmentStateDidChangeObserver)
            self.terminalAttachmentStateDidChangeObserver = nil
        }
        if let textInputDidEndEditingObserver {
            NotificationCenter.default.removeObserver(textInputDidEndEditingObserver)
            self.textInputDidEndEditingObserver = nil
        }
        commandPalette.commandPaletteLoadTask?.cancel()
        commandPalette.commandPaletteLoadTask = nil
        commandPalette.commandPalettePanel?.close()
        // Terminal windows once detached their clients as AppKit closed them during
        // termination; panes are not closed by AppKit, so detach their clients here.
        // The sessions themselves are untouched — quit keeps them running unless the
        // quit dialog already stopped them all.
        panelCoordinator.closeAllContentForTermination()
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

    /// The workspace's focusable targets plus the context needed to name and resolve them,
    /// using the same ordering and (all configured) browser sessions as the numbered
    /// shortcuts so by-name focus, the names dump, and Cmd-N stay consistent.
    func focusableWindowContext(workspaceID: String) -> (
        detail: SpacesDeviceWorkspaceDetailViewModel, overview: SpacesDeviceOverviewPayload, browserSessions: [BrowserSession],
        targets: [WorkspaceRunShortcutTarget]
    )? {
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
        case .browser: return browserSessionDisplayName(for: target.targetURL, sessions: browserSessions)
        case .process: return target.processID.flatMap { id in detail.processRows.first(where: { ($0.processID ?? $0.id) == id })?.name }
        case .window: return target.windowListIndex.flatMap { detail.terminalRows.indices.contains($0) ? detail.terminalRows[$0].title : nil }
        case .agent: return target.agentWindow?.label
        case .missingConfiguredProcess: return target.processKey
        case .agentLauncher: return target.launcherName
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
        func logResult(_ success: Bool) {
            logPerfMetric("named_window_focus", target: name, elapsedMS: windowShortcutElapsedMS(since: startedAt), success: success)
        }
        guard let context = focusableWindowContext(workspaceID: workspaceID),
            let target = context.targets.first(where: {
                Self.focusableWindowName(for: $0, detail: context.detail, browserSessions: context.browserSessions).map {
                    Self.normalizedRunRowName($0) == Self.normalizedRunRowName(name)
                } ?? false
            })
        else {
            logResult(false)
            return
        }
        let resolution = Self.windowShortcutTargetResolution(target, workspaceID: workspaceID, detail: context.detail, overview: context.overview)
        guard let action = await executeWindowFocusResolution(resolution) else {
            logResult(false)
            return
        }
        logResult(true)
        hideAfterSuccessfulExternalWindowAction(action)
    }

    /// Focuses a workspace's running process window by template name. Threads `requestID`
    /// to the terminal focus so the `terminal_window_focus_ipc` line carries it, which the
    /// real-system E2E correlates; also emits `process_focus` for the non-correlated path.
    private func focusWorkspaceProcess(workspaceID: String, processName: String, requestID: String?) async {
        let startedAt = Date()
        func logResult(_ success: Bool) {
            logPerfMetric("process_focus", target: processName, elapsedMS: windowShortcutElapsedMS(since: startedAt), success: success)
        }
        guard let context = focusableWindowContext(workspaceID: workspaceID),
            let target = context.targets.first(where: { target in
                guard target.kind == .process, let id = target.processID,
                    let rowName = context.detail.processRows.first(where: { ($0.processID ?? $0.id) == id })?.name
                else { return false }
                return Self.normalizedRunRowName(rowName) == Self.normalizedRunRowName(processName)
            })
        else {
            logResult(false)
            return
        }
        let resolution = Self.windowShortcutTargetResolution(target, workspaceID: workspaceID, detail: context.detail, overview: context.overview)
        guard let action = await executeWindowFocusResolution(resolution, requestID: requestID) else {
            logResult(false)
            return
        }
        logResult(true)
        hideAfterSuccessfulExternalWindowAction(action)
    }

    // In-memory window-cycle state (a "window" is a client concept). The cursor remembers
    // the last-focused target per workspace; the cycle session preserves rotation order
    // across a short burst of rapid presses. MainActor-isolated, so no lock is needed.
    private var windowNavigationCursorByWorkspace: [String: WorkspaceWindowCycle.Cursor] = [:]
    private var windowNavigationCycleSessionByWorkspace: [String: WorkspaceWindowCycle.CycleSession] = [:]

    /// Cycles focus to the next/previous window of a workspace, entirely client-side:
    /// rebuilds the focusable targets from the workspace's overview, resolves the current
    /// target from the focused terminal session / frontmost Chrome tab / remembered
    /// cursor, advances, and focuses through the shared `executeWindowFocusResolution`.
    private func cycleWorkspaceWindow(workspaceID: String, delta: Int, preferredTerminalSessionID: String?) async {
        let cycleStartedAt = Date()
        let direction = delta > 0 ? "next" : "previous"
        // The real-system E2E waits for this `window_cycle` perf line, so emit it on both
        // success and failure (matching the orchestrator's format) — it is a parsed surface.
        func logCycleMetric(target: String, success: Bool) {
            TerminalPerformance.logWorkspaceMetric(
                "window_cycle", workspaceID: workspaceID, target: target, elapsedMS: windowShortcutElapsedMS(since: cycleStartedAt), success: success,
                detail: "direction=\(direction)")
        }
        guard let overview = overview(forWorkspaceID: workspaceID), let detail = Self.workspaceDetail(workspaceID, in: overview) else {
            logCycleMetric(target: "none", success: false)
            return
        }
        // A "window" is client state, so a configured browser session is only a cycle target
        // when it currently has an open Chrome tab. Scan Chrome once (when any browser is
        // configured) for the open tab URLs and the frontmost tab URL; the latter resolves
        // the current target when no built-in terminal session is focused.
        let chromeState: (openTabURLs: [String], frontmostURL: String?) =
            detail.config.resolvedBrowserSessions.isEmpty
            ? ([], nil)
            : await Task.detached(priority: .userInitiated) {
                let chrome = ChromeAdapter()
                guard chrome.isAvailable() else { return ([], nil) }
                return ((try? chrome.allTabs())?.map(\.url) ?? [], try? chrome.frontmostActiveTabURL())
            }.value
        let openBrowserSessions = detail.config.resolvedBrowserSessions.filter { session in
            guard let url = session.url, !url.isEmpty else { return false }
            return chromeState.openTabURLs.contains { $0.hasPrefix(url) }
        }.map(Self.localBrowserSession(from:))

        // Cycle over the same ordered targets the numbered shortcuts use, limited to running
        // windows (open browsers, running processes/terminals, agents) — not launch actions.
        let targets = Self.workspaceShortcutTargets(detail: detail, browserSessions: openBrowserSessions).filter { target in
            switch target.kind {
            case .browser, .process, .window, .agent: return true
            case .missingConfiguredProcess, .agentLauncher: return false
            }
        }
        guard !targets.isEmpty else {
            logCycleMetric(target: "none", success: false)
            return
        }

        let cursorKeys = targets.map { Self.cycleCursorKey(for: $0, detail: detail) }
        let cursor = windowNavigationCursorByWorkspace[workspaceID]
        let frontmostBrowserURL = (preferredTerminalSessionID?.isEmpty == false) ? nil : chromeState.frontmostURL
        let currentIndex = Self.cycleCurrentIndex(
            targets: targets, detail: detail, focusedTerminalSessionID: preferredTerminalSessionID, frontmostBrowserURL: frontmostBrowserURL,
            cursorKeys: cursorKeys, cursor: cursor)
        let ordering = WorkspaceWindowCycle.cycleOrdering(
            cursors: cursorKeys, currentIndex: currentIndex, session: validCycleSession(workspaceID: workspaceID))
        let orderedTargets = ordering.indices.map { targets[$0] }
        let orderedCursors = ordering.indices.map { cursorKeys[$0] }
        guard !orderedTargets.isEmpty else {
            logCycleMetric(target: "none", success: false)
            return
        }
        let startIndex = WorkspaceWindowCycle.nextIndex(orderedCount: orderedTargets.count, orderedCurrentIndex: ordering.currentIndex, delta: delta)

        var focusedAction: ExternalWindowAction?
        var resolvedIndex = startIndex
        for attempt in 0..<orderedTargets.count {
            let candidateIndex = (startIndex + (attempt * delta) + (orderedTargets.count * 4)) % orderedTargets.count
            let resolution = Self.windowShortcutTargetResolution(
                orderedTargets[candidateIndex], workspaceID: workspaceID, detail: detail, overview: overview)
            if let action = await executeWindowFocusResolution(resolution) {
                focusedAction = action
                resolvedIndex = candidateIndex
                break
            }
        }
        guard let action = focusedAction else {
            logCycleMetric(target: Self.cycleDebugName(for: orderedTargets[startIndex], detail: detail), success: false)
            return
        }

        windowNavigationCursorByWorkspace[workspaceID] = orderedCursors[resolvedIndex]
        windowNavigationCycleSessionByWorkspace[workspaceID] = WorkspaceWindowCycle.CycleSession(
            orderedCursors: orderedCursors, currentIndex: resolvedIndex, lastUsedAt: Date())
        logCycleMetric(target: Self.cycleDebugName(for: orderedTargets[resolvedIndex], detail: detail), success: true)

        let hidesApp: Bool
        switch action {
        case .focus(let value), .open(let value): hidesApp = value
        }
        if hidesApp { hideAfterSuccessfulExternalWindowAction(action) } else { commandPalette.dismissCommandPaletteForBuiltInWindowNavigation() }
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
        case .agentLauncher: return "launcher:\(target.launcherName ?? "")"
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
        case .browser, .missingConfiguredProcess, .agentLauncher: return nil
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
        case .agent: return "agent:\(target.agentWindow?.label ?? target.agentWindow?.id ?? "")"
        case .missingConfiguredProcess: return "process:\(target.processKey ?? "")"
        case .agentLauncher: return "agent:\(target.launcherName ?? "")"
        }
    }

    nonisolated private static func cycleCurrentIndex(
        targets: [WorkspaceRunShortcutTarget], detail: SpacesDeviceWorkspaceDetailViewModel, focusedTerminalSessionID: String?,
        frontmostBrowserURL: String?, cursorKeys: [String], cursor: String?
    ) -> Int? {
        if let focusedTerminalSessionID, !focusedTerminalSessionID.isEmpty {
            let matches = targets.indices.filter { cycleTargetSessionID(for: targets[$0], detail: detail) == focusedTerminalSessionID }
            if !matches.isEmpty {
                if let cursor, let match = matches.first(where: { cursorKeys[$0] == cursor }) { return match }
                return matches.last
            }
        }
        if let frontmostBrowserURL, !frontmostBrowserURL.isEmpty {
            let matches = targets.indices.compactMap { index -> (offset: Int, targetURL: String)? in
                guard targets[index].kind == .browser, let targetURL = targets[index].targetURL, !targetURL.isEmpty,
                    frontmostBrowserURL.hasPrefix(targetURL)
                else { return nil }
                return (index, targetURL)
            }
            if !matches.isEmpty {
                if let cursor, let match = matches.first(where: { cursorKeys[$0.offset] == cursor }) { return match.offset }
                return matches.max(by: { $0.targetURL.count < $1.targetURL.count })?.offset
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
            self.showingAlerts = false
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

    @objc private nonisolated func handleLaunchWorkspaceAgentIPC(_ notification: Notification) {
        let object = notification.object as? String
        guard let workspaceID = notification.userInfo?[IPCNotification.workspaceIDUserInfoKey] as? String else { return }
        guard let launcherName = notification.userInfo?[IPCNotification.workspaceTargetNameUserInfoKey] as? String else { return }
        Task { @MainActor [weak self, object, workspaceID, launcherName] in
            guard let self, self.matchesProfileIPCObject(object) else { return }
            self.launchWorkspaceAgent(workspaceID: workspaceID, launcherName: launcherName)
        }
    }

    @objc private nonisolated func handleOpenTerminalSessionWindowIPC(_ notification: Notification) {
        let object = notification.object as? String
        guard let sessionID = notification.userInfo?[IPCNotification.terminalSessionIDUserInfoKey] as? String else { return }
        let modeRawValue = notification.userInfo?[IPCNotification.terminalAttachmentModeUserInfoKey] as? String
        let mode = modeRawValue.flatMap(TerminalAttachmentMode.init(rawValue:)) ?? .owner
        let requestID = notification.userInfo?[IPCNotification.focusRequestIDUserInfoKey] as? String
        Task { @MainActor [weak self, object, sessionID, mode, requestID] in
            guard let self else { return }
            guard self.matchesProfileIPCObject(object) else { return }
            TerminalPerformance.logMetric(
                "terminal_window_open_ipc", target: "session=\(sessionID)", elapsedMS: 0, success: true,
                detail: "mode=\(mode.rawValue)\(requestID.map { " request_id=\($0)" } ?? "")")
            await self.openTerminalSessionPane(sessionID: sessionID, requestID: requestID)
        }
    }

    @objc private nonisolated func handleCloseTerminalSessionWindowIPC(_ notification: Notification) {
        let object = notification.object as? String
        guard let sessionID = notification.userInfo?[IPCNotification.terminalSessionIDUserInfoKey] as? String else { return }
        let sessionIsTerminating = (notification.userInfo?[IPCNotification.terminalSessionIsTerminatingUserInfoKey] as? String) == "true"
        Task { @MainActor [weak self, object, sessionID, sessionIsTerminating] in
            guard let self, self.matchesProfileIPCObject(object) else { return }
            TerminalPerformance.logMetric(
                "terminal_window_close_ipc", target: "session=\(sessionID)", elapsedMS: 0, success: true,
                detail: "terminating=\(sessionIsTerminating ? 1 : 0)")
            self.closeTerminalSessionPane(sessionID: sessionID, sessionIsTerminating: sessionIsTerminating)
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
            visibleSurfaceOutput: debugState?.visibleSurfaceOutput, summary: debugState?.summary, state: debugState?.state,
            showsTerminalSurface: debugState?.showsTerminalSurface, showsTextRenderer: debugState?.showsTextRenderer,
            didClose: debugState?.didCloseWindow, windowNumber: content?.contentView.window?.windowNumber, surfaceColumns: debugState?.surfaceColumns,
            surfaceRows: debugState?.surfaceRows, windowIsKey: debugState?.windowIsKey, firstResponderTypeName: debugState?.firstResponderTypeName,
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

    private final class RemoteTerminalWindowClientStore: @unchecked Sendable {
        private let lock = NSLock()
        private var clientID: String?

        func set(_ clientID: String?) {
            lock.lock()
            self.clientID = clientID
            lock.unlock()
        }

        func current() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return clientID
        }
    }

    struct TerminalSessionSummaryMatch: Sendable, Equatable {
        let device: SpacesPairedDeviceRecord
        let summary: SpacesDeviceTerminalSessionSummary
    }

    typealias TerminalSessionOverviewResolver = @Sendable (SpacesPairedDeviceRecord, SpacesDeviceClientApp) throws -> SpacesDeviceOverviewResolution

    /// The overview session summary for a session and the device that owns it,
    /// when the session is currently surfaced in a loaded device overview.
    private func terminalSessionSummaryMatch(sessionID: String) -> TerminalSessionSummaryMatch? {
        for section in deviceSections {
            guard let summary = section.overview?.sessions.first(where: { $0.id == sessionID }) else { continue }
            guard let device = deviceForMutation(deviceID: section.deviceID) else { continue }
            return TerminalSessionSummaryMatch(device: device, summary: summary)
        }
        return nil
    }

    /// The device that owns a terminal session: its overview's device, the device
    /// of the workspace that carries it, or the local device as a last resort.
    private func terminalSessionOwningDevice(sessionID: String) -> SpacesPairedDeviceRecord? {
        if let match = terminalSessionSummaryMatch(sessionID: sessionID) { return match.device }
        if let workspaceID = clientWorkspaceID(forTerminalSession: sessionID) { return deviceForWorkspaceMutation(workspaceID: workspaceID) }
        return localPairedDevice
    }

    nonisolated private static func terminalSessionLaunchConfiguration(sessionID: String, summary: SpacesDeviceTerminalSessionSummary)
        -> TerminalSessionLaunchConfiguration
    {
        TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: summary.backend, lifetimePolicy: summary.lifetimePolicy, title: summary.title,
            workingDirectory: summary.workingDirectory, shell: summary.shell, command: summary.command, createdAt: summary.createdAt,
            workspaceID: summary.workspaceID, kind: terminalSessionKind(rowKind: summary.rowKind))
    }

    nonisolated private static func terminalSessionRuntimeState(sessionID: String, summary: SpacesDeviceTerminalSessionSummary)
        -> TerminalSessionRuntimeState
    {
        TerminalSessionRuntimeState(
            sessionID: sessionID, backend: summary.backend, servicePID: summary.servicePID, childPID: summary.childPID, state: summary.state,
            updatedAt: summary.updatedAt, title: summary.title, workingDirectory: summary.workingDirectory)
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
        if localPairedDevice == nil {
            guard
                let device = await Task.detached(
                    priority: .userInitiated, operation: { try? SpacesDeviceClient.bootstrapLocalDevice(clientApp: clientApp) }
                ).value
            else { return nil }
            localPairedDevice = device
            localDeviceID = device.id
        }
        guard let device = terminalSessionOwningDevice(sessionID: sessionID) else { return nil }
        return await Self.resolveSessionSummaryMatchOffMain(sessionID: sessionID, device: device, clientApp: clientApp)
    }

    nonisolated static func resolveSessionSummaryMatchOffMain(
        sessionID: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp,
        resolveOverview: @escaping TerminalSessionOverviewResolver = { device, clientApp in
            try SpacesDeviceClient.resolveOverview(device: device, clientApp: clientApp)
        }
    ) async -> TerminalSessionSummaryMatch? {
        await Task.detached(priority: .userInitiated) {
            guard let summary = try? resolveOverview(device, clientApp).overview?.overview.sessions.first(where: { $0.id == sessionID }) else {
                return nil
            }
            return TerminalSessionSummaryMatch(device: device, summary: summary)
        }.value
    }

    /// Builds the device-backed terminal state model for a session, seeding launch
    /// configuration and runtime state from the caller's known values or, failing that,
    /// the loaded device overview or an off-main cold overview lookup prepared by the
    /// caller. The model fetches the rest through the owning device's Device API, so the
    /// mac GUI never opens `spaces.db`.
    private func makeTerminalSessionStateModel(
        sessionID: String, seedDevice: SpacesPairedDeviceRecord? = nil, seedLaunchConfiguration: TerminalSessionLaunchConfiguration? = nil,
        seedInitialRuntimeState: TerminalSessionRuntimeState? = nil, resolvedSummaryMatch: TerminalSessionSummaryMatch? = nil
    ) throws -> DeviceTerminalSessionStateModel {
        let summaryMatch = terminalSessionSummaryMatch(sessionID: sessionID) ?? resolvedSummaryMatch
        guard let device = seedDevice ?? summaryMatch?.device ?? terminalSessionOwningDevice(sessionID: sessionID) else {
            throw Self.deviceNotLoadedError()
        }
        // The launch configuration carries the daemon's real shell/command, which the live
        // Device API state payload never resends (it carries only title/cwd/runtime). It must
        // come from the caller's seed or the device overview — fabricating a placeholder here
        // would leave the window summary showing the wrong launch command for the session's
        // lifetime.
        guard
            let launchConfiguration = seedLaunchConfiguration
                ?? summaryMatch.map({ Self.terminalSessionLaunchConfiguration(sessionID: sessionID, summary: $0.summary) })
        else { throw Self.terminalSessionNotFoundError() }
        let initialRuntimeState =
            seedInitialRuntimeState ?? summaryMatch.map { Self.terminalSessionRuntimeState(sessionID: sessionID, summary: $0.summary) }
        return try DeviceTerminalSessionStateModel(
            device: device, sessionID: sessionID, launchConfiguration: launchConfiguration, initialRuntimeState: initialRuntimeState,
            initialAttachmentSnapshot: summaryMatch?.summary.attachmentSnapshot,
            clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
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
        guard let summary = await resolveSessionSummaryMatch(sessionID: sessionID)?.summary, let workspaceID = summary.workspaceID else { return nil }
        return DeviceTerminalOpenRequest(
            workspaceID: workspaceID, sessionID: sessionID, title: summary.title, workingDirectory: summary.workingDirectory,
            kind: Self.terminalSessionKind(rowKind: summary.rowKind), shell: summary.shell, command: summary.command, initialState: summary.state,
            servicePID: summary.servicePID, childPID: summary.childPID, createdAt: summary.createdAt, updatedAt: summary.updatedAt)
    }

    /// Opens (or focuses) a session's pane for the open/focus IPC surfaces. Emits the
    /// `terminal_window_summon` perf metric the E2E harness parses; panes always attach
    /// as owner, so the detail reports `mode=owner`.
    @discardableResult private func openTerminalSessionPane(sessionID: String, requestID: String? = nil) async -> Bool {
        let startedAt = Date()
        let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
        cancelDeferredExternalWindowHide()
        let reusedExistingPane = panelCoordinator.placement(forSessionID: sessionID) != nil
        guard let request = await resolveTerminalSessionPaneOpenRequest(sessionID: sessionID), panelCoordinator.openOrFocusTerminalPane(request)
        else {
            logPerfMetric(
                "terminal_window_summon", target: "session=\(sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false,
                detail: "mode=owner route=pane\(requestDetail)")
            return false
        }
        logPerfMetric(
            "terminal_window_summon", target: "session=\(sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true,
            detail: "mode=owner reused=\(reusedExistingPane ? 1 : 0) route=pane\(requestDetail)")
        return true
    }

    /// Focuses a session's pane (opening it when needed) for the focus IPC, emitting the
    /// `terminal_window_focus_ipc` metric the E2E harness correlates by request id.
    private func focusTerminalSessionPane(sessionID: String, requestID: String?) async {
        let startedAt = Date()
        let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
        let focused = await openTerminalSessionPane(sessionID: sessionID, requestID: requestID)
        logPerfMetric(
            "terminal_window_focus_ipc", target: "session=\(sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: focused,
            detail: "route=pane\(requestDetail)")
    }

    /// Builds the live terminal content controller for a pane: a device-backed terminal
    /// state model plus the Device API control closures, hosted by the window-independent
    /// pane view controller. Local and remote sessions share this one path. Returns nil
    /// (surfacing the error) when the session's paths or state model cannot be built.
    func makeTerminalPaneContent(request: DeviceTerminalOpenRequest) -> TerminalPaneContentController? {
        let sessionID = request.sessionID
        do {
            let paths = try TerminalSessionPaths.forSession(id: sessionID)
            let device = deviceForWorkspaceMutation(workspaceID: request.workspaceID)
            let summary = terminalSessionSummaryMatch(sessionID: sessionID)?.summary
            let createdAt = request.createdAt ?? ISO8601DateFormatter().string(from: Date())
            // The seed launch configuration wins over the state model's own summary lookup,
            // and the live Device API state payload never resends shell/command, so seed one
            // only when a real shell is known — from the request (resolved from the source
            // overview) or the loaded summary for a row-built request. Fabricating a
            // "/bin/bash" placeholder here would mislabel the pane's launch command for the
            // session's lifetime; with no seed the state model builds from the loaded summary
            // and a session unknown to both surfaces an error instead.
            let launchConfiguration = (request.shell ?? summary?.shell).map { shell in
                TerminalSessionLaunchConfiguration(
                    sessionID: sessionID, backend: .ghosttyEmbedded, title: request.title, workingDirectory: request.workingDirectory, shell: shell,
                    command: request.command ?? summary?.command, createdAt: createdAt, workspaceID: request.workspaceID, kind: request.kind)
            }
            let initialRuntimeState = request.initialState.map {
                TerminalSessionRuntimeState(
                    sessionID: sessionID, backend: .ghosttyEmbedded, servicePID: request.servicePID ?? 0, childPID: request.childPID, state: $0,
                    updatedAt: request.updatedAt ?? createdAt, title: request.title, workingDirectory: request.workingDirectory)
            }
            let stateModel = try makeTerminalSessionStateModel(
                sessionID: sessionID, seedDevice: device, seedLaunchConfiguration: launchConfiguration, seedInitialRuntimeState: initialRuntimeState,
                resolvedSummaryMatch: nil)
            let requestSender = stateModel.terminalServiceRequestSender
            let applyControlState = stateModel.controlStateApplier
            let agentSignalHandler: RemoteGhosttyAgentSignalHandler = { [weak self] events in
                guard let self else { return [String]() }
                return self.applyRemoteAgentSignals(events)
            }
            let remoteClientStore = RemoteTerminalWindowClientStore()
            let attachClientAction: @Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void = { client, attachmentMode in
                remoteClientStore.set(client.id)
                let response = try Self.sendDeviceTerminalControl(
                    sessionID: sessionID, request: TerminalControlRequest(command: "attach", client: client, attachmentMode: attachmentMode),
                    requestSender: requestSender, refreshStateAfterControl: true, applyState: applyControlState)
                guard response.ok else { throw WorkspaceError.invalidArgument(message: response.message) }
            }
            let detachClientAction: @Sendable (String) throws -> Void = { clientID in
                if remoteClientStore.current() == clientID { remoteClientStore.set(nil) }
                let response = try Self.sendDeviceTerminalControl(
                    sessionID: sessionID, request: TerminalControlRequest(command: "detach", clientID: clientID), requestSender: requestSender,
                    refreshStateAfterControl: true, applyState: applyControlState)
                guard response.ok else { throw WorkspaceError.invalidArgument(message: response.message) }
            }
            let sendInputAction: @Sendable (String, Bool) throws -> TerminalControlResponse = { text, appendNewline in
                guard let clientID = remoteClientStore.current() else {
                    return TerminalControlResponse(ok: false, message: "Terminal pane is not attached.")
                }
                return try Self.sendDeviceTerminalControl(
                    sessionID: sessionID,
                    request: TerminalControlRequest(command: "send", text: text, clientID: clientID, appendNewline: appendNewline),
                    requestSender: requestSender, applyState: applyControlState)
            }
            let sendKeyAction: @Sendable (String) throws -> TerminalControlResponse = { key in
                guard let clientID = remoteClientStore.current() else {
                    return TerminalControlResponse(ok: false, message: "Terminal pane is not attached.")
                }
                return try Self.sendDeviceTerminalControl(
                    sessionID: sessionID, request: TerminalControlRequest(command: "key", key: key, clientID: clientID), requestSender: requestSender,
                    applyState: applyControlState)
            }
            let takeoverAction: @Sendable (String) throws -> TerminalControlResponse = { clientID in
                try Self.sendDeviceTerminalControl(
                    sessionID: sessionID, request: TerminalControlRequest(command: "takeover", clientID: clientID), requestSender: requestSender,
                    refreshStateAfterControl: true, applyState: applyControlState)
            }
            let pane = TerminalSessionPaneViewController(
                sessionID: sessionID, paths: paths, stateProvider: stateModel, preferredAttachmentMode: .owner, performInitialRefresh: false,
                sendInputAction: sendInputAction, sendKeyAction: sendKeyAction, takeoverAction: takeoverAction,
                attachClientAction: attachClientAction, detachClientAction: detachClientAction, detachClientSynchronouslyOnClose: false,
                runtimeControlsProvider: { [weak self] sessionID in
                    self?.terminalRuntimeControls(forSessionID: sessionID, cause: "controller_refresh")
                },
                sessionHostProvider: { launchConfiguration, paths in
                    Self.terminalSessionHost(
                        launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: requestSender,
                        stateStreamSubscriber: stateModel.makeHostStateStreamSubscriber(), agentSignalHandler: agentSignalHandler)
                })
            return TerminalPaneContentController(
                descriptor: .terminalSession(deviceID: deviceID(forWorkspaceID: request.workspaceID), sessionID: sessionID),
                workspaceID: request.workspaceID, sessionID: sessionID, pane: pane)
        } catch {
            showError(error)
            return nil
        }
    }

    /// Starts a fresh ad hoc terminal session on the workspace's owning daemon and
    /// resolves the pane open request for it (split fill and new-tab paths).
    func createTerminalSessionForPane(workspaceID: String, completion: @escaping (DeviceTerminalOpenRequest?) -> Void) {
        guard let device = deviceForWorkspaceMutation(workspaceID: workspaceID) else {
            showDeviceNotLoadedError()
            completion(nil)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else {
                completion(nil)
                return
            }
            let result = await Self.deviceMutation(device: device) { device in
                try SpacesDeviceClient.openWorkspaceTerminal(
                    workspaceID: workspaceID, device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
            }
            switch result {
            case .success(let response):
                self.applyDeviceMutationResponse(response, selectedWorkspaceID: workspaceID)
                guard let sessionID = response.sessionID,
                    let request = Self.deviceTerminalOpenRequest(
                        workspaceID: workspaceID, sessionID: sessionID, overview: response.overview ?? self.overview(forWorkspaceID: workspaceID))
                else {
                    completion(nil)
                    return
                }
                completion(request)
            case .failure(let error):
                self.showError(error)
                completion(nil)
            }
        }
    }

    nonisolated static func deviceTerminalControlRequest(sessionID: String, controlRequest request: TerminalControlRequest) throws
        -> SpacesDeviceTerminalControlRequest
    {
        guard request.bytes == nil else {
            throw WorkspaceError.invalidArgument(message: "Raw byte terminal control is not supported for active remote devices.")
        }
        guard let action = SpacesDeviceTerminalControlAction(rawValue: request.command) else {
            throw WorkspaceError.invalidArgument(message: "Unsupported remote terminal command '\(request.command)'.")
        }
        return SpacesDeviceTerminalControlRequest(
            action: action, sessionID: sessionID, clientID: request.clientID, client: request.client, attachmentMode: request.attachmentMode,
            text: request.text, key: request.key, columns: request.columns, rows: request.rows, ownerEpoch: request.ownerEpoch,
            resizeSerial: request.resizeSerial, scrollHorizontal: request.scrollHorizontal, scrollVertical: request.scrollVertical,
            scrollMods: request.scrollMods, appendNewline: request.appendNewline)
    }

    /// Issues a terminal control request to the session's owning device and returns
    /// the control response. When the response carries session state (notably a
    /// successful takeover), it is applied to the state model immediately so the
    /// window reflects the new owner without waiting for the live subscription.
    ///
    /// Attachment-changing controls (attach/detach, and takeover when the daemon
    /// omits the post-takeover render) do not echo session state, so
    /// `refreshStateAfterControl` fetches the post-control state and applies the new
    /// ownership directly. This forces the state model off its pre-control attachment
    /// snapshot at once rather than depending on the live subscription to redeliver
    /// the change — the subscription may be connecting or reconnecting during window
    /// open/close, which would otherwise leave the window showing the wrong owner (or
    /// retrying attachments) until another stream event arrives. The follow-up fetch
    /// is best-effort: the control already succeeded, and a stale-by-emission payload
    /// is dropped by the model, so a failed refresh falls back to the subscription
    /// instead of failing the completed control.
    nonisolated static func sendDeviceTerminalControl(
        sessionID: String, request: TerminalControlRequest, requestSender: RemoteGhosttyTerminalServiceRequestSender,
        refreshStateAfterControl: Bool = false, applyState: @Sendable (GhosttyRemoteSessionStatePayload) -> Void
    ) throws -> TerminalControlResponse {
        let response = try requestSender(TerminalServiceRequest(command: .control(.init(sessionID: sessionID, controlRequest: request))))
        guard response.ok else { throw WorkspaceError.invalidArgument(message: response.message) }
        if let sessionState = response.sessionState {
            applyState(sessionState)
        } else if refreshStateAfterControl,
            let stateResponse = try? requestSender(TerminalServiceRequest(command: .state(.init(sessionID: sessionID)))),
            let sessionState = stateResponse.sessionState
        {
            applyState(sessionState)
        }
        return response.controlResponse ?? TerminalControlResponse(ok: response.ok, message: response.message)
    }

    private func applyRemoteAgentSignals(_ events: [TerminalServiceAgentSignalEvent]) -> [String] {
        // Agent state is recorded by the daemon that owns the session and reaches this
        // client through the overview, so the window only acknowledges delivery to
        // release the owning terminal service's signal queue.
        events.map(\.id)
    }

    /// Resolves a session's kind from the loaded device overview (not the daemon
    /// database): top-level sessions carry their row kind, and process/agent rows
    /// identify configured sessions. Used to decide whether an ad hoc session stops
    /// once it has no live attachments.
    private func remoteTerminalSessionKind(sessionID: String) -> TerminalSessionKind {
        for overview in deviceSections.compactMap({ $0.overview }) {
            if let session = overview.sessions.first(where: { $0.id == sessionID }) { return Self.terminalSessionKind(rowKind: session.rowKind) }
            for workspace in overview.workspaces {
                if workspace.processRows.contains(where: { $0.sessionID == sessionID }) { return .process }
                if workspace.codingAgentRows.contains(where: { $0.sessionID == sessionID }) { return .agent }
            }
        }
        return .shell
    }

    /// Closes a session's pane for the close IPC and daemon-driven session
    /// termination, keeping the `terminal_window_close` perf metric the E2E harness
    /// parses.
    private func closeTerminalSessionPane(sessionID: String, sessionIsTerminating: Bool = false) {
        let startedAt = Date()
        guard panelCoordinator.placement(forSessionID: sessionID) != nil else {
            logPerfMetric(
                "terminal_window_close", target: "session=\(sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false,
                detail: "route=missing_pane terminating=\(sessionIsTerminating ? 1 : 0)")
            return
        }
        logPerfMetric(
            "terminal_window_close", target: "session=\(sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true,
            detail: "route=pane terminating=\(sessionIsTerminating ? 1 : 0)")
        panelCoordinator.closePane(forSessionID: sessionID, sessionIsTerminating: sessionIsTerminating)
    }

    private func terminalRuntimeControls(forSessionID sessionID: String, cause: String = "provider", requestID: String? = nil)
        -> TerminalSessionRuntimeControls?
    {
        let startedAt = Date()
        let workspaceLookupStartedAt = Date()
        guard let workspaceID = clientWorkspaceID(forTerminalSession: sessionID) else {
            let descriptorChanged = terminalRuntimeControlDescriptorsBySessionID.removeValue(forKey: sessionID) != nil
            logTerminalRuntimeControlsRefresh(
                sessionID: sessionID, startedAt: startedAt, cause: cause, requestID: requestID,
                workspaceLookupMS: windowShortcutElapsedMS(since: workspaceLookupStartedAt), settingsMS: 0, processesMS: 0, agentsMS: 0, windowsMS: 0,
                runtimeStateMS: 0, descriptorBuildMS: 0, descriptorChanged: descriptorChanged, success: false)
            return nil
        }
        let workspaceLookupMS = windowShortcutElapsedMS(since: workspaceLookupStartedAt)

        // The runtime-controls descriptor is built from the workspace's overview rows
        // (config, processes, agents, terminals) rather than daemon-DB reads.
        let settingsStartedAt = Date()
        let detail = overview(forWorkspaceID: workspaceID).flatMap { Self.workspaceDetail(workspaceID, in: $0) }
        let settings = detail.map { Self.localWorkspaceSettings(from: $0.config) }
        let settingsMS = windowShortcutElapsedMS(since: settingsStartedAt)
        let processesStartedAt = Date()
        let runningProcesses = detail.map { Self.runningProcesses(from: $0.processRows) } ?? []
        let processesMS = windowShortcutElapsedMS(since: processesStartedAt)
        let agentsStartedAt = Date()
        let agentWindows = detail.map { Self.agentWindows(from: $0.codingAgentRows) } ?? []
        let agentsMS = windowShortcutElapsedMS(since: agentsStartedAt)
        let windowsStartedAt = Date()
        let trackedWindows = detail.map { Self.deviceTerminalWindows(from: $0.terminalRows) } ?? []
        let windowsMS = windowShortcutElapsedMS(since: windowsStartedAt)
        let runtimeStateStartedAt = Date()
        let isSessionRunning = Self.terminalSessionIsRunning(sessionID: sessionID)
        let runtimeStateMS = windowShortcutElapsedMS(since: runtimeStateStartedAt)
        let descriptorBuildStartedAt = Date()
        let descriptor = Self.terminalRuntimeControlDescriptor(
            sessionID: sessionID, workspaceID: workspaceID, settings: settings, runningProcesses: runningProcesses, agentWindows: agentWindows,
            trackedWindows: trackedWindows, isSessionRunning: isSessionRunning)
        let descriptorBuildMS = windowShortcutElapsedMS(since: descriptorBuildStartedAt)
        let descriptorChanged = terminalRuntimeControlDescriptorsBySessionID[sessionID] != descriptor
        if let descriptor {
            terminalRuntimeControlDescriptorsBySessionID[sessionID] = descriptor
        } else {
            terminalRuntimeControlDescriptorsBySessionID.removeValue(forKey: sessionID)
        }
        logTerminalRuntimeControlsRefresh(
            sessionID: sessionID, startedAt: startedAt, cause: cause, requestID: requestID, workspaceLookupMS: workspaceLookupMS,
            settingsMS: settingsMS, processesMS: processesMS, agentsMS: agentsMS, windowsMS: windowsMS, runtimeStateMS: runtimeStateMS,
            descriptorBuildMS: descriptorBuildMS, descriptorChanged: descriptorChanged, success: descriptor != nil)

        guard let descriptor, descriptor.canRun || descriptor.canStop || descriptor.canRestart else { return nil }
        let runAction: (@MainActor @Sendable () -> Void)?
        if descriptor.canRun {
            runAction = { @MainActor @Sendable [weak self, descriptor] in
                guard let self else { return }
                self.runTerminalRuntime(descriptor)
            }
        } else {
            runAction = nil
        }
        let stopAction: (@MainActor @Sendable () -> Void)?
        if descriptor.canStop {
            stopAction = { @MainActor @Sendable [weak self, descriptor] in
                guard let self else { return }
                self.stopTerminalRuntime(descriptor)
            }
        } else {
            stopAction = nil
        }
        let restartAction: (@MainActor @Sendable () -> Void)?
        if descriptor.canRestart {
            restartAction = { @MainActor @Sendable [weak self, descriptor] in
                guard let self else { return }
                self.restartTerminalRuntime(descriptor)
            }
        } else {
            restartAction = nil
        }
        return TerminalSessionRuntimeControls(
            title: descriptor.title, canRun: descriptor.canRun, canStop: descriptor.canStop, canRestart: descriptor.canRestart, onRun: runAction,
            onStop: stopAction, onRestart: restartAction)
    }

    private func logTerminalRuntimeControlsRefresh(
        sessionID: String, startedAt: Date, cause: String, requestID: String?, workspaceLookupMS: Int, settingsMS: Int, processesMS: Int,
        agentsMS: Int, windowsMS: Int, runtimeStateMS: Int, descriptorBuildMS: Int, descriptorChanged: Bool, success: Bool
    ) {
        let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
        logPerfMetric(
            "terminal_runtime_controls_refresh", target: "session=\(sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
            success: success,
            detail:
                "cause=\(cause) workspace_lookup_ms=\(workspaceLookupMS) settings_ms=\(settingsMS) processes_ms=\(processesMS) agents_ms=\(agentsMS) windows_ms=\(windowsMS) runtime_state_ms=\(runtimeStateMS) descriptor_build_ms=\(descriptorBuildMS) descriptor_changed=\(descriptorChanged ? 1 : 0)\(requestDetail)"
        )
    }

    private func refreshTerminalRuntimeControls(sessionID: String, cause: String, requestID: String? = nil) {
        guard let content = panelCoordinator.content(forSessionID: sessionID) else { return }
        content.setRuntimeControls(terminalRuntimeControls(forSessionID: sessionID, cause: cause, requestID: requestID))
    }

    static func terminalRuntimeControlDescriptor(
        sessionID: String, workspaceID: String, deviceID: String? = nil, settings: WorkspaceSettings?, runningProcesses: [RunningProcessRecord],
        agentWindows: [AgentWindowRecord], trackedWindows: [WindowRecord], isSessionRunning: Bool
    ) -> TerminalRuntimeControlDescriptor? {
        guard let normalizedSessionID = normalizedTerminalSessionID(sessionID) else { return nil }
        if let process = runningProcesses.first(where: { terminalSessionID(for: $0) == normalizedSessionID }) {
            let template = configuredProcessTemplate(for: process, settings: settings)
            let title = trimmedNonEmpty(template?.name) ?? trimmedNonEmpty(process.templateName) ?? "Process"
            let processKey = trimmedNonEmpty(template?.name) ?? trimmedNonEmpty(process.templateName)
            let isRunning = process.status != .exited && isSessionRunning
            return TerminalRuntimeControlDescriptor(
                kind: .process, deviceID: deviceID, workspaceID: workspaceID, sessionID: normalizedSessionID, title: title, processID: process.id,
                processTemplateID: template?.id, processKey: processKey, agentID: nil, agentLauncherID: nil, agentLauncherName: nil,
                canRun: template != nil && !isRunning, canStop: true, canRestart: template != nil)
        }

        if let agent = agentWindows.first(where: { terminalSessionID(for: $0) == normalizedSessionID }) {
            let launcher = configuredAgentLauncher(for: agent, settings: settings)
            let windowTitle = terminalWindowTitle(for: agent, trackedWindows: trackedWindows)
            let title = trimmedNonEmpty(launcher?.name) ?? codingAgentDisplayName(label: agent.label, runtimeWindowTitle: windowTitle)
            let isRunning = agent.status != .done && isSessionRunning
            return TerminalRuntimeControlDescriptor(
                kind: .codingAgent, deviceID: deviceID, workspaceID: workspaceID, sessionID: normalizedSessionID, title: title, processID: nil,
                processTemplateID: nil, processKey: nil, agentID: agent.id, agentLauncherID: launcher?.id, agentLauncherName: launcher?.name,
                canRun: launcher != nil && !isRunning, canStop: true, canRestart: launcher != nil)
        }

        let title =
            trackedWindows.first(where: { terminalSessionID(for: $0) == normalizedSessionID }).flatMap {
                trimmedNonEmpty($0.name) ?? trimmedNonEmpty($0.detail)
            } ?? "Terminal"
        return TerminalRuntimeControlDescriptor(
            kind: .workspaceTerminal, deviceID: deviceID, workspaceID: workspaceID, sessionID: normalizedSessionID, title: title, processID: nil,
            processTemplateID: nil, processKey: nil, agentID: nil, agentLauncherID: nil, agentLauncherName: nil, canRun: false, canStop: true,
            canRestart: false)
    }

    private static func configuredProcessTemplate(for process: RunningProcessRecord, settings: WorkspaceSettings?) -> ProcessTemplate? {
        guard let settings else { return nil }
        if let templateID = trimmedNonEmpty(process.templateID) { return settings.processes.first(where: { $0.id == templateID }) }
        guard let processKey = trimmedNonEmpty(process.templateName).map(normalizedRunRowName) else { return nil }
        return settings.processes.first { normalizedRunRowName($0.name ?? "") == processKey }
    }

    private static func configuredAgentLauncher(for agent: AgentWindowRecord, settings: WorkspaceSettings?) -> AgentLauncher? {
        guard let settings else { return nil }
        if let launcherID = trimmedNonEmpty(agent.claimedLauncherID) { return settings.agentLaunchers.first(where: { $0.id == launcherID }) }
        let candidateNames = [agent.claimedLauncherName, agent.label].compactMap(trimmedNonEmpty)
        guard let launcherName = candidateNames.first.map(normalizedRunRowName) else { return nil }
        return settings.agentLaunchers.first { normalizedRunRowName($0.name) == launcherName }
    }

    private static func terminalWindowTitle(for agent: AgentWindowRecord, trackedWindows: [WindowRecord]) -> String? {
        guard let key = terminalSessionID(for: agent) else { return nil }
        return trackedWindows.first(where: { terminalSessionID(for: $0) == key }).flatMap { trimmedNonEmpty($0.name) ?? trimmedNonEmpty($0.detail) }
    }

    private static func terminalSessionID(for process: RunningProcessRecord) -> String? {
        normalizedTerminalSessionID(process.terminalNativeID ?? process.terminalTrackingID)
    }

    private static func terminalSessionID(for agent: AgentWindowRecord) -> String? {
        normalizedTerminalSessionID(agent.terminalNativeID ?? agent.terminalTrackingID)
    }

    private static func terminalSessionID(for window: WindowRecord) -> String? {
        normalizedTerminalSessionID(window.terminalNativeID ?? window.terminalTrackingID)
    }

    private static func normalizedTerminalSessionID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func deviceIDCandidate(name: String?, sshHost: String?, daemonHost: String?) -> String {
        let source = trimmedNonEmpty(name) ?? trimmedNonEmpty(sshHost) ?? trimmedNonEmpty(daemonHost) ?? "remote-device"
        var scalars: [UnicodeScalar] = []
        var lastWasSeparator = false
        for scalar in source.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                scalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                scalars.append("-")
                lastWasSeparator = true
            }
        }
        let slug = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "remote-device" : slug
    }

    private static func terminalSessionIsRunning(sessionID: String) -> Bool {
        guard let paths = try? TerminalSessionPaths.forSession(id: sessionID),
            let state = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
        else { return true }
        return state.state.isInteractive
    }

    private func runTerminalRuntime(_ descriptor: TerminalRuntimeControlDescriptor) {
        if let device = deviceForDaemonStateMutation() {
            performDeviceTerminalRuntimeMutation(metric: "terminal_runtime_run", descriptor: descriptor, device: device) { device in
                switch descriptor.kind {
                case .process:
                    guard let processKey = descriptor.processKey else {
                        throw WorkspaceError.invalidArgument(message: "Configured process not found.")
                    }
                    return try SpacesDeviceClient.runWorkspaceProcess(
                        workspaceID: descriptor.workspaceID, processKey: processKey, processTemplateID: descriptor.processTemplateID, device: device,
                        clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                case .codingAgent:
                    guard let agentName = descriptor.agentLauncherName else {
                        throw WorkspaceError.invalidArgument(message: "Configured coding agent not found.")
                    }
                    return try SpacesDeviceClient.runCodingAgent(
                        workspaceID: descriptor.workspaceID, agentName: agentName, agentLauncherID: descriptor.agentLauncherID, device: device,
                        clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                case .workspaceTerminal: throw WorkspaceError.invalidArgument(message: "Workspace terminals do not support Run.")
                }
            }
            return
        }
        showDeviceNotLoadedError()
    }

    private func stopTerminalRuntime(_ descriptor: TerminalRuntimeControlDescriptor) {
        if let device = deviceForDaemonStateMutation() {
            performDeviceTerminalRuntimeMutation(metric: "terminal_runtime_stop", descriptor: descriptor, device: device) { device in
                switch descriptor.kind {
                case .process:
                    return try SpacesDeviceClient.stopWorkspaceProcess(
                        workspaceID: descriptor.workspaceID, processID: descriptor.processID, processKey: descriptor.processKey,
                        processTemplateID: descriptor.processTemplateID, device: device,
                        clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                case .codingAgent:
                    return try SpacesDeviceClient.stopCodingAgent(
                        workspaceID: descriptor.workspaceID, agentID: descriptor.agentID, agentName: descriptor.agentLauncherName,
                        agentLauncherID: descriptor.agentLauncherID, device: device,
                        clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                case .workspaceTerminal:
                    return try SpacesDeviceClient.stopWorkspaceTerminal(
                        workspaceID: descriptor.workspaceID, sessionID: descriptor.sessionID, device: device,
                        clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                }
            }
            return
        }
        showDeviceNotLoadedError()
    }

    private func restartTerminalRuntime(_ descriptor: TerminalRuntimeControlDescriptor) {
        if let device = deviceForDaemonStateMutation() {
            performDeviceTerminalRuntimeMutation(metric: "terminal_runtime_restart", descriptor: descriptor, device: device) { device in
                switch descriptor.kind {
                case .process:
                    return try SpacesDeviceClient.restartWorkspaceProcess(
                        workspaceID: descriptor.workspaceID, processID: descriptor.processID, processKey: descriptor.processKey,
                        processTemplateID: descriptor.processTemplateID, device: device,
                        clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                case .codingAgent:
                    return try SpacesDeviceClient.restartCodingAgent(
                        workspaceID: descriptor.workspaceID, agentID: descriptor.agentID, agentName: descriptor.agentLauncherName,
                        agentLauncherID: descriptor.agentLauncherID, device: device,
                        clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                case .workspaceTerminal: throw WorkspaceError.invalidArgument(message: "Workspace terminals do not support Restart.")
                }
            }
            return
        }
        showDeviceNotLoadedError()
    }

    private func performDeviceTerminalRuntimeMutation(
        metric: String, descriptor: TerminalRuntimeControlDescriptor, device: SpacesPairedDeviceRecord,
        operation: @Sendable @escaping (SpacesPairedDeviceRecord) throws -> SpacesDeviceAPIResponse
    ) {
        let startedAt = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Self.deviceMutation(device: device, operation: operation)
            switch result {
            case .success(let response):
                logPerfMetric(
                    metric, target: "workspace=\(descriptor.workspaceID) session=\(descriptor.sessionID)",
                    elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true, detail: "kind=\(descriptor.kind)")
                applyDeviceMutationResponse(response, selectedWorkspaceID: descriptor.workspaceID)
                refreshTerminalRuntimeControls(sessionID: descriptor.sessionID, cause: metric)
            case .failure(let error):
                logPerfMetric(
                    metric, target: "workspace=\(descriptor.workspaceID) session=\(descriptor.sessionID)",
                    elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false, detail: "kind=\(descriptor.kind)")
                showError(error)
            }
        }
    }

    /// Whether an ad hoc built-in terminal session left without a client should stop.
    /// Liveness comes from the device overview's attachment snapshot, not the
    /// daemon database; `hasLiveAttachments` should be `true` when liveness is
    /// unknown so a session is never stopped out from under another client.
    nonisolated static func shouldTerminateAdHocBuiltInTerminalSession(
        hasLiveAttachments: Bool, isConfiguredProcessSession: Bool, isAppTerminatingAndKeepingSessions: Bool = false
    ) -> Bool {
        guard !isAppTerminatingAndKeepingSessions else { return false }
        guard !isConfiguredProcessSession else { return false }
        return !hasLiveAttachments
    }

    private func terminateUnattachedAdHocBuiltInTerminalSessionIfNeeded(sessionID: String) {
        guard !keepsTerminalSessionsRunningDuringTermination else { return }
        // A session owned by a configured process or agent is not ad hoc; the overview's
        // session kind tells us without a daemon-DB read.
        guard remoteTerminalSessionKind(sessionID: sessionID) == .shell else { return }
        guard let device = terminalSessionOwningDevice(sessionID: sessionID) else { return }
        let clientApp = SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)
        Task { @MainActor [weak self] in
            guard let self else { return }
            // The loaded overview may not yet reflect the detach/expiry that triggered this
            // cleanup, so decide on the authoritative attachment snapshot fetched from the
            // owning device. A device that does not answer leaves the session untouched.
            guard let fetched = await Self.fetchSessionAttachmentSnapshot(sessionID: sessionID, device: device, clientApp: clientApp) else { return }
            // A remote viewer can stop refreshing its lease without ever sending a detach,
            // leaving its attachment row with detachedAt == nil. Judge liveness with the
            // lease rule — against the daemon's own clock — so an expired viewer does not keep
            // an otherwise-unattached ad hoc session alive, and clock skew does not expire a
            // live one.
            let hasLiveAttachments = !fetched.snapshot.liveAttachments(now: fetched.daemonNow).isEmpty
            guard
                Self.shouldTerminateAdHocBuiltInTerminalSession(
                    hasLiveAttachments: hasLiveAttachments, isConfiguredProcessSession: false,
                    isAppTerminatingAndKeepingSessions: self.keepsTerminalSessionsRunningDuringTermination)
            else { return }
            self.stopAdHocTerminalSession(sessionID: sessionID)
        }
    }

    /// Fetches the authoritative attachment snapshot for a session from its owning device,
    /// along with the daemon's emission time. The snapshot's lease timestamps are stamped by
    /// that daemon, so liveness must be judged against `daemonNow` rather than this Mac's
    /// clock — a remote device's clock can skew past the 60s lease interval.
    nonisolated private static func fetchSessionAttachmentSnapshot(
        sessionID: String, device: SpacesPairedDeviceRecord, clientApp: SpacesDeviceClientApp
    ) async -> (snapshot: TerminalSessionAttachmentSnapshot, daemonNow: Date)? {
        await Task.detached(priority: .utility) {
            let response = try? SpacesDeviceClient.request(
                SpacesDeviceAPIRequest(command: .state(SpacesDeviceTerminalSessionRequest(sessionID: sessionID))), device: device,
                clientApp: clientApp)
            guard let state = response?.sessionState, let snapshot = state.attachmentSnapshot else { return nil }
            return (snapshot, GhosttyRemoteSessionStateTimestamp.date(from: state.emittedAt) ?? Date())
        }.value
    }

    /// Stops an ad hoc built-in terminal session through the owning daemon's Device API.
    private func stopAdHocTerminalSession(sessionID: String) {
        guard let workspaceID = clientWorkspaceID(forTerminalSession: sessionID), let device = deviceForWorkspaceMutation(workspaceID: workspaceID)
        else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Self.deviceMutation(device: device) { device in
                try SpacesDeviceClient.stopWorkspaceTerminal(
                    workspaceID: workspaceID, sessionID: sessionID, device: device,
                    clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
            }
            if case .success = result { self.requestSidebarReload() }
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

    private func setupTerminalAttachmentStateObserver() {
        terminalAttachmentStateDidChangeObserver = NotificationCenter.default.addObserver(
            forName: .spacesTerminalAttachmentStateDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            let changedSessionID = notification.userInfo?["sessionID"] as? String
            MainActor.assumeIsolated {
                guard let self, let changedSessionID else { return }
                self.handleTerminalAttachmentStateDidChange(sessionID: changedSessionID)
            }
        }
    }

    private func handleTerminalAttachmentStateDidChange(sessionID: String) {
        // A session with an open pane keeps its own client attached; only sessions
        // without one are candidates for unattached ad hoc cleanup.
        guard panelCoordinator.content(forSessionID: sessionID) == nil else { return }
        terminateUnattachedAdHocBuiltInTerminalSessionIfNeeded(sessionID: sessionID)
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

    func canReloadAfterBackgroundWorkspaceRefresh() -> Bool {
        !projectHasUnsavedChanges && activeAddWorkspaceFormTag == nil && activeAddProjectFormTag == nil && !isTextInputFocused()
    }

    private enum AddWorkspaceBranchMode: String {
        case existing
        case create
    }

    private struct WorkspaceCreateInput: Sendable {
        let projectID: String
        let branch: String?
        let baseBranch: String?
        let notes: String?
        let allowRemoteBranchLookup: Bool
        let allowExistingBranchReuse: Bool
        let replaceExistingManagedDirectory: Bool
    }

    struct SidebarDataSnapshot: Sendable {
        let config: AppConfig
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

    enum SidebarDeviceLoadState: Sendable, Equatable {
        case loading
        case offline(String)
        case loaded

        var isOffline: Bool {
            if case .offline = self { return true }
            return false
        }
    }

    /// The sidebar groups projects under per-device header rows when more than one device is paired, or
    /// when any section is offline so its "offline" caption (the only surface for an unreachable daemon's
    /// reason) still has a header row to render in. A single loaded device stays a flat project list.
    /// Pure so the single-offline-device rule is directly testable.
    nonisolated static func sidebarShowsDeviceHeaders(deviceCount: Int, hasOfflineSection: Bool) -> Bool { deviceCount > 1 || hasOfflineSection }

    /// Maps the local device's snapshot reachability to a sidebar load state. A non-nil offline message
    /// (the local daemon could not be reached) renders the local device as offline, exactly like a remote
    /// device that fails to load; otherwise the device is loaded. Keeping this pure makes the
    /// parity-with-remote contract directly testable.
    nonisolated static func localDeviceLoadState(offlineMessage: String?) -> SidebarDeviceLoadState { offlineMessage.map { .offline($0) } ?? .loaded }

    /// One paired device's slice of the sidebar. The sidebar shows every paired
    /// device at once; each section loads independently so a slow or unreachable
    /// device does not block the others.
    struct DeviceSection: Sendable {
        let deviceID: String
        let deviceName: String
        let isLocal: Bool
        var loadState: SidebarDeviceLoadState
        var device: SpacesPairedDeviceRecord?
        var projects: [ProjectSummary] = []
        var workspacesByProject: [String: [WorkspaceSummary]] = [:]
        var workspaceRuntimeStatusByID: [String: WorkspaceRuntimeStatus] = [:]
        var alertsGroups: [AlertsGroup] = []
        var overview: SpacesDeviceOverviewPayload?
        /// Frozen-core handshake read for this device, refreshed alongside the overview. `nil` until
        /// the first successful handshake; drives the per-device compatibility banner and gating.
        var daemonStatus: TerminalServiceDaemonStatus?
        var compatibility: SpacesWireCompatibility?
    }

    /// Whether the current sidebar selection points at a workspace or project owned by `section`. Used
    /// when a device transitions to offline: its rows are about to drop out of the merged sidebar data,
    /// so a selection under it leaves a stale detail pane that must be reconciled. A selected workspace's
    /// project is always under the same device, so the workspace check alone suffices when one is selected.
    nonisolated static func sidebarSelectionBelongsToDeviceSection(selectedWorkspaceID: String?, selectedProjectID: String?, section: DeviceSection)
        -> Bool
    {
        if let selectedWorkspaceID { return section.workspacesByProject.values.contains { $0.contains { $0.id == selectedWorkspaceID } } }
        if let selectedProjectID { return section.projects.contains { $0.id == selectedProjectID } }
        return false
    }

    enum BackgroundRefreshFailureAction: Equatable {
        case deferredSetup
        case logOnly
    }

    /// Holds a click closure and serves as the NSGestureRecognizer target for clickable row views.
    @MainActor private final class ClickTarget: NSObject {
        let action: () async -> Void
        init(_ action: @escaping () async -> Void) { self.action = action }
        @objc func clicked(_ sender: NSGestureRecognizer) { Task { await self.action() } }
    }

    private static var clickTargetAssocKey: UInt8 = 0

    @MainActor static func terminalSessionHost(
        launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths,
        terminalServiceRequestSender: RemoteGhosttyTerminalServiceRequestSender? = nil,
        stateStreamSubscriber: RemoteGhosttyStateStreamSubscriber? = nil, agentSignalHandler: RemoteGhosttyAgentSignalHandler? = nil
    ) -> any TerminalGhosttySessionHosting {
        RemoteGhosttySessionHost(
            launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: terminalServiceRequestSender,
            stateStreamSubscriber: stateStreamSubscriber, agentSignalHandler: agentSignalHandler)
    }

    nonisolated static func launchServiceBuiltInTerminalSession(_ launchConfiguration: TerminalSessionLaunchConfiguration) throws
        -> TerminalServiceSessionSummary
    { try appBuiltInTerminalSessionLauncher()(launchConfiguration) }

    nonisolated static func appBuiltInTerminalSessionLauncher(
        createSession: @escaping @Sendable (TerminalSessionLaunchConfiguration) throws -> TerminalServiceSessionSummary = {
            try TerminalService.createSession($0)
        }
    ) -> WorkspaceOrchestrator.BuiltInTerminalSessionLauncher { { launchConfiguration in try createSession(launchConfiguration) } }

    nonisolated static func terminateBuiltInTerminalSession(sessionID: String) {
        try? performBuiltInTerminalSessionWorkOnMainThread {
            (NSApp.delegate as? AppKitController)?.closeTerminalSessionPane(sessionID: sessionID, sessionIsTerminating: true)
            try? TerminalService.terminateSession(id: sessionID)
        }
    }

    nonisolated static func performBuiltInTerminalSessionWorkOnMainThread<T: Sendable>(
        isMainThread: Bool = Thread.isMainThread,
        scheduler: @escaping (@escaping @Sendable () -> Void) -> Void = { action in DispatchQueue.main.async(execute: action) },
        work: @escaping @MainActor () throws -> T
    ) throws -> T {
        if isMainThread { return try MainActor.assumeIsolated { try work() } }

        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = MainThreadResultBox<T>()
        scheduler {
            resultBox.set(Result { try MainActor.assumeIsolated { try work() } })
            semaphore.signal()
        }
        semaphore.wait()
        guard let result = resultBox.get() else {
            throw WorkspaceError.invalidArgument(message: "Built-in terminal main-thread work did not return a result.")
        }
        return try result.get()
    }

    nonisolated static func terminalQuitPolicy(liveTerminalSessionCount: Int) -> TerminalQuitPolicy {
        liveTerminalSessionCount > 0 ? .promptForLiveSessions(count: liveTerminalSessionCount) : .quitImmediately
    }

    nonisolated static func liveBuiltInTerminalSessions(listSessions: () throws -> [TerminalServiceSessionSummary] = TerminalService.listSessions)
        -> [TerminalServiceSessionSummary]
    { (try? listSessions()) ?? [] }

    @discardableResult nonisolated static func stopAllBuiltInTerminalSessions(
        liveSessions: [TerminalServiceSessionSummary], terminateSession: (String) throws -> Void = { try TerminalService.terminateSession(id: $0) }
    ) -> Int {
        var stoppedCount = 0
        for session in liveSessions {
            do {
                try terminateSession(session.id)
                stoppedCount += 1
            } catch { fputs("spaces: failed to stop terminal session \(session.id): \(error)\n", stderr) }
        }
        return stoppedCount
    }

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

    private func recordStartupInteraction(kind: String) {
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

    static func alertsIconColor(_ tint: AlertsIconTint) -> NSColor {
        switch tint {
        case .browser: .systemBlue
        case .terminal: .systemGreen
        case .code: .systemPurple
        case .success: .systemGreen
        case .warning: .systemOrange
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

    nonisolated private static func deviceWorkspaceCreateOptions(projectID: String, device: SpacesPairedDeviceRecord) async -> Result<
        SpacesDeviceWorkspaceCreateOptions, Error
    > {
        await Task.detached(priority: .userInitiated) {
            do {
                return .success(
                    try SpacesDeviceClient.workspaceCreateOptions(
                        selectedProjectID: projectID, device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func deviceProjectPreview(dir: String, device: SpacesPairedDeviceRecord) async -> Result<
        SpacesDeviceProjectPreview, Error
    > {
        await Task.detached(priority: .userInitiated) {
            do {
                return .success(
                    try SpacesDeviceClient.previewProject(
                        dir: dir, device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func deviceDirectorySuggestions(path: String, device: SpacesPairedDeviceRecord) async -> [String] {
        await Task.detached(priority: .userInitiated) {
            (try? SpacesDeviceClient.listDirectories(
                path: path, device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))) ?? []
        }.value
    }

    /// Clones a git repository on the target device and returns its detected spaces.yaml config plus
    /// an opaque handle to the clone. Routed through the Device API so the preview works on the
    /// device that will own the project (local or remote), not always locally.
    nonisolated private static func prepareGitProjectResult(gitURL: String, replaceExistingManagedDirectories: Bool, device: SpacesPairedDeviceRecord)
        async -> Result<SpacesDeviceGitProjectPreparation, Error>
    {
        await Task.detached(priority: .userInitiated) {
            do {
                return .success(
                    try SpacesDeviceClient.prepareGitProject(
                        gitURL: gitURL, replaceExistingManagedDirectories: replaceExistingManagedDirectories, device: device,
                        clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func discardPreparedGitProjectResult(preparedGitProjectHandle: String, device: SpacesPairedDeviceRecord) async
        -> Result<Void, Error>
    {
        await Task.detached(priority: .utility) {
            do {
                _ = try SpacesDeviceClient.discardPreparedGitProject(
                    preparedGitProjectHandle: preparedGitProjectHandle, device: device,
                    clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                return .success(())
            } catch { return .failure(error) }
        }.value
    }

    // Browser rows stay visible even when the workspace is stopped so the Run tab
    // remains a stable launch surface for configured browser sessions.
    nonisolated static func shouldShowConfiguredBrowserSessions(workspaceIsRunning _: Bool) -> Bool { true }

    nonisolated static func shouldShowWorkspaceSetupPanel(status: WorkspaceSetupStatus) -> Bool { status != .succeeded }

    nonisolated static func shouldShowWorkspaceSetupScriptEditor(status: WorkspaceSetupStatus) -> Bool { status == .failed }

    nonisolated static func shouldRequestNormalWorkspaceDetailRefresh(setupStatus: WorkspaceSetupStatus) -> Bool { setupStatus == .succeeded }

    /// Builds attention alerts for a device from its overview payload — used for both the local and
    /// remote devices so alerts aggregate identically across the sidebar without the client ever
    /// opening `spaces.db`. Window-role styling (browser/editor icons, per-window focus) is
    /// intentionally absent: desktop windows are client-local and not part of the daemon overview,
    /// so an exited process shows as a process alert and clicking it focuses the process. Recency
    /// (and dismissal identity) come from the daemon-supplied `exitedAt`/`updatedAt` timestamps.
    nonisolated static func buildOverviewAlertsGroups(from overview: SpacesDeviceOverviewPayload, deviceID: String) -> [AlertsGroup] {
        let iso8601Formatter = ISO8601DateFormatter()
        var groups: [AlertsGroup] = []
        for workspace in overview.workspaces where !workspace.isArchived {
            var items: [AlertsAttentionEntry] = []
            if workspace.isRunning {
                for process in workspace.processRows where process.runState == .exited {
                    let eventDate = process.exitedAt.flatMap { iso8601Formatter.date(from: $0) }
                    items.append(
                        AlertsAttentionEntry(
                            attentionID: "alert:\(deviceID):process:\(process.processID ?? process.id):\(process.exitedAt ?? "unknown")",
                            icon: "terminal", iconTint: .terminal, label: process.name, detail: process.command, shortcut: "", processStatus: .exited,
                            agentStatus: nil, countsTowardBadge: true, eventDate: eventDate,
                            focusRequest: process.processID.map { .workspaceProcess(workspaceID: workspace.id, processID: $0) }))
                }
            }
            for agent in workspace.codingAgentRows where agent.activityState == .waiting || agent.activityState == .done {
                let eventDate = agent.updatedAt.flatMap { iso8601Formatter.date(from: $0) }
                items.append(
                    AlertsAttentionEntry(
                        attentionID: "alert:\(deviceID):agent:\(agent.agentID ?? agent.id):\(agent.activityState.rawValue):\(agent.updatedAt ?? "")",
                        icon: "cpu.fill", iconTint: .warning, label: agent.name, detail: nil, shortcut: "", processStatus: nil,
                        agentStatus: AgentWindowStatus(rawValue: agent.activityState.rawValue), countsTowardBadge: true, eventDate: eventDate,
                        // The alert is for an existing waiting/done agent, so activating it must focus that
                        // agent's session — not `.workspaceAgentLauncher`, which resolves to a fresh launch and
                        // would start a second agent. Mirror `agentWindows(from:)` so the `.agentWindow`
                        // resolution finds the row by `agentID`/`id` and opens its session.
                        focusRequest: .agentWindow(
                            AgentWindowRecord(
                                id: agent.agentID ?? agent.id, workspaceID: workspace.id, provider: .spaces, label: agent.name,
                                terminalTarget: agent.sessionID.map { TerminalTargetRecord(trackingID: $0) }, claimedLauncherID: agent.launcherID,
                                claimedLauncherName: agent.name, status: agentStatus(from: agent.activityState), createdAt: agent.updatedAt ?? "",
                                updatedAt: agent.updatedAt ?? ""))))
            }
            guard !items.isEmpty else { continue }
            items.sort {
                switch ($0.eventDate, $1.eventDate) {
                case (let a?, let b?): return a > b
                case (nil, _): return false
                case (_, nil): return true
                }
            }
            groups.append(
                AlertsGroup(
                    projectName: workspace.projectName, workspaceID: workspace.id, workspaceName: workspace.displayName,
                    workspaceBranch: workspace.branch, items: items))
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

    nonisolated static func initialSidebarDataSnapshot() async -> Result<SidebarDataSnapshot, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let snapshotStartedAt = ProcessInfo.processInfo.systemUptime
                let config = try clientAppConfig()
                logStartupSnapshotProfile("sidebar_snapshot_config_ready")
                // The sidebar shows every paired device at once; the initial snapshot
                // always loads the local device first, then remote sections stream in
                // independently (see loadRemoteDeviceSections).
                let deviceClientApp = SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)
                let database = try SpacesClientDatabase.defaultDatabase()
                // The local daemon being unreachable is an offline state, not a snapshot failure: degrade to
                // an empty overview tagged with the reason so the sidebar shows "This Mac" offline the same
                // way remote devices do, while the rest of the snapshot (config and the paired-device record,
                // both read from the local database) still loads. This covers both failure points — the
                // bootstrap call (the daemon never came up) and the overview round-trip (the daemon answered
                // but its overview failed). A bootstrap failure falls back to the last stored local device
                // record so "This Mac" still has an identity to render; with no stored record (a first launch
                // while the daemon is down) there is no device to show, so it stays a genuine snapshot failure.
                // Only reachability failures degrade to offline: a bootstrap that reaches the daemon but then
                // fails writing the paired-device record or saving Keychain credentials is a real error, not
                // an offline state, so it must surface rather than be hidden behind an empty offline sidebar.
                let localDevice: SpacesPairedDeviceRecord
                let bootstrapOfflineMessage: String?
                do {
                    localDevice = try SpacesDeviceClient.bootstrapLocalDevice(database: database, clientApp: deviceClientApp)
                    bootstrapOfflineMessage = nil
                } catch {
                    guard SpacesDeviceClient.isLocalDaemonUnreachableError(error),
                        let storedLocalDevice = try? database.pairedDevice(id: SpacesPairedDeviceRecord.localDeviceID)
                    else { throw error }
                    localDevice = storedLocalDevice
                    bootstrapOfflineMessage = error.localizedDescription
                }
                // Read compatibility from the overview's inline frozen-core status: the compatible steady
                // state costs a single round-trip, and only an incompatible/too-old daemon falls back to the
                // standalone handshake (which stays decodable when the overview would not), so the local
                // device can show the restart/update block instead of a generic load error.
                let localDaemonStatus: TerminalServiceDaemonStatus?
                let localCompatibility: SpacesWireCompatibility?
                let localOverview: SpacesDeviceOverviewPayload
                let localOfflineMessage: String?
                if let bootstrapOfflineMessage {
                    // Bootstrap already failed; skip the overview round-trip (it would only fail too) and
                    // render offline directly from the stored device record.
                    localDaemonStatus = nil
                    localCompatibility = nil
                    localOverview = SpacesDeviceOverviewPayload(workspaces: [], sessions: [])
                    localOfflineMessage = bootstrapOfflineMessage
                } else {
                    do {
                        let localResolution = try SpacesDeviceClient.resolveOverview(device: localDevice, clientApp: deviceClientApp)
                        localDaemonStatus = localResolution.daemonStatus
                        localCompatibility = localResolution.compatibility
                        // A blocked (incompatible) device has no decodable overview to show; render the block
                        // from an empty snapshot instead.
                        localOverview = localResolution.overview?.overview ?? SpacesDeviceOverviewPayload(workspaces: [], sessions: [])
                        localOfflineMessage = nil
                    } catch {
                        // Only a reachability failure degrades to offline. An error from a reachable daemon
                        // (a database/migration failure, an authorization rejection, a malformed overview)
                        // must surface through the snapshot's failure path, not be hidden behind the offline
                        // sidebar/restart flow.
                        guard SpacesDeviceClient.isLocalDaemonUnreachableError(error) else { throw error }
                        localDaemonStatus = nil
                        localCompatibility = nil
                        localOverview = SpacesDeviceOverviewPayload(workspaces: [], sessions: [])
                        localOfflineMessage = error.localizedDescription
                    }
                }
                let collapseStates = (try? database.projectCollapseStates(deviceID: localDevice.id)) ?? [:]
                let mapped = deviceSidebarData(from: localOverview, deviceID: localDevice.id, projectCollapseStates: collapseStates)
                let workspaceCount = mapped.workspacesByProject.values.reduce(0) { $0 + $1.count }
                logStartupSnapshotProfile(
                    "sidebar_snapshot_local_device_ready",
                    details: "device=\(localDevice.name) project_count=\(mapped.projects.count) workspace_count=\(workspaceCount)")
                let alertsGroups = buildOverviewAlertsGroups(from: localOverview, deviceID: localDevice.id)
                logStartupSnapshotProfile(
                    "sidebar_snapshot_alerts_ready",
                    details: "group_count=\(alertsGroups.count) item_count=\(alertsGroups.reduce(0) { $0 + $1.items.count })")
                logStartupSnapshotProfile(
                    "sidebar_snapshot_complete", details: "total_ms=\(Int((ProcessInfo.processInfo.systemUptime - snapshotStartedAt) * 1000))")
                return .success(
                    .init(
                        config: config, projects: mapped.projects, workspacesByProject: mapped.workspacesByProject,
                        workspaceRuntimeStatusByID: mapped.workspaceRuntimeStatusByID, alertsGroups: alertsGroups, localDeviceID: localDevice.id,
                        localDeviceName: localDevice.name, localPairedDevice: localDevice, localDeviceOverview: localOverview,
                        localDaemonStatus: localDaemonStatus, localCompatibility: localCompatibility, localOfflineMessage: localOfflineMessage))
            } catch { return .failure(error) }
        }.value
    }

    nonisolated static func deviceSidebarData(
        from overview: SpacesDeviceOverviewPayload, deviceID: String, projectCollapseStates: [String: Bool] = [:]
    ) -> (projects: [ProjectSummary], workspacesByProject: [String: [WorkspaceSummary]], workspaceRuntimeStatusByID: [String: WorkspaceRuntimeStatus])
    {
        let model = SpacesDeviceOverviewViewModel(overview: overview)
        let projects = model.projects.map {
            ProjectSummary(
                id: $0.id, name: $0.name, dir: $0.dir, isGitRepo: $0.isGitRepo, defaultBranch: $0.defaultBranch,
                isCollapsed: projectCollapseStates[$0.id] ?? false, deviceID: deviceID)
        }
        let workspacesByProject = model.workspacesByProject.mapValues { workspaces in
            workspaces.map {
                WorkspaceSummary(
                    id: $0.id, branch: $0.branch, baseBranch: $0.baseBranch, dir: $0.dir, isRunning: $0.isRunning, isArchived: $0.isArchived,
                    isHidden: $0.isHidden, isDefault: $0.isDefault, notes: $0.notes, deviceID: deviceID)
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

    nonisolated private static func localServiceDefinition(from port: SpacesDeviceServiceDefinition) -> ServiceDefinition {
        ServiceDefinition(id: port.id, name: port.name)
    }

    nonisolated private static func deviceServiceDefinition(from port: ServiceDefinition) -> SpacesDeviceServiceDefinition {
        SpacesDeviceServiceDefinition(id: port.id, name: port.name)
    }

    nonisolated private static func localProcessTemplate(from process: SpacesDeviceProcessTemplate) -> ProcessTemplate {
        ProcessTemplate(
            id: process.id, name: process.name, command: process.command, kind: process.kind,
            onExit: ProcessExitAction(rawValue: process.onExit) ?? .none)
    }

    nonisolated private static func deviceProcessTemplate(from process: ProcessTemplate) -> SpacesDeviceProcessTemplate {
        SpacesDeviceProcessTemplate(id: process.id, name: process.name, command: process.command, kind: process.kind, onExit: process.onExit.rawValue)
    }

    nonisolated static func localBrowserSession(from session: SpacesDeviceBrowserSession) -> BrowserSession {
        BrowserSession(name: session.name, url: session.url)
    }

    nonisolated private static func deviceBrowserSession(from session: BrowserSession) -> SpacesDeviceBrowserSession {
        SpacesDeviceBrowserSession(name: session.name, url: session.url)
    }

    nonisolated private static func localAgentLauncher(from launcher: SpacesDeviceAgentLauncher) -> AgentLauncher {
        AgentLauncher(id: launcher.id, name: launcher.name, command: launcher.command)
    }

    nonisolated private static func deviceAgentLauncher(from launcher: AgentLauncher) -> SpacesDeviceAgentLauncher {
        SpacesDeviceAgentLauncher(id: launcher.id, name: launcher.name, command: launcher.command)
    }

    nonisolated static func localWorkspaceSettings(from config: SpacesDeviceWorkspaceConfig) -> WorkspaceSettings {
        WorkspaceSettings(
            stopScript: config.stopScript, ports: config.ports.map(localServiceDefinition(from:)),
            processes: config.processes.map(localProcessTemplate(from:)), browserSessions: config.browserSessions.map(localBrowserSession(from:)),
            agentLaunchers: config.agentLaunchers.map(localAgentLauncher(from:)))
    }

    nonisolated private static func deviceWorkspaceConfig(
        from settings: WorkspaceSettings, resolvedBrowserSessions: [SpacesDeviceBrowserSession] = []
    ) -> SpacesDeviceWorkspaceConfig {
        SpacesDeviceWorkspaceConfig(
            stopScript: settings.stopScript, ports: settings.ports.map(deviceServiceDefinition(from:)),
            processes: settings.processes.map(deviceProcessTemplate(from:)),
            browserSessions: settings.browserSessions.map(deviceBrowserSession(from:)), resolvedBrowserSessions: resolvedBrowserSessions,
            agentLaunchers: settings.agentLaunchers.map(deviceAgentLauncher(from:)))
    }

    nonisolated private static func localProjectSettings(from config: SpacesDeviceProjectConfig) -> (
        setupScript: String?, stopScript: String?, ports: [ServiceDefinition], processes: [ProcessTemplate], browserSessions: [BrowserSession],
        agentLaunchers: [AgentLauncher]
    ) {
        (
            setupScript: config.setupScript, stopScript: config.stopScript, ports: config.ports.map(localServiceDefinition(from:)),
            processes: config.processes.map(localProcessTemplate(from:)), browserSessions: config.browserSessions.map(localBrowserSession(from:)),
            agentLaunchers: config.agentLaunchers.map(localAgentLauncher(from:))
        )
    }

    private static func deviceProjectConfig(from refs: ProjectFieldRefs) -> SpacesDeviceProjectConfig {
        SpacesDeviceProjectConfig(
            setupScript: refs.setupScriptSection.currentValue.isEmpty ? nil : refs.setupScriptSection.currentValue,
            stopScript: refs.stopScriptSection.currentValue.isEmpty ? nil : refs.stopScriptSection.currentValue,
            ports: refs.portsSection.currentPorts.map(deviceServiceDefinition(from:)),
            processes: refs.processesSection.currentProcesses.map(deviceProcessTemplate(from:)),
            browserSessions: refs.browserSessionsSection.currentSessions.map(deviceBrowserSession(from:)),
            agentLaunchers: refs.agentLaunchersSection.currentLaunchers.map(deviceAgentLauncher(from:)))
    }

    private static func deviceProjectConfig(from refs: AddProjectFieldRefs) -> SpacesDeviceProjectConfig {
        SpacesDeviceProjectConfig(
            setupScript: refs.setupScriptSection.currentValue.isEmpty ? nil : refs.setupScriptSection.currentValue,
            stopScript: refs.stopScriptSection.currentValue.isEmpty ? nil : refs.stopScriptSection.currentValue,
            ports: refs.portsSection.currentPorts.map(deviceServiceDefinition(from:)),
            processes: refs.processesSection.currentProcesses.map(deviceProcessTemplate(from:)),
            browserSessions: refs.browserSessionsSection.currentSessions.map(deviceBrowserSession(from:)),
            agentLaunchers: refs.agentLaunchersSection.currentLaunchers.map(deviceAgentLauncher(from:)))
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

    nonisolated private static func agentStatus(from state: SpacesDeviceCodingAgentActivityState) -> AgentWindowStatus {
        switch state {
        case .idle: return .idle
        case .spinning: return .spinning
        case .waiting: return .waiting
        case .done: return .done
        }
    }

    nonisolated private static func runningProcesses(from rows: [SpacesDeviceWorkspaceProcessRow]) -> [RunningProcessRecord] {
        rows.compactMap { row in
            guard row.runState != .notStarted || row.processID != nil || row.sessionID != nil else { return nil }
            return RunningProcessRecord(
                id: row.processID ?? row.id, workspaceID: row.workspaceID, templateID: row.templateID, templateName: row.name, command: row.command,
                runtimeTargetID: nil, terminalApp: nil, terminalTarget: row.sessionID.map { TerminalTargetRecord(trackingID: $0) }, pid: nil,
                status: runningState(from: row.runState), logPath: nil, lastOutputAt: nil, startedAt: nil, exitedAt: nil)
        }
    }

    nonisolated private static func agentWindows(from rows: [SpacesDeviceWorkspaceCodingAgentRow]) -> [AgentWindowRecord] {
        let now = ISO8601DateFormatter().string(from: Date())
        return rows.compactMap { row in
            guard row.agentID != nil || row.sessionID != nil || row.runState != .notStarted else { return nil }
            return AgentWindowRecord(
                id: row.agentID ?? row.id, workspaceID: row.workspaceID, provider: .spaces, label: row.name,
                terminalTarget: row.sessionID.map { TerminalTargetRecord(trackingID: $0) }, claimedLauncherID: row.launcherID,
                claimedLauncherName: row.name, status: agentStatus(from: row.activityState), createdAt: now, updatedAt: now)
        }
    }

    nonisolated static func deviceTerminalWindows(from rows: [SpacesDeviceWorkspaceTerminalRow]) -> [WindowRecord] {
        let now = ISO8601DateFormatter().string(from: Date())
        return rows.enumerated().map { index, row in
            WindowRecord(
                id: row.id, workspaceID: row.workspaceID, app: "Spaces", name: row.title, detail: row.workingDirectory, windowID: nil,
                terminalTrackingID: row.sessionID, role: "terminal", orderIndex: index, lastSeenAt: now)
        }
    }

    nonisolated static func shouldHideAfterSuccessfulExternalWindowAction(_ succeeded: Bool, action: ExternalWindowAction) -> Bool {
        guard succeeded else { return false }
        switch action {
        case .focus(let hidesApp), .open(let hidesApp): return hidesApp
        }
    }

    nonisolated static func hideDelayAfterSuccessfulExternalWindowAction(_ succeeded: Bool, action: ExternalWindowAction) -> Duration? {
        guard shouldHideAfterSuccessfulExternalWindowAction(succeeded, action: action) else { return nil }
        switch action {
        case .focus(_): return .milliseconds(400)
        case .open(_): return nil
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

    struct DeviceTerminalOpenRequest: Sendable, Equatable {
        let workspaceID: String
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

        init(
            workspaceID: String, sessionID: String, title: String, workingDirectory: String, kind: TerminalSessionKind, shell: String? = nil,
            command: String? = nil, initialState: TerminalSessionState? = nil, servicePID: Int32? = nil, childPID: Int32? = nil,
            createdAt: String? = nil, updatedAt: String? = nil
        ) {
            self.workspaceID = workspaceID
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
        case runCodingAgent(workspaceID: String, agentName: String, agentLauncherID: String?)
        case noWorkspace
        case noMatch
    }

    struct WorkspaceDetailShortcutIndices: Sendable {
        let browserSessionsByURL: [String: Int]
        let processesByName: [String: Int]
        let codingAgentsByName: [String: Int]
        let codingAgentsByIdentity: [String: Int]
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

    enum ProjectImportWorkspaceSyncDecision: Equatable, Sendable {
        case updateAllWorkspaces
        case projectOnly
        case cancel
    }

    enum ManagedDirectoryReplacementDecision: Equatable, Sendable {
        case replace
        case cancel
    }

    enum WorkspacePathAction: String, Sendable {
        case openEditor
        case revealInFinder

        var title: String {
            switch self {
            case .openEditor: "Open editor"
            case .revealInFinder: "Reveal in Finder"
            }
        }
    }

    nonisolated static func remoteWorkspacePathActionErrorMessage(action: WorkspacePathAction, deviceName: String) -> String {
        "\(action.title) requires a workspace path on this Mac. \(deviceName) workspaces live on the selected daemon; use an SSH-capable workflow for that remote path."
    }

    static func projectImportWorkspaceSyncDecision(for response: NSApplication.ModalResponse) -> ProjectImportWorkspaceSyncDecision {
        switch response {
        case .alertFirstButtonReturn: return .updateAllWorkspaces
        case .alertSecondButtonReturn: return .projectOnly
        default: return .cancel
        }
    }

    static func managedDirectoryReplacementDecision(for response: NSApplication.ModalResponse) -> ManagedDirectoryReplacementDecision {
        response == .alertFirstButtonReturn ? .replace : .cancel
    }

    static func shouldStartManagedDirectoryReplacementFlow(candidateCount: Int, decision: ManagedDirectoryReplacementDecision) -> Bool {
        candidateCount == 0 || decision == .replace
    }

    @discardableResult static func applyProjectImportWorkspaceSyncDecision(_ decision: ProjectImportWorkspaceSyncDecision, to refs: ProjectFieldRefs)
        -> Bool
    {
        switch decision {
        case .updateAllWorkspaces:
            refs.pendingImportUpdateAllWorkspaces = true
            return true
        case .projectOnly:
            refs.pendingImportUpdateAllWorkspaces = false
            return true
        case .cancel: return false
        }
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

    nonisolated static func resolvedCodingAgentRunEntries(configuredAgentLaunchers: [AgentLauncher], agentWindows: [AgentWindowRecord])
        -> [ResolvedCodingAgentRunEntry]
    {
        let configuredAgentNames = Set(configuredAgentLaunchers.map(\.name).map(normalizedRunRowName).filter { !$0.isEmpty })
        let configuredAgentIDs = Set(configuredAgentLaunchers.map(\.id).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        var entries: [ResolvedCodingAgentRunEntry] = []

        // Configured coding agents always own the first slots in the Coding Agents
        // section. If a live agent matches one of those names, the slot resolves to
        // that agent; otherwise the slot stays launchable from the config row.
        for launcher in configuredAgentLaunchers {
            let normalizedName = normalizedRunRowName(launcher.name)
            guard !normalizedName.isEmpty else { continue }
            let matchedAgent = agentWindows.first(where: { agentWindow in
                if agentWindow.claimedLauncherID == launcher.id { return true }
                guard agentWindow.claimedLauncherID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return false }
                return normalizedRunRowName(agentWindow.label ?? "") == normalizedName
            })
            entries.append(ResolvedCodingAgentRunEntry(launcher: launcher, agentWindow: matchedAgent))
        }

        for agentWindow in agentWindows {
            if let claimedLauncherID = agentWindow.claimedLauncherID?.trimmingCharacters(in: .whitespacesAndNewlines), !claimedLauncherID.isEmpty {
                if configuredAgentIDs.contains(claimedLauncherID) { continue }
            } else {
                guard !configuredAgentNames.contains(normalizedRunRowName(agentWindow.label ?? "")) else { continue }
            }
            entries.append(ResolvedCodingAgentRunEntry(launcher: nil, agentWindow: agentWindow))
        }

        return entries
    }

    nonisolated static func codingAgentShortcutIdentity(launcherName: String) -> String { "launcher:\(normalizedRunRowName(launcherName))" }

    nonisolated static func codingAgentShortcutIdentity(agentWindowID: String) -> String { "agent:\(agentWindowID)" }

    nonisolated static func codingAgentDisplayName(label: String?, runtimeWindowTitle: String?) -> String {
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty { return label }
        if let runtimeWindowTitle = runtimeWindowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !runtimeWindowTitle.isEmpty {
            return "Coding Agent \(runtimeWindowTitle)"
        }
        return "Coding Agent"
    }

    nonisolated static func isAdHocCodingAgent(_ agentWindow: AgentWindowRecord) -> Bool {
        agentWindow.claimedLauncherID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
            && agentWindow.claimedLauncherName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

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

        for (windowIdx, window) in windows.enumerated() where window.role != "browser" {
            let windowProcesses: [RunningProcessRecord]
            if window.role == "terminal" {
                windowProcesses = window.terminalTrackingKey.flatMap { processesByTerminalID[$0] } ?? []
            } else {
                windowProcesses = []
            }
            let isAgentClaimedWindow = window.terminalTrackingKey.map(agentTerminalIDs.contains) ?? false
            let nonAgentWindowProcesses = windowProcesses.filter { process in !(process.terminalTrackingKey.map(agentTerminalIDs.contains) ?? false) }
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
    /// processes, ad hoc terminals, agents). Shared by the numbered shortcuts and window
    /// cycling so both rotate over the same list.
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
        return orderedWorkspaceRunShortcutTargets(
            browserSessions: browserSessions, processEntries: processEntries, processesByID: processesByID,
            configuredAgentLaunchers: settings.agentLaunchers, agentWindows: agentWindows)
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
        case .agentLauncher:
            guard let launcherName = target.launcherName else { return .noMatch }
            let launcherID = detail.config.agentLaunchers.first { normalizedRunRowName($0.name) == normalizedRunRowName(launcherName) }?.id
            return .runCodingAgent(workspaceID: workspaceID, agentName: launcherName, agentLauncherID: launcherID)
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
                workspaceID: session.workspaceID ?? fallbackWorkspaceID, sessionID: session.id, title: session.title,
                workingDirectory: session.workingDirectory, kind: terminalSessionKind(rowKind: session.rowKind), shell: session.shell,
                command: session.command, initialState: session.state, servicePID: session.servicePID, childPID: session.childPID,
                createdAt: session.createdAt, updatedAt: session.updatedAt)
        }
        guard let workspace = overview?.workspaces.first(where: { $0.id == fallbackWorkspaceID }),
            let row = workspace.terminalRows.first(where: { $0.sessionID == sessionID })
        else { return nil }
        return DeviceTerminalOpenRequest(
            workspaceID: fallbackWorkspaceID, sessionID: sessionID, title: row.title, workingDirectory: row.workingDirectory, kind: .shell)
    }

    nonisolated private static func terminalSessionKind(rowKind: SpacesDeviceTerminalSessionRowKind) -> TerminalSessionKind {
        switch rowKind {
        case .process: .process
        case .agent: .agent
        case .liveSession: .shell
        }
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
        var codingAgentsByIdentity: [String: Int] = [:]

        for (offset, target) in targets.enumerated() {
            let index = offset + 1
            guard index <= 10 else { break }
            switch target.kind {
            case .browser: if let targetURL = target.targetURL, !targetURL.isEmpty { browserSessionsByURL[targetURL] = index }
            case .process:
                if let processID = target.processID, let process = processesByID[processID] { processesByName[process.templateName] = index }
            case .missingConfiguredProcess: if let processKey = target.processKey, !processKey.isEmpty { processesByName[processKey] = index }
            case .agentLauncher:
                if let launcherName = target.launcherName, !launcherName.isEmpty {
                    codingAgentsByName[launcherName] = index
                    codingAgentsByIdentity[codingAgentShortcutIdentity(launcherName: launcherName)] = index
                }
            case .agent:
                if let agentWindow = target.agentWindow {
                    if let label = agentWindow.label, !label.isEmpty { codingAgentsByName[label] = index }
                    codingAgentsByIdentity[codingAgentShortcutIdentity(agentWindowID: agentWindow.id)] = index
                }
            case .window: break
            }
        }

        return WorkspaceDetailShortcutIndices(
            browserSessionsByURL: browserSessionsByURL, processesByName: processesByName, codingAgentsByName: codingAgentsByName,
            codingAgentsByIdentity: codingAgentsByIdentity)
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
    private func focusedTerminalPaneContentForMenuAction() -> TerminalPaneContentController? {
        panelCoordinator.contentOwning(responder: NSApp.keyWindow?.firstResponder)
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
        window.title = "Spaces"
        window.setAccessibilityIdentifier("spaces-main-window")
        window.backgroundColor = sidebarPanelBackgroundColor()
        window.titlebarAppearsTransparent = true
        refreshDesktopControlStatusUI()
        window.center()
        window.delegate = self
        presentWindowIfAllowed(window)
    }

    private func ensureMainWindowVisibleOnLaunch() {
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
    }

    private func makeLeftPane() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = sidebarPanelBackgroundColor().cgColor

        let topBarRow = sidebar.makeSidebarTopBarRow()
        topBarRow.translatesAutoresizingMaskIntoConstraints = false

        let sectionHeader = sidebarSectionHeader(
            title: "Projects",
            actions: [
                (symbol: "line.3.horizontal.decrease.circle", tooltip: "Filter workspaces", action: #selector(showWorkspaceVisibilityDialog)),
                (symbol: "plus", tooltip: "New project", action: #selector(addProject)),
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

        // The sidebar owns its own footer strip (the app-level Alerts entry), separate
        // from the right panel's workspace footer.
        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        let alertsRow = sidebar.makeAlertsSidebarRow()
        alertsRow.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(topBarRow)
        container.addSubview(sectionHeader)
        container.addSubview(scroll)
        container.addSubview(footerSeparator)
        container.addSubview(alertsRow)

        NSLayoutConstraint.activate([
            topBarRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            topBarRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            topBarRow.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),

            sectionHeader.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            sectionHeader.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            sectionHeader.topAnchor.constraint(equalTo: topBarRow.bottomAnchor, constant: 10),

            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sectionHeader.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: footerSeparator.topAnchor),

            footerSeparator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            alertsRow.topAnchor.constraint(equalTo: footerSeparator.bottomAnchor, constant: 2),
            alertsRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            alertsRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            alertsRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            alertsRow.heightAnchor.constraint(equalToConstant: 26),
        ])

        return container
    }

    nonisolated static func pairedDeviceHasRequiredCredentials(deviceID: String) -> Bool {
        let hasToken = (try? SpacesDeviceCredentialStore.hasToken(deviceID: deviceID)) ?? false
        let hasTransportKey = (try? SpacesDeviceCredentialStore.hasTransportKey(deviceID: deviceID)) ?? false
        return hasToken && hasTransportKey
    }

    @objc func alertsRowClicked() { alerts.showAlertsDetail() }

    // MARK: - Alerts forwarders
    // Thin pass-throughs that keep widely-used alerts entry points callable from
    // host and sidebar code. The implementations live on `alerts` (AlertsController).
    func alertsAttentionCount() -> Int { alerts.alertsAttentionCount() }
    func loadAlertsDismissedAttentionItemIDs() { alerts.loadAlertsDismissedAttentionItemIDs() }
    func pruneDismissedAlertsAttentionItemIDsIfNeeded() { alerts.pruneDismissedAlertsAttentionItemIDsIfNeeded() }
    func showAlertsDetail() { alerts.showAlertsDetail() }

    private func makeRightPane() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = sidebarPanelBackgroundColor().cgColor

        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.wantsLayer = true
        detailContainer.layer?.backgroundColor = sidebarPanelBackgroundColor().cgColor

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
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            footer.heightAnchor.constraint(equalToConstant: 26),
        ])
        showPlaceholder()
        return container
    }

    func reloadData(forceRemoteRefresh: Bool = false) { sidebar.requestSidebarReload(forceRemoteRefresh: forceRemoteRefresh) }

    // MARK: - Sidebar forwarders
    // Thin pass-throughs that keep widely-used sidebar entry points callable from
    // host code without rewiring dozens of call sites. The implementations live on
    // `sidebar` (SidebarController).
    func requestSidebarReload(failurePlaceholderMessage: String? = nil, forceRemoteRefresh: Bool = false) {
        sidebar.requestSidebarReload(failurePlaceholderMessage: failurePlaceholderMessage, forceRemoteRefresh: forceRemoteRefresh)
    }
    func findWorkspace(id: String) -> (ProjectSummary, WorkspaceSummary)? { sidebar.findWorkspace(id: id) }
    func deviceRecord(forDeviceID deviceID: String) -> SpacesPairedDeviceRecord? { sidebar.deviceRecord(forDeviceID: deviceID) }
    func deviceSection(id deviceID: String) -> DeviceSection? { sidebar.deviceSection(id: deviceID) }
    func visibleWorkspaces(projectID: String) -> [WorkspaceSummary] { sidebar.visibleWorkspaces(projectID: projectID) }
    func deviceProjects(deviceID: String) -> [ProjectSummary] { sidebar.deviceProjects(deviceID: deviceID) }
    func selectWorkspace(_ workspace: WorkspaceSummary) { sidebar.selectWorkspace(workspace) }
    func orderedSidebarWorkspaces() -> [WorkspaceSummary] { sidebar.orderedSidebarWorkspaces() }
    func navigateSidebarSelection(direction: Int) -> Bool { sidebar.navigateSidebarSelection(direction: direction) }
    func handleSidebarArrowNavigation(event: NSEvent) -> Bool { sidebar.handleSidebarArrowNavigation(event: event) }
    func toggleProjectExpanded(projectID: String) { sidebar.toggleProjectExpanded(projectID: projectID) }
    func canPreserveDetailPaneAfterSidebarReload() -> Bool { sidebar.canPreserveDetailPaneAfterSidebarReload() }
    func rebuildFlatSidebarData() { sidebar.rebuildFlatSidebarData() }
    func applySidebarProjectExpansionState() { sidebar.applySidebarProjectExpansionState() }
    func updateAlertsSidebarBadge() { sidebar.updateAlertsSidebarBadge() }
    func updateAlertsRowAppearance() { sidebar.updateAlertsRowAppearance() }
    func refreshSidebarSelectionRows(previousProjectID: String?, currentProjectID: String?, previousWorkspaceID: String?, currentWorkspaceID: String?)
    {
        sidebar.refreshSidebarSelectionRows(
            previousProjectID: previousProjectID, currentProjectID: currentProjectID, previousWorkspaceID: previousWorkspaceID,
            currentWorkspaceID: currentWorkspaceID)
    }
    func sidebarPanelBackgroundColor() -> NSColor { sidebar.sidebarPanelBackgroundColor() }
    func sidebarCardBackgroundColor(isArchived: Bool) -> NSColor { sidebar.sidebarCardBackgroundColor(isArchived: isArchived) }
    func sidebarSelectedCardBackgroundColor() -> NSColor { sidebar.sidebarSelectedCardBackgroundColor() }
    func sidebarCardBorderColor(isSelected: Bool) -> NSColor { sidebar.sidebarCardBorderColor(isSelected: isSelected) }
    func sidebarPrimaryTextColor(isSelected: Bool, isArchived: Bool) -> NSColor {
        sidebar.sidebarPrimaryTextColor(isSelected: isSelected, isArchived: isArchived)
    }
    func sidebarMetadataTextColor(isSelected: Bool) -> NSColor { sidebar.sidebarMetadataTextColor(isSelected: isSelected) }
    func sidebarRunningIndicatorColor() -> NSColor { sidebar.sidebarRunningIndicatorColor() }
    func sidebarFailedIndicatorColor() -> NSColor { sidebar.sidebarFailedIndicatorColor() }
    func sidebarIdleIndicatorColor() -> NSColor { sidebar.sidebarIdleIndicatorColor() }
    func sidebarThemeColor(light: (Int, Int, Int), dark: (Int, Int, Int), alpha: CGFloat = 1) -> NSColor {
        sidebar.sidebarThemeColor(light: light, dark: dark, alpha: alpha)
    }

    func startBackgroundServicesIfNeeded() {
        guard !didStartBackgroundServices else { return }
        didStartBackgroundServices = true
        sidebar.startRemoteOverviewSubscriptions()
    }

    private func stopBackgroundServices() {
        sidebar.stopSidebarTasks()
        didStartBackgroundServices = false
    }

    func reconcileRemoteBrowserForwards(device: SpacesPairedDeviceRecord, overview: SpacesDeviceOverviewPayload) {
        guard device.id != localDeviceID else { return }
        let manager = browserSSHForwardManager
        let revision = nextRemoteBrowserForwardRevision(deviceID: device.id)
        Task.detached(priority: .utility) { manager.reconcile(device: device, overview: overview, revision: revision) }
    }

    func stopRemoteBrowserForwards(deviceID: String) {
        guard deviceID != localDeviceID else { return }
        let manager = browserSSHForwardManager
        let revision = nextRemoteBrowserForwardRevision(deviceID: deviceID)
        Task.detached(priority: .utility) { manager.stop(deviceID: deviceID, revision: revision) }
    }

    private func nextRemoteBrowserForwardRevision(deviceID: String) -> Int {
        let next = (remoteBrowserForwardRevisions[deviceID] ?? 0) + 1
        remoteBrowserForwardRevisions[deviceID] = next
        return next
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

    /// Decides at launch whether to show the blocking Chrome Automation permission screen or open
    /// straight to the workspace UI.
    private func startWorkspaceUIAfterPermissionCheck() {
        if Self.requiresChromeAutomationSetup(ChromeAutomationPermission.status()) {
            enterChromeAutomationSetupFlow()
        } else {
            presentMainWorkspaceUI()
        }
    }

    /// Builds the main split-view content and kicks off the initial sidebar load. Shared by the
    /// normal launch path and the Chrome Automation setup screen's completion handler.
    private func presentMainWorkspaceUI() {
        chromeAutomationSetupController?.stop()
        chromeAutomationSetupController = nil
        buildMainWindowContent()
        logStartupProfile("main_content_ready")
        showLoadingPlaceholder(message: "Loading projects and workspaces...", detail: "Spaces is preparing your workspace data.")
        logStartupProfile("loading_placeholder_ready")
        Task { @MainActor [weak self] in await self?.sidebar.loadInitialSidebarData() }
    }

    /// Presents the blocking permission screen and advances to the workspace UI once the user
    /// grants Chrome Automation. The controller polls so granting via System Settings (where macOS
    /// no longer offers an in-app prompt after a denial) advances the app without a restart.
    private func enterChromeAutomationSetupFlow() {
        logStartupProfile("chrome_automation_setup_started")
        chromeAutomationSetupController?.stop()
        let controller = ChromeAutomationSetupController()
        chromeAutomationSetupController = controller
        // Capture `controller` weakly: it owns `onGranted`, so a strong capture would retain the
        // controller (and its view hierarchy) past the point where `presentMainWorkspaceUI` clears
        // `chromeAutomationSetupController`, leaking a setup controller each time the flow is shown.
        controller.onGranted = { [weak self, weak controller] in
            guard let self, let controller, self.chromeAutomationSetupController === controller else { return }
            self.logStartupProfile("chrome_automation_setup_complete")
            self.presentMainWorkspaceUI()
        }
        window.contentView = controller.begin()
    }

    /// The app has no prerequisite/onboarding flow: background-refresh failures are always
    /// logged rather than routed to a setup screen. Retained so call sites that previously
    /// short-circuited on a deferred-setup requirement keep a single, explicit no-op.
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
        updateAlertsRowAppearance()
    }

    /// The id of the device that owns a workspace/project, falling back to the
    /// local device. These give every action its per-row device context so it
    /// routes to the daemon that actually hosts the workspace.
    func deviceID(forWorkspaceID workspaceID: String) -> String {
        findWorkspace(id: workspaceID)?.0.deviceID ?? SpacesPairedDeviceRecord.localDeviceID
    }

    private func deviceID(forProjectID projectID: String) -> String {
        projects.first(where: { $0.id == projectID })?.deviceID ?? SpacesPairedDeviceRecord.localDeviceID
    }

    private func isRemoteDeviceID(_ deviceID: String) -> Bool {
        deviceSection(id: deviceID).map { !$0.isLocal } ?? (deviceID != SpacesPairedDeviceRecord.localDeviceID)
    }

    private func isLocalWorkspace(_ workspace: WorkspaceSummary) -> Bool { workspace.deviceID == SpacesPairedDeviceRecord.localDeviceID }

    /// The device that owns the current selection, so mutations route to the
    /// daemon that actually hosts the selected workspace/project rather than
    /// always defaulting to the local device.
    private func selectedRowDeviceID() -> String? {
        if let selectedWorkspaceID, let (project, _) = findWorkspace(id: selectedWorkspaceID) { return project.deviceID }
        if let selectedProjectID, let project = projects.first(where: { $0.id == selectedProjectID }) { return project.deviceID }
        return nil
    }

    func deviceForDaemonStateMutation() -> SpacesPairedDeviceRecord? {
        if let deviceID = selectedRowDeviceID(), let device = deviceRecord(forDeviceID: deviceID) { return device }
        return localPairedDevice
    }

    /// Resolves the paired-device record for a mutation target by owning-device id.
    /// Local ids route to the local record; remote ids route to their loaded
    /// section, returning nil when that remote section is offline/unloaded so
    /// callers surface a not-loaded error instead of misrouting the mutation to the
    /// local daemon (which does not host the workspace).
    private func deviceForMutation(deviceID: String) -> SpacesPairedDeviceRecord? {
        if deviceID == SpacesPairedDeviceRecord.localDeviceID { return localPairedDevice }
        return deviceRecord(forDeviceID: deviceID)
    }

    /// The device that owns a specific workspace, so per-workspace mutations route
    /// to the daemon that actually hosts it rather than the currently selected
    /// row's device. Clicking a row button or invoking a context menu does not
    /// change the outline selection, so these actions must resolve their target
    /// from the workspace ID they carry, not the selection.
    func deviceForWorkspaceMutation(workspaceID: String) -> SpacesPairedDeviceRecord? {
        deviceForMutation(deviceID: deviceID(forWorkspaceID: workspaceID))
    }

    private static func deviceNotLoadedError() -> NSError {
        NSError(
            domain: "Spaces", code: 1001,
            userInfo: [
                NSLocalizedDescriptionKey: "Spaces has not finished loading.",
                NSLocalizedRecoverySuggestionErrorKey: "Wait for Spaces to load, or reload Spaces, and try again.",
            ])
    }

    /// Raised when a terminal window is opened by id but neither the caller nor a fresh
    /// device overview knows the session, so its real launch configuration cannot be read.
    private static func terminalSessionNotFoundError() -> NSError {
        NSError(
            domain: "Spaces", code: 1002,
            userInfo: [
                NSLocalizedDescriptionKey: "That terminal session is no longer available.",
                NSLocalizedRecoverySuggestionErrorKey: "Reload Spaces and try again.",
            ])
    }

    func showDeviceNotLoadedError() { showError(Self.deviceNotLoadedError()) }

    private func deviceProjectSummary(projectID: String) -> SpacesDeviceProjectSummary? {
        // Search every device section's overview, not just the local one, so detail
        // and config flows resolve projects that live on a remote device.
        for section in deviceSections { if let project = section.overview?.projects.first(where: { $0.id == projectID }) { return project } }
        return nil
    }

    func deviceWorkspaceSummary(workspaceID: String) -> SpacesDeviceWorkspaceSummary? {
        for section in deviceSections { if let workspace = section.overview?.workspaces.first(where: { $0.id == workspaceID }) { return workspace } }
        return nil
    }

    private func applyDeviceOverview(
        _ overview: SpacesDeviceOverviewPayload, selectedProjectID preferredProjectID: String? = nil,
        selectedWorkspaceID preferredWorkspaceID: String? = nil, preserveDetailPane: Bool = false
    ) {
        let shouldPreserveDetailPane = preserveDetailPane && canPreserveDetailPaneAfterSidebarReload()
        // The mutation's overview belongs to whichever device hosts the affected
        // workspace; update only that device's section and re-merge so the other
        // devices' rows stay intact. An archive removes the workspace before this
        // runs, so fall back to the affected project's device before the current
        // selection to avoid installing the overview into the wrong section.
        let deviceID =
            preferredWorkspaceID.flatMap { findWorkspace(id: $0)?.0.deviceID } ?? preferredProjectID.flatMap { projectID in
                projects.first(where: { $0.id == projectID })?.deviceID
            } ?? selectedRowDeviceID() ?? localDeviceID
        let collapseStates = (try? SpacesClientDatabase.defaultDatabase().projectCollapseStates(deviceID: deviceID)) ?? [:]
        let mapped = Self.deviceSidebarData(from: overview, deviceID: deviceID, projectCollapseStates: collapseStates)
        if let index = deviceSections.firstIndex(where: { $0.deviceID == deviceID }) {
            deviceSections[index].projects = mapped.projects
            deviceSections[index].workspacesByProject = mapped.workspacesByProject
            deviceSections[index].workspaceRuntimeStatusByID = mapped.workspaceRuntimeStatusByID
            deviceSections[index].overview = overview
            if deviceSections[index].isLocal {
                localDeviceOverview = overview
                deviceSections[index].alertsGroups = Self.buildOverviewAlertsGroups(from: overview, deviceID: deviceID)
            }
        }
        if deviceID != localDeviceID, let device = deviceRecord(forDeviceID: deviceID) {
            reconcileRemoteBrowserForwards(device: device, overview: overview)
        }
        rebuildFlatSidebarData()
        if let preferredWorkspaceID, findWorkspace(id: preferredWorkspaceID) != nil {
            selectedWorkspaceID = preferredWorkspaceID
            Self.setClientActiveWorkspaceID(preferredWorkspaceID)
            selectedProjectID = findWorkspace(id: preferredWorkspaceID)?.0.id ?? preferredProjectID
        } else if let preferredProjectID, projects.contains(where: { $0.id == preferredProjectID }) {
            selectedProjectID = preferredProjectID
            selectedWorkspaceID = nil
        }
        outlineView.reloadData()
        applySidebarProjectExpansionState()
        if !shouldPreserveDetailPane { refreshSelection() }
        updateAlertsSidebarBadge()
        if showingAlerts { showAlertsDetail() }
    }

    func applyDeviceMutationResponse(
        _ response: SpacesDeviceAPIResponse, selectedProjectID preferredProjectID: String? = nil,
        selectedWorkspaceID preferredWorkspaceID: String? = nil
    ) {
        if let overview = response.overview {
            applyDeviceOverview(overview, selectedProjectID: preferredProjectID, selectedWorkspaceID: preferredWorkspaceID, preserveDetailPane: false)
        } else {
            if let preferredWorkspaceID { selectedWorkspaceID = preferredWorkspaceID }
            if let preferredWorkspaceID { Self.setClientActiveWorkspaceID(preferredWorkspaceID) }
            if let preferredProjectID { selectedProjectID = preferredProjectID }
            requestSidebarReload()
        }
    }

    func updateDeviceWorkspaceConfig(workspaceID: String, update: (inout WorkspaceSettings) -> Void) throws {
        guard let device = deviceForDaemonStateMutation() else { throw Self.deviceNotLoadedError() }
        guard let workspace = deviceWorkspaceSummary(workspaceID: workspaceID) else {
            throw WorkspaceError.invalidArgument(message: "Workspace not found on the selected device.")
        }
        var settings = Self.localWorkspaceSettings(from: workspace.config)
        update(&settings)
        let response = try SpacesDeviceClient.updateWorkspaceConfig(
            workspaceID: workspaceID,
            config: Self.deviceWorkspaceConfig(from: settings, resolvedBrowserSessions: workspace.config.resolvedBrowserSessions), device: device,
            clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
        applyDeviceMutationResponse(response, selectedWorkspaceID: workspaceID)
    }

    func refreshSelection() {
        if showingAlerts {
            showAlertsDetail()
            return
        }
        if let selectedWorkspaceID {
            if let (project, workspace) = findWorkspace(id: selectedWorkspaceID) {
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
        if let verdict = deviceCompatibility(forDeviceID: localDeviceID), !verdict.isCompatible {
            showCompatibilityBlock(deviceID: localDeviceID, verdict: verdict)
            return
        }
        showAlertsDetail()
    }

    private func startWorkspaceSetupDetailRefreshTimerIfNeeded(workspaceID: String) {
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
        guard selectedWorkspaceID == workspaceID, !showingAlerts, !showingSettings, findWorkspace(id: workspaceID) != nil else {
            stopWorkspaceSetupDetailRefreshTimer()
            return
        }
        guard deviceForDaemonStateMutation() != nil else {
            stopWorkspaceSetupDetailRefreshTimer()
            showDeviceNotLoadedError()
            return
        }
        // Live setup progress for a remote workspace must bypass the remote overview
        // freshness gate, or its logs/status/completion update only at the metadata
        // interval. A local setup needs no forced remote fetch.
        requestSidebarReload(forceRemoteRefresh: isRemoteDeviceID(deviceID(forWorkspaceID: workspaceID)))
    }

    func showPlaceholder(message: String = "Select a project or workspace.") {
        clearActiveAddFormStateAndCloseWindows()
        stopWorkspaceSetupDetailRefreshTimer()
        visibleDetailWorkspaceID = nil
        visibleCompatibilityBlockDeviceID = nil
        showingSettings = false
        showingAlerts = false
        updateAlertsRowAppearance()
        activeShortcutCaptureSetting = nil
        clearWorkspaceDetailFooter()
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

    /// Wire-protocol verdict for a device section, or `nil` if the device hasn't been handshaken yet.
    func deviceCompatibility(forDeviceID deviceID: String) -> SpacesWireCompatibility? { deviceSection(id: deviceID)?.compatibility }

    func deviceDaemonStatus(forDeviceID deviceID: String) -> TerminalServiceDaemonStatus? { deviceSection(id: deviceID)?.daemonStatus }

    /// If the device whose compatibility block is currently shown is no longer incompatible (e.g. after
    /// a restart updated its daemon), drop the obsolete block and re-resolve the detail pane. Called
    /// from the apply paths after a reload updates a section's verdict.
    func clearCompatibilityBlockIfResolved(deviceID: String) {
        guard visibleCompatibilityBlockDeviceID == deviceID else { return }
        if deviceCompatibility(forDeviceID: deviceID)?.isCompatible == false { return }
        visibleCompatibilityBlockDeviceID = nil
        refreshSelection()
    }

    /// Renders the full-pane compatibility block for an incompatible device, with the restart-impact
    /// report and a restart action. Switching to a compatible device in the sidebar leaves it.
    func showCompatibilityBlock(deviceID: String, verdict: SpacesWireCompatibility) {
        clearActiveAddFormStateAndCloseWindows()
        stopWorkspaceSetupDetailRefreshTimer()
        visibleDetailWorkspaceID = nil
        visibleCompatibilityBlockDeviceID = deviceID
        showingSettings = false
        showingAlerts = false
        updateAlertsRowAppearance()
        activeShortcutCaptureSetting = nil
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

        let status = deviceDaemonStatus(forDeviceID: deviceID)
        let card = CompatibilityBlockView(
            verdict: verdict, status: status,
            onRestart: verdict == .clientTooOld ? nil : { [weak self] in self?.confirmDaemonRestart(deviceID: deviceID) })
        card.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: detailContainer.topAnchor, constant: 24),
            card.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(lessThanOrEqualTo: detailContainer.trailingAnchor, constant: -24),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])
    }

    /// Confirms the restart-impact with the user, then restarts the device's daemon. A remote Linux
    /// daemon is updated from the signed artifact over SSH (which restarts it); every other device
    /// restarts through the `requestDaemonRestart` RPC, after which launchd/systemd respawns it.
    private func confirmDaemonRestart(deviceID: String) {
        let status = deviceDaemonStatus(forDeviceID: deviceID)
        let alert = NSAlert()
        alert.messageText = "Restart this device's daemon?"
        alert.informativeText = Self.restartImpactMessage(status: status)
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Defer")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let device = deviceRecord(forDeviceID: deviceID) else {
            showDeviceNotLoadedError()
            return
        }
        // The daemon reports its own OS, so route on that rather than probing SSH: a non-Linux daemon
        // must not run the Linux SSH preflight, or a stale/unavailable SSH path would block restarting a
        // remote Mac whose Device API is still reachable.
        let isLinuxDaemon = status?.isLinuxDaemon ?? false
        Task { @MainActor [weak self] in
            let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    if isLinuxDaemon {
                        // A remote Linux daemon must be reinstalled from the signed artifact to actually
                        // update (a plain restart respawns the same old binary); the installer restarts it.
                        // `false` means the SSH path could not confirm a Linux host, so nothing happened —
                        // surface that instead of reloading as if it succeeded.
                        let updated = try SpacesDevicePairingClient.updateRemoteLinuxDaemon(
                            for: device, appVersion: AppVersion.short, remoteArtifactPublicKey: AppVersion.remoteArtifactPublicKey)
                        guard updated else {
                            throw NSError(
                                domain: "SpacesCompatibility", code: 1,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "Couldn't update this device's daemon over SSH. Check the SSH connection to the device and try again."
                                ])
                        }
                    } else {
                        // Local or remote Mac: restart through the RPC, applying any update already staged on disk.
                        try SpacesDeviceClient.requestDaemonRestart(device: device)
                    }
                    return .success(())
                } catch { return .failure(error) }
            }.value
            guard let self else { return }
            if case .failure(let error) = result { self.showError(error) }
            // Give the daemon a moment to exit and respawn, then re-handshake.
            try? await Task.sleep(for: .seconds(2))
            self.requestSidebarReload(forceRemoteRefresh: true)
        }
    }

    /// Compatible, but the daemon reports an older app version than this build — a daemon update is
    /// staged and applies on the next restart. Non-blocking; surfaced as a quiet caption only.
    static func daemonUpdatePending(status: TerminalServiceDaemonStatus?) -> Bool {
        guard let status else { return false }
        return SpacesWireProtocol.isVersion(status.version, olderThan: AppVersion.short)
    }

    static func restartImpactMessage(status: TerminalServiceDaemonStatus?) -> String {
        guard let status else { return "Running terminals, processes, and coding agents on this device will stop." }
        let agents = status.activeAgents + status.waitingAgents
        var parts: [String] = []
        if status.activeSessionCount > 0 { parts.append("\(status.activeSessionCount) terminal\(status.activeSessionCount == 1 ? "" : "s")") }
        if status.runningProcesses > 0 { parts.append("\(status.runningProcesses) process\(status.runningProcesses == 1 ? "" : "es")") }
        if agents > 0 { parts.append("\(agents) coding agent\(agents == 1 ? "" : "s")") }
        guard !parts.isEmpty else { return "No running work will be interrupted." }
        return "This will stop " + parts.joined(separator: ", ") + ". Defer if you need them to finish first."
    }

    private func showLoadingPlaceholder(message: String, detail: String?) {
        clearActiveAddFormStateAndCloseWindows()
        stopWorkspaceSetupDetailRefreshTimer()
        visibleDetailWorkspaceID = nil
        showingSettings = false
        showingAlerts = false
        updateAlertsRowAppearance()
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
        case mcp

        var title: String {
            switch self {
            case .general: "General"
            case .shortcuts: "Shortcuts"
            case .devices: "Devices"
            case .mcp: "MCP"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .shortcuts: "keyboard"
            case .devices: "desktopcomputer.and.macbook"
            case .mcp: "puzzlepiece.extension"
            }
        }
    }

    func settingsHairlineDivider() -> NSView {
        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = sidebarCardBorderColor(isSelected: false).cgColor
        return divider
    }

    @objc func closeSettingsWindow() { settings.closeSettingsWindow() }

    public func windowWillClose(_ notification: Notification) {
        let closingWindow = notification.object as? NSWindow
        if closingWindow === addProjectWindow {
            clearActiveAddProjectFormState()
            return
        }
        if closingWindow === addWorkspaceWindow {
            clearActiveAddWorkspaceFormState()
            return
        }
        if closingWindow === projectSettingsWindow {
            if let projectSettingsProjectID { ProjectFieldCache.shared.cache[projectSettingsProjectID.hashValue] = nil }
            projectSettingsProjectID = nil
            projectHasUnsavedChanges = false
            return
        }
        if closingWindow === workspaceSettingsWindow {
            workspaceSettingsWorkspaceID = nil
            return
        }
        guard closingWindow === settings.settingsWindow else { return }
        showingSettings = false
        shortcutButtonsBySetting.removeAll()
        activeShortcutCaptureSetting = nil
        settings.handleSettingsWindowClosed()
    }

    func settingsLabeledField(name: String, hint: String, control: NSView) -> NSView {
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

    func settingsSettingRow(name: String, hint: String, control: NSView) -> NSView {
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

    func buildShortcutRowsContainer() -> NSView {
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

    private func showProjectSettingsDialog(project: ProjectSummary) {
        clearActiveAddFormStateAndCloseWindows()
        projectHasUnsavedChanges = false

        let projectSettings:
            (
                setupScript: String?, stopScript: String?, ports: [ServiceDefinition], processes: [ProcessTemplate],
                browserSessions: [BrowserSession], agentLaunchers: [AgentLauncher]
            )
        if let activeProject = deviceProjectSummary(projectID: project.id).map({ SpacesDeviceProjectSettingsViewModel(project: $0) }) {
            projectSettings = Self.localProjectSettings(from: activeProject.config)
        } else {
            projectSettings = (setupScript: nil, stopScript: nil, ports: [], processes: [], browserSessions: [], agentLaunchers: [])
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        // --- Directory subtitle (the project name is shown in the dialog header) ---
        let dirField = NSTextField(string: project.dir)
        dirField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        dirField.textColor = .tertiaryLabelColor
        dirField.lineBreakMode = .byTruncatingMiddle
        dirField.isEditable = false
        dirField.isSelectable = true
        dirField.drawsBackground = false
        dirField.isBordered = false
        dirField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(dirField)
        constrainFormFieldToFillWidth(dirField, in: stack)

        // --- Fields ---
        let setupScriptSection = ScriptSection(
            title: "Setup Script", editAccessibilityIdentifier: "setup-script-edit", formAccessibilityPrefix: "project-setup-script",
            value: projectSettings.setupScript ?? "", subtitle: "Runs when each new workspace is created or revived from archive.")
        let stopScriptSection = ScriptSection(
            title: "Stop Script", editAccessibilityIdentifier: "stop-script-edit", formAccessibilityPrefix: "workspace-stop-script",
            value: projectSettings.stopScript ?? "", subtitle: "Runs after processes stop — on stop, restart, and archive.")
        let portsSection = PortsSection(ports: projectSettings.ports, subtitle: "Per-workspace services, routed through Caddy.")
        let processesSection = ProcessesSection(
            processes: projectSettings.processes, subtitle: "Commands that run inside the workspace.", showsRuntimeControls: false)
        let browserSessionsSection = BrowserSessionsSection(
            sessions: projectSettings.browserSessions, subtitle: "Named URLs that open in Chrome when you focus them.")
        let agentLaunchersSection = AgentLaunchersSection(
            launchers: projectSettings.agentLaunchers, subtitle: "Coding agents that open in a Spaces terminal.", showsRuntimeControls: false)

        setupScriptSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
        stopScriptSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
        portsSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
        portsSection.presentRemoveConfirmation = { [weak self] port, confirm in
            self?.presentProjectPortRemoveConfirmation(port: port, confirm: confirm)
        }
        processesSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
        processesSection.validateProcess = { process in try Self.validateProcessTemplate(process) }
        processesSection.presentValidationError = { [weak self] error in self?.showError(error) }
        processesSection.presentRemoveConfirmation = { [weak self] process, confirm in
            self?.presentProjectProcessRemoveConfirmation(process: process, confirm: confirm)
        }
        browserSessionsSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
        browserSessionsSection.presentRemoveConfirmation = { [weak self] session, confirm in
            self?.presentProjectBrowserSessionRemoveConfirmation(session: session, confirm: confirm)
        }
        agentLaunchersSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
        agentLaunchersSection.presentRemoveConfirmation = { [weak self] launcher, confirm in
            self?.presentProjectAgentLauncherRemoveConfirmation(launcher: launcher, confirm: confirm)
        }

        for section in [
            setupScriptSection.view, portsSection.view, processesSection.view, browserSessionsSection.view, agentLaunchersSection.view,
            stopScriptSection.view,
        ] {
            stack.addArrangedSubview(section)
            constrainFormFieldToFillWidth(section, in: stack)
        }

        // --- Buttons ---
        let saveButton = actionButton(title: "Save", symbol: nil, tooltip: "Save project (⌘S)", action: #selector(saveProject(_:)), primary: true)
        saveButton.identifier = NSUserInterfaceItemIdentifier(project.id)
        saveButton.setAccessibilityIdentifier("project-settings-save")
        saveButton.keyEquivalent = "\r"

        let importButton = actionButton(
            title: "Import spaces.yaml", symbol: nil, tooltip: "Load spaces.yaml into project settings",
            action: #selector(importProjectSpacesYAML(_:)), primary: false)
        importButton.setAccessibilityIdentifier("project-settings-import-spaces-yaml")
        Theme.applySecondaryStyle(to: importButton)

        let exportButton = actionButton(
            title: "Export spaces.yaml", symbol: nil, tooltip: "Export this project to spaces.yaml", action: #selector(exportProjectSpacesYAML(_:)),
            primary: false)
        exportButton.setAccessibilityIdentifier("project-settings-export-spaces-yaml")
        Theme.applySecondaryStyle(to: exportButton)

        let discardImportButton = actionButton(
            title: "Discard Import", symbol: nil, tooltip: "Discard imported config changes and reload the saved project settings",
            action: #selector(discardProjectConfigChanges(_:)), primary: false)
        discardImportButton.setAccessibilityIdentifier("project-settings-discard-import")
        discardImportButton.isHidden = true
        Theme.applySecondaryStyle(to: discardImportButton)

        let deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteProject(_:)))
        deleteButton.identifier = NSUserInterfaceItemIdentifier(project.id)
        deleteButton.setAccessibilityIdentifier("project-settings-delete")
        Theme.applyTextStyle(to: deleteButton, color: .systemRed)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.addArrangedSubview(deleteButton)
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(importButton)
        buttonRow.addArrangedSubview(exportButton)
        buttonRow.addArrangedSubview(discardImportButton)
        buttonRow.addArrangedSubview(saveButton)
        stack.addArrangedSubview(buttonRow)
        constrainFormFieldToFillWidth(buttonRow, in: stack)

        presentProjectSettingsWindow(hosting: stack, project: project)

        let fieldsTag = storeProjectFields(
            projectID: project.id, setupScriptSection: setupScriptSection, stopScriptSection: stopScriptSection, portsSection: portsSection,
            processesSection: processesSection, browserSessionsSection: browserSessionsSection, agentLaunchersSection: agentLaunchersSection,
            importButton: importButton, exportButton: exportButton, discardImportedConfigButton: discardImportButton)
        saveButton.tag = fieldsTag
        discardImportButton.tag = fieldsTag
        importButton.tag = fieldsTag
        exportButton.tag = fieldsTag
        registerDirtyTracking(
            setupScriptSection: setupScriptSection, stopScriptSection: stopScriptSection, portsSection: portsSection,
            processesSection: processesSection, browserSessionsSection: browserSessionsSection, agentLaunchersSection: agentLaunchersSection)
    }

    private func presentProjectSettingsWindow(hosting stack: NSStackView, project: ProjectSummary) {
        projectSettingsProjectID = project.id
        let header = buildFormWindowHeader(symbol: "gearshape", title: project.name, closeAction: #selector(closeProjectSettingsWindow))
        projectSettingsWindow = presentFormWindow(existing: projectSettingsWindow, header: header, hosting: stack)
    }

    @objc private func closeProjectSettingsWindow() { projectSettingsWindow?.performClose(nil) }

    func formSectionCard(
        icon: String?, title: String, subtitle: String = "", iconColor: NSColor? = nil, trailingView: NSView? = nil, contentViews: [NSView]
    ) -> NSView {
        let section = NSView()
        section.translatesAutoresizingMaskIntoConstraints = false
        section.setContentHuggingPriority(.required, for: .vertical)

        let accentColor = iconColor ?? sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))

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
        if let icon {
            let iconView = NSImageView()
            if let img = NSImage(systemSymbolName: icon, accessibilityDescription: title) {
                let config = NSImage.SymbolConfiguration(paletteColors: [accentColor])
                iconView.image = img.withSymbolConfiguration(config)
            }
            iconView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([iconView.widthAnchor.constraint(equalToConstant: 20), iconView.heightAnchor.constraint(equalToConstant: 20)])
            headerRow.addArrangedSubview(iconView)
        }
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

    private func projectDetailSection(title: String, subtitle: String = "", trailingView: NSView? = nil, contentViews: [NSView]) -> NSView {
        let section = NSView()
        section.translatesAutoresizingMaskIntoConstraints = false
        section.setContentHuggingPriority(.required, for: .vertical)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = Theme.text

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        titleStack.addArrangedSubview(titleLabel)
        if !subtitle.isEmpty {
            let subtitleLabel = NSTextField(labelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
            subtitleLabel.textColor = Theme.muted
            subtitleLabel.lineBreakMode = .byTruncatingTail
            subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleStack.addArrangedSubview(subtitleLabel)
        }
        titleStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let headerRow = NSStackView(views: trailingView.map { [titleStack, spacer, $0] } ?? [titleStack, spacer])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.edgeInsets = Theme.cardContentInsets
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        let innerStack = NSStackView()
        innerStack.orientation = .vertical
        innerStack.alignment = .leading
        innerStack.spacing = 0
        innerStack.translatesAutoresizingMaskIntoConstraints = false
        innerStack.addArrangedSubview(headerRow)
        for view in contentViews { innerStack.addArrangedSubview(view) }

        let divider = ColoredBackgroundView()
        divider.fillColor = Theme.border
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        section.addSubview(innerStack)
        section.addSubview(divider)
        NSLayoutConstraint.activate([
            innerStack.leadingAnchor.constraint(equalTo: section.leadingAnchor),
            innerStack.trailingAnchor.constraint(equalTo: section.trailingAnchor), innerStack.topAnchor.constraint(equalTo: section.topAnchor),
            divider.leadingAnchor.constraint(equalTo: section.leadingAnchor), divider.trailingAnchor.constraint(equalTo: section.trailingAnchor),
            divider.topAnchor.constraint(equalTo: innerStack.bottomAnchor), divider.bottomAnchor.constraint(equalTo: section.bottomAnchor),
        ])
        headerRow.widthAnchor.constraint(equalTo: innerStack.widthAnchor).isActive = true
        for view in contentViews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: innerStack.widthAnchor).isActive = true
        }
        return section
    }

    private func showAddProjectForm() {
        clearActiveAddProjectFormState()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false

        // --- Fields ---
        let sourceSegmented = NSSegmentedControl(
            labels: ["Pick folder", "Clone repo"], trackingMode: .selectOne, target: self, action: #selector(projectSourceChanged(_:)))
        sourceSegmented.selectedSegment = 0
        sourceSegmented.setAccessibilityIdentifier("add-project-source-mode")

        let dirField = NSTextField(string: "")
        dirField.placeholderString = "~/projects/my-app"
        dirField.delegate = self
        dirField.setAccessibilityIdentifier("add-project-directory-path")
        let repoURLField = NSTextField(string: "")
        repoURLField.placeholderString = "https://github.com/org/repo.git"
        repoURLField.delegate = self
        let prepareButton = actionButton(
            title: "Clone", symbol: "arrow.down.circle", tooltip: "Clone repository and load project settings",
            action: #selector(prepareProjectSource(_:)), primary: false)
        prepareButton.setAccessibilityIdentifier("add-project-prepare-source")
        Theme.applySecondaryStyle(to: prepareButton)

        let setupScriptSection = ScriptSection(
            title: "Setup Script", editAccessibilityIdentifier: "setup-script-edit", formAccessibilityPrefix: "project-setup-script", value: "",
            subtitle: "Runs when each new workspace is created or revived from archive.")
        let stopScriptSection = ScriptSection(
            title: "Stop Script", editAccessibilityIdentifier: "stop-script-edit", formAccessibilityPrefix: "workspace-stop-script", value: "",
            subtitle: "Runs after processes stop — on stop, restart, and archive.")
        let portsSection = PortsSection(subtitle: "Per-workspace named ports, exposed as env vars.")
        let processesSection = ProcessesSection(subtitle: "Commands that run inside the workspace.", showsRuntimeControls: false)
        let browserSessionsSection = BrowserSessionsSection(subtitle: "Named URLs that open in Chrome when you focus them.")
        let agentLaunchersSection = AgentLaunchersSection(subtitle: "Coding agents that open in a Spaces terminal.", showsRuntimeControls: false)

        // --- Source section: segmented control on top, input below ---
        let localSourceSection = NSStackView()
        localSourceSection.orientation = .horizontal
        localSourceSection.alignment = .centerY
        localSourceSection.spacing = 8
        localSourceSection.detachesHiddenViews = true

        dirField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        dirField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        localSourceSection.addArrangedSubview(dirField)

        let cloneSourceSection = NSStackView()
        cloneSourceSection.orientation = .horizontal
        cloneSourceSection.alignment = .centerY
        cloneSourceSection.spacing = 8
        cloneSourceSection.detachesHiddenViews = true
        cloneSourceSection.isHidden = true

        repoURLField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        repoURLField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        cloneSourceSection.addArrangedSubview(repoURLField)
        cloneSourceSection.addArrangedSubview(prepareButton)

        let sourceContentStack = NSStackView()
        sourceContentStack.orientation = .vertical
        sourceContentStack.alignment = .leading
        sourceContentStack.spacing = 8
        sourceContentStack.detachesHiddenViews = true
        sourceSegmented.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        // Device selector: only meaningful when more than one device is paired.
        // With a single device the project is created on the local Mac. The label
        // sits above a full-width popup so it lines up with the controls below.
        if deviceSections.count > 1 {
            let devicePopUp = NSPopUpButton()
            devicePopUp.target = self
            devicePopUp.action = #selector(projectDeviceChanged(_:))
            devicePopUp.setAccessibilityIdentifier("add-project-device")
            for section in deviceSections {
                devicePopUp.addItem(withTitle: section.deviceName)
                devicePopUp.lastItem?.representedObject = section.deviceID
            }
            if let localItem = devicePopUp.itemArray.first(where: { ($0.representedObject as? String) == localProjectCreationDeviceID() }) {
                devicePopUp.select(localItem)
            }
            let deviceField = NSStackView(views: [makeFieldHeader("Device"), devicePopUp])
            deviceField.orientation = .vertical
            deviceField.alignment = .leading
            deviceField.spacing = 4
            sourceContentStack.addArrangedSubview(deviceField)
            constrainFormFieldToFillWidth(deviceField, in: sourceContentStack)
            devicePopUp.widthAnchor.constraint(equalTo: deviceField.widthAnchor).isActive = true
        }
        sourceContentStack.addArrangedSubview(sourceSegmented)
        sourceContentStack.addArrangedSubview(localSourceSection)
        sourceContentStack.addArrangedSubview(cloneSourceSection)
        constrainFormFieldToFillWidth(localSourceSection, in: sourceContentStack)
        constrainFormFieldToFillWidth(cloneSourceSection, in: sourceContentStack)

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
        let createButton = actionButton(title: "Create", symbol: nil, tooltip: "Create project", action: #selector(createProject(_:)), primary: true)
        createButton.isEnabled = false
        let cancelButton = actionButton(title: "Cancel", symbol: nil, tooltip: "Cancel", action: #selector(cancelProjectForm), primary: false)
        Theme.applySecondaryStyle(to: cancelButton)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.setViews([cancelButton], in: .leading)
        buttonRow.setViews([createButton], in: .trailing)
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

        presentAddProjectWindow(hosting: stack)

        createButton.tag = storeAddProjectFields(
            sourceSegmented: sourceSegmented, localSourceSection: localSourceSection, cloneSourceSection: cloneSourceSection, dirField: dirField,
            repoURLField: repoURLField, setupScriptSection: setupScriptSection, stopScriptSection: stopScriptSection, portsSection: portsSection,
            processesSection: processesSection, browserSessionsSection: browserSessionsSection, agentLaunchersSection: agentLaunchersSection,
            prepareButton: prepareButton,
            progressiveInputViews: [
                setupScriptSection.view, portsSection.view, processesSection.view, browserSessionsSection.view, agentLaunchersSection.view,
                stopScriptSection.view,
            ], createButton: createButton)
        activeAddProjectFormTag = createButton.tag
        if let refs = AddProjectFieldCache.shared.cache[createButton.tag] {
            refs.selectedDeviceID = localProjectCreationDeviceID()
            updateAddProjectSourceUI(refs)
        }
        addProjectWindow?.makeFirstResponder(dirField)
    }

    /// The default device for new projects: the local Mac.
    private func localProjectCreationDeviceID() -> String {
        deviceSections.first(where: { $0.isLocal })?.deviceID ?? SpacesPairedDeviceRecord.localDeviceID
    }

    @objc private func projectDeviceChanged(_ sender: NSPopUpButton) {
        guard let tag = activeAddProjectFormTag, let refs = AddProjectFieldCache.shared.cache[tag] else { return }
        refs.selectedDeviceID = (sender.selectedItem?.representedObject as? String) ?? localProjectCreationDeviceID()
        // The folder lives on the chosen device, so re-validate any typed path there.
        refs.preparedLocalDirectoryPath = nil
        refs.directoryCompletions = []
        updateAddProjectProgressiveDisclosure(refs)
        scheduleAddProjectDirectoryPreview(refs)
        scheduleAddProjectDirectorySuggestions(refs)
    }

    private func presentAddProjectWindow(hosting stack: NSStackView) {
        let header = buildFormWindowHeader(symbol: "square.and.pencil", title: "New Project", closeAction: #selector(closeAddProjectWindow))
        addProjectWindow = presentFormWindow(existing: addProjectWindow, header: header, hosting: stack)
    }

    @objc private func closeAddProjectWindow() { addProjectWindow?.performClose(nil) }

    public func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard sender === addProjectWindow, let field = client as? NSTextField, addProjectRefs(forDirectoryField: field) != nil else { return nil }
        let editor = pathCompletionFieldEditor ?? PathCompletionTextView()
        editor.isFieldEditor = true
        pathCompletionFieldEditor = editor
        return editor
    }

    func presentFormWindow(existing: NSWindow?, header: NSView, hosting stack: NSStackView) -> NSWindow {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = sidebarPanelBackgroundColor().cgColor

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

    func buildFormWindowHeader(symbol: String, title: String, closeAction: Selector) -> NSView {
        let header = NSView()

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([iconView.widthAnchor.constraint(equalToConstant: 18), iconView.heightAnchor.constraint(equalToConstant: 18)])

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .labelColor

        let closeButton = iconButton(symbol: "xmark", tooltip: "Close", action: closeAction)
        closeButton.keyEquivalent = "\u{1b}"

        let stack = NSStackView(views: [iconView, titleLabel, NSView(), closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 18, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor), stack.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            stack.topAnchor.constraint(equalTo: header.topAnchor), stack.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])
        return header
    }

    private func presentAddWorkspaceWindow(hosting stack: NSStackView) {
        let header = buildFormWindowHeader(
            symbol: "plus.rectangle.on.folder", title: "New Workspace", closeAction: #selector(closeAddWorkspaceWindow))
        addWorkspaceWindow = presentFormWindow(existing: addWorkspaceWindow, header: header, hosting: stack)
    }

    // MARK: - Workspace visibility forwarders
    // The dialog-open (sidebar header) and window-close buttons bind their target
    // to the host, so these stay as @objc host methods; the implementation lives
    // on `workspaceVisibility` (WorkspaceVisibilityController).
    @objc func showWorkspaceVisibilityDialog() { workspaceVisibility.showWorkspaceVisibilityDialog() }
    @objc func closeWorkspaceVisibilityWindow() { workspaceVisibility.closeWorkspaceVisibilityWindow() }

    @objc private func closeAddWorkspaceWindow() { addWorkspaceWindow?.performClose(nil) }

    private func showAddWorkspaceForm(project: ProjectSummary) {
        // The new-workspace form is git-only: non-git projects own a single workspace
        // (the project directory) and offer no way to add more.
        guard project.isGitRepo else { return }
        clearActiveAddWorkspaceFormState()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        // --- Fields ---
        let baseBranchField = NSComboBox()
        baseBranchField.usesDataSource = false
        baseBranchField.completes = true
        baseBranchField.numberOfVisibleItems = 10
        baseBranchField.setAccessibilityIdentifier("add-workspace-base-branch")
        let baseBranches = [defaultWorkspaceBaseBranchFast(project: project)].compactMap { $0 }
        baseBranchField.addItems(withObjectValues: baseBranches)
        if let defaultBaseBranch = defaultWorkspaceBaseBranch(project: project, branches: baseBranches) {
            baseBranchField.stringValue = defaultBaseBranch
        }
        let existingBranchField = NSComboBox()
        existingBranchField.usesDataSource = false
        existingBranchField.completes = true
        existingBranchField.numberOfVisibleItems = 10
        existingBranchField.placeholderString = "search branches"
        existingBranchField.setAccessibilityIdentifier("add-workspace-existing-branch")
        existingBranchField.target = self
        existingBranchField.action = #selector(addWorkspaceBranchFieldChanged(_:))
        existingBranchField.delegate = self
        existingBranchField.addItems(withObjectValues: baseBranches)
        let newBranchField = NSTextField(string: "")
        newBranchField.placeholderString = "new branch name"
        newBranchField.setAccessibilityIdentifier("add-workspace-new-branch")
        newBranchField.delegate = self
        let notesField = NSTextField(string: "")
        notesField.placeholderString = "optional: context about what you're working on"
        notesField.setAccessibilityIdentifier("add-workspace-notes")
        let autoNameState = AddWorkspaceAutoNameState()

        // --- Content card ---
        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10

        let modeSegmented = NSSegmentedControl(
            labels: ["Create branch", "Use existing"], trackingMode: .selectOne, target: self, action: #selector(addWorkspaceBranchModeChanged(_:)))
        modeSegmented.selectedSegment = 0
        modeSegmented.setAccessibilityIdentifier("add-workspace-branch-mode")
        modeSegmented.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        contentStack.addArrangedSubview(modeSegmented)

        let branchInputContainer = NSStackView()
        branchInputContainer.orientation = .vertical
        branchInputContainer.spacing = 0
        branchInputContainer.detachesHiddenViews = true
        branchInputContainer.addArrangedSubview(newBranchField)
        branchInputContainer.addArrangedSubview(existingBranchField)
        constrainFormFieldToFillWidth(newBranchField, in: branchInputContainer)
        constrainFormFieldToFillWidth(existingBranchField, in: branchInputContainer)
        existingBranchField.isHidden = true

        let branchRow = labeledInputRow(label: "Branch", input: branchInputContainer)
        contentStack.addArrangedSubview(branchRow)
        constrainFormFieldToFillWidth(branchRow, in: contentStack)

        let baseRow = labeledInputRow(label: "Base branch", input: baseBranchField)
        contentStack.addArrangedSubview(baseRow)
        constrainFormFieldToFillWidth(baseRow, in: contentStack)

        let notesRow = labeledInputRow(label: "Notes", input: notesField)
        contentStack.addArrangedSubview(notesRow)
        constrainFormFieldToFillWidth(notesRow, in: contentStack)

        let branchModeSegmented: NSSegmentedControl? = modeSegmented

        stack.addArrangedSubview(contentStack)
        constrainFormFieldToFillWidth(contentStack, in: stack)

        // --- Buttons ---
        let createButton = actionButton(
            title: "Create", symbol: nil, tooltip: "Create workspace", action: #selector(createWorkspace(_:)), primary: true)
        createButton.setAccessibilityIdentifier("add-workspace-create")
        let cancelButton = actionButton(title: "Cancel", symbol: nil, tooltip: "Cancel", action: #selector(closeAddWorkspaceWindow), primary: false)
        cancelButton.setAccessibilityIdentifier("add-workspace-cancel")
        Theme.applySecondaryStyle(to: cancelButton)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.setViews([cancelButton], in: .leading)
        buttonRow.setViews([createButton], in: .trailing)
        stack.addArrangedSubview(buttonRow)
        constrainFormFieldToFillWidth(buttonRow, in: stack)

        presentAddWorkspaceWindow(hosting: stack)

        createButton.tag = storeAddWorkspaceFields(
            projectID: project.id, isGitRepo: project.isGitRepo, branchModeSegmented: branchModeSegmented, existingBranchField: existingBranchField,
            newBranchField: newBranchField, baseBranchField: baseBranchField, notesField: notesField, autoNameState: autoNameState,
            createButton: createButton)
        activeAddWorkspaceFormTag = createButton.tag
        if let refs = AddWorkspaceFieldCache.shared.cache[createButton.tag] {
            updateAddWorkspaceBranchInputUI(refs: refs)
            updateAddWorkspaceProgressiveDisclosure(refs: refs, branchValue: currentAddWorkspaceBranchValue(refs))
        }
        Task { @MainActor [weak self, weak newBranchField] in
            await Task.yield()
            guard let self else { return }
            self.addWorkspaceWindow?.makeFirstResponder(newBranchField)
        }
        let formTag = createButton.tag
        guard let device = deviceRecord(forDeviceID: deviceID(forProjectID: project.id)) else {
            showDeviceNotLoadedError()
            return
        }
        Task { @MainActor [weak self, weak baseBranchField, weak existingBranchField] in
            guard let self else { return }
            let result = await Self.deviceWorkspaceCreateOptions(projectID: project.id, device: device).map(\.branchOptions)
            guard activeAddWorkspaceFormTag == formTag else { return }
            guard let baseBranchField else { return }
            guard case .success(let options) = result else { return }
            autoNameState.branchOptions = options
            let currentValue = baseBranchField.stringValue
            baseBranchField.removeAllItems()
            baseBranchField.addItems(withObjectValues: options)
            if !currentValue.isEmpty {
                baseBranchField.stringValue = currentValue
            } else if let defaultBranch = defaultWorkspaceBaseBranch(project: project, branches: options) {
                baseBranchField.stringValue = defaultBranch
            }
            if let existingBranchField {
                let existingValue = existingBranchField.stringValue
                existingBranchField.removeAllItems()
                existingBranchField.addItems(withObjectValues: options)
                if !existingValue.isEmpty { existingBranchField.stringValue = existingValue }
            }
            if let refs = AddWorkspaceFieldCache.shared.cache[formTag] {
                self.updateAddWorkspaceProgressiveDisclosure(refs: refs, branchValue: self.currentAddWorkspaceBranchValue(refs))
            }
        }
    }

    private func prepareWorkspaceDetailContainer(workspaceID: String) {
        clearActiveAddFormStateAndCloseWindows()
        visibleDetailWorkspaceID = workspaceID
        showingSettings = false
        showingAlerts = false
        updateAlertsRowAppearance()
        activeShortcutCaptureSetting = nil
        workspaceSetupLogTextView = nil
        for view in detailContainer.subviews { view.removeFromSuperview() }
        detailContainer.wantsLayer = true
        detailContainer.layer?.backgroundColor = sidebarPanelBackgroundColor().cgColor
        // Every workspace-detail surface (panel, loading, setup) shares the footer
        // strip with the workspace's identity and actions.
        if let (_, workspace) = findWorkspace(id: workspaceID) {
            populateWorkspaceDetailFooter(workspace: workspace)
        } else {
            clearWorkspaceDetailFooter()
        }
    }

    func showWorkspaceDetail(project: ProjectSummary, workspace: WorkspaceSummary) {
        // Fully blocked, scoped to the owning device: if its daemon is wire-incompatible, the only
        // detail surface is the compatibility banner. Other devices' workspaces stay usable.
        let workspaceDeviceID = deviceID(forWorkspaceID: workspace.id)
        if let verdict = deviceCompatibility(forDeviceID: workspaceDeviceID), !verdict.isCompatible {
            showCompatibilityBlock(deviceID: workspaceDeviceID, verdict: verdict)
            return
        }
        visibleCompatibilityBlockDeviceID = nil
        guard let deviceWorkspaceSummary = deviceWorkspaceSummary(workspaceID: workspace.id) else {
            prepareWorkspaceDetailContainer(workspaceID: workspace.id)
            showWorkspaceDetailLoadingPlaceholder(workspace: workspace)
            requestSidebarReload()
            return
        }
        let deviceWorkspace = SpacesDeviceWorkspaceDetailViewModel(workspace: deviceWorkspaceSummary)
        let setupState = Self.localSetupState(from: deviceWorkspace.setupState)
        prepareWorkspaceDetailContainer(workspaceID: workspace.id)
        if !Self.shouldRequestNormalWorkspaceDetailRefresh(setupStatus: setupState.status) {
            showWorkspaceSetupDetail(project: project, workspace: workspace, setupState: setupState, logTail: deviceWorkspace.setupState?.logTail)
            return
        }
        stopWorkspaceSetupDetailRefreshTimer()

        // The right panel is the workspace's panel (tabs of terminal panes) and
        // nothing else; workspace identity and actions live in the footer strip below.
        // The panel view instance is stable per workspace, so overview ticks re-parent
        // it without recreating hosted terminal surfaces.
        let scope = PanelScope.workspace(deviceID: workspaceDeviceID, workspaceID: workspace.id)
        panelCoordinator.restoreLayoutIfNeeded(scope: scope)
        let panelView = panelCoordinator.panelView(for: scope)
        panelView.removeFromSuperview()
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

    /// Fills the right panel's footer strip with the selected workspace's identity and
    /// actions — status dot, name, branch, directory, notes, runtime warning, and the
    /// launch/restart, stop, and overflow controls.
    private func populateWorkspaceDetailFooter(workspace: WorkspaceSummary) {
        guard let footer = workspaceDetailFooterRow else { return }
        clearWorkspaceDetailFooter()
        let accentColor = sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
        let runtimeStatus =
            workspaceRuntimeStatusByID[workspace.id]
            ?? WorkspaceRuntimeStatus(
                workspaceID: workspace.id, lifecycleState: WorkspaceLifecycleState(isRunning: workspace.isRunning), runtimeHealth: .healthy,
                hasTrackedRuntimeIndicators: false, runningProcessCount: 0, exitedProcessCount: 0, waitingAgentWindowCount: 0,
                missingConfiguredProcessCount: 0, missingConfiguredBrowserSessionCount: 0)
        let isLifecycleRunning = runtimeStatus.lifecycleState == .running

        let statusDot = NSImageView()
        statusDot.image = NSImage(
            systemSymbolName: isLifecycleRunning ? "circle.fill" : "circle", accessibilityDescription: isLifecycleRunning ? "Running" : "Stopped")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .regular))
        statusDot.contentTintColor = isLifecycleRunning ? accentColor : .tertiaryLabelColor
        statusDot.toolTip = isLifecycleRunning ? "Running" : "Stopped"
        statusDot.setContentHuggingPriority(.required, for: .horizontal)
        footer.addArrangedSubview(statusDot)

        let titleLabel = NSTextField(labelWithString: workspace.displayName)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = sidebarPrimaryTextColor(isSelected: false, isArchived: false)
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

        let branch = (workspace.branch ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !branch.isEmpty {
            let branchIcon = NSImageView()
            branchIcon.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Branch")?
                .withSymbolConfiguration(.init(pointSize: 9, weight: .regular))
            branchIcon.contentTintColor = .tertiaryLabelColor
            branchIcon.setContentHuggingPriority(.required, for: .horizontal)
            let branchLabel = NSTextField(labelWithString: branch)
            branchLabel.font = .systemFont(ofSize: 11)
            branchLabel.textColor = .secondaryLabelColor
            branchLabel.lineBreakMode = .byTruncatingTail
            branchLabel.setAccessibilityIdentifier("workspace-detail-branch")
            footer.addArrangedSubview(branchIcon)
            footer.addArrangedSubview(branchLabel)
            footer.setCustomSpacing(3, after: branchIcon)
        }

        let dirLabel = NSTextField(labelWithString: workspace.dir)
        dirLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        dirLabel.textColor = .tertiaryLabelColor
        dirLabel.lineBreakMode = .byTruncatingMiddle
        dirLabel.toolTip = workspace.dir
        dirLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dirLabel.setAccessibilityIdentifier("workspace-detail-dir")
        footer.addArrangedSubview(dirLabel)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        footer.addArrangedSubview(spacer)

        let notes = (workspace.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let notesButton = footerActionButton(
            symbol: "note.text", tooltip: notes.isEmpty ? "Add notes" : notes, action: #selector(showWorkspaceNotesEditor(_:)))
        notesButton.contentTintColor = notes.isEmpty ? .tertiaryLabelColor : accentColor
        notesButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        notesButton.setAccessibilityIdentifier("workspace-detail-notes")
        footer.addArrangedSubview(notesButton)

        let launchOrRestartButton = footerActionButton(
            symbol: workspace.isRunning ? "arrow.clockwise.circle" : "play.circle", tooltip: workspace.isRunning ? "Restart" : "Launch",
            action: workspace.isRunning ? #selector(restartWorkspace(_:)) : #selector(launchWorkspace(_:)))
        launchOrRestartButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        launchOrRestartButton.setAccessibilityIdentifier("workspace-detail-launch-restart")
        footer.addArrangedSubview(launchOrRestartButton)

        let stopButton = footerActionButton(symbol: "stop.circle", tooltip: "Stop", action: #selector(stopWorkspace(_:)))
        stopButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        stopButton.setAccessibilityIdentifier("workspace-detail-stop")
        footer.addArrangedSubview(stopButton)

        let overflowButton = footerActionButton(symbol: "ellipsis.circle", tooltip: "More actions", action: #selector(showWorkspaceOverflowMenu(_:)))
        overflowButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        overflowButton.setAccessibilityIdentifier("workspace-detail-overflow")
        footer.addArrangedSubview(overflowButton)
    }

    private func footerActionButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) ?? NSImage(), target: self, action: action)
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
        guard let footer = workspaceDetailFooterRow else { return }
        for view in footer.arrangedSubviews {
            footer.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    /// Opens the notes editor in a popover anchored to the footer's notes button.
    /// Saving routes through the same workspace-metadata mutation the detail header's
    /// inline editor used.
    @objc private func showWorkspaceNotesEditor(_ sender: NSButton) {
        guard let workspaceID = sender.identifier?.rawValue, let (_, workspace) = findWorkspace(id: workspaceID) else { return }
        workspaceNotesPopover?.close()

        let textView = makeEditableTextView()
        textView.string = workspace.notes ?? ""
        textView.font = .systemFont(ofSize: 12)
        textView.setAccessibilityIdentifier("workspace-detail-notes-input")
        textView.onSave = { [weak self, weak textView] in
            guard let self, let textView else { return }
            self.saveWorkspaceNotes(workspaceID: workspaceID, text: textView.string)
        }
        textView.onCancel = { [weak self] in
            self?.workspaceNotesPopover?.close()
            self?.workspaceNotesPopover = nil
        }
        let scrollView = scrollableTextView(textView, height: 88)

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
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            scrollView.widthAnchor.constraint(equalToConstant: 320),
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
                showDeviceNotLoadedError()
                return
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let response = try SpacesDeviceClient.updateWorkspaceMetadata(
                workspaceID: workspaceID, notes: trimmed.isEmpty ? nil : trimmed, updatesNotes: true, device: device,
                clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
            workspaceNotesPopover?.close()
            workspaceNotesPopover = nil
            applyDeviceMutationResponse(response, selectedWorkspaceID: workspaceID)
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
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.textColor = .labelColor
        stack.addArrangedSubview(title)

        let workspaceDeviceName = deviceSections.first(where: { $0.deviceID == workspace.deviceID })?.deviceName ?? localDeviceName
        let detail = NSTextField(labelWithString: "Spaces is loading workspace details from \(workspaceDeviceName).")
        detail.font = .systemFont(ofSize: 12)
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
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = sidebarPrimaryTextColor(isSelected: false, isArchived: false)
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
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = workspaceSetupStatusColor(setupState.status)

        let headerRow = NSStackView(views: [titleLabel, NSView(), statusIcon, statusLabel])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8

        let dirField = NSTextField(string: workspace.dir)
        dirField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
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
            tooltip: "Run workspace setup", action: #selector(runWorkspaceSetupFromDetail(_:)), primary: setupState.status != .running)
        runButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        runButton.isEnabled = setupState.status != .running
        runButton.setAccessibilityIdentifier("workspace-setup-run")

        let terminalButton = actionButton(
            title: "Terminal", symbol: "terminal", tooltip: "Open a workspace terminal", action: #selector(openWorkspaceTerminal(_:)), primary: false)
        terminalButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        terminalButton.setAccessibilityIdentifier("workspace-setup-terminal")

        let revealButton = actionButton(
            title: "Reveal", symbol: "folder", tooltip: "Reveal workspace in Finder", action: #selector(revealDirectoryInFinder(_:)), primary: false)
        revealButton.identifier = NSUserInterfaceItemIdentifier(workspace.dir)
        revealButton.isEnabled = isLocalWorkspace(workspace)
        revealButton.setAccessibilityIdentifier("workspace-setup-reveal")

        let hasLogTail = logTail?.isEmpty == false
        let hasLocalLogFile = isLocalWorkspace(workspace) && setupState.logPath?.isEmpty == false

        // Copy reflects the displayed log content so it works for remote workspaces too; Open opens
        // the log file on disk, which is only reachable for a local workspace.
        let copyLogButton = actionButton(
            title: "Copy Log", symbol: "doc.on.doc", tooltip: "Copy setup log", action: #selector(copyWorkspaceSetupLog(_:)), primary: false)
        copyLogButton.isEnabled = hasLogTail
        copyLogButton.setAccessibilityIdentifier("workspace-setup-copy-log")

        let openLogButton = actionButton(
            title: "Open Log", symbol: "doc.text.magnifyingglass", tooltip: "Open setup log", action: #selector(openWorkspaceSetupLog(_:)),
            primary: false)
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
                    if let device = deviceRecord(forDeviceID: deviceID(forProjectID: project.id)),
                        let current = deviceProjectSummary(projectID: project.id)?.config
                    {
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        let updated = SpacesDeviceProjectConfig(
                            setupScript: trimmed.isEmpty ? nil : value, stopScript: current.stopScript, ports: current.ports,
                            processes: current.processes, browserSessions: current.browserSessions, agentLaunchers: current.agentLaunchers)
                        let response = try SpacesDeviceClient.updateProjectConfig(
                            projectID: project.id, config: updated, device: device,
                            clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                        applyDeviceMutationResponse(response, selectedWorkspaceID: workspace.id)
                    } else {
                        showDeviceNotLoadedError()
                    }
                } catch { showError(error) }
            }
            stack.addArrangedSubview(setupScriptSection.view)
            constrainFormFieldToFillWidth(setupScriptSection.view, in: stack)
        }

        showScrollableDetailStack(stack)
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
        labelField.font = .systemFont(ofSize: 11, weight: .semibold)
        labelField.textColor = .tertiaryLabelColor
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.widthAnchor.constraint(equalToConstant: 62).isActive = true
        labelField.setContentHuggingPriority(.required, for: .horizontal)

        let valueField = NSTextField(labelWithString: value)
        valueField.font = label == "Log" ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 11)
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
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let text = content ?? ""
        textView.string = text.isEmpty ? "No setup log output." : text
        textView.setAccessibilityIdentifier("workspace-setup-log-tail")
        workspaceSetupLogTextView = textView
        let scrollView = scrollableTextView(textView, height: 240)
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
        case .running: return sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
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

    nonisolated static func codingAgentWindowTitleByAgentID(agentWindows: [AgentWindowRecord], trackedWindows: [WindowRecord]) -> [String: String] {
        agentWindows.reduce(into: [:]) { result, agentWindow in
            guard
                let window = trackedWindows.first(where: {
                    guard $0.role == "terminal" else { return false }
                    if let trackingID = agentWindow.terminalTrackingID, !trackingID.isEmpty, $0.terminalTrackingID == trackingID { return true }
                    if let nativeID = agentWindow.terminalNativeID, !nativeID.isEmpty, $0.terminalNativeID == nativeID { return true }
                    return false
                })
            else { return }

            if isAdHocCodingAgent(agentWindow) {
                if let detail = window.detail?.trimmingCharacters(in: .whitespacesAndNewlines), !detail.isEmpty {
                    let label = agentWindow.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if normalizedRunRowName(detail) != normalizedRunRowName(label) { result[agentWindow.id] = detail }
                }
                return
            }

            let title =
                (window.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? (window.detail?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            if let title { result[agentWindow.id] = title }
        }
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

    private func clearActiveAddProjectFormState() {
        discardActiveAddProjectPreparedSourceIfNeeded()
        if let activeAddProjectFormTag { AddProjectFieldCache.shared.cache[activeAddProjectFormTag] = nil }
        activeAddProjectFormTag = nil
    }

    private func clearActiveAddWorkspaceFormState() {
        if let activeAddWorkspaceFormTag { AddWorkspaceFieldCache.shared.cache[activeAddWorkspaceFormTag] = nil }
        activeAddWorkspaceFormTag = nil
    }

    func clearActiveAddFormStateAndCloseWindows() {
        clearActiveAddProjectFormState()
        clearActiveAddWorkspaceFormState()
        closeVisibleAddFormWindows()
        flushDeferredSidebarReloadsIfNeeded()
    }

    private func closeVisibleAddFormWindows() {
        if addProjectWindow?.isVisible == true { addProjectWindow?.close() }
        if addWorkspaceWindow?.isVisible == true { addWorkspaceWindow?.close() }
        if projectSettingsWindow?.isVisible == true { projectSettingsWindow?.close() }
    }

    private func label(text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    func helpTextLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        // Without lowered horizontal compression resistance the label's intrinsic width becomes a hard
        // floor, so a long unbreakable token (e.g. a file path in an error message) forces the whole
        // container — and the resizable settings window — wider. Let it shrink and wrap instead.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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

    func windowRow(
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
        fputs("spaces: window_row_click \(message)\n", stderr)
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

    /// Editors offered in settings, filtered to those installed on this Mac. Detection and
    /// launch both key off the bundle identifier so an app rename (e.g. Windsurf → Devin
    /// Desktop) does not require a path or display-name update here.
    func installedEditorOptions() -> [EditorPreference] { [.vscode, .devin, .zed].filter(isEditorInstalled) }

    private func isEditorInstalled(_ editor: EditorPreference) -> Bool {
        guard let bundleID = editor.bundleIdentifier else { return false }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
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

    func footerShortcutHint(for setting: ShortcutSetting) -> String {
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
        case "minus": return "-"
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

    func iconButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.toolTip = tooltip
        return button
    }

    func actionButton(title: String, symbol: String?, tooltip: String, action: Selector, primary: Bool) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = primary ? .rounded : .texturedRounded
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
        }
        button.toolTip = tooltip
        if primary { stylePrimaryActionButton(button, title: title) }
        return button
    }

    private func stylePrimaryActionButton(_ button: NSButton, title: String) {
        Theme.applyPrimaryStyle(to: button)
        if let image = button.image { button.image = image.withSymbolConfiguration(.init(paletteColors: [Theme.primaryButtonText])) }
    }

    func constrainFormFieldToFillWidth(_ view: NSView, in stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func labeledInputRow(label text: String, input: NSView, labelWidth: CGFloat = 108) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        let labelField = NSTextField(labelWithString: text)
        labelField.font = .systemFont(ofSize: 12, weight: .semibold)
        labelField.textColor = .secondaryLabelColor
        labelField.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([labelField.widthAnchor.constraint(equalToConstant: labelWidth)])
        labelField.setContentHuggingPriority(.required, for: .horizontal)
        labelField.setContentCompressionResistancePriority(.required, for: .horizontal)
        input.setContentHuggingPriority(.defaultLow, for: .horizontal)
        input.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(labelField)
        row.addArrangedSubview(input)
        return row
    }

    func showScrollableDetailStack(_ stack: NSStackView, in host: NSView? = nil) {
        let container = host ?? detailContainer
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

        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor), scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),

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

    func scrollableTextView(_ textView: NSTextView, height: CGFloat) -> NSScrollView {
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

    private func makeEditableTextView() -> InlineWorkspaceEditorTextView {
        let textView = InlineWorkspaceEditorTextView()
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
        projectID: String, setupScriptSection: ScriptSection, stopScriptSection: ScriptSection, portsSection: PortsSection,
        processesSection: ProcessesSection, browserSessionsSection: BrowserSessionsSection, agentLaunchersSection: AgentLaunchersSection,
        importButton: NSButton, exportButton: NSButton, discardImportedConfigButton: NSButton
    ) -> Int {
        let id = projectID.hashValue
        ProjectFieldCache.shared.cache[id] = ProjectFieldRefs(
            projectID: projectID, setupScriptSection: setupScriptSection, stopScriptSection: stopScriptSection, portsSection: portsSection,
            processesSection: processesSection, browserSessionsSection: browserSessionsSection, agentLaunchersSection: agentLaunchersSection,
            importButton: importButton, exportButton: exportButton, discardImportedConfigButton: discardImportedConfigButton)
        return id
    }

    private func storeAddProjectFields(
        sourceSegmented: NSSegmentedControl, localSourceSection: NSStackView, cloneSourceSection: NSStackView, dirField: NSTextField,
        repoURLField: NSTextField, setupScriptSection: ScriptSection, stopScriptSection: ScriptSection, portsSection: PortsSection,
        processesSection: ProcessesSection, browserSessionsSection: BrowserSessionsSection, agentLaunchersSection: AgentLaunchersSection,
        prepareButton: NSButton, progressiveInputViews: [NSView], createButton: NSButton
    ) -> Int {
        let id = UUID().uuidString.hashValue
        AddProjectFieldCache.shared.cache[id] = AddProjectFieldRefs(
            sourceSegmented: sourceSegmented, localSourceSection: localSourceSection, cloneSourceSection: cloneSourceSection, dirField: dirField,
            repoURLField: repoURLField, prepareButton: prepareButton, progressiveInputViews: progressiveInputViews, createButton: createButton,
            setupScriptSection: setupScriptSection, stopScriptSection: stopScriptSection, portsSection: portsSection,
            processesSection: processesSection, browserSessionsSection: browserSessionsSection, agentLaunchersSection: agentLaunchersSection)
        sourceSegmented.tag = id
        prepareButton.tag = id
        return id
    }

    private func storeAddWorkspaceFields(
        projectID: String, isGitRepo: Bool, branchModeSegmented: NSSegmentedControl?, existingBranchField: NSComboBox?, newBranchField: NSTextField?,
        baseBranchField: NSComboBox?, notesField: NSTextField?, autoNameState: AddWorkspaceAutoNameState?, createButton: NSButton
    ) -> Int {
        let id = UUID().uuidString.hashValue
        AddWorkspaceFieldCache.shared.cache[id] = AddWorkspaceFieldRefs(
            projectID: projectID, isGitRepo: isGitRepo, branchModeSegmented: branchModeSegmented, existingBranchField: existingBranchField,
            newBranchField: newBranchField, baseBranchField: baseBranchField, notesField: notesField, autoNameState: autoNameState,
            createButton: createButton)
        branchModeSegmented?.tag = id
        return id
    }

    @objc func reloadTapped() {
        // An explicit reload should refresh remotes immediately, bypassing the
        // per-device freshness gate in loadRemoteDeviceSections.
        reloadData(forceRemoteRefresh: true)
    }

    // MARK: - Device pairing forwarders
    // The device-section @objc actions stay here because their buttons/menus bind
    // their target to the host; they forward to `devicePairing`. `renderDeviceSettings`
    // and `currentDeviceControlResponse` forward for the Settings Devices section.
    @objc func showMobileConnection() { devicePairing.showMobileConnection() }
    @objc func openDevicePairingWindow() { devicePairing.openDevicePairingWindow() }
    @objc func pairIOSWithConnectedDevice(_ sender: NSButton) { devicePairing.pairIOSWithConnectedDevice(sender) }
    @objc func connectRemoteDeviceFromPairingPanel() { devicePairing.connectRemoteDeviceFromPairingPanel() }
    @objc func restartLocalDaemon() { devicePairing.restartLocalDaemon() }
    @objc func removeMacPairedDevice(_ sender: NSButton) { devicePairing.removeMacPairedDevice(sender) }
    @objc func beginClientDeviceRename(_ sender: NSMenuItem) { devicePairing.beginClientDeviceRename(sender) }
    func renderDeviceSettings(response: SpacesDeviceAPIControlResponse) { devicePairing.renderDeviceSettings(response: response) }
    func currentDeviceControlResponse() -> SpacesDeviceAPIControlResponse { devicePairing.currentDeviceControlResponse() }

    private func centeredPanelRow(_ view: NSView) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: container.centerXAnchor), view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func clientDatabase() throws -> SpacesClientDatabase { try SpacesClientDatabase.defaultDatabase() }

    /// Attention-item dismissals are per-client desktop state, so they live in the client
    /// database rather than the daemon's settings.
    func loadDismissedAlertsAttentionItemIDs() -> Set<String> {
        guard let raw = (try? clientDatabase().setting(key: SettingsKey.alertsDismissedAttentionItems)) ?? nil, !raw.isEmpty,
            let data = raw.data(using: .utf8), let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(decoded)
    }

    func storeDismissedAlertsAttentionItemIDs(_ ids: Set<String>) throws {
        guard !ids.isEmpty else {
            try clientDatabase().setSetting(key: SettingsKey.alertsDismissedAttentionItems, value: nil)
            return
        }
        let encoded = try JSONEncoder().encode(ids.sorted())
        try clientDatabase().setSetting(key: SettingsKey.alertsDismissedAttentionItems, value: String(decoding: encoded, as: UTF8.self))
    }

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
            let result: Result<SpacesDeviceAPIResponse, Error>?
            if let device = deviceForDaemonStateMutation() {
                result = await Self.deviceMutation(device: device) { device in
                    try SpacesDeviceClient.runWorkspaceSetup(
                        workspaceID: workspaceID, device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                }
            } else {
                result = nil
            }
            sender?.isEnabled = true
            if let result {
                switch result {
                case .success(let response): applyDeviceMutationResponse(response, selectedWorkspaceID: workspaceID)
                case .failure(let error): showError(error)
                }
            } else {
                showDeviceNotLoadedError()
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

    @objc private func addProject() { showAddProjectForm() }

    @objc func addWorkspace(_ sender: NSButton) {
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

    @objc private func saveProject(_ sender: NSButton) {
        commitEditing()
        guard let refs = ProjectFieldCache.shared.cache[sender.tag] else { return }
        guard confirmProjectImportWorkspaceSyncIfNeeded(refs) else { return }
        do {
            try persistProjectFields(refs)
            projectHasUnsavedChanges = false
            reloadData()
        } catch { showError(error) }
    }

    @objc private func exportProjectSpacesYAML(_ sender: NSButton) {
        commitEditing()
        guard let refs = ProjectFieldCache.shared.cache[sender.tag] else { return }
        guard !projectHasUnsavedChanges, !refs.hasOpenSectionEditor else {
            showInfoMessage(title: "Save project settings first", message: "Save or discard pending changes before exporting spaces.yaml.")
            return
        }
        do {
            if let device = deviceForDaemonStateMutation() {
                let response = try SpacesDeviceClient.exportProjectSpacesYAML(
                    projectID: refs.projectID, device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                applyDeviceMutationResponse(response)
                showInfoMessage(title: "Exported spaces.yaml", message: response.message)
                return
            }
            showDeviceNotLoadedError()
        } catch { showError(error) }
    }

    @objc private func importProjectSpacesYAML(_ sender: NSButton) {
        commitEditing()
        guard let refs = ProjectFieldCache.shared.cache[sender.tag] else { return }
        do {
            if let device = deviceForDaemonStateMutation() {
                let decision = presentProjectImportWorkspaceSyncPrompt()
                guard decision != .cancel else { return }
                let updateAllWorkspaces = decision == .updateAllWorkspaces
                let response = try SpacesDeviceClient.importProjectSpacesYAML(
                    projectID: refs.projectID, updateAllWorkspaces: updateAllWorkspaces, device: device,
                    clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                refs.hasPendingImportedConfig = false
                refs.pendingImportUpdateAllWorkspaces = false
                refs.importButton.isHidden = false
                refs.exportButton.isHidden = false
                refs.discardImportedConfigButton.isHidden = true
                projectHasUnsavedChanges = false
                applyDeviceMutationResponse(response)
                return
            }
            showDeviceNotLoadedError()
        } catch { showError(error) }
    }

    @objc private func discardProjectConfigChanges(_ sender: NSButton) {
        commitEditing()
        guard let refs = ProjectFieldCache.shared.cache[sender.tag] else { return }
        if let config = deviceProjectSummary(projectID: refs.projectID)?.config {
            hydrateProjectSettings(refs, from: config)
            refs.hasPendingImportedConfig = false
            refs.pendingImportUpdateAllWorkspaces = false
            refs.importButton.isHidden = false
            refs.exportButton.isHidden = false
            refs.discardImportedConfigButton.isHidden = true
            projectHasUnsavedChanges = false
            return
        }
        showDeviceNotLoadedError()
    }

    private func hydrateProjectSettings(_ refs: ProjectFieldRefs, from project: ProjectRecord) {
        refs.setupScriptSection.replace(value: project.setupScript ?? "")
        refs.stopScriptSection.replace(value: project.stopScript ?? "")
        refs.portsSection.replace(ports: project.ports)
        refs.processesSection.replace(processes: project.processes)
        refs.browserSessionsSection.replace(sessions: project.browserSessions)
        refs.agentLaunchersSection.replace(launchers: project.agentLaunchers)
    }

    private func hydrateProjectSettings(_ refs: ProjectFieldRefs, from config: SpacesDeviceProjectConfig) {
        let settings = Self.localProjectSettings(from: config)
        refs.setupScriptSection.replace(value: settings.setupScript ?? "")
        refs.stopScriptSection.replace(value: settings.stopScript ?? "")
        refs.portsSection.replace(ports: settings.ports)
        refs.processesSection.replace(processes: settings.processes)
        refs.browserSessionsSection.replace(sessions: settings.browserSessions)
        refs.agentLaunchersSection.replace(launchers: settings.agentLaunchers)
    }

    private func confirmProjectImportWorkspaceSyncIfNeeded(_ refs: ProjectFieldRefs) -> Bool {
        guard refs.hasPendingImportedConfig else { return true }
        return Self.applyProjectImportWorkspaceSyncDecision(presentProjectImportWorkspaceSyncPrompt(), to: refs)
    }

    private func presentProjectImportWorkspaceSyncPrompt() -> ProjectImportWorkspaceSyncDecision {
        let alert = NSAlert()
        alert.messageText = "Update workspaces?"
        alert.informativeText =
            "Save the imported spaces.yaml settings to this project. Apply the same settings to every workspace in this project, including archived workspaces?"
        alert.addButton(withTitle: "Update All Workspaces")
        alert.addButton(withTitle: "Project Only")
        alert.addButton(withTitle: "Cancel")
        return Self.projectImportWorkspaceSyncDecision(for: alert.runModal())
    }

    private func presentManagedDirectoryReplacementPrompt(candidates: [SpacesDeviceManagedDirectoryReplacementCandidate]) -> Bool {
        let paths = candidates.map(\.path).joined(separator: "\n")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = candidates.count == 1 ? "Replace existing managed folder?" : "Replace existing managed folders?"
        alert.informativeText = """
            Spaces found existing managed folders that are not registered to any project or workspace:

            \(paths)

            Replace them before continuing?
            """
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        let decision = Self.managedDirectoryReplacementDecision(for: alert.runModal())
        return Self.shouldStartManagedDirectoryReplacementFlow(candidateCount: candidates.count, decision: decision)
    }

    @objc private func deleteProject(_ sender: NSButton) {
        guard let projectID = sender.identifier?.rawValue, projects.contains(where: { $0.id == projectID }) else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete project?"
        alert.informativeText = """
            This removes the project and its workspaces from Spaces.
            If this project was cloned into ~/spaces/repos by Spaces, that project directory is deleted.
            For git projects, related workspace directories under ~/spaces/workspaces are also deleted.
            """
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        sender.isEnabled = false
        showOperationProgressOverlay(
            message: "Deleting project...", detail: "Removing the project and its managed workspaces.", context: .project(projectID))
        Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            defer {
                sender?.isEnabled = true
                hideOperationProgressOverlay()
            }
            if let device = deviceForDaemonStateMutation() {
                let result = await Self.deviceMutation(device: device) { device in
                    try SpacesDeviceClient.deleteProject(
                        projectID: projectID, device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                }
                switch result {
                case .success(let response):
                    projectHasUnsavedChanges = false
                    selectedProjectID = nil
                    selectedWorkspaceID = nil
                    closeProjectSettingsWindow()
                    applyDeviceMutationResponse(response)
                case .failure(let error): showError(error)
                }
            } else {
                showDeviceNotLoadedError()
            }
        }
    }

    @objc private func createProject(_ sender: NSButton) {
        guard let refs = AddProjectFieldCache.shared.cache[sender.tag] else { return }
        do {
            // The project is created on the device chosen in the form (local by
            // default); folder autocomplete and preview use the same device.
            if let device = deviceRecord(forDeviceID: refs.selectedDeviceID) {
                let projectDir: String?
                let gitURL: String?
                if refs.sourceSegmented.selectedSegment == 1 {
                    let repoURL = refs.repoURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !repoURL.isEmpty else { throw WorkspaceError.invalidArgument(message: "Git repository URL is required.") }
                    projectDir = nil
                    gitURL = repoURL
                } else {
                    let dir = refs.dirField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !dir.isEmpty else { return }
                    guard refs.preparedLocalDirectoryPath == dir else {
                        throw WorkspaceError.invalidArgument(message: "Enter the project directory before creating the project.")
                    }
                    projectDir = dir
                    gitURL = nil
                }
                let config = Self.deviceProjectConfig(from: refs)
                // The repository was already cloned by prepareGitProject; pass its handle so the
                // daemon adopts that clone instead of re-cloning. Clear it off the form so Cancel
                // or a window close during the in-flight create won't discard the clone that is
                // being consumed; on failure it is restored (or discarded) so it never leaks.
                let preparedGitProjectHandle = refs.preparedGitProjectHandle
                let preparedGitURL = refs.preparedGitURL
                refs.preparedGitProjectHandle = nil
                refs.preparedGitURL = nil
                refs.preparedGitDeviceID = nil
                refs.gitPreparationID = nil
                let originalTitle = sender.title
                sender.isEnabled = false
                sender.title = "Creating..."
                showOperationProgressOverlay(
                    message: "Creating project...",
                    detail: "Creating the project on \(deviceSection(id: refs.selectedDeviceID)?.deviceName ?? localDeviceName).", context: .global)
                Task { @MainActor [weak self, weak sender] in
                    guard let self else { return }
                    defer {
                        sender?.isEnabled = true
                        sender?.title = originalTitle
                        hideOperationProgressOverlay()
                        if isActiveAddProjectForm(refs) { updateAddProjectSourceUI(refs) }
                    }
                    let result = await Self.deviceMutation(device: device) { device in
                        try SpacesDeviceClient.createProject(
                            projectDir: projectDir, gitURL: gitURL, config: config, preparedGitProjectHandle: preparedGitProjectHandle,
                            device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                    }
                    switch result {
                    case .success(let response):
                        clearActiveAddFormStateAndCloseWindows()
                        selectedProjectID = response.projectID
                        selectedWorkspaceID = response.workspaceID
                        // A new project on a remote device belongs to that device's
                        // section; force a remote refresh so it lands there immediately
                        // instead of waiting out the per-device freshness gate.
                        if isRemoteDeviceID(refs.selectedDeviceID) {
                            requestSidebarReload(forceRemoteRefresh: true)
                        } else {
                            applyDeviceMutationResponse(response, selectedProjectID: response.projectID, selectedWorkspaceID: response.workspaceID)
                        }
                    case .failure(let error):
                        restoreOrDiscardPreparedGitProjectAfterCreateFailure(
                            refs: refs, handle: preparedGitProjectHandle, repoURL: preparedGitURL, device: device)
                        showError(error)
                    }
                }
                return
            }
            showDeviceNotLoadedError()
        } catch { showError(error) }
    }

    @objc private func projectSourceChanged(_ sender: NSSegmentedControl) {
        guard let refs = AddProjectFieldCache.shared.cache[sender.tag] else { return }
        if refs.sourceSegmented.selectedSegment == 0 { discardPreparedAddProjectGitSourceIfNeeded(refs) }
        updateAddProjectSourceUI(refs)
    }

    @objc private func prepareProjectSource(_ sender: NSButton) {
        guard let refs = AddProjectFieldCache.shared.cache[sender.tag] else { return }
        prepareAddProjectGitSource(refs)
    }

    private func updateAddProjectSourceUI(_ refs: AddProjectFieldRefs) {
        let cloneSelected = refs.sourceSegmented.selectedSegment == 1
        refs.localSourceSection.isHidden = cloneSelected
        refs.cloneSourceSection.isHidden = !cloneSelected
        let repoURL = refs.repoURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let gitPrepared = refs.preparedGitProjectHandle != nil && refs.preparedGitURL == repoURL
        let gitPreparing = refs.gitPreparationID != nil
        // The daemon clones the repo and returns its spaces.yaml config to pre-fill the form, so the
        // Clone step is shown for git sources on any device (local or remote).
        refs.prepareButton.isHidden = !cloneSelected
        refs.prepareButton.title = gitPreparing ? "Cloning..." : (gitPrepared ? "Cloned" : "Clone")
        refs.prepareButton.isEnabled = cloneSelected && !repoURL.isEmpty && !gitPrepared && !gitPreparing
        updateAddProjectProgressiveDisclosure(refs)
    }

    private func updateAddProjectProgressiveDisclosure(_ refs: AddProjectFieldRefs) {
        let hasPreparedSource = isAddProjectSourcePrepared(refs)
        for view in refs.progressiveInputViews { view.isHidden = !hasPreparedSource }
        refs.createButton.isEnabled = hasPreparedSource
    }

    private func isAddProjectSourcePrepared(_ refs: AddProjectFieldRefs) -> Bool {
        if refs.sourceSegmented.selectedSegment == 1 {
            let repoURL = refs.repoURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // A git source is prepared once the daemon has cloned it (handle held), so the form is
            // populated from spaces.yaml and Create can adopt the existing clone.
            return refs.gitPreparationID == nil && refs.preparedGitProjectHandle != nil && refs.preparedGitURL == repoURL
                && refs.preparedGitDeviceID == refs.selectedDeviceID
        }
        let directoryPath = refs.dirField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return !directoryPath.isEmpty && refs.preparedLocalDirectoryPath == directoryPath
    }

    nonisolated static func preparedGitProjectResultMatchesActiveRequest(
        isActiveForm: Bool, selectedSegment: Int, currentRepoURL: String, requestedRepoURL: String, currentDeviceID: String,
        requestedDeviceID: String, currentPreparationID: UUID?, completionPreparationID: UUID
    ) -> Bool {
        isActiveForm && selectedSegment == 1 && currentRepoURL == requestedRepoURL && currentDeviceID == requestedDeviceID
            && currentPreparationID == completionPreparationID
    }

    nonisolated static func localProjectPreviewResultMatchesActiveRequest(
        isActiveForm: Bool, selectedSegment: Int, currentDirectoryPath: String, requestedDirectoryPath: String
    ) -> Bool { isActiveForm && selectedSegment == 0 && currentDirectoryPath == requestedDirectoryPath }

    nonisolated static func preparedGitProjectMatchesCurrentSelection(
        preparedGitProjectHandle: String?, preparedGitURL: String?, preparedGitDeviceID: String?, currentRepoURL: String, selectedDeviceID: String,
        currentPreparationID: UUID?
    ) -> Bool {
        guard preparedGitProjectHandle != nil, currentPreparationID == nil else { return false }
        return preparedGitURL == currentRepoURL && preparedGitDeviceID == selectedDeviceID
    }

    nonisolated static func preparedGitProjectDiscardKey(repoURL: String?, deviceID: String) -> String? {
        guard let key = repoURL?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return "\(deviceID)\n\(key)"
    }

    private func isActiveAddProjectForm(_ refs: AddProjectFieldRefs) -> Bool {
        activeAddProjectFormTag == refs.createButton.tag && AddProjectFieldCache.shared.cache[refs.createButton.tag] === refs
    }

    private func addProjectRefs(forDirectoryField field: NSControl) -> AddProjectFieldRefs? {
        AddProjectFieldCache.shared.cache.values.first { $0.dirField === field }
    }

    private func scheduleAddProjectDirectorySuggestions(_ refs: AddProjectFieldRefs) {
        refs.directorySuggestionTask?.cancel()
        let query = refs.dirField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let device = deviceRecord(forDeviceID: refs.selectedDeviceID) else {
            refs.directoryCompletions = []
            return
        }
        refs.directorySuggestionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            let suggestions = await Self.deviceDirectorySuggestions(path: query, device: device)
            guard !Task.isCancelled, isActiveAddProjectForm(refs), refs.dirField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) == query
            else { return }
            let completions = suggestions.map { ($0 as NSString).lastPathComponent }
            refs.directoryCompletions = completions
            // Suppress re-popping the dropdown when the only match is the leaf already typed.
            let typedLeaf = (query as NSString).lastPathComponent
            let exactSingleMatch = completions.count == 1 && completions[0].localizedCaseInsensitiveCompare(typedLeaf) == .orderedSame
            guard !completions.isEmpty, !exactSingleMatch, let editor = refs.dirField.currentEditor() else { return }
            editor.complete(nil)
        }
    }

    public func control(
        _ control: NSControl, textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>
    ) -> [String] {
        guard let refs = addProjectRefs(forDirectoryField: control) else { return words }
        index.pointee = -1
        return refs.directoryCompletions
    }

    /// Validates the typed directory on the selected device and loads its `spaces.yaml` settings,
    /// debounced so it runs as the user types or picks a suggestion. Runs silently: a path that is
    /// not yet a valid project directory simply leaves Create disabled rather than surfacing an error.
    private func scheduleAddProjectDirectoryPreview(_ refs: AddProjectFieldRefs) {
        refs.directoryPreviewTask?.cancel()
        let directoryPath = refs.dirField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directoryPath.isEmpty, refs.preparedLocalDirectoryPath != directoryPath else { return }
        guard let device = deviceRecord(forDeviceID: refs.selectedDeviceID) else { return }
        refs.directoryPreviewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            let result = await Self.deviceProjectPreview(dir: directoryPath, device: device)
            guard !Task.isCancelled,
                Self.localProjectPreviewResultMatchesActiveRequest(
                    isActiveForm: isActiveAddProjectForm(refs), selectedSegment: refs.sourceSegmented.selectedSegment,
                    currentDirectoryPath: refs.dirField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    requestedDirectoryPath: directoryPath)
            else { return }
            switch result {
            case .success(let preview):
                refs.preparedLocalDirectoryPath = directoryPath
                hydrateAddProjectSettings(refs, from: preview.config)
            case .failure: refs.preparedLocalDirectoryPath = nil
            }
            updateAddProjectSourceUI(refs)
        }
    }

    private func prepareAddProjectGitSource(_ refs: AddProjectFieldRefs) {
        let repoURL = refs.repoURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !repoURL.isEmpty else {
            showError(WorkspaceError.invalidArgument(message: "Git repository URL is required."))
            return
        }
        guard refs.gitPreparationID == nil else {
            updateAddProjectSourceUI(refs)
            return
        }
        if refs.preparedGitProjectHandle != nil, refs.preparedGitURL == repoURL {
            updateAddProjectSourceUI(refs)
            return
        }
        guard let device = deviceRecord(forDeviceID: refs.selectedDeviceID) else {
            showDeviceNotLoadedError()
            return
        }
        let preparationID = UUID()
        refs.gitPreparationID = preparationID
        refs.preparedLocalDirectoryPath = nil
        refs.prepareButton.isEnabled = false
        let originalTitle = refs.prepareButton.title
        refs.prepareButton.title = "Cloning..."
        updateAddProjectProgressiveDisclosure(refs)
        showOperationProgressOverlay(
            message: "Cloning project...", detail: "Cloning repository and checking the default workspace for spaces.yaml.", context: .global)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if refs.gitPreparationID == preparationID {
                    refs.gitPreparationID = nil
                    refs.prepareButton.title = originalTitle
                }
                hideOperationProgressOverlay()
                updateAddProjectSourceUI(refs)
            }
            // Discard any repository prepared earlier for this form before preparing a new one.
            if let previousHandle = refs.preparedGitProjectHandle {
                let discardResult = await beginPreparedGitProjectDiscard(handle: previousHandle, repoURL: refs.preparedGitURL, device: device).value
                if case .failure(let error) = discardResult {
                    refs.preparedGitProjectHandle = nil
                    refs.preparedGitURL = nil
                    refs.preparedGitDeviceID = nil
                    showError(error)
                    return
                }
                refs.preparedGitProjectHandle = nil
                refs.preparedGitURL = nil
                refs.preparedGitDeviceID = nil
            }
            if let discardResult = await activePreparedGitProjectDiscardResult(repoURL: repoURL), case .failure(let error) = discardResult {
                showError(error)
                return
            }
            // The daemon clones to the project's final managed path and returns its spaces.yaml
            // config. If managed directories already exist it returns replacement candidates instead
            // of cloning, so confirm replacement and prepare again.
            var preparation: SpacesDeviceGitProjectPreparation
            switch await Self.prepareGitProjectResult(gitURL: repoURL, replaceExistingManagedDirectories: false, device: device) {
            case .failure(let error):
                refs.preparedGitProjectHandle = nil
                refs.preparedGitURL = nil
                refs.preparedGitDeviceID = nil
                showError(error)
                return
            case .success(let result): preparation = result
            }
            if !preparation.replacementCandidates.isEmpty {
                guard presentManagedDirectoryReplacementPrompt(candidates: preparation.replacementCandidates) else { return }
                switch await Self.prepareGitProjectResult(gitURL: repoURL, replaceExistingManagedDirectories: true, device: device) {
                case .failure(let error):
                    refs.preparedGitProjectHandle = nil
                    refs.preparedGitURL = nil
                    refs.preparedGitDeviceID = nil
                    showError(error)
                    return
                case .success(let result): preparation = result
                }
            }
            guard
                Self.preparedGitProjectResultMatchesActiveRequest(
                    isActiveForm: isActiveAddProjectForm(refs), selectedSegment: refs.sourceSegmented.selectedSegment,
                    currentRepoURL: refs.repoURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), requestedRepoURL: repoURL,
                    currentDeviceID: refs.selectedDeviceID, requestedDeviceID: device.id, currentPreparationID: refs.gitPreparationID,
                    completionPreparationID: preparationID)
            else {
                // The form moved on while cloning; discard the clone we just made.
                if let handle = preparation.preparedGitProjectHandle {
                    _ = await beginPreparedGitProjectDiscard(handle: handle, repoURL: repoURL, device: device).value
                }
                return
            }
            guard let handle = preparation.preparedGitProjectHandle, let config = preparation.config else {
                showError(WorkspaceError.invalidArgument(message: "Preparing the git project did not return a cloned repository."))
                return
            }
            refs.preparedGitProjectHandle = handle
            refs.preparedGitURL = repoURL
            refs.preparedGitDeviceID = device.id
            hydrateAddProjectSettings(refs, from: config)
        }
    }

    private func hydrateAddProjectSettings(_ refs: AddProjectFieldRefs, from config: SpacesDeviceProjectConfig) {
        let settings = Self.localProjectSettings(from: config)
        refs.setupScriptSection.replace(value: settings.setupScript ?? "")
        refs.stopScriptSection.replace(value: settings.stopScript ?? "")
        refs.portsSection.replace(ports: settings.ports)
        refs.processesSection.replace(processes: settings.processes)
        refs.browserSessionsSection.replace(sessions: settings.browserSessions)
        refs.agentLaunchersSection.replace(launchers: settings.agentLaunchers)
    }

    private func discardPreparedAddProjectGitSourceIfNeeded(_ refs: AddProjectFieldRefs) {
        guard let handle = refs.preparedGitProjectHandle else { return }
        let repoURL = refs.preparedGitURL
        let device = deviceRecord(forDeviceID: refs.selectedDeviceID)
        refs.preparedGitProjectHandle = nil
        refs.preparedGitURL = nil
        refs.preparedGitDeviceID = nil
        guard let device else { return }
        let discardTask = beginPreparedGitProjectDiscard(handle: handle, repoURL: repoURL, device: device)
        Task { @MainActor [weak self] in
            let result = await discardTask.value
            if case .failure(let error) = result { self?.showError(error) }
        }
    }

    /// Adoption of a prepared git clone failed, so the daemon-side clone still exists in the managed
    /// repo/workspace directories. If the add-project form is still open and hasn't been re-prepared,
    /// restore the handle to it so Cancel/retry can discard or reuse the clone. Otherwise (the form was
    /// dismissed mid-create, or a newer preparation replaced the handle) discard the orphaned clone here
    /// so it never leaks.
    private func restoreOrDiscardPreparedGitProjectAfterCreateFailure(
        refs: AddProjectFieldRefs, handle: String?, repoURL: String?, device: SpacesPairedDeviceRecord
    ) {
        guard let handle else { return }
        switch Self.preparedGitProjectCreateFailureAction(
            isActiveForm: isActiveAddProjectForm(refs), formHasPreparedHandle: refs.preparedGitProjectHandle != nil,
            formTargetsPreparationDevice: refs.selectedDeviceID == device.id)
        {
        case .restoreToForm:
            refs.preparedGitProjectHandle = handle
            refs.preparedGitURL = repoURL
            refs.preparedGitDeviceID = device.id
        case .discardOrphan: beginPreparedGitProjectDiscard(handle: handle, repoURL: repoURL, device: device)
        }
    }

    enum PreparedGitProjectCreateFailureAction: Equatable { case restoreToForm, discardOrphan }

    /// Decides what to do with a prepared git clone whose project create failed. Restore the handle to the
    /// form only when it is still the active form, nothing newer was prepared into it, and the form still
    /// targets the device the clone was prepared on, so Cancel/retry acts on the right daemon. Otherwise the
    /// captured clone is orphaned — the form was dismissed, a newer preparation replaced the handle, or the
    /// user switched the (still-editable) device picker mid-create so the form now points at a different
    /// daemon — and it must be discarded on its original device so it never leaks or targets the wrong daemon.
    nonisolated static func preparedGitProjectCreateFailureAction(isActiveForm: Bool, formHasPreparedHandle: Bool, formTargetsPreparationDevice: Bool)
        -> PreparedGitProjectCreateFailureAction
    { isActiveForm && !formHasPreparedHandle && formTargetsPreparationDevice ? .restoreToForm : .discardOrphan }

    private func discardActiveAddProjectPreparedSourceIfNeeded() {
        guard let activeAddProjectFormTag, let refs = AddProjectFieldCache.shared.cache[activeAddProjectFormTag] else { return }
        discardPreparedAddProjectGitSourceIfNeeded(refs)
    }

    private func discardActiveAddProjectPreparedSourceSynchronouslyIfNeeded() -> Result<Void, Error>? {
        guard let activeAddProjectFormTag, let refs = AddProjectFieldCache.shared.cache[activeAddProjectFormTag],
            let handle = refs.preparedGitProjectHandle, let device = deviceRecord(forDeviceID: refs.selectedDeviceID)
        else { return nil }
        refs.preparedGitProjectHandle = nil
        refs.preparedGitURL = nil
        refs.preparedGitDeviceID = nil
        do {
            _ = try SpacesDeviceClient.discardPreparedGitProject(
                preparedGitProjectHandle: handle, device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
            return .success(())
        } catch { return .failure(error) }
    }

    @discardableResult private func beginPreparedGitProjectDiscard(handle: String, repoURL: String?, device: SpacesPairedDeviceRecord) -> Task<
        Result<Void, Error>, Never
    > {
        let key = Self.preparedGitProjectDiscardKey(repoURL: repoURL, deviceID: device.id)
        let previousTask = key.flatMap { preparedGitProjectDiscardTasksByURL[$0]?.task }
        let task = Task<Result<Void, Error>, Never> {
            if let previousTask { _ = await previousTask.value }
            return await Self.discardPreparedGitProjectResult(preparedGitProjectHandle: handle, device: device)
        }
        guard let key else { return task }
        let id = UUID()
        preparedGitProjectDiscardTasksByURL[key] = PreparedGitProjectDiscardEntry(id: id, task: task)
        Task { @MainActor [weak self] in
            _ = await task.value
            guard let self, self.preparedGitProjectDiscardTasksByURL[key]?.id == id else { return }
            self.preparedGitProjectDiscardTasksByURL[key] = nil
        }
        return task
    }

    private func activePreparedGitProjectDiscardResult(repoURL: String) async -> Result<Void, Error>? {
        let deviceID =
            activeAddProjectFormTag.flatMap { AddProjectFieldCache.shared.cache[$0]?.selectedDeviceID } ?? SpacesPairedDeviceRecord.localDeviceID
        guard let key = Self.preparedGitProjectDiscardKey(repoURL: repoURL, deviceID: deviceID), let entry = preparedGitProjectDiscardTasksByURL[key]
        else { return nil }
        return await entry.task.value
    }

    private func defaultWorkspaceBaseBranch(project: ProjectSummary, branches: [String]) -> String? {
        if let configured = project.defaultBranch, !configured.isEmpty { return configured }
        if branches.contains("main") { return "main" }
        if branches.contains("master") { return "master" }
        return branches.first
    }

    private func defaultWorkspaceBaseBranchFast(project: ProjectSummary) -> String? {
        if let configured = project.defaultBranch, !configured.isEmpty { return configured }
        return "main"
    }

    private func addWorkspaceBranchMode(refs: AddWorkspaceFieldRefs) -> AddWorkspaceBranchMode {
        refs.branchModeSegmented?.selectedSegment == 0 ? .create : .existing
    }

    static func resolvedExistingWorkspaceBranchValue(existingBranchField: NSComboBox?) -> String {
        guard let existingBranchField else { return "" }
        if existingBranchField.indexOfSelectedItem >= 0, let selectedValue = existingBranchField.objectValueOfSelectedItem as? String {
            return selectedValue
        }
        return existingBranchField.stringValue
    }

    static func syncExistingWorkspaceBranchSelection(existingBranchField: NSComboBox?) {
        guard let existingBranchField else { return }
        let currentText = existingBranchField.stringValue
        let selectedIndex = existingBranchField.indexOfSelectedItem
        guard selectedIndex >= 0, let selectedValue = existingBranchField.objectValueOfSelectedItem as? String, selectedValue != currentText else {
            return
        }
        existingBranchField.deselectItem(at: selectedIndex)
        existingBranchField.stringValue = currentText
    }

    private func currentAddWorkspaceBranchValue(_ refs: AddWorkspaceFieldRefs) -> String {
        switch addWorkspaceBranchMode(refs: refs) {
        case .existing: Self.resolvedExistingWorkspaceBranchValue(existingBranchField: refs.existingBranchField)
        case .create: refs.newBranchField?.stringValue ?? ""
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
        refs.createButton.isEnabled = hasBranch
    }

    @objc private func addWorkspaceBranchModeChanged(_ sender: NSSegmentedControl) {
        guard let refs = AddWorkspaceFieldCache.shared.cache[sender.tag] else { return }
        handleAddWorkspaceBranchFieldChange(refs: refs)
        if addWorkspaceBranchMode(refs: refs) == .create {
            window.makeFirstResponder(refs.newBranchField)
        } else {
            window.makeFirstResponder(refs.existingBranchField)
        }
    }

    @objc private func addWorkspaceBranchFieldChanged(_ sender: NSControl) {
        for refs in AddWorkspaceFieldCache.shared.cache.values {
            guard refs.existingBranchField === sender || refs.newBranchField === sender else { continue }
            handleAddWorkspaceBranchFieldChange(refs: refs)
            return
        }
    }

    @objc private func createWorkspace(_ sender: NSButton) {
        guard let refs = AddWorkspaceFieldCache.shared.cache[sender.tag] else { return }
        do {
            let baseBranch = refs.baseBranchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = currentAddWorkspaceBranchValue(refs).trimmingCharacters(in: .whitespacesAndNewlines)
            let notes = refs.notesField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedNotes: String?
            if let notes, notes.isEmpty { resolvedNotes = nil } else { resolvedNotes = notes }
            if refs.isGitRepo, branch.isEmpty { throw WorkspaceError.invalidArgument(message: "Branch name is required for git projects.") }
            if refs.isGitRepo, baseBranch == nil || baseBranch?.isEmpty == true {
                throw WorkspaceError.invalidArgument(message: "Base branch is required for git projects.")
            }
            if refs.isGitRepo, addWorkspaceBranchMode(refs: refs) == .create, refs.autoNameState?.branchOptions.contains(branch) == true {
                throw WorkspaceError.invalidArgument(
                    message: "Branch '\(branch)' already exists. Choose it from Existing branch or enter a different new branch name.")
            }
            let workspaceTargetDeviceID = deviceID(forProjectID: refs.projectID)
            if let device = deviceRecord(forDeviceID: workspaceTargetDeviceID) {
                let input = WorkspaceCreateInput(
                    projectID: refs.projectID, branch: branch, baseBranch: baseBranch, notes: resolvedNotes, allowRemoteBranchLookup: true,
                    allowExistingBranchReuse: addWorkspaceBranchMode(refs: refs) == .existing, replaceExistingManagedDirectory: false)
                let originalTitle = sender.title
                sender.isEnabled = false
                sender.title = "Creating..."
                showOperationProgressOverlay(
                    message: "Creating workspace...",
                    detail: "Creating the workspace on \(deviceSection(id: workspaceTargetDeviceID)?.deviceName ?? localDeviceName).",
                    context: .project(refs.projectID))
                Task { @MainActor [weak self, weak sender] in
                    guard let self else { return }
                    defer {
                        sender?.isEnabled = true
                        sender?.title = originalTitle
                        hideOperationProgressOverlay()
                    }
                    let result = await Self.deviceMutation(device: device) { device in
                        try SpacesDeviceClient.createWorkspace(
                            projectID: input.projectID, branch: input.branch, baseBranch: input.baseBranch, notes: input.notes,
                            allowExistingBranchReuse: input.allowExistingBranchReuse, device: device,
                            clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                    }
                    switch result {
                    case .success(let response):
                        clearActiveAddFormStateAndCloseWindows()
                        selectedProjectID = refs.projectID
                        selectedWorkspaceID = response.workspaceID
                        lastSelectedRow = -1
                        applyDeviceMutationResponse(response, selectedProjectID: refs.projectID, selectedWorkspaceID: response.workspaceID)
                    case .failure(let error): showError(error)
                    }
                }
                return
            }
            showDeviceNotLoadedError()
        } catch { showError(error) }
    }

    public func controlTextDidChange(_ obj: Notification) {
        guard let changedField = obj.object as? NSTextField else { return }
        if changedField === commandPalette.commandPaletteSearchField {
            logHotkeyDebug("search_change query=\(changedField.stringValue)")
            commandPalette.applyCommandPaletteFilter()
            return
        }
        for refs in AddProjectFieldCache.shared.cache.values {
            guard refs.repoURLField === changedField else { continue }
            updateAddProjectSourceUI(refs)
            return
        }
        if let refs = addProjectRefs(forDirectoryField: changedField) {
            updateAddProjectSourceUI(refs)
            scheduleAddProjectDirectorySuggestions(refs)
            scheduleAddProjectDirectoryPreview(refs)
            return
        }
        for refs in AddWorkspaceFieldCache.shared.cache.values {
            guard refs.existingBranchField === changedField || refs.newBranchField === changedField else { continue }
            if let existingBranchField = refs.existingBranchField, existingBranchField === changedField {
                Self.syncExistingWorkspaceBranchSelection(existingBranchField: existingBranchField)
            }
            handleAddWorkspaceBranchFieldChange(refs: refs)
            return
        }
    }

    public func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let comboBox = notification.object as? NSComboBox else { return }
        for refs in AddWorkspaceFieldCache.shared.cache.values {
            guard refs.existingBranchField === comboBox else { continue }
            let selectedBranchValue = (comboBox.objectValueOfSelectedItem as? String) ?? comboBox.stringValue
            comboBox.stringValue = selectedBranchValue
            handleAddWorkspaceBranchFieldChange(refs: refs, branchValueOverride: selectedBranchValue)
            return
        }
    }

    private func handleAddWorkspaceBranchFieldChange(refs: AddWorkspaceFieldRefs, branchValueOverride: String? = nil) {
        updateAddWorkspaceBranchInputUI(refs: refs)
        let branchValue = branchValueOverride ?? currentAddWorkspaceBranchValue(refs)
        updateAddWorkspaceProgressiveDisclosure(refs: refs, branchValue: branchValue)
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

    @objc private func cancelProjectForm() { closeAddProjectWindow() }

    @objc private func launchWorkspace(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        sender.isEnabled = false
        Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            let result: Result<SpacesDeviceAPIResponse, Error>?
            if let device = deviceForWorkspaceMutation(workspaceID: id) {
                result = await Self.deviceMutation(device: device) { device in
                    try SpacesDeviceClient.launchWorkspace(
                        workspaceID: id, device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                }
            } else {
                result = nil
            }
            sender?.isEnabled = true
            if let result {
                switch result {
                case .success(let response): applyDeviceMutationResponse(response, selectedWorkspaceID: id)
                case .failure(let error): showError(error)
                }
            } else {
                showDeviceNotLoadedError()
            }
        }
    }

    @objc private func restartWorkspace(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        sender.isEnabled = false
        Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            let result: Result<SpacesDeviceAPIResponse, Error>?
            if let device = deviceForWorkspaceMutation(workspaceID: id) {
                result = await Self.deviceMutation(device: device) { device in
                    try SpacesDeviceClient.restartWorkspace(
                        workspaceID: id, device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                }
            } else {
                result = nil
            }
            sender?.isEnabled = true
            if let result {
                switch result {
                case .success(let response):
                    // Restart goes through the daemon stop path; the daemon does not own the
                    // client-side dedicated Chrome windows, so close them here too for a clean
                    // restarted state (a later browser focus then opens a fresh window).
                    self.closeLocalBrowserSessionWindows(workspaceID: id)
                    applyDeviceMutationResponse(response, selectedWorkspaceID: id)
                case .failure(let error): showError(error)
                }
            } else {
                showDeviceNotLoadedError()
            }
        }
    }

    @objc private func stopWorkspace(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        sender.isEnabled = false
        Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            let result: Result<SpacesDeviceAPIResponse, Error>?
            if let device = deviceForWorkspaceMutation(workspaceID: id) {
                result = await Self.deviceMutation(device: device) { device in
                    try SpacesDeviceClient.stopWorkspace(
                        workspaceID: id, device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                }
            } else {
                result = nil
            }
            sender?.isEnabled = true
            if let result {
                switch result {
                case .success(let response):
                    self.closeLocalBrowserSessionWindows(workspaceID: id)
                    applyDeviceMutationResponse(response, selectedWorkspaceID: id)
                case .failure(let error): showError(error)
                }
            } else {
                showDeviceNotLoadedError()
            }
        }
    }

    /// Closes the workspace browser-session tabs the app opened (in their dedicated Chrome windows)
    /// and clears their tracking rows. Browser-session windows are client/desktop-local, so the
    /// daemon cannot close them when a workspace stops — the GUI tears them down here. A no-op when
    /// the workspace has no tracked browser windows (e.g. a remote workspace, whose browser sessions
    /// open a URL without a dedicated tracked window).
    ///
    /// Called from two disjoint triggers: the GUI's own stop/restart/archive handlers (eager, and
    /// the only reliable signal for a restart's transient stop), and the sidebar's daemon-observed
    /// transition diff (the net for stop/archive initiated outside this GUI — CLI, MCP, the Device
    /// API, or another device). Idempotent: it clears the tracking rows, so a later reload that
    /// re-observes the same stopped workspace finds nothing to close.
    func closeLocalBrowserSessionWindows(workspaceID: String) {
        Task.detached(priority: .utility) {
            let store = ClientBrowserWindowIDStore()
            guard let tracked = try? store.windowIDs(workspaceID: workspaceID), !tracked.isEmpty else { return }
            let chrome = ChromeAdapter()
            // Gate on `isRunning()` (a no-Apple-Events check) so stopping a workspace never launches
            // Chrome: if the user already quit Chrome, the tracked tabs are gone — scripting Chrome
            // would only relaunch it. Just clear the tracking rows below.
            if chrome.isRunning() {
                // Close only the session's matching tab, never the whole window: the window may hold
                // other tabs the user opened, and a tracked id can be stale (Chrome reuses window
                // ids after a restart) so the URL must still match.
                for entry in tracked { _ = try? chrome.closeMatchingTabsInWindow(windowID: entry.windowID, urlPrefix: entry.targetURL) }
            }
            try? store.clearAll(workspaceID: workspaceID)
        }
    }

    @objc private func archiveWorkspace(_ sender: Any) {
        guard let id = Self.senderIdentifier(sender) else { return }
        guard let (project, workspace) = findWorkspace(id: id) else { return }
        if workspace.isDefault {
            showInfoMessage(
                title: "Default Workspace",
                message: "Default workspaces cannot be archived. Delete the project instead to remove all of its workspaces.")
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Archive workspace?"
        alert.informativeText =
            "Are you sure you want to archive \"\(workspace.displayName)\"? This will remove its git worktree and stop all running processes."
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
        alert.addButton(withTitle: "Archive")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let deleteLocalBranch = project.isGitRepo && deleteLocalBranchCheckbox.state == .on
        let deleteRemoteBranch = project.isGitRepo && deleteRemoteBranchCheckbox.state == .on
        let button = sender as? NSButton
        // Resolve the owning device before the optimistic removal below; once the row
        // is gone from workspacesByProject, deviceForWorkspaceMutation can no longer
        // find it and would fall back to the local device, misrouting remote archives.
        let device = deviceForMutation(deviceID: project.deviceID)
        let didOptimisticallyArchive = optimisticallyArchiveWorkspaceInSidebar(workspaceID: id)
        if !didOptimisticallyArchive { button?.isEnabled = false }
        showOperationProgressOverlay(
            message: "Archiving workspace...", detail: "Stopping runtime state and cleaning up workspace files.", context: .workspace(id))
        Task { @MainActor [weak self, weak button] in
            guard let self else { return }
            defer { hideOperationProgressOverlay() }
            if let device {
                let result = await Self.deviceMutation(device: device) { device in
                    try SpacesDeviceClient.archiveWorkspace(
                        workspaceID: id, deleteLocalBranch: deleteLocalBranch, deleteRemoteBranch: deleteRemoteBranch, device: device,
                        clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                }
                switch result {
                case .success(let response):
                    button?.isEnabled = true
                    self.closeLocalBrowserSessionWindows(workspaceID: id)
                    applyDeviceMutationResponse(response, selectedProjectID: project.id)
                case .failure(let error):
                    requestSidebarReload()
                    button?.isEnabled = true
                    showError(error)
                }
            } else {
                if didOptimisticallyArchive { requestSidebarReload() }
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

    @objc func revealDirectoryInFinder(_ sender: Any) {
        if showRemoteWorkspacePathActionErrorIfNeeded(.revealInFinder) { return }
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
    static func makeWorkspaceOverflowMenu(workspaceID: String, path: String, target: AnyObject?, isLocalDevice: Bool = true) -> NSMenu {
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
        // Reveal in Finder needs a path on this Mac, so it is offered only for
        // local-device workspaces; remote workspaces live on another daemon.
        if isLocalDevice {
            addItem(
                title: "Reveal in Finder", symbol: "folder", action: #selector(AppKitController.revealDirectoryInFinder(_:)), keyEquivalent: "f",
                modifiers: [.command, .shift], identifier: path)
        }
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
        let menu = Self.makeWorkspaceOverflowMenu(
            workspaceID: workspaceID, path: workspace.dir, target: self, isLocalDevice: isLocalWorkspace(workspace))
        let origin = NSPoint(x: 0, y: sender.bounds.maxY + 4)
        menu.popUp(positioning: nil, at: origin, in: sender)
    }

    private func parseProcesses(_ raw: String) -> [ProcessTemplate] {
        _ = raw
        return []
    }

    nonisolated static func browserSessionDisplayName(for targetURL: String?, sessions: [BrowserSession]) -> String? {
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

    func showError(_ error: Error) {
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

    private func showRemoteWorkspacePathActionErrorIfNeeded(_ action: WorkspacePathAction, workspaceID: String? = nil) -> Bool {
        // Editor/Finder actions need a path on this Mac; gate them when the affected
        // workspace lives on a remote device. The action carries its own workspace
        // id, which can differ from the selected row, so resolve the owning device
        // from it and fall back to the selection only for path-based callers.
        let targetDeviceID = workspaceID.map { deviceID(forWorkspaceID: $0) } ?? selectedRowDeviceID()
        guard let targetDeviceID, let section = deviceSections.first(where: { $0.deviceID == targetDeviceID }), !section.isLocal else { return false }
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

    private func openWorkspaceEditor(workspaceID: String) {
        do {
            guard let (_, workspace) = findWorkspace(id: workspaceID) else { throw WorkspaceError.invalidArgument(message: "Workspace not found.") }
            guard !workspace.isArchived else { throw WorkspaceError.invalidArgument(message: "Workspace is archived.") }
            let target = try resolveEditorLaunch(try clientAppConfig().editor)
            let deviceID = deviceID(forWorkspaceID: workspaceID)
            if isRemoteDeviceID(deviceID) {
                guard let device = deviceRecord(forDeviceID: deviceID), let sshHost = device.sshHost?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !sshHost.isEmpty
                else { throw WorkspaceError.invalidArgument(message: "Remote editor launch requires SSH settings for the paired device.") }
                switch target {
                case .vscode(let editor, let support):
                    guard ensureRemoteSSHCapability(editor: editor, support: support) else { return }
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
            hideAfterSuccessfulExternalWindowAction(.open(hidesApp: true))
        } catch { showError(error) }
    }

    /// Resolves the configured editor to a launchable CLI from its installed bundle,
    /// throwing a clear error when no editor is configured or it is not installed.
    private func resolveEditorLaunch(_ editor: EditorPreference?) throws -> EditorLaunchTarget {
        guard let editor, editor != .none, let bundleID = editor.bundleIdentifier else {
            throw WorkspaceError.configError(message: "Preferred editor is not configured.")
        }
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

    private enum WorkspaceTerminalOpenRoute: String {
        case button
        case shortcut
        case ipc
    }

    private func openWorkspaceTerminal(workspaceID: String, route: WorkspaceTerminalOpenRoute, completion: (() -> Void)? = nil) {
        let startedAt = Date()
        let workspaceDeviceID = deviceID(forWorkspaceID: workspaceID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { completion?() }
            if let device = deviceRecord(forDeviceID: workspaceDeviceID) {
                let result = await Self.deviceMutation(device: device) { device in
                    try SpacesDeviceClient.openWorkspaceTerminal(
                        workspaceID: workspaceID, device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                }
                switch result {
                case .success(let response):
                    applyDeviceMutationResponse(response, selectedWorkspaceID: workspaceID)
                    // A fresh ad hoc session opens as a new tab in the workspace's panel.
                    if let sessionID = response.sessionID,
                        let request = Self.deviceTerminalOpenRequest(
                            workspaceID: workspaceID, sessionID: sessionID, overview: response.overview ?? overview(forWorkspaceID: workspaceID))
                    {
                        panelCoordinator.openSessionInNewTab(request)
                    }
                    hideAfterSuccessfulExternalWindowAction(.open(hidesApp: false))
                    logPerfMetric(
                        "workspace_terminal_open_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                        success: true, detail: "route=\(route.rawValue)")
                case .failure(let error):
                    logPerfMetric(
                        "workspace_terminal_open_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                        success: false, detail: "route=\(route.rawValue)")
                    showError(error)
                }
                return
            }
            logPerfMetric(
                "workspace_terminal_open_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                success: false, detail: "route=\(route.rawValue)")
            showDeviceNotLoadedError()
        }
    }

    private func runWorkspaceProcess(workspaceID: String, processName: String) {
        let startedAt = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let device = deviceForWorkspaceMutation(workspaceID: workspaceID) {
                let result = await Self.deviceMutation(device: device) { device in
                    try SpacesDeviceClient.runWorkspaceProcess(
                        workspaceID: workspaceID, processKey: processName, processTemplateID: nil, device: device,
                        clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                }
                switch result {
                case .success(let response):
                    logPerfMetric(
                        "workspace_process_launch_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                        success: true, detail: "route=ipc name=\(processName)")
                    applyDeviceMutationResponse(response, selectedWorkspaceID: workspaceID)
                    hideAfterSuccessfulExternalWindowAction(.open(hidesApp: false))
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
            showDeviceNotLoadedError()
        }
    }

    private func stopWorkspaceProcess(workspaceID: String, processName: String) {
        let startedAt = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let device = deviceForWorkspaceMutation(workspaceID: workspaceID) {
                    let response = try SpacesDeviceClient.stopWorkspaceProcess(
                        workspaceID: workspaceID, processID: nil, processKey: processName, processTemplateID: nil, device: device,
                        clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                    logPerfMetric(
                        "workspace_process_stop_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                        success: true, detail: "route=ipc name=\(processName)")
                    applyDeviceMutationResponse(response, selectedWorkspaceID: workspaceID)
                    return
                }
                logPerfMetric(
                    "workspace_process_stop_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                    success: false, detail: "route=ipc name=\(processName)")
                showDeviceNotLoadedError()
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
                    let response = try SpacesDeviceClient.restartWorkspaceProcess(
                        workspaceID: workspaceID, processID: nil, processKey: processName, processTemplateID: nil, device: device,
                        clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                    logPerfMetric(
                        "workspace_process_restart_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                        success: true, detail: "route=ipc name=\(processName)")
                    applyDeviceMutationResponse(response, selectedWorkspaceID: workspaceID)
                    return
                }
                logPerfMetric(
                    "workspace_process_restart_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                    success: false, detail: "route=ipc name=\(processName)")
                showDeviceNotLoadedError()
            } catch {
                logPerfMetric(
                    "workspace_process_restart_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                    success: false, detail: "route=ipc name=\(processName)")
                showError(error)
            }
        }
    }

    private func launchWorkspaceAgent(workspaceID: String, launcherName: String) {
        let startedAt = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let device = deviceForWorkspaceMutation(workspaceID: workspaceID) {
                let result = await Self.deviceMutation(device: device) { device in
                    try SpacesDeviceClient.runCodingAgent(
                        workspaceID: workspaceID, agentName: launcherName, agentLauncherID: nil, device: device,
                        clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                }
                switch result {
                case .success(let response):
                    logPerfMetric(
                        "workspace_agent_launch_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                        success: true, detail: "route=ipc name=\(launcherName)")
                    applyDeviceMutationResponse(response, selectedWorkspaceID: workspaceID)
                    hideAfterSuccessfulExternalWindowAction(.open(hidesApp: false))
                case .failure(let error):
                    logPerfMetric(
                        "workspace_agent_launch_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                        success: false, detail: "route=ipc name=\(launcherName)")
                    showError(error)
                }
                return
            }
            logPerfMetric(
                "workspace_agent_launch_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false,
                detail: "route=ipc name=\(launcherName)")
            showDeviceNotLoadedError()
        }
    }

    private func openWorkspaceFinder(workspaceID: String) {
        if showRemoteWorkspacePathActionErrorIfNeeded(.revealInFinder, workspaceID: workspaceID) { return }
        guard let (_, workspace) = findWorkspace(id: workspaceID) else { return }
        let url = URL(fileURLWithPath: workspace.dir, isDirectory: true)
        if NSWorkspace.shared.open(url) { hideAfterSuccessfulExternalWindowAction(.open(hidesApp: true)) }
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
        guard desktopControlLease != nil else {
            logHotkeyDebug("setup skipped no_desktop_control_lease")
            teardownGlobalHotkey()
            return
        }
        guard let toggleShortcutSpec else {
            logHotkeyDebug("setup skipped missing_toggle_spec")
            teardownGlobalHotkey()
            return
        }
        logHotkeyDebug(
            "setup start toggle=\(toggleShortcutSpec) palette=\(String(describing: commandPaletteShortcutSpec)) next=\(String(describing: nextShortcutSpec)) previous=\(String(describing: previousShortcutSpec))"
        )
        registerHotkeys(
            toggle: toggleShortcutSpec, commandPalette: commandPaletteShortcutSpec, next: nextShortcutSpec, previous: previousShortcutSpec)
    }

    private func teardownGlobalHotkey() {
        logHotkeyDebug("teardown refs=\(hotkeyRefs.count) handler=\(hotkeyHandler == nil ? 0 : 1)")
        for ref in hotkeyRefs.values { UnregisterEventHotKey(ref) }
        hotkeyRefs.removeAll()
        if let hotkeyHandler { RemoveEventHandler(hotkeyHandler) }
        hotkeyHandler = nil
    }

    private func registerHotkeys(toggle: HotkeySpec, commandPalette: HotkeySpec?, next: HotkeySpec?, previous: HotkeySpec?) {
        teardownGlobalHotkey()
        let signature = OSType(UInt32(truncatingIfNeeded: "AMUX".utf8.reduce(0) { ($0 << 8) + UInt32($1) }))
        let target = GetEventDispatcherTarget()
        logHotkeyDebug("register begin signature=\(signature)")
        registerHotkey(spec: toggle, id: GlobalHotkey.toggle.rawValue, signature: signature, target: target)
        if let commandPalette {
            registerHotkey(spec: commandPalette, id: GlobalHotkey.openCommandPalette.rawValue, signature: signature, target: target)
        }
        if let next { registerHotkey(spec: next, id: GlobalHotkey.next.rawValue, signature: signature, target: target) }
        if let previous { registerHotkey(spec: previous, id: GlobalHotkey.previous.rawValue, signature: signature, target: target) }
        if let openEditorShortcutSpec {
            registerHotkey(spec: openEditorShortcutSpec, id: GlobalHotkey.openEditor.rawValue, signature: signature, target: target)
        }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            target, hotkeyHandlerProc, 1, &eventSpec, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), &hotkeyHandler)
        logHotkeyDebug("register handler_status=\(status) refs=\(hotkeyRefs.count) handler=\(hotkeyHandler == nil ? 0 : 1)")
    }

    private func registerHotkey(spec: HotkeySpec, id: UInt32, signature: OSType, target: EventTargetRef?) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(UInt32(spec.keyCode), spec.modifiersCarbon, hotKeyID, target, 0, &ref)
        logHotkeyDebug("register_hotkey id=\(id) spec=\(spec) status=\(status) ref=\(ref == nil ? 0 : 1)")
        if status == noErr, let ref { hotkeyRefs[id] = ref }
    }

    private func setupShortcutMonitor() {
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged { return self.handleLeaderShortcutCaptureFlagsChanged(event: event) ? nil : event }
            // A focused terminal pane owns every non-⌘ key (the pane translation
            // replaces the old terminal window's sendEvent hook); ⌘ chords run the app
            // shortcuts below and fall through to the pane's command handling at the end.
            let focusedPaneContent = self.panelCoordinator.contentOwning(responder: NSApp.keyWindow?.firstResponder)
            if let focusedPaneContent {
                self.panelCoordinator.noteContentFocused(focusedPaneContent)
                if Self.shortcutMonitorDisposition(eventModifiers: event.modifierFlags, firstResponderIsTerminalPane: true) == .passEventToTerminal {
                    return focusedPaneContent.handleKeyEvent(event) ? nil : event
                }
            }
            self.recordStartupInteraction(kind: "key_down")
            if self.handleShortcutCaptureEvent(event: event) { return nil }
            if self.handleNewWorkspaceShortcut(event: event) { return nil }
            if self.handleReloadShortcut(event: event) { return nil }
            if self.handleFormCancelShortcut(event: event) { return nil }
            if self.alerts.handleAlertsShortcut(event: event) { return nil }
            if let openSettingsShortcutSpec, matches(event: event, spec: openSettingsShortcutSpec) {
                self.showSettings()
                return nil
            }
            if self.commandPalette.handleCommandPaletteShortcut(event: event) { return nil }
            if self.handlePanelWindowCloseTabShortcut(event: event) { return nil }
            if self.handleFocusedTextInputShortcut(event: event) { return nil }
            if self.isTextInputFocused() { return event }
            if self.handleSidebarArrowNavigation(event: event) { return nil }
            if let openTerminalShortcutSpec, matches(event: event, spec: openTerminalShortcutSpec) {
                // In a global panel window the new tab opens there, targeting the
                // focused pane's workspace; otherwise it lands in the selected
                // workspace's panel.
                if let panelWindowID = self.panelCoordinator.panelWindowID(forWindow: NSApp.keyWindow) {
                    self.openNewTerminalTab(scope: .globalWindow(panelWindowID: panelWindowID))
                } else if let workspaceID = self.selectedWorkspaceID {
                    self.openWorkspaceTerminal(workspaceID: workspaceID, route: .shortcut)
                }
                return nil
            }
            if let openFinderShortcutSpec, matches(event: event, spec: openFinderShortcutSpec) {
                if let workspaceID = self.selectedWorkspaceID { self.openWorkspaceFinder(workspaceID: workspaceID) }
                return nil
            }
            if let windowIndex = windowShortcutIndex(for: event) {
                self.logWindowShortcutProfile("stage=monitor_schedule index=\(windowIndex)")
                let startedAt = Date()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.logWindowShortcutProfile("stage=monitor_dispatch index=\(windowIndex)")
                    await self.runWindowShortcut(index: windowIndex, startedAt: startedAt)
                    self.logWindowShortcutProfile("stage=monitor_after_handler index=\(windowIndex)")
                }
                return nil
            }
            // App shortcuts didn't claim this ⌘ chord; give the focused pane's terminal
            // command handling a chance (the old terminal window's performKeyEquivalent).
            if let focusedPaneContent, focusedPaneContent.handleCommandKeyEquivalent(event) { return nil }
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
                setupGlobalHotkey()
                refreshDesktopControlStatusUI()
            case .busy(let owner):
                passiveDesktopControlOwner = owner
                refreshDesktopControlStatusUI()
            }
        } catch { logHotkeyDebug("desktop_control_recovery_failed error=\(error.localizedDescription)") }
    }

    private func refreshDesktopControlStatusUI() {
        guard let window else { return }
        if passiveDesktopControlOwner != nil {
            window.subtitle = "Global shortcuts unavailable while another Spaces instance owns desktop control."
        } else {
            window.subtitle = ""
        }
    }

    nonisolated static func shouldAttemptDesktopControlRecovery(passiveOwnerPID: Int32?, terminatedApplicationPID: Int32?) -> Bool {
        guard let passiveOwnerPID, let terminatedApplicationPID else { return false }
        return passiveOwnerPID == terminatedApplicationPID
    }

    enum ShortcutMonitorDisposition: Equatable, Sendable {
        /// Return the event untouched so the focused terminal pane receives it (plain
        /// keys, ctrl chords, arrows — anything without ⌘).
        case passEventToTerminal
        /// Run the app-shortcut chain; unhandled events still fall through to the
        /// window, whose key routing forwards them to the focused pane.
        case runAppShortcuts
    }

    /// Keyboard routing for the local shortcut monitor once terminals live inside app
    /// windows as panes: a focused terminal owns every non-⌘ key, while ⌘ chords run
    /// the app shortcuts first. With no terminal focused, all shortcuts run as before.
    nonisolated static func shortcutMonitorDisposition(eventModifiers: NSEvent.ModifierFlags, firstResponderIsTerminalPane: Bool)
        -> ShortcutMonitorDisposition
    {
        guard firstResponderIsTerminalPane else { return .runAppShortcuts }
        return eventModifiers.contains(.command) ? .runAppShortcuts : .passEventToTerminal
    }

    /// ⌘W in a global panel window closes the selected tab (the last tab closes the
    /// window); everywhere else ⌘W keeps its default behavior.
    private func handlePanelWindowCloseTabShortcut(event: NSEvent) -> Bool {
        guard
            Self.isPanelWindowCloseTabShortcut(
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                eventModifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask)),
            let panelWindowID = panelCoordinator.panelWindowID(forWindow: NSApp.keyWindow)
        else { return false }
        panelCoordinator.closeSelectedTab(panelWindowID: panelWindowID)
        return true
    }

    /// Plain ⌘W — no other chord modifiers, so terminal/app chords like ⌘⇧W or ⌥⌘W
    /// stay untouched.
    nonisolated static func isPanelWindowCloseTabShortcut(charactersIgnoringModifiers: String?, eventModifiers: NSEvent.ModifierFlags) -> Bool {
        guard charactersIgnoringModifiers?.lowercased() == "w" else { return false }
        return eventModifiers.intersection([.command, .option, .control, .shift]) == .command
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
        if addWorkspaceWindow?.isVisible == true {
            closeAddWorkspaceWindow()
            return true
        }
        if addProjectWindow?.isVisible == true {
            closeAddProjectWindow()
            return true
        }
        return false
    }

    private func handleNewWorkspaceShortcut(event: NSEvent) -> Bool {
        guard let addWorkspaceShortcutSpec, matches(event: event, spec: addWorkspaceShortcutSpec) else { return false }
        if showingAlerts, windowShortcutIndex(for: event) != nil { return false }
        if activeAddWorkspaceFormTag != nil { return true }
        addWorkspaceFromShortcut()
        return true
    }

    private func handleReloadShortcut(event: NSEvent) -> Bool {
        guard let reloadShortcutSpec, matches(event: event, spec: reloadShortcutSpec) else { return false }
        reloadData(forceRemoteRefresh: true)
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

    func shortcutModifiers(from flags: NSEvent.ModifierFlags) -> Set<HotkeyModifier> {
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

    nonisolated static func sidebarArrowSelectionTarget(
        visibleWorkspaceIDsByProject: [(projectID: String, workspaceIDs: [String])], hiddenWorkspaceIDs: [String], selectedProjectID: String?,
        selectedWorkspaceID: String?, showingAlerts: Bool, direction: Int
    ) -> SidebarArrowSelectionTarget? {
        guard direction == -1 || direction == 1 else { return nil }
        let visibleWorkspaceIDs = visibleWorkspaceIDsByProject.flatMap(\.workspaceIDs) + hiddenWorkspaceIDs
        if showingAlerts {
            guard direction > 0, let firstWorkspaceID = visibleWorkspaceIDs.first else { return nil }
            return .workspace(firstWorkspaceID)
        }
        if let selectedWorkspaceID, let currentIndex = visibleWorkspaceIDs.firstIndex(of: selectedWorkspaceID) {
            let targetIndex = currentIndex + direction
            if targetIndex < 0 { return .alerts }
            guard targetIndex < visibleWorkspaceIDs.count else { return nil }
            return .workspace(visibleWorkspaceIDs[targetIndex])
        }
        guard let selectedProjectID, let projectIndex = visibleWorkspaceIDsByProject.firstIndex(where: { $0.projectID == selectedProjectID }) else {
            return nil
        }
        if direction < 0 {
            let priorProjects = visibleWorkspaceIDsByProject[..<projectIndex].reversed()
            for project in priorProjects { if let workspaceID = project.workspaceIDs.last { return .workspace(workspaceID) } }
            return .alerts
        }
        for project in visibleWorkspaceIDsByProject[(projectIndex + 1)...] {
            if let workspaceID = project.workspaceIDs.first { return .workspace(workspaceID) }
        }
        if let hiddenWorkspaceID = hiddenWorkspaceIDs.first { return .workspace(hiddenWorkspaceID) }
        return nil
    }

    private func handleGlobalHotkey(id: UInt32) {
        guard let hotkey = GlobalHotkey(rawValue: id) else { return }
        logHotkeyDebug("handle id=\(id) hotkey=\(hotkey) \(hotkeyWindowStateSummary())")
        switch hotkey {
        case .toggle: toggleWindowFromHotkey()
        case .openCommandPalette: commandPalette.toggleCommandPaletteFromHotkey()
        case .next: focusGlobalWindowNavigation(direction: 1)
        case .previous: focusGlobalWindowNavigation(direction: -1)
        case .openEditor: openGlobalEditorFromHotkey()
        }
    }

    private func openGlobalEditorFromHotkey() {
        guard let workspaceID = globalEditorWorkspaceID() else { return }
        openWorkspaceEditor(workspaceID: workspaceID)
    }

    private func globalEditorWorkspaceID() -> String? {
        if let workspaceID = clientWorkspaceIDForFocusedWindow() { return workspaceID }
        if NSApp.isActive, let selectedWorkspaceID { return selectedWorkspaceID }
        if let workspaceID = clientActiveWorkspaceID() { return workspaceID }
        return nil
    }

    nonisolated static func activationSelectionTarget(focusedWorkspaceID: String?) -> SidebarArrowSelectionTarget {
        if let focusedWorkspaceID { return .workspace(focusedWorkspaceID) }
        return .alerts
    }

    /// The macOS client's app config is just the editor preference (client-local in the client
    /// database). The port range is daemon-owned and never read by the GUI, so it carries a
    /// placeholder rather than a daemon-DB read — keeping config sourcing off the orchestrator.
    nonisolated static func clientAppConfig() throws -> AppConfig {
        let editor = try SpacesClientDatabase.defaultDatabase().setting(key: SettingsKey.appEditor).flatMap(EditorPreference.init(rawValue:))
        return AppConfig(editor: editor, portRange: .default)
    }

    private func clientAppConfig() throws -> AppConfig {
        let editor = try clientDatabase().setting(key: SettingsKey.appEditor).flatMap(EditorPreference.init(rawValue:))
        return AppConfig(editor: editor, portRange: .default)
    }

    private func clientActiveWorkspaceID() -> String? { try? clientDatabase().setting(key: SettingsKey.activeWorkspaceID) }

    nonisolated static func setClientActiveWorkspaceID(_ workspaceID: String?) {
        try? SpacesClientDatabase.setDefaultSetting(key: SettingsKey.activeWorkspaceID, value: workspaceID)
    }

    func loadShortcutSpecs() {
        if let modifiers = try? shortcutSettingResolver().leaderModifiers() {
            shortcutLeaderModifiers = modifiers
        } else {
            shortcutLeaderModifiers = (try? HotkeySpec.parseModifierSet(SettingsKey.defaultGUILeaderHotkey)) ?? [.cmd, .alt]
        }
        toggleShortcutSpec = loadShortcutSpec(setting: .guiHotkey)
        commandPaletteShortcutSpec = loadShortcutSpec(setting: .guiCommandPaletteHotkey)
        alerts.alertsShortcutSpec = loadShortcutSpec(setting: .guiAlertsShortcut)
        addWorkspaceShortcutSpec = loadShortcutSpec(setting: .guiAddWorkspaceShortcut)
        reloadShortcutSpec = loadShortcutSpec(setting: .guiReloadShortcut)
        nextShortcutSpec = loadShortcutSpec(setting: .guiNextShortcut)
        previousShortcutSpec = loadShortcutSpec(setting: .guiPreviousShortcut)
        openEditorShortcutSpec = loadShortcutSpec(setting: .guiOpenEditorShortcut)
        openTerminalShortcutSpec = loadShortcutSpec(setting: .guiOpenTerminalShortcut)
        openFinderShortcutSpec = loadShortcutSpec(setting: .guiOpenFinderShortcut)
        openSettingsShortcutSpec = loadShortcutSpec(setting: .guiOpenSettingsShortcut)
        windowShortcutSpec = loadShortcutSpec(setting: .guiWindowShortcut)
    }

    private func loadShortcutSpec(setting: ShortcutSetting) -> HotkeySpec? {
        if let stored = try? HotkeySpec.parse(shortcutRawValue(for: setting)) { return stored }
        return try? HotkeySpec.parse(setting.defaultSpec)
    }

    private func shortcutRawValue(for setting: ShortcutSetting) throws -> String { try shortcutSettingResolver().rawValue(for: setting) }

    private func setShortcutSetting(setting: ShortcutSetting, value: String?) throws {
        let normalized = try shortcutSettingResolver().normalizedValue(for: setting, rawValue: value)
        try clientDatabase().setSetting(key: setting.settingKey, value: normalized)
    }

    private func shortcutSettingResolver() -> ShortcutSettingResolver {
        ShortcutSettingResolver(value: { key in try self.clientDatabase().setting(key: key) })
    }

    private func shortcutSpec(for setting: ShortcutSetting) -> HotkeySpec? {
        switch setting {
        case .guiHotkey: return toggleShortcutSpec
        case .guiCommandPaletteHotkey: return commandPaletteShortcutSpec
        case .guiLeaderHotkey: return nil
        case .guiAlertsShortcut: return alerts.alertsShortcutSpec
        case .guiAddWorkspaceShortcut: return addWorkspaceShortcutSpec
        case .guiReloadShortcut: return reloadShortcutSpec
        case .guiNextShortcut: return nextShortcutSpec
        case .guiPreviousShortcut: return previousShortcutSpec
        case .guiOpenEditorShortcut: return openEditorShortcutSpec
        case .guiOpenTerminalShortcut: return openTerminalShortcutSpec
        case .guiOpenFinderShortcut: return openFinderShortcutSpec
        case .guiOpenSettingsShortcut: return openSettingsShortcutSpec
        case .guiWindowShortcut: return windowShortcutSpec
        }
    }

    func matches(event: NSEvent, spec: HotkeySpec) -> Bool {
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

    func performWindowFocus(_ request: WindowFocusRequest) async {
        guard let action = await executeWindowFocus(request) else { return }
        reloadData()
        hideAfterSuccessfulExternalWindowAction(action)
    }

    /// Resolves an explicit focus request against its workspace's overview and focuses the
    /// client's window for it, returning the resulting action (or nil if nothing was
    /// focused). Shared by the command palette and attention-item focus. A missing window
    /// is reopened by the executor itself, so there is no separate recovery prompt.
    func executeWindowFocus(_ request: WindowFocusRequest) async -> ExternalWindowAction? {
        guard let overview = overview(forWorkspaceID: request.workspaceID) else { return nil }
        return await executeWindowFocusResolution(Self.windowFocusResolution(for: request, overview: overview))
    }

    private func runWindowShortcut(index: Int, startedAt: Date) async {
        activeWindowShortcutProfile = WindowShortcutProfile(index: index, startedAt: startedAt)
        logWindowShortcutProfile("stage=received index=\(index) alerts=\(showingAlerts ? 1 : 0)")
        await dispatchWindowShortcut(windowShortcutResolution(index: index), index: index, startedAt: startedAt)
    }

    /// Resolves a window-shortcut press to a device-agnostic focus target. Alerts focus
    /// uses the clicked attention item; otherwise the target is reconstructed from the
    /// selected workspace's overview — the same path for local and remote workspaces.
    private func windowShortcutResolution(index: Int) -> DeviceWindowShortcutResolution {
        if showingAlerts {
            guard let request = alerts.alertsFocusRequest(for: index) else { return .noMatch }
            guard let overview = overview(forWorkspaceID: request.workspaceID) else { return .noMatch }
            return Self.windowFocusResolution(for: request, overview: overview)
        }
        guard let selectedWorkspaceID else { return .noWorkspace }
        guard let overview = overview(forWorkspaceID: selectedWorkspaceID) else { return .noWorkspace }
        return Self.deviceWindowShortcutResolution(index: index, selectedWorkspaceID: selectedWorkspaceID, overview: overview)
    }

    /// The overview for the daemon that owns `workspaceID` (local or remote).
    func overview(forWorkspaceID workspaceID: String) -> SpacesDeviceOverviewPayload? {
        deviceSection(id: deviceID(forWorkspaceID: workspaceID))?.overview ?? localDeviceOverview
    }

    /// Focuses the local Chrome window for a workspace browser session. A browser session is a
    /// distinct client "window", so the app opens a dedicated Chrome window for it once and
    /// tracks that window's id in client state (`ClientBrowserWindowIDStore`, keyed by the
    /// resolved URL) — replacing the daemon's former `extracted_window_id`. Re-focus returns to
    /// that specific window by id; only when it is gone does the app open a fresh dedicated
    /// window. Scoping to the tracked window id means focus never lands on an unrelated window
    /// that merely has the same URL open. `NSWorkspace.open` is a last resort when Chrome
    /// cannot be scripted. Remote service sessions use this after their URL has been routed through
    /// the Mac Caddy router.
    private func focusLocalChromeTab(workspaceID: String, targetURL: String, fallbackURL: URL) async {
        let focused = await Task.detached(priority: .userInitiated) {
            let chrome = ChromeAdapter()
            guard chrome.isAvailable() else { return false }
            let store = ClientBrowserWindowIDStore()
            if let trackedID = try? store.windowID(workspaceID: workspaceID, targetURL: targetURL),
                (try? chrome.focusMatchingTabInWindow(windowID: trackedID, urlPrefix: targetURL)) ?? false
            {
                return true
            }
            let newWindowID = (try? chrome.openWindow(url: targetURL, background: false)) ?? -1
            guard newWindowID > 0 else { return false }
            try? store.setWindowID(workspaceID: workspaceID, targetURL: targetURL, windowID: newWindowID)
            return true
        }.value
        if !focused { NSWorkspace.shared.open(fallbackURL) }
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
        case .workspaceAgentLauncher(let workspaceID, let name):
            let launcherID = workspaceDetail(workspaceID, in: overview)?.config.agentLaunchers.first {
                normalizedRunRowName($0.name) == normalizedRunRowName(name)
            }?.id
            return .runCodingAgent(workspaceID: workspaceID, agentName: name, agentLauncherID: launcherID)
        case .agentWindow(let record):
            guard let detail = workspaceDetail(record.workspaceID, in: overview),
                let row = detail.codingAgentRows.first(where: { ($0.agentID ?? $0.id) == record.id }), let sessionID = row.sessionID
            else { return .noMatch }
            return openTerminalResolution(
                workspaceID: record.workspaceID, sessionID: sessionID, fallbackTitle: row.name, fallbackDir: detail.dir, fallbackKind: .agent,
                overview: overview)
        }
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

    nonisolated private static func workspaceDetail(_ workspaceID: String, in overview: SpacesDeviceOverviewPayload)
        -> SpacesDeviceWorkspaceDetailViewModel?
    { overview.workspaces.first(where: { $0.id == workspaceID }).map(SpacesDeviceWorkspaceDetailViewModel.init) }

    /// The single window-shortcut dispatcher for every device. It executes the resolved
    /// target, then applies the window-shortcut profiling and app-hide handling. The
    /// focus work itself lives in `executeWindowFocusResolution` so the cycle and
    /// command-palette paths reuse it.
    private func dispatchWindowShortcut(_ resolution: DeviceWindowShortcutResolution, index: Int, startedAt: Date) async {
        let routeStartedAt = Date()
        let kind = Self.windowShortcutKind(for: resolution)
        guard let action = await executeWindowFocusResolution(resolution) else {
            logWindowShortcutProfile("stage=aborted index=\(index) kind=\(kind) elapsed_ms=\(windowShortcutElapsedMS(since: startedAt))")
            logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false)
            activeWindowShortcutProfile = nil
            return
        }
        logWindowShortcutProfile("stage=route_done index=\(index) kind=\(kind) elapsed_ms=\(windowShortcutElapsedMS(since: routeStartedAt))")
        logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true)
        hideAfterSuccessfulExternalWindowAction(action)
        activeWindowShortcutProfile = nil
    }

    /// Executes a resolved focus target on the client and reports the resulting window
    /// action, or nil when nothing was focused (the executor surfaces its own errors).
    /// Shared by the numbered-shortcut, command-palette, and cycle focus paths so all
    /// three behave identically. Only two leaves depend on where the workspace's daemon
    /// runs: browser URLs may need remote-service routing before local Chrome focus, and
    /// terminal windows use native sessions locally vs Device API mirrors remotely.
    @discardableResult func executeWindowFocusResolution(_ resolution: DeviceWindowShortcutResolution, requestID: String? = nil) async
        -> ExternalWindowAction?
    {
        switch resolution {
        case .openURL(let workspaceID, let targetURL):
            guard let url = URL(string: targetURL) else {
                showError(WorkspaceError.invalidArgument(message: "Browser session URL is invalid."))
                return nil
            }
            if isRemoteDeviceID(deviceID(forWorkspaceID: workspaceID)) {
                guard let device = deviceForWorkspaceMutation(workspaceID: workspaceID) else {
                    showDeviceNotLoadedError()
                    return nil
                }
                guard let workspace = deviceWorkspaceSummary(workspaceID: workspaceID) else {
                    showError(WorkspaceError.invalidArgument(message: "Workspace not found on the selected device."))
                    return nil
                }
                // Opening a missing workspace SSH forward and reconciling the Caddy route blocks (spawns
                // `ssh`, polls local ports and router config up to the timeout), so run it off the main
                // actor to keep the focus keypress from freezing the UI. The manager is `Sendable` and
                // serializes its own state, so the detached task can safely own the reconciliation.
                let manager = browserSSHForwardManager
                let routeResult: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                    do { return .success(try manager.routedURL(targetURL: targetURL, workspace: workspace, device: device)) } catch {
                        return .failure(error)
                    }
                }.value
                switch routeResult {
                case .success(let routedURL):
                    await focusLocalChromeTab(workspaceID: workspaceID, targetURL: routedURL.absoluteString, fallbackURL: routedURL)
                case .failure(let error):
                    showError(error)
                    return nil
                }
            } else {
                await focusLocalChromeTab(workspaceID: workspaceID, targetURL: targetURL, fallbackURL: url)
            }
            Self.setClientActiveWorkspaceID(workspaceID)
            return .focus(hidesApp: true)
        case .openTerminal(let request):
            guard deviceForWorkspaceMutation(workspaceID: request.workspaceID) != nil else {
                showDeviceNotLoadedError()
                return nil
            }
            Self.setClientActiveWorkspaceID(request.workspaceID)
            // A row-built resolution can predate the session's overview entry and lack the
            // real shell/command; recover them through the cold overview fetch so the pane's
            // seeded launch config never shows a placeholder (see makeTerminalPaneContent).
            let openRequest = request.shell == nil ? await resolveTerminalSessionPaneOpenRequest(sessionID: request.sessionID) ?? request : request
            guard panelCoordinator.openOrFocusTerminalPane(openRequest) else { return nil }
            if let requestID, !requestID.isEmpty {
                logPerfMetric(
                    "terminal_window_focus_ipc", target: "session=\(request.sessionID)", elapsedMS: 0, success: true,
                    detail: "route=pane request_id=\(requestID)")
            }
            return .focus(hidesApp: false)
        case .runProcess(let workspaceID, let processKey, let processTemplateID):
            guard let device = deviceForWorkspaceMutation(workspaceID: workspaceID) else {
                showDeviceNotLoadedError()
                return nil
            }
            let result = await Self.deviceMutation(device: device) { device in
                try SpacesDeviceClient.runWorkspaceProcess(
                    workspaceID: workspaceID, processKey: processKey, processTemplateID: processTemplateID, device: device,
                    clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
            }
            switch result {
            case .success(let response):
                Self.setClientActiveWorkspaceID(workspaceID)
                applyDeviceMutationResponse(response, selectedWorkspaceID: workspaceID)
                return .open(hidesApp: false)
            case .failure(let error):
                showError(error)
                return nil
            }
        case .runCodingAgent(let workspaceID, let agentName, let agentLauncherID):
            guard let device = deviceForWorkspaceMutation(workspaceID: workspaceID) else {
                showDeviceNotLoadedError()
                return nil
            }
            let result = await Self.deviceMutation(device: device) { device in
                try SpacesDeviceClient.runCodingAgent(
                    workspaceID: workspaceID, agentName: agentName, agentLauncherID: agentLauncherID, device: device,
                    clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
            }
            switch result {
            case .success(let response):
                Self.setClientActiveWorkspaceID(workspaceID)
                applyDeviceMutationResponse(response, selectedWorkspaceID: workspaceID)
                return .open(hidesApp: false)
            case .failure(let error):
                showError(error)
                return nil
            }
        case .noWorkspace, .noMatch: return nil
        }
    }

    nonisolated private static func windowShortcutKind(for resolution: DeviceWindowShortcutResolution) -> String {
        switch resolution {
        case .openURL: return "browser"
        case .openTerminal: return "terminal"
        case .runProcess: return "process"
        case .runCodingAgent: return "agent_launcher"
        case .noWorkspace, .noMatch: return "none"
        }
    }

    private func logWindowShortcutProfile(_ message: String) {
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
        guard let windowShortcutSpec else { return nil }
        return numberedWindowShortcutIndex(for: event, spec: windowShortcutSpec)
    }

    private func numberedWindowShortcutIndex(for event: NSEvent, spec: HotkeySpec) -> Int? {
        guard eventModifierCarbonFlags(event) == spec.modifiersCarbon else { return nil }
        let keyMap: [UInt16: Int] = [
            UInt16(kVK_ANSI_1): 1, UInt16(kVK_ANSI_2): 2, UInt16(kVK_ANSI_3): 3, UInt16(kVK_ANSI_4): 4, UInt16(kVK_ANSI_5): 5, UInt16(kVK_ANSI_6): 6,
            UInt16(kVK_ANSI_7): 7, UInt16(kVK_ANSI_8): 8, UInt16(kVK_ANSI_9): 9, UInt16(kVK_ANSI_0): 10,
        ]
        return keyMap[event.keyCode]
    }

    func windowShortcutBadgeText(index: Int) -> String {
        let keyText = index == 10 ? "0" : String(index)
        guard let windowShortcutSpec else { return "⌘\(keyText)" }
        return displayShortcut(windowShortcutSpec, keyText: keyText)
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

    private func focusGlobalWindowNavigation(direction: Int) {
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
                workspaceID: workspaceID, delta: direction > 0 ? 1 : -1, preferredTerminalSessionID: preferredFocusedBuiltInTerminalSessionID)
            self.logPerfMetric(
                "global_window_navigation", target: "workspace=\(workspaceID)", elapsedMS: self.windowShortcutElapsedMS(since: startedAt),
                success: true, detail: "direction=\(direction > 0 ? "next" : "previous") request_id=\(requestID)")
        }
    }

    func hideAfterSuccessfulExternalWindowAction(_ action: ExternalWindowAction) {
        let hideDelay = Self.hideDelayAfterSuccessfulExternalWindowAction(true, action: action)
        guard hideDelay != nil || Self.shouldHideAfterSuccessfulExternalWindowAction(true, action: action) else { return }
        cancelDeferredExternalWindowHide()
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

    private func cancelDeferredExternalWindowHide() {
        deferredExternalWindowHideTask?.cancel()
        deferredExternalWindowHideTask = nil
    }

    /// Resolves the workspace owning a terminal session from the overview (sessions and
    /// process/agent/terminal rows all carry both the session id and workspace id),
    /// replacing the orchestrator's daemon-DB lookup. Searches every paired device's
    /// overview so mirrored remote sessions resolve too.
    func clientWorkspaceID(forTerminalSession sessionID: String) -> String? {
        for overview in deviceSections.compactMap({ $0.overview }) {
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
        var best: (workspaceID: String, prefixLength: Int)?
        for overview in deviceSections.compactMap({ $0.overview }) {
            for workspace in overview.workspaces {
                for session in workspace.config.resolvedBrowserSessions {
                    guard let url = session.url, !url.isEmpty, activeURL.hasPrefix(url) else { continue }
                    if best == nil || url.count > best!.prefixLength { best = (workspace.id, url.count) }
                }
            }
        }
        return best?.workspaceID
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

    nonisolated static func shouldRestoreReturnApplicationAfterPaletteHide(returnTerminalSessionID: String?, returnApplicationProcessID: pid_t?)
        -> Bool
    { return returnTerminalSessionID == nil && returnApplicationProcessID != nil }

    nonisolated static func commandPaletteDismissShortcutMatches(
        charactersIgnoringModifiers: String?, modifiers: Set<HotkeyModifier>, leaderModifiers: Set<HotkeyModifier>
    ) -> Bool {
        guard charactersIgnoringModifiers?.lowercased() == "x" else { return false }
        return modifiers == leaderModifiers
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
                "toggle_window_selection_refresh", target: "workspace=\(focusedWorkspaceID ?? "alerts")",
                elapsedMS: self.windowShortcutElapsedMS(since: refreshStartedAt), success: true, detail: "source=\(source)")
        }
    }

    private func refreshWorkspaceSelectionForActivation(focusedWorkspaceID: String?) {
        switch Self.activationSelectionTarget(focusedWorkspaceID: focusedWorkspaceID) {
        case .alerts:
            if showingAlerts, !showingSettings {
                refreshSelection()
                return
            }
            showAlertsDetail()
        case .workspace(let targetWorkspaceID):
            guard let (_, workspace) = findWorkspace(id: targetWorkspaceID) else { return }
            if selectedWorkspaceID == targetWorkspaceID, !showingAlerts, !showingSettings {
                refreshSelection()
                return
            }
            selectWorkspace(workspace)
        }
    }

    @objc func showProjectSettings(_ sender: NSButton) {
        guard let projectID = sender.identifier?.rawValue, let project = projects.first(where: { $0.id == projectID }) else { return }
        showProjectSettingsDialog(project: project)
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
        setupScriptSection: ScriptSection, stopScriptSection: ScriptSection, portsSection: PortsSection, processesSection: ProcessesSection,
        browserSessionsSection: BrowserSessionsSection, agentLaunchersSection: AgentLaunchersSection
    ) {
        projectHasUnsavedChanges = false
        setupScriptSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
        stopScriptSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
        portsSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
        processesSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
        browserSessionsSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
        agentLaunchersSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
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

    private func persistProjectFields(_ refs: ProjectFieldRefs) throws {
        if let device = deviceForDaemonStateMutation() {
            let response = try SpacesDeviceClient.updateProjectConfig(
                projectID: refs.projectID, config: Self.deviceProjectConfig(from: refs), updateAllWorkspaces: refs.pendingImportUpdateAllWorkspaces,
                device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
            refs.hasPendingImportedConfig = false
            refs.pendingImportUpdateAllWorkspaces = false
            refs.discardImportedConfigButton.isHidden = true
            applyDeviceMutationResponse(response)
            return
        }
        throw Self.deviceNotLoadedError()
    }

    private func commitEditing() {
        let windows = [window, NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
        for window in windows {
            window.endEditing(for: nil)
            _ = window.makeFirstResponder(nil)
        }
    }

    private func presentProjectPortRemoveConfirmation(port: ServiceDefinition, confirm: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Remove port \"\(port.name)\"?"
        alert.informativeText = "This removes the port definition from the project."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        confirm(alert.runModal() == .alertFirstButtonReturn)
    }

    private func presentProjectProcessRemoveConfirmation(process: ProcessTemplate, confirm: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        let displayName = process.name ?? process.command
        alert.messageText = "Remove \(displayName)?"
        alert.informativeText = "This removes the process from the project."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        confirm(alert.runModal() == .alertFirstButtonReturn)
    }

    private func presentProjectBrowserSessionRemoveConfirmation(session: BrowserSession, confirm: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        let displayName = session.name ?? session.url ?? "this session"
        alert.messageText = "Remove \(displayName)?"
        alert.informativeText = "This removes the browser session from the project."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        confirm(alert.runModal() == .alertFirstButtonReturn)
    }

    private func presentProjectAgentLauncherRemoveConfirmation(launcher: AgentLauncher, confirm: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Remove \(launcher.name)?"
        alert.informativeText = "This removes the coding agent from the project."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        confirm(alert.runModal() == .alertFirstButtonReturn)
    }

}

struct CommandPaletteItem: Sendable {
    enum Source: Sendable {
        case alertsAttention
        case workspaceTarget
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
    let focusRequest: AppKitController.WindowFocusRequest
    let recentFocusIdentity: String

    var secondaryText: String {
        guard let detail, !detail.isEmpty else { return workspaceTitle }
        return "\(workspaceTitle)  ·  \(detail)"
    }

    var searchCandidate: CommandPaletteFuzzySearch.Candidate<String> {
        let combinedText = "\(workspaceTitle) \(workspaceBranch ?? "") \(label) \(detail ?? "")"
        return CommandPaletteFuzzySearch.Candidate(
            id: id,
            fields: [
                .init(text: workspaceTitle, weight: 0.92), .init(text: workspaceBranch ?? "", weight: 0.9), .init(text: label, weight: 1.0),
                .init(text: detail ?? "", weight: 0.78), .init(text: secondaryText, weight: 0.84), .init(text: combinedText, weight: 0.88),
                .init(text: Self.searchInitials(for: combinedText), weight: 0.94),
            ])
    }

    var focusIdentity: String {
        switch focusRequest {
        case .workspaceBrowserSession(let workspaceID, let targetURL): return "browser:\(workspaceID):\(targetURL)"
        case .workspaceWindow(let workspaceID, let index): return "window:\(workspaceID):\(index)"
        case .workspaceProcess(let workspaceID, let processID): return "process:\(workspaceID):\(processID)"
        case .workspaceMissingConfiguredProcess(let workspaceID, let processKey): return "missing:\(workspaceID):\(processKey)"
        case .workspaceAgentLauncher(let workspaceID, let name): return "agent-launcher:\(workspaceID):\(name)"
        case .agentWindow(let record): return "agent:\(record.id)"
        }
    }

    var visibleIdentity: String {
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return "\(workspaceID):\(kind):\(normalizedLabel):\(normalizedDetail)"
    }

    var iconSymbol: String {
        switch kind {
        case .browser: return "globe"
        case .process, .missingConfiguredProcess: return "terminal"
        case .window: return (detail?.localizedStandardContains("http") == true) ? "globe" : "chevron.left.forwardslash.chevron.right"
        case .agentLauncher, .agent: return "cpu.fill"
        }
    }

    var typeKind: RowPrimitives.TypeKind {
        switch kind {
        case .browser: return .browser
        case .agentLauncher, .agent: return .agent
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
        case .workspaceAgentLauncher(let workspaceID, let name): return "agent-launcher:\(workspaceID):\(name)"
        case .agentWindow(let record): return "agent:\(record.workspaceID):\(record.id)"
        }
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

        labelField.font = .systemFont(ofSize: 13, weight: .semibold)
        labelField.textColor = Theme.text
        labelField.lineBreakMode = .byTruncatingTail
        labelField.maximumNumberOfLines = 1

        detailField.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        detailField.textColor = Theme.muted
        detailField.lineBreakMode = .byTruncatingTail
        detailField.maximumNumberOfLines = 1

        workspaceField.font = .systemFont(ofSize: 10.5, weight: .semibold)
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

        branchField.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
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
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = (isSelected ? Theme.rowSelectedCard : .clear).cgColor }
        layer?.borderWidth = isSelected ? 1 : 0
        layer?.borderColor = (isSelected ? Theme.rowSelectedCardBorder : NSColor.clear).cgColor

        labelField.stringValue = item.label
        workspaceField.stringValue = item.workspaceTitle
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
        switch status {
        case .none: return nil
        case .idle: return RowPrimitives.statusDot(.idle)
        case .process(let processStatus):
            switch processStatus {
            case .running: return RowPrimitives.statusDot(.running)
            case .exited: return RowPrimitives.statusDot(.exited)
            case .idle: return RowPrimitives.statusDot(.idle)
            }
        case .agent(let agentStatus):
            switch agentStatus {
            case .spinning:
                let spinner = NSProgressIndicator()
                spinner.style = .spinning
                spinner.controlSize = .mini
                spinner.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    spinner.widthAnchor.constraint(equalToConstant: 12), spinner.heightAnchor.constraint(equalToConstant: 12),
                ])
                spinner.startAnimation(nil)
                return spinner
            case .waiting: return RowPrimitives.statusDot(.waiting)
            case .done: return RowPrimitives.statusDot(.running)
            case .idle: return RowPrimitives.statusDot(.idle)
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isSelectedState ? Theme.rowSelectedCard.cgColor : NSColor.clear.cgColor
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

extension AppKitController {
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

        let rankedIDs = CommandPaletteFuzzySearch.rank(query: trimmedQuery, candidates: allItems.map(\.searchCandidate)).map(\.id)
        let itemsByID = Dictionary(uniqueKeysWithValues: allItems.map { ($0.id, $0) })
        return rankedIDs.compactMap { itemsByID[$0] }
    }

    nonisolated private static func commandPaletteKind(
        focusRequest: WindowFocusRequest?, fallbackIcon: String, processStatus: RunningProcessState?, agentStatus: AgentWindowStatus?
    ) -> WorkspaceRunShortcutTarget.Kind {
        switch focusRequest {
        case .workspaceBrowserSession: return .browser
        case .workspaceWindow: return .window
        case .workspaceProcess: return .process
        case .workspaceMissingConfiguredProcess: return .missingConfiguredProcess
        case .workspaceAgentLauncher: return .agentLauncher
        case .agentWindow: return .agent
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

    nonisolated private static func buildCommandPaletteAlertsItems(alertsGroups: [AlertsGroup]) -> [CommandPaletteItem] {
        alertsGroups.flatMap { group in
            group.items.compactMap { entry in
                guard let focusRequest = entry.focusRequest else { return nil }
                let kind = commandPaletteKind(
                    focusRequest: focusRequest, fallbackIcon: entry.icon, processStatus: entry.processStatus, agentStatus: entry.agentStatus)
                let status: CommandPaletteItem.Status =
                    if let processStatus = entry.processStatus { .process(processStatus) } else if let agentStatus = entry.agentStatus {
                        .agent(agentStatus)
                    } else { .none }

                return CommandPaletteItem(
                    id: "alerts::\(entry.attentionID)", source: .alertsAttention, alertsAttentionID: entry.attentionID,
                    workspaceID: group.workspaceID, workspaceTitle: group.workspaceName, workspaceBranch: group.workspaceBranch,
                    projectTitle: group.projectName, kind: kind, label: entry.label, detail: entry.detail, status: status, focusRequest: focusRequest,
                    recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(for: focusRequest, detail: entry.detail))
            }
        }
    }

    nonisolated private static func buildCommandPaletteItems(overview: SpacesDeviceOverviewPayload, alertsGroups: [AlertsGroup] = [])
        -> [CommandPaletteItem]
    {
        var items: [CommandPaletteItem] = buildCommandPaletteAlertsItems(alertsGroups: alertsGroups)
        items.append(contentsOf: deviceCommandPaletteWorkspaceItems(from: overview))
        return items
    }

    nonisolated static func deviceCommandPaletteWorkspaceItems(
        from overview: SpacesDeviceOverviewPayload, deviceID: String = SpacesDeviceRecord.localDeviceID
    ) -> [CommandPaletteItem] {
        let mapped = deviceSidebarData(from: overview, deviceID: deviceID)
        var items: [CommandPaletteItem] = []

        for project in mapped.projects {
            for workspace in mapped.workspacesByProject[project.id] ?? [] {
                guard let deviceWorkspace = overview.workspaces.first(where: { $0.id == workspace.id }) else { continue }
                let detail = SpacesDeviceWorkspaceDetailViewModel(workspace: deviceWorkspace)
                let windows = deviceTerminalWindows(from: detail.terminalRows)
                let processes = runningProcesses(from: detail.processRows)
                let agentWindows = agentWindows(from: detail.codingAgentRows)
                let settings = localWorkspaceSettings(from: detail.config)
                let browserSessions = detail.config.resolvedBrowserSessions.map(localBrowserSession(from:))
                let processEntries = orderedWorkspaceRunProcessEntries(
                    configuredProcesses: settings.processes, windows: windows, processes: processes, agentWindows: agentWindows)
                let processesByID = Dictionary(uniqueKeysWithValues: processes.map { ($0.id, $0) })
                let shortcutTargets = orderedWorkspaceRunShortcutTargets(
                    browserSessions: browserSessions, processEntries: processEntries, processesByID: processesByID,
                    configuredAgentLaunchers: settings.agentLaunchers, agentWindows: agentWindows)
                let runtimeWindowTitleByAgentID = codingAgentWindowTitleByAgentID(agentWindows: agentWindows, trackedWindows: windows)
                let configuredAgentByName = Dictionary(uniqueKeysWithValues: settings.agentLaunchers.map { ($0.name, $0) })

                for (offset, target) in shortcutTargets.enumerated() {
                    let itemID = "\(workspace.id)::\(offset)"
                    switch target.kind {
                    case .browser:
                        guard let targetURL = target.targetURL else { continue }
                        let label = browserSessionDisplayName(for: targetURL, sessions: browserSessions) ?? targetURL
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
                        items.append(
                            CommandPaletteItem(
                                id: itemID, source: .workspaceTarget, alertsAttentionID: nil, workspaceID: workspace.id,
                                workspaceTitle: workspace.displayName, workspaceBranch: workspace.branch, projectTitle: project.name,
                                kind: target.kind, label: process.templateName, detail: process.command, status: .process(process.status),
                                focusRequest: .workspaceProcess(workspaceID: workspace.id, processID: processID),
                                recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(
                                    for: .workspaceProcess(workspaceID: workspace.id, processID: processID), detail: process.command)))
                    case .window:
                        guard let windowListIndex = target.windowListIndex, windows.indices.contains(windowListIndex) else { continue }
                        let window = windows[windowListIndex]
                        let label: String
                        let detail: String?
                        if window.role == "terminal" {
                            let fallback = terminalFallbackRowText(name: window.name, detail: window.detail, app: window.app)
                            label = fallback.label
                            detail = fallback.detail
                        } else {
                            label = window.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Window"
                            detail = window.detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                        }
                        items.append(
                            CommandPaletteItem(
                                id: itemID, source: .workspaceTarget, alertsAttentionID: nil, workspaceID: workspace.id,
                                workspaceTitle: workspace.displayName, workspaceBranch: workspace.branch, projectTitle: project.name,
                                kind: target.kind, label: label, detail: detail, status: .none,
                                focusRequest: .workspaceWindow(workspaceID: workspace.id, index: windowListIndex + 1),
                                recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(
                                    for: .workspaceWindow(workspaceID: workspace.id, index: windowListIndex + 1), detail: detail)))
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
                    case .agentLauncher:
                        guard let launcherName = target.launcherName else { continue }
                        let detail = configuredAgentByName[launcherName]?.command
                        items.append(
                            CommandPaletteItem(
                                id: itemID, source: .workspaceTarget, alertsAttentionID: nil, workspaceID: workspace.id,
                                workspaceTitle: workspace.displayName, workspaceBranch: workspace.branch, projectTitle: project.name,
                                kind: target.kind, label: launcherName, detail: detail, status: .none,
                                focusRequest: .workspaceAgentLauncher(workspaceID: workspace.id, name: launcherName),
                                recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(
                                    for: .workspaceAgentLauncher(workspaceID: workspace.id, name: launcherName), detail: detail)))
                    case .agent:
                        guard let agentWindow = target.agentWindow else { continue }
                        let label = agentWindow.label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Coding Agent"
                        let detail = runtimeWindowTitleByAgentID[agentWindow.id]
                        items.append(
                            CommandPaletteItem(
                                id: itemID, source: .workspaceTarget, alertsAttentionID: nil, workspaceID: workspace.id,
                                workspaceTitle: workspace.displayName, workspaceBranch: workspace.branch, projectTitle: project.name,
                                kind: target.kind, label: label, detail: detail, status: .agent(agentWindow.status),
                                focusRequest: .agentWindow(agentWindow),
                                recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(for: .agentWindow(agentWindow), detail: detail)))
                    }
                }
            }
        }

        return items
    }

    func loadCommandPaletteItemsSnapshot() async -> Result<[CommandPaletteItem], Error> {
        await Self.commandPaletteItemsSnapshot(alertsGroups: alertsGroups)
    }

    nonisolated private static func commandPaletteItemsSnapshot(alertsGroups: [AlertsGroup]) async -> Result<[CommandPaletteItem], Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let localOverview = try SpacesDeviceClient.localOverview(
                    database: SpacesClientDatabase.defaultDatabase(), clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                return .success(buildCommandPaletteItems(overview: localOverview.overview, alertsGroups: alertsGroups))
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
