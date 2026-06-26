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
public final class AppKitController: NSObject, NSApplicationDelegate, NSSplitViewDelegate,
    NSWindowDelegate, NSTextFieldDelegate, NSSearchFieldDelegate, NSComboBoxDelegate, NSTableViewDelegate, NSTableViewDataSource
{
    private static let isRunningUnderXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

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

    private enum InlineWorkspaceDetailField {
        case title
        case branch
        case notes
    }

    private struct InlineWorkspaceDetailFieldRefs {
        let workspaceID: String
        let field: InlineWorkspaceDetailField
        let valueLabel: NSTextField
        let editorContainer: NSView
        let textField: NSTextField?
        let textView: NSTextView?
        let saveButton: NSButton?
        let cancelButton: NSButton?
        var originalValue: String
        var isEditing: Bool
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
    private weak var workspaceShortcutFooterRowView: NSStackView?
    // workspaceShortcutFooterLabels removed — footer rebuilt on each refresh
    var orchestrator: WorkspaceOrchestrator!
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

    var selectedProjectID: String? { didSet { overlays.updateOperationProgressOverlayVisibility() } }
    var selectedWorkspaceID: String? { didSet { overlays.updateOperationProgressOverlayVisibility() } }
    var lastSelectedRow: Int = -1
    var suppressOutlineSelectionChanges = false
    // Clearing any reload blocker (unsaved project settings, an open add form) can
    // happen from several paths; flushing here covers them all so a deferred
    // database/worktree reload is never stranded once the user is idle again.
    private var projectHasUnsavedChanges = false {
        didSet { if oldValue, !projectHasUnsavedChanges { flushDeferredSidebarReloadsIfNeeded() } }
    }
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
    private var periodicWorkspaceRefreshTask: Task<Void, Never>?
    /// Exit observers for owned child processes, keyed by pid. They replace the
    /// process-monitor poll: a child's exit triggers the existing status reconcile
    /// immediately instead of on a fixed interval.
    private var processExitObservers: [Int: DispatchSourceProcess] = [:]
    /// Recorded-running pids that were already dead when observed (they died before
    /// an observer was installed, so no exit event is coming). Tracked so they are
    /// reconciled once; a pid the reconcile keeps running (e.g. a surviving child)
    /// is not reconciled again, avoiding a loop. Cleared when the pid leaves the
    /// running set.
    private var reconciledDeadProcessPIDs: Set<Int> = []
    /// Per-local-git-project FSEvents watchers on each repo's git common directory.
    /// They replace worktree-discovery polling: filesystem changes under
    /// `worktrees/`/`HEAD` trigger the existing reconcile path. Keyed by project id.
    private var worktreeDiscoveryWatchers: [String: WorktreeDiscoveryWatch] = [:]
    private var deferredHotkeySelectionRefreshTask: Task<Void, Never>?
    private var activeSpaceSummonCleanupTask: Task<Void, Never>?
    private var visibleWorkspaceDetailRefreshTask: Task<Void, Never>?
    private var visibleWorkspaceDetailRefreshWorkspaceID: String?
    private var workspaceSetupDetailRefreshTimer: Timer?
    private var workspaceSetupDetailRefreshWorkspaceID: String?
    private weak var workspaceSetupLogTextView: NSTextView?
    lazy var commandPalette = CommandPaletteController(host: self)
    lazy var alerts = AlertsController(host: self)
    lazy var overlays = TransientOverlaysController(host: self)
    lazy var workspaceVisibility = WorkspaceVisibilityController(host: self)
    lazy var settings = SettingsController(host: self)
    lazy var devicePairing = DevicePairingController(host: self)
    private var addProjectWindow: NSWindow?
    private var addWorkspaceWindow: NSWindow?
    private var projectSettingsWindow: NSWindow?
    var projectSettingsProjectID: String?
    private var pathCompletionFieldEditor: PathCompletionTextView?
    var pendingWorktreeDiscoveryReload = false
    private var lastTrackedWindowCounts: [String: Int] = [:]
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
    ]
    private var appDidBecomeActiveObserver: NSObjectProtocol?
    private var appDidResignActiveObserver: NSObjectProtocol?
    private var workspaceDidTerminateApplicationObserver: NSObjectProtocol?
    private var terminalAttachmentStateDidChangeObserver: NSObjectProtocol?
    private var terminalRuntimeStateDidChangeObserver: NSObjectProtocol?
    private var textInputDidEndEditingObserver: NSObjectProtocol?
    /// Coalesces foreground-agent reconciles triggered by terminal runtime-state
    /// events: guards against overlap and re-runs once if events arrived mid-run.
    private var terminalForegroundReconcileInFlight = false
    private var terminalForegroundReconcilePending = false
    private var didStartBackgroundServices = false
    var setupManager: SetupManager?
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
    private var inlineWorkspaceFieldRefsByTag: [Int: InlineWorkspaceDetailFieldRefs] = [:]
    private var inlineWorkspaceFieldTagByObjectID: [ObjectIdentifier: Int] = [:]
    private var inlineWorkspaceLabelTagByObjectID: [ObjectIdentifier: Int] = [:]
    private var inlineWorkspaceOutsideClickMonitor: Any?
    var activeAddWorkspaceFormTag: Int? {
        didSet { if oldValue != nil, activeAddWorkspaceFormTag == nil { flushDeferredSidebarReloadsIfNeeded() } }
    }
    var activeAddProjectFormTag: Int? {
        didSet { if oldValue != nil, activeAddProjectFormTag == nil { flushDeferredSidebarReloadsIfNeeded() } }
    }
    private var preparedGitProjectDiscardTasksByURL: [String: PreparedGitProjectDiscardEntry] = [:]
    private lazy var iso8601Formatter: ISO8601DateFormatter = ISO8601DateFormatter()

    var showingAlerts = false
    private var deferredExternalWindowHideTask: Task<Void, Never>?
    private var terminalSessionWindowControllers: [String: TerminalSessionWindowController] = [:]
    private var lastFocusedBuiltInTerminalSessionID: String?
    private var keepsTerminalSessionsRunningDuringTermination = false
    private var appToggleReturnTerminalSessionID: String?
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
    }

    enum WindowFocusRequest: Sendable {
        case workspaceBrowserSession(workspaceID: String, targetURL: String)
        case workspaceWindow(workspaceID: String, index: Int)
        case workspaceProcess(workspaceID: String, processID: String)
        case workspaceMissingConfiguredProcess(workspaceID: String, processKey: String)
        case workspaceAgentLauncher(workspaceID: String, name: String)
        case agentWindow(AgentWindowRecord)
    }

    enum ExternalWindowAction: Sendable {
        case focus(hidesApp: Bool)
        case open(hidesApp: Bool)
    }

    private enum WindowShortcutExecutionOutcome: Sendable {
        case focused(kind: String, recentFocusIdentity: String, hidesApp: Bool)
        case opened(kind: String, hidesApp: Bool)
        case noWorkspace
        case noMatch
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
        do {
            let store = try SQLiteStore(path: launchProfile.databasePath)
            orchestrator = makeUIOrchestrator(store: store)
        } catch {
            releaseLaunchLeases()
            showError(error)
            return
        }
        logStartupProfile("store_ready")

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
        setupTerminalRuntimeStateObserver()
        setupTextInputDidEndEditingObserver()
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionTerminator(Self.terminateBuiltInTerminalSession)
        logStartupProfile("ipc_observers_ready")
        Self.scheduleAfterNextRunLoopTurn { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.buildShellWindow()
                self.logStartupProfile("shell_window_ready")
                self.enterSetupFlow()
                self.logStartupProfile("setup_started")
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

    private func makeUIOrchestrator(store: SQLiteStore) -> WorkspaceOrchestrator {
        WorkspaceOrchestrator(
            store: store,
            builtInTerminalWindowOpener: { [weak self] sessionID, mode in
                Self.dispatchBuiltInTerminalWindowActionOnMainThread { self?.openTerminalSessionWindow(sessionID: sessionID, mode: mode) }
            },
            builtInTerminalWindowFocuser: { [weak self] sessionID, requestID in
                Self.dispatchBuiltInTerminalWindowActionOnMainThread { self?.focusTerminalSessionWindow(sessionID: sessionID, requestID: requestID) }
            },
            builtInTerminalWindowCloser: { [weak self] sessionID in
                Self.dispatchBuiltInTerminalWindowActionOnMainThread {
                    self?.closeTerminalSessionWindows(sessionID: sessionID, sessionIsTerminating: true)
                }
            }, builtInTerminalSessionTerminator: Self.terminateBuiltInTerminalSession,
            builtInTerminalSessionLauncher: Self.launchServiceBuiltInTerminalSession,
            windowFocusPulseEnabledProvider: { [weak self] in self?.clientWindowFocusPulseEnabled() ?? SettingsKey.defaultWindowFocusPulseEnabled },
            windowFocusPulseColorProvider: { [weak self] in self?.clientWindowFocusPulseColor() ?? SettingsKey.windowFocusPulseColor(from: nil) })
    }

    nonisolated static func dispatchBuiltInTerminalWindowActionOnMainThread(
        isMainThread: Bool = Thread.isMainThread,
        scheduler: (@escaping @MainActor () -> Void) -> Void = { action in Task { @MainActor in action() } }, action: @escaping @MainActor () -> Void
    ) { if isMainThread { MainActor.assumeIsolated { action() } } else { scheduler(action) } }

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
        periodicWorkspaceRefreshTask?.cancel()
        stopProcessExitMonitoring()
        stopWorktreeDiscoveryWatchers()
        deferredHotkeySelectionRefreshTask?.cancel()
        sidebar.cancelSidebarReloadTask()
        teardownInlineWorkspaceOutsideClickMonitor()
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
        if let terminalRuntimeStateDidChangeObserver {
            NotificationCenter.default.removeObserver(terminalRuntimeStateDidChangeObserver)
            self.terminalRuntimeStateDidChangeObserver = nil
        }
        if let textInputDidEndEditingObserver {
            NotificationCenter.default.removeObserver(textInputDidEndEditingObserver)
            self.textInputDidEndEditingObserver = nil
        }
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
        let requestID = (notification.userInfo?[IPCNotification.focusRequestIDUserInfoKey] as? String)?.trimmingCharacters(
            in: .whitespacesAndNewlines)
        let preferredFocusedBuiltInTerminalSessionID = (notification.userInfo?[IPCNotification.terminalSessionIDUserInfoKey] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor [weak self, object, workspaceID, direction, requestID, preferredFocusedBuiltInTerminalSessionID] in
            guard let self, self.matchesProfileIPCObject(object) else { return }
            do {
                let effectiveRequestID = (requestID?.isEmpty == false) ? requestID : UUID().uuidString
                let effectivePreferredTerminalSessionID =
                    (preferredFocusedBuiltInTerminalSessionID?.isEmpty == false)
                    ? preferredFocusedBuiltInTerminalSessionID : self.activeBuiltInTerminalSessionID()
                let hidesApp: Bool
                switch direction {
                case "next":
                    hidesApp = try self.orchestrator.focusNextWindowHidesApp(
                        workspaceID: workspaceID, requestID: effectiveRequestID,
                        preferredFocusedBuiltInTerminalSessionID: effectivePreferredTerminalSessionID)
                case "previous":
                    hidesApp = try self.orchestrator.focusPreviousWindowHidesApp(
                        workspaceID: workspaceID, requestID: effectiveRequestID,
                        preferredFocusedBuiltInTerminalSessionID: effectivePreferredTerminalSessionID)
                default: return
                }
                if hidesApp {
                    self.hideAfterSuccessfulExternalWindowAction(.focus(hidesApp: true))
                } else {
                    self.commandPalette.dismissCommandPaletteForBuiltInWindowNavigation()
                }
            } catch { self.showError(error) }
        }
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
            self.logWorkspaceDetailIPC("selecting id=\(workspaceID) title=\(workspace.title)")
            self.showingAlerts = false
            self.showingSettings = false
            self.selectWorkspace(workspace)
            self.refreshSelection()
            if let window = self.window { self.revealTargetedHotkeyWindow(window) }
            self.logWorkspaceDetailIPC("selected id=\(workspaceID) title=\(workspace.title)")
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
            self.openTerminalSessionWindow(sessionID: sessionID, mode: mode, requestID: requestID)
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
            self.closeTerminalSessionWindows(sessionID: sessionID, sessionIsTerminating: sessionIsTerminating)
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
            self.dumpTerminalSessionWindowState(sessionID: sessionID, mode: mode, outputPath: outputPath)
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
            self.focusTerminalSessionWindow(sessionID: sessionID, requestID: requestID)
        }
    }

    @objc private nonisolated func handlePerformTerminalSessionWindowShortcutIPC(_ notification: Notification) {
        let object = notification.object as? String
        guard let sessionID = notification.userInfo?[IPCNotification.terminalSessionIDUserInfoKey] as? String else { return }
        guard let action = notification.userInfo?[IPCNotification.terminalShortcutActionUserInfoKey] as? String else { return }
        let text = notification.userInfo?[IPCNotification.terminalShortcutTextUserInfoKey] as? String
        Task { @MainActor [weak self, object, sessionID, action, text] in
            guard let self, self.matchesProfileIPCObject(object) else { return }
            self.performTerminalSessionWindowShortcut(sessionID: sessionID, action: action, text: text)
        }
    }

    private func matchesProfileIPCObject(_ object: String?) -> Bool { object == ipcNotificationObject }

    private func dumpTerminalSessionWindowState(sessionID: String, mode: TerminalAttachmentMode?, outputPath: String) {
        pruneClosedTerminalSessionWindowControllers(sessionID: sessionID)
        let requestedMode = mode?.rawValue ?? "any"
        let controller = Self.liveTerminalSessionWindowController(terminalSessionWindowControllers[sessionID])
        if let controller { controller.debugRefreshStateForTesting(skipOwnerAttach: mode == .viewer) }
        let debugState = controller?.debugStateDump()
        let payload = TerminalSessionWindowStateDump(
            sessionID: sessionID, requestedMode: requestedMode, found: controller != nil, windowTitle: debugState?.windowTitle,
            rendererSummary: debugState?.rendererSummary, renderedOutput: debugState?.renderedOutput,
            visibleSurfaceOutput: debugState?.visibleSurfaceOutput, summary: debugState?.summary, state: debugState?.state,
            showsTerminalSurface: debugState?.showsTerminalSurface, showsTextRenderer: debugState?.showsTextRenderer,
            didClose: debugState?.didCloseWindow, windowNumber: controller?.window?.windowNumber, surfaceColumns: debugState?.surfaceColumns,
            surfaceRows: debugState?.surfaceRows, windowIsKey: debugState?.windowIsKey, firstResponderTypeName: debugState?.firstResponderTypeName,
            searchVisible: debugState?.searchVisible, searchQuery: debugState?.searchQuery, searchTotal: debugState?.searchTotal,
            searchSelected: debugState?.searchSelected, attachmentMode: debugState?.attachmentMode, takeoverPending: debugState?.takeoverPending,
            takeoverButtonVisible: debugState?.takeoverButtonVisible, takeoverButtonEnabled: debugState?.takeoverButtonEnabled,
            takeoverMessage: debugState?.takeoverMessage)
        writeTerminalSessionWindowStateDump(payload, to: outputPath)
    }

    private func performTerminalSessionWindowShortcut(sessionID: String, action: String, text: String?) {
        pruneClosedTerminalSessionWindowControllers(sessionID: sessionID)
        guard let controller = Self.liveTerminalSessionWindowController(terminalSessionWindowControllers[sessionID]) else { return }
        controller.performShortcutForTesting(action: action, text: text)
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

    private struct RemoteTerminalSessionRoute: Sendable {
        let requestSender: RemoteGhosttyTerminalServiceRequestSender
        let stateStreamSubscriber: RemoteGhosttyStateStreamSubscriber?
        let launchConfiguration: TerminalSessionLaunchConfiguration
        let initialRuntimeState: TerminalSessionRuntimeState?
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

    @discardableResult private func openTerminalSessionWindow(
        sessionID: String, mode: TerminalAttachmentMode, requestID: String? = nil, remoteRouteOverride: RemoteTerminalSessionRoute? = nil
    ) -> Int? {
        let startedAt = Date()
        let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
        cancelDeferredExternalWindowHide()
        do {
            pruneClosedTerminalSessionWindowControllers(sessionID: sessionID)
            let controller: TerminalSessionWindowController
            let reusedExistingWindow: Bool
            if let existing = Self.liveTerminalSessionWindowController(terminalSessionWindowControllers[sessionID]) {
                controller = existing
                reusedExistingWindow = true
            } else {
                let paths = try TerminalSessionPaths.forSession(id: sessionID)
                let remoteRoute: RemoteTerminalSessionRoute? = remoteRouteOverride
                if let remoteRoute { try ensureRemoteTerminalSessionMirror(remoteRoute, paths: paths) }
                let agentSignalHandler: RemoteGhosttyAgentSignalHandler?
                if remoteRoute == nil {
                    agentSignalHandler = nil
                } else {
                    agentSignalHandler = { [weak self] events in
                        guard let self else { return [String]() }
                        return try self.applyRemoteAgentSignals(events)
                    }
                }
                let remoteClientStore = RemoteTerminalWindowClientStore()
                let attachClientAction: @Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void
                let detachClientAction: @Sendable (String) throws -> Void
                let sendInputAction: (@Sendable (String, Bool) throws -> TerminalControlResponse)?
                let sendKeyAction: (@Sendable (String) throws -> TerminalControlResponse)?
                let takeoverAction: (@Sendable (String) throws -> TerminalControlResponse)?
                if let remoteRoute {
                    let requestSender = remoteRoute.requestSender
                    attachClientAction = { client, attachmentMode in
                        remoteClientStore.set(client.id)
                        let response = try Self.sendRemoteTerminalControl(
                            sessionID: sessionID, request: TerminalControlRequest(command: "attach", client: client, attachmentMode: attachmentMode),
                            paths: paths, requestSender: requestSender, refreshMirror: true)
                        guard response.ok else { throw WorkspaceError.invalidArgument(message: response.message) }
                    }
                    detachClientAction = { clientID in
                        if remoteClientStore.current() == clientID { remoteClientStore.set(nil) }
                        let response = try Self.sendRemoteTerminalControl(
                            sessionID: sessionID, request: TerminalControlRequest(command: "detach", clientID: clientID), paths: paths,
                            requestSender: requestSender, refreshMirror: true)
                        guard response.ok else { throw WorkspaceError.invalidArgument(message: response.message) }
                    }
                    sendInputAction = { text, appendNewline in
                        guard let clientID = remoteClientStore.current() else {
                            return TerminalControlResponse(ok: false, message: "Terminal window is not attached.")
                        }
                        return try Self.sendRemoteTerminalControl(
                            sessionID: sessionID,
                            request: TerminalControlRequest(command: "send", text: text, clientID: clientID, appendNewline: appendNewline),
                            paths: paths, requestSender: requestSender, refreshMirror: false)
                    }
                    sendKeyAction = { key in
                        guard let clientID = remoteClientStore.current() else {
                            return TerminalControlResponse(ok: false, message: "Terminal window is not attached.")
                        }
                        return try Self.sendRemoteTerminalControl(
                            sessionID: sessionID, request: TerminalControlRequest(command: "key", key: key, clientID: clientID), paths: paths,
                            requestSender: requestSender, refreshMirror: false)
                    }
                    takeoverAction = { clientID in
                        try Self.sendRemoteTerminalControl(
                            sessionID: sessionID, request: TerminalControlRequest(command: "takeover", clientID: clientID), paths: paths,
                            requestSender: requestSender, refreshMirror: true)
                    }
                } else {
                    attachClientAction = { client, attachmentMode in
                        let response = try TerminalControlClient.send(
                            request: TerminalControlRequest(command: "attach", client: client, attachmentMode: attachmentMode),
                            socketPath: paths.controlSocketPath)
                        guard response.ok else { throw WorkspaceError.invalidArgument(message: response.message) }
                    }
                    detachClientAction = { clientID in
                        let response = try TerminalControlClient.send(
                            request: TerminalControlRequest(command: "detach", clientID: clientID), socketPath: paths.controlSocketPath)
                        guard response.ok else { throw WorkspaceError.invalidArgument(message: response.message) }
                    }
                    sendInputAction = nil
                    sendKeyAction = nil
                    takeoverAction = { clientID in
                        try TerminalControlClient.send(
                            request: TerminalControlRequest(command: "takeover", clientID: clientID), socketPath: paths.controlSocketPath)
                    }
                }
                let created = TerminalSessionWindowController(
                    sessionID: sessionID, paths: paths, preferredAttachmentMode: mode, performInitialRefresh: false, sendInputAction: sendInputAction,
                    sendKeyAction: sendKeyAction, takeoverAction: takeoverAction, attachClientAction: attachClientAction,
                    detachClientAction: detachClientAction, detachClientSynchronouslyOnClose: false,
                    onWindowFocus: { [weak self] sessionID in self?.lastFocusedBuiltInTerminalSessionID = sessionID },
                    onWindowClose: { [weak self] sessionID, clientID, sessionIsTerminating in
                        if self?.lastFocusedBuiltInTerminalSessionID == sessionID { self?.lastFocusedBuiltInTerminalSessionID = nil }
                        self?.removeTerminalSessionWindowController(
                            sessionID: sessionID, clientID: clientID, sessionIsTerminating: sessionIsTerminating)
                    },
                    runtimeControlsProvider: { [weak self] sessionID in
                        self?.terminalRuntimeControls(forSessionID: sessionID, cause: "controller_refresh")
                    },
                    loadWindowFrameAction: { [weak self] mode in
                        guard let self else { return nil }
                        return try clientDatabase().terminalWindowFrame(rootDirectory: paths.rootDirectory, mode: mode)
                    },
                    saveWindowFrameAction: { frame, mode in
                        try self.clientDatabase().writeTerminalWindowFrame(
                            frame, rootDirectory: paths.rootDirectory, sessionID: sessionID, mode: mode)
                    },
                    sessionHostProvider: { launchConfiguration, paths in
                        Self.terminalSessionHost(
                            launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: remoteRoute?.requestSender,
                            stateStreamSubscriber: remoteRoute?.stateStreamSubscriber, agentSignalHandler: agentSignalHandler)
                    })
                terminalSessionWindowControllers[sessionID] = created
                controller = created
                reusedExistingWindow = false
            }
            controller.show(requestID: requestID, route: reusedExistingWindow ? "reuse_existing_window" : "create_window")
            if mode == .owner { controller.requestOwnershipIfNeeded() }
            logPerfMetric(
                "terminal_window_summon", target: "session=\(sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true,
                detail: "mode=\(mode.rawValue) reused=\(reusedExistingWindow ? 1 : 0)\(requestDetail)")
            if let requestID, !requestID.isEmpty {
                logPerfMetric(
                    "terminal_window_focus_ipc", target: "session=\(sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true,
                    detail: "route=summoned_owner request_id=\(requestID)")
            }
            return controller.window?.windowNumber
        } catch {
            logPerfMetric(
                "terminal_window_summon", target: "session=\(sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false,
                detail: "mode=\(mode.rawValue)\(requestDetail)")
            showError(error)
            return nil
        }
    }

    private func deviceRemoteTerminalSessionRoute(_ request: DeviceTerminalOpenRequest, device: SpacesPairedDeviceRecord) throws
        -> RemoteTerminalSessionRoute
    {
        guard let transportKey = try SpacesDeviceCredentialStore.transportKey(deviceID: device.id) else {
            throw SpacesDeviceClientError.missingTransportKey(device.name)
        }
        let authToken = try SpacesDeviceCredentialStore.token(deviceID: device.id)
        let clientApp = SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)
        let requestClient = try SpacesDeviceAPIRequestSessionClient(host: device.host, port: device.port, transportKey: transportKey)
        let launchConfiguration = TerminalSessionLaunchConfiguration(
            sessionID: request.sessionID, backend: .ghosttyEmbedded, title: request.title, workingDirectory: request.workingDirectory,
            shell: "/bin/bash", command: nil, createdAt: request.createdAt ?? ISO8601DateFormatter().string(from: Date()),
            workspaceID: request.workspaceID, kind: request.kind)
        let runtimeState = request.initialState.map {
            TerminalSessionRuntimeState(
                sessionID: request.sessionID, backend: .ghosttyEmbedded, servicePID: request.servicePID ?? 0, childPID: request.childPID, state: $0,
                updatedAt: request.updatedAt ?? launchConfiguration.createdAt, title: request.title, workingDirectory: request.workingDirectory)
        }
        return RemoteTerminalSessionRoute(
            requestSender: Self.deviceTerminalServiceRequestSender(requestClient: requestClient, authToken: authToken, clientApp: clientApp),
            stateStreamSubscriber: { sessionID, onEvent, onDisconnect in
                let request = SpacesDeviceAPIRequest(
                    command: .subscribe(SpacesDeviceTerminalSubscriptionRequest(sessionID: sessionID, clientID: nil)), authToken: authToken,
                    clientApp: clientApp)
                let client = try SpacesDeviceAPIStateStreamClient(
                    request: request, host: device.host, port: device.port, transportKey: transportKey, onEvent: onEvent, onDisconnect: onDisconnect)
                try client.start()
                return client
            }, launchConfiguration: launchConfiguration, initialRuntimeState: runtimeState)
    }

    private func openDeviceTerminalSession(_ request: DeviceTerminalOpenRequest, device: SpacesPairedDeviceRecord, requestID: String? = nil) -> Bool {
        let route: RemoteTerminalSessionRoute
        do { route = try deviceRemoteTerminalSessionRoute(request, device: device) } catch {
            showError(error)
            return false
        }
        return openTerminalSessionWindow(sessionID: request.sessionID, mode: .owner, requestID: requestID, remoteRouteOverride: route) != nil
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

    nonisolated private static func deviceTerminalServiceRequestSender(
        requestClient: SpacesDeviceAPIRequestSessionClient, authToken: String?, clientApp: SpacesDeviceClientApp
    ) -> RemoteGhosttyTerminalServiceRequestSender {
        { request in
            switch request.command {
            case .state(let payload):
                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(
                        command: .state(SpacesDeviceTerminalSessionRequest(sessionID: payload.sessionID)), authToken: authToken, clientApp: clientApp)
                )
                return TerminalServiceResponse(ok: response.ok, message: response.message, sessionState: response.sessionState)
            case .control(let payload):
                let deviceRequest = try deviceTerminalControlRequest(sessionID: payload.sessionID, controlRequest: payload.controlRequest)
                let response = try requestClient.send(
                    SpacesDeviceAPIRequest(command: .terminalControl(deviceRequest), authToken: authToken, clientApp: clientApp))
                return TerminalServiceResponse(
                    ok: response.ok, message: response.message, sessionState: response.sessionState,
                    controlResponse: TerminalControlResponse(ok: response.ok, message: response.message))
            default: throw WorkspaceError.invalidArgument(message: "Remote device terminal command '\(request.commandName)' is not supported.")
            }
        }
    }

    private func ensureRemoteTerminalSessionMirror(_ route: RemoteTerminalSessionRoute, paths: TerminalSessionPaths) throws {
        if (try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths)) == nil {
            try TerminalSessionPersistence.writeLaunchConfiguration(route.launchConfiguration, paths: paths)
        }
        if let initialRuntimeState = route.initialRuntimeState, (try? TerminalSessionPersistence.readRuntimeState(paths: paths)) == nil {
            try TerminalSessionPersistence.writeRuntimeState(initialRuntimeState, paths: paths)
        }
    }

    private func applyRemoteAgentSignals(_ events: [TerminalServiceAgentSignalEvent]) throws -> [String] {
        var acknowledgedIDs: [String] = []
        var didApply = false
        for event in events {
            if try orchestrator.recordRemoteAgentSignal(event) {
                acknowledgedIDs.append(event.id)
                didApply = true
            }
        }
        if didApply { reloadData() }
        return acknowledgedIDs
    }

    private func refreshRemoteTerminalSessionMirror(
        sessionID: String, paths: TerminalSessionPaths, requestSender: RemoteGhosttyTerminalServiceRequestSender
    ) throws {
        let response = try requestSender(TerminalServiceRequest(command: .state(.init(sessionID: sessionID))))
        guard response.ok else { throw WorkspaceError.invalidArgument(message: response.message) }
        guard let payload = response.sessionState else {
            throw WorkspaceError.invalidArgument(message: "Remote spacesd did not return terminal state.")
        }
        if (try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths)) == nil {
            let workspaceID = try orchestrator.workspaceIDForTerminalSession(sessionID)
            let kind = try remoteTerminalSessionKind(sessionID: sessionID, workspaceID: workspaceID)
            try TerminalSessionPersistence.writeLaunchConfiguration(
                Self.remoteTerminalLaunchConfiguration(sessionID: sessionID, workspaceID: workspaceID, kind: kind, payload: payload), paths: paths)
        }
        try TerminalSessionPersistence.writeRemoteStateMirror(payload, paths: paths)
    }

    private func remoteTerminalSessionKind(sessionID: String, workspaceID: String?) throws -> TerminalSessionKind {
        guard let workspaceID else { return .shell }
        if try orchestrator.runningProcesses(workspaceID: workspaceID).contains(where: { Self.terminalSessionID(for: $0) == sessionID }) {
            return .process
        }
        if try orchestrator.agentWindows(workspaceID: workspaceID).contains(where: { Self.terminalSessionID(for: $0) == sessionID }) { return .agent }
        return .shell
    }

    nonisolated private static func sendRemoteTerminalControl(
        sessionID: String, request: TerminalControlRequest, paths: TerminalSessionPaths, requestSender: RemoteGhosttyTerminalServiceRequestSender,
        refreshMirror: Bool
    ) throws -> TerminalControlResponse {
        let response = try requestSender(TerminalServiceRequest(command: .control(.init(sessionID: sessionID, controlRequest: request))))
        guard response.ok else { throw WorkspaceError.invalidArgument(message: response.message) }
        if let payload = response.sessionState {
            try TerminalSessionPersistence.writeRemoteStateMirror(payload, paths: paths)
        } else if refreshMirror {
            try refreshRemoteTerminalSessionMirror(sessionID: sessionID, paths: paths, requestSender: requestSender)
        }
        return response.controlResponse ?? TerminalControlResponse(ok: response.ok, message: response.message)
    }

    nonisolated private static func refreshRemoteTerminalSessionMirror(
        sessionID: String, paths: TerminalSessionPaths, requestSender: RemoteGhosttyTerminalServiceRequestSender
    ) throws {
        let response = try requestSender(TerminalServiceRequest(command: .state(.init(sessionID: sessionID))))
        guard response.ok else { throw WorkspaceError.invalidArgument(message: response.message) }
        guard let payload = response.sessionState else {
            throw WorkspaceError.invalidArgument(message: "Remote spacesd did not return terminal state.")
        }
        try TerminalSessionPersistence.writeRemoteStateMirror(payload, paths: paths)
    }

    nonisolated private static func remoteTerminalLaunchConfiguration(
        sessionID: String, workspaceID: String?, kind: TerminalSessionKind, payload: GhosttyRemoteSessionStatePayload
    ) -> TerminalSessionLaunchConfiguration {
        TerminalSessionLaunchConfiguration(
            sessionID: sessionID, backend: payload.runtimeState?.backend ?? .ghosttyEmbedded, title: payload.title,
            workingDirectory: payload.workingDirectory, shell: "/bin/bash", command: nil,
            createdAt: payload.runtimeState?.updatedAt ?? payload.emittedAt, workspaceID: workspaceID, kind: kind)
    }

    private func pruneClosedTerminalSessionWindowControllers(sessionID: String) {
        guard let controller = terminalSessionWindowControllers[sessionID] else { return }
        if controller.didClose { terminalSessionWindowControllers.removeValue(forKey: sessionID) }
    }

    private func closeTerminalSessionWindows(sessionID: String, sessionIsTerminating: Bool = false) {
        let startedAt = Date()
        pruneClosedTerminalSessionWindowControllers(sessionID: sessionID)
        guard let controller = Self.liveTerminalSessionWindowController(terminalSessionWindowControllers[sessionID]) else {
            logPerfMetric(
                "terminal_window_close", target: "session=\(sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false,
                detail: "route=missing_controller terminating=\(sessionIsTerminating ? 1 : 0)")
            return
        }
        logPerfMetric(
            "terminal_window_close", target: "session=\(sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true,
            detail:
                "route=controller terminating=\(sessionIsTerminating ? 1 : 0) client=\(controller.clientID) window_number=\(controller.window?.windowNumber ?? 0) visible=\((controller.window?.isVisible == true) ? 1 : 0)"
        )
        if sessionIsTerminating { controller.closeForSessionTermination() } else { controller.window?.close() }
        pruneClosedTerminalSessionWindowControllers(sessionID: sessionID)
    }

    func focusTerminalSessionWindow(sessionID: String, requestID: String? = nil) {
        let startedAt = Date()
        let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
        cancelDeferredExternalWindowHide()
        logPerfMetric(
            "terminal_window_focus_ipc_stage", target: "session=\(sessionID)", elapsedMS: 0, success: true, detail: "stage=start\(requestDetail)")
        pruneClosedTerminalSessionWindowControllers(sessionID: sessionID)
        let controllerAndRoute: (controller: TerminalSessionWindowController, route: String)?
        if let resolved = Self.focusableTerminalSessionWindowController(terminalSessionWindowControllers[sessionID], sessionID: sessionID) {
            controllerAndRoute = resolved
        } else {
            openTerminalSessionWindow(sessionID: sessionID, mode: .owner, requestID: requestID)
            pruneClosedTerminalSessionWindowControllers(sessionID: sessionID)
            controllerAndRoute = Self.focusableTerminalSessionWindowController(terminalSessionWindowControllers[sessionID], sessionID: sessionID).map
            { ($0.controller, "summoned_owner") }
        }
        guard let (controller, route) = controllerAndRoute else {
            logPerfMetric(
                "terminal_window_focus_ipc", target: "session=\(sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true,
                detail: "route=missing\(requestDetail)")
            return
        }
        logPerfMetric(
            "terminal_window_focus_ipc_stage", target: "session=\(sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true,
            detail: "stage=resolved_controller route=\(route)\(requestDetail)")
        controller.focusWindow(requestID: requestID, route: route)
        logPerfMetric(
            "terminal_window_focus_ipc", target: "session=\(sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true,
            detail: "route=\(route)\(requestDetail)")
    }

    static func liveTerminalSessionWindowController(_ controller: TerminalSessionWindowController?) -> TerminalSessionWindowController? {
        guard let controller, !controller.didClose else { return nil }
        return controller
    }

    static func focusableTerminalSessionWindowController(_ controller: TerminalSessionWindowController?, sessionID: String) -> (
        controller: TerminalSessionWindowController, route: String
    )? {
        guard let controller = liveTerminalSessionWindowController(controller) else { return nil }
        return (controller, "existing_window")
    }

    private func terminalRuntimeControls(forSessionID sessionID: String, cause: String = "provider", requestID: String? = nil)
        -> TerminalSessionRuntimeControls?
    {
        let startedAt = Date()
        let workspaceLookupStartedAt = Date()
        guard let workspaceID = try? orchestrator.workspaceIDForTerminalSession(sessionID) else {
            let descriptorChanged = terminalRuntimeControlDescriptorsBySessionID.removeValue(forKey: sessionID) != nil
            logTerminalRuntimeControlsRefresh(
                sessionID: sessionID, startedAt: startedAt, cause: cause, requestID: requestID,
                workspaceLookupMS: windowShortcutElapsedMS(since: workspaceLookupStartedAt), settingsMS: 0, processesMS: 0, agentsMS: 0, windowsMS: 0,
                runtimeStateMS: 0, descriptorBuildMS: 0, descriptorChanged: descriptorChanged, success: false)
            return nil
        }
        let workspaceLookupMS = windowShortcutElapsedMS(since: workspaceLookupStartedAt)

        let settingsStartedAt = Date()
        let settings = try? orchestrator.workspaceSettings(workspaceID: workspaceID)
        let settingsMS = windowShortcutElapsedMS(since: settingsStartedAt)
        let processesStartedAt = Date()
        let runningProcesses = (try? orchestrator.runningProcesses(workspaceID: workspaceID)) ?? []
        let processesMS = windowShortcutElapsedMS(since: processesStartedAt)
        let agentsStartedAt = Date()
        let agentWindows = (try? orchestrator.agentWindows(workspaceID: workspaceID)) ?? []
        let agentsMS = windowShortcutElapsedMS(since: agentsStartedAt)
        let windowsStartedAt = Date()
        let trackedWindows = (try? orchestrator.windows(workspaceID: workspaceID)) ?? []
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
        pruneClosedTerminalSessionWindowControllers(sessionID: sessionID)
        guard let controller = Self.liveTerminalSessionWindowController(terminalSessionWindowControllers[sessionID]) else { return }
        controller.setRuntimeControls(terminalRuntimeControls(forSessionID: sessionID, cause: cause, requestID: requestID))
    }

    static func terminalRuntimeControlDescriptor(
        sessionID: String, workspaceID: String, settings: WorkspaceSettings?, runningProcesses: [RunningProcessRecord],
        agentWindows: [AgentWindowRecord], trackedWindows: [WindowRecord], isSessionRunning: Bool
    ) -> TerminalRuntimeControlDescriptor? {
        guard let normalizedSessionID = normalizedTerminalSessionID(sessionID) else { return nil }
        if let process = runningProcesses.first(where: { terminalSessionID(for: $0) == normalizedSessionID }) {
            let template = configuredProcessTemplate(for: process, settings: settings)
            let title = trimmedNonEmpty(template?.name) ?? trimmedNonEmpty(process.templateName) ?? "Process"
            let processKey = trimmedNonEmpty(template?.name) ?? trimmedNonEmpty(process.templateName)
            let isRunning = process.status != .exited && isSessionRunning
            return TerminalRuntimeControlDescriptor(
                kind: .process, workspaceID: workspaceID, sessionID: normalizedSessionID, title: title, processID: process.id,
                processTemplateID: template?.id, processKey: processKey, agentID: nil, agentLauncherID: nil, agentLauncherName: nil,
                canRun: template != nil && !isRunning, canStop: true, canRestart: template != nil)
        }

        if let agent = agentWindows.first(where: { terminalSessionID(for: $0) == normalizedSessionID }) {
            let launcher = configuredAgentLauncher(for: agent, settings: settings)
            let windowTitle = terminalWindowTitle(for: agent, trackedWindows: trackedWindows)
            let title = trimmedNonEmpty(launcher?.name) ?? codingAgentDisplayName(label: agent.label, runtimeWindowTitle: windowTitle)
            let isRunning = agent.status != .done && isSessionRunning
            return TerminalRuntimeControlDescriptor(
                kind: .codingAgent, workspaceID: workspaceID, sessionID: normalizedSessionID, title: title, processID: nil, processTemplateID: nil,
                processKey: nil, agentID: agent.id, agentLauncherID: launcher?.id, agentLauncherName: launcher?.name,
                canRun: launcher != nil && !isRunning, canStop: true, canRestart: launcher != nil)
        }

        let title =
            trackedWindows.first(where: { terminalSessionID(for: $0) == normalizedSessionID }).flatMap {
                trimmedNonEmpty($0.name) ?? trimmedNonEmpty($0.detail)
            } ?? "Terminal"
        return TerminalRuntimeControlDescriptor(
            kind: .workspaceTerminal, workspaceID: workspaceID, sessionID: normalizedSessionID, title: title, processID: nil, processTemplateID: nil,
            processKey: nil, agentID: nil, agentLauncherID: nil, agentLauncherName: nil, canRun: false, canStop: true, canRestart: false)
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

    static func activeOwnerClientID(paths: TerminalSessionPaths) -> String? {
        guard let ownerAttachment = try? TerminalSessionPersistence.activeAttachments(paths: paths).first(where: { $0.mode == .owner }) else {
            return nil
        }
        return ownerAttachment.clientID
    }

    nonisolated static func shouldTerminateAdHocBuiltInTerminalSession(
        paths: TerminalSessionPaths?, isConfiguredProcessSession: Bool, isAppTerminatingAndKeepingSessions: Bool = false, now: Date = Date()
    ) -> Bool {
        guard !isAppTerminatingAndKeepingSessions else { return false }
        guard !isConfiguredProcessSession, let paths, let activeAttachments = try? TerminalSessionPersistence.liveAttachments(paths: paths, now: now)
        else { return false }
        return activeAttachments.isEmpty
    }

    private func removeTerminalSessionWindowController(sessionID: String, clientID: String, sessionIsTerminating: Bool) {
        guard let controller = terminalSessionWindowControllers[sessionID] else {
            logPerfMetric(
                "terminal_window_controller_remove", target: "session=\(sessionID)", elapsedMS: 0, success: false,
                detail: "route=missing_controller client=\(clientID) terminating=\(sessionIsTerminating ? 1 : 0)")
            return
        }
        guard controller.clientID == clientID else {
            logPerfMetric(
                "terminal_window_controller_remove", target: "session=\(sessionID)", elapsedMS: 0, success: false,
                detail: "route=client_mismatch expected=\(controller.clientID) actual=\(clientID) terminating=\(sessionIsTerminating ? 1 : 0)")
            return
        }
        logPerfMetric(
            "terminal_window_controller_remove", target: "session=\(sessionID)", elapsedMS: 0, success: true,
            detail: "client=\(clientID) terminating=\(sessionIsTerminating ? 1 : 0)")
        terminalSessionWindowControllers.removeValue(forKey: sessionID)
        terminalRuntimeControlDescriptorsBySessionID.removeValue(forKey: sessionID)
        guard !sessionIsTerminating else { return }
        stopBuiltInTerminalSessionClosedByUser(sessionID: sessionID)
    }

    private func stopBuiltInTerminalSessionClosedByUser(sessionID: String) {
        guard !keepsTerminalSessionsRunningDuringTermination else { return }
        do {
            let didStop = try orchestrator.stopBuiltInTerminalSessionClosedByUser(sessionID: sessionID)
            logPerfMetric("terminal_window_closed_by_user_stop", target: "session=\(sessionID)", elapsedMS: 0, success: didStop)
            if didStop { requestSidebarReload() }
        } catch {
            logPerfMetric("terminal_window_closed_by_user_stop", target: "session=\(sessionID)", elapsedMS: 0, success: false)
            showError(error)
        }
    }

    private func terminateUnattachedAdHocBuiltInTerminalSessionIfNeeded(sessionID: String, now: Date = Date()) {
        let workspaceID = try? orchestrator.workspaceIDForTerminalSession(sessionID)
        let sessionOwnsTrackedRuntime =
            workspaceID.map { workspaceID in
                let processOwnsSession = ((try? orchestrator.runningProcesses(workspaceID: workspaceID)) ?? []).contains {
                    ($0.terminalNativeID ?? $0.terminalTrackingID) == sessionID
                }
                let agentOwnsSession = ((try? orchestrator.agentWindows(workspaceID: workspaceID)) ?? []).contains {
                    ($0.terminalNativeID ?? $0.terminalTrackingID) == sessionID
                }
                return processOwnsSession || agentOwnsSession
            } ?? false
        let paths = try? TerminalSessionPaths.forSession(id: sessionID)
        guard
            Self.shouldTerminateAdHocBuiltInTerminalSession(
                paths: paths, isConfiguredProcessSession: sessionOwnsTrackedRuntime,
                isAppTerminatingAndKeepingSessions: keepsTerminalSessionsRunningDuringTermination, now: now)
        else { return }
        if (try? orchestrator.stopAdHocBuiltInTerminalSession(sessionID: sessionID)) == true { requestSidebarReload() }
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
                self.requestVisibleWorkspaceDetailRefreshIfNeeded(reason: "app_became_active")
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
        guard terminalSessionWindowControllers[sessionID] == nil else { return }
        terminateUnattachedAdHocBuiltInTerminalSessionIfNeeded(sessionID: sessionID)
    }

    private func setupTerminalRuntimeStateObserver() {
        terminalRuntimeStateDidChangeObserver = NotificationCenter.default.addObserver(
            forName: .spacesTerminalRuntimeStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reconcileTerminalForegroundAgentsFromRuntimeEvent()
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
        textInputDidEndEditingObserver = NotificationCenter.default.addObserver(
            forName: NSText.didEndEditingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Self.scheduleAfterNextRunLoopTurn { self?.flushDeferredSidebarReloadsIfNeeded() }
        }
    }

    /// Reconciles ad-hoc foreground-agent classifications when a terminal's
    /// runtime state changes (the foreground process is part of runtime state).
    /// Replaces the periodic reconcile the process-monitor poll used to drive.
    private func reconcileTerminalForegroundAgentsFromRuntimeEvent() {
        guard didStartBackgroundServices else { return }
        guard !terminalForegroundReconcileInFlight else {
            terminalForegroundReconcilePending = true
            return
        }
        terminalForegroundReconcileInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.terminalForegroundReconcilePending = false
                let result = await Self.runTerminalForegroundAgentReconcileSnapshot()
                if case .success(let didMutate) = result, didMutate, self.canReloadAfterBackgroundWorkspaceRefresh() {
                    self.requestSidebarReload()
                }
            } while self.terminalForegroundReconcilePending
            self.terminalForegroundReconcileInFlight = false
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
                case .failure(let error): self.handleBackgroundRefreshFailure(error, source: "workspace_window_refresh")
                }
                do { try await Task.sleep(for: .seconds(PollingConstants.workspaceWindowRefreshInterval)) } catch { break }
            }
        }
    }

    private func startProcessExitMonitoring() {
        // Reconcile once on startup (catching exits that happened while not
        // observing) and install exit observers for currently-running children.
        handleProcessMonitorChange()
    }

    private func stopProcessExitMonitoring() {
        for source in processExitObservers.values { source.cancel() }
        processExitObservers.removeAll()
        reconciledDeadProcessPIDs.removeAll()
    }

    /// Reconciles the installed exit observers to the set of currently-running
    /// owned processes. Idempotent and cheap, so it is safe to call after every
    /// sidebar reload (workspace launches/stops change the running set).
    func refreshProcessExitObservers() {
        guard didStartBackgroundServices else { return }
        Task { @MainActor [weak self] in
            guard let self, self.didStartBackgroundServices else { return }
            guard let runningPIDs = await Self.runningOwnedProcessPIDsSnapshot() else {
                // Transient read failure: keep existing observers rather than
                // dropping them all, which would leave exits undetected.
                self.handleBackgroundRefreshFailure(
                    WorkspaceError.invalidArgument(message: "Could not read running processes to refresh exit observers."),
                    source: "process_exit_observers")
                return
            }
            guard self.didStartBackgroundServices else { return }
            for (pid, source) in self.processExitObservers where !runningPIDs.contains(pid) {
                source.cancel()
                self.processExitObservers[pid] = nil
            }
            self.reconciledDeadProcessPIDs.formIntersection(runningPIDs)
            var hasUnreconciledDeadPID = false
            for pid in runningPIDs where self.processExitObservers[pid] == nil {
                if Self.isProcessAlive(pid: pid) {
                    self.installProcessExitObserver(pid: pid)
                } else if !self.reconciledDeadProcessPIDs.contains(pid) {
                    // Recorded running but already dead with no exit event coming
                    // (it died before its observer was installed). Reconcile once,
                    // ignoring the startup grace, so it is marked exited and its
                    // on-exit policy runs.
                    self.reconciledDeadProcessPIDs.insert(pid)
                    hasUnreconciledDeadPID = true
                }
            }
            if hasUnreconciledDeadPID { self.handleProcessMonitorChange(ignoreStartupGracePeriod: true) }
        }
    }

    private func installProcessExitObserver(pid: Int) {
        let source = DispatchSource.makeProcessSource(identifier: pid_t(pid), eventMask: .exit, queue: .global(qos: .utility))
        // The handler runs on a background dispatch queue, so it must be a
        // non-isolated @Sendable closure that hops to the main actor; otherwise
        // the closure inherits this method's @MainActor isolation and dispatch
        // trips a `dispatch_assert_queue` SIGTRAP when it invokes it off-main.
        source.setEventHandler { @Sendable [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.processExitObservers[pid]?.cancel()
                self.processExitObservers[pid] = nil
                // The kernel told us this pid exited, so reconcile authoritatively:
                // ignore the startup grace period that the periodic poll used, which
                // would otherwise skip a process that exited within its first 10s and
                // leave it stuck running with no retry now that the poll is gone.
                self.handleProcessMonitorChange(ignoreStartupGracePeriod: true)
            }
        }
        source.resume()
        processExitObservers[pid] = source
    }

    private func handleProcessMonitorChange(ignoreStartupGracePeriod: Bool = false) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Self.runProcessMonitorSnapshot(ignoreStartupGracePeriod: ignoreStartupGracePeriod)
            switch result {
            case .success(let didUpdate): if didUpdate && self.canReloadAfterBackgroundWorkspaceRefresh() { self.requestSidebarReload() }
            case .failure(let error): self.handleBackgroundRefreshFailure(error, source: "process_monitor")
            }
            // The reconcile may have applied restart/exit policies that changed the
            // running set, so reattach observers to the current children.
            self.refreshProcessExitObservers()
        }
    }

    nonisolated private static func isProcessAlive(pid: Int) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    /// Holds the FSEvents watcher for one local git project along with the repo
    /// directory it was installed for, so `refreshWorktreeDiscoveryWatchers` can
    /// detect when a project's path changes and reinstall.
    private struct WorktreeDiscoveryWatch {
        let projectDir: String
        let watcher: FileSystemWatcher
    }

    private func startWorktreeDiscoveryWatchers() {
        refreshWorktreeDiscoveryWatchers()
        // Reconcile once on startup to catch worktrees created, removed, or
        // branch-switched while the app was not watching.
        handleWorktreeDiscoveryChange(projectID: nil)
    }

    private func stopWorktreeDiscoveryWatchers() {
        for watch in worktreeDiscoveryWatchers.values { watch.watcher.stop() }
        worktreeDiscoveryWatchers.removeAll()
    }

    /// Reconciles the installed watchers to the current set of local git projects.
    /// Idempotent and cheap, so it is safe to call after every sidebar reload:
    /// it only tears down watchers for projects that vanished or moved and only
    /// resolves git directories (off the main thread) for newly added projects.
    func refreshWorktreeDiscoveryWatchers() {
        guard didStartBackgroundServices else { return }
        let desired = Dictionary(
            projects.filter { $0.deviceID == localDeviceID && $0.isGitRepo }.map { ($0.id, $0.dir) },
            uniquingKeysWith: { first, _ in first })
        for (projectID, watch) in worktreeDiscoveryWatchers where desired[projectID] != watch.projectDir {
            watch.watcher.stop()
            worktreeDiscoveryWatchers[projectID] = nil
        }
        let missing = desired.filter { worktreeDiscoveryWatchers[$0.key] == nil }
        guard !missing.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            for (projectID, projectDir) in missing {
                guard self.didStartBackgroundServices, self.worktreeDiscoveryWatchers[projectID] == nil else { continue }
                let commonDir = await Task.detached(priority: .utility) { GitClient().commonDirectory(path: projectDir) }.value
                guard self.didStartBackgroundServices, self.worktreeDiscoveryWatchers[projectID] == nil,
                    self.projects.contains(where: { $0.id == projectID && $0.dir == projectDir })
                else { continue }
                guard let commonDir else {
                    self.handleBackgroundRefreshFailure(
                        WorkspaceError.invalidArgument(
                            message: "Live worktree discovery unavailable: could not resolve git directory for \(projectDir)"),
                        source: "worktree_discovery_watch")
                    continue
                }
                self.installWorktreeDiscoveryWatcher(projectID: projectID, projectDir: projectDir, commonDirectory: commonDir)
            }
        }
    }

    private func installWorktreeDiscoveryWatcher(projectID: String, projectDir: String, commonDirectory: String) {
        let watcher = FileSystemWatcher(paths: [commonDirectory], latency: 1) { [weak self] changedPaths in
            guard Self.changedPathsAffectWorktrees(changedPaths, commonDirectory: commonDirectory) else { return }
            Task { @MainActor [weak self] in self?.handleWorktreeDiscoveryChange(projectID: projectID) }
        }
        do {
            try watcher.start()
            worktreeDiscoveryWatchers[projectID] = WorktreeDiscoveryWatch(projectDir: projectDir, watcher: watcher)
        } catch {
            handleBackgroundRefreshFailure(error, source: "worktree_discovery_watch")
        }
    }

    /// Only git worktree metadata should trigger a reconcile; object/index/log
    /// churn from ordinary commits must not. Matches the shared `HEAD` (main
    /// checkout branch switch) and anything under `worktrees/` (linked worktree
    /// add, remove, or branch switch).
    nonisolated static func changedPathsAffectWorktrees(_ paths: [String], commonDirectory: String) -> Bool {
        let head = commonDirectory + "/HEAD"
        let worktreesDir = commonDirectory + "/worktrees"
        return paths.contains { $0 == head || $0 == worktreesDir || $0.hasPrefix(worktreesDir + "/") }
    }

    private func handleWorktreeDiscoveryChange(projectID: String?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Self.runWorktreeDiscoverySnapshot(projectID: projectID)
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
            case .failure(let error): self.handleBackgroundRefreshFailure(error, source: "worktree_discovery_watch")
            }
        }
    }

    /// Flushes sidebar reloads that were deferred because the user was mid-edit.
    /// Watcher events are one-shot, so this runs at natural idle points (forms
    /// closing, app re-activation) in place of the old poll re-check.
    func flushDeferredSidebarReloadsIfNeeded() {
        sidebar.flushPendingDatabaseReloadIfNeeded()
        guard pendingWorktreeDiscoveryReload, canReloadAfterBackgroundWorkspaceRefresh() else { return }
        pendingWorktreeDiscoveryReload = false
        requestSidebarReload()
    }


    func canReloadAfterBackgroundWorkspaceRefresh() -> Bool {
        !projectHasUnsavedChanges && activeAddWorkspaceFormTag == nil && activeAddProjectFormTag == nil && !isTextInputFocused()
    }


    private enum AddWorkspaceBranchMode: String {
        case existing
        case create
    }

    private struct VisibleWorkspaceDetailRefreshOutcome: Sendable {
        let didMutateWindows: Bool
        let didUpdateProcesses: Bool

        var didChangeVisibleState: Bool { didMutateWindows || didUpdateProcesses }
    }

    private struct WorkspaceCreateInput: Sendable {
        let projectID: String
        let name: String
        let branch: String?
        let baseBranch: String?
        let directoryName: String?
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
    }

    enum SidebarDeviceLoadState: Sendable, Equatable {
        case loading
        case offline(String)
        case loaded
    }

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
            (NSApp.delegate as? AppKitController)?.closeTerminalSessionWindows(sessionID: sessionID, sessionIsTerminating: true)
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
        let auxiliaryVisible = hasVisibleAuxiliaryWindowsForHotkeyState() ? 1 : 0
        let terminalVisible = hasVisibleTerminalSessionWindowsForHotkeyState() ? 1 : 0
        return
            "app_active=\(NSApp.isActive ? 1 : 0) app_hidden=\(NSApp.isHidden ? 1 : 0) main_visible=\(mainVisible) main_key=\(mainKey) main_mini=\(mainMini) palette_exists=\(commandPalette.commandPalettePanel == nil ? 0 : 1) palette_visible=\(paletteVisible) palette_key=\(paletteKey) auxiliary_visible=\(auxiliaryVisible) terminal_visible=\(terminalVisible)"
    }

    func rawMainWindowVisibility() -> Bool { window?.isVisible == true && window?.isMiniaturized != true }

    private func hasVisibleTerminalSessionWindowsForHotkeyState() -> Bool {
        terminalSessionWindowControllers.values.contains { controller in
            controller.window?.isVisible == true && controller.window?.isMiniaturized != true
        }
    }

    private func hasVisibleAuxiliaryWindowsForHotkeyState() -> Bool {
        if commandPalette.commandPalettePanel?.isVisible == true { return true }
        return hasVisibleTerminalSessionWindowsForHotkeyState()
    }

    func focusedTerminalSessionIDForToggle() -> String? {
        for (sessionID, controller) in terminalSessionWindowControllers {
            if !controller.didClose && (controller.window?.isKeyWindow == true || controller.window?.isMainWindow == true) { return sessionID }
        }
        return nil
    }

    func activateReturnApplication(processIdentifier: pid_t) {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else { return }
        application.activate(options: [])
    }

    private func activateCurrentApplicationForTargetedReveal() { NSApp.activate(ignoringOtherApps: true) }

    private func effectiveMainWindowVisibilityForHotkeyState() -> Bool {
        Self.effectiveMainWindowVisibilityForHotkeyState(
            rawMainWindowIsVisible: rawMainWindowVisibility(),
            commandPaletteMainWindowVisibility: commandPalette.commandPaletteMainWindowVisibility ?? commandPalette.pendingCommandPalettePresentation?.mainWindowWasVisible)
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

    nonisolated private static func alertsAttentionID(process: RunningProcessRecord) -> String {
        "process:\(process.id):exited:\(process.exitedAt ?? "unknown")"
    }

    nonisolated private static func alertsAttentionID(agentWindow: AgentWindowRecord) -> String {
        "agent:\(agentWindow.id):\(agentWindow.status.rawValue):\(agentWindow.updatedAt)"
    }

    nonisolated static func alertsAttentionAgentWindows(_ agentWindows: [AgentWindowRecord]) -> [AgentWindowRecord] {
        agentWindows.filter { $0.status == .waiting || $0.status == .done }
    }

    nonisolated private static func alertsFocusRequest(window: WindowRecord, windowListIndex: Int, process: RunningProcessRecord, workspaceID: String)
        -> WindowFocusRequest
    {
        if window.role == "browser", let targetURL = window.targetURL, !targetURL.isEmpty {
            return .workspaceBrowserSession(workspaceID: workspaceID, targetURL: targetURL)
        }
        if window.role == "terminal" { return .workspaceProcess(workspaceID: workspaceID, processID: process.id) }
        return .workspaceWindow(workspaceID: workspaceID, index: windowListIndex)
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

    nonisolated private static func refreshWorkspaceWindowsSnapshot() async -> Result<WorkspaceOrchestrator.RefreshResult, Error> {
        await Task.detached(priority: .utility) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = WorkspaceOrchestrator(store: store)
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
                let orchestrator = WorkspaceOrchestrator(store: store)
                let didMutateWindows = try orchestrator.refreshWorkspaceWindows(workspaceID: workspaceID)
                let didUpdateProcesses = try orchestrator.checkAndUpdateProcessStatuses()
                return .success(.init(didMutateWindows: didMutateWindows, didUpdateProcesses: didUpdateProcesses))
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

    nonisolated private static func prepareGitProjectSourceSnapshot(gitURL: String, replaceExistingManagedDirectories: Bool) async -> Result<
        WorkspaceOrchestrator.PreparedGitProjectImport, Error
    > {
        await Task.detached(priority: .userInitiated) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = WorkspaceOrchestrator(store: store)
                return .success(
                    try orchestrator.prepareGitProject(gitURL: gitURL, replaceExistingManagedDirectories: replaceExistingManagedDirectories))
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func discardPreparedGitProjectSnapshot(_ prepared: WorkspaceOrchestrator.PreparedGitProjectImport) async -> Result<
        Void, Error
    > { await Task.detached(priority: .utility) { discardPreparedGitProject(prepared) }.value }

    nonisolated private static func discardPreparedGitProject(_ prepared: WorkspaceOrchestrator.PreparedGitProjectImport) -> Result<Void, Error> {
        do {
            let db = try DatabaseLocator.defaultPath()
            let store = try SQLiteStore(path: db)
            let orchestrator = WorkspaceOrchestrator(store: store)
            try orchestrator.discardPreparedGitProject(prepared)
            return .success(())
        } catch { return .failure(error) }
    }

    nonisolated static func performWindowFocusSnapshot(_ request: WindowFocusRequest) async -> Result<ExternalWindowAction, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = WorkspaceOrchestrator(store: store)
                switch request {
                case .workspaceBrowserSession(let workspaceID, let targetURL):
                    try orchestrator.focusWorkspaceBrowserSession(workspaceID: workspaceID, targetURL: targetURL)
                    Self.setClientActiveWorkspaceID(workspaceID)
                    return .success(.focus(hidesApp: true))
                case .workspaceWindow(let workspaceID, let index):
                    let trackedWindows = try orchestrator.windows(workspaceID: workspaceID)
                    let trackedWindow = index > 0 && index <= trackedWindows.count ? trackedWindows[index - 1] : nil
                    try orchestrator.focusWorkspaceWindow(workspaceID: workspaceID, index: index)
                    Self.setClientActiveWorkspaceID(workspaceID)
                    return .success(.focus(hidesApp: trackedWindow?.app != TerminalHost.spaces.appName))
                case .workspaceProcess(let workspaceID, let processID):
                    try orchestrator.focusWorkspaceProcess(workspaceID: workspaceID, processID: processID)
                    Self.setClientActiveWorkspaceID(workspaceID)
                    return .success(.focus(hidesApp: false))
                case .workspaceMissingConfiguredProcess(let workspaceID, let processKey):
                    try orchestrator.recoverMissingConfiguredProcess(workspaceID: workspaceID, processKey: processKey)
                    Self.setClientActiveWorkspaceID(workspaceID)
                    return .success(.open(hidesApp: false))
                case .workspaceAgentLauncher(let workspaceID, let name):
                    _ = try orchestrator.launchAgentLauncher(workspaceID: workspaceID, name: name)
                    Self.setClientActiveWorkspaceID(workspaceID)
                    return .success(.open(hidesApp: false))
                case .agentWindow(let record):
                    try orchestrator.focusAgentWindow(record)
                    Self.setClientActiveWorkspaceID(record.workspaceID)
                    return .success(.focus(hidesApp: false))
                }
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func recoverMissingTrackedWindowSnapshot(_ context: MissingTrackedWindowContext) async -> Result<Void, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = WorkspaceOrchestrator(store: store)
                switch context.kind {
                case .browserSession:
                    guard let targetURL = context.targetURL else {
                        throw WorkspaceError.invalidArgument(message: "Browser recovery requires a target URL.")
                    }
                    try orchestrator.recoverMissingBrowserSession(workspaceID: context.workspaceID, targetURL: targetURL)
                case .process:
                    guard let processID = context.processID else {
                        throw WorkspaceError.invalidArgument(message: "Process recovery requires a process identifier.")
                    }
                    let recovered = try orchestrator.recoverRunningWorkspaceProcessIfPossible(workspaceID: context.workspaceID, processID: processID)
                    if !recovered { try orchestrator.restartWorkspaceProcess(workspaceID: context.workspaceID, processID: processID) }
                case .codingAgent, .window: throw WorkspaceError.invalidArgument(message: "This window cannot be recovered automatically.")
                }
                return .success(())
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func recoveredWorkspaceProcessSnapshot(workspaceID: String, processID: String) async -> Result<
        RunningProcessRecord?, Error
    > {
        await Task.detached(priority: .userInitiated) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = WorkspaceOrchestrator(store: store)
                return .success(try orchestrator.runningProcesses(workspaceID: workspaceID).first(where: { $0.id == processID }))
            } catch { return .failure(error) }
        }.value
    }

    nonisolated static func recoveredProcessWindowDetail(title: String, terminalApp _: String?) -> String {
        "\(title) reopened in a new Spaces window."
    }

    nonisolated private static func recoverRunningWorkspaceProcessIfPossibleSnapshot(_ context: MissingTrackedWindowContext) async -> Result<
        Bool, Error
    > {
        await Task.detached(priority: .userInitiated) {
            do {
                guard context.kind == .process, let processID = context.processID else {
                    throw WorkspaceError.invalidArgument(message: "Running-process recovery requires a process identifier.")
                }
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = WorkspaceOrchestrator(store: store)
                return .success(try orchestrator.recoverRunningWorkspaceProcessIfPossible(workspaceID: context.workspaceID, processID: processID))
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func launchConfiguredAgentSnapshot(workspaceID: String, name: String) async -> Result<Void, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = WorkspaceOrchestrator(store: store)
                _ = try orchestrator.launchAgentLauncher(workspaceID: workspaceID, name: name)
                return .success(())
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func focusWindowShortcutSnapshot(index: Int, selectedWorkspaceID: String?, alertsFocusRequest: WindowFocusRequest?)
        async -> Result<WindowShortcutExecutionOutcome, Error>
    {
        await Task.detached(priority: .userInitiated) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = WorkspaceOrchestrator(store: store)

                if let alertsFocusRequest {
                    switch alertsFocusRequest {
                    case .workspaceBrowserSession(let workspaceID, let targetURL):
                        try orchestrator.focusWorkspaceBrowserSession(workspaceID: workspaceID, targetURL: targetURL)
                        Self.setClientActiveWorkspaceID(workspaceID)
                        return .success(
                            .focused(
                                kind: "alerts_browser", recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(for: alertsFocusRequest),
                                hidesApp: true))
                    case .workspaceWindow(let workspaceID, let index):
                        let trackedWindows = try orchestrator.windows(workspaceID: workspaceID)
                        let trackedWindow = index > 0 && index <= trackedWindows.count ? trackedWindows[index - 1] : nil
                        try orchestrator.focusWorkspaceWindow(workspaceID: workspaceID, index: index)
                        Self.setClientActiveWorkspaceID(workspaceID)
                        return .success(
                            .focused(
                                kind: "alerts_window", recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(for: alertsFocusRequest),
                                hidesApp: trackedWindow?.app != TerminalHost.spaces.appName))
                    case .workspaceProcess(let workspaceID, let processID):
                        try orchestrator.focusWorkspaceProcess(workspaceID: workspaceID, processID: processID)
                        Self.setClientActiveWorkspaceID(workspaceID)
                        return .success(
                            .focused(
                                kind: "alerts_process", recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(for: alertsFocusRequest),
                                hidesApp: false))
                    case .workspaceMissingConfiguredProcess(let workspaceID, let processKey):
                        try orchestrator.recoverMissingConfiguredProcess(workspaceID: workspaceID, processKey: processKey)
                        Self.setClientActiveWorkspaceID(workspaceID)
                        return .success(.opened(kind: "alerts_process", hidesApp: false))
                    case .workspaceAgentLauncher(let workspaceID, let name):
                        _ = try orchestrator.launchAgentLauncher(workspaceID: workspaceID, name: name)
                        Self.setClientActiveWorkspaceID(workspaceID)
                        return .success(.opened(kind: "alerts_agent_launcher", hidesApp: false))
                    case .agentWindow(let record):
                        try orchestrator.focusAgentWindow(record)
                        Self.setClientActiveWorkspaceID(record.workspaceID)
                        return .success(
                            .focused(
                                kind: "alerts_agent", recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(for: alertsFocusRequest),
                                hidesApp: false))
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
                    let focusRequest = WindowFocusRequest.workspaceBrowserSession(workspaceID: selectedWorkspaceID, targetURL: targetURL)
                    try orchestrator.focusWorkspaceBrowserSession(workspaceID: selectedWorkspaceID, targetURL: targetURL)
                    Self.setClientActiveWorkspaceID(selectedWorkspaceID)
                    return .success(
                        .focused(kind: "browser", recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(for: focusRequest), hidesApp: true))
                case .process:
                    guard let processID = target.processID else { return .success(.noMatch) }
                    let focusRequest = WindowFocusRequest.workspaceProcess(workspaceID: selectedWorkspaceID, processID: processID)
                    try orchestrator.focusWorkspaceProcess(workspaceID: selectedWorkspaceID, processID: processID)
                    Self.setClientActiveWorkspaceID(selectedWorkspaceID)
                    return .success(
                        .focused(kind: "process", recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(for: focusRequest), hidesApp: false))
                case .window:
                    guard let windowListIndex = target.windowListIndex else { return .success(.noMatch) }
                    let focusRequest = WindowFocusRequest.workspaceWindow(workspaceID: selectedWorkspaceID, index: windowListIndex + 1)
                    let targetWindow = windowListIndex < windows.count ? windows[windowListIndex] : nil
                    try orchestrator.focusWorkspaceWindow(workspaceID: selectedWorkspaceID, index: windowListIndex + 1)
                    Self.setClientActiveWorkspaceID(selectedWorkspaceID)
                    return .success(
                        .focused(
                            kind: "window", recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(for: focusRequest),
                            hidesApp: targetWindow?.app != TerminalHost.spaces.appName))
                case .missingConfiguredProcess:
                    guard let processKey = target.processKey else { return .success(.noMatch) }
                    try orchestrator.recoverMissingConfiguredProcess(workspaceID: selectedWorkspaceID, processKey: processKey)
                    Self.setClientActiveWorkspaceID(selectedWorkspaceID)
                    return .success(.opened(kind: "process", hidesApp: false))
                case .agentLauncher:
                    guard let launcherName = target.launcherName else { return .success(.noMatch) }
                    _ = try orchestrator.launchAgentLauncher(workspaceID: selectedWorkspaceID, name: launcherName)
                    Self.setClientActiveWorkspaceID(selectedWorkspaceID)
                    return .success(.opened(kind: "agent_launcher", hidesApp: false))
                case .agent:
                    guard let record = target.agentWindow else { return .success(.noMatch) }
                    let focusRequest = WindowFocusRequest.agentWindow(record)
                    try orchestrator.focusAgentWindow(record)
                    Self.setClientActiveWorkspaceID(record.workspaceID)
                    return .success(
                        .focused(kind: "agent", recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(for: focusRequest), hidesApp: false))
                }
            } catch { return .failure(error) }
        }.value
    }

    // Browser rows stay visible even when the workspace is stopped so the Run tab
    // remains a stable launch surface for configured browser sessions.
    nonisolated static func shouldShowConfiguredBrowserSessions(workspaceIsRunning _: Bool) -> Bool { true }

    nonisolated static func shouldShowWorkspaceSetupPanel(status: WorkspaceSetupStatus) -> Bool { status != .succeeded }

    nonisolated static func shouldShowWorkspaceSetupScriptEditor(status: WorkspaceSetupStatus) -> Bool { status == .failed }

    nonisolated static func shouldRequestNormalWorkspaceDetailRefresh(setupStatus: WorkspaceSetupStatus) -> Bool { setupStatus == .succeeded }

    nonisolated private static func runProcessMonitorSnapshot(ignoreStartupGracePeriod: Bool = false) async -> Result<Bool, Error> {
        await Task.detached(priority: .utility) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = WorkspaceOrchestrator(store: store)
                let didUpdateProcessStates = try orchestrator.checkAndUpdateProcessStatuses(
                    ignoreStartupGracePeriod: ignoreStartupGracePeriod)
                return .success(didUpdateProcessStates)
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func runTerminalForegroundAgentReconcileSnapshot() async -> Result<Bool, Error> {
        await Task.detached(priority: .utility) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = WorkspaceOrchestrator(store: store)
                return .success(try orchestrator.reconcileTerminalForegroundAgentClassifications())
            } catch { return .failure(error) }
        }.value
    }

    /// Returns nil on a transient store/profile error so callers can distinguish
    /// "no processes are running" from "could not read", and avoid tearing down
    /// live exit observers on a failed read.
    nonisolated private static func runningOwnedProcessPIDsSnapshot() async -> Set<Int>? {
        await Task.detached(priority: .utility) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = WorkspaceOrchestrator(store: store)
                return try orchestrator.runningOwnedProcessPIDs()
            } catch { return nil }
        }.value
    }

    nonisolated private static func runWorktreeDiscoverySnapshot(projectID: String?) async -> Result<Int, Error> {
        await Task.detached(priority: .utility) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = WorkspaceOrchestrator(store: store)
                let created = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: projectID)
                return .success(created.count)
            } catch { return .failure(error) }
        }.value
    }

    /// Builds attention alerts for a remote device from its overview payload.
    /// A remote device has no local orchestrator, but its overview already carries
    /// per-workspace process run states and coding-agent activity states, which is
    /// exactly what the attention list needs — so alerts aggregate across devices
    /// without any daemon protocol change.
    nonisolated static func buildRemoteAlertsGroups(from overview: SpacesDeviceOverviewPayload, deviceID: String) -> [AlertsGroup] {
        var groups: [AlertsGroup] = []
        for workspace in overview.workspaces where !workspace.isArchived {
            var items: [AlertsAttentionEntry] = []
            if workspace.isRunning {
                for process in workspace.processRows where process.runState == .exited {
                    items.append(
                        AlertsAttentionEntry(
                            attentionID: "remote:\(deviceID):p:\(process.id)", icon: "terminal", iconTint: .terminal, label: process.name,
                            detail: process.command, shortcut: "", processStatus: .exited, agentStatus: nil, countsTowardBadge: true, eventDate: nil,
                            focusRequest: process.processID.map { .workspaceProcess(workspaceID: workspace.id, processID: $0) }))
                }
            }
            for agent in workspace.codingAgentRows where agent.activityState == .waiting {
                items.append(
                    AlertsAttentionEntry(
                        attentionID: "remote:\(deviceID):a:\(agent.id)", icon: "cpu.fill", iconTint: .warning, label: agent.name, detail: nil,
                        shortcut: "", processStatus: nil, agentStatus: .waiting, countsTowardBadge: true, eventDate: nil,
                        focusRequest: .workspaceAgentLauncher(workspaceID: workspace.id, name: agent.name)))
            }
            guard !items.isEmpty else { continue }
            groups.append(
                AlertsGroup(
                    projectName: workspace.projectName, workspaceID: workspace.id, workspaceName: workspace.title, workspaceBranch: workspace.branch,
                    items: items))
        }
        return groups
    }

    nonisolated private static func buildAlertsGroupsSnapshot(
        orchestrator: WorkspaceOrchestrator, projects: [ProjectSummary], workspacesByProject: [String: [WorkspaceSummary]]
    ) throws -> [AlertsGroup] {
        let iso8601Formatter = ISO8601DateFormatter()
        var groups: [AlertsGroup] = []
        for project in projects {
            let workspaces = workspacesByProject[project.id] ?? []
            for workspace in workspaces {
                let agentWindowsList = (try? orchestrator.agentWindows(workspaceID: workspace.id)) ?? []
                let attentionAgentWindows = alertsAttentionAgentWindows(agentWindowsList)
                guard workspace.isRunning || !attentionAgentWindows.isEmpty else { continue }

                let processes = workspace.isRunning ? ((try? orchestrator.runningProcesses(workspaceID: workspace.id)) ?? []) : []
                let windows = workspace.isRunning ? ((try? orchestrator.windows(workspaceID: workspace.id)) ?? []) : []
                let configuredSessions: [BrowserSession] = {
                    guard workspace.isRunning else { return [] }
                    return (try? orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspace.id)) ?? []
                }()
                var processByWindowID: [Int: RunningProcessRecord] = [:]
                for process in processes { if let wid = process.windowID { processByWindowID[wid] = process } }
                var items: [AlertsAttentionEntry] = []
                var matchedProcessIDs: Set<String> = []

                for (idx, win) in windows.enumerated() {
                    guard let wid = win.windowID, let process = processByWindowID[wid] else { continue }
                    matchedProcessIDs.insert(process.id)
                    guard process.status == .exited else { continue }
                    let icon: String
                    let iconTint: AlertsIconTint
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
                    let eventDate = process.exitedAt.flatMap { iso8601Formatter.date(from: $0) }
                    items.append(
                        AlertsAttentionEntry(
                            attentionID: Self.alertsAttentionID(process: process), icon: icon, iconTint: iconTint, label: label, detail: detail,
                            shortcut: "", processStatus: process.status, agentStatus: nil, countsTowardBadge: true, eventDate: eventDate,
                            focusRequest: Self.alertsFocusRequest(window: win, windowListIndex: idx + 1, process: process, workspaceID: workspace.id))
                    )
                }

                for process in processes where !matchedProcessIDs.contains(process.id) {
                    guard process.status == .exited else { continue }
                    let eventDate = process.exitedAt.flatMap { iso8601Formatter.date(from: $0) }
                    items.append(
                        AlertsAttentionEntry(
                            attentionID: Self.alertsAttentionID(process: process), icon: "terminal", iconTint: .terminal, label: process.templateName,
                            detail: process.command, shortcut: "", processStatus: process.status, agentStatus: nil, countsTowardBadge: true,
                            eventDate: eventDate, focusRequest: .workspaceProcess(workspaceID: workspace.id, processID: process.id)))
                }

                for agentWin in attentionAgentWindows {
                    items.append(
                        AlertsAttentionEntry(
                            attentionID: Self.alertsAttentionID(agentWindow: agentWin), icon: "cpu.fill", iconTint: .warning,
                            label: agentWin.label ?? "Coding Agent CLI", detail: nil, shortcut: "", processStatus: nil, agentStatus: agentWin.status,
                            countsTowardBadge: true, eventDate: iso8601Formatter.date(from: agentWin.updatedAt), focusRequest: .agentWindow(agentWin))
                    )
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
                        projectName: project.name, workspaceID: workspace.id, workspaceName: workspace.title, workspaceBranch: workspace.branch,
                        items: items))
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

    nonisolated static func initialSidebarDataSnapshot() async -> Result<SidebarDataSnapshot, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let snapshotStartedAt = ProcessInfo.processInfo.systemUptime
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = WorkspaceOrchestrator(store: store)
                logStartupSnapshotProfile("sidebar_snapshot_store_ready")
                let config = try clientAppConfig(base: orchestrator.syncConfig())
                logStartupSnapshotProfile("sidebar_snapshot_config_ready")
                // The sidebar shows every paired device at once; the initial snapshot
                // always loads the local device first, then remote sections stream in
                // independently (see loadRemoteDeviceSections).
                let deviceClientApp = SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)
                let localDevice = try SpacesDeviceClient.bootstrapLocalDevice(
                    database: SpacesClientDatabase.defaultDatabase(), clientApp: deviceClientApp)
                let localOverview = try SpacesDeviceClient.overview(device: localDevice, clientApp: deviceClientApp)
                let collapseStates = (try? SpacesClientDatabase.defaultDatabase().projectCollapseStates(deviceID: localOverview.device.id)) ?? [:]
                let mapped = deviceSidebarData(from: localOverview.overview, deviceID: localOverview.device.id, projectCollapseStates: collapseStates)
                let workspaceCount = mapped.workspacesByProject.values.reduce(0) { $0 + $1.count }
                logStartupSnapshotProfile(
                    "sidebar_snapshot_local_device_ready",
                    details: "device=\(localOverview.device.name) project_count=\(mapped.projects.count) workspace_count=\(workspaceCount)")
                let alertsGroups = try buildAlertsGroupsSnapshot(
                    orchestrator: orchestrator, projects: mapped.projects, workspacesByProject: mapped.workspacesByProject)
                logStartupSnapshotProfile(
                    "sidebar_snapshot_alerts_ready",
                    details: "group_count=\(alertsGroups.count) item_count=\(alertsGroups.reduce(0) { $0 + $1.items.count })")
                logStartupSnapshotProfile(
                    "sidebar_snapshot_complete", details: "total_ms=\(Int((ProcessInfo.processInfo.systemUptime - snapshotStartedAt) * 1000))")
                return .success(
                    .init(
                        config: config, projects: mapped.projects, workspacesByProject: mapped.workspacesByProject,
                        workspaceRuntimeStatusByID: mapped.workspaceRuntimeStatusByID, alertsGroups: alertsGroups,
                        localDeviceID: localOverview.device.id, localDeviceName: localOverview.device.name, localPairedDevice: localOverview.device,
                        localDeviceOverview: localOverview.overview))
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
                    id: $0.id, title: $0.title, branch: $0.branch, baseBranch: $0.baseBranch, dir: $0.dir, isRunning: $0.isRunning,
                    isArchived: $0.isArchived, isHidden: $0.isHidden, isDefault: $0.isDefault, notes: $0.notes, deviceID: deviceID)
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

    nonisolated private static func localPortDefinition(from port: SpacesDevicePortDefinition) -> PortDefinition {
        PortDefinition(id: port.id, name: port.name)
    }

    nonisolated private static func devicePortDefinition(from port: PortDefinition) -> SpacesDevicePortDefinition {
        SpacesDevicePortDefinition(id: port.id, name: port.name)
    }

    nonisolated private static func localProcessTemplate(from process: SpacesDeviceProcessTemplate) -> ProcessTemplate {
        ProcessTemplate(
            id: process.id, name: process.name, command: process.command, kind: process.kind,
            onExit: ProcessExitAction(rawValue: process.onExit) ?? .none)
    }

    nonisolated private static func deviceProcessTemplate(from process: ProcessTemplate) -> SpacesDeviceProcessTemplate {
        SpacesDeviceProcessTemplate(id: process.id, name: process.name, command: process.command, kind: process.kind, onExit: process.onExit.rawValue)
    }

    nonisolated private static func localBrowserSession(from session: SpacesDeviceBrowserSession) -> BrowserSession {
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

    nonisolated private static func localWorkspaceSettings(from config: SpacesDeviceWorkspaceConfig) -> WorkspaceSettings {
        WorkspaceSettings(
            stopScript: config.stopScript, ports: config.ports.map(localPortDefinition(from:)),
            processes: config.processes.map(localProcessTemplate(from:)), browserSessions: config.browserSessions.map(localBrowserSession(from:)),
            agentLaunchers: config.agentLaunchers.map(localAgentLauncher(from:)))
    }

    nonisolated private static func deviceWorkspaceConfig(
        from settings: WorkspaceSettings, resolvedBrowserSessions: [SpacesDeviceBrowserSession] = []
    ) -> SpacesDeviceWorkspaceConfig {
        SpacesDeviceWorkspaceConfig(
            stopScript: settings.stopScript, ports: settings.ports.map(devicePortDefinition(from:)),
            processes: settings.processes.map(deviceProcessTemplate(from:)),
            browserSessions: settings.browserSessions.map(deviceBrowserSession(from:)), resolvedBrowserSessions: resolvedBrowserSessions,
            agentLaunchers: settings.agentLaunchers.map(deviceAgentLauncher(from:)))
    }

    nonisolated private static func localProjectSettings(from config: SpacesDeviceProjectConfig) -> (
        setupScript: String?, stopScript: String?, ports: [PortDefinition], processes: [ProcessTemplate], browserSessions: [BrowserSession],
        agentLaunchers: [AgentLauncher]
    ) {
        (
            setupScript: config.setupScript, stopScript: config.stopScript, ports: config.ports.map(localPortDefinition(from:)),
            processes: config.processes.map(localProcessTemplate(from:)), browserSessions: config.browserSessions.map(localBrowserSession(from:)),
            agentLaunchers: config.agentLaunchers.map(localAgentLauncher(from:))
        )
    }

    private static func deviceProjectConfig(from refs: ProjectFieldRefs) -> SpacesDeviceProjectConfig {
        SpacesDeviceProjectConfig(
            setupScript: refs.setupScriptSection.currentValue.isEmpty ? nil : refs.setupScriptSection.currentValue,
            stopScript: refs.stopScriptSection.currentValue.isEmpty ? nil : refs.stopScriptSection.currentValue,
            ports: refs.portsSection.currentPorts.map(devicePortDefinition(from:)),
            processes: refs.processesSection.currentProcesses.map(deviceProcessTemplate(from:)),
            browserSessions: refs.browserSessionsSection.currentSessions.map(deviceBrowserSession(from:)),
            agentLaunchers: refs.agentLaunchersSection.currentLaunchers.map(deviceAgentLauncher(from:)))
    }

    private static func deviceProjectConfig(from refs: AddProjectFieldRefs) -> SpacesDeviceProjectConfig {
        SpacesDeviceProjectConfig(
            setupScript: refs.setupScriptSection.currentValue.isEmpty ? nil : refs.setupScriptSection.currentValue,
            stopScript: refs.stopScriptSection.currentValue.isEmpty ? nil : refs.stopScriptSection.currentValue,
            ports: refs.portsSection.currentPorts.map(devicePortDefinition(from:)),
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
            status: localSetupStatus(from: state.status), errorMessage: state.errorMessage, startedAt: state.startedAt, finishedAt: state.finishedAt)
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
        let initialState: TerminalSessionState?
        let servicePID: Int32?
        let childPID: Int32?
        let createdAt: String?
        let updatedAt: String?

        init(
            workspaceID: String, sessionID: String, title: String, workingDirectory: String, kind: TerminalSessionKind,
            initialState: TerminalSessionState? = nil, servicePID: Int32? = nil, childPID: Int32? = nil, createdAt: String? = nil,
            updatedAt: String? = nil
        ) {
            self.workspaceID = workspaceID
            self.sessionID = sessionID
            self.title = title
            self.workingDirectory = workingDirectory
            self.kind = kind
            self.initialState = initialState
            self.servicePID = servicePID
            self.childPID = childPID
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    enum DeviceWindowShortcutResolution: Sendable, Equatable {
        case openURL(String)
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
        let terminalOrderByWindowID: [Int: Int] = windows.reduce(into: [:]) { result, window in
            guard window.role == "terminal", let windowID = window.windowID else { return }
            let existingOrder = result[windowID] ?? Int.max
            result[windowID] = min(existingOrder, window.orderIndex)
        }
        func processOrder(_ process: RunningProcessRecord) -> Int {
            if let targetID = process.terminalTrackingKey, let order = terminalOrderByTargetID[targetID] { return order }
            if let windowID = process.windowID, let order = terminalOrderByWindowID[windowID] { return order }
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
        let processesByWindowID: [Int: [RunningProcessRecord]] = {
            var map: [Int: [RunningProcessRecord]] = [:]
            for process in processes {
                guard let windowID = process.windowID else { continue }
                map[windowID, default: []].append(process)
            }
            for (windowID, list) in map {
                map[windowID] = list.sorted { lhs, rhs in
                    let lhsOrder = processOrder(lhs)
                    let rhsOrder = processOrder(rhs)
                    if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                    if lhs.templateName != rhs.templateName {
                        return lhs.templateName.localizedStandardCompare(rhs.templateName) == .orderedAscending
                    }
                    return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
                }
            }
            return map
        }()
        let agentTerminalIDs = Set(agentWindows.flatMap { agentTerminalTrackingKeys(for: $0) })
        let agentWindowIDs = Set(agentWindows.compactMap { $0.yabaiWindowID ?? $0.windowID })
        let eligibleProcesses = processes.filter { process in
            let claimedByTerminalID = process.terminalTrackingKey.map(agentTerminalIDs.contains) ?? false
            let claimedByWindowID = process.windowID.map(agentWindowIDs.contains) ?? false
            return !claimedByTerminalID && !claimedByWindowID
        }
        let agentClaimedProcessKeys = Set(
            processes.filter { process in
                (process.terminalTrackingKey.map(agentTerminalIDs.contains) ?? false) || (process.windowID.map(agentWindowIDs.contains) ?? false)
            }.map { processRuntimeKey(name: $0.templateName) })
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
                let linkedByTrackingID = window.terminalTrackingKey.flatMap { processesByTerminalID[$0] } ?? []
                let linkedByWindowID = window.windowID.flatMap { processesByWindowID[$0] } ?? []
                var seen = Set<String>()
                windowProcesses = (linkedByTrackingID + linkedByWindowID).filter { seen.insert($0.id).inserted }
            } else {
                windowProcesses = []
            }
            let isAgentClaimedWindow =
                (window.terminalTrackingKey.map(agentTerminalIDs.contains) ?? false) || (window.windowID.map(agentWindowIDs.contains) ?? false)
            let nonAgentWindowProcesses = windowProcesses.filter { process in
                let claimedByTerminalID = process.terminalTrackingKey.map(agentTerminalIDs.contains) ?? false
                let claimedByWindowID = process.windowID.map(agentWindowIDs.contains) ?? false
                return !claimedByTerminalID && !claimedByWindowID
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

    nonisolated static func deviceWindowShortcutResolution(index: Int, selectedWorkspaceID: String?, overview: SpacesDeviceOverviewPayload)
        -> DeviceWindowShortcutResolution
    {
        guard let selectedWorkspaceID else { return .noWorkspace }
        guard index > 0 else { return .noMatch }
        guard let deviceWorkspace = overview.workspaces.first(where: { $0.id == selectedWorkspaceID }) else { return .noWorkspace }

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
        guard shortcutTargets.indices.contains(index - 1) else { return .noMatch }

        let target = shortcutTargets[index - 1]
        switch target.kind {
        case .browser:
            guard let targetURL = target.targetURL, !targetURL.isEmpty else { return .noMatch }
            return .openURL(targetURL)
        case .process:
            guard let processID = target.processID, let row = detail.processRows.first(where: { ($0.processID ?? $0.id) == processID }),
                let sessionID = row.sessionID
            else { return .noMatch }
            return .openTerminal(
                deviceTerminalOpenRequest(workspaceID: selectedWorkspaceID, sessionID: sessionID, overview: overview)
                    ?? DeviceTerminalOpenRequest(
                        workspaceID: selectedWorkspaceID, sessionID: sessionID, title: row.name, workingDirectory: deviceWorkspace.dir, kind: .process
                    ))
        case .window:
            guard let windowListIndex = target.windowListIndex, detail.terminalRows.indices.contains(windowListIndex),
                let sessionID = detail.terminalRows[windowListIndex].sessionID
            else { return .noMatch }
            let row = detail.terminalRows[windowListIndex]
            return .openTerminal(
                deviceTerminalOpenRequest(workspaceID: selectedWorkspaceID, sessionID: sessionID, overview: overview)
                    ?? DeviceTerminalOpenRequest(
                        workspaceID: selectedWorkspaceID, sessionID: sessionID, title: row.title, workingDirectory: row.workingDirectory, kind: .shell
                    ))
        case .missingConfiguredProcess:
            guard let processKey = target.processKey else { return .noMatch }
            let processTemplateID = detail.config.processes.first { normalizedRunRowName($0.name ?? "") == normalizedRunRowName(processKey) }?.id
            return .runProcess(workspaceID: selectedWorkspaceID, processKey: processKey, processTemplateID: processTemplateID)
        case .agentLauncher:
            guard let launcherName = target.launcherName else { return .noMatch }
            let launcherID = detail.config.agentLaunchers.first { normalizedRunRowName($0.name) == normalizedRunRowName(launcherName) }?.id
            return .runCodingAgent(workspaceID: selectedWorkspaceID, agentName: launcherName, agentLauncherID: launcherID)
        case .agent:
            guard let agentWindow = target.agentWindow, let row = detail.codingAgentRows.first(where: { ($0.agentID ?? $0.id) == agentWindow.id }),
                let sessionID = row.sessionID
            else { return .noMatch }
            return .openTerminal(
                deviceTerminalOpenRequest(workspaceID: selectedWorkspaceID, sessionID: sessionID, overview: overview)
                    ?? DeviceTerminalOpenRequest(
                        workspaceID: selectedWorkspaceID, sessionID: sessionID, title: row.name, workingDirectory: deviceWorkspace.dir, kind: .agent))
        }
    }

    nonisolated static func deviceTerminalOpenRequest(
        workspaceID fallbackWorkspaceID: String, sessionID: String, overview: SpacesDeviceOverviewPayload?
    ) -> DeviceTerminalOpenRequest? {
        let session = overview?.sessions.first { $0.id == sessionID }
        if let session {
            return DeviceTerminalOpenRequest(
                workspaceID: session.workspaceID ?? fallbackWorkspaceID, sessionID: session.id, title: session.title,
                workingDirectory: session.workingDirectory, kind: terminalSessionKind(rowKind: session.rowKind), initialState: session.state,
                servicePID: session.servicePID, childPID: session.childPID, createdAt: session.createdAt, updatedAt: session.updatedAt)
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
        let findItem = editMenu.addItem(withTitle: "Find", action: #selector(TerminalSessionWindowController.find(_:)), keyEquivalent: "f")
        findItem.tag = NSTextFinder.Action.showFindInterface.rawValue
        let findNextItem = editMenu.addItem(
            withTitle: "Find Next", action: #selector(TerminalSessionWindowController.findNext(_:)), keyEquivalent: "g")
        findNextItem.tag = NSTextFinder.Action.nextMatch.rawValue
        let findPreviousItem = editMenu.addItem(
            withTitle: "Find Previous", action: #selector(TerminalSessionWindowController.findPrevious(_:)), keyEquivalent: "g")
        findPreviousItem.keyEquivalentModifierMask = [.command, .shift]
        findPreviousItem.tag = NSTextFinder.Action.previousMatch.rawValue
        let useSelectionForFindItem = editMenu.addItem(
            withTitle: "Use Selection for Find", action: #selector(TerminalSessionWindowController.useSelectionForFind(_:)), keyEquivalent: "e")
        useSelectionForFindItem.tag = NSTextFinder.Action.setSearchString.rawValue
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

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

    private func makeStartupLoadingContentView() -> NSView {
        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

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

        let title = NSTextField(labelWithString: "Starting Spaces…")
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.textColor = .labelColor
        stack.addArrangedSubview(title)

        let detail = NSTextField(labelWithString: "Checking dependencies and loading workspace data.")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        stack.addArrangedSubview(detail)

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor), stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        return content
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

        let topBarRow = sidebar.makeSidebarTopBarRow()
        topBarRow.translatesAutoresizingMaskIntoConstraints = false

        let alertsRow = sidebar.makeAlertsSidebarRow()
        alertsRow.translatesAutoresizingMaskIntoConstraints = false

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

        container.addSubview(topBarRow)
        container.addSubview(alertsRow)
        container.addSubview(sectionHeader)
        container.addSubview(scroll)

        NSLayoutConstraint.activate([
            topBarRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            topBarRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            topBarRow.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),

            alertsRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            alertsRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            alertsRow.topAnchor.constraint(equalTo: topBarRow.bottomAnchor, constant: 8),

            sectionHeader.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            sectionHeader.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            sectionHeader.topAnchor.constraint(equalTo: alertsRow.bottomAnchor, constant: 10),

            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sectionHeader.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.wantsLayer = true
        detailContainer.layer?.backgroundColor = sidebarPanelBackgroundColor().cgColor
        showPlaceholder()
        return detailContainer
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
    func refreshSidebarSelectionRows(
        previousProjectID: String?, currentProjectID: String?, previousWorkspaceID: String?, currentWorkspaceID: String?
    ) {
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
        startPeriodicWorkspaceWindowRefresh()
        startProcessExitMonitoring()
        startWorktreeDiscoveryWatchers()
        sidebar.startRemoteOverviewSubscriptions()
    }

    private func stopBackgroundServices() {
        periodicWorkspaceRefreshTask?.cancel()
        periodicWorkspaceRefreshTask = nil
        stopProcessExitMonitoring()
        stopWorktreeDiscoveryWatchers()
        sidebar.stopSidebarTasks()
        didStartBackgroundServices = false
    }

    enum SetupFlowEntryContext {
        case appLaunch
        case deferredRequirement
    }

    nonisolated static func shouldShowStartupSplashBeforeSetup(entryContext: SetupFlowEntryContext) -> Bool { entryContext == .appLaunch }
    nonisolated static func shouldDeferSetupChecksUntilAfterSplash(entryContext: SetupFlowEntryContext) -> Bool {
        shouldShowStartupSplashBeforeSetup(entryContext: entryContext)
    }
    nonisolated static func scheduleAfterNextRunLoopTurn(_ action: @escaping @MainActor () -> Void) {
        RunLoop.main.perform { Task { @MainActor in action() } }
    }

    private func enterSetupFlow(preferredInitialCheckID: SetupCheckID? = nil, entryContext: SetupFlowEntryContext = .appLaunch) {
        stopBackgroundServices()
        setupManager?.stop()
        let mgr = SetupManager()
        setupManager = mgr
        let startSetupChecks = { [weak self] in
            guard let self, self.setupManager === mgr else { return }
            guard let setupView = mgr.begin(preferredInitialCheckID: preferredInitialCheckID) else { return }
            self.window.contentView = setupView
        }
        if Self.shouldShowStartupSplashBeforeSetup(entryContext: entryContext) {
            // Show a neutral startup view before running setup checks so launch never
            // presents an empty window while the app decides between onboarding and
            // the normal workspace UI.
            window.contentView = makeStartupLoadingContentView()
        }
        mgr.onComplete = { [weak self] in
            self?.logStartupProfile("setup_complete")
            self?.setupManager = nil
            self?.buildMainWindowContent()
            self?.logStartupProfile("main_content_ready")
            self?.showLoadingPlaceholder(message: "Loading projects and workspaces...", detail: "Spaces is preparing your workspace data.")
            self?.logStartupProfile("loading_placeholder_ready")
            Task { @MainActor [weak self] in await self?.sidebar.loadInitialSidebarData() }
        }
        if Self.shouldDeferSetupChecksUntilAfterSplash(entryContext: entryContext) {
            Self.scheduleAfterNextRunLoopTurn { startSetupChecks() }
        } else {
            startSetupChecks()
        }
    }

    func handleDeferredSetupRequirementIfNeeded(_ error: Error) -> Bool {
        guard Self.shouldRouteToDeferredSetup(for: error) else { return false }
        enterSetupFlow(preferredInitialCheckID: .yabaiServiceRunning, entryContext: .deferredRequirement)
        return true
    }

    static func shouldRouteToDeferredSetup(for error: Error) -> Bool {
        if case WorkspaceError.yabaiUnavailable(let message) = error { return message.localizedStandardContains("failed to connect to socket") }
        let message = error.localizedDescription
        return message.localizedStandardContains("yabai-msg") && message.localizedStandardContains("failed to connect to socket")
    }

    static func backgroundRefreshFailureAction(for error: Error) -> BackgroundRefreshFailureAction {
        shouldRouteToDeferredSetup(for: error) ? .deferredSetup : .logOnly
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

    private func deviceForDaemonStateMutation() -> SpacesPairedDeviceRecord? {
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
    private func deviceForWorkspaceMutation(workspaceID: String) -> SpacesPairedDeviceRecord? {
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

    func showDeviceNotLoadedError() { showError(Self.deviceNotLoadedError()) }

    private func deviceProjectSummary(projectID: String) -> SpacesDeviceProjectSummary? {
        // Search every device section's overview, not just the local one, so detail
        // and config flows resolve projects that live on a remote device.
        for section in deviceSections { if let project = section.overview?.projects.first(where: { $0.id == projectID }) { return project } }
        return nil
    }

    private func deviceWorkspaceSummary(workspaceID: String) -> SpacesDeviceWorkspaceSummary? {
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
                deviceSections[index].alertsGroups =
                    (try? Self.buildAlertsGroupsSnapshot(
                        orchestrator: orchestrator, projects: mapped.projects, workspacesByProject: mapped.workspacesByProject)) ?? []
            }
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

    private func updateDeviceWorkspaceConfig(workspaceID: String, update: (inout WorkspaceSettings) -> Void) throws {
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
        showAlertsDetail()
    }

    private func requestVisibleWorkspaceDetailRefreshIfNeeded(reason _: String) {
        guard let workspaceID = selectedWorkspaceID else { return }
        guard
            Self.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: selectedWorkspaceID, showingAlerts: showingAlerts, showingSettings: showingSettings,
                workspaceExists: findWorkspace(id: workspaceID) != nil, mainWindowIsFocused: window?.isKeyWindow == true,
                commandPaletteIsVisible: commandPalette.commandPalettePanel?.isVisible == true)
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

            guard self.selectedWorkspaceID == workspaceID, !self.showingAlerts, !self.showingSettings else { return }
            switch result {
            case .success(let outcome):
                guard outcome.didChangeVisibleState else { return }
                guard self.canReloadAfterBackgroundWorkspaceRefresh() else { return }
                self.reloadData()
            case .failure(let error): self.handleBackgroundRefreshFailure(error, source: "workspace_detail_refresh")
            }
        }
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
        showingSettings = false
        showingAlerts = false
        updateAlertsRowAppearance()
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
            clearInlineWorkspaceFieldRefs()
            clearActiveAddWorkspaceFormState()
            return
        }
        if closingWindow === projectSettingsWindow {
            if let projectSettingsProjectID { ProjectFieldCache.shared.cache[projectSettingsProjectID.hashValue] = nil }
            projectSettingsProjectID = nil
            projectHasUnsavedChanges = false
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

        let fullProject = (try? orchestrator.project(id: project.id))
        let projectSettings:
            (
                setupScript: String?, stopScript: String?, ports: [PortDefinition], processes: [ProcessTemplate], browserSessions: [BrowserSession],
                agentLaunchers: [AgentLauncher]
            )
        if let activeProject = deviceProjectSummary(projectID: project.id).map({ SpacesDeviceProjectSettingsViewModel(project: $0) }) {
            projectSettings = Self.localProjectSettings(from: activeProject.config)
        } else {
            projectSettings = (
                setupScript: fullProject?.setupScript, stopScript: fullProject?.stopScript, ports: fullProject?.ports ?? [],
                processes: fullProject?.processes ?? [], browserSessions: fullProject?.browserSessions ?? [],
                agentLaunchers: fullProject?.agentLaunchers ?? []
            )
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
        let portsSection = PortsSection(ports: projectSettings.ports, subtitle: "Per-workspace named ports, exposed as env vars.")
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
        processesSection.validateProcess = { [weak self] process in try self?.orchestrator.validateProcessTemplate(process) }
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

    private func presentFormWindow(existing: NSWindow?, header: NSView, hosting stack: NSStackView) -> NSWindow {
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
        clearInlineWorkspaceFieldRefs()
        clearActiveAddWorkspaceFormState()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        // --- Fields ---
        let nameField = NSTextField(string: "")
        nameField.placeholderString = "workspace title"
        nameField.setAccessibilityIdentifier("add-workspace-title")
        let baseBranchField = NSComboBox()
        baseBranchField.usesDataSource = false
        baseBranchField.completes = true
        baseBranchField.numberOfVisibleItems = 10
        baseBranchField.setAccessibilityIdentifier("add-workspace-base-branch")
        let baseBranches = project.isGitRepo ? [defaultWorkspaceBaseBranchFast(project: project)].compactMap { $0 } : []
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
        let directoryNameField = NSTextField(string: "")
        directoryNameField.placeholderString = "optional: letters, numbers, -, _"
        directoryNameField.setAccessibilityIdentifier("add-workspace-directory-name")
        let notesField = NSTextField(string: "")
        notesField.placeholderString = "optional: context about what you're working on"
        notesField.setAccessibilityIdentifier("add-workspace-notes")
        let autoNameState = project.isGitRepo ? AddWorkspaceAutoNameState() : nil

        // --- Content card ---
        let contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 10

        var branchModeSegmented: NSSegmentedControl? = nil
        var customizeStack: NSView? = nil
        var customizeButton: NSButton? = nil

        if project.isGitRepo {
            let modeSegmented = NSSegmentedControl(
                labels: ["Create branch", "Use existing"], trackingMode: .selectOne, target: self,
                action: #selector(addWorkspaceBranchModeChanged(_:)))
            modeSegmented.selectedSegment = 0
            modeSegmented.setAccessibilityIdentifier("add-workspace-branch-mode")
            branchModeSegmented = modeSegmented
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

            let customize = NSButton(title: " Customize", target: self, action: #selector(toggleWorkspaceCustomize(_:)))
            customize.bezelStyle = .inline
            customize.controlSize = .small
            customize.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
            customize.imagePosition = .imageLeading
            customize.setAccessibilityIdentifier("add-workspace-customize")
            customizeButton = customize
            contentStack.addArrangedSubview(customize)

            let customStack = NSStackView()
            customStack.orientation = .vertical
            customStack.alignment = .leading
            customStack.spacing = 10
            customStack.isHidden = true
            let targetRow = labeledInputRow(label: "Base branch", input: baseBranchField)
            let titleRow = labeledInputRow(label: "Workspace title", input: nameField)
            let dirRow = labeledInputRow(label: "Directory", input: directoryNameField)
            let notesRow = labeledInputRow(label: "Notes", input: notesField)
            customStack.addArrangedSubview(targetRow)
            customStack.addArrangedSubview(titleRow)
            customStack.addArrangedSubview(dirRow)
            customStack.addArrangedSubview(notesRow)
            constrainFormFieldToFillWidth(targetRow, in: customStack)
            constrainFormFieldToFillWidth(titleRow, in: customStack)
            constrainFormFieldToFillWidth(dirRow, in: customStack)
            constrainFormFieldToFillWidth(notesRow, in: customStack)
            contentStack.addArrangedSubview(customStack)
            constrainFormFieldToFillWidth(customStack, in: contentStack)
            customizeStack = customStack
        } else {
            let titleRow = labeledInputRow(label: "Workspace title", input: nameField)
            contentStack.addArrangedSubview(titleRow)
            constrainFormFieldToFillWidth(titleRow, in: contentStack)

            let customize = NSButton(title: " Customize", target: self, action: #selector(toggleWorkspaceCustomize(_:)))
            customize.bezelStyle = .inline
            customize.controlSize = .small
            customize.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
            customize.imagePosition = .imageLeading
            customizeButton = customize
            contentStack.addArrangedSubview(customize)

            let customStack = NSStackView()
            customStack.orientation = .vertical
            customStack.alignment = .leading
            customStack.spacing = 10
            customStack.isHidden = true
            let notesRow = labeledInputRow(label: "Notes", input: notesField)
            customStack.addArrangedSubview(notesRow)
            constrainFormFieldToFillWidth(notesRow, in: customStack)
            contentStack.addArrangedSubview(customStack)
            constrainFormFieldToFillWidth(customStack, in: contentStack)
            customizeStack = customStack
        }

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
            projectID: project.id, isGitRepo: project.isGitRepo, branchModeSegmented: project.isGitRepo ? branchModeSegmented : nil,
            existingBranchField: project.isGitRepo ? existingBranchField : nil, newBranchField: project.isGitRepo ? newBranchField : nil,
            baseBranchField: project.isGitRepo ? baseBranchField : nil, nameField: nameField,
            directoryNameField: project.isGitRepo ? directoryNameField : nil, notesField: notesField, autoNameState: autoNameState,
            progressiveInputViews: [], createButton: createButton, customizeStack: customizeStack, customizeButton: customizeButton)
        activeAddWorkspaceFormTag = createButton.tag
        if let refs = AddWorkspaceFieldCache.shared.cache[createButton.tag] {
            updateAddWorkspaceBranchInputUI(refs: refs)
            updateAddWorkspaceProgressiveDisclosure(refs: refs, branchValue: currentAddWorkspaceBranchValue(refs))
        }
        Task { @MainActor [weak self, weak newBranchField, weak nameField] in
            await Task.yield()
            guard let self else { return }
            self.addWorkspaceWindow?.makeFirstResponder(project.isGitRepo ? newBranchField : nameField)
        }
        guard project.isGitRepo else { return }
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
            autoNameState?.branchOptions = options
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
    }

    func showWorkspaceDetail(project: ProjectSummary, workspace: WorkspaceSummary) {
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
            showWorkspaceSetupDetail(project: project, workspace: workspace, setupState: setupState)
            return
        }
        stopWorkspaceSetupDetailRefreshTimer()

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
                hasTrackedRuntimeIndicators: false, runningProcessCount: 0, exitedProcessCount: 0, waitingAgentWindowCount: 0,
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
        workspaceTitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
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
        workspaceTitleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        workspaceTitleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        workspaceTitleField.setAccessibilityIdentifier("workspace-detail-title-input")

        let workspaceTitleSlot = Self.makeInlineEditorSlot(label: workspaceTitleLabel, editor: workspaceTitleField)

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.addArrangedSubview(statusDot)
        headerRow.addArrangedSubview(workspaceTitleSlot)
        headerRow.addArrangedSubview(runtimeWarningIcon)
        headerRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let tag = UUID().uuidString.hashValue
        let refs = InlineWorkspaceDetailFieldRefs(
            workspaceID: workspace.id, field: .title, valueLabel: workspaceTitleLabel, editorContainer: workspaceTitleField,
            textField: workspaceTitleField, textView: nil, saveButton: nil, cancelButton: nil, originalValue: workspace.title, isEditing: false)
        inlineWorkspaceFieldRefsByTag[tag] = refs
        inlineWorkspaceFieldTagByObjectID[ObjectIdentifier(workspaceTitleField)] = tag
        inlineWorkspaceLabelTagByObjectID[ObjectIdentifier(workspaceTitleLabel)] = tag
        workspaceTitleField.toolTip = "Press Return to save, Esc to cancel."

        let titleDoubleClick = NSClickGestureRecognizer(target: self, action: #selector(beginInlineWorkspaceMetadataEdit(_:)))
        titleDoubleClick.numberOfClicksRequired = 2
        workspaceTitleLabel.addGestureRecognizer(titleDoubleClick)
        workspaceTitleLabel.toolTip = "Double-click or right-click to rename."

        let titleMenu = NSMenu()
        let titleRenameItem = NSMenuItem(title: "Rename", action: #selector(beginWorkspaceTitleRename(_:)), keyEquivalent: "")
        titleRenameItem.target = self
        titleRenameItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        titleRenameItem.tag = tag
        titleMenu.addItem(titleRenameItem)
        workspaceTitleLabel.menu = titleMenu

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

        // --- Branch (read-only) ---
        let branchValue = (workspace.branch ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let inlineBranchRow: NSView? =
            branchValue.isEmpty
            ? nil
            : makeInlineWorkspaceMetadataEditRow(
                workspaceID: workspace.id, field: .branch, icon: "arrow.triangle.branch", labelText: "Branch", value: branchValue, placeholder: "",
                isEditable: false)

        // --- Inline editable metadata ---
        let inlineNotesRow = makeInlineWorkspaceMetadataEditRow(
            workspaceID: workspace.id, field: .notes, icon: "info.circle", labelText: "Notes", value: workspace.notes ?? "",
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

        let sectionConfig = Self.localWorkspaceSettings(from: deviceWorkspace.config)
        let trackedWindows: [WindowRecord] = Self.deviceTerminalWindows(from: deviceWorkspace.terminalRows)
        let runningProcesses = Self.runningProcesses(from: deviceWorkspace.processRows)
        let agentWindows = Self.agentWindows(from: deviceWorkspace.codingAgentRows)
        let browserSessions = deviceWorkspace.config.resolvedBrowserSessions.map(Self.localBrowserSession(from:))
        let configuredProcesses = sectionConfig.processes
        let configuredAgentLaunchers = sectionConfig.agentLaunchers
        let processEntries = Self.orderedWorkspaceRunProcessEntries(
            configuredProcesses: configuredProcesses, windows: trackedWindows, processes: runningProcesses, agentWindows: agentWindows)
        let processesByID = Dictionary(uniqueKeysWithValues: runningProcesses.map { ($0.id, $0) })
        let shortcutTargets = Self.orderedWorkspaceRunShortcutTargets(
            browserSessions: browserSessions, processEntries: processEntries, processesByID: processesByID,
            configuredAgentLaunchers: configuredAgentLaunchers, agentWindows: agentWindows)
        let shortcutIndices = Self.workspaceDetailShortcutIndices(
            browserSessions: browserSessions, processEntries: processEntries, processesByID: processesByID,
            configuredAgentLaunchers: configuredAgentLaunchers, agentWindows: agentWindows)
        let processStatusByName = Self.workspaceProcessStatusByName(runningProcesses)
        let processesSection = workspaceProcessesSection(
            workspace: workspace, config: sectionConfig, runningProcesses: runningProcesses, trackedWindows: trackedWindows,
            processEntries: processEntries, shortcutTargets: shortcutTargets, shortcutIndicesByName: shortcutIndices.processesByName,
            statusByName: processStatusByName)
        let agentLaunchersSection = workspaceAgentLaunchersSection(
            workspace: workspace, config: sectionConfig, shortcutIndicesByIdentity: shortcutIndices.codingAgentsByIdentity,
            agentWindows: agentWindows, trackedWindows: trackedWindows)
        let browserSessionsSection = workspaceBrowserSessionsSection(
            workspace: workspace, config: sectionConfig, resolvedSessions: browserSessions, shortcutIndicesByURL: shortcutIndices.browserSessionsByURL
        )
        let portsSection = workspacePortsSection(workspace: workspace, config: sectionConfig, assignedPorts: deviceWorkspace.assignedPorts)
        let stopScriptSection = workspaceStopScriptSection(workspace: workspace, config: sectionConfig)

        stack.addArrangedSubview(headerAndActionsRow)
        if let inlineBranchRow { stack.addArrangedSubview(inlineBranchRow) }
        stack.addArrangedSubview(inlineNotesRow)
        for section in Self.orderedWorkspaceDetailSections(
            processesSection: processesSection, browserSessionsSection: browserSessionsSection, agentLaunchersSection: agentLaunchersSection,
            portsSection: portsSection, stopScriptSection: stopScriptSection)
        {
            stack.addArrangedSubview(section)
            constrainFormFieldToFillWidth(section, in: stack)
            stack.setCustomSpacing(10, after: section)
        }
        if let agentLaunchersSection { stack.setCustomSpacing(20, after: agentLaunchersSection) }
        if let portsSection { stack.setCustomSpacing(20, after: portsSection) }
        stack.setCustomSpacing(20, after: headerAndActionsRow)
        if let inlineBranchRow {
            stack.setCustomSpacing(8, after: headerAndActionsRow)
            stack.setCustomSpacing(20, after: inlineBranchRow)
            constrainFormFieldToFillWidth(inlineBranchRow, in: stack)
        }
        stack.setCustomSpacing(20, after: inlineNotesRow)
        constrainFormFieldToFillWidth(inlineNotesRow, in: stack)
        constrainFormFieldToFillWidth(headerRow, in: headerAndActionsRow)
        constrainFormFieldToFillWidth(dirField, in: headerAndActionsRow)
        constrainFormFieldToFillWidth(headerAndActionsRow, in: stack)
        showScrollableDetailStack(stack)
        detailContainer.layoutSubtreeIfNeeded()
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

        let title = NSTextField(labelWithString: "Loading \(workspace.title)...")
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

    private func showWorkspaceSetupDetail(project: ProjectSummary, workspace: WorkspaceSummary, setupState: WorkspaceSetupState) {
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

        let titleLabel = NSTextField(labelWithString: inlineWorkspaceFieldDisplayValue(workspace.title, field: .title))
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

        let copyLogButton = actionButton(
            title: "Copy Log", symbol: "doc.on.doc", tooltip: "Copy setup log", action: #selector(copyWorkspaceSetupLog(_:)), primary: false)
        copyLogButton.identifier = NSUserInterfaceItemIdentifier(setupState.logPath ?? "")
        copyLogButton.isEnabled = setupState.logPath?.isEmpty == false
        copyLogButton.setAccessibilityIdentifier("workspace-setup-copy-log")

        let openLogButton = actionButton(
            title: "Open Log", symbol: "doc.text.magnifyingglass", tooltip: "Open setup log", action: #selector(openWorkspaceSetupLog(_:)),
            primary: false)
        openLogButton.identifier = NSUserInterfaceItemIdentifier(setupState.logPath ?? "")
        openLogButton.isEnabled = setupState.logPath?.isEmpty == false
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
        let logView = workspaceSetupLogTailView(path: setupState.logPath)
        statusContent.addArrangedSubview(logView)
        constrainFormFieldToFillWidth(logView, in: statusContent)

        let statusCard = formSectionCard(
            icon: nil, title: "Workspace Setup", subtitle: workspaceSetupPanelSubtitle(setupState.status),
            iconColor: workspaceSetupStatusColor(setupState.status), contentViews: [statusContent])
        stack.addArrangedSubview(statusCard)
        constrainFormFieldToFillWidth(statusCard, in: stack)

        if Self.shouldShowWorkspaceSetupScriptEditor(status: setupState.status) {
            let fullProject = (try? orchestrator.project(id: project.id))
            let activeProjectConfig = deviceProjectSummary(projectID: project.id)?.config
            let setupScriptSection = ScriptSection(
                title: "Setup Script", editAccessibilityIdentifier: "setup-script-edit", formAccessibilityPrefix: "project-setup-script",
                value: activeProjectConfig?.setupScript ?? fullProject?.setupScript ?? "",
                subtitle: "Edit the project setup script, then run setup again.")
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

    private func workspaceSetupLogTailView(path: String?) -> NSView {
        let textView = NSTextView()
        textView.isRichText = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let text = path.flatMap { Self.workspaceSetupLogTail(path: $0, maxBytes: 16_384) } ?? ""
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

    private static func workspaceSetupLogTail(path: String, maxBytes: UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return "" }
        defer { try? handle.close() }
        let endOffset = (try? handle.seekToEnd()) ?? 0
        let startOffset = endOffset > maxBytes ? endOffset - maxBytes : 0
        try? handle.seek(toOffset: startOffset)
        guard let data = try? handle.readToEnd() else { return "" }
        var text = String(decoding: data, as: UTF8.self)
        if startOffset > 0, let firstNewline = text.firstIndex(of: "\n") { text = "...\n" + String(text[text.index(after: firstNewline)...]) }
        return text
    }

    private func workspaceProcessesSection(
        workspace: WorkspaceSummary, config providedConfig: WorkspaceSettings? = nil,
        runningProcesses providedRunningProcesses: [RunningProcessRecord]? = nil, trackedWindows: [WindowRecord],
        processEntries: [WorkspaceRunProcessEntry], shortcutTargets: [WorkspaceRunShortcutTarget], shortcutIndicesByName: [String: Int],
        statusByName: [String: RowPrimitives.StatusKind]
    ) -> NSView? {
        guard let config = providedConfig else { return nil }
        let runningProcesses = providedRunningProcesses ?? []
        let runningProcessIDByName = Dictionary(uniqueKeysWithValues: runningProcesses.map { (Self.processRuntimeKey(name: $0.templateName), $0.id) })
        let section = ProcessesSection(processes: config.processes)
        section.validateProcess = { [weak self] process in try self?.orchestrator.validateProcessTemplate(process) }
        section.presentValidationError = { [weak self] error in self?.showError(error) }
        section.onCommit = { [weak self] updated in
            guard let self else { return }
            do {
                if deviceForDaemonStateMutation() != nil {
                    try updateDeviceWorkspaceConfig(workspaceID: workspace.id) { $0.processes = updated }
                } else {
                    showDeviceNotLoadedError()
                    return
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
                if let device = deviceForDaemonStateMutation() {
                    let response = try SpacesDeviceClient.runWorkspaceProcess(
                        workspaceID: workspace.id, processKey: key, processTemplateID: process.id, device: device,
                        clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                    applyDeviceMutationResponse(response, selectedWorkspaceID: workspace.id)
                } else {
                    showDeviceNotLoadedError()
                }
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
                if let device = deviceForDaemonStateMutation() {
                    let response = try SpacesDeviceClient.stopWorkspaceProcess(
                        workspaceID: workspace.id, processID: processID, processKey: key, processTemplateID: process.id, device: device,
                        clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                    applyDeviceMutationResponse(response, selectedWorkspaceID: workspace.id)
                } else {
                    showDeviceNotLoadedError()
                }
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
                if let device = deviceForDaemonStateMutation() {
                    let response = try SpacesDeviceClient.restartWorkspaceProcess(
                        workspaceID: workspace.id, processID: processID, processKey: key, processTemplateID: process.id, device: device,
                        clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                    applyDeviceMutationResponse(response, selectedWorkspaceID: workspace.id)
                } else {
                    showDeviceNotLoadedError()
                }
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
        let windowShortcutByListIndex: [Int: Int] = Dictionary(
            uniqueKeysWithValues: shortcutTargets.enumerated().compactMap { offset, target in
                guard target.kind == .window, let windowListIndex = target.windowListIndex else { return nil }
                return (windowListIndex, offset + 1)
            })
        section.supplementalRows = processEntries.compactMap { entry in
            guard entry.kind == .window, let windowListIndex = entry.windowListIndex, trackedWindows.indices.contains(windowListIndex) else {
                return nil
            }
            let window = trackedWindows[windowListIndex]
            guard window.role == "terminal" else { return nil }
            let fallback = Self.terminalFallbackRowText(name: window.name, detail: window.detail, app: window.app)
            let shortcut = windowShortcutByListIndex[windowListIndex].map(windowShortcutBadgeText(index:))
            return ProcessesSection.SupplementalRuntimeRow(
                id: window.id, label: fallback.label, detail: fallback.detail, shortcut: shortcut, status: .running,
                onFocus: { [weak self] in
                    guard let self else { return }
                    Task { @MainActor [weak self] in
                        await self?.runWindowShortcut(index: windowShortcutByListIndex[windowListIndex] ?? 0, startedAt: Date())
                    }
                })
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
                    if let windowID = agentWindow.yabaiWindowID ?? agentWindow.windowID, $0.windowID == windowID { return true }
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

    private func workspaceAgentLaunchersSection(
        workspace: WorkspaceSummary, config providedConfig: WorkspaceSettings? = nil, shortcutIndicesByIdentity: [String: Int],
        agentWindows: [AgentWindowRecord], trackedWindows: [WindowRecord]
    ) -> NSView? {
        guard let config = providedConfig else { return nil }
        let section = AgentLaunchersSection(launchers: config.agentLaunchers)
        section.runtimeAgentWindows = agentWindows
        section.runtimeWindowTitleByAgentWindowID = Self.codingAgentWindowTitleByAgentID(agentWindows: agentWindows, trackedWindows: trackedWindows)
        section.onCommit = { [weak self] updated in
            guard let self else { return }
            do {
                if deviceForDaemonStateMutation() != nil {
                    try updateDeviceWorkspaceConfig(workspaceID: workspace.id) { $0.agentLaunchers = updated }
                } else {
                    showDeviceNotLoadedError()
                }
            } catch { showError(error) }
        }
        section.onRunLauncher = { [weak self] launcher in
            guard let self else { return }
            do {
                if let device = deviceForDaemonStateMutation() {
                    let response = try SpacesDeviceClient.runCodingAgent(
                        workspaceID: workspace.id, agentName: launcher.name, agentLauncherID: launcher.id, device: device,
                        clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                    applyDeviceMutationResponse(response, selectedWorkspaceID: workspace.id)
                } else {
                    showDeviceNotLoadedError()
                }
            } catch {
                reloadData()
                showError(error)
            }
        }
        section.onStopAgentWindow = { [weak self] agentWindow in
            guard let self else { return }
            do {
                if let device = deviceForDaemonStateMutation() {
                    let response = try SpacesDeviceClient.stopCodingAgent(
                        workspaceID: workspace.id, agentID: agentWindow.id, agentName: agentWindow.claimedLauncherName ?? agentWindow.label,
                        agentLauncherID: agentWindow.claimedLauncherID, device: device,
                        clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                    applyDeviceMutationResponse(response, selectedWorkspaceID: workspace.id)
                } else {
                    showDeviceNotLoadedError()
                }
            } catch {
                reloadData()
                showError(error)
            }
        }
        section.onRestartAgentWindow = { [weak self] agentWindow in
            guard let self else { return }
            do {
                if let device = deviceForDaemonStateMutation() {
                    let response = try SpacesDeviceClient.restartCodingAgent(
                        workspaceID: workspace.id, agentID: agentWindow.id, agentName: agentWindow.claimedLauncherName ?? agentWindow.label,
                        agentLauncherID: agentWindow.claimedLauncherID, device: device,
                        clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                    applyDeviceMutationResponse(response, selectedWorkspaceID: workspace.id)
                } else {
                    showDeviceNotLoadedError()
                }
            } catch {
                reloadData()
                showError(error)
            }
        }
        var identityToIndex: [String: Int] = [:]
        var shortcutMap: [String: String] = [:]
        for entry in Self.resolvedCodingAgentRunEntries(configuredAgentLaunchers: config.agentLaunchers, agentWindows: agentWindows) {
            let identity: String
            if let agentWindow = entry.agentWindow {
                identity = Self.codingAgentShortcutIdentity(agentWindowID: agentWindow.id)
            } else if let launcherName = entry.launcherName, !launcherName.isEmpty {
                identity = Self.codingAgentShortcutIdentity(launcherName: launcherName)
            } else {
                continue
            }
            guard let index = shortcutIndicesByIdentity[identity] else { continue }
            shortcutMap[identity] = windowShortcutBadgeText(index: index)
            identityToIndex[identity] = index
        }
        section.onFocusLauncher = { [weak self] launcher in
            let identity = Self.codingAgentShortcutIdentity(launcherName: launcher.name)
            guard let self, let index = identityToIndex[identity] else { return }
            Task { @MainActor [weak self] in await self?.runWindowShortcut(index: index, startedAt: Date()) }
        }
        section.onFocusAgentWindow = { [weak self] agentWindow in
            let identity = Self.codingAgentShortcutIdentity(agentWindowID: agentWindow.id)
            guard let self, let index = identityToIndex[identity] else { return }
            Task { @MainActor [weak self] in await self?.runWindowShortcut(index: index, startedAt: Date()) }
        }
        section.shortcutsByIdentity = shortcutMap
        return section.view
    }

    private func workspaceBrowserSessionsSection(
        workspace: WorkspaceSummary, config providedConfig: WorkspaceSettings? = nil,
        resolvedSessions providedResolvedSessions: [BrowserSession]? = nil, shortcutIndicesByURL: [String: Int]
    ) -> NSView? {
        guard let config = providedConfig else { return nil }
        let resolvedSessions = providedResolvedSessions ?? []
        let displayURLs = Self.browserSessionDisplayURLs(configuredSessions: config.browserSessions, resolvedSessions: resolvedSessions)
        let section = BrowserSessionsSection(sessions: config.browserSessions, collapsedDisplayURLs: displayURLs)
        section.onCommit = { [weak self] updated in
            guard let self else { return }
            do {
                if deviceForDaemonStateMutation() != nil {
                    try updateDeviceWorkspaceConfig(workspaceID: workspace.id) { $0.browserSessions = updated }
                } else {
                    showDeviceNotLoadedError()
                }
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

    private func workspacePortsSection(
        workspace: WorkspaceSummary, config providedConfig: WorkspaceSettings? = nil,
        assignedPorts providedAssignedPorts: [SpacesDeviceAssignedPort]? = nil
    ) -> NSView? {
        guard let config = providedConfig else { return nil }
        let reservedPorts = providedAssignedPorts?.map(\.port) ?? []
        let section = PortsSection(ports: config.ports, collapsedDisplayPorts: reservedPorts.map(Optional.some))
        section.onCommit = { [weak self] updated in
            guard let self else { return }
            do {
                if deviceForDaemonStateMutation() != nil {
                    try updateDeviceWorkspaceConfig(workspaceID: workspace.id) { $0.ports = updated }
                } else {
                    showDeviceNotLoadedError()
                }
            } catch { showError(error) }
        }
        return section.view
    }

    private func workspaceStopScriptSection(workspace: WorkspaceSummary, config providedConfig: WorkspaceSettings? = nil) -> NSView? {
        guard let config = providedConfig else { return nil }
        let section = ScriptSection(
            title: "Stop Script", editAccessibilityIdentifier: "stop-script-edit", formAccessibilityPrefix: "workspace-stop-script",
            value: config.stopScript ?? "")
        section.onCommit = { [weak self] value in
            guard let self else { return }
            do {
                if deviceForDaemonStateMutation() != nil {
                    try updateDeviceWorkspaceConfig(workspaceID: workspace.id) { $0.stopScript = value.isEmpty ? nil : value }
                } else {
                    showDeviceNotLoadedError()
                }
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
        clearInlineWorkspaceFieldRefs()
        clearActiveAddWorkspaceFormState()
        closeVisibleAddFormWindows()
        flushDeferredSidebarReloadsIfNeeded()
    }

    private func closeVisibleAddFormWindows() {
        if addProjectWindow?.isVisible == true { addProjectWindow?.close() }
        if addWorkspaceWindow?.isVisible == true { addWorkspaceWindow?.close() }
        if projectSettingsWindow?.isVisible == true { projectSettingsWindow?.close() }
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
                if self.isView(hitView, descendantOf: refs.editorContainer)
                    || (refs.saveButton.map { self.isView(hitView, descendantOf: $0) } ?? false)
                    || (refs.cancelButton.map { self.isView(hitView, descendantOf: $0) } ?? false)
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
        case .notes: return trimmed.isEmpty ? "No notes" : trimmed
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
            case .notes: "workspace-detail-notes"
            }
        let isMultiline = field == .notes
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = isMultiline ? .top : .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setAccessibilityIdentifier("\(automationID)-row")

        let iconContainer = NSView()
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.setContentHuggingPriority(.required, for: .horizontal)
        iconContainer.setContentCompressionResistancePriority(.required, for: .horizontal)

        let iconView = NSImageView()
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: labelText)?.withSymbolConfiguration(iconConfig)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(iconView)

        NSLayoutConstraint.activate([
            iconContainer.widthAnchor.constraint(equalToConstant: 16), iconContainer.heightAnchor.constraint(equalToConstant: 16),
            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor, constant: 1),
        ])

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

        let textField: NSTextField?
        let textView: NSTextView?
        let editorContainer: NSView
        if isMultiline {
            let multilineTextView = makeEditableTextView()
            multilineTextView.string = value
            multilineTextView.font = .systemFont(ofSize: 12)
            multilineTextView.setAccessibilityIdentifier("\(automationID)-input")
            let scrollView = scrollableTextView(multilineTextView, height: 72)
            scrollView.isHidden = true
            scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textField = nil
            textView = multilineTextView
            editorContainer = scrollView
        } else {
            let singleLineField = NSTextField(string: value)
            singleLineField.placeholderString = placeholder
            singleLineField.delegate = self
            singleLineField.isEnabled = isEditable
            singleLineField.isHidden = true
            singleLineField.font = .systemFont(ofSize: 12)
            singleLineField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            singleLineField.setAccessibilityIdentifier("\(automationID)-input")
            textField = singleLineField
            textView = nil
            editorContainer = singleLineField
        }

        let saveButtonTitle = isMultiline ? "Save (⌘↩)" : "Save (↩)"
        let saveButton = NSButton(title: saveButtonTitle, target: self, action: #selector(saveInlineWorkspaceMetadata(_:)))
        saveButton.controlSize = .small
        saveButton.bezelStyle = .rounded
        saveButton.isHidden = true
        saveButton.setAccessibilityIdentifier("\(automationID)-save")
        saveButton.toolTip = isMultiline ? "Save notes (⌘↩)." : "Save (↩)."

        let cancelButton = NSButton(title: "Cancel (Esc)", target: self, action: #selector(cancelInlineWorkspaceMetadata(_:)))
        cancelButton.controlSize = .small
        cancelButton.bezelStyle = .rounded
        cancelButton.isHidden = true
        cancelButton.setAccessibilityIdentifier("\(automationID)-cancel")
        cancelButton.toolTip = isMultiline ? "Cancel notes edit (Esc)." : "Cancel (Esc)."

        row.addArrangedSubview(iconContainer)
        if isMultiline {
            let contentStack = NSStackView()
            contentStack.orientation = .vertical
            contentStack.alignment = .leading
            contentStack.spacing = 6
            contentStack.translatesAutoresizingMaskIntoConstraints = false
            contentStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let buttonRow = NSStackView()
            buttonRow.orientation = .horizontal
            buttonRow.alignment = .centerY
            buttonRow.spacing = 8
            buttonRow.translatesAutoresizingMaskIntoConstraints = false
            buttonRow.addArrangedSubview(cancelButton)
            buttonRow.addArrangedSubview(saveButton)

            contentStack.addArrangedSubview(valueLabel)
            contentStack.addArrangedSubview(editorContainer)
            contentStack.addArrangedSubview(buttonRow)
            row.addArrangedSubview(contentStack)
        } else {
            row.addArrangedSubview(valueLabel)
            row.addArrangedSubview(editorContainer)
            row.addArrangedSubview(cancelButton)
            row.addArrangedSubview(saveButton)
        }

        if isEditable {
            let tag = UUID().uuidString.hashValue
            let refs = InlineWorkspaceDetailFieldRefs(
                workspaceID: workspaceID, field: field, valueLabel: valueLabel, editorContainer: editorContainer, textField: textField,
                textView: textView, saveButton: saveButton, cancelButton: cancelButton, originalValue: value, isEditing: false)
            inlineWorkspaceFieldRefsByTag[tag] = refs
            if let textField { inlineWorkspaceFieldTagByObjectID[ObjectIdentifier(textField)] = tag }
            inlineWorkspaceLabelTagByObjectID[ObjectIdentifier(valueLabel)] = tag
            saveButton.tag = tag
            cancelButton.tag = tag
            if let textView = textView as? InlineWorkspaceEditorTextView {
                textView.onSave = { [weak self] in self?.saveInlineWorkspaceMetadata(tag: tag) }
                textView.onCancel = { [weak self] in self?.cancelInlineWorkspaceMetadataEdit(tag: tag) }
            }

            let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(beginInlineWorkspaceMetadataEdit(_:)))
            doubleClick.numberOfClicksRequired = 2
            valueLabel.addGestureRecognizer(doubleClick)
        } else {
            editorContainer.toolTip = field == .branch ? "Protected branch names main/master cannot be renamed." : "\(labelText) is not editable."
        }

        return row
    }

    private func inlineWorkspaceEditorValue(_ refs: InlineWorkspaceDetailFieldRefs) -> String {
        if let textField = refs.textField { return textField.stringValue }
        if let textView = refs.textView { return textView.string }
        return ""
    }

    private func setInlineWorkspaceEditorValue(_ value: String, refs: InlineWorkspaceDetailFieldRefs) {
        refs.textField?.stringValue = value
        refs.textView?.string = value
    }

    private func setInlineWorkspaceEditorHidden(_ isHidden: Bool, refs: InlineWorkspaceDetailFieldRefs) {
        refs.editorContainer.isHidden = isHidden
        refs.textField?.isHidden = isHidden
    }

    private func focusInlineWorkspaceEditor(_ refs: InlineWorkspaceDetailFieldRefs) {
        if let textField = refs.textField {
            textField.isEnabled = true
            textField.becomeFirstResponder()
            return
        }
        if let textView = refs.textView {
            window?.makeFirstResponder(textView)
            return
        }
    }

    private func normalizeInlineWorkspaceMetadataValue(_ value: String, for field: InlineWorkspaceDetailField) -> String {
        switch field {
        case .title, .branch: return value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .notes: return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func updateInlineWorkspaceMetadataButtons(tag: Int) {
        guard let refs = inlineWorkspaceFieldRefsByTag[tag] else { return }
        refs.saveButton?.isHidden = !refs.isEditing
        refs.cancelButton?.isHidden = !refs.isEditing
    }

    @objc private func beginInlineWorkspaceMetadataEdit(_ sender: NSClickGestureRecognizer) {
        guard let valueLabel = sender.view as? NSTextField else { return }
        guard let tag = inlineWorkspaceLabelTagByObjectID[ObjectIdentifier(valueLabel)] else { return }
        beginInlineWorkspaceMetadataEdit(tag: tag)
    }

    @objc private func beginWorkspaceTitleRename(_ sender: NSMenuItem) { beginInlineWorkspaceMetadataEdit(tag: sender.tag) }

    private func beginInlineWorkspaceMetadataEdit(tag: Int) {
        if let refs = inlineWorkspaceFieldRefsByTag[tag], refs.field == .branch, isProtectedBranchName(refs.originalValue) { return }
        for activeTag in activeInlineWorkspaceEditTags() where activeTag != tag { cancelInlineWorkspaceMetadataEdit(tag: activeTag) }
        guard var refs = inlineWorkspaceFieldRefsByTag[tag] else { return }
        refs.isEditing = true
        refs.valueLabel.isHidden = true
        setInlineWorkspaceEditorValue(refs.originalValue, refs: refs)
        setInlineWorkspaceEditorHidden(false, refs: refs)
        setupInlineWorkspaceOutsideClickMonitorIfNeeded()
        inlineWorkspaceFieldRefsByTag[tag] = refs
        focusInlineWorkspaceEditor(refs)
        updateInlineWorkspaceMetadataButtons(tag: tag)
    }

    private func endInlineWorkspaceMetadataEdit(tag: Int, keepCurrentValueAsOriginal: Bool) {
        guard var refs = inlineWorkspaceFieldRefsByTag[tag] else { return }
        if keepCurrentValueAsOriginal {
            refs.originalValue = normalizeInlineWorkspaceMetadataValue(inlineWorkspaceEditorValue(refs), for: refs.field)
        } else {
            setInlineWorkspaceEditorValue(refs.originalValue, refs: refs)
        }
        refs.valueLabel.stringValue = inlineWorkspaceFieldDisplayValue(refs.originalValue, field: refs.field)
        refs.valueLabel.isHidden = false
        setInlineWorkspaceEditorHidden(true, refs: refs)
        refs.isEditing = false
        refs.saveButton?.isHidden = true
        refs.cancelButton?.isHidden = true
        inlineWorkspaceFieldRefsByTag[tag] = refs
        if activeInlineWorkspaceEditTags().isEmpty { teardownInlineWorkspaceOutsideClickMonitor() }
    }

    private func saveInlineWorkspaceMetadata(tag: Int) {
        guard var refs = inlineWorkspaceFieldRefsByTag[tag] else { return }
        do {
            if let device = deviceForDaemonStateMutation() {
                let response: SpacesDeviceAPIResponse
                switch refs.field {
                case .title:
                    let title = inlineWorkspaceEditorValue(refs).trimmingCharacters(in: .whitespacesAndNewlines)
                    response = try SpacesDeviceClient.updateWorkspaceMetadata(
                        workspaceID: refs.workspaceID, title: title, updatesTitle: true, device: device,
                        clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                    refs.originalValue = title
                case .branch:
                    let branch = inlineWorkspaceEditorValue(refs).trimmingCharacters(in: .whitespacesAndNewlines)
                    response = try SpacesDeviceClient.updateWorkspaceMetadata(
                        workspaceID: refs.workspaceID, branch: branch, updatesBranch: true, device: device,
                        clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                    refs.originalValue = branch
                case .notes:
                    let trimmedNotes = inlineWorkspaceEditorValue(refs).trimmingCharacters(in: .whitespacesAndNewlines)
                    let notes = trimmedNotes.isEmpty ? nil : trimmedNotes
                    response = try SpacesDeviceClient.updateWorkspaceMetadata(
                        workspaceID: refs.workspaceID, notes: notes, updatesNotes: true, device: device,
                        clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                    refs.originalValue = notes ?? ""
                }
                refs.valueLabel.stringValue = inlineWorkspaceFieldDisplayValue(refs.originalValue, field: refs.field)
                inlineWorkspaceFieldRefsByTag[tag] = refs
                endInlineWorkspaceMetadataEdit(tag: tag, keepCurrentValueAsOriginal: true)
                applyDeviceMutationResponse(response, selectedWorkspaceID: refs.workspaceID)
                return
            }
            showDeviceNotLoadedError()
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

    func helpTextLabel(_ text: String) -> NSTextField {
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

    struct EditorOption {
        let preference: EditorPreference
        let displayName: String
        let bundleName: String
    }

    func installedEditorOptions() -> [EditorOption] {
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

    func editorDisplayName(_ editor: EditorPreference) -> String {
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
        row.spacing = 5
        workspaceShortcutFooterRowView = row
        populateWorkspaceShortcutFooterRow(row)
        return row
    }

    private func populateWorkspaceShortcutFooterRow(_ row: NSStackView) {
        for view in row.arrangedSubviews {
            row.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, segment) in workspaceDetailShortcutFooterSegments().enumerated() {
            if index > 0 {
                let sep = NSTextField(labelWithString: "|")
                sep.font = .systemFont(ofSize: 10, weight: .thin)
                sep.textColor = .quaternaryLabelColor
                row.addArrangedSubview(sep)
            }
            let group = NSStackView()
            group.orientation = .horizontal
            group.alignment = .centerY
            group.spacing = 3
            let chip = footerShortcutHint(for: segment.setting)
            if !chip.isEmpty { group.addArrangedSubview(RowPrimitives.shortcutChip(chip)) }
            let lbl = NSTextField(labelWithString: segment.label)
            lbl.font = .systemFont(ofSize: 10.5, weight: .regular)
            lbl.textColor = .secondaryLabelColor
            lbl.lineBreakMode = .byTruncatingTail
            lbl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            group.addArrangedSubview(lbl)
            row.addArrangedSubview(group)
        }
        row.addArrangedSubview(NSView())
    }

    private func refreshWorkspaceShortcutFooterRow() {
        guard let row = workspaceShortcutFooterRowView else { return }
        populateWorkspaceShortcutFooterRow(row)
    }

    private func workspaceDetailShortcutFooterSegments() -> [(label: String, setting: ShortcutSetting)] {
        [
            ("Toggle app", .guiHotkey), ("Palette", .guiCommandPaletteHotkey), ("Alerts", .guiAlertsShortcut), ("Settings", .guiOpenSettingsShortcut),
            ("Open editor", .guiOpenEditorShortcut), ("New terminal", .guiOpenTerminalShortcut), ("Next window", .guiNextShortcut),
            ("Prev window", .guiPreviousShortcut),
        ]
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
        baseBranchField: NSComboBox?, nameField: NSTextField, directoryNameField: NSTextField?, notesField: NSTextField?,
        autoNameState: AddWorkspaceAutoNameState?, progressiveInputViews: [NSView], createButton: NSButton, customizeStack: NSView?,
        customizeButton: NSButton?
    ) -> Int {
        let id = UUID().uuidString.hashValue
        AddWorkspaceFieldCache.shared.cache[id] = AddWorkspaceFieldRefs(
            projectID: projectID, isGitRepo: isGitRepo, branchModeSegmented: branchModeSegmented, existingBranchField: existingBranchField,
            newBranchField: newBranchField, baseBranchField: baseBranchField, nameField: nameField, directoryNameField: directoryNameField,
            notesField: notesField, autoNameState: autoNameState, progressiveInputViews: progressiveInputViews, createButton: createButton,
            customizeStack: customizeStack, customizeButton: customizeButton)
        branchModeSegmented?.tag = id
        customizeButton?.tag = id
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
        guard let path = Self.senderIdentifier(sender), !path.isEmpty else { return }
        let contents = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
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

    private func presentManagedDirectoryReplacementPrompt(candidates: [WorkspaceOrchestrator.ManagedDirectoryReplacementCandidate]) -> Bool {
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
                let preparedGitProjectForDiscard = refs.preparedGitProject
                let preparedGitURLForDiscard = refs.preparedGitURL
                refs.preparedGitProject = nil
                refs.preparedGitURL = nil
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
                    if let preparedGitProjectForDiscard {
                        _ = await beginPreparedGitProjectDiscard(preparedGitProjectForDiscard, repoURL: preparedGitURLForDiscard).value
                    }
                    let result = await Self.deviceMutation(device: device) { device in
                        try SpacesDeviceClient.createProject(
                            projectDir: projectDir, gitURL: gitURL, config: config, device: device,
                            clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
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
                    case .failure(let error): showError(error)
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
        let usesDeviceCreate = deviceRecord(forDeviceID: refs.selectedDeviceID) != nil
        refs.localSourceSection.isHidden = cloneSelected
        refs.cloneSourceSection.isHidden = !cloneSelected
        let repoURL = refs.repoURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let gitPrepared = refs.preparedGitProject != nil && refs.preparedGitURL == repoURL
        let gitPreparing = refs.gitPreparationID != nil
        refs.prepareButton.isHidden = usesDeviceCreate
        refs.prepareButton.title = gitPreparing ? "Cloning..." : (gitPrepared ? "Cloned" : "Clone")
        refs.prepareButton.isEnabled = !usesDeviceCreate && cloneSelected && !repoURL.isEmpty && !gitPrepared && !gitPreparing
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
            if deviceRecord(forDeviceID: refs.selectedDeviceID) != nil { return !repoURL.isEmpty && refs.gitPreparationID == nil }
            return refs.gitPreparationID == nil && refs.preparedGitProject != nil && refs.preparedGitURL == repoURL
        }
        let directoryPath = refs.dirField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return !directoryPath.isEmpty && refs.preparedLocalDirectoryPath == directoryPath
    }

    nonisolated static func preparedGitProjectResultMatchesActiveRequest(
        isActiveForm: Bool, selectedSegment: Int, currentRepoURL: String, requestedRepoURL: String, currentPreparationID: UUID?,
        completionPreparationID: UUID
    ) -> Bool { isActiveForm && selectedSegment == 1 && currentRepoURL == requestedRepoURL && currentPreparationID == completionPreparationID }

    nonisolated static func localProjectPreviewResultMatchesActiveRequest(
        isActiveForm: Bool, selectedSegment: Int, currentDirectoryPath: String, requestedDirectoryPath: String
    ) -> Bool { isActiveForm && selectedSegment == 0 && currentDirectoryPath == requestedDirectoryPath }

    nonisolated static func preparedGitProjectDiscardKey(repoURL: String?) -> String? {
        guard let key = repoURL?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return nil }
        return key
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
        if refs.preparedGitProject != nil, refs.preparedGitURL == repoURL {
            updateAddProjectSourceUI(refs)
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
            if let previous = refs.preparedGitProject {
                let discardResult = await beginPreparedGitProjectDiscard(previous, repoURL: refs.preparedGitURL).value
                if case .failure(let error) = discardResult {
                    refs.preparedGitProject = nil
                    refs.preparedGitURL = nil
                    showError(error)
                    return
                }
                refs.preparedGitProject = nil
                refs.preparedGitURL = nil
            }
            if let discardResult = await activePreparedGitProjectDiscardResult(repoURL: repoURL), case .failure(let error) = discardResult {
                showError(error)
                return
            }
            let replacementCandidates: [WorkspaceOrchestrator.ManagedDirectoryReplacementCandidate]
            do { replacementCandidates = try orchestrator.managedGitProjectImportReplacementCandidates(gitURL: repoURL) } catch {
                showError(error)
                return
            }
            let replaceExistingManagedDirectories = !replacementCandidates.isEmpty
            if replaceExistingManagedDirectories, !presentManagedDirectoryReplacementPrompt(candidates: replacementCandidates) { return }
            let result = await Self.prepareGitProjectSourceSnapshot(
                gitURL: repoURL, replaceExistingManagedDirectories: replaceExistingManagedDirectories)
            guard
                Self.preparedGitProjectResultMatchesActiveRequest(
                    isActiveForm: isActiveAddProjectForm(refs), selectedSegment: refs.sourceSegmented.selectedSegment,
                    currentRepoURL: refs.repoURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), requestedRepoURL: repoURL,
                    currentPreparationID: refs.gitPreparationID, completionPreparationID: preparationID)
            else {
                if case .success(let prepared) = result { _ = await beginPreparedGitProjectDiscard(prepared, repoURL: repoURL).value }
                return
            }
            switch result {
            case .success(let prepared):
                refs.preparedGitProject = prepared
                refs.preparedGitURL = repoURL
                hydrateAddProjectSettings(refs, from: prepared.project)
            case .failure(let error):
                refs.preparedGitProject = nil
                refs.preparedGitURL = nil
                showError(error)
            }
        }
    }

    private func hydrateAddProjectSettings(_ refs: AddProjectFieldRefs, from project: ProjectRecord) {
        refs.setupScriptSection.replace(value: project.setupScript ?? "")
        refs.stopScriptSection.replace(value: project.stopScript ?? "")
        refs.portsSection.replace(ports: project.ports)
        refs.processesSection.replace(processes: project.processes)
        refs.browserSessionsSection.replace(sessions: project.browserSessions)
        refs.agentLaunchersSection.replace(launchers: project.agentLaunchers)
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
        guard let prepared = refs.preparedGitProject else { return }
        let repoURL = refs.preparedGitURL
        refs.preparedGitProject = nil
        refs.preparedGitURL = nil
        let discardTask = beginPreparedGitProjectDiscard(prepared, repoURL: repoURL)
        Task { @MainActor [weak self] in
            let result = await discardTask.value
            if case .failure(let error) = result { self?.showError(error) }
        }
    }

    private func discardActiveAddProjectPreparedSourceIfNeeded() {
        guard let activeAddProjectFormTag, let refs = AddProjectFieldCache.shared.cache[activeAddProjectFormTag] else { return }
        discardPreparedAddProjectGitSourceIfNeeded(refs)
    }

    private func discardActiveAddProjectPreparedSourceSynchronouslyIfNeeded() -> Result<Void, Error>? {
        guard let activeAddProjectFormTag, let refs = AddProjectFieldCache.shared.cache[activeAddProjectFormTag],
            let prepared = refs.preparedGitProject
        else { return nil }
        refs.preparedGitProject = nil
        refs.preparedGitURL = nil
        return Self.discardPreparedGitProject(prepared)
    }

    @discardableResult private func beginPreparedGitProjectDiscard(_ prepared: WorkspaceOrchestrator.PreparedGitProjectImport, repoURL: String?)
        -> Task<Result<Void, Error>, Never>
    {
        let key = Self.preparedGitProjectDiscardKey(repoURL: repoURL)
        let previousTask = key.flatMap { preparedGitProjectDiscardTasksByURL[$0]?.task }
        let task = Task<Result<Void, Error>, Never> {
            if let previousTask { _ = await previousTask.value }
            return await Self.discardPreparedGitProjectSnapshot(prepared)
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
        guard let key = Self.preparedGitProjectDiscardKey(repoURL: repoURL), let entry = preparedGitProjectDiscardTasksByURL[key] else { return nil }
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

    private func updateAddWorkspaceBranchDerivedFields(refs: AddWorkspaceFieldRefs, branchValue: String) {
        guard let autoNameState = refs.autoNameState else { return }
        let trimmedBranch = branchValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty else { return }
        let currentName = refs.nameField.stringValue
        if currentName.isEmpty || currentName == autoNameState.lastAutoWorkspaceName {
            refs.nameField.stringValue = trimmedBranch
            autoNameState.lastAutoWorkspaceName = trimmedBranch
        }
        if let dirField = refs.directoryNameField {
            let currentDir = dirField.stringValue
            let sanitized = trimmedBranch.replacing(/[^A-Za-z0-9\-_]/, with: "-").replacing(/\-{2,}/, with: "-").trimmingCharacters(
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

    @objc private func toggleWorkspaceCustomize(_ sender: NSButton) {
        guard let refs = AddWorkspaceFieldCache.shared.cache[sender.tag] else { return }
        guard let customizeStack = refs.customizeStack else { return }
        let expanding = customizeStack.isHidden
        customizeStack.isHidden = !expanding
        sender.image = NSImage(systemSymbolName: expanding ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
    }

    @objc private func createWorkspace(_ sender: NSButton) {
        guard let refs = AddWorkspaceFieldCache.shared.cache[sender.tag] else { return }
        do {
            let name = refs.nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw WorkspaceError.invalidArgument(message: "Workspace title is required.") }
            let baseBranch = refs.baseBranchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = currentAddWorkspaceBranchValue(refs).trimmingCharacters(in: .whitespacesAndNewlines)
            let directoryName = refs.directoryNameField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedDirectoryName: String?
            if let directoryName, directoryName.isEmpty { resolvedDirectoryName = nil } else { resolvedDirectoryName = directoryName }
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
                    projectID: refs.projectID, name: name, branch: branch, baseBranch: baseBranch, directoryName: resolvedDirectoryName,
                    notes: resolvedNotes, allowRemoteBranchLookup: true, allowExistingBranchReuse: addWorkspaceBranchMode(refs: refs) == .existing,
                    replaceExistingManagedDirectory: false)
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
                            projectID: input.projectID, title: input.name, branch: input.branch, baseBranch: input.baseBranch,
                            directoryName: input.directoryName, notes: input.notes, allowExistingBranchReuse: input.allowExistingBranchReuse,
                            device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
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
        if let tag = inlineWorkspaceFieldTagByObjectID[ObjectIdentifier(changedField)] {
            updateInlineWorkspaceMetadataButtons(tag: tag)
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
        updateAddWorkspaceBranchDerivedFields(refs: refs, branchValue: branchValue)
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
                case .success(let response): applyDeviceMutationResponse(response, selectedWorkspaceID: id)
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
                case .success(let response): applyDeviceMutationResponse(response, selectedWorkspaceID: id)
                case .failure(let error): showError(error)
                }
            } else {
                showDeviceNotLoadedError()
            }
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
            "Are you sure you want to archive \"\(workspace.title)\"? This will remove its git worktree and stop all running processes."
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

    private func openWorkspaceEditor(workspaceID: String) {
        do {
            guard let (_, workspace) = findWorkspace(id: workspaceID) else { throw WorkspaceError.invalidArgument(message: "Workspace not found.") }
            guard !workspace.isArchived else { throw WorkspaceError.invalidArgument(message: "Workspace is archived.") }
            let editor = try clientAppConfig(base: orchestrator.appConfig()).editor
            let deviceID = deviceID(forWorkspaceID: workspaceID)
            if isRemoteDeviceID(deviceID) {
                guard let device = deviceRecord(forDeviceID: deviceID), let sshHost = device.sshHost?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !sshHost.isEmpty
                else { throw WorkspaceError.invalidArgument(message: "Remote editor launch requires SSH settings for the paired device.") }
                try EditorLauncher.openRemote(
                    editor: editor, sshHost: sshHost, sshUser: device.sshUser, sshPort: device.sshPort, directory: workspace.dir)
            } else {
                try EditorLauncher.open(editor: editor, directory: workspace.dir)
            }
            reloadData()
            hideAfterSuccessfulExternalWindowAction(.open(hidesApp: true))
        } catch { showError(error) }
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
                    if let sessionID = response.sessionID {
                        if isRemoteDeviceID(deviceID(forWorkspaceID: workspaceID)) {
                            if let request = Self.deviceTerminalOpenRequest(
                                workspaceID: workspaceID, sessionID: sessionID, overview: response.overview ?? localDeviceOverview)
                            {
                                _ = openDeviceTerminalSession(request, device: device)
                            }
                        } else {
                            _ = openTerminalSessionWindow(sessionID: sessionID, mode: .owner)
                        }
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
            if Self.shouldBypassLocalShortcutMonitor(for: NSApp.keyWindow) { return event }
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
            if self.handleFocusedTextInputShortcut(event: event) { return nil }
            if self.isTextInputFocused() { return event }
            if self.handleSidebarArrowNavigation(event: event) { return nil }
            if let openTerminalShortcutSpec, matches(event: event, spec: openTerminalShortcutSpec) {
                if let workspaceID = self.selectedWorkspaceID { self.openWorkspaceTerminal(workspaceID: workspaceID, route: .shortcut) }
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

    static func shouldBypassLocalShortcutMonitor(for keyWindow: NSWindow?) -> Bool {
        (keyWindow?.windowController as? TerminalSessionWindowController) != nil
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
        if let workspaceID = try? orchestrator.workspaceIDForFocusedWindow() { return workspaceID }
        if NSApp.isActive, let selectedWorkspaceID { return selectedWorkspaceID }
        if let workspaceID = clientActiveWorkspaceID() { return workspaceID }
        return nil
    }

    nonisolated static func activationSelectionTarget(focusedWorkspaceID: String?) -> SidebarArrowSelectionTarget {
        if let focusedWorkspaceID { return .workspace(focusedWorkspaceID) }
        return .alerts
    }

    nonisolated static func clientAppConfig(base: AppConfig) throws -> AppConfig {
        let editor = try SpacesClientDatabase.defaultDatabase().setting(key: SettingsKey.appEditor).flatMap(EditorPreference.init(rawValue:))
        return AppConfig(editor: editor, portRange: base.portRange)
    }

    private func clientAppConfig(base: AppConfig) throws -> AppConfig {
        let editor = try clientDatabase().setting(key: SettingsKey.appEditor).flatMap(EditorPreference.init(rawValue:))
        return AppConfig(editor: editor, portRange: base.portRange)
    }

    func clientWindowFocusPulseEnabled() -> Bool {
        guard let raw = try? clientDatabase().setting(key: SettingsKey.windowFocusPulseEnabled) else {
            return SettingsKey.defaultWindowFocusPulseEnabled
        }
        return raw != "0"
    }

    func clientWindowFocusPulseColor() -> (r: Int, g: Int, b: Int) {
        SettingsKey.windowFocusPulseColor(from: try? clientDatabase().setting(key: SettingsKey.windowFocusPulseColor))
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
        refreshWorkspaceShortcutFooterRow()
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
        let result = await Self.performWindowFocusSnapshot(request)
        switch result {
        case .success(let action):
            reloadData()
            hideAfterSuccessfulExternalWindowAction(action)
        case .failure(let error): await handleWindowFocusFailure(error)
        }
    }

    private func launchConfiguredAgent(workspaceID: String, name: String) async {
        let result = await Self.launchConfiguredAgentSnapshot(workspaceID: workspaceID, name: name)
        switch result {
        case .success:
            reloadData()
            hideAfterSuccessfulExternalWindowAction(.open(hidesApp: true))
        case .failure(let error): showError(error)
        }
    }

    private func runWindowShortcut(index: Int, startedAt: Date) async {
        activeWindowShortcutProfile = WindowShortcutProfile(index: index, startedAt: startedAt)
        logWindowShortcutProfile("stage=received index=\(index) alerts=\(showingAlerts ? 1 : 0)")
        // Focus through the Device API when the selected workspace lives on a remote
        // device; its processes/terminals have no local windows to raise.
        if let selectedWorkspaceID, isRemoteDeviceID(deviceID(forWorkspaceID: selectedWorkspaceID)) {
            await runDeviceWindowShortcut(index: index, startedAt: startedAt)
            return
        }
        let alertsFocusRequest = showingAlerts ? alerts.alertsFocusRequest(for: index) : nil
        let routeStartedAt = Date()
        let result = await Self.focusWindowShortcutSnapshot(
            index: index, selectedWorkspaceID: selectedWorkspaceID, alertsFocusRequest: alertsFocusRequest)
        switch result {
        case .success(.focused(let kind, let recentFocusIdentity, let hidesApp)):
            logWindowShortcutProfile("stage=route_done index=\(index) kind=\(kind) elapsed_ms=\(windowShortcutElapsedMS(since: routeStartedAt))")
            activeWindowShortcutProfile?.routeCompletedAt = Date()
            commandPalette.rememberRecentCommandPaletteFocusIdentity(recentFocusIdentity)
            logWindowShortcutProfile("stage=total index=\(index) elapsed_ms=\(windowShortcutElapsedMS(since: startedAt))")
            logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true)
            if hidesApp { hideAfterSuccessfulExternalWindowAction(.focus(hidesApp: true)) } else { activeWindowShortcutProfile = nil }
        case .success(.opened(let kind, let hidesApp)):
            logWindowShortcutProfile("stage=route_done index=\(index) kind=\(kind) elapsed_ms=\(windowShortcutElapsedMS(since: routeStartedAt))")
            activeWindowShortcutProfile?.routeCompletedAt = Date()
            logWindowShortcutProfile("stage=total index=\(index) elapsed_ms=\(windowShortcutElapsedMS(since: startedAt))")
            logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true)
            reloadData()
            if hidesApp { hideAfterSuccessfulExternalWindowAction(.open(hidesApp: true)) } else { activeWindowShortcutProfile = nil }
        case .success(.noWorkspace):
            logWindowShortcutProfile("stage=aborted index=\(index) reason=no_workspace elapsed_ms=\(windowShortcutElapsedMS(since: startedAt))")
            logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false)
            activeWindowShortcutProfile = nil
        case .success(.noMatch):
            logWindowShortcutProfile("stage=aborted index=\(index) reason=no_match elapsed_ms=\(windowShortcutElapsedMS(since: startedAt))")
            logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false)
            activeWindowShortcutProfile = nil
        case .failure(let error):
            await handleWindowFocusFailure(error)
            logWindowShortcutProfile("stage=aborted index=\(index) reason=error elapsed_ms=\(windowShortcutElapsedMS(since: startedAt))")
            logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false)
            activeWindowShortcutProfile = nil
        }
    }

    private func runDeviceWindowShortcut(index: Int, startedAt: Date) async {
        let routeStartedAt = Date()
        guard let overview = selectedWorkspaceID.flatMap({ deviceSection(id: deviceID(forWorkspaceID: $0))?.overview }) ?? localDeviceOverview else {
            logWindowShortcutProfile("stage=aborted index=\(index) reason=no_device_overview elapsed_ms=\(windowShortcutElapsedMS(since: startedAt))")
            logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false)
            activeWindowShortcutProfile = nil
            showDeviceNotLoadedError()
            return
        }
        let resolution = Self.deviceWindowShortcutResolution(index: index, selectedWorkspaceID: selectedWorkspaceID, overview: overview)
        switch resolution {
        case .openURL(let targetURL):
            guard let url = URL(string: targetURL) else {
                logWindowShortcutProfile("stage=aborted index=\(index) reason=invalid_url elapsed_ms=\(windowShortcutElapsedMS(since: startedAt))")
                logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false)
                activeWindowShortcutProfile = nil
                showError(WorkspaceError.invalidArgument(message: "Browser session URL is invalid."))
                return
            }
            NSWorkspace.shared.open(url)
            logWindowShortcutProfile("stage=route_done index=\(index) kind=browser elapsed_ms=\(windowShortcutElapsedMS(since: routeStartedAt))")
            logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true)
            hideAfterSuccessfulExternalWindowAction(.focus(hidesApp: true))
        case .openTerminal(let request):
            guard let device = deviceForDaemonStateMutation() else {
                logWindowShortcutProfile("stage=aborted index=\(index) reason=no_device elapsed_ms=\(windowShortcutElapsedMS(since: startedAt))")
                logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false)
                activeWindowShortcutProfile = nil
                showDeviceNotLoadedError()
                return
            }
            let opened = openDeviceTerminalSession(request, device: device)
            logWindowShortcutProfile("stage=route_done index=\(index) kind=terminal elapsed_ms=\(windowShortcutElapsedMS(since: routeStartedAt))")
            logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: opened)
            activeWindowShortcutProfile = nil
        case .runProcess(let workspaceID, let processKey, let processTemplateID):
            guard let device = deviceForDaemonStateMutation() else {
                logWindowShortcutProfile("stage=aborted index=\(index) reason=no_device elapsed_ms=\(windowShortcutElapsedMS(since: startedAt))")
                logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false)
                activeWindowShortcutProfile = nil
                showDeviceNotLoadedError()
                return
            }
            let result = await Self.deviceMutation(device: device) { device in
                try SpacesDeviceClient.runWorkspaceProcess(
                    workspaceID: workspaceID, processKey: processKey, processTemplateID: processTemplateID, device: device,
                    clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
            }
            switch result {
            case .success(let response):
                logWindowShortcutProfile("stage=route_done index=\(index) kind=process elapsed_ms=\(windowShortcutElapsedMS(since: routeStartedAt))")
                logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true)
                applyDeviceMutationResponse(response, selectedWorkspaceID: workspaceID)
            case .failure(let error):
                logWindowShortcutProfile("stage=aborted index=\(index) reason=error elapsed_ms=\(windowShortcutElapsedMS(since: startedAt))")
                logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false)
                showError(error)
            }
            activeWindowShortcutProfile = nil
        case .runCodingAgent(let workspaceID, let agentName, let agentLauncherID):
            guard let device = deviceForDaemonStateMutation() else {
                logWindowShortcutProfile("stage=aborted index=\(index) reason=no_device elapsed_ms=\(windowShortcutElapsedMS(since: startedAt))")
                logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false)
                activeWindowShortcutProfile = nil
                showDeviceNotLoadedError()
                return
            }
            let result = await Self.deviceMutation(device: device) { device in
                try SpacesDeviceClient.runCodingAgent(
                    workspaceID: workspaceID, agentName: agentName, agentLauncherID: agentLauncherID, device: device,
                    clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
            }
            switch result {
            case .success(let response):
                logWindowShortcutProfile(
                    "stage=route_done index=\(index) kind=agent_launcher elapsed_ms=\(windowShortcutElapsedMS(since: routeStartedAt))")
                logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true)
                applyDeviceMutationResponse(response, selectedWorkspaceID: workspaceID)
            case .failure(let error):
                logWindowShortcutProfile("stage=aborted index=\(index) reason=error elapsed_ms=\(windowShortcutElapsedMS(since: startedAt))")
                logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false)
                showError(error)
            }
            activeWindowShortcutProfile = nil
        case .noWorkspace:
            logWindowShortcutProfile("stage=aborted index=\(index) reason=no_workspace elapsed_ms=\(windowShortcutElapsedMS(since: startedAt))")
            logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false)
            activeWindowShortcutProfile = nil
        case .noMatch:
            logWindowShortcutProfile("stage=aborted index=\(index) reason=no_match elapsed_ms=\(windowShortcutElapsedMS(since: startedAt))")
            logPerfMetric("window_shortcut", target: "index=\(index)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false)
            activeWindowShortcutProfile = nil
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

    nonisolated static func shouldUseRememberedBuiltInTerminalSessionForGlobalNavigation(
        appIsActive: Bool, mainWindowIsFocused: Bool, commandPaletteIsFocused: Bool
    ) -> Bool { appIsActive && !mainWindowIsFocused && !commandPaletteIsFocused }

    nonisolated static func shouldUseFocusedBuiltInTerminalWindowForGlobalNavigation(appIsActive: Bool) -> Bool { appIsActive }

    nonisolated static func preferredWorkspaceIDForGlobalNavigation(
        focusedTerminalSessionWorkspaceID: String?, focusedWindowWorkspaceID: String?, rememberedTerminalSessionWorkspaceID: String?,
        activeWorkspaceID: String?
    ) -> GlobalNavigationWorkspaceResolution {
        if let focusedTerminalSessionWorkspaceID {
            return GlobalNavigationWorkspaceResolution(workspaceID: focusedTerminalSessionWorkspaceID, source: "focused_terminal_session")
        }
        if let focusedWindowWorkspaceID {
            return GlobalNavigationWorkspaceResolution(workspaceID: focusedWindowWorkspaceID, source: "focused_window")
        }
        if let rememberedTerminalSessionWorkspaceID {
            return GlobalNavigationWorkspaceResolution(workspaceID: rememberedTerminalSessionWorkspaceID, source: "remembered_terminal_session")
        }
        if let activeWorkspaceID { return GlobalNavigationWorkspaceResolution(workspaceID: activeWorkspaceID, source: "active_workspace") }
        return GlobalNavigationWorkspaceResolution(workspaceID: nil, source: "none")
    }

    nonisolated static func shouldHideMainWindowForToggle(appIsHidden: Bool, mainWindowIsFocused: Bool) -> Bool {
        !appIsHidden && mainWindowIsFocused
    }

    nonisolated static func shouldRestoreTerminalFocusAfterMainHide(returnTerminalSessionID: String?, auxiliaryTerminalWindowsVisible: Bool) -> Bool {
        auxiliaryTerminalWindowsVisible && returnTerminalSessionID != nil
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
        do {
            let hidesApp: Bool
            let preferredFocusedBuiltInTerminalSessionID = activeBuiltInTerminalSessionID()
            if direction > 0 {
                hidesApp = try orchestrator.focusNextWindowHidesApp(
                    workspaceID: workspaceID, requestID: requestID, preferredFocusedBuiltInTerminalSessionID: preferredFocusedBuiltInTerminalSessionID
                )
            } else {
                hidesApp = try orchestrator.focusPreviousWindowHidesApp(
                    workspaceID: workspaceID, requestID: requestID, preferredFocusedBuiltInTerminalSessionID: preferredFocusedBuiltInTerminalSessionID
                )
            }
            logPerfMetric(
                "global_window_navigation", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true,
                detail: "direction=\(direction > 0 ? "next" : "previous") hides_app=\(hidesApp ? 1 : 0) request_id=\(requestID)")
            if hidesApp { hideAfterSuccessfulExternalWindowAction(.focus(hidesApp: true)) } else { commandPalette.dismissCommandPaletteForBuiltInWindowNavigation() }
        } catch {
            logPerfMetric(
                "global_window_navigation", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false,
                detail: "direction=\(direction > 0 ? "next" : "previous") request_id=\(requestID)")
            showError(error)
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

    func handleWindowFocusFailure(_ error: Error) async {
        guard let spacesError = error as? WorkspaceError, case .missingTrackedWindow(let context) = spacesError else {
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
        guard let spacesError = error as? WorkspaceError, case .missingTrackedWindow(let context) = spacesError else {
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

        showOperationProgressOverlay(message: progressTitle, detail: progressDetail, context: .workspace(context.workspaceID))
        let result = await Self.recoverMissingTrackedWindowSnapshot(context)
        hideOperationProgressOverlay()
        switch result {
        case .success:
            reloadData()
            switch context.kind {
            case .browserSession:
                showWindowIssueToast(title: "Browser session recovered", detail: "\(context.title) reopened in a new Chrome window.")
            case .process:
                let recoveredProcess: RunningProcessRecord?
                if let processID = context.processID {
                    recoveredProcess = try? await Self.recoveredWorkspaceProcessSnapshot(workspaceID: context.workspaceID, processID: processID).get()
                } else {
                    recoveredProcess = nil
                }
                showWindowIssueToast(
                    title: "Process recovered",
                    detail: Self.recoveredProcessWindowDetail(title: context.title, terminalApp: recoveredProcess?.terminalApp))
            case .codingAgent, .window: break
            }
        case .failure(let error): showError(error)
        }
    }

    private func globalWindowNavigationWorkspaceID(requestID: String? = nil) -> String? {
        let startedAt = Date()
        let activeTerminalSessionStartedAt = Date()
        let focusedTerminalSessionID = focusedBuiltInTerminalSessionIDForGlobalNavigation()
        let activeTerminalSessionMS = windowShortcutElapsedMS(since: activeTerminalSessionStartedAt)

        var focusedTerminalSessionWorkspaceID: String?
        var focusedWindowWorkspaceID: String?
        var rememberedTerminalSessionWorkspaceID: String?
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
            focusedTerminalSessionWorkspaceID = try? orchestrator.workspaceIDForTerminalSession(focusedTerminalSessionID)
            terminalWorkspaceMS = windowShortcutElapsedMS(since: lookupStartedAt)
            terminalWorkspaceSource = "focused"
            terminalWorkspaceStatus = focusedTerminalSessionWorkspaceID == nil ? "miss" : "hit"
        }

        if focusedTerminalSessionWorkspaceID == nil {
            let lookupStartedAt = Date()
            focusedWindowWorkspaceID = try? orchestrator.workspaceIDForFocusedWindow()
            focusedWindowWorkspaceMS = windowShortcutElapsedMS(since: lookupStartedAt)
            focusedWindowWorkspaceStatus = focusedWindowWorkspaceID == nil ? "miss" : "hit"
        }

        if focusedTerminalSessionWorkspaceID == nil, focusedWindowWorkspaceID == nil,
            let rememberedSessionID = rememberedBuiltInTerminalSessionIDForGlobalNavigation()
        {
            let lookupStartedAt = Date()
            rememberedTerminalSessionWorkspaceID = try? orchestrator.workspaceIDForTerminalSession(rememberedSessionID)
            terminalWorkspaceMS += windowShortcutElapsedMS(since: lookupStartedAt)
            terminalWorkspaceSource = terminalWorkspaceSource == "skipped" ? "remembered" : "\(terminalWorkspaceSource)+remembered"
            terminalWorkspaceStatus = rememberedTerminalSessionWorkspaceID == nil ? "miss" : "hit"
        }

        if focusedTerminalSessionWorkspaceID == nil, focusedWindowWorkspaceID == nil, rememberedTerminalSessionWorkspaceID == nil {
            let lookupStartedAt = Date()
            activeWorkspaceID = clientActiveWorkspaceID()
            activeWorkspaceMS = windowShortcutElapsedMS(since: lookupStartedAt)
            activeWorkspaceStatus = activeWorkspaceID == nil ? "miss" : "hit"
        }

        let resolution = Self.preferredWorkspaceIDForGlobalNavigation(
            focusedTerminalSessionWorkspaceID: focusedTerminalSessionWorkspaceID, focusedWindowWorkspaceID: focusedWindowWorkspaceID,
            rememberedTerminalSessionWorkspaceID: rememberedTerminalSessionWorkspaceID, activeWorkspaceID: activeWorkspaceID)
        let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
        let detail =
            "selected_source=\(resolution.source) active_terminal_session=\(focusedTerminalSessionID == nil ? "miss" : "hit") active_terminal_session_ms=\(activeTerminalSessionMS) terminal_workspace=\(terminalWorkspaceStatus) terminal_workspace_source=\(terminalWorkspaceSource) terminal_workspace_ms=\(terminalWorkspaceMS) focused_window_workspace=\(focusedWindowWorkspaceStatus) focused_window_workspace_ms=\(focusedWindowWorkspaceMS) active_workspace=\(activeWorkspaceStatus) active_workspace_ms=\(activeWorkspaceMS)\(requestDetail)"
        logPerfMetric(
            "global_window_navigation_workspace_resolution", target: "workspace=\(resolution.workspaceID ?? "nil")",
            elapsedMS: windowShortcutElapsedMS(since: startedAt), success: resolution.workspaceID != nil, detail: detail)
        return resolution.workspaceID
    }

    private func activeBuiltInTerminalSessionID() -> String? {
        focusedBuiltInTerminalSessionIDForGlobalNavigation() ?? rememberedBuiltInTerminalSessionIDForGlobalNavigation()
    }

    private func focusedBuiltInTerminalSessionIDForGlobalNavigation() -> String? {
        if Self.shouldUseFocusedBuiltInTerminalWindowForGlobalNavigation(appIsActive: NSApp.isActive) {
            for window in [NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 }) {
                if let sessionID = (window.windowController as? TerminalSessionWindowController)?.terminalSessionID { return sessionID }
            }
        }
        return nil
    }

    private func rememberedBuiltInTerminalSessionIDForGlobalNavigation() -> String? {
        guard
            Self.shouldUseRememberedBuiltInTerminalSessionForGlobalNavigation(
                appIsActive: NSApp.isActive, mainWindowIsFocused: window?.isKeyWindow == true,
                commandPaletteIsFocused: commandPalette.commandPalettePanel?.isKeyWindow == true)
        else { return nil }
        if let sessionID = lastFocusedBuiltInTerminalSessionID { return sessionID }
        return nil
    }

    nonisolated static func preferredWorkspaceIDForAppToggle(focusedTerminalSessionWorkspaceID: String?, focusedWindowWorkspaceID: String?) -> String?
    { focusedTerminalSessionWorkspaceID ?? focusedWindowWorkspaceID }

    nonisolated static func shouldRestoreReturnApplicationAfterMainHide(
        returnTerminalSessionID: String?, returnApplicationProcessID: pid_t?, auxiliaryTerminalWindowsVisible: Bool
    ) -> Bool { return returnTerminalSessionID == nil && returnApplicationProcessID != nil && !auxiliaryTerminalWindowsVisible }

    nonisolated static func shouldHideAppAfterMainHide(
        returnTerminalSessionID: String?, returnApplicationProcessID: pid_t?, auxiliaryTerminalWindowsVisible: Bool
    ) -> Bool { return returnTerminalSessionID == nil && !auxiliaryTerminalWindowsVisible }

    nonisolated static func shouldMiniaturizeMainWindowAfterHide(returnTerminalSessionID: String?) -> Bool { return returnTerminalSessionID == nil }

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
            let returnTerminalSessionID = appToggleReturnTerminalSessionID
            let returnApplicationProcessID = appToggleReturnApplicationProcessID
            let shouldRestoreTerminalFocus = Self.shouldRestoreTerminalFocusAfterMainHide(
                returnTerminalSessionID: returnTerminalSessionID, auxiliaryTerminalWindowsVisible: hasVisibleTerminalSessionWindowsForHotkeyState())
            let shouldRestoreReturnApplication = Self.shouldRestoreReturnApplicationAfterMainHide(
                returnTerminalSessionID: returnTerminalSessionID, returnApplicationProcessID: returnApplicationProcessID,
                auxiliaryTerminalWindowsVisible: hasVisibleTerminalSessionWindowsForHotkeyState())
            let shouldHideApp = Self.shouldHideAppAfterMainHide(
                returnTerminalSessionID: returnTerminalSessionID, returnApplicationProcessID: returnApplicationProcessID,
                auxiliaryTerminalWindowsVisible: hasVisibleTerminalSessionWindowsForHotkeyState())
            if shouldHideApp {
                window.orderOut(nil)
                NSApp.hide(nil)
            } else if Self.shouldMiniaturizeMainWindowAfterHide(returnTerminalSessionID: returnTerminalSessionID) {
                window.miniaturize(nil)
            } else {
                window.orderOut(nil)
            }
            if shouldRestoreTerminalFocus, let returnTerminalSessionID {
                let restoreStartedAt = Date()
                focusTerminalSessionWindow(sessionID: returnTerminalSessionID)
                logPerfMetric(
                    "toggle_window_return_terminal_focus", target: "session=\(returnTerminalSessionID)",
                    elapsedMS: windowShortcutElapsedMS(since: restoreStartedAt), success: true)
            } else if shouldRestoreReturnApplication, let returnApplicationProcessID {
                let restoreStartedAt = Date()
                activateReturnApplication(processIdentifier: returnApplicationProcessID)
                logPerfMetric(
                    "toggle_window_return_application_focus", target: "pid=\(returnApplicationProcessID)",
                    elapsedMS: windowShortcutElapsedMS(since: restoreStartedAt), success: true)
            }
            appToggleReturnTerminalSessionID = nil
            appToggleReturnApplicationProcessID = nil
            logHotkeyPerfMetric("toggle_window", action: "hide", context: perfContext)
            return
        }
        let returnApplicationProcessID = Self.returnApplicationProcessIDForAppToggle(
            frontmostApplicationProcessID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            currentProcessID: ProcessInfo.processInfo.processIdentifier)
        let focusedTerminalSessionID = focusedTerminalSessionIDForToggle()
        let focusedTerminalWorkspaceID: String?
        let selectionRefreshSource: String
        if let terminalSessionID = focusedTerminalSessionID {
            let lookupStartedAt = Date()
            focusedTerminalWorkspaceID = try? orchestrator.workspaceIDForTerminalSession(terminalSessionID)
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
            focusedWindowWorkspaceID = try? orchestrator.workspaceIDForFocusedWindow()
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
        appToggleReturnTerminalSessionID = focusedTerminalSessionID
        appToggleReturnApplicationProcessID = focusedTerminalSessionID == nil ? returnApplicationProcessID : nil
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
        if resignedWindow === commandPalette.commandPalettePanel, !commandPalette.isDismissingCommandPalette { commandPalette.dismissCommandPalette() }
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

    private func presentProjectPortRemoveConfirmation(port: PortDefinition, confirm: @escaping (Bool) -> Void) {
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
                                workspaceTitle: workspace.title, workspaceBranch: workspace.branch, projectTitle: project.name, kind: target.kind,
                                label: label, detail: targetURL, status: .none,
                                focusRequest: .workspaceBrowserSession(workspaceID: workspace.id, targetURL: targetURL),
                                recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(
                                    for: .workspaceBrowserSession(workspaceID: workspace.id, targetURL: targetURL), detail: targetURL)))
                    case .process:
                        guard let processID = target.processID, let process = processesByID[processID] else { continue }
                        items.append(
                            CommandPaletteItem(
                                id: itemID, source: .workspaceTarget, alertsAttentionID: nil, workspaceID: workspace.id,
                                workspaceTitle: workspace.title, workspaceBranch: workspace.branch, projectTitle: project.name, kind: target.kind,
                                label: process.templateName, detail: process.command, status: .process(process.status),
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
                                workspaceTitle: workspace.title, workspaceBranch: workspace.branch, projectTitle: project.name, kind: target.kind,
                                label: label, detail: detail, status: .none,
                                focusRequest: .workspaceWindow(workspaceID: workspace.id, index: windowListIndex + 1),
                                recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(
                                    for: .workspaceWindow(workspaceID: workspace.id, index: windowListIndex + 1), detail: detail)))
                    case .missingConfiguredProcess:
                        guard let processKey = target.processKey else { continue }
                        items.append(
                            CommandPaletteItem(
                                id: itemID, source: .workspaceTarget, alertsAttentionID: nil, workspaceID: workspace.id,
                                workspaceTitle: workspace.title, workspaceBranch: workspace.branch, projectTitle: project.name, kind: target.kind,
                                label: processKey, detail: nil, status: .idle,
                                focusRequest: .workspaceMissingConfiguredProcess(workspaceID: workspace.id, processKey: processKey),
                                recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(
                                    for: .workspaceMissingConfiguredProcess(workspaceID: workspace.id, processKey: processKey))))
                    case .agentLauncher:
                        guard let launcherName = target.launcherName else { continue }
                        let detail = configuredAgentByName[launcherName]?.command
                        items.append(
                            CommandPaletteItem(
                                id: itemID, source: .workspaceTarget, alertsAttentionID: nil, workspaceID: workspace.id,
                                workspaceTitle: workspace.title, workspaceBranch: workspace.branch, projectTitle: project.name, kind: target.kind,
                                label: launcherName, detail: detail, status: .none,
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
                                workspaceTitle: workspace.title, workspaceBranch: workspace.branch, projectTitle: project.name, kind: target.kind,
                                label: label, detail: detail, status: .agent(agentWindow.status), focusRequest: .agentWindow(agentWindow),
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
