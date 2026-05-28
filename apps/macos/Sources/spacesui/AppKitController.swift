import AppKit
import Carbon
import CoreImage
import Foundation
import Sparkle
import spacesmobilebridge
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

private final class CommandPaletteSearchField: NSSearchField { override var needsPanelToBecomeKey: Bool { true } }

private final class CommandPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

protocol ProcessLifecyclePolicyController {
    func disableAutomaticTermination(_ reason: String)
    func disableSuddenTermination()
}

extension ProcessInfo: ProcessLifecyclePolicyController {}

@MainActor
public final class AppKitController: NSObject, NSApplicationDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSplitViewDelegate,
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

    private enum AlertsIconTint: Sendable {
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
        let saveButton: NSButton
        let cancelButton: NSButton
        var originalValue: String
        var isEditing: Bool
    }

    private struct AlertsAttentionEntry: Sendable {
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

    private struct AlertsGroup: Sendable {
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

    private struct HotkeyPerfContext {
        let startedAt: Date
        let appWasActive: Bool
        let appWasHidden: Bool
        let mainWindowWasVisible: Bool
        let paletteWasVisible: Bool
    }

    private struct PendingCommandPalettePresentation {
        let perfContext: HotkeyPerfContext?
        let mainWindowWasVisible: Bool
    }

    private var window: NSWindow!
    private var splitView: NSSplitView?
    private let outlineView = SidebarOutlineView()
    private let detailContainer = NSView()
    private weak var workspaceShortcutFooterRowView: NSStackView?
    // workspaceShortcutFooterLabels removed — footer rebuilt on each refresh
    private var orchestrator: WorkspaceOrchestrator!
    private var projects: [ProjectSummary] = []
    private var outlineItemRefCache: [String: OutlineItemRef] = [:]
    private var workspacesByProject: [String: [WorkspaceSummary]] = [:]
    private var workspaceRuntimeStatusByID: [String: WorkspaceRuntimeStatus] = [:]
    private var alertsGroups: [AlertsGroup] = []
    private var dismissedAlertsAttentionItemIDs: Set<String> = []
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
    private var commandPaletteShortcutSpec: HotkeySpec?
    private var alertsShortcutSpec: HotkeySpec?
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
    private var shortcutButtonsBySetting: [String: NSButton] = [:]
    private var activeShortcutCaptureSetting: ShortcutSetting?
    private weak var pulseColorWell: NSColorWell?
    private var periodicWorkspaceRefreshTask: Task<Void, Never>?
    private var periodicProcessMonitorTask: Task<Void, Never>?
    private var periodicWorktreeDiscoveryTask: Task<Void, Never>?
    private var periodicSidebarMetadataRefreshTask: Task<Void, Never>?
    private var deferredHotkeySelectionRefreshTask: Task<Void, Never>?
    private var activeSpaceSummonCleanupTask: Task<Void, Never>?
    private var visibleWorkspaceDetailRefreshTask: Task<Void, Never>?
    private var visibleWorkspaceDetailRefreshWorkspaceID: String?
    private var commandPalettePanel: NSPanel?
    private var commandPaletteSearchField: NSSearchField?
    private var commandPaletteTableView: NSTableView?
    private var commandPaletteLoadingIndicator: NSProgressIndicator?
    private var commandPaletteEmptyLabel: NSTextField?
    private var commandPaletteSummaryLabel: NSTextField?
    private var commandPaletteLoadTask: Task<Void, Never>?
    private var commandPaletteItems: [CommandPaletteItem] = []
    private var commandPaletteFilteredItems: [CommandPaletteItem] = []
    private var commandPaletteContextWorkspaceID: String?
    private var commandPaletteSelectedIndex = 0
    private var commandPaletteNeedsReload = true
    private var isDismissingCommandPalette = false
    private var pendingCommandPalettePresentation: PendingCommandPalettePresentation?
    private var commandPaletteMainWindowVisibility: Bool?
    private var mobileConnectionPanel: NSPanel?
    private var mobileConnectionTimer: Timer?
    private var pendingWorktreeDiscoveryReload = false
    private var lastTrackedWindowCounts: [String: Int] = [:]
    private lazy var updaterController: SPUStandardUpdaterController? = {
        guard Self.isRunningFromAppBundle else { return nil }
        return SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    }()
    private var agentEventIPCObserver: NSObjectProtocol?
    private var selectWorkspaceDetailIPCObserver: NSObjectProtocol?
    private var showMainWindowIPCObserver: NSObjectProtocol?
    private var hideMainWindowIPCObserver: NSObjectProtocol?
    private var showWindowIssueModalIPCObserver: NSObjectProtocol?
    private var cycleWorkspaceWindowIPCObserver: NSObjectProtocol?
    private var openWorkspaceTerminalIPCObserver: NSObjectProtocol?
    private var runWorkspaceProcessIPCObserver: NSObjectProtocol?
    private var stopWorkspaceProcessIPCObserver: NSObjectProtocol?
    private var restartWorkspaceProcessIPCObserver: NSObjectProtocol?
    private var launchWorkspaceAgentIPCObserver: NSObjectProtocol?
    private var openTerminalSessionWindowIPCObserver: NSObjectProtocol?
    private var focusTerminalSessionWindowIPCObserver: NSObjectProtocol?
    private var closeTerminalSessionWindowIPCObserver: NSObjectProtocol?
    private var dumpTerminalSessionWindowStateIPCObserver: NSObjectProtocol?
    private var appDidBecomeActiveObserver: NSObjectProtocol?
    private var appDidResignActiveObserver: NSObjectProtocol?
    private var workspaceDidTerminateApplicationObserver: NSObjectProtocol?
    private var terminalAttachmentStateDidChangeObserver: NSObjectProtocol?
    private var didStartBackgroundServices = false
    private var setupManager: SetupManager?
    private var sidebarReloadTask: Task<Void, Never>?
    private var pendingSidebarReloadRequest = false
    private var activeWindowShortcutProfile: WindowShortcutProfile?
    private let startupProfileStartTime = startupProfileBaselineUptime
    private var didLogFirstStartupInteraction = false
    private let launchProfile: SpacesProfile
    private let appOwnerLease: SpacesProcessLease
    private var desktopControlLease: SpacesProcessLease?
    private var passiveDesktopControlOwner: SpacesProcessLeaseOwner?
    private let ipcNotificationObject: String

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
    private var windowIssueToastOverlay: NSView?
    private var windowIssueToastTitleLabel: NSTextField?
    private var windowIssueToastDetailLabel: NSTextField?
    private var windowIssueToastActionButton: NSButton?
    private var windowIssueToastActionHandler: (() -> Void)?
    private var windowIssueToastDismissTask: Task<Void, Never>?
    private lazy var iso8601Formatter: ISO8601DateFormatter = ISO8601DateFormatter()

    // Alerts sidebar row
    private var alertsRowView: NSView?
    private var alertsRowStack: NSStackView?
    private var alertsRowBadge: NSTextField?
    private var showingAlerts = false
    /// Maps sequential window shortcut numbers (1-9) to focus targets for the current Alerts view.
    private var alertsFocusRequestMap: [Int: WindowFocusRequest] = [:]
    private var deferredExternalWindowHideTask: Task<Void, Never>?
    private var recentCommandPaletteFocusIdentities: [String] = []
    private var terminalSessionWindowControllers: [String: TerminalSessionWindowController] = [:]
    private var lastFocusedBuiltInTerminalSessionID: String?
    private var keepsTerminalSessionsRunningDuringTermination = false
    private var appToggleReturnTerminalSessionID: String?
    private var appToggleReturnApplicationProcessID: pid_t?
    private var commandPaletteReturnTerminalSessionID: String?
    private var commandPaletteReturnApplicationProcessID: pid_t?

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
        let summary: String?
        let state: String?
        let showsTerminalSurface: Bool?
        let showsOutputFallback: Bool?
        let didClose: Bool?
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

    private struct OpenWorkspaceTerminalSnapshotResult: Sendable {
        let sessionID: String
        let action: ExternalWindowAction
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
        setupAgentEventIPCObserver()
        setupShowMainWindowIPCObserver()
        setupHideMainWindowIPCObserver()
        setupShowWindowIssueModalIPCObserver()
        setupCycleWorkspaceWindowIPCObserver()
        setupSelectWorkspaceDetailIPCObserver()
        setupOpenWorkspaceTerminalIPCObserver()
        setupRunWorkspaceProcessIPCObserver()
        setupStopWorkspaceProcessIPCObserver()
        setupRestartWorkspaceProcessIPCObserver()
        setupLaunchWorkspaceAgentIPCObserver()
        setupOpenTerminalSessionWindowIPCObserver()
        setupFocusTerminalSessionWindowIPCObserver()
        setupCloseTerminalSessionWindowIPCObserver()
        setupDumpTerminalSessionWindowStateIPCObserver()
        setupAppActivationObservers()
        setupWorkspaceApplicationObservers()
        setupTerminalAttachmentStateObserver()
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
        "Spaces coordinates long-lived workspace windows, terminal sessions, and mobile bridge clients."
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
                Self.dispatchBuiltInTerminalWindowActionOnMainThread { self?.closeTerminalSessionWindows(sessionID: sessionID) }
            }, builtInTerminalSessionTerminator: Self.terminateBuiltInTerminalSession,
            builtInTerminalSessionLauncher: Self.launchServiceBuiltInTerminalSession)
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
                GhosttyEmbeddedSessionRegistry.shared.terminateAll()
                return .terminateNow
            case .cancel: return .terminateCancel
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        periodicWorkspaceRefreshTask?.cancel()
        periodicProcessMonitorTask?.cancel()
        periodicWorktreeDiscoveryTask?.cancel()
        periodicSidebarMetadataRefreshTask?.cancel()
        deferredHotkeySelectionRefreshTask?.cancel()
        sidebarReloadTask?.cancel()
        mobileConnectionTimer?.invalidate()
        mobileConnectionTimer = nil
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
        if let showMainWindowIPCObserver {
            DistributedNotificationCenter.default().removeObserver(showMainWindowIPCObserver)
            self.showMainWindowIPCObserver = nil
        }
        if let hideMainWindowIPCObserver {
            DistributedNotificationCenter.default().removeObserver(hideMainWindowIPCObserver)
            self.hideMainWindowIPCObserver = nil
        }
        if let showWindowIssueModalIPCObserver {
            DistributedNotificationCenter.default().removeObserver(showWindowIssueModalIPCObserver)
            self.showWindowIssueModalIPCObserver = nil
        }
        if let cycleWorkspaceWindowIPCObserver {
            DistributedNotificationCenter.default().removeObserver(cycleWorkspaceWindowIPCObserver)
            self.cycleWorkspaceWindowIPCObserver = nil
        }
        if let openWorkspaceTerminalIPCObserver {
            DistributedNotificationCenter.default().removeObserver(openWorkspaceTerminalIPCObserver)
            self.openWorkspaceTerminalIPCObserver = nil
        }
        if let runWorkspaceProcessIPCObserver {
            DistributedNotificationCenter.default().removeObserver(runWorkspaceProcessIPCObserver)
            self.runWorkspaceProcessIPCObserver = nil
        }
        if let stopWorkspaceProcessIPCObserver {
            DistributedNotificationCenter.default().removeObserver(stopWorkspaceProcessIPCObserver)
            self.stopWorkspaceProcessIPCObserver = nil
        }
        if let restartWorkspaceProcessIPCObserver {
            DistributedNotificationCenter.default().removeObserver(restartWorkspaceProcessIPCObserver)
            self.restartWorkspaceProcessIPCObserver = nil
        }
        if let launchWorkspaceAgentIPCObserver {
            DistributedNotificationCenter.default().removeObserver(launchWorkspaceAgentIPCObserver)
            self.launchWorkspaceAgentIPCObserver = nil
        }
        if let openTerminalSessionWindowIPCObserver {
            DistributedNotificationCenter.default().removeObserver(openTerminalSessionWindowIPCObserver)
            self.openTerminalSessionWindowIPCObserver = nil
        }
        if let focusTerminalSessionWindowIPCObserver {
            DistributedNotificationCenter.default().removeObserver(focusTerminalSessionWindowIPCObserver)
            self.focusTerminalSessionWindowIPCObserver = nil
        }
        if let closeTerminalSessionWindowIPCObserver {
            DistributedNotificationCenter.default().removeObserver(closeTerminalSessionWindowIPCObserver)
            self.closeTerminalSessionWindowIPCObserver = nil
        }
        if let dumpTerminalSessionWindowStateIPCObserver {
            DistributedNotificationCenter.default().removeObserver(dumpTerminalSessionWindowStateIPCObserver)
            self.dumpTerminalSessionWindowStateIPCObserver = nil
        }
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
        commandPaletteLoadTask?.cancel()
        commandPaletteLoadTask = nil
        commandPalettePanel?.close()
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionLauncher(nil)
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionTerminator(nil)
        releaseLaunchLeases()
    }

    private func setupAgentEventIPCObserver() {
        agentEventIPCObserver = DistributedNotificationCenter.default().addObserver(
            forName: IPCNotification.agentEventFired, object: ipcNotificationObject, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reloadData()
            }
        }
    }

    private func setupShowMainWindowIPCObserver() {
        showMainWindowIPCObserver = DistributedNotificationCenter.default().addObserver(
            forName: IPCNotification.showMainWindow, object: ipcNotificationObject, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let window = self.window else { return }
                self.revealTargetedHotkeyWindow(window)
            }
        }
    }

    private func setupHideMainWindowIPCObserver() {
        hideMainWindowIPCObserver = DistributedNotificationCenter.default().addObserver(
            forName: IPCNotification.hideMainWindow, object: ipcNotificationObject, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let window = self.window else { return }
                // This IPC is only used by the real-system E2E harness. Hide the
                // entire app process so the setup state is deterministic before
                // profiling external-app -> main-window hotkey flows.
                window.orderOut(nil)
                NSApp.hide(nil)
            }
        }
    }

    private func setupShowWindowIssueModalIPCObserver() {
        showWindowIssueModalIPCObserver = DistributedNotificationCenter.default().addObserver(
            forName: IPCNotification.showWindowIssueModal, object: ipcNotificationObject, queue: .main
        ) { [weak self] notification in
            guard let title = notification.userInfo?[IPCNotification.titleUserInfoKey] as? String else { return }
            guard let detail = notification.userInfo?[IPCNotification.detailUserInfoKey] as? String else { return }
            Task { @MainActor [weak self, title, detail] in
                guard let self else { return }
                self.showWindowIssueModal(title: title, detail: detail)
            }
        }
    }

    private func setupCycleWorkspaceWindowIPCObserver() {
        cycleWorkspaceWindowIPCObserver = DistributedNotificationCenter.default().addObserver(
            forName: IPCNotification.cycleWorkspaceWindow, object: ipcNotificationObject, queue: .main
        ) { [weak self] notification in
            guard let workspaceID = notification.userInfo?[IPCNotification.workspaceIDUserInfoKey] as? String else { return }
            guard let direction = notification.userInfo?[IPCNotification.cycleDirectionUserInfoKey] as? String else { return }
            let requestID = (notification.userInfo?[IPCNotification.focusRequestIDUserInfoKey] as? String)?.trimmingCharacters(
                in: .whitespacesAndNewlines)
            let preferredFocusedBuiltInTerminalSessionID = (notification.userInfo?[IPCNotification.terminalSessionIDUserInfoKey] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor [weak self, workspaceID, direction, requestID, preferredFocusedBuiltInTerminalSessionID] in
                guard let self else { return }
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
                        self.dismissCommandPaletteForBuiltInWindowNavigation()
                    }
                } catch { self.showError(error) }
            }
        }
    }

    private func setupSelectWorkspaceDetailIPCObserver() {
        selectWorkspaceDetailIPCObserver = DistributedNotificationCenter.default().addObserver(
            forName: IPCNotification.selectWorkspaceDetail, object: ipcNotificationObject, queue: .main
        ) { [weak self] notification in
            guard let workspaceID = notification.userInfo?[IPCNotification.workspaceIDUserInfoKey] as? String else { return }
            Task { @MainActor [weak self, workspaceID] in
                guard let self else { return }
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
    }

    private func setupOpenWorkspaceTerminalIPCObserver() {
        openWorkspaceTerminalIPCObserver = DistributedNotificationCenter.default().addObserver(
            forName: IPCNotification.openWorkspaceTerminal, object: ipcNotificationObject, queue: .main
        ) { [weak self] notification in
            guard let workspaceID = notification.userInfo?[IPCNotification.workspaceIDUserInfoKey] as? String else { return }
            Task { @MainActor [weak self, workspaceID] in
                guard let self else { return }
                self.openWorkspaceTerminal(workspaceID: workspaceID, route: .ipc)
            }
        }
    }

    private func setupRunWorkspaceProcessIPCObserver() {
        runWorkspaceProcessIPCObserver = DistributedNotificationCenter.default().addObserver(
            forName: IPCNotification.runWorkspaceProcess, object: nil, queue: .main
        ) { [weak self] notification in
            guard let workspaceID = notification.userInfo?[IPCNotification.workspaceIDUserInfoKey] as? String else { return }
            guard let processName = notification.userInfo?[IPCNotification.workspaceTargetNameUserInfoKey] as? String else { return }
            Task { @MainActor [weak self, workspaceID, processName] in
                guard let self else { return }
                self.runWorkspaceProcess(workspaceID: workspaceID, processName: processName)
            }
        }
    }

    private func setupStopWorkspaceProcessIPCObserver() {
        stopWorkspaceProcessIPCObserver = DistributedNotificationCenter.default().addObserver(
            forName: IPCNotification.stopWorkspaceProcess, object: nil, queue: .main
        ) { [weak self] notification in
            guard let workspaceID = notification.userInfo?[IPCNotification.workspaceIDUserInfoKey] as? String else { return }
            guard let processName = notification.userInfo?[IPCNotification.workspaceTargetNameUserInfoKey] as? String else { return }
            Task { @MainActor [weak self, workspaceID, processName] in
                guard let self else { return }
                self.stopWorkspaceProcess(workspaceID: workspaceID, processName: processName)
            }
        }
    }

    private func setupRestartWorkspaceProcessIPCObserver() {
        restartWorkspaceProcessIPCObserver = DistributedNotificationCenter.default().addObserver(
            forName: IPCNotification.restartWorkspaceProcess, object: nil, queue: .main
        ) { [weak self] notification in
            guard let workspaceID = notification.userInfo?[IPCNotification.workspaceIDUserInfoKey] as? String else { return }
            guard let processName = notification.userInfo?[IPCNotification.workspaceTargetNameUserInfoKey] as? String else { return }
            Task { @MainActor [weak self, workspaceID, processName] in
                guard let self else { return }
                self.restartWorkspaceProcess(workspaceID: workspaceID, processName: processName)
            }
        }
    }

    private func setupLaunchWorkspaceAgentIPCObserver() {
        launchWorkspaceAgentIPCObserver = DistributedNotificationCenter.default().addObserver(
            forName: IPCNotification.launchWorkspaceAgent, object: nil, queue: .main
        ) { [weak self] notification in
            guard let workspaceID = notification.userInfo?[IPCNotification.workspaceIDUserInfoKey] as? String else { return }
            guard let launcherName = notification.userInfo?[IPCNotification.workspaceTargetNameUserInfoKey] as? String else { return }
            Task { @MainActor [weak self, workspaceID, launcherName] in
                guard let self else { return }
                self.launchWorkspaceAgent(workspaceID: workspaceID, launcherName: launcherName)
            }
        }
    }

    private func setupOpenTerminalSessionWindowIPCObserver() {
        openTerminalSessionWindowIPCObserver = DistributedNotificationCenter.default().addObserver(
            forName: IPCNotification.openTerminalSessionWindow, object: ipcNotificationObject, queue: .main
        ) { [weak self] notification in
            guard let sessionID = notification.userInfo?[IPCNotification.terminalSessionIDUserInfoKey] as? String else { return }
            let modeRawValue = notification.userInfo?[IPCNotification.terminalAttachmentModeUserInfoKey] as? String
            let mode = modeRawValue.flatMap(TerminalAttachmentMode.init(rawValue:)) ?? .owner
            let requestID = notification.userInfo?[IPCNotification.focusRequestIDUserInfoKey] as? String
            Task { @MainActor [weak self, sessionID, mode, requestID] in
                guard let self else { return }
                self.openTerminalSessionWindow(sessionID: sessionID, mode: mode, requestID: requestID)
            }
        }
    }

    private func setupCloseTerminalSessionWindowIPCObserver() {
        closeTerminalSessionWindowIPCObserver = DistributedNotificationCenter.default().addObserver(
            forName: IPCNotification.closeTerminalSessionWindow, object: ipcNotificationObject, queue: .main
        ) { [weak self] notification in
            guard let sessionID = notification.userInfo?[IPCNotification.terminalSessionIDUserInfoKey] as? String else { return }
            Task { @MainActor [weak self, sessionID] in
                guard let self else { return }
                self.closeTerminalSessionWindows(sessionID: sessionID)
            }
        }
    }

    private func setupDumpTerminalSessionWindowStateIPCObserver() {
        dumpTerminalSessionWindowStateIPCObserver = DistributedNotificationCenter.default().addObserver(
            forName: IPCNotification.dumpTerminalSessionWindowState, object: nil, queue: .main
        ) { [weak self] notification in
            guard let sessionID = notification.userInfo?[IPCNotification.terminalSessionIDUserInfoKey] as? String else { return }
            guard let outputPath = notification.userInfo?[IPCNotification.outputPathUserInfoKey] as? String else { return }
            let modeRawValue = notification.userInfo?[IPCNotification.terminalAttachmentModeUserInfoKey] as? String
            let mode = modeRawValue.flatMap(TerminalAttachmentMode.init(rawValue:))
            Task { @MainActor [weak self, sessionID, outputPath, mode] in
                guard let self else { return }
                self.dumpTerminalSessionWindowState(sessionID: sessionID, mode: mode, outputPath: outputPath)
            }
        }
    }

    private func setupFocusTerminalSessionWindowIPCObserver() {
        focusTerminalSessionWindowIPCObserver = DistributedNotificationCenter.default().addObserver(
            forName: IPCNotification.focusTerminalSessionWindow, object: ipcNotificationObject, queue: .main
        ) { [weak self] notification in
            guard let sessionID = notification.userInfo?[IPCNotification.terminalSessionIDUserInfoKey] as? String else { return }
            let requestID = notification.userInfo?[IPCNotification.focusRequestIDUserInfoKey] as? String
            Task { @MainActor [weak self, sessionID, requestID] in
                guard let self else { return }
                self.focusTerminalSessionWindow(sessionID: sessionID, requestID: requestID)
            }
        }
    }

    private func dumpTerminalSessionWindowState(sessionID: String, mode: TerminalAttachmentMode?, outputPath: String) {
        pruneClosedTerminalSessionWindowControllers(sessionID: sessionID)
        let requestedMode = mode?.rawValue ?? "any"
        let controller = Self.liveTerminalSessionWindowController(terminalSessionWindowControllers[sessionID])
        if let controller { controller.debugRefreshStateForTesting(skipOwnerAttach: mode == .viewer) }
        let debugState = controller?.debugStateDump()
        let payload = TerminalSessionWindowStateDump(
            sessionID: sessionID, requestedMode: requestedMode, found: controller != nil, windowTitle: debugState?.windowTitle,
            rendererSummary: debugState?.rendererSummary, renderedOutput: debugState?.renderedOutput, summary: debugState?.summary,
            state: debugState?.state, showsTerminalSurface: debugState?.showsTerminalSurface, showsOutputFallback: debugState?.showsOutputFallback,
            didClose: debugState?.didCloseWindow)
        writeTerminalSessionWindowStateDump(payload, to: outputPath)
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

    private func openTerminalSessionWindow(sessionID: String, mode: TerminalAttachmentMode, requestID: String? = nil) {
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
                let useControlSocketClientActions = Self.shouldUseTerminalControlSocketClientActions(sessionID: sessionID)
                let attachClientAction: (@Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void)?
                let detachClientAction: (@Sendable (String) throws -> Void)?
                if useControlSocketClientActions {
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
                } else {
                    attachClientAction = nil
                    detachClientAction = nil
                }
                let created = TerminalSessionWindowController(
                    sessionID: sessionID, paths: paths, preferredAttachmentMode: mode, performInitialRefresh: false,
                    attachClientAction: attachClientAction, detachClientAction: detachClientAction,
                    detachClientSynchronouslyOnClose: !useControlSocketClientActions,
                    onWindowFocus: { [weak self] sessionID in self?.lastFocusedBuiltInTerminalSessionID = sessionID },
                    onWindowClose: { [weak self] sessionID, clientID in
                        if self?.lastFocusedBuiltInTerminalSessionID == sessionID { self?.lastFocusedBuiltInTerminalSessionID = nil }
                        self?.removeTerminalSessionWindowController(sessionID: sessionID, clientID: clientID)
                    },
                    sessionHostProvider: { launchConfiguration, paths in
                        Self.terminalSessionHost(launchConfiguration: launchConfiguration, paths: paths)
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
        } catch {
            logPerfMetric(
                "terminal_window_summon", target: "session=\(sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false,
                detail: "mode=\(mode.rawValue)\(requestDetail)")
            showError(error)
            return
        }
    }

    private func pruneClosedTerminalSessionWindowControllers(sessionID: String) {
        guard let controller = terminalSessionWindowControllers[sessionID] else { return }
        if controller.didClose { terminalSessionWindowControllers.removeValue(forKey: sessionID) }
    }

    private func closeTerminalSessionWindows(sessionID: String, sessionIsTerminating: Bool = false) {
        pruneClosedTerminalSessionWindowControllers(sessionID: sessionID)
        guard let controller = Self.liveTerminalSessionWindowController(terminalSessionWindowControllers[sessionID]) else { return }
        if sessionIsTerminating { controller.closeForSessionTermination() } else { controller.window?.close() }
        pruneClosedTerminalSessionWindowControllers(sessionID: sessionID)
    }

    private func focusTerminalSessionWindow(sessionID: String, requestID: String? = nil) {
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

    private func removeTerminalSessionWindowController(sessionID: String, clientID: String) {
        guard let controller = terminalSessionWindowControllers[sessionID] else { return }
        guard controller.clientID == clientID else { return }
        terminalSessionWindowControllers.removeValue(forKey: sessionID)
        terminateAdHocBuiltInTerminalSessionIfNeeded(sessionID: sessionID)
    }

    private func terminateAdHocBuiltInTerminalSessionIfNeeded(sessionID: String, now: Date = Date()) {
        let workspaceID = try? orchestrator.workspaceIDForTerminalSession(sessionID)
        guard let workspaceID else { return }
        let isConfiguredProcessSession = ((try? orchestrator.runningProcesses(workspaceID: workspaceID)) ?? []).contains {
            ($0.terminalNativeID ?? $0.terminalTrackingID) == sessionID
        }
        let paths = try? TerminalSessionPaths.forSession(id: sessionID)
        guard
            Self.shouldTerminateAdHocBuiltInTerminalSession(
                paths: paths, isConfiguredProcessSession: isConfiguredProcessSession,
                isAppTerminatingAndKeepingSessions: keepsTerminalSessionsRunningDuringTermination, now: now)
        else { return }
        if !Self.terminateLocalBuiltInTerminalSessionIfPresent(sessionID: sessionID) { try? TerminalService.terminateSession(id: sessionID) }
        if (try? orchestrator.removeAdHocBuiltInTerminalSession(sessionID: sessionID)) == true { requestSidebarReload() }
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
            }
        }
        appDidResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.logHotkeyDebug("app_did_resign_active \(self.hotkeyWindowStateSummary())")
                if self.commandPalettePanel?.isVisible == true { self.dismissCommandPalette() }
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
        terminateAdHocBuiltInTerminalSessionIfNeeded(sessionID: sessionID)
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
                do { try await Task.sleep(for: .seconds(PollingConstants.processMonitorInterval)) } catch { break }
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

    private func canReloadAfterBackgroundWorkspaceRefresh() -> Bool {
        !projectHasUnsavedChanges && activeAddWorkspaceFormTag == nil && activeAddProjectFormTag == nil && !isTextInputFocused()
    }

    private func canPreserveDetailPaneAfterSidebarReload() -> Bool {
        if activeAddWorkspaceFormTag != nil || activeAddProjectFormTag != nil { return true }
        if showingAlerts || showingSettings { return true }
        if let selectedWorkspaceID { return findWorkspace(id: selectedWorkspaceID) != nil }
        if let selectedProjectID { return projects.contains(where: { $0.id == selectedProjectID }) }
        return false
    }

    private enum WorkspaceLifecycleAction {
        case launch
        case restart
        case stop
        case archive(deleteLocalBranch: Bool, deleteRemoteBranch: Bool)
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
        let notes: String?
        let allowRemoteBranchLookup: Bool
        let allowExistingBranchReuse: Bool
    }

    private struct ProjectCreateInput: Sendable {
        let gitURL: String?
        let directoryPath: String?
        let setupScript: String?
        let stopScript: String?
        let ports: [PortDefinition]
        let processes: [ProcessTemplate]
        let browserSessions: [BrowserSession]
        let agentLaunchers: [AgentLauncher]
    }

    private struct SidebarDataSnapshot: Sendable {
        let config: AppConfig
        let projects: [ProjectSummary]
        let workspacesByProject: [String: [WorkspaceSummary]]
        let workspaceRuntimeStatusByID: [String: WorkspaceRuntimeStatus]
        let alertsGroups: [AlertsGroup]
    }

    /// Holds a click closure and serves as the NSGestureRecognizer target for clickable row views.
    @MainActor private final class ClickTarget: NSObject {
        let action: () async -> Void
        init(_ action: @escaping () async -> Void) { self.action = action }
        @objc func clicked(_ sender: NSGestureRecognizer) { Task { await self.action() } }
    }

    private static var clickTargetAssocKey: UInt8 = 0

    @MainActor static func terminalSessionHost(launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths)
        -> any TerminalGhosttySessionHosting
    {
        if GhosttyEmbeddedSessionRegistry.shared.existingCore(sessionID: launchConfiguration.sessionID) != nil {
            return GhosttyEmbeddedSessionRegistry.shared.host(for: launchConfiguration, paths: paths)
        }
        return RemoteGhosttySessionHost(launchConfiguration: launchConfiguration, paths: paths)
    }

    @MainActor static func shouldUseTerminalControlSocketClientActions(sessionID: String) -> Bool {
        GhosttyEmbeddedSessionRegistry.shared.existingCore(sessionID: sessionID) == nil
    }

    nonisolated static func launchLocalBuiltInTerminalSession(_ launchConfiguration: TerminalSessionLaunchConfiguration) throws
        -> TerminalServiceSessionSummary
    {
        try performBuiltInTerminalSessionWorkOnMainThread {
            let paths = try TerminalSessionPaths.forSession(id: launchConfiguration.sessionID)
            let sessionCore = GhosttyEmbeddedSessionRegistry.shared.core(for: launchConfiguration, paths: paths)
            try sessionCore.startIfNeeded()
            let runtimeState = try TerminalSessionPersistence.readRuntimeState(paths: paths)
            return TerminalServiceSessionSummary(
                id: launchConfiguration.sessionID, title: runtimeState.title ?? launchConfiguration.title,
                workingDirectory: runtimeState.workingDirectory ?? launchConfiguration.workingDirectory, backend: launchConfiguration.backend,
                lifetimePolicy: launchConfiguration.lifetimePolicy, state: runtimeState.state, servicePID: runtimeState.servicePID,
                childPID: runtimeState.childPID, controlSocketPath: paths.controlSocketPath, outputPath: paths.outputPath)
        }
    }

    nonisolated static func launchServiceBuiltInTerminalSession(_ launchConfiguration: TerminalSessionLaunchConfiguration) throws
        -> TerminalServiceSessionSummary
    { try appBuiltInTerminalSessionLauncher()(launchConfiguration) }

    nonisolated static func appBuiltInTerminalSessionLauncher(
        createSession: @escaping @Sendable (TerminalSessionLaunchConfiguration) throws -> TerminalServiceSessionSummary = {
            try TerminalService.createSession($0)
        }
    ) -> WorkspaceOrchestrator.BuiltInTerminalSessionLauncher { { launchConfiguration in try createSession(launchConfiguration) } }

    nonisolated static func terminateLocalBuiltInTerminalSessionIfPresent(sessionID: String) -> Bool {
        (try? performBuiltInTerminalSessionWorkOnMainThread {
            guard GhosttyEmbeddedSessionRegistry.shared.existingCore(sessionID: sessionID) != nil else { return false }
            GhosttyEmbeddedSessionRegistry.shared.terminate(sessionID: sessionID)
            return true
        }) ?? false
    }

    nonisolated static func terminateBuiltInTerminalSession(sessionID: String) {
        try? performBuiltInTerminalSessionWorkOnMainThread {
            (NSApp.delegate as? AppKitController)?.closeTerminalSessionWindows(sessionID: sessionID, sessionIsTerminating: true)
            if GhosttyEmbeddedSessionRegistry.shared.existingCore(sessionID: sessionID) != nil {
                GhosttyEmbeddedSessionRegistry.shared.terminate(sessionID: sessionID)
            } else {
                try? TerminalService.terminateSession(id: sessionID)
            }
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
            } catch { if Self.hotkeyDebugEnabled() { fputs("spaces: terminal service prewarm failed: \(error)\n", stderr) } }
        }
    }

    nonisolated private static func startupProfileEnabled() -> Bool { ProcessInfo.processInfo.environment["SPACES_STARTUP_PROFILE"] == "1" }

    nonisolated private static func startupElapsedMS() -> Int { Int((ProcessInfo.processInfo.systemUptime - startupProfileBaselineUptime) * 1000) }

    private func logStartupProfile(_ stage: String, details: String = "") {
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

    private func logHotkeyDebug(_ message: String) {
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

    private func hotkeyWindowStateSummary() -> String {
        let mainVisible = effectiveMainWindowVisibilityForHotkeyState() ? 1 : 0
        let mainMini = window?.isMiniaturized == true ? 1 : 0
        let mainKey = window?.isKeyWindow == true ? 1 : 0
        let paletteVisible = commandPalettePanel?.isVisible == true ? 1 : 0
        let paletteKey = commandPalettePanel?.isKeyWindow == true ? 1 : 0
        let auxiliaryVisible = hasVisibleAuxiliaryWindowsForHotkeyState() ? 1 : 0
        let terminalVisible = hasVisibleTerminalSessionWindowsForHotkeyState() ? 1 : 0
        return
            "app_active=\(NSApp.isActive ? 1 : 0) app_hidden=\(NSApp.isHidden ? 1 : 0) main_visible=\(mainVisible) main_key=\(mainKey) main_mini=\(mainMini) palette_exists=\(commandPalettePanel == nil ? 0 : 1) palette_visible=\(paletteVisible) palette_key=\(paletteKey) auxiliary_visible=\(auxiliaryVisible) terminal_visible=\(terminalVisible)"
    }

    private func rawMainWindowVisibility() -> Bool { window?.isVisible == true && window?.isMiniaturized != true }

    private func hasVisibleTerminalSessionWindowsForHotkeyState() -> Bool {
        terminalSessionWindowControllers.values.contains { controller in
            controller.window?.isVisible == true && controller.window?.isMiniaturized != true
        }
    }

    private func hasVisibleAuxiliaryWindowsForHotkeyState() -> Bool {
        if commandPalettePanel?.isVisible == true { return true }
        return hasVisibleTerminalSessionWindowsForHotkeyState()
    }

    private func focusedTerminalSessionIDForToggle() -> String? {
        for (sessionID, controller) in terminalSessionWindowControllers {
            if !controller.didClose && (controller.window?.isKeyWindow == true || controller.window?.isMainWindow == true) { return sessionID }
        }
        return nil
    }

    private func activateReturnApplication(processIdentifier: pid_t) {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else { return }
        application.activate(options: [])
    }

    private func activateCurrentApplicationForTargetedReveal() { NSApp.activate(ignoringOtherApps: true) }

    private func effectiveMainWindowVisibilityForHotkeyState() -> Bool {
        Self.effectiveMainWindowVisibilityForHotkeyState(
            rawMainWindowIsVisible: rawMainWindowVisibility(),
            commandPaletteMainWindowVisibility: commandPaletteMainWindowVisibility ?? pendingCommandPalettePresentation?.mainWindowWasVisible)
    }

    private static func alertsIconColor(_ tint: AlertsIconTint) -> NSColor {
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

    nonisolated private static func runWorkspaceLifecycleAction(_ action: WorkspaceLifecycleAction, workspaceID: String) async -> Result<
        WorkspaceLifecycleOutcome, Error
    > {
        await Task.detached(priority: .userInitiated) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = WorkspaceOrchestrator(store: store)
                var notice: String?
                switch action {
                case .launch: try orchestrator.launchWorkspace(workspaceID: workspaceID)
                case .restart: try orchestrator.restartWorkspace(workspaceID: workspaceID)
                case .stop:
                    let outcome = try orchestrator.stopWorkspace(workspaceID: workspaceID)
                    if outcome.skippedStopScriptBecauseWorkspaceDirectoryMissing {
                        notice = "Workspace directory is missing. Spaces stopped the workspace and skipped its stop script."
                    }
                case .archive(let deleteLocalBranch, let deleteRemoteBranch):
                    let outcome = try orchestrator.archiveWorkspace(
                        workspaceID: workspaceID, deleteLocalBranch: deleteLocalBranch, deleteRemoteBranch: deleteRemoteBranch)
                    notice = outcome.notice
                }
                return .success(.init(notice: notice))
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func openWorkspaceTerminalSnapshot(workspaceID: String) async -> Result<OpenWorkspaceTerminalSnapshotResult, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = WorkspaceOrchestrator(store: store, builtInTerminalWindowOpener: { _, _ in })
                let sessionID = try orchestrator.openWorkspaceTerminal(workspaceID: workspaceID)
                return .success(.init(sessionID: sessionID, action: .open(hidesApp: false)))
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func createWorkspaceSnapshot(input: WorkspaceCreateInput) async -> Result<WorkspaceRecord, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = WorkspaceOrchestrator(store: store)
                var workspace = try orchestrator.createWorkspace(
                    projectID: input.projectID, name: input.name, branch: input.branch, targetBranch: input.targetBranch,
                    directoryName: input.directoryName, runSetupScript: false, allowRemoteBranchLookup: input.allowRemoteBranchLookup,
                    allowExistingBranchReuse: input.allowExistingBranchReuse)
                if let notes = input.notes {
                    try orchestrator.updateWorkspaceNotes(workspaceID: workspace.id, notes: notes)
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
                let orchestrator = WorkspaceOrchestrator(store: store)
                let record: ProjectRecord
                if let gitURL = input.gitURL {
                    record = try orchestrator.addProject(gitURL: gitURL) { project in
                        project.setupScript = input.setupScript
                        project.stopScript = input.stopScript
                        project.ports = input.ports
                        project.processes = input.processes
                        project.browserSessions = input.browserSessions
                        project.agentLaunchers = input.agentLaunchers
                    }
                } else if let directoryPath = input.directoryPath {
                    record = try orchestrator.addProject(dir: directoryPath) { project in
                        project.setupScript = input.setupScript
                        project.stopScript = input.stopScript
                        project.ports = input.ports
                        project.processes = input.processes
                        project.browserSessions = input.browserSessions
                        project.agentLaunchers = input.agentLaunchers
                    }
                } else {
                    throw WorkspaceError.invalidArgument(message: "Project source is required.")
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
                let orchestrator = WorkspaceOrchestrator(store: store)
                try orchestrator.removeProject(dir: projectDirectory)
                return .success(())
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func performWindowFocusSnapshot(_ request: WindowFocusRequest) async -> Result<ExternalWindowAction, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = WorkspaceOrchestrator(store: store)
                switch request {
                case .workspaceBrowserSession(let workspaceID, let targetURL):
                    try orchestrator.focusWorkspaceBrowserSession(workspaceID: workspaceID, targetURL: targetURL)
                    return .success(.focus(hidesApp: true))
                case .workspaceWindow(let workspaceID, let index):
                    let trackedWindows = try orchestrator.windows(workspaceID: workspaceID)
                    let trackedWindow = index > 0 && index <= trackedWindows.count ? trackedWindows[index - 1] : nil
                    try orchestrator.focusWorkspaceWindow(workspaceID: workspaceID, index: index)
                    return .success(.focus(hidesApp: trackedWindow?.app != TerminalHost.spaces.appName))
                case .workspaceProcess(let workspaceID, let processID):
                    let process = try orchestrator.runningProcesses(workspaceID: workspaceID).first(where: { $0.id == processID })
                    try orchestrator.focusWorkspaceProcess(workspaceID: workspaceID, processID: processID)
                    return .success(.focus(hidesApp: process?.terminalApp != TerminalHost.spaces.appName))
                case .workspaceMissingConfiguredProcess(let workspaceID, let processKey):
                    try orchestrator.recoverMissingConfiguredProcess(workspaceID: workspaceID, processKey: processKey)
                    return .success(.open(hidesApp: false))
                case .workspaceAgentLauncher(let workspaceID, let name):
                    _ = try orchestrator.launchAgentLauncher(workspaceID: workspaceID, name: name)
                    return .success(.open(hidesApp: Self.shouldHideAfterConfiguredAgentLauncherOpen(terminalHost: .spaces)))
                case .agentWindow(let record):
                    try orchestrator.focusAgentWindow(record)
                    return .success(.focus(hidesApp: Self.shouldHideAfterAgentWindowFocus(provider: record.provider)))
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

    nonisolated static func recoveredProcessWindowDetail(title: String, terminalApp: String?) -> String {
        let destination = terminalApp == TerminalHost.spaces.appName ? "a new Spaces window" : "a new terminal window"
        return "\(title) reopened in \(destination)."
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
                        return .success(
                            .focused(
                                kind: "alerts_browser", recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(for: alertsFocusRequest),
                                hidesApp: true))
                    case .workspaceWindow(let workspaceID, let index):
                        let trackedWindows = try orchestrator.windows(workspaceID: workspaceID)
                        let trackedWindow = index > 0 && index <= trackedWindows.count ? trackedWindows[index - 1] : nil
                        try orchestrator.focusWorkspaceWindow(workspaceID: workspaceID, index: index)
                        return .success(
                            .focused(
                                kind: "alerts_window", recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(for: alertsFocusRequest),
                                hidesApp: trackedWindow?.app != TerminalHost.spaces.appName))
                    case .workspaceProcess(let workspaceID, let processID):
                        let process = try orchestrator.runningProcesses(workspaceID: workspaceID).first(where: { $0.id == processID })
                        try orchestrator.focusWorkspaceProcess(workspaceID: workspaceID, processID: processID)
                        return .success(
                            .focused(
                                kind: "alerts_process", recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(for: alertsFocusRequest),
                                hidesApp: process?.terminalApp != TerminalHost.spaces.appName))
                    case .workspaceMissingConfiguredProcess(let workspaceID, let processKey):
                        try orchestrator.recoverMissingConfiguredProcess(workspaceID: workspaceID, processKey: processKey)
                        return .success(.opened(kind: "alerts_process", hidesApp: false))
                    case .workspaceAgentLauncher(let workspaceID, let name):
                        _ = try orchestrator.launchAgentLauncher(workspaceID: workspaceID, name: name)
                        return .success(
                            .opened(kind: "alerts_agent_launcher", hidesApp: Self.shouldHideAfterConfiguredAgentLauncherOpen(terminalHost: .spaces)))
                    case .agentWindow(let record):
                        try orchestrator.focusAgentWindow(record)
                        return .success(
                            .focused(
                                kind: "alerts_agent", recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(for: alertsFocusRequest),
                                hidesApp: Self.shouldHideAfterAgentWindowFocus(provider: record.provider)))
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
                    return .success(
                        .focused(kind: "browser", recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(for: focusRequest), hidesApp: true))
                case .process:
                    guard let processID = target.processID else { return .success(.noMatch) }
                    let focusRequest = WindowFocusRequest.workspaceProcess(workspaceID: selectedWorkspaceID, processID: processID)
                    let process = processesByID[processID]
                    try orchestrator.focusWorkspaceProcess(workspaceID: selectedWorkspaceID, processID: processID)
                    return .success(
                        .focused(
                            kind: "process", recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(for: focusRequest),
                            hidesApp: process?.terminalApp != TerminalHost.spaces.appName))
                case .window:
                    guard let windowListIndex = target.windowListIndex else { return .success(.noMatch) }
                    let focusRequest = WindowFocusRequest.workspaceWindow(workspaceID: selectedWorkspaceID, index: windowListIndex + 1)
                    let targetWindow = windowListIndex < windows.count ? windows[windowListIndex] : nil
                    try orchestrator.focusWorkspaceWindow(workspaceID: selectedWorkspaceID, index: windowListIndex + 1)
                    return .success(
                        .focused(
                            kind: "window", recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(for: focusRequest),
                            hidesApp: targetWindow?.app != TerminalHost.spaces.appName))
                case .missingConfiguredProcess:
                    guard let processKey = target.processKey else { return .success(.noMatch) }
                    try orchestrator.recoverMissingConfiguredProcess(workspaceID: selectedWorkspaceID, processKey: processKey)
                    return .success(.opened(kind: "process", hidesApp: false))
                case .agentLauncher:
                    guard let launcherName = target.launcherName else { return .success(.noMatch) }
                    _ = try orchestrator.launchAgentLauncher(workspaceID: selectedWorkspaceID, name: launcherName)
                    return .success(.opened(kind: "agent_launcher", hidesApp: Self.shouldHideAfterConfiguredAgentLauncherOpen(terminalHost: .spaces)))
                case .agent:
                    guard let record = target.agentWindow else { return .success(.noMatch) }
                    let focusRequest = WindowFocusRequest.agentWindow(record)
                    try orchestrator.focusAgentWindow(record)
                    return .success(
                        .focused(
                            kind: "agent", recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(for: focusRequest),
                            hidesApp: Self.shouldHideAfterAgentWindowFocus(provider: record.provider)))
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
                let orchestrator = WorkspaceOrchestrator(store: store)
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
                let orchestrator = WorkspaceOrchestrator(store: store)
                let options = try orchestrator.gitBranchOptions(projectID: projectID, includeLiveRemoteHeads: true)
                return .success(options)
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func runProcessMonitorSnapshot() async -> Result<Bool, Error> {
        await Task.detached(priority: .utility) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = WorkspaceOrchestrator(store: store)
                let didUpdateProcessStates = try orchestrator.checkAndUpdateProcessStatuses()
                return .success(didUpdateProcessStates)
            } catch { return .failure(error) }
        }.value
    }

    nonisolated private static func runWorktreeDiscoverySnapshot() async -> Result<Int, Error> {
        await Task.detached(priority: .utility) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = WorkspaceOrchestrator(store: store)
                let created = try orchestrator.scanAndCreateWorkspacesFromWorktrees(projectID: nil)
                return .success(created.count)
            } catch { return .failure(error) }
        }.value
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

    nonisolated private static func initialSidebarDataSnapshot() async -> Result<SidebarDataSnapshot, Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let snapshotStartedAt = ProcessInfo.processInfo.systemUptime
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = WorkspaceOrchestrator(store: store)
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
                let alertsGroups = try buildAlertsGroupsSnapshot(
                    orchestrator: orchestrator, projects: projects, workspacesByProject: workspacesByProject)
                logStartupSnapshotProfile(
                    "sidebar_snapshot_alerts_ready",
                    details: "group_count=\(alertsGroups.count) item_count=\(alertsGroups.reduce(0) { $0 + $1.items.count })")
                logStartupSnapshotProfile(
                    "sidebar_snapshot_complete", details: "total_ms=\(Int((ProcessInfo.processInfo.systemUptime - snapshotStartedAt) * 1000))")
                return .success(
                    .init(
                        config: config, projects: projects, workspacesByProject: workspacesByProject,
                        workspaceRuntimeStatusByID: workspaceRuntimeStatusByID, alertsGroups: alertsGroups))
            } catch { return .failure(error) }
        }.value
    }

    nonisolated static func shouldHideAfterSuccessfulExternalWindowAction(_ succeeded: Bool, action: ExternalWindowAction) -> Bool {
        guard succeeded else { return false }
        switch action {
        case .focus(let hidesApp), .open(let hidesApp): return hidesApp
        }
    }

    nonisolated static func shouldHideAfterConfiguredAgentLauncherOpen(terminalHost: TerminalHost) -> Bool { terminalHost != .spaces }

    nonisolated static func shouldHideAfterAgentWindowFocus(provider: AgentProvider) -> Bool { provider != .spaces }

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

    nonisolated static func processTemplateKey(for template: ProcessTemplate) -> String {
        template.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    nonisolated static func runningWorkspaceProcessEditDecision(previous: [ProcessTemplate], updated: [ProcessTemplate])
        -> RunningWorkspaceProcessEditDecision
    {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let changedProcessNames = updated.compactMap { updatedTemplate -> String? in
            guard let previousTemplate = previousByID[updatedTemplate.id] else { return nil }
            guard previousTemplate.command != updatedTemplate.command || previousTemplate.executionMode != updatedTemplate.executionMode else {
                return nil
            }
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

    nonisolated static func codingAgentShortcutIdentity(launcherName: String) -> String { "launcher:\(normalizedRunRowName(launcherName))" }

    nonisolated static func codingAgentShortcutIdentity(agentWindowID: String) -> String { "agent:\(agentWindowID)" }

    nonisolated static func codingAgentDisplayName(label: String?, runtimeWindowTitle: String?) -> String {
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty { return label }
        if let runtimeWindowTitle = runtimeWindowTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !runtimeWindowTitle.isEmpty {
            return "Coding Agent \(runtimeWindowTitle)"
        }
        return "Coding Agent"
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
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
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

        let topBarRow = makeSidebarTopBarRow()
        topBarRow.translatesAutoresizingMaskIntoConstraints = false

        let alertsRow = makeAlertsSidebarRow()
        alertsRow.translatesAutoresizingMaskIntoConstraints = false
        alertsRowView = alertsRow

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
            iconView.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "Spaces")
            iconView.contentTintColor = sidebarRunningIndicatorColor()
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([iconView.widthAnchor.constraint(equalToConstant: 18), iconView.heightAnchor.constraint(equalToConstant: 18)])

        let mobileButton = sidebarRowIconButton(
            symbol: "iphone.gen3.radiowaves.left.and.right", tooltip: "Mobile connection", action: #selector(showMobileConnection))
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

    private func makeAlertsSidebarRow() -> NSView {
        let row = NSView()
        row.setAccessibilityIdentifier("sidebar-alerts")

        let titleLabel = NSTextField(labelWithString: "Alerts")
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor

        let hintLabel = NSTextField(labelWithString: footerShortcutHint(for: .guiAlertsShortcut))
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

        let click = NSClickGestureRecognizer(target: self, action: #selector(alertsRowClicked))
        row.addGestureRecognizer(click)
        return row
    }

    @objc private func alertsRowClicked() { showAlertsDetail() }

    private func updateAlertsRowAppearance() {
        guard let stack = alertsRowStack else { return }
        if showingAlerts {
            stack.layer?.backgroundColor = sidebarSelectedCardBackgroundColor().cgColor
        } else {
            stack.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    // MARK: - Alerts content

    private func buildAlertsGroups() -> [AlertsGroup] {
        alertsGroups.compactMap { group -> AlertsGroup? in
            let items = group.items.filter { !dismissedAlertsAttentionItemIDs.contains($0.attentionID) }
            guard !items.isEmpty else { return nil }
            return AlertsGroup(
                projectName: group.projectName, workspaceID: group.workspaceID, workspaceName: group.workspaceName,
                workspaceBranch: group.workspaceBranch, items: items)
        }
    }

    private func alertsAttentionCount() -> Int {
        buildAlertsGroups().reduce(0) { total, group in total + group.items.filter(\.countsTowardBadge).count }
    }

    private func loadAlertsDismissedAttentionItemIDs() {
        dismissedAlertsAttentionItemIDs = (try? orchestrator.alertsDismissedAttentionItemIDs()) ?? []
    }

    private func pruneDismissedAlertsAttentionItemIDsIfNeeded() {
        let activeIDs = Set(alertsGroups.flatMap { $0.items.map(\.attentionID) })
        let prunedIDs = dismissedAlertsAttentionItemIDs.intersection(activeIDs)
        guard prunedIDs != dismissedAlertsAttentionItemIDs else { return }
        dismissedAlertsAttentionItemIDs = prunedIDs
        do { try orchestrator.setAlertsDismissedAttentionItemIDs(prunedIDs) } catch { showError(error) }
    }

    private func dismissAlertsAttentionItem(_ attentionID: String) {
        guard !dismissedAlertsAttentionItemIDs.contains(attentionID) else { return }
        dismissedAlertsAttentionItemIDs.insert(attentionID)
        do {
            try orchestrator.setAlertsDismissedAttentionItemIDs(dismissedAlertsAttentionItemIDs)
            updateAlertsSidebarBadge()
            if showingAlerts { showAlertsDetail() }
        } catch {
            dismissedAlertsAttentionItemIDs.remove(attentionID)
            showError(error)
        }
    }

    private func filteredCommandPaletteItems(_ items: [CommandPaletteItem]) -> [CommandPaletteItem] {
        items.filter { item in
            guard let attentionID = item.alertsAttentionID else { return true }
            return !dismissedAlertsAttentionItemIDs.contains(attentionID)
        }
    }

    private func rememberRecentCommandPaletteFocusIdentity(_ identity: String) {
        recentCommandPaletteFocusIdentities.removeAll(where: { $0 == identity })
        recentCommandPaletteFocusIdentities.insert(identity, at: 0)
        if recentCommandPaletteFocusIdentities.count > 64 {
            recentCommandPaletteFocusIdentities.removeLast(recentCommandPaletteFocusIdentities.count - 64)
        }
    }

    private func showAlertsDetail() {
        clearInlineWorkspaceFieldRefs()
        activeAddWorkspaceFormTag = nil
        activeAddProjectFormTag = nil
        visibleDetailWorkspaceID = nil
        showingSettings = false
        showingAlerts = true
        let previousProjectID = selectedProjectID
        let previousWorkspaceID = selectedWorkspaceID
        selectedProjectID = nil
        selectedWorkspaceID = nil
        alertsFocusRequestMap = [:]
        outlineView.deselectAll(nil)
        // Reload only the previously-selected workspace row to clear its selection styling;
        // avoid full reloadData() which would reset expand/collapse state.
        refreshSidebarSelectionRows(
            previousProjectID: previousProjectID, currentProjectID: nil, previousWorkspaceID: previousWorkspaceID, currentWorkspaceID: nil)
        updateAlertsRowAppearance()

        for view in detailContainer.subviews { view.removeFromSuperview() }
        detailContainer.wantsLayer = true
        detailContainer.layer?.backgroundColor = sidebarPanelBackgroundColor().cgColor

        let groups = buildAlertsGroups()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Header
        let accentColor = sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
        let headerTitle = NSTextField(labelWithString: "Alerts")
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
                    if shortcutCounter <= 9, let focusRequest = entry.focusRequest { alertsFocusRequestMap[shortcutCounter] = focusRequest }
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
                    let card = alertsWindowCard(entry: entry, shortcut: shortcut, action: cardAction)
                    itemsStack.addArrangedSubview(card)
                    constrainFormFieldToFillWidth(card, in: itemsStack)
                }

                stack.addArrangedSubview(itemsStack)
                constrainFormFieldToFillWidth(itemsStack, in: stack)
            }
        }

        showScrollableDetailStack(stack)
    }

    /// Builds an alerts card with focus and dismiss affordances while preserving the workspace Run tab rows.
    private func alertsWindowCard(entry: AlertsAttentionEntry, shortcut: String, action: (() async -> Void)? = nil) -> NSView {
        let dismissButton = NSButton()
        dismissButton.title = ""
        dismissButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        dismissButton.imagePosition = .imageOnly
        dismissButton.setButtonType(.momentaryPushIn)
        dismissButton.isBordered = false
        dismissButton.contentTintColor = .secondaryLabelColor
        dismissButton.bezelStyle = .regularSquare
        dismissButton.target = self
        dismissButton.action = #selector(dismissAlertsAttentionItemAction(_:))
        dismissButton.identifier = NSUserInterfaceItemIdentifier(entry.attentionID)
        dismissButton.toolTip = "Dismiss from alerts"

        let mainRow = windowRow(
            icon: entry.icon, iconColor: Self.alertsIconColor(entry.iconTint), label: entry.label, detail: entry.detail, shortcut: shortcut,
            processStatus: entry.processStatus, agentStatus: entry.agentStatus,
            automationID: entry.agentStatus == nil ? nil : "alerts-agent-\(Self.automationIdentifierSlug(entry.label))",
            trailingAccessory: dismissButton, action: action)

        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 4
        container.translatesAutoresizingMaskIntoConstraints = false

        container.addArrangedSubview(mainRow)
        constrainFormFieldToFillWidth(mainRow, in: container)

        return container
    }

    @objc private func dismissAlertsAttentionItemAction(_ sender: NSButton) {
        guard let attentionID = sender.identifier?.rawValue, !attentionID.isEmpty else { return }
        dismissAlertsAttentionItem(attentionID)
    }

    private func makeRightPane() -> NSView {
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.wantsLayer = true
        detailContainer.layer?.backgroundColor = sidebarPanelBackgroundColor().cgColor
        showPlaceholder()
        return detailContainer
    }

    private func invalidateCommandPaletteCache() { commandPaletteNeedsReload = true }

    private func reloadData() {
        do {
            pendingWorktreeDiscoveryReload = false
            invalidateCommandPaletteCache()
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
            alertsGroups = try Self.buildAlertsGroupsSnapshot(
                orchestrator: orchestrator, projects: projects, workspacesByProject: workspacesByProject)
            loadAlertsDismissedAttentionItemIDs()
            pruneDismissedAlertsAttentionItemIDsIfNeeded()
            outlineView.reloadData()
            applySidebarProjectExpansionState()
            refreshSelection()
            updateAlertsSidebarBadge()
        } catch { showError(error) }
    }

    private func startBackgroundServicesIfNeeded() {
        guard !didStartBackgroundServices else { return }
        didStartBackgroundServices = true
        startPeriodicWorkspaceWindowRefresh()
        startPeriodicProcessMonitor()
        startPeriodicWorktreeDiscovery()
        startPeriodicSidebarMetadataRefresh()
    }

    private func stopBackgroundServices() {
        periodicWorkspaceRefreshTask?.cancel()
        periodicWorkspaceRefreshTask = nil
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
            Task { @MainActor [weak self] in await self?.loadInitialSidebarData() }
        }
        if Self.shouldDeferSetupChecksUntilAfterSplash(entryContext: entryContext) {
            Self.scheduleAfterNextRunLoopTurn { startSetupChecks() }
        } else {
            startSetupChecks()
        }
    }

    private func handleDeferredSetupRequirementIfNeeded(_ error: Error) -> Bool {
        guard shouldRouteToDeferredSetup(for: error) else { return false }
        enterSetupFlow(preferredInitialCheckID: .yabaiServiceRunning, entryContext: .deferredRequirement)
        return true
    }

    private func shouldRouteToDeferredSetup(for error: Error) -> Bool {
        if case WorkspaceError.yabaiUnavailable(let message) = error { return message.localizedStandardContains("failed to connect to socket") }
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
            showPlaceholder(message: "Spaces couldn't load workspace data.")
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
        updateAlertsRowAppearance()
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
        invalidateCommandPaletteCache()
        configCache = snapshot.config
        loadShortcutSpecs()
        projects = snapshot.projects
        workspacesByProject = snapshot.workspacesByProject
        workspaceRuntimeStatusByID = snapshot.workspaceRuntimeStatusByID
        alertsGroups = snapshot.alertsGroups
        loadAlertsDismissedAttentionItemIDs()
        pruneDismissedAlertsAttentionItemIDsIfNeeded()
        outlineView.reloadData()
        applySidebarProjectExpansionState()
        logStartupProfile("apply_snapshot_outline_ready")
        if !shouldPreserveDetailPane {
            refreshSelection()
            logStartupProfile("apply_snapshot_selection_ready")
        } else if Self.shouldRefreshVisibleWorkspaceDetail(
            selectedWorkspaceID: selectedWorkspaceID, showingAlerts: showingAlerts, showingSettings: showingSettings,
            workspaceExists: selectedWorkspaceID.flatMap { findWorkspace(id: $0) } != nil, mainWindowIsFocused: window?.isKeyWindow == true,
            commandPaletteIsVisible: commandPalettePanel?.isVisible == true)
        {
            refreshSelection()
            logStartupProfile("apply_snapshot_selection_preserved_ready")
        }
        updateAlertsSidebarBadge()
        logStartupProfile("apply_snapshot_alerts_badge_ready", details: "group_count=\(alertsGroups.count)")
        if showingAlerts { showAlertsDetail() }
    }

    /// Update the Alerts sidebar row badge with the current attention item count.
    private func updateAlertsSidebarBadge() {
        let totalCount = alertsAttentionCount()
        if let badge = alertsRowBadge {
            badge.stringValue = "\(totalCount)"
            badge.isHidden = totalCount == 0
        }
        NSApp.dockTile.badgeLabel = totalCount == 0 ? nil : "\(totalCount)"
        NSApp.dockTile.display()
    }

    private func refreshSelection() {
        if showingAlerts {
            showAlertsDetail()
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
        showAlertsDetail()
    }

    private func requestVisibleWorkspaceDetailRefreshIfNeeded(reason _: String) {
        guard let workspaceID = selectedWorkspaceID else { return }
        guard
            Self.shouldRefreshVisibleWorkspaceDetail(
                selectedWorkspaceID: selectedWorkspaceID, showingAlerts: showingAlerts, showingSettings: showingSettings,
                workspaceExists: findWorkspace(id: workspaceID) != nil, mainWindowIsFocused: window?.isKeyWindow == true,
                commandPaletteIsVisible: commandPalettePanel?.isVisible == true)
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
        clearInlineWorkspaceFieldRefs()
        activeAddWorkspaceFormTag = nil
        activeAddProjectFormTag = nil
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
        let overlay: NSView
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
            overlay = NSView()
            overlay.wantsLayer = true
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

        refreshWindowIssueToastAppearance()
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        actionButton.title = actionTitle ?? ""
        actionButton.isHidden = actionTitle == nil
        if actionTitle != nil { Theme.applyPrimaryStyle(to: actionButton) }
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

    private func refreshWindowIssueToastAppearance() {
        guard let layer = windowIssueToastOverlay?.layer else { return }
        layer.cornerRadius = UIRadius.large
        layer.borderWidth = 1
        let appearance = window?.contentView?.effectiveAppearance ?? window?.effectiveAppearance ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            layer.borderColor = NSColor.systemRed.withAlphaComponent(0.35).cgColor
            layer.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        }
    }

    @objc private func handleWindowIssueToastAction() {
        let action = windowIssueToastActionHandler
        hideWindowIssueToast()
        action?()
    }

    private func showWindowIssueModal(title: String, detail: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        hideWindowIssueToast()
        if commandPalettePanel?.isVisible == true {
            commandPaletteReturnTerminalSessionID = nil
            commandPaletteReturnApplicationProcessID = nil
            dismissCommandPalette()
        }
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

        if let window {
            prepareWindowForActiveSpaceSummon(window)
            NSApp.unhide(nil)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        Task { @MainActor in
            await Task.yield()
            if let window {
                prepareWindowForActiveSpaceSummon(window)
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
            let response = alert.runModal()
            if actionTitle != nil, response == .alertFirstButtonReturn { action?() }
        }
    }

    private func showSettingsDetail() {
        clearInlineWorkspaceFieldRefs()
        activeAddWorkspaceFormTag = nil
        activeAddProjectFormTag = nil
        visibleDetailWorkspaceID = nil
        showingSettings = true
        showingAlerts = false
        updateAlertsRowAppearance()
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

        let processShellPopUp = NSPopUpButton()
        processShellPopUp.translatesAutoresizingMaskIntoConstraints = false
        for shell in ProcessShell.allCases {
            processShellPopUp.addItem(withTitle: shell.displayName)
            processShellPopUp.itemArray.last?.representedObject = shell
        }
        if let currentShell = configCache?.processShell,
            let item = processShellPopUp.itemArray.first(where: { ($0.representedObject as? ProcessShell) == currentShell })
        {
            processShellPopUp.select(item)
        }
        processShellPopUp.setAccessibilityIdentifier("settings-process-shell")
        processShellPopUp.target = self
        processShellPopUp.action = #selector(processShellChanged(_:))
        processShellPopUp.setContentHuggingPriority(.defaultLow, for: .horizontal)

        var editorContentViews: [NSView] = [
            settingsLabeledField(
                name: "Preferred editor", hint: "Opened when you use the editor shortcut from inside a workspace", control: editorPopUp),
            settingsLabeledField(
                name: "Shell for shell-mode processes", hint: "Applies only when a process row uses Shell execution mode", control: processShellPopUp),
        ]
        if let current = currentEditor, !options.contains(where: { $0.preference == current }) {
            let note = helpTextLabel("Saved editor \"\(editorDisplayName(current))\" is not installed.")
            editorContentViews.append(note)
        }
        let editorCard = formSectionCard(icon: "square.and.pencil", title: "Editor & shell", contentViews: editorContentViews)
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

        // --- Mobile section ---
        let mobileCard = settingsMobileSection()
        stack.addArrangedSubview(mobileCard)
        constrainFormFieldToFillWidth(mobileCard, in: stack)

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

    private func settingsMobileSection() -> NSView {
        let response: SpacesMobileBridgeControlResponse? = { try? SpacesMobileBridgeControlClient.statusEnsuringCurrentTerminalService(timeout: 2) }()
        let devices = response?.devices ?? []
        let resetButton = actionButton(
            title: "Reset All Pairings", symbol: "trash", tooltip: "Remove all paired mobile devices and rotate the transport key",
            action: #selector(resetAllMobilePairings), primary: false)
        var rows: [NSView] = [
            settingsSettingRow(
                name: "Paired devices",
                hint: response == nil ? "Mobile bridge status unavailable" : "\(devices.count) device\(devices.count == 1 ? "" : "s") paired",
                control: resetButton)
        ]
        if !devices.isEmpty { rows.append(contentsOf: devices.map { mobileDeviceRow($0) }) }
        return formSectionCard(icon: "iphone", title: "Mobile", contentViews: rows)
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
        showingAlerts = false
        updateAlertsRowAppearance()
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
        let headerTitle = NSTextField(labelWithString: project.name)
        headerTitle.font = .systemFont(ofSize: 20, weight: .semibold)
        headerTitle.textColor = sidebarPrimaryTextColor(isSelected: false, isArchived: false)
        headerTitle.lineBreakMode = .byTruncatingTail
        headerTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.addArrangedSubview(headerTitle)

        let dirField = NSTextField(string: project.dir)
        dirField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        dirField.textColor = .tertiaryLabelColor
        dirField.lineBreakMode = .byTruncatingMiddle
        dirField.isEditable = false
        dirField.isSelectable = true
        dirField.drawsBackground = false
        dirField.isBordered = false
        dirField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let headerAndActionsRow = NSStackView()
        headerAndActionsRow.orientation = .vertical
        headerAndActionsRow.alignment = .leading
        headerAndActionsRow.spacing = 4
        headerAndActionsRow.addArrangedSubview(headerRow)
        headerAndActionsRow.addArrangedSubview(dirField)
        headerAndActionsRow.setCustomSpacing(2, after: headerRow)

        stack.addArrangedSubview(headerAndActionsRow)
        constrainFormFieldToFillWidth(headerRow, in: headerAndActionsRow)
        constrainFormFieldToFillWidth(dirField, in: headerAndActionsRow)
        constrainFormFieldToFillWidth(headerAndActionsRow, in: stack)

        // --- Fields ---
        let setupScriptSection = SetupScriptSection(
            value: fullProject?.setupScript ?? "", subtitle: "Runs when each new workspace is created or revived from archive.")
        let stopScriptSection = StopScriptSection(
            value: fullProject?.stopScript ?? "", subtitle: "Runs on stop/restart/archive after process termination.")
        let portsSection = PortsSection(
            ports: fullProject?.ports ?? [], subtitle: "Named ports allocated per workspace. Available as env vars in scripts and commands.")
        let processesSection = ProcessesSection(
            processes: fullProject?.processes ?? [], subtitle: "Define the commands that run inside your workspace.", showsRuntimeControls: false)
        let browserSessionsSection = BrowserSessionsSection(
            sessions: fullProject?.browserSessions ?? [], subtitle: "Optional names with URL prefixes to open automatically.")
        let agentLaunchersSection = AgentLaunchersSection(
            launchers: fullProject?.agentLaunchers ?? [], subtitle: "Named interactive coding agents that open in the built-in Spaces terminal.")

        setupScriptSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
        stopScriptSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
        portsSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
        portsSection.presentRemoveConfirmation = { [weak self] port, confirm in
            self?.presentProjectPortRemoveConfirmation(port: port, confirm: confirm)
        }
        processesSection.onCommit = { [weak self] _ in self?.projectHasUnsavedChanges = true }
        processesSection.validateProcess = { [weak self] process in
            try self?.orchestrator.validateProcessTemplate(
                process, allowedVariableNames: self?.orchestrator.directProcessVariableNamesForValidation(portDefinitions: fullProject?.ports ?? []))
        }
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
        saveButton.keyEquivalent = "\r"

        let deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteProject(_:)))
        deleteButton.identifier = NSUserInterfaceItemIdentifier(project.id)
        Theme.applyTextStyle(to: deleteButton, color: .systemRed)

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
            projectID: project.id, setupScriptSection: setupScriptSection, stopScriptSection: stopScriptSection, portsSection: portsSection,
            processesSection: processesSection, browserSessionsSection: browserSessionsSection, agentLaunchersSection: agentLaunchersSection)
        registerDirtyTracking(
            setupScriptSection: setupScriptSection, stopScriptSection: stopScriptSection, portsSection: portsSection,
            processesSection: processesSection, browserSessionsSection: browserSessionsSection, agentLaunchersSection: agentLaunchersSection)
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
        headerRow.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
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
        clearInlineWorkspaceFieldRefs()
        activeAddWorkspaceFormTag = nil
        activeAddProjectFormTag = nil
        showingSettings = false
        showingAlerts = false
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
        let sourceSegmented = NSSegmentedControl(
            labels: ["Pick folder", "Clone repo"], trackingMode: .selectOne, target: self, action: #selector(projectSourceChanged(_:)))
        sourceSegmented.selectedSegment = 0
        sourceSegmented.setAccessibilityIdentifier("add-project-source-mode")

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
        let processesSection = ProcessesSection(subtitle: "Commands that run inside each workspace.", showsRuntimeControls: false)
        let browserSessionsSection = BrowserSessionsSection(subtitle: "Browser windows opened automatically on launch.")
        let agentLaunchersSection = AgentLaunchersSection(subtitle: "Interactive coding agents that open in the built-in Spaces terminal.")

        // --- Source section: segmented control on top, input below ---
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
        cloneSourceSection.isHidden = true

        repoURLField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        repoURLField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        cloneSourceSection.addArrangedSubview(repoURLField)

        let sourceContentStack = NSStackView()
        sourceContentStack.orientation = .vertical
        sourceContentStack.alignment = .leading
        sourceContentStack.spacing = 8
        sourceContentStack.detachesHiddenViews = true
        sourceSegmented.setContentHuggingPriority(.defaultHigh, for: .horizontal)
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

        showScrollableDetailStack(stack)

        createButton.tag = storeAddProjectFields(
            sourceSegmented: sourceSegmented, localSourceSection: localSourceSection, cloneSourceSection: cloneSourceSection, dirField: dirField,
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
        showingAlerts = false
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

        stack.addArrangedSubview(headerRow)
        stack.addArrangedSubview(headerSubtitle)

        // --- Fields ---
        let nameField = NSTextField(string: "")
        nameField.placeholderString = "workspace title"
        nameField.setAccessibilityIdentifier("add-workspace-title")
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
        existingBranchField.target = self
        existingBranchField.action = #selector(addWorkspaceBranchFieldChanged(_:))
        existingBranchField.delegate = self
        existingBranchField.addItems(withObjectValues: targetBranches)
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
            let targetRow = labeledInputRow(label: "Target branch", input: targetBranchField)
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

        let card = formSectionCard(
            icon: "plus.rectangle.on.folder", title: "Workspace",
            subtitle: project.isGitRepo ? "Configure branch, title, and directory for your new workspace." : "Title your new workspace.",
            contentViews: [contentStack])
        stack.addArrangedSubview(card)
        constrainFormFieldToFillWidth(card, in: stack)

        // --- Buttons ---
        let createButton = actionButton(
            title: "Create", symbol: nil, tooltip: "Create workspace", action: #selector(createWorkspace(_:)), primary: true)
        createButton.setAccessibilityIdentifier("add-workspace-create")
        let cancelButton = actionButton(title: "Cancel", symbol: nil, tooltip: "Cancel", action: #selector(cancelProjectForm), primary: false)
        cancelButton.setAccessibilityIdentifier("add-workspace-cancel")
        Theme.applySecondaryStyle(to: cancelButton)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.setViews([cancelButton], in: .leading)
        buttonRow.setViews([createButton], in: .trailing)
        stack.addArrangedSubview(buttonRow)
        constrainFormFieldToFillWidth(buttonRow, in: stack)

        showScrollableDetailStack(stack)

        createButton.tag = storeAddWorkspaceFields(
            projectID: project.id, isGitRepo: project.isGitRepo, branchModeSegmented: project.isGitRepo ? branchModeSegmented : nil,
            existingBranchField: project.isGitRepo ? existingBranchField : nil, newBranchField: project.isGitRepo ? newBranchField : nil,
            targetBranchField: project.isGitRepo ? targetBranchField : nil, nameField: nameField,
            directoryNameField: project.isGitRepo ? directoryNameField : nil, notesField: notesField, autoNameState: autoNameState,
            progressiveInputViews: [], createButton: createButton, customizeStack: customizeStack, customizeButton: customizeButton)
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
                if !existingValue.isEmpty { existingBranchField.stringValue = existingValue }
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
        showingAlerts = false
        updateAlertsRowAppearance()
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

        let titleSaveButton = NSButton(title: "Save (↩)", target: self, action: #selector(saveInlineWorkspaceMetadata(_:)))
        titleSaveButton.controlSize = .small
        titleSaveButton.bezelStyle = .rounded
        titleSaveButton.isHidden = true
        titleSaveButton.setAccessibilityIdentifier("workspace-detail-title-save")
        titleSaveButton.toolTip = "Save title edit (↩)."

        let titleCancelButton = NSButton(title: "Cancel (Esc)", target: self, action: #selector(cancelInlineWorkspaceMetadata(_:)))
        titleCancelButton.controlSize = .small
        titleCancelButton.bezelStyle = .rounded
        titleCancelButton.isHidden = true
        titleCancelButton.setAccessibilityIdentifier("workspace-detail-title-cancel")
        titleCancelButton.toolTip = "Cancel title edit (Esc)."
        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.addArrangedSubview(statusDot)
        headerRow.addArrangedSubview(workspaceTitleSlot)
        headerRow.addArrangedSubview(runtimeWarningIcon)
        headerRow.addArrangedSubview(titleSaveButton)
        headerRow.addArrangedSubview(titleCancelButton)
        headerRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let tag = UUID().uuidString.hashValue
        let refs = InlineWorkspaceDetailFieldRefs(
            workspaceID: workspace.id, field: .title, valueLabel: workspaceTitleLabel, editorContainer: workspaceTitleField,
            textField: workspaceTitleField, textView: nil, saveButton: titleSaveButton, cancelButton: titleCancelButton,
            originalValue: workspace.title, isEditing: false)
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
        let shortcutTargets = Self.orderedWorkspaceRunShortcutTargets(
            browserSessions: browserSessions, processEntries: processEntries, processesByID: processesByID,
            configuredAgentLaunchers: configuredAgentLaunchers, agentWindows: agentWindows)
        let shortcutIndices = Self.workspaceDetailShortcutIndices(
            browserSessions: browserSessions, processEntries: processEntries, processesByID: processesByID,
            configuredAgentLaunchers: configuredAgentLaunchers, agentWindows: agentWindows)
        let processStatusByName = Self.workspaceProcessStatusByName(runningProcesses)
        let processesSection = workspaceProcessesSection(
            workspace: workspace, trackedWindows: trackedWindows, processEntries: processEntries, shortcutTargets: shortcutTargets,
            shortcutIndicesByName: shortcutIndices.processesByName, statusByName: processStatusByName)
        let agentLaunchersSection = workspaceAgentLaunchersSection(
            workspace: workspace, shortcutIndicesByIdentity: shortcutIndices.codingAgentsByIdentity, agentWindows: agentWindows,
            trackedWindows: trackedWindows)
        let browserSessionsSection = workspaceBrowserSessionsSection(workspace: workspace, shortcutIndicesByURL: shortcutIndices.browserSessionsByURL)
        let portsSection = workspacePortsSection(workspace: workspace)
        let stopScriptSection = workspaceStopScriptSection(workspace: workspace)

        stack.addArrangedSubview(headerAndActionsRow)
        stack.addArrangedSubview(inlineNotesRow)
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
        stack.setCustomSpacing(20, after: inlineNotesRow)
        constrainFormFieldToFillWidth(inlineNotesRow, in: stack)
        constrainFormFieldToFillWidth(headerRow, in: headerAndActionsRow)
        constrainFormFieldToFillWidth(dirField, in: headerAndActionsRow)
        constrainFormFieldToFillWidth(headerAndActionsRow, in: stack)
        showScrollableDetailStack(stack)
        detailContainer.layoutSubtreeIfNeeded()
    }

    private func workspaceProcessesSection(
        workspace: WorkspaceSummary, trackedWindows: [WindowRecord], processEntries: [WorkspaceRunProcessEntry],
        shortcutTargets: [WorkspaceRunShortcutTarget], shortcutIndicesByName: [String: Int], statusByName: [String: RowPrimitives.StatusKind]
    ) -> NSView? {
        guard let config = try? orchestrator.workspaceSettings(workspaceID: workspace.id) else { return nil }
        let runningProcesses = (try? orchestrator.runningProcesses(workspaceID: workspace.id)) ?? []
        let runningProcessIDByName = Dictionary(uniqueKeysWithValues: runningProcesses.map { (Self.processRuntimeKey(name: $0.templateName), $0.id) })
        let section = ProcessesSection(processes: config.processes)
        section.validateProcess = { [weak self] process in
            try self?.orchestrator.validateProcessTemplate(
                process, allowedVariableNames: self?.orchestrator.directProcessVariableNamesForValidation(portDefinitions: config.ports))
        }
        section.presentValidationError = { [weak self] error in self?.showError(error) }
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
                try orchestrator.runConfiguredProcess(workspaceID: workspace.id, processKey: key)
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
                id: window.id, label: fallback.label, detail: fallback.detail, shortcut: shortcut, status: .idle,
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
            "Changing the command or execution mode for \(names) requires an immediate restart. Choose Restart to apply the new launch behavior now, or Cancel Changes to keep the existing configuration."
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

            let title =
                (window.name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? (window.detail?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            if let title { result[agentWindow.id] = title }
        }
    }

    private func workspaceAgentLaunchersSection(
        workspace: WorkspaceSummary, shortcutIndicesByIdentity: [String: Int], agentWindows: [AgentWindowRecord], trackedWindows: [WindowRecord]
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
                if self.isView(hitView, descendantOf: refs.editorContainer) || self.isView(hitView, descendantOf: refs.saveButton)
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
            buttonRow.addArrangedSubview(saveButton)
            buttonRow.addArrangedSubview(cancelButton)

            contentStack.addArrangedSubview(valueLabel)
            contentStack.addArrangedSubview(editorContainer)
            contentStack.addArrangedSubview(buttonRow)
            row.addArrangedSubview(contentStack)
        } else {
            row.addArrangedSubview(valueLabel)
            row.addArrangedSubview(editorContainer)
            row.addArrangedSubview(saveButton)
            row.addArrangedSubview(cancelButton)
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
                let title = inlineWorkspaceEditorValue(refs).trimmingCharacters(in: .whitespacesAndNewlines)
                try orchestrator.updateWorkspaceName(workspaceID: refs.workspaceID, name: title)
                refs.originalValue = title
            case .branch:
                let branch = inlineWorkspaceEditorValue(refs).trimmingCharacters(in: .whitespacesAndNewlines)
                try orchestrator.updateWorkspaceMetadata(workspaceID: refs.workspaceID, branch: branch)
                refs.originalValue = branch
            case .notes:
                let trimmedNotes = inlineWorkspaceEditorValue(refs).trimmingCharacters(in: .whitespacesAndNewlines)
                let notes = trimmedNotes.isEmpty ? nil : trimmedNotes
                try orchestrator.updateWorkspaceNotes(workspaceID: refs.workspaceID, notes: notes)
                refs.originalValue = notes ?? ""
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

    private func footerShortcutHint(for setting: ShortcutSetting) -> String {
        if setting == .guiLeaderHotkey { return displayShortcut(modifiers: shortcutLeaderModifiers, separator: " ") }
        guard let spec = shortcutSpec(for: setting) else { return setting.defaultSpec }
        if setting.usesDigitRangeCapture { return displayShortcut(spec, separator: " ", keyText: "1-9") }
        return displayShortcut(spec, separator: " ")
    }

    private func commandPaletteFooterRow() -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5

        func addSep() {
            let sep = NSTextField(labelWithString: "|")
            sep.font = .systemFont(ofSize: 10, weight: .thin)
            sep.textColor = .quaternaryLabelColor
            row.addArrangedSubview(sep)
        }

        func addSegment(keys: [String], label: String) {
            let group = NSStackView()
            group.orientation = .horizontal
            group.alignment = .centerY
            group.spacing = 3
            for key in keys { group.addArrangedSubview(RowPrimitives.shortcutChip(key)) }
            let lbl = NSTextField(labelWithString: label)
            lbl.font = .systemFont(ofSize: 10.5, weight: .regular)
            lbl.textColor = .secondaryLabelColor
            group.addArrangedSubview(lbl)
            row.addArrangedSubview(group)
        }

        let jumpKey = footerShortcutHint(for: .guiWindowShortcut)
        addSegment(keys: ["↑", "↓"], label: "Move")
        addSep()
        addSegment(keys: ["↵"], label: "Open")
        addSep()
        addSegment(keys: ["esc"], label: "Close")
        addSep()
        addSegment(keys: [jumpKey], label: "Jump")
        addSep()
        addSegment(keys: ["⌘ X"], label: "Dismiss alert")
        row.addArrangedSubview(NSView())
        return row
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
        if primary { stylePrimaryActionButton(button, title: title) }
        return button
    }

    private func stylePrimaryActionButton(_ button: NSButton, title: String) {
        Theme.applyPrimaryStyle(to: button)
        if let image = button.image { button.image = image.withSymbolConfiguration(.init(paletteColors: [Theme.primaryButtonText])) }
    }

    private func constrainFormFieldToFillWidth(_ view: NSView, in stack: NSStackView) {
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
        projectID: String, setupScriptSection: SetupScriptSection, stopScriptSection: StopScriptSection, portsSection: PortsSection,
        processesSection: ProcessesSection, browserSessionsSection: BrowserSessionsSection, agentLaunchersSection: AgentLaunchersSection
    ) -> Int {
        let id = projectID.hashValue
        ProjectFieldCache.shared.cache[id] = ProjectFieldRefs(
            projectID: projectID, setupScriptSection: setupScriptSection, stopScriptSection: stopScriptSection, portsSection: portsSection,
            processesSection: processesSection, browserSessionsSection: browserSessionsSection, agentLaunchersSection: agentLaunchersSection)
        return id
    }

    private func storeAddProjectFields(
        sourceSegmented: NSSegmentedControl, localSourceSection: NSStackView, cloneSourceSection: NSStackView, dirField: NSTextField,
        repoURLField: NSTextField, setupScriptSection: SetupScriptSection, stopScriptSection: StopScriptSection, portsSection: PortsSection,
        processesSection: ProcessesSection, browserSessionsSection: BrowserSessionsSection, agentLaunchersSection: AgentLaunchersSection,
        browseButton: NSButton, progressiveInputViews: [NSView], createButton: NSButton
    ) -> Int {
        let id = UUID().uuidString.hashValue
        AddProjectFieldCache.shared.cache[id] = AddProjectFieldRefs(
            sourceSegmented: sourceSegmented, localSourceSection: localSourceSection, cloneSourceSection: cloneSourceSection, dirField: dirField,
            repoURLField: repoURLField, browseButton: browseButton, progressiveInputViews: progressiveInputViews, createButton: createButton,
            setupScriptSection: setupScriptSection, stopScriptSection: stopScriptSection, portsSection: portsSection,
            processesSection: processesSection, browserSessionsSection: browserSessionsSection, agentLaunchersSection: agentLaunchersSection)
        sourceSegmented.tag = id
        browseButton.tag = id
        return id
    }

    private func storeAddWorkspaceFields(
        projectID: String, isGitRepo: Bool, branchModeSegmented: NSSegmentedControl?, existingBranchField: NSComboBox?, newBranchField: NSTextField?,
        targetBranchField: NSComboBox?, nameField: NSTextField, directoryNameField: NSTextField?, notesField: NSTextField?,
        autoNameState: AddWorkspaceAutoNameState?, progressiveInputViews: [NSView], createButton: NSButton, customizeStack: NSView?,
        customizeButton: NSButton?
    ) -> Int {
        let id = UUID().uuidString.hashValue
        AddWorkspaceFieldCache.shared.cache[id] = AddWorkspaceFieldRefs(
            projectID: projectID, isGitRepo: isGitRepo, branchModeSegmented: branchModeSegmented, existingBranchField: existingBranchField,
            newBranchField: newBranchField, targetBranchField: targetBranchField, nameField: nameField, directoryNameField: directoryNameField,
            notesField: notesField, autoNameState: autoNameState, progressiveInputViews: progressiveInputViews, createButton: createButton,
            customizeStack: customizeStack, customizeButton: customizeButton)
        branchModeSegmented?.tag = id
        customizeButton?.tag = id
        return id
    }

    @objc private func reloadTapped() { reloadData() }

    @objc private func showMobileConnection() {
        presentMobileConnectionPanelOrShowError { try SpacesMobileBridgeControlClient.statusEnsuringCurrentTerminalService() }
    }

    private func presentMobileConnectionPanelOrShowError(_ loadResponse: () throws -> SpacesMobileBridgeControlResponse) {
        do { presentMobileConnectionPanel(try loadResponse()) } catch {
            if let unavailableResponse = mobileConnectionUnavailableResponse(for: error) {
                presentMobileConnectionPanel(unavailableResponse)
            } else {
                showError(error)
            }
        }
    }

    private func mobileConnectionUnavailableResponse(for error: Error) -> SpacesMobileBridgeControlResponse? {
        guard SpacesMobileBridgeControlClient.isControlEndpointUnavailable(error) else { return nil }
        return SpacesMobileBridgeControlResponse(
            ok: false,
            message:
                "Mobile bridge control is unavailable for this profile. Relaunch Spaces without the disabled bridge environment override, or use the standalone bridge from a terminal."
        )
    }

    private func presentMobileConnectionPanel(_ response: SpacesMobileBridgeControlResponse) {
        let pairingWindow = visibleMobilePairingWindow(for: response)
        let panel: NSPanel
        if let existing = mobileConnectionPanel {
            panel = existing
        } else {
            let created = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 680), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered,
                defer: false)
            created.title = "Mobile Connection"
            created.isReleasedWhenClosed = false
            created.minSize = NSSize(width: 500, height: 520)
            created.center()
            mobileConnectionPanel = created
            panel = created
        }
        panel.contentView = buildMobileConnectionPanelContent(response: response, pairingWindow: pairingWindow)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startMobileConnectionTimer()
    }

    private func refreshVisibleMobileConnectionPanel(_ response: SpacesMobileBridgeControlResponse) {
        guard let panel = mobileConnectionPanel, panel.isVisible else { return }
        let pairingWindow = visibleMobilePairingWindow(for: response)
        panel.contentView = buildMobileConnectionPanelContent(response: response, pairingWindow: pairingWindow)
    }

    private func visibleMobilePairingWindow(for response: SpacesMobileBridgeControlResponse) -> SpacesMobilePairingWindowSnapshot? {
        if let pairingWindow = response.pairingWindow, pairingWindow.expiresAt > Date() { return pairingWindow }
        return nil
    }

    private func buildMobileConnectionPanelContent(response: SpacesMobileBridgeControlResponse, pairingWindow: SpacesMobilePairingWindowSnapshot?)
        -> NSView
    {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        root.layer?.backgroundColor = sidebarPanelBackgroundColor().cgColor

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let title = NSTextField(labelWithString: "Mobile Connection")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = sidebarPrimaryTextColor(isSelected: false, isArchived: false)
        stack.addArrangedSubview(title)

        let pairingSection = mobilePairingSection(response: response, pairingWindow: pairingWindow)
        stack.addArrangedSubview(pairingSection)
        constrainFormFieldToFillWidth(pairingSection, in: stack)

        let devicesSection = mobileDevicesSection(devices: response.devices ?? [])
        stack.addArrangedSubview(devicesSection)
        constrainFormFieldToFillWidth(devicesSection, in: stack)

        // Flexible trailing spacer absorbs any extra vertical space so the sections
        // keep their natural height instead of one card stretching to fill the panel.
        let bottomSpacer = NSView()
        bottomSpacer.translatesAutoresizingMaskIntoConstraints = false
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        bottomSpacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(bottomSpacer)
        constrainFormFieldToFillWidth(bottomSpacer, in: stack)

        root.addSubview(scroll)
        let contentBottomFollowsStack = content.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: 24)
        contentBottomFollowsStack.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.bottomAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24), contentBottomFollowsStack,
        ])
        return root
    }

    private func mobilePairingSection(response: SpacesMobileBridgeControlResponse, pairingWindow: SpacesMobilePairingWindowSnapshot?) -> NSView {
        var rows: [NSView] = []

        if let window = pairingWindow, window.expiresAt > Date() {
            rows.append(mobilePairingInstructionLabel("Scan this QR code with the Spaces app on your phone to pair it."))
            rows.append(mobileQRCodeView(link: window.linkString))
            rows.append(mobilePairingCodeRow(code: window.code, expiresAt: window.expiresAt))
            let newCodeButton = actionButton(
                title: "New Code", symbol: "arrow.clockwise", tooltip: "Replace the current code with a fresh one",
                action: #selector(openMobilePairingWindow), primary: false)
            rows.append(mobilePanelButtonRow([newCodeButton]))
        } else {
            rows.append(mobilePairingInstructionLabel("Start pairing to show a QR code you can scan with the Spaces app on your phone."))
            let pairButton = actionButton(
                title: "Pair a Device", symbol: "qrcode", tooltip: "Show a QR code to pair a phone", action: #selector(openMobilePairingWindow),
                primary: true)
            pairButton.isEnabled = response.ok || response.status != nil
            rows.append(mobilePanelButtonRow([pairButton]))
            if !response.ok { rows.append(helpTextLabel(response.message)) }
        }

        return mobilePanelSection(icon: "qrcode", title: "Pair a Device", rows: rows)
    }

    private func mobilePairingInstructionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        return label
    }

    private func mobilePairingCodeRow(code: String, expiresAt: Date) -> NSView {
        let codeLabel = NSTextField(labelWithString: code)
        codeLabel.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        codeLabel.textColor = Theme.text

        let expiresLabel = NSTextField(labelWithString: "Expires in \(mobileCountdownText(expiresAt: expiresAt))")
        expiresLabel.font = .systemFont(ofSize: 11)
        expiresLabel.textColor = .secondaryLabelColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.addArrangedSubview(codeLabel)
        stack.addArrangedSubview(expiresLabel)
        return stack
    }

    private func mobileQRCodeView(link: String) -> NSView {
        let qrSize: CGFloat = 200
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let qrView = NSImageView()
        qrView.image = qrImage(for: link, size: qrSize)
        qrView.imageScaling = .scaleProportionallyUpOrDown
        qrView.translatesAutoresizingMaskIntoConstraints = false
        qrView.wantsLayer = true
        qrView.layer?.backgroundColor = NSColor.white.cgColor
        qrView.layer?.cornerRadius = 4
        qrView.layer?.masksToBounds = true
        container.addSubview(qrView)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: qrSize), qrView.widthAnchor.constraint(equalToConstant: qrSize),
            qrView.heightAnchor.constraint(equalToConstant: qrSize), qrView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            qrView.topAnchor.constraint(equalTo: container.topAnchor), qrView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func mobileDevicesSection(devices: [SpacesMobilePairedDevice]) -> NSView {
        var rows: [NSView] = []
        if devices.isEmpty {
            rows.append(helpTextLabel("No devices are paired yet."))
        } else {
            rows.append(contentsOf: devices.map { mobileDeviceRow($0) })
            let resetButton = actionButton(
                title: "Remove All", symbol: "trash", tooltip: "Remove all paired mobile devices and rotate the transport key",
                action: #selector(resetAllMobilePairings), primary: false)
            rows.append(mobilePanelButtonRow([resetButton]))
        }
        return mobilePanelSection(icon: "iphone", title: "Paired Devices", rows: rows)
    }

    private func mobilePanelSection(icon: String, title: String, rows: [NSView]) -> NSView {
        let section = NSView()
        section.translatesAutoresizingMaskIntoConstraints = false
        section.setContentHuggingPriority(.required, for: .vertical)

        let accentColor = sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
        let iconView = NSImageView()
        if let image = NSImage(systemSymbolName: icon, accessibilityDescription: title) {
            iconView.image = image.withSymbolConfiguration(.init(paletteColors: [accentColor]))
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([iconView.widthAnchor.constraint(equalToConstant: 18), iconView.heightAnchor.constraint(equalToConstant: 18)])

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = Theme.text

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        header.addArrangedSubview(iconView)
        header.addArrangedSubview(titleLabel)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(header)
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        if !rows.isEmpty { stack.addArrangedSubview(mobilePanelDivider()) }
        for row in rows {
            let paddedRow = mobilePanelPaddedRow(row)
            stack.addArrangedSubview(paddedRow)
            paddedRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        section.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: section.leadingAnchor), stack.trailingAnchor.constraint(equalTo: section.trailingAnchor),
            stack.topAnchor.constraint(equalTo: section.topAnchor), stack.bottomAnchor.constraint(equalTo: section.bottomAnchor),
        ])
        return section
    }

    private func mobilePanelPaddedRow(_ view: NSView) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 9),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -9),
        ])
        return container
    }

    private func mobilePanelDivider(indent: CGFloat = 0) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.border.cgColor
        container.addSubview(divider)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 1),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: indent),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -indent),
            divider.topAnchor.constraint(equalTo: container.topAnchor), divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func mobilePanelButtonRow(_ buttons: [NSButton]) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        for button in buttons {
            button.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(button)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        return row
    }

    private func mobileDeviceRow(_ device: SpacesMobilePairedDevice) -> NSView {
        let titleLabel = NSTextField(labelWithString: device.deviceName)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1

        let platformText = [device.platform, device.appVersion].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " ")
        let detailPrefix = platformText.isEmpty ? "" : "\(platformText) · "
        let detailLabel = NSTextField(labelWithString: "\(detailPrefix)Last used \(mobilePanelDateText(device.lastUsedAt))")
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(detailLabel)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let revokeButton = iconButton(symbol: "xmark.circle", tooltip: "Remove this device", action: #selector(revokeMobileDevice(_:)))
        revokeButton.identifier = NSUserInterfaceItemIdentifier(device.installationID)
        revokeButton.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(revokeButton)
        return row
    }

    private func mobilePanelDateText(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func mobileCountdownText(expiresAt: Date) -> String {
        let remaining = max(Int(expiresAt.timeIntervalSince(Date()).rounded(.down)), 0)
        let minutes = remaining / 60
        let seconds = remaining % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func startMobileConnectionTimer() {
        mobileConnectionTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.refreshMobileConnectionPanelIfVisible() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mobileConnectionTimer = timer
    }

    private func refreshMobileConnectionPanelIfVisible() {
        guard mobileConnectionPanel?.isVisible == true else {
            mobileConnectionTimer?.invalidate()
            mobileConnectionTimer = nil
            return
        }
        do { refreshVisibleMobileConnectionPanel(try SpacesMobileBridgeControlClient.status(timeout: 1)) } catch {}
    }

    @objc private func openMobilePairingWindow() {
        presentMobileConnectionPanelOrShowError { try SpacesMobileBridgeControlClient.openPairingWindow() }
    }

    @objc private func revokeMobileDevice(_ sender: NSButton) {
        guard let installationID = sender.identifier?.rawValue else { return }
        presentMobileConnectionPanelOrShowError { try SpacesMobileBridgeControlClient.revokeDevice(installationID: installationID) }
    }

    @objc private func resetAllMobilePairings() { presentMobileConnectionPanelOrShowError { try SpacesMobileBridgeControlClient.resetAllPairings() } }

    private func qrImage(for value: String, size: CGFloat) -> NSImage? {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(Data(value.utf8), forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter?.outputImage else { return nil }
        let quietZone: CGFloat = 16
        let availableSize = max(size - (quietZone * 2), 1)
        let scale = max(floor(availableSize / output.extent.width), 1)
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = CIContext().createCGImage(transformed, from: transformed.extent) else { return nil }
        let qrSize = transformed.extent.size
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: cgImage, size: qrSize).draw(
            in: NSRect(x: (size - qrSize.width) / 2, y: (size - qrSize.height) / 2, width: qrSize.width, height: qrSize.height),
            from: NSRect(origin: .zero, size: qrSize), operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        return image
    }

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

    @objc private func openWorkspaceFinder(_ sender: NSButton) {
        guard let workspaceID = sender.identifier?.rawValue else { return }
        openWorkspaceFinder(workspaceID: workspaceID)
    }

    @objc private func editorPreferenceChanged(_ sender: NSPopUpButton) {
        guard let preference = sender.selectedItem?.representedObject as? EditorPreference else { return }
        if configCache?.editor == preference { return }
        do { configCache = try orchestrator.updateEditorPreference(preference) } catch { showError(error) }
    }

    @objc private func processShellChanged(_ sender: NSPopUpButton) {
        guard let processShell = sender.selectedItem?.representedObject as? ProcessShell else { return }
        if configCache?.processShell == processShell { return }
        do { configCache = try orchestrator.updateProcessShell(processShell) } catch { showError(error) }
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

    @objc private func saveProject(_ sender: NSButton) {
        commitEditing()
        guard let refs = ProjectFieldCache.shared.cache[sender.tag] else { return }
        do {
            try orchestrator.updateProjectConfig(projectID: refs.projectID) { config in
                config.setupScript = refs.setupScriptSection.currentValue.isEmpty ? nil : refs.setupScriptSection.currentValue
                config.stopScript = refs.stopScriptSection.currentValue.isEmpty ? nil : refs.stopScriptSection.currentValue
                config.ports = refs.portsSection.currentPorts
                config.processes = refs.processesSection.currentProcesses
                config.browserSessions = refs.browserSessionsSection.currentSessions
                config.agentLaunchers = refs.agentLaunchersSection.currentLaunchers
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
            This removes the project and its workspaces from Spaces.
            If this project was cloned into ~/spaces/repos by Spaces, that project directory is deleted.
            For git projects, related workspace directories under ~/spaces/workspaces are also deleted.
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
            if refs.sourceSegmented.selectedSegment == 1 {
                let repoURL = refs.repoURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !repoURL.isEmpty else { throw WorkspaceError.invalidArgument(message: "Git repository URL is required.") }
                input = ProjectCreateInput(
                    gitURL: repoURL, directoryPath: nil, setupScript: setupScript, stopScript: stopScript, ports: refs.portsSection.currentPorts,
                    processes: refs.processesSection.currentProcesses, browserSessions: refs.browserSessionsSection.currentSessions,
                    agentLaunchers: refs.agentLaunchersSection.currentLaunchers)
                progressDetail = "Cloning repository and applying project settings."
            } else {
                let dir = refs.dirField.toolTip?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !dir.isEmpty else { return }
                input = ProjectCreateInput(
                    gitURL: nil, directoryPath: dir, setupScript: setupScript, stopScript: stopScript, ports: refs.portsSection.currentPorts,
                    processes: refs.processesSection.currentProcesses, browserSessions: refs.browserSessionsSection.currentSessions,
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

    @objc private func projectSourceChanged(_ sender: NSSegmentedControl) {
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
        let cloneSelected = refs.sourceSegmented.selectedSegment == 1
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
        if refs.sourceSegmented.selectedSegment == 1 { return !refs.repoURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
            let targetBranch = refs.targetBranchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = currentAddWorkspaceBranchValue(refs).trimmingCharacters(in: .whitespacesAndNewlines)
            let directoryName = refs.directoryNameField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedDirectoryName: String?
            if let directoryName, directoryName.isEmpty { resolvedDirectoryName = nil } else { resolvedDirectoryName = directoryName }
            let notes = refs.notesField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedNotes: String?
            if let notes, notes.isEmpty { resolvedNotes = nil } else { resolvedNotes = notes }
            if refs.isGitRepo, branch.isEmpty { throw WorkspaceError.invalidArgument(message: "Branch name is required for git projects.") }
            if refs.isGitRepo, targetBranch == nil || targetBranch?.isEmpty == true {
                throw WorkspaceError.invalidArgument(message: "Target branch is required for git projects.")
            }
            if refs.isGitRepo, addWorkspaceBranchMode(refs: refs) == .create, refs.autoNameState?.branchOptions.contains(branch) == true {
                throw WorkspaceError.invalidArgument(
                    message: "Branch '\(branch)' already exists. Choose it from Existing branch or enter a different new branch name.")
            }
            let input = WorkspaceCreateInput(
                projectID: refs.projectID, name: name, branch: branch, targetBranch: targetBranch, directoryName: resolvedDirectoryName,
                notes: resolvedNotes, allowRemoteBranchLookup: true, allowExistingBranchReuse: addWorkspaceBranchMode(refs: refs) == .existing)
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
        if changedField === commandPaletteSearchField {
            logHotkeyDebug("search_change query=\(changedField.stringValue)")
            applyCommandPaletteFilter()
            return
        }
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
        if textField === commandPaletteSearchField {
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                moveCommandPaletteSelection(delta: 1)
                return true
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                moveCommandPaletteSelection(delta: -1)
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                executeSelectedCommandPaletteItem()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                dismissCommandPalette()
                return true
            }
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
        let didOptimisticallyArchive = optimisticallyArchiveWorkspaceInSidebar(workspaceID: id)
        if !didOptimisticallyArchive { button?.isEnabled = false }
        showOperationProgressOverlay(message: "Archiving workspace...", detail: "Stopping runtime state and cleaning up workspace files.")
        Task { @MainActor [weak self, weak button] in
            guard let self else { return }
            defer { hideOperationProgressOverlay() }
            let result = await Self.runWorkspaceLifecycleAction(
                .archive(deleteLocalBranch: deleteLocalBranch, deleteRemoteBranch: deleteRemoteBranch), workspaceID: id)
            switch result {
            case .success(let outcome):
                if didOptimisticallyArchive {
                    requestSidebarReload()
                } else {
                    button?.isEnabled = true
                    reloadData()
                }
                if let notice = outcome.notice { showInfoMessage(title: "Workspace Archived", message: notice) }
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { completion?() }
            let result = await Self.openWorkspaceTerminalSnapshot(workspaceID: workspaceID)
            let elapsedMS = windowShortcutElapsedMS(since: startedAt)
            switch result {
            case .success(let result):
                logPerfMetric(
                    "workspace_terminal_open_ui", target: "workspace=\(workspaceID)", elapsedMS: elapsedMS, success: true,
                    detail: "route=\(route.rawValue)")
                openTerminalSessionWindow(sessionID: result.sessionID, mode: .owner)
                reloadData()
                hideAfterSuccessfulExternalWindowAction(result.action)
            case .failure(let error):
                logPerfMetric(
                    "workspace_terminal_open_ui", target: "workspace=\(workspaceID)", elapsedMS: elapsedMS, success: false,
                    detail: "route=\(route.rawValue)")
                showError(error)
            }
        }
    }

    private func runWorkspaceProcess(workspaceID: String, processName: String) {
        let startedAt = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Self.performWindowFocusSnapshot(.workspaceMissingConfiguredProcess(workspaceID: workspaceID, processKey: processName))
            let elapsedMS = windowShortcutElapsedMS(since: startedAt)
            switch result {
            case .success(let action):
                logPerfMetric(
                    "workspace_process_launch_ui", target: "workspace=\(workspaceID)", elapsedMS: elapsedMS, success: true,
                    detail: "route=ipc name=\(processName)")
                reloadData()
                hideAfterSuccessfulExternalWindowAction(action)
            case .failure(let error):
                logPerfMetric(
                    "workspace_process_launch_ui", target: "workspace=\(workspaceID)", elapsedMS: elapsedMS, success: false,
                    detail: "route=ipc name=\(processName)")
                showError(error)
            }
        }
    }

    private func stopWorkspaceProcess(workspaceID: String, processName: String) {
        let startedAt = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let process = try orchestrator.runningProcesses(workspaceID: workspaceID).first(where: { $0.templateName == processName })
                else { throw WorkspaceError.invalidArgument(message: "Configured process not found.") }
                try orchestrator.stopWorkspaceProcess(workspaceID: workspaceID, processID: process.id)
                logPerfMetric(
                    "workspace_process_stop_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                    success: true, detail: "route=ipc name=\(processName)")
                reloadData()
            } catch {
                logPerfMetric(
                    "workspace_process_stop_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                    success: false, detail: "route=ipc name=\(processName)")
                fputs("spaces: workspace process stop IPC failed for \(processName): \(error)\n", stderr)
                showError(error)
            }
        }
    }

    private func restartWorkspaceProcess(workspaceID: String, processName: String) {
        let startedAt = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let process = try orchestrator.runningProcesses(workspaceID: workspaceID).first(where: { $0.templateName == processName })
                else { throw WorkspaceError.invalidArgument(message: "Configured process not found.") }
                try orchestrator.restartWorkspaceProcess(workspaceID: workspaceID, processID: process.id)
                logPerfMetric(
                    "workspace_process_restart_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                    success: true, detail: "route=ipc name=\(processName)")
                reloadData()
            } catch {
                logPerfMetric(
                    "workspace_process_restart_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                    success: false, detail: "route=ipc name=\(processName)")
                fputs("spaces: workspace process restart IPC failed for \(processName): \(error)\n", stderr)
                showError(error)
            }
        }
    }

    private func launchWorkspaceAgent(workspaceID: String, launcherName: String) {
        let startedAt = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Self.performWindowFocusSnapshot(.workspaceAgentLauncher(workspaceID: workspaceID, name: launcherName))
            let elapsedMS = windowShortcutElapsedMS(since: startedAt)
            switch result {
            case .success(let action):
                logPerfMetric(
                    "workspace_agent_launch_ui", target: "workspace=\(workspaceID)", elapsedMS: elapsedMS, success: true,
                    detail: "route=ipc name=\(launcherName)")
                reloadData()
                hideAfterSuccessfulExternalWindowAction(action)
            case .failure(let error):
                logPerfMetric(
                    "workspace_agent_launch_ui", target: "workspace=\(workspaceID)", elapsedMS: elapsedMS, success: false,
                    detail: "route=ipc name=\(launcherName)")
                showError(error)
            }
        }
    }

    private func openWorkspaceFinder(workspaceID: String) {
        guard let (_, workspace) = findWorkspace(id: workspaceID) else { return }
        let url = URL(fileURLWithPath: workspace.dir, isDirectory: true)
        if NSWorkspace.shared.open(url) { hideAfterSuccessfulExternalWindowAction(.open(hidesApp: true)) }
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
            if self.handleAlertsShortcut(event: event) { return nil }
            if let openSettingsShortcutSpec, matches(event: event, spec: openSettingsShortcutSpec) {
                self.showSettings()
                return nil
            }
            if self.handleCommandPaletteShortcut(event: event) { return nil }
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
        guard activeAddWorkspaceFormTag != nil || activeAddProjectFormTag != nil else { return false }
        cancelProjectForm()
        return true
    }

    private func handleAlertsShortcut(event: NSEvent) -> Bool {
        guard let alertsShortcutSpec, matches(event: event, spec: alertsShortcutSpec) else { return false }
        showAlertsDetail()
        return true
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
                selectedWorkspaceID: selectedWorkspaceID, showingAlerts: showingAlerts, direction: direction)
        else { return false }
        switch target {
        case .alerts: showAlertsDetail()
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
        case .openCommandPalette: toggleCommandPaletteFromHotkey()
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
        if let workspaceID = try? orchestrator.activeWorkspaceID() { return workspaceID }
        return nil
    }

    nonisolated static func activationSelectionTarget(focusedWorkspaceID: String?) -> SidebarArrowSelectionTarget {
        if let focusedWorkspaceID { return .workspace(focusedWorkspaceID) }
        return .alerts
    }

    private func loadShortcutSpecs() {
        if let leaderRaw = try? orchestrator.guiLeaderHotkey(), let modifiers = try? HotkeySpec.parseModifierSet(leaderRaw) {
            shortcutLeaderModifiers = modifiers
        } else {
            shortcutLeaderModifiers = (try? HotkeySpec.parseModifierSet(SettingsKey.defaultGUILeaderHotkey)) ?? [.cmd, .alt]
        }
        toggleShortcutSpec = loadShortcutSpec(setting: .guiHotkey)
        commandPaletteShortcutSpec = loadShortcutSpec(setting: .guiCommandPaletteHotkey)
        alertsShortcutSpec = loadShortcutSpec(setting: .guiAlertsShortcut)
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

    private func shortcutRawValue(for setting: ShortcutSetting) throws -> String {
        switch setting {
        case .guiHotkey: return try orchestrator.guiHotkey()
        case .guiCommandPaletteHotkey: return try orchestrator.guiCommandPaletteHotkey()
        case .guiLeaderHotkey: return try orchestrator.guiLeaderHotkey()
        case .guiAlertsShortcut: return try orchestrator.guiAlertsShortcut()
        case .guiAddWorkspaceShortcut: return try orchestrator.guiAddWorkspaceShortcut()
        case .guiReloadShortcut: return try orchestrator.guiReloadShortcut()
        case .guiNextShortcut: return try orchestrator.guiNextShortcut()
        case .guiPreviousShortcut: return try orchestrator.guiPreviousShortcut()
        case .guiOpenEditorShortcut: return try orchestrator.guiOpenEditorShortcut()
        case .guiOpenTerminalShortcut: return try orchestrator.guiOpenTerminalShortcut()
        case .guiOpenFinderShortcut: return try orchestrator.guiOpenFinderShortcut()
        case .guiOpenSettingsShortcut: return try orchestrator.guiOpenSettingsShortcut()
        case .guiWindowShortcut: return try orchestrator.guiWindowShortcut()
        }
    }

    private func setShortcutSetting(setting: ShortcutSetting, value: String?) throws {
        switch setting {
        case .guiHotkey: try orchestrator.setGUIHotkey(value)
        case .guiCommandPaletteHotkey: try orchestrator.setGUICommandPaletteHotkey(value)
        case .guiLeaderHotkey: try orchestrator.setGUILeaderHotkey(value)
        case .guiAlertsShortcut: try orchestrator.setGUIAlertsShortcut(value)
        case .guiAddWorkspaceShortcut: try orchestrator.setGUIAddWorkspaceShortcut(value)
        case .guiReloadShortcut: try orchestrator.setGUIReloadShortcut(value)
        case .guiNextShortcut: try orchestrator.setGUINextShortcut(value)
        case .guiPreviousShortcut: try orchestrator.setGUIPreviousShortcut(value)
        case .guiOpenEditorShortcut: try orchestrator.setGUIOpenEditorShortcut(value)
        case .guiOpenTerminalShortcut: try orchestrator.setGUIOpenTerminalShortcut(value)
        case .guiOpenFinderShortcut: try orchestrator.setGUIOpenFinderShortcut(value)
        case .guiOpenSettingsShortcut: try orchestrator.setGUIOpenSettingsShortcut(value)
        case .guiWindowShortcut: try orchestrator.setGUIWindowShortcut(value)
        }
    }

    private func shortcutSpec(for setting: ShortcutSetting) -> HotkeySpec? {
        switch setting {
        case .guiHotkey: return toggleShortcutSpec
        case .guiCommandPaletteHotkey: return commandPaletteShortcutSpec
        case .guiLeaderHotkey: return nil
        case .guiAlertsShortcut: return alertsShortcutSpec
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
        let alertsFocusRequest = showingAlerts ? alertsFocusRequestMap[index] : nil
        let routeStartedAt = Date()
        let result = await Self.focusWindowShortcutSnapshot(
            index: index, selectedWorkspaceID: selectedWorkspaceID, alertsFocusRequest: alertsFocusRequest)
        switch result {
        case .success(.focused(let kind, let recentFocusIdentity, let hidesApp)):
            logWindowShortcutProfile("stage=route_done index=\(index) kind=\(kind) elapsed_ms=\(windowShortcutElapsedMS(since: routeStartedAt))")
            activeWindowShortcutProfile?.routeCompletedAt = Date()
            rememberRecentCommandPaletteFocusIdentity(recentFocusIdentity)
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

    private func logWindowShortcutProfile(_ message: String) {
        guard ProcessInfo.processInfo.environment["DEBUG"] == "1" else { return }
        fputs("spaces: window_shortcut \(message)\n", stderr)
    }

    private func captureHotkeyPerfContext() -> HotkeyPerfContext {
        HotkeyPerfContext(
            startedAt: Date(), appWasActive: NSApp.isActive, appWasHidden: NSApp.isHidden,
            mainWindowWasVisible: window?.isVisible == true && window?.isMiniaturized != true,
            paletteWasVisible: commandPalettePanel?.isVisible == true)
    }

    nonisolated static func commandPalettePresentationIsComplete(panelIsVisible: Bool, panelIsKey: Bool) -> Bool { panelIsVisible && panelIsKey }

    nonisolated static func shouldDismissCommandPaletteForToggle(panelIsVisible: Bool, panelIsFocused: Bool) -> Bool {
        panelIsVisible && panelIsFocused
    }

    nonisolated static func shouldUseRememberedBuiltInTerminalSessionForGlobalNavigation(
        appIsActive: Bool, mainWindowIsFocused: Bool, commandPaletteIsFocused: Bool
    ) -> Bool { appIsActive && !mainWindowIsFocused && !commandPaletteIsFocused }

    nonisolated static func shouldHideMainWindowForToggle(appIsHidden: Bool, mainWindowIsFocused: Bool) -> Bool {
        !appIsHidden && mainWindowIsFocused
    }

    nonisolated static func shouldRestoreTerminalFocusAfterMainHide(returnTerminalSessionID: String?, auxiliaryTerminalWindowsVisible: Bool) -> Bool {
        auxiliaryTerminalWindowsVisible && returnTerminalSessionID != nil
    }

    nonisolated static func effectiveMainWindowVisibilityForHotkeyState(rawMainWindowIsVisible: Bool, commandPaletteMainWindowVisibility: Bool?)
        -> Bool
    { commandPaletteMainWindowVisibility ?? rawMainWindowIsVisible }

    private func logHotkeyPerfMetric(_ metric: String, action: String, context: HotkeyPerfContext) {
        let target =
            "action=\(action) app_active_before=\(context.appWasActive ? 1 : 0) app_hidden_before=\(context.appWasHidden ? 1 : 0) main_visible_before=\(context.mainWindowWasVisible ? 1 : 0) palette_visible_before=\(context.paletteWasVisible ? 1 : 0)"
        logPerfMetric(metric, target: target, elapsedMS: windowShortcutElapsedMS(since: context.startedAt), success: true)
    }

    private func completePendingCommandPalettePresentationIfNeeded() {
        guard let pending = pendingCommandPalettePresentation, let panel = commandPalettePanel else { return }
        guard Self.commandPalettePresentationIsComplete(panelIsVisible: panel.isVisible, panelIsKey: panel.isKeyWindow) else { return }
        pendingCommandPalettePresentation = nil
        commandPaletteMainWindowVisibility = pending.mainWindowWasVisible
        logHotkeyDebug("present_palette end \(hotkeyWindowStateSummary())")
        if let perfContext = pending.perfContext { logHotkeyPerfMetric("toggle_palette", action: "show", context: perfContext) }
    }

    private func logPerfMetric(_ metric: String, target: String, elapsedMS: Int, success: Bool, detail: String = "") {
        TerminalPerformance.logMetric(metric, target: target, elapsedMS: elapsedMS, success: success, detail: detail)
    }

    private func windowShortcutElapsedMS(since start: Date) -> Int { max(Int(Date().timeIntervalSince(start) * 1000), 0) }

    private func windowShortcutIndex(for event: NSEvent) -> Int? {
        guard let windowShortcutSpec else { return nil }
        return numberedWindowShortcutIndex(for: event, spec: windowShortcutSpec)
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
        guard let windowShortcutSpec else { return "⌘\(index)" }
        return displayShortcut(windowShortcutSpec, keyText: String(index))
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
        guard let workspaceID = globalWindowNavigationWorkspaceID() else { return }
        let requestID = UUID().uuidString
        let startedAt = Date()
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
            if hidesApp { hideAfterSuccessfulExternalWindowAction(.focus(hidesApp: true)) } else { dismissCommandPaletteForBuiltInWindowNavigation() }
        } catch {
            logPerfMetric(
                "global_window_navigation", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false,
                detail: "direction=\(direction > 0 ? "next" : "previous") request_id=\(requestID)")
            showError(error)
        }
    }

    private func dismissCommandPaletteForBuiltInWindowNavigation() {
        if let panel = commandPalettePanel, panel.isVisible {
            panel.makeFirstResponder(nil)
            panel.orderOut(nil)
            commandPaletteContextWorkspaceID = nil
            commandPaletteMainWindowVisibility = nil
            commandPaletteReturnTerminalSessionID = nil
            commandPaletteReturnApplicationProcessID = nil
        }
    }

    private func hideAfterSuccessfulExternalWindowAction(_ action: ExternalWindowAction) {
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

    private func handleWindowFocusFailure(_ error: Error) async {
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

        showOperationProgressOverlay(message: progressTitle, detail: progressDetail)
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

    private func globalWindowNavigationWorkspaceID() -> String? {
        if let terminalSessionID = activeBuiltInTerminalSessionID(),
            let workspaceID = try? orchestrator.workspaceIDForTerminalSession(terminalSessionID)
        {
            return workspaceID
        }
        if let workspaceID = try? orchestrator.workspaceIDForFocusedWindow() { return workspaceID }
        if let workspaceID = try? orchestrator.activeWorkspaceID() { return workspaceID }
        return nil
    }

    private func activeBuiltInTerminalSessionID() -> String? {
        for window in [NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 }) {
            if let sessionID = (window.windowController as? TerminalSessionWindowController)?.terminalSessionID { return sessionID }
        }
        guard
            Self.shouldUseRememberedBuiltInTerminalSessionForGlobalNavigation(
                appIsActive: NSApp.isActive, mainWindowIsFocused: window?.isKeyWindow == true,
                commandPaletteIsFocused: commandPalettePanel?.isKeyWindow == true)
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

    private func commandPaletteDefaultWorkspaceID() -> String? {
        let focusedTerminalWorkspaceID: String?
        if let terminalSessionID = focusedTerminalSessionIDForToggle() {
            let lookupStartedAt = Date()
            focusedTerminalWorkspaceID = try? orchestrator.workspaceIDForTerminalSession(terminalSessionID)
            logPerfMetric(
                "toggle_palette_terminal_workspace_lookup", target: "session=\(terminalSessionID)",
                elapsedMS: windowShortcutElapsedMS(since: lookupStartedAt), success: focusedTerminalWorkspaceID != nil)
        } else {
            focusedTerminalWorkspaceID = nil
        }

        let focusedWindowWorkspaceID: String?
        if selectedWorkspaceID == nil, focusedTerminalWorkspaceID == nil {
            let lookupStartedAt = Date()
            focusedWindowWorkspaceID = try? orchestrator.workspaceIDForFocusedWindow()
            logPerfMetric(
                "toggle_palette_focused_window_workspace_lookup", target: "frontmost_window",
                elapsedMS: windowShortcutElapsedMS(since: lookupStartedAt), success: focusedWindowWorkspaceID != nil)
        } else {
            focusedWindowWorkspaceID = nil
        }

        return Self.preferredWorkspaceIDForCommandPalette(
            selectedWorkspaceID: selectedWorkspaceID, focusedTerminalSessionWorkspaceID: focusedTerminalWorkspaceID,
            focusedWindowWorkspaceID: focusedWindowWorkspaceID)
    }

    private func handleCommandPaletteShortcut(event: NSEvent) -> Bool {
        guard commandPalettePanel?.isVisible == true else { return false }
        if let windowIndex = windowShortcutIndex(for: event) {
            executeCommandPaletteShortcut(index: windowIndex)
            return true
        }
        if matchesCommandPaletteDismissShortcut(event: event) {
            dismissSelectedCommandPaletteAlertsItem()
            return true
        }
        return false
    }

    nonisolated static func commandPaletteDismissShortcutMatches(
        charactersIgnoringModifiers: String?, modifiers: Set<HotkeyModifier>, leaderModifiers: Set<HotkeyModifier>
    ) -> Bool {
        guard charactersIgnoringModifiers?.lowercased() == "x" else { return false }
        return modifiers == leaderModifiers
    }

    private func matchesCommandPaletteDismissShortcut(event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        return Self.commandPaletteDismissShortcutMatches(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers, modifiers: shortcutModifiers(from: flags),
            leaderModifiers: shortcutLeaderModifiers)
    }

    private func executeCommandPaletteShortcut(index: Int) {
        let row = index - 1
        guard commandPaletteFilteredItems.indices.contains(row) else {
            NSSound.beep()
            return
        }
        commandPaletteSelectedIndex = row
        commandPaletteTableView?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        commandPaletteTableView?.scrollRowToVisible(row)
        executeSelectedCommandPaletteItem()
    }

    private func dismissSelectedCommandPaletteAlertsItem() {
        guard commandPaletteFilteredItems.indices.contains(commandPaletteSelectedIndex) else {
            NSSound.beep()
            return
        }
        let item = commandPaletteFilteredItems[commandPaletteSelectedIndex]
        guard let attentionID = item.alertsAttentionID else {
            NSSound.beep()
            return
        }
        dismissAlertsAttentionItem(attentionID)
        commandPaletteItems.removeAll { $0.alertsAttentionID == attentionID }
        applyCommandPaletteFilter()
    }

    private func toggleWindowFromHotkey() {
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

    private func revealTargetedHotkeyWindow(_ window: NSWindow) {
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
                hasTrackedRuntimeIndicators: false, runningProcessCount: 0, exitedProcessCount: 0, waitingAgentWindowCount: 0,
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
            if !showingAlerts { showPlaceholder() }
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
        setupScriptSection: SetupScriptSection, stopScriptSection: StopScriptSection, portsSection: PortsSection, processesSection: ProcessesSection,
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
        if let focusedWindow = notification.object as? NSWindow {
            logHotkeyDebug("window_did_become_key class=\(type(of: focusedWindow)) title=\(focusedWindow.title) \(hotkeyWindowStateSummary())")
            if focusedWindow === commandPalettePanel { completePendingCommandPalettePresentationIfNeeded() }
        }
        guard !hasAppliedSplitViewWidth else { return }
        hasAppliedSplitViewWidth = true
        applySplitViewWidth()
    }

    public func windowDidResignKey(_ notification: Notification) {
        guard let resignedWindow = notification.object as? NSWindow else { return }
        logHotkeyDebug("window_did_resign_key class=\(type(of: resignedWindow)) title=\(resignedWindow.title) \(hotkeyWindowStateSummary())")
        if resignedWindow === commandPalettePanel, !isDismissingCommandPalette { dismissCommandPalette() }
    }

    @objc public func numberOfRows(in tableView: NSTableView) -> Int {
        guard tableView === commandPaletteTableView else { return 0 }
        return commandPaletteFilteredItems.count
    }

    @objc public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableView === commandPaletteTableView else { return nil }
        guard commandPaletteFilteredItems.indices.contains(row) else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("command-palette-cell")
        let cell =
            (tableView.makeView(withIdentifier: identifier, owner: self) as? CommandPaletteTableCellView)
            ?? {
                let cell = CommandPaletteTableCellView()
                cell.identifier = identifier
                cell.translatesAutoresizingMaskIntoConstraints = false
                return cell
            }()

        let item = commandPaletteFilteredItems[row]
        let shortcutText = row < 9 ? windowShortcutBadgeText(index: row + 1) : nil
        cell.update(item: item, isSelected: row == commandPaletteSelectedIndex, shortcutText: shortcutText) { [weak self] in
            self?.commandPaletteSelectedIndex = row
            self?.executeSelectedCommandPaletteItem()
        }
        return cell
    }

    @objc public func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView, tableView === commandPaletteTableView else { return }
        guard tableView.selectedRow >= 0 else { return }
        commandPaletteSelectedIndex = tableView.selectedRow
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<tableView.numberOfRows), columnIndexes: IndexSet(integer: 0))
    }

    private func saveCurrentProject() -> Bool {
        commitEditing()
        guard let selectedProjectID else { return true }
        let tag = selectedProjectID.hashValue
        guard let refs = ProjectFieldCache.shared.cache[tag] else { return true }
        do {
            try orchestrator.updateProjectConfig(projectID: refs.projectID) { config in
                config.setupScript = refs.setupScriptSection.currentValue.isEmpty ? nil : refs.setupScriptSection.currentValue
                config.stopScript = refs.stopScriptSection.currentValue.isEmpty ? nil : refs.stopScriptSection.currentValue
                config.ports = refs.portsSection.currentPorts
                config.processes = refs.processesSection.currentProcesses
                config.browserSessions = refs.browserSessionsSection.currentSessions
                config.agentLaunchers = refs.agentLaunchersSection.currentLaunchers
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

    nonisolated fileprivate static func buildCommandPaletteItems(
        orchestrator: WorkspaceOrchestrator, projects: [ProjectSummary], workspacesByProject: [String: [WorkspaceSummary]]
    ) throws -> [CommandPaletteItem] {
        let alertsGroups = try buildAlertsGroupsSnapshot(orchestrator: orchestrator, projects: projects, workspacesByProject: workspacesByProject)
        var items: [CommandPaletteItem] = buildCommandPaletteAlertsItems(alertsGroups: alertsGroups)

        for project in projects {
            for workspace in workspacesByProject[project.id] ?? [] {
                let windows = (try? orchestrator.windows(workspaceID: workspace.id)) ?? []
                let processes = (try? orchestrator.runningProcesses(workspaceID: workspace.id)) ?? []
                let agentWindows = (try? orchestrator.agentWindows(workspaceID: workspace.id)) ?? []
                let settings = try orchestrator.workspaceSettings(workspaceID: workspace.id)
                let browserSessions =
                    shouldShowConfiguredBrowserSessions(workspaceIsRunning: workspace.isRunning)
                    ? ((try? orchestrator.resolvedWorkspaceBrowserSessions(workspaceID: workspace.id)) ?? []) : []
                let processEntries = orderedWorkspaceRunProcessEntries(
                    configuredProcesses: settings?.processes ?? [], windows: windows, processes: processes, agentWindows: agentWindows)
                let processesByID = Dictionary(uniqueKeysWithValues: processes.map { ($0.id, $0) })
                let shortcutTargets = orderedWorkspaceRunShortcutTargets(
                    browserSessions: browserSessions, processEntries: processEntries, processesByID: processesByID,
                    configuredAgentLaunchers: settings?.agentLaunchers ?? [], agentWindows: agentWindows)
                let runtimeWindowTitleByAgentID = codingAgentWindowTitleByAgentID(agentWindows: agentWindows, trackedWindows: windows)
                let configuredAgentByName = Dictionary(uniqueKeysWithValues: (settings?.agentLaunchers ?? []).map { ($0.name, $0) })

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

    nonisolated private static func commandPaletteItemsSnapshot() async -> Result<[CommandPaletteItem], Error> {
        await Task.detached(priority: .userInitiated) {
            do {
                let db = try DatabaseLocator.defaultPath()
                let store = try SQLiteStore(path: db)
                let orchestrator = WorkspaceOrchestrator(store: store)
                let projects = try orchestrator.listProjects()
                var workspacesByProject: [String: [WorkspaceSummary]] = [:]
                for project in projects {
                    workspacesByProject[project.id] = try orchestrator.listWorkspaces(projectID: project.id, includeArchived: false)
                }
                return .success(
                    try buildCommandPaletteItems(orchestrator: orchestrator, projects: projects, workspacesByProject: workspacesByProject))
            } catch { return .failure(error) }
        }.value
    }

    private func toggleCommandPaletteFromHotkey() {
        let perfContext = captureHotkeyPerfContext()
        logHotkeyDebug("toggle_palette begin \(hotkeyWindowStateSummary())")
        guard setupManager == nil else {
            logHotkeyDebug("toggle_palette reroute_setup_manager")
            toggleWindowFromHotkey()
            return
        }
        if let panel = commandPalettePanel,
            Self.shouldDismissCommandPaletteForToggle(panelIsVisible: panel.isVisible, panelIsFocused: panel.isKeyWindow)
        {
            logHotkeyDebug("toggle_palette dismiss_visible_panel")
            dismissCommandPalette(perfContext: perfContext)
            return
        }
        if let panel = commandPalettePanel, panel.isVisible {
            logHotkeyDebug("toggle_palette refocus_visible_panel")
            revealTargetedHotkeyWindow(panel)
            if let commandPaletteSearchField { panel.makeFirstResponder(commandPaletteSearchField) }
            pendingCommandPalettePresentation = PendingCommandPalettePresentation(
                perfContext: perfContext, mainWindowWasVisible: rawMainWindowVisibility())
            completePendingCommandPalettePresentationIfNeeded()
            return
        }
        presentCommandPalette(perfContext: perfContext)
    }

    private func presentCommandPalette(perfContext: HotkeyPerfContext? = nil) {
        let panel = ensureCommandPalettePanel()
        let mainWindowWasVisible = rawMainWindowVisibility()
        logHotkeyDebug("present_palette begin \(hotkeyWindowStateSummary())")
        let focusedTerminalSessionID = focusedTerminalSessionIDForToggle()
        let returnApplicationProcessID = Self.returnApplicationProcessIDForAppToggle(
            frontmostApplicationProcessID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            currentProcessID: ProcessInfo.processInfo.processIdentifier)
        commandPaletteReturnTerminalSessionID = focusedTerminalSessionID
        commandPaletteReturnApplicationProcessID = focusedTerminalSessionID == nil ? returnApplicationProcessID : nil
        let contextLookupStartedAt = Date()
        commandPaletteContextWorkspaceID = commandPaletteDefaultWorkspaceID()
        logPerfMetric(
            "toggle_palette_context_workspace", target: "workspace=\(commandPaletteContextWorkspaceID ?? "nil")",
            elapsedMS: windowShortcutElapsedMS(since: contextLookupStartedAt), success: true)
        panel.center()
        let revealStartedAt = Date()
        revealTargetedHotkeyWindow(panel)
        logPerfMetric("toggle_palette_reveal_target", target: "palette", elapsedMS: windowShortcutElapsedMS(since: revealStartedAt), success: true)
        commandPaletteSearchField?.stringValue = ""
        commandPaletteSelectedIndex = 0
        if let commandPaletteSearchField { panel.makeFirstResponder(commandPaletteSearchField) }
        let filterStartedAt = Date()
        applyCommandPaletteFilter()
        logPerfMetric(
            "toggle_palette_apply_filter", target: "query=<empty>", elapsedMS: windowShortcutElapsedMS(since: filterStartedAt), success: true)
        if commandPaletteItems.isEmpty {
            reloadCommandPaletteItems()
        } else if commandPaletteNeedsReload, commandPaletteLoadTask == nil {
            reloadCommandPaletteItems()
        }
        pendingCommandPalettePresentation = PendingCommandPalettePresentation(perfContext: perfContext, mainWindowWasVisible: mainWindowWasVisible)
        completePendingCommandPalettePresentationIfNeeded()
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.completePendingCommandPalettePresentationIfNeeded()
        }
    }

    private func dismissCommandPalette(perfContext: HotkeyPerfContext? = nil) {
        guard let panel = commandPalettePanel else { return }
        guard !isDismissingCommandPalette else { return }
        isDismissingCommandPalette = true
        logHotkeyDebug("dismiss_palette begin visible=\(panel.isVisible ? 1 : 0) key=\(panel.isKeyWindow ? 1 : 0) \(hotkeyWindowStateSummary())")
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        commandPaletteContextWorkspaceID = nil
        if Self.shouldRestoreTerminalFocusAfterPaletteHide(returnTerminalSessionID: commandPaletteReturnTerminalSessionID),
            let returnTerminalSessionID = commandPaletteReturnTerminalSessionID
        {
            focusTerminalSessionWindow(sessionID: returnTerminalSessionID)
        } else if Self.shouldRestoreReturnApplicationAfterPaletteHide(
            returnTerminalSessionID: commandPaletteReturnTerminalSessionID, returnApplicationProcessID: commandPaletteReturnApplicationProcessID),
            let returnApplicationProcessID = commandPaletteReturnApplicationProcessID
        {
            activateReturnApplication(processIdentifier: returnApplicationProcessID)
        } else if rawMainWindowVisibility(), let window {
            revealTargetedHotkeyWindow(window)
        }
        isDismissingCommandPalette = false
        logHotkeyDebug("dismiss_palette end \(hotkeyWindowStateSummary())")
        commandPaletteMainWindowVisibility = nil
        commandPaletteReturnTerminalSessionID = nil
        commandPaletteReturnApplicationProcessID = nil
        if let perfContext { logHotkeyPerfMetric("toggle_palette", action: "hide", context: perfContext) }
    }

    private func ensureCommandPalettePanel() -> NSPanel {
        if let commandPalettePanel { return commandPalettePanel }

        let panel = CommandPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 470), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.setAccessibilityIdentifier("spaces-command-palette")

        if let closeButton = panel.standardWindowButton(.closeButton) { closeButton.isHidden = true }
        if let miniButton = panel.standardWindowButton(.miniaturizeButton) { miniButton.isHidden = true }
        if let zoomButton = panel.standardWindowButton(.zoomButton) { zoomButton.isHidden = true }

        let root = ColoredBackgroundView()
        root.fillColor = Theme.paletteSurface
        root.cornerRadius = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = Theme.border.cgColor

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSStackView()
        headerRow.orientation = .vertical
        headerRow.alignment = .leading
        headerRow.spacing = 2
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.setContentHuggingPriority(.required, for: .vertical)
        headerRow.setContentCompressionResistancePriority(.required, for: .vertical)

        let brandRow = NSStackView()
        brandRow.orientation = .horizontal
        brandRow.alignment = .centerY
        brandRow.spacing = 7
        brandRow.translatesAutoresizingMaskIntoConstraints = false

        let titleIconView = NSImageView()
        if let appIcon = NSApp.applicationIconImage.copy() as? NSImage {
            appIcon.size = NSSize(width: 18, height: 18)
            titleIconView.image = appIcon
        } else {
            titleIconView.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "Spaces")
            titleIconView.contentTintColor = Theme.accentStrong
        }
        titleIconView.translatesAutoresizingMaskIntoConstraints = false
        titleIconView.setContentHuggingPriority(.required, for: .horizontal)
        titleIconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            titleIconView.widthAnchor.constraint(equalToConstant: 18), titleIconView.heightAnchor.constraint(equalToConstant: 18),
        ])

        let titleLabel = NSTextField(labelWithString: "Spaces")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.textColor = Theme.text
        brandRow.addArrangedSubview(titleIconView)
        brandRow.addArrangedSubview(titleLabel)
        headerRow.addArrangedSubview(brandRow)

        let searchField = CommandPaletteSearchField()
        searchField.placeholderString = "fuzzy search workspaces, targets, and details"
        searchField.font = .systemFont(ofSize: 13)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchField.focusRingType = .default
        searchField.setAccessibilityIdentifier("command-palette-search")
        searchField.controlSize = .large
        searchField.heightAnchor.constraint(equalToConstant: 30).isActive = true
        searchField.setContentHuggingPriority(.required, for: .vertical)
        searchField.setContentCompressionResistancePriority(.required, for: .vertical)

        let countBadge = ColoredBackgroundView()
        countBadge.fillColor = Theme.chipBg
        countBadge.cornerRadius = 4
        countBadge.translatesAutoresizingMaskIntoConstraints = false

        let countLabel = NSTextField(labelWithString: "")
        countLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        countLabel.textColor = Theme.muted
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countBadge.addSubview(countLabel)
        NSLayoutConstraint.activate([
            countLabel.leadingAnchor.constraint(equalTo: countBadge.leadingAnchor, constant: 5),
            countLabel.trailingAnchor.constraint(equalTo: countBadge.trailingAnchor, constant: -5),
            countLabel.topAnchor.constraint(equalTo: countBadge.topAnchor, constant: 2),
            countLabel.bottomAnchor.constraint(equalTo: countBadge.bottomAnchor, constant: -2),
        ])
        searchField.addSubview(countBadge)
        NSLayoutConstraint.activate([
            countBadge.trailingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: -8),
            countBadge.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
        ])

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.setContentHuggingPriority(.required, for: .vertical)
        divider.setContentCompressionResistancePriority(.required, for: .vertical)

        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        footerSeparator.setContentHuggingPriority(.required, for: .vertical)
        footerSeparator.setContentCompressionResistancePriority(.required, for: .vertical)

        let footerRow = commandPaletteFooterRow()
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footerRow.setContentHuggingPriority(.required, for: .vertical)
        footerRow.setContentCompressionResistancePriority(.required, for: .vertical)

        let tableView = NSTableView()
        let tableColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command-palette-column"))
        tableColumn.resizingMask = .autoresizingMask
        tableView.addTableColumn(tableColumn)
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.focusRingType = .none
        tableView.rowHeight = 42
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.translatesAutoresizingMaskIntoConstraints = false

        let emptyLabel = NSTextField(labelWithString: "No matching targets")
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = Theme.muted
        emptyLabel.isHidden = true
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.setContentHuggingPriority(.required, for: .vertical)
        emptyLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        let loadingIndicator = NSProgressIndicator()
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .regular
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.isDisplayedWhenStopped = false
        loadingIndicator.setContentHuggingPriority(.required, for: .vertical)
        loadingIndicator.setContentCompressionResistancePriority(.required, for: .vertical)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView

        content.addSubview(headerRow)
        content.addSubview(searchField)
        content.addSubview(divider)
        content.addSubview(scrollView)
        content.addSubview(emptyLabel)
        content.addSubview(loadingIndicator)
        content.addSubview(footerSeparator)
        content.addSubview(footerRow)

        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor), content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            headerRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            headerRow.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -14),
            headerRow.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),

            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            searchField.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 10),

            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),

            footerRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            footerRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            footerRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            footerSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            footerSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            footerSeparator.bottomAnchor.constraint(equalTo: footerRow.topAnchor, constant: -6),

            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: footerSeparator.topAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            tableView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        panel.contentView = container
        commandPalettePanel = panel
        commandPaletteSearchField = searchField
        commandPaletteTableView = tableView
        commandPaletteLoadingIndicator = loadingIndicator
        commandPaletteEmptyLabel = emptyLabel
        commandPaletteSummaryLabel = countLabel
        logHotkeyDebug("ensure_palette_panel created")
        return panel
    }

    private func reloadCommandPaletteItems() {
        commandPaletteLoadTask?.cancel()
        setCommandPaletteLoading(true)
        logHotkeyDebug("reload_palette_items begin")
        commandPaletteLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Self.commandPaletteItemsSnapshot()
            guard !Task.isCancelled else { return }
            self.commandPaletteLoadTask = nil
            self.setCommandPaletteLoading(false)
            switch result {
            case .success(let items):
                self.logHotkeyDebug("reload_palette_items success count=\(items.count)")
                self.commandPaletteNeedsReload = false
                self.commandPaletteItems = self.filteredCommandPaletteItems(items)
                self.applyCommandPaletteFilter()
            case .failure(let error):
                self.logHotkeyDebug("reload_palette_items failure error=\(error)")
                if !self.handleDeferredSetupRequirementIfNeeded(error) {
                    self.dismissCommandPalette()
                    self.showError(error)
                }
            }
        }
    }

    private func setCommandPaletteLoading(_ loading: Bool) {
        logHotkeyDebug("set_palette_loading loading=\(loading ? 1 : 0)")
        commandPaletteLoadingIndicator?.isHidden = !loading
        if loading { commandPaletteLoadingIndicator?.startAnimation(nil) } else { commandPaletteLoadingIndicator?.stopAnimation(nil) }
        commandPaletteEmptyLabel?.isHidden = loading
        commandPaletteTableView?.isHidden = loading && commandPaletteItems.isEmpty
    }

    private func applyCommandPaletteFilter() {
        let query = commandPaletteSearchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        commandPaletteFilteredItems = Self.visibleCommandPaletteItems(
            allItems: commandPaletteItems, query: query, currentWorkspaceID: commandPaletteContextWorkspaceID,
            recentFocusIdentities: recentCommandPaletteFocusIdentities)
        commandPaletteSelectedIndex = commandPaletteFilteredItems.isEmpty ? 0 : 0
        logHotkeyDebug(
            "apply_palette_filter query=\(query.isEmpty ? "<empty>" : query) all=\(commandPaletteItems.count) filtered=\(commandPaletteFilteredItems.count) context_workspace=\(commandPaletteContextWorkspaceID ?? "nil")"
        )
        rebuildCommandPaletteRows()
    }

    private func rebuildCommandPaletteRows() {
        guard let tableView = commandPaletteTableView else { return }
        tableView.isHidden = commandPaletteFilteredItems.isEmpty
        let showEmptyState =
            commandPaletteFilteredItems.isEmpty
            && !(commandPaletteSearchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        commandPaletteEmptyLabel?.isHidden = !showEmptyState
        logHotkeyDebug("rebuild_palette_rows count=\(commandPaletteFilteredItems.count) selected=\(commandPaletteSelectedIndex)")
        tableView.reloadData()
        if commandPaletteFilteredItems.indices.contains(commandPaletteSelectedIndex) {
            tableView.selectRowIndexes(IndexSet(integer: commandPaletteSelectedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(commandPaletteSelectedIndex)
        } else {
            tableView.deselectAll(nil)
        }
        logHotkeyDebug("rebuild_palette_rows_done rows=\(tableView.numberOfRows) selected_row=\(tableView.selectedRow)")
        let count = commandPaletteFilteredItems.count
        commandPaletteSummaryLabel?.stringValue = count > 0 ? "\(count)" : ""
        commandPaletteSummaryLabel?.superview?.isHidden = count == 0
    }

    private func moveCommandPaletteSelection(delta: Int) {
        guard !commandPaletteFilteredItems.isEmpty else { return }
        let nextIndex = min(max(commandPaletteSelectedIndex + delta, 0), commandPaletteFilteredItems.count - 1)
        guard nextIndex != commandPaletteSelectedIndex else { return }
        commandPaletteSelectedIndex = nextIndex
        commandPaletteTableView?.selectRowIndexes(IndexSet(integer: nextIndex), byExtendingSelection: false)
        commandPaletteTableView?.scrollRowToVisible(nextIndex)
    }

    private func executeSelectedCommandPaletteItem() {
        guard commandPaletteFilteredItems.indices.contains(commandPaletteSelectedIndex) else {
            NSSound.beep()
            return
        }
        let item = commandPaletteFilteredItems[commandPaletteSelectedIndex]
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await Self.performWindowFocusSnapshot(item.focusRequest)
            switch result {
            case .success(let action):
                if case .focus(_) = action { self.rememberRecentCommandPaletteFocusIdentity(item.recentFocusIdentity) }
                dismissCommandPalette()
                reloadData()
                hideAfterSuccessfulExternalWindowAction(action)
            case .failure(let error): await handleWindowFocusFailure(error)
            }
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
