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

/// Field-reference bundles for a single-instance form. `formTag` is the generation stamped on the
/// form's controls (`NSControl.tag`) when it is built, letting a control's action confirm it still
/// belongs to the live form. See `AppKitController.liveFormRefs(_:forSenderTag:)`.
protocol FormGenerationTagged { var formTag: Int { get } }

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

    enum AlertsIconTint: Sendable, Equatable {
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

    var window: NSWindow!
    private var splitView: NSSplitView?
    let outlineView = SidebarOutlineView()
    lazy var sidebar = SidebarController(host: self)
    let detailContainer = NSView()
    /// The right panel's footer strip: workspace details for the selected workspace.
    private weak var workspaceDetailFooterRow: NSStackView?
    private weak var workspaceFooterPaneLabel: NSTextField?
    private var workspaceFooterWorkspaceID: String?
    private var workspaceNotesPopover: NSPopover?
    private weak var workspaceNotesEditorTextView: NSTextView?
    private var workspaceNotesEditorWorkspaceID: String?
    // workspaceShortcutFooterLabels removed — footer rebuilt on each refresh
    var projects: [ProjectSummary] = []
    var workspacesByProject: [String: [WorkspaceSummary]] = [:] {
        didSet {
            sidebar.invalidateVisibleWorkspacesCache()
            // Flat id -> (projectID, workspace) index, rebuilt alongside workspacesByProject so it can
            // never go stale. Lets findWorkspace(id:) resolve in O(1) instead of scanning every
            // project's workspace list, which matters since it's called from ~26 sites including
            // selection/reload hot paths.
            workspaceIndex = workspacesByProject.reduce(into: [:]) { index, entry in
                for workspace in entry.value { index[workspace.id] = (projectID: entry.key, workspace: workspace) }
            }
            // `SidebarController.rebuildFlatSidebarData()` — the single point every overview-install
            // path (the local snapshot, a remote pull/subscription, a mutation response) funnels
            // through — assigns this property on every call, so it is the nearest reachable proxy for
            // that funnel from this type. See `resolveAwaitingWorkspaceDeletions`.
            resolveAwaitingWorkspaceDeletions()
        }
    }
    private(set) var workspaceIndex: [String: (projectID: String, workspace: WorkspaceSummary)] = [:]
    var workspaceRuntimeStatusByID: [String: WorkspaceRuntimeStatus] = [:]
    // The macOS app always loads its own local daemon first; these hold that local
    // device and act as the default target when no row is selected. Per-row device
    // context is resolved via deviceID(for…) helpers and the device sections.
    var localDeviceID = SpacesPairedDeviceRecord.localDeviceID
    var localDeviceName = "This Mac"
    var localPairedDevice: SpacesPairedDeviceRecord?
    var deviceSections: [DeviceSection] = []
    /// `"deviceID|targetVersion"` keys for silent daemon-handoff requests already fired this app run
    /// (see `maybeRequestSilentDaemonHandoff`), so a status refresh never re-requests a handoff that is
    /// already staged or that failed/was refused — a failed handoff surfaces via the still-pending
    /// caption and the daemon log rather than a retry loop.
    private var silentDaemonHandoffRequestedKeys: Set<String> = []
    /// Devices whose compatibility-block "Update over SSH" installer run is in flight, so the block
    /// renders a spinner instead of re-offering the button. Entries are dropped by
    /// `updateRemoteDaemonOverSSH` on failure and by `reconcileCompatibilityBlock` once a fresh verdict
    /// for the device stops calling for `.installUpdateOnDevice`, so a finished run can never pin a
    /// spinner permanently.
    private var daemonSSHUpdateInProgressDeviceIDs: Set<String> = []
    var alertsGroups: [AlertsGroup] = []
    /// The single content the detail pane is showing. Mutually exclusive by construction, so presenting
    /// one content replaces the previous one. Written only through `presentDetailPane`.
    var detailPane: DetailPane = .none
    /// Read-only facets of `detailPane` that the app reads throughout. `showingSettings` is a separate
    /// stored flag because the Settings dialog floats over, and coexists with, whatever pane is shown.
    var visibleDetailWorkspaceID: String? { detailPane.workspaceID }
    var visibleCompatibilityBlockDeviceID: String? { detailPane.compatibilityBlockDeviceID }
    var showingAlerts: Bool { detailPane.isAlerts }
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
    private var mouseFocusMonitor: Any?
    private var addWorkspaceShortcutSpec: HotkeySpec?
    private var reloadShortcutSpec: HotkeySpec?
    private var openEditorShortcutSpec: HotkeySpec?
    private var openTerminalShortcutSpec: HotkeySpec?
    private var newTabShortcutSpec: HotkeySpec?
    private var openFinderShortcutSpec: HotkeySpec?
    private var openSettingsShortcutSpec: HotkeySpec?
    private var nextShortcutSpec: HotkeySpec?
    private var previousShortcutSpec: HotkeySpec?
    private var sidebarNextShortcutSpec: HotkeySpec?
    private var sidebarPreviousShortcutSpec: HotkeySpec?
    /// The main window's titlebar accessory hosting the visible workspace panel's
    /// tab strip (hidden while the detail area shows anything but a workspace panel).
    let panelTabStripAccessory = NSTitlebarAccessoryViewController()
    let panelTabStripView = PanelTabStripAccessoryView()
    private var mainWindowIsFullScreen = false
    private var windowShortcutSpec: HotkeySpec?
    var shortcutButtonsBySetting: [String: NSButton] = [:]
    var activeShortcutCaptureSetting: ShortcutSetting?
    private var deferredHotkeySelectionRefreshTask: Task<Void, Never>?
    private var activeSpaceSummonCleanupTask: Task<Void, Never>?
    private var workspaceSetupDetailRefreshTimer: Timer?
    private var workspaceSetupDetailRefreshWorkspaceID: String?
    private weak var workspaceSetupLogTextView: NSTextView?
    /// The app-wide terminal text size every open pane renders at, loaded from the profile at launch
    /// and moved by the focused pane's zoom keys (see `AppKitController+TerminalTextSize`).
    var terminalTextSize: TerminalTextSize = .default
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
    // Each of these dialogs is single-instance (one optional window above), so at most one live set of
    // field references exists at a time. Its controls are stamped with the form's generation tag; see
    // `liveFormRefs(_:forSenderTag:)` for how a stale control's action is rejected.
    private var projectSettingsFieldRefs: ProjectFieldRefs?
    private var addProjectFieldRefs: AddProjectFieldRefs?
    private var addWorkspaceFieldRefs: AddWorkspaceFieldRefs?
    var workspaceSettingsWindow: NSWindow?
    var workspaceSettingsWorkspaceID: String?
    private var pathCompletionFieldEditor: PathCompletionTextView?
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
        (TerminalOverviewSignal.name, #selector(handleTerminalOverviewSignalIPC(_:))),
        (IPCNotification.deliverUserNotification, #selector(handleDeliverUserNotificationIPC(_:))),
    ]
    private var appDidBecomeActiveObserver: NSObjectProtocol?
    private var appDidResignActiveObserver: NSObjectProtocol?
    private var workspaceDidTerminateApplicationObserver: NSObjectProtocol?
    private var terminalAttachmentStateDidChangeObserver: NSObjectProtocol?
    private var textInputDidEndEditingObserver: NSObjectProtocol?
    private var appEffectiveAppearanceObservation: NSKeyValueObservation?
    private var didStartBackgroundServices = false
    private let browserSSHForwardManager = BrowserSSHForwardManager()
    private var remoteBrowserForwardRevisions: [String: Int] = [:]
    // The open workspace settings dialog's Services section, kept so an SSH forward start/stop can
    // refresh the rows' port texts in place instead of rebuilding the section. The section object is
    // owned by its view (RowSectionCard.retain), so the weak reference clears itself when the dialog
    // closes. Set from the workspace settings dialog, which lives in a separate file, so these are
    // module-internal rather than private.
    weak var visibleWorkspacePortsSection: PortsSection?
    var visiblePortsWorkspaceID: String?
    var setupFlowController: SetupFlowController?
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
    private lazy var iso8601Formatter: ISO8601DateFormatter = ISO8601DateFormatter()

    private var deferredExternalWindowHideTask: Task<Void, Never>?
    private var keepsTerminalSessionsRunningDuringTermination = false
    private var appToggleReturnApplicationProcessID: pid_t?
    private var pendingNewTerminalSessionWorkspaceIDs: Set<String> = []
    /// Workspaces whose delete mutation is in flight. Deleting a workspace takes seconds on the owning
    /// daemon — it stops the workspace, then removes the git worktree — and every overview that lands in
    /// that window still lists the workspace, so removing the row up front would let the next background
    /// refresh put it back for a beat before it finally disappears. The row stays and renders marked as
    /// deleting instead (see `sidebarWorkspaceRowState`), whatever rebuilds happen meanwhile.
    /// In-memory and per-run, like `pendingNewTerminalSessionWorkspaceIDs`: a relaunch reloads from the
    /// daemons, which are authoritative about whether the delete landed.
    ///
    /// Deletes issued from this app only. What the row renders is `isWorkspaceMarkedDeleting`, which
    /// unions this with the teardowns the owning daemon reports; this set stays exactly the deletes this
    /// app has to see through, since it is what the reconciliation paths key their outcome on.
    private(set) var workspaceIDsPendingDeletion: Set<String> = []

    /// What `deleteWorkspace` held back when `WorkspaceDeletionReconciler` returned `.unknown` — every
    /// reconciliation refetch failed, so no overview ever proved the delete's fate either way. The
    /// workspace stays in `workspaceIDsPendingDeletion` (its row stays inert) and this is what
    /// `resolveAwaitingWorkspaceDeletions` needs once a real overview for `deviceID` finally arrives:
    /// which device to check, the error to surface if the workspace is still there, whether to show the
    /// branch-outcome notice if it is gone, and the browser windows/panes a confirmed-gone resolution
    /// still has to close (the same cleanup an immediate `.gone` verdict performs).
    private struct AwaitingWorkspaceDeletionResolution {
        let deviceID: String
        let error: Error
        let branchDeletionRequested: Bool
        let browserSessionTargetURLs: [String]
        /// `deviceID`'s `DeviceSection.overviewInstallGeneration` at the moment reconciliation gave up.
        /// Resolution waits for a fresh install for this exact device — one whose generation exceeds
        /// this snapshot — rather than settling on any `workspacesByProject` rebuild, which fires for
        /// every device's refresh and would otherwise reread this device's own untouched cached overview
        /// as if it were new evidence.
        let overviewInstallGenerationAtDefer: Int
    }

    /// Workspaces whose delete reconciliation exhausted its attempt budget without a single overview
    /// resolving (`WorkspaceDeletionReconciler.Outcome.unknown`). In-memory and per-run, like
    /// `workspaceIDsPendingDeletion`: a relaunch always refetches reality from the daemon instead of
    /// trusting anything held here.
    private var workspaceIDsAwaitingDeletionResolution: [String: AwaitingWorkspaceDeletionResolution] = [:]

    @discardableResult func beginNewTerminalSessionCreation(workspaceID: String) -> Bool {
        pendingNewTerminalSessionWorkspaceIDs.insert(workspaceID).inserted
    }

    func finishNewTerminalSessionCreation(workspaceID: String) { pendingNewTerminalSessionWorkspaceIDs.remove(workspaceID) }

    private struct WindowShortcutProfile {
        let index: Int
        let startedAt: Date
        var routeCompletedAt: Date?
    }

    private struct BrowserCycleState: Sendable {
        let openBrowserSessions: [BrowserSession]
        let frontmostURL: String?
        let clientDBLookupMS: Int
        let chromeAppleScriptMS: Int
        let trackedWindowCount: Int
        let trackedTabCount: Int
    }

    private struct BrowserFocusResult: Sendable {
        let focused: Bool
        let path: String
        let clientDBLookupMS: Int
        let clientDBWriteMS: Int
        let chromeAppleScriptMS: Int
    }

    private struct RoutedBrowserFocusTarget: Sendable {
        let targetURL: URL
        let siblingTargetURLs: [String]
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
        case workspaceAgentLauncher(workspaceID: String, name: String)
        case agentWindow(AgentWindowRecord)
        case terminalSession(workspaceID: String, sessionID: String)

        var workspaceID: String {
            switch self {
            case .workspaceBrowserSession(let workspaceID, _), .workspaceWindow(let workspaceID, _), .workspaceProcess(let workspaceID, _),
                .workspaceMissingConfiguredProcess(let workspaceID, _), .workspaceAgentLauncher(let workspaceID, _),
                .terminalSession(let workspaceID, _):
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
        setupAppEffectiveAppearanceObserver()
        WorkspaceOrchestrator.setProcessWideBuiltInTerminalSessionTerminator(Self.terminateBuiltInTerminalSession)
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
                let cleanupResult = performStopAllQuitCleanup(liveSessions: liveSessions)
                guard cleanupResult.succeeded else { return handleStopAllQuitCleanupFailure(cleanupResult) }
                return .terminateNow
            case .cancel: return .terminateCancel
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        deferredHotkeySelectionRefreshTask?.cancel()
        browserSSHForwardManager.stopAll()
        sidebar.cancelSidebarReloadTask()
        teardownGlobalHotkey()
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
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
        if let terminalAttachmentStateDidChangeObserver {
            NotificationCenter.default.removeObserver(terminalAttachmentStateDidChangeObserver)
            self.terminalAttachmentStateDidChangeObserver = nil
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

    /// Reloads the sidebar when a terminal session's overview-affecting state changes (a bell, an exit,
    /// a title or runtime-state change). Terminal runtime state lives outside the database and so raises
    /// no `databaseDidChange`; this signal is its equivalent, and it takes the same reload path so the
    /// mid-edit deferral and reload coalescing are identical. The app and the daemon hosting the session
    /// are separate processes, so the signal arrives here through its distributed half.
    @objc private nonisolated func handleTerminalOverviewSignalIPC(_ notification: Notification) {
        let object = notification.object as? String
        Task { @MainActor [weak self, object] in
            guard let self,
                Self.shouldReloadSidebarForTerminalOverviewSignal(
                    didStartBackgroundServices: self.didStartBackgroundServices, notificationObject: object, profileObject: self.ipcNotificationObject
                )
            else { return }
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
        var targetResolutionMS = 0
        var routeMS = 0
        func logResult(_ success: Bool, reason: String = "") {
            let reasonDetail = reason.isEmpty ? "" : " reason=\(reason)"
            logPerfMetric(
                "named_window_focus", target: name, elapsedMS: windowShortcutElapsedMS(since: startedAt), success: success,
                detail: "target_resolution_ms=\(targetResolutionMS) route_ms=\(routeMS)\(reasonDetail)")
        }
        let resolutionStartedAt = Date()
        guard let context = focusableWindowContext(workspaceID: workspaceID),
            let target = context.targets.first(where: {
                Self.focusableWindowName(for: $0, detail: context.detail, browserSessions: context.browserSessions).map {
                    Self.normalizedRunRowName($0) == Self.normalizedRunRowName(name)
                } ?? false
            })
        else {
            targetResolutionMS = windowShortcutElapsedMS(since: resolutionStartedAt)
            logResult(false, reason: "no_match")
            return
        }
        targetResolutionMS = windowShortcutElapsedMS(since: resolutionStartedAt)
        let resolution = Self.windowShortcutTargetResolution(target, workspaceID: workspaceID, detail: context.detail, overview: context.overview)
        let routeStartedAt = Date()
        guard let action = await executeWindowFocusResolution(resolution, preferredTarget: target, preferredDetail: context.detail) else {
            routeMS = windowShortcutElapsedMS(since: routeStartedAt)
            logResult(false, reason: "focus_failed")
            return
        }
        routeMS = windowShortcutElapsedMS(since: routeStartedAt)
        logResult(true)
        hideAfterSuccessfulExternalWindowAction(action)
    }

    /// Focuses a workspace's running process window by template name. Threads `requestID`
    /// to the terminal focus so the `terminal_window_focus_ipc` line carries it, which the
    /// real-system E2E correlates; also emits `process_focus` for the non-correlated path.
    private func focusWorkspaceProcess(workspaceID: String, processName: String, requestID: String?) async {
        let startedAt = Date()
        var targetResolutionMS = 0
        var routeMS = 0
        func logResult(_ success: Bool, reason: String = "") {
            let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
            let reasonDetail = reason.isEmpty ? "" : " reason=\(reason)"
            logPerfMetric(
                "process_focus", target: processName, elapsedMS: windowShortcutElapsedMS(since: startedAt), success: success,
                detail: "target_resolution_ms=\(targetResolutionMS) route_ms=\(routeMS)\(requestDetail)\(reasonDetail)")
        }
        let resolutionStartedAt = Date()
        guard let context = focusableWindowContext(workspaceID: workspaceID),
            let target = context.targets.first(where: { target in
                guard target.kind == .process, let id = target.processID,
                    let rowName = context.detail.processRows.first(where: { ($0.processID ?? $0.id) == id })?.name
                else { return false }
                return Self.normalizedRunRowName(rowName) == Self.normalizedRunRowName(processName)
            })
        else {
            targetResolutionMS = windowShortcutElapsedMS(since: resolutionStartedAt)
            logResult(false, reason: "no_match")
            return
        }
        targetResolutionMS = windowShortcutElapsedMS(since: resolutionStartedAt)
        let resolution = Self.windowShortcutTargetResolution(target, workspaceID: workspaceID, detail: context.detail, overview: context.overview)
        let routeStartedAt = Date()
        guard
            let action = await executeWindowFocusResolution(
                resolution, requestID: requestID, preferredTarget: target, preferredDetail: context.detail)
        else {
            routeMS = windowShortcutElapsedMS(since: routeStartedAt)
            logResult(false, reason: "focus_failed")
            return
        }
        routeMS = windowShortcutElapsedMS(since: routeStartedAt)
        logResult(true)
        hideAfterSuccessfulExternalWindowAction(action)
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
        let browserCycleState = await trackedBrowserCycleState(workspaceID: workspaceID, detail: detail)
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
        let configuredBrowserTargetURLs = Self.browserSessionTargetURLs(resolvedSessions: detail.config.resolvedBrowserSessions)
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

        var focusedAction: ExternalWindowAction?
        var resolvedIndex = startIndex
        for attempt in 0..<orderedTargets.count {
            let candidateIndex = (startIndex + (attempt * delta) + (orderedTargets.count * 4)) % orderedTargets.count
            let resolution = Self.windowShortcutTargetResolution(
                orderedTargets[candidateIndex], workspaceID: workspaceID, detail: detail, overview: overview)
            if let action = await executeWindowFocusResolution(
                resolution, requestID: requestID, preferredTarget: orderedTargets[candidateIndex], preferredDetail: detail,
                preserveWindowCycleSession: true)
            {
                focusedAction = action
                resolvedIndex = candidateIndex
                break
            }
        }
        guard let action = focusedAction else {
            logCycleMetric(target: Self.cycleDebugName(for: orderedTargets[startIndex], detail: detail), success: false, detail: resolutionDetail)
            return
        }

        windowNavigationCursorByWorkspace[workspaceID] = orderedCursors[resolvedIndex]
        windowNavigationCycleSessionByWorkspace[workspaceID] = WorkspaceWindowCycle.CycleSession(
            orderedCursors: orderedCursors, currentIndex: resolvedIndex, lastUsedAt: Date())
        logCycleMetric(target: Self.cycleDebugName(for: orderedTargets[resolvedIndex], detail: detail), success: true, detail: resolutionDetail)

        let hidesApp: Bool
        switch action {
        case .focus(let value), .open(let value): hidesApp = value
        }
        if hidesApp { hideAfterSuccessfulExternalWindowAction(action) } else { commandPalette.dismissCommandPaletteForBuiltInWindowNavigation() }
    }

    private func trackedBrowserCycleState(workspaceID: String, detail: SpacesDeviceWorkspaceDetailViewModel) async -> BrowserCycleState {
        let resolvedSessions = detail.config.resolvedBrowserSessions
        guard !resolvedSessions.isEmpty else {
            return BrowserCycleState(
                openBrowserSessions: [], frontmostURL: nil, clientDBLookupMS: 0, chromeAppleScriptMS: 0, trackedWindowCount: 0, trackedTabCount: 0)
        }
        return await Task.detached(priority: .userInitiated) {
            let dbStartedAt = Date()
            let trackedWindows = ((try? ClientBrowserWindowIDStore().windowIDs(workspaceID: workspaceID)) ?? []).filter { $0.windowID > 0 }
            let clientDBLookupMS = TerminalPerformance.elapsedMS(since: dbStartedAt)
            guard !trackedWindows.isEmpty else {
                return BrowserCycleState(
                    openBrowserSessions: [], frontmostURL: nil, clientDBLookupMS: clientDBLookupMS, chromeAppleScriptMS: 0, trackedWindowCount: 0,
                    trackedTabCount: 0)
            }

            let chrome = ChromeAdapter()
            let chromeStartedAt = Date()
            let snapshot =
                (try? chrome.tabSnapshot(inWindowIDs: trackedWindows.map(\.windowID))) ?? ChromeTabSnapshot(tabs: [], frontmostActiveTabURL: nil)
            let chromeAppleScriptMS = TerminalPerformance.elapsedMS(since: chromeStartedAt)
            let openBrowserSessions = Self.openBrowserSessionsForCycle(
                resolvedSessions: resolvedSessions, assignedPorts: detail.assignedPorts, trackedTargetURLs: trackedWindows.map(\.targetURL),
                openTabURLs: snapshot.tabs.map(\.url))
            return BrowserCycleState(
                openBrowserSessions: openBrowserSessions, frontmostURL: snapshot.frontmostActiveTabURL, clientDBLookupMS: clientDBLookupMS,
                chromeAppleScriptMS: chromeAppleScriptMS, trackedWindowCount: trackedWindows.count, trackedTabCount: snapshot.tabs.count)
        }.value
    }

    nonisolated static func openBrowserSessionsForCycle(
        resolvedSessions: [SpacesDeviceBrowserSession], assignedPorts: [SpacesDeviceAssignedPort], trackedTargetURLs: [String], openTabURLs: [String]
    ) -> [BrowserSession] {
        let configuredTargetURLs = browserSessionTargetURLs(resolvedSessions: resolvedSessions)
        return resolvedSessions.compactMap { session -> BrowserSession? in
            guard let url = session.url, !url.isEmpty else { return nil }
            let siblingTargetURLs = browserSessionSiblingTargetURLs(targetURL: url, targetURLs: configuredTargetURLs)
            guard
                trackedTargetURLs.contains(where: {
                    browserObservedURL($0, matchesBrowserSessionTargetURL: url, excluding: siblingTargetURLs, assignedPorts: assignedPorts)
                })
            else { return nil }
            guard
                openTabURLs.contains(where: {
                    browserObservedURL($0, matchesBrowserSessionTargetURL: url, excluding: siblingTargetURLs, assignedPorts: assignedPorts)
                })
            else { return nil }
            return localBrowserSession(from: session)
        }
    }

    nonisolated static func browserSessionTargetURLs(resolvedSessions: [SpacesDeviceBrowserSession], including targetURL: String? = nil) -> [String] {
        var values = resolvedSessions.compactMap(\.url)
        if let targetURL { values.append(targetURL) }
        return uniqueBrowserSessionTargetURLs(values)
    }

    nonisolated static func browserSessionTargetURLs(workspaceID: String, targetURL: String, overview: SpacesDeviceOverviewPayload?) -> [String] {
        browserSessionTargetURLs(
            resolvedSessions: overview.flatMap { workspaceDetail(workspaceID, in: $0)?.config.resolvedBrowserSessions } ?? [], including: targetURL)
    }

    nonisolated static func browserSessionTargetURLs(workspaceID: String, overview: SpacesDeviceOverviewPayload?) -> [String] {
        browserSessionTargetURLs(resolvedSessions: overview.flatMap { workspaceDetail(workspaceID, in: $0)?.config.resolvedBrowserSessions } ?? [])
    }

    nonisolated static func browserSessionTeardownTargetURLs(configuredTargetURLs: [String], trackedTargetURLs: [String]) -> [String] {
        uniqueBrowserSessionTargetURLs(configuredTargetURLs + trackedTargetURLs)
    }

    nonisolated private static func uniqueBrowserSessionTargetURLs(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    nonisolated static func browserSessionSiblingTargetURLs(targetURL: String, targetURLs: [String]) -> [String] {
        guard !targetURL.isEmpty else { return [] }
        var seen = Set<String>()
        return targetURLs.filter { candidate in
            guard !candidate.isEmpty, !browserSessionTargetURL(candidate, matches: targetURL), candidate.hasPrefix(targetURL),
                seen.insert(candidate).inserted
            else { return false }
            return true
        }
    }

    nonisolated static func browserSessionTargetURL(_ candidateURL: String, matches targetURL: String) -> Bool {
        guard !candidateURL.isEmpty, !targetURL.isEmpty else { return false }
        return browserTabURLIsExactTarget(candidateURL, targetURL: targetURL)
    }

    nonisolated static func browserTabURL(_ tabURL: String, matchesBrowserSessionTargetURL targetURL: String, excluding siblingTargetURLs: [String])
        -> Bool
    {
        guard !targetURL.isEmpty else { return false }
        if browserTabURLIsExactTarget(tabURL, targetURL: targetURL) { return true }
        guard tabURL.hasPrefix(targetURL) else { return false }
        return !siblingTargetURLs.contains { siblingTargetURL in !siblingTargetURL.isEmpty && tabURL.hasPrefix(siblingTargetURL) }
    }

    nonisolated static func browserObservedURL(
        _ observedURL: String, matchesBrowserSessionTargetURL targetURL: String, excluding siblingTargetURLs: [String],
        assignedPorts: [SpacesDeviceAssignedPort]
    ) -> Bool {
        browserObservedURLMatchLength(observedURL, targetURL: targetURL, siblingTargetURLs: siblingTargetURLs, assignedPorts: assignedPorts) != nil
    }

    nonisolated private static func browserObservedURLMatchLength(
        _ observedURL: String, targetURL: String, siblingTargetURLs: [String], assignedPorts: [SpacesDeviceAssignedPort]
    ) -> Int? {
        if browserTabURL(observedURL, matchesBrowserSessionTargetURL: targetURL, excluding: siblingTargetURLs) { return targetURL.count }
        guard let routedTargetURL = routedBrowserSessionTargetURL(targetURL: targetURL, observedURL: observedURL, assignedPorts: assignedPorts) else {
            return nil
        }
        let routedSiblingTargetURLs = siblingTargetURLs.compactMap {
            routedBrowserSessionTargetURL(targetURL: $0, observedURL: observedURL, assignedPorts: assignedPorts)
        }
        guard browserTabURL(observedURL, matchesBrowserSessionTargetURL: routedTargetURL, excluding: routedSiblingTargetURLs) else { return nil }
        return routedTargetURL.count
    }

    nonisolated private static func routedBrowserSessionTargetURL(targetURL: String, observedURL: String, assignedPorts: [SpacesDeviceAssignedPort])
        -> String?
    {
        BrowserSSHForwardManager.routePlan(
            targetURL: targetURL, assignedPorts: assignedPorts, localRouterPort: URLComponents(string: observedURL)?.port)?.browserURL.absoluteString
    }

    nonisolated private static func browserTabURLIsExactTarget(_ tabURL: String, targetURL: String) -> Bool {
        if tabURL == targetURL { return true }
        guard !targetURL.contains("?"), !targetURL.contains("#") else { return false }
        if targetURL.hasSuffix("/") { return tabURL == String(targetURL.dropLast()) }
        return tabURL == targetURL + "/"
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
            case .missingConfiguredProcess, .agentLauncher: return false
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
        case .runCodingAgent(_, let agentName, let launcherID):
            rememberWindowNavigationCodingAgent(
                workspaceID: workspaceID, agentName: agentName, launcherID: launcherID, preserveWindowCycleSession: preserveWindowCycleSession)
        case .noWorkspace, .noMatch: return
        }
    }

    @discardableResult private func rememberWindowNavigationTargetIfCycleable(
        _ target: WorkspaceRunShortcutTarget, workspaceID: String, detail: SpacesDeviceWorkspaceDetailViewModel, preserveWindowCycleSession: Bool
    ) -> Bool {
        switch target.kind {
        case .browser: guard target.targetURL?.isEmpty == false else { return false }
        case .process, .window, .agent: guard Self.cycleTargetSessionID(for: target, detail: detail)?.isEmpty == false else { return false }
        case .missingConfiguredProcess, .agentLauncher: return false
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

    private func rememberWindowNavigationCodingAgent(workspaceID: String, agentName: String, launcherID: String?, preserveWindowCycleSession: Bool) {
        guard let context = focusableWindowContext(workspaceID: workspaceID) else { return }
        let target = context.targets.first { target in
            guard target.kind == .agent, let agentWindow = target.agentWindow,
                let row = context.detail.codingAgentRows.first(where: { ($0.agentID ?? $0.id) == agentWindow.id })
            else { return false }
            if let launcherID, !launcherID.isEmpty, row.launcherID == launcherID { return true }
            return Self.normalizedRunRowName(row.name) == Self.normalizedRunRowName(agentName)
                || Self.normalizedRunRowName(agentWindow.label ?? "") == Self.normalizedRunRowName(agentName)
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
        case .openURL(let workspaceID, _), .runProcess(let workspaceID, _, _), .runCodingAgent(let workspaceID, _, _): return workspaceID
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
        case .agent: return "agent:\(target.agentWindow?.label ?? target.agentWindow?.id ?? "")"
        case .missingConfiguredProcess: return "process:\(target.processKey ?? "")"
        case .agentLauncher: return "agent:\(target.launcherName ?? "")"
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
                let siblingTargetURLs = browserSessionSiblingTargetURLs(targetURL: targetURL, targetURLs: browserTargetURLs)
                guard
                    let matchLength = browserObservedURLMatchLength(
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
            await self.openTerminalSessionPane(sessionID: sessionID, mode: mode, requestID: requestID)
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
                let opened = await self.openTerminalSessionPane(sessionID: sessionID, mode: .owner, requestID: focusRequestID)
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
                sessionID: sessionID, mode: .owner, requestID: focusRequestID, resolvedRequest: Self.terminalSessionPaneOpenRequest(from: match))
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

    /// The light/dark appearance a terminal session should carry, shared thread-safely between the
    /// pane's attach closure (which reads it when the client attaches, off the main actor) and the
    /// appearance-broadcast path (which advances it on an app appearance change). One value across both
    /// means an appearance change that lands before the pane attaches is carried by the pending attach
    /// rather than lost, and it doubles as the per-session dedupe state for `applyAppearanceToLiveSession`.
    private final class SessionAppearanceStore: @unchecked Sendable {
        private let lock = NSLock()
        private var appearance: ThemeAppearance

        init(_ appearance: ThemeAppearance) { self.appearance = appearance }

        func set(_ appearance: ThemeAppearance) {
            lock.lock()
            self.appearance = appearance
            lock.unlock()
        }

        func current() -> ThemeAppearance {
            lock.lock()
            defer { lock.unlock() }
            return appearance
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
    /// Ownership is read ungated — a session on an unreachable device still belongs to that
    /// device, and refusing to name it here would drop through to the local-device fallback and
    /// read another machine's session from this Mac. Acting on the session is gated separately.
    private func terminalSessionOwningDevice(sessionID: String) -> SpacesPairedDeviceRecord? {
        if let match = terminalSessionSummaryMatch(sessionID: sessionID) { return match.device }
        if let workspaceID = clientWorkspaceID(forTerminalSession: sessionID), let deviceID = deviceID(forWorkspaceID: workspaceID) {
            return deviceOwning(deviceID: deviceID)
        }
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
            updatedAt: summary.updatedAt, title: summary.title, workingDirectory: summary.workingDirectory, bellAt: summary.bellAt)
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
            let bootstrapStartedAt = Date()
            let device = await Task.detached(
                priority: .userInitiated, operation: { try? SpacesDeviceClient.bootstrapLocalDevice(clientApp: clientApp) }
            ).value
            logPerfMetric(
                "terminal_session_resolve_bootstrap", target: "session=\(sessionID)",
                elapsedMS: TerminalPerformance.elapsedMS(since: bootstrapStartedAt), success: device != nil)
            guard let device else { return nil }
            localPairedDevice = device
            localDeviceID = device.id
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
        seedInitialRuntimeState: TerminalSessionRuntimeState? = nil, resolvedSummaryMatch: TerminalSessionSummaryMatch? = nil,
        preparedCredentials: DeviceTerminalSessionStateModel.PreparedCredentials
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
            clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short), preparedCredentials: preparedCredentials)
    }

    func prepareTerminalPaneOpenRequest(_ request: DeviceTerminalOpenRequest) async -> Result<DeviceTerminalOpenRequest, Error> {
        if request.preparedCredentials != nil { return .success(request) }
        // Opening a pane connects to the owning daemon, so an unreachable device is refused here with
        // the same named-and-offline message its other actions carry rather than a generic not-loaded
        // one the user can see they are not in.
        let requestedDeviceID = request.deviceID ?? deviceID(forWorkspaceID: request.workspaceID)
        guard let requestedDeviceID, let device = deviceForMutation(deviceID: requestedDeviceID) else {
            return .failure(deviceUnavailableError(deviceID: requestedDeviceID))
        }
        let clientApp = SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)
        let isLocalDevice = device.id == SpacesPairedDeviceRecord.localDeviceID
        // For the local device, re-resolve the daemon's current Device API port (and ensure it is
        // running) the way the CLI does per request. The stored paired_devices row goes stale when
        // the local daemon idle-shuts-down and rebinds a port; seeding the fresh endpoint here — off
        // the main actor, before the model and its request client are built — keeps the pane's first
        // control connect fast instead of blocking the main actor on a dead port. The bootstrap goes
        // through the process-wide single-flight shared with the models' recovery paths: pane
        // restoration prepares many panes concurrently, and uncoalesced bootstraps presenting the
        // same stale token would each mint a distinct replacement, seeding all but the last-prepared
        // pane with an already-revoked token. Best-effort: a failed re-resolution falls back to the
        // stored row, and the model's connect-time recovery still heals the port later.
        let refreshedLocalDevice = isLocalDevice ? await LocalDeviceRecoveryBootstrap.run(clientApp: clientApp)?.record : nil
        let result: Result<DeviceTerminalSessionStateModel.PreparedCredentials, Error> = await Task.detached(priority: .userInitiated) {
            do {
                // Resolve credentials from the same record the endpoint came from: the bootstrap above may
                // have re-paired against a daemon whose TLS identity rotated, so `resolveCredentials` must
                // read the refreshed record's fingerprint. Resolving before the bootstrap would pair the
                // rotated daemon's fresh host/port with the stale token file's fingerprint — its
                // re-bootstrap branch only fires on a missing token — and pin-fail every connect.
                let credentials = try DeviceTerminalSessionStateModel.resolveCredentials(device: refreshedLocalDevice ?? device, clientApp: clientApp)
                return .success(credentials)
            } catch { return .failure(error) }
        }.value
        return result.map { credentials in request.prepared(credentials: credentials, resolvedLocalDevice: refreshedLocalDevice) }
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
        return Self.terminalSessionPaneOpenRequest(from: match)
    }

    /// The pane open request for a session resolved to its owning device, pinning `deviceID` so the
    /// pane attaches to that device — remote or local — regardless of the request's later workspace
    /// device lookup. Shared by the cold-resolve path and the remote deep-link open.
    nonisolated static func terminalSessionPaneOpenRequest(from match: TerminalSessionSummaryMatch) -> DeviceTerminalOpenRequest {
        let summary = match.summary
        return DeviceTerminalOpenRequest(
            workspaceID: summary.workspaceID, deviceID: match.device.id, sessionID: summary.id, title: summary.title,
            workingDirectory: summary.workingDirectory, kind: terminalSessionKind(rowKind: summary.rowKind), shell: summary.shell,
            command: summary.command, initialState: summary.state, servicePID: summary.servicePID, childPID: summary.childPID,
            createdAt: summary.createdAt, updatedAt: summary.updatedAt)
    }

    /// Opens (or focuses) the session's pane and, for an owner-mode open, reclaims owner
    /// attachment. `mode` carries the intent of the `openTerminalSessionWindow` IPC: an
    /// owner open (e.g. `spaces terminal show`) must preempt a different active owner (a
    /// mobile client that took the session over), so it calls `requestOwnershipIfNeeded()`
    /// after the pane opens. The pane's own attach otherwise stays a viewer when another
    /// client owns, which would leave ownership unchanged. Emits the `terminal_window_summon`
    /// perf metric the E2E harness parses.
    /// `resolvedRequest`, when provided, skips the internal session→device resolution: the remote
    /// deep-link open resolves the request against the link's explicitly named device (so it never
    /// falls back to the local device the way the session-id-only resolve does) and hands it in here,
    /// reusing this one open/focus + owner-reclaim + metric path.
    @discardableResult private func openTerminalSessionPane(
        sessionID: String, mode: TerminalAttachmentMode, requestID: String? = nil, resolvedRequest: DeviceTerminalOpenRequest? = nil
    ) async -> Bool {
        let startedAt = Date()
        let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
        cancelDeferredExternalWindowHide()
        let reusedExistingPane = panelCoordinator.placement(forSessionID: sessionID) != nil
        // Re-showing the pane the user is already focused in and owns is a foreground-and-focus, so it also
        // skips resolving the request: resolution only exists to install or re-target a pane.
        if reusedExistingPane, panelCoordinator.refocusFocusedTerminalPane(forSessionID: sessionID) {
            logPerfMetric(
                "terminal_window_summon", target: "session=\(sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true,
                detail: "mode=\(mode.rawValue) reused=1 route=pane refocus=1\(requestDetail)")
            return true
        }
        let resolved: DeviceTerminalOpenRequest?
        if let resolvedRequest { resolved = resolvedRequest } else { resolved = await resolveTerminalSessionPaneOpenRequest(sessionID: sessionID) }
        guard let request = resolved else {
            logPerfMetric(
                "terminal_window_summon", target: "session=\(sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false,
                detail: "mode=\(mode.rawValue) route=pane reason=resolve_nil\(requestDetail)")
            return false
        }
        guard panelCoordinator.openOrFocusTerminalPane(request) else {
            logPerfMetric(
                "terminal_window_summon", target: "session=\(sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: false,
                detail: "mode=\(mode.rawValue) route=pane reason=pane_open_failed\(requestDetail)")
            return false
        }
        if mode == .owner { panelCoordinator.content(forSessionID: sessionID)?.requestOwnershipIfNeeded() }
        logPerfMetric(
            "terminal_window_summon", target: "session=\(sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: true,
            detail: "mode=\(mode.rawValue) reused=\(reusedExistingPane ? 1 : 0) route=pane\(requestDetail)")
        return true
    }

    /// Focuses a session's pane (opening it when needed) for the focus IPC, emitting the
    /// `terminal_window_focus_ipc` metric the E2E harness correlates by request id.
    private func focusTerminalSessionPane(sessionID: String, requestID: String?) async {
        let startedAt = Date()
        let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
        // Focus must not preempt a different active owner (matching the pre-rework focus
        // path); only the owner-mode open IPC reclaims ownership.
        let focused = await openTerminalSessionPane(sessionID: sessionID, mode: .viewer, requestID: requestID)
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
            // A global-window pane can mix devices, so its request carries deviceID
            // directly; otherwise it derives from the request's workspace. The id is the pane
            // descriptor's device key and decides local-vs-remote link handling, so a workspace
            // no loaded section claims raises not-loaded instead of being treated as local.
            guard let resolvedDeviceID = request.deviceID ?? deviceID(forWorkspaceID: request.workspaceID) else { throw Self.deviceNotLoadedError() }
            // Prefer the local device endpoint re-resolved during preparation (current port, daemon
            // ensured running) over the possibly-stale stored row, so the model's request client and
            // subscription stream target a live port from the start (issue #185). Remote devices carry
            // `nil` here and use the stored record.
            let device = request.resolvedLocalDevice ?? deviceForMutation(deviceID: resolvedDeviceID)
            guard let preparedCredentials = request.preparedCredentials else {
                throw WorkspaceError.invalidArgument(message: "Terminal credentials are still preparing.")
            }
            let summary = terminalSessionSummaryMatch(sessionID: sessionID)?.summary
            let createdAt = request.createdAt ?? iso8601Formatter.string(from: Date())
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
                resolvedSummaryMatch: nil, preparedCredentials: preparedCredentials)
            let requestSender = stateModel.terminalServiceRequestSender
            let applyControlState = stateModel.controlStateApplier
            let agentSignalHandler: RemoteGhosttyAgentSignalHandler = { [weak self] events in
                guard let self else { return [String]() }
                return self.applyRemoteAgentSignals(events)
            }
            let remoteClientStore = RemoteTerminalWindowClientStore()
            // Reuse the owner client id this device stored on its last successful owner attach/takeover
            // for this session so a relaunch of this Mac (e.g. after an app upgrade) presents the same id
            // and silently reclaims the still-running session's orphaned `localWindow` owner attachment.
            // Keyed by the local device id; a stale mapping is inert since it matches no current owner.
            let ownerClientIDStore = ClientTerminalOwnerClientIDStore()
            let reusableOwnerClientID = try? ownerClientIDStore.clientID(sessionID: sessionID)
            // Resolved once here (this runs on the main actor); the attach closure is @Sendable and may
            // run off-main, so it cannot read NSApp. Seeds the shared appearance store, which the attach
            // reads when it fires and the broadcast path advances on a mid-session appearance change
            // (settings picker or an OS flip while on `.system`) — so an appearance change that lands
            // before the pane attaches is carried by the attach, and one after it re-themes the live
            // session without waiting for a reopen.
            let themeAppearance: ThemeAppearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
            let appearanceStore = SessionAppearanceStore(themeAppearance)
            let attachClientAction: @Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void = { client, attachmentMode in
                remoteClientStore.set(client.id)
                let response = try Self.sendDeviceTerminalControl(
                    sessionID: sessionID,
                    request: TerminalControlRequest(
                        command: .attach(
                            TerminalControlAttachPayload(client: client, attachmentMode: attachmentMode, appearance: appearanceStore.current()))),
                    requestSender: requestSender, refreshStateAfterControl: true, applyState: applyControlState)
                guard response.ok else { throw WorkspaceError.invalidArgument(message: response.message) }
                // Persist the owner client id only once the daemon confirms this client attached as
                // OWNER, so a relaunch of this Mac reuses it and silently reclaims the still-running
                // session's orphaned owner attachment. Not optimistic: response.ok means the daemon
                // recorded this client as the owner attachment.
                if attachmentMode == .owner { try? ownerClientIDStore.setClientID(sessionID: sessionID, clientID: client.id) }
            }
            let detachClientAction: @Sendable (String) throws -> Void = { clientID in
                if remoteClientStore.current() == clientID { remoteClientStore.set(nil) }
                let response = try Self.sendDeviceTerminalControl(
                    sessionID: sessionID, request: TerminalControlRequest(command: .detach(TerminalControlClientPayload(clientID: clientID))),
                    requestSender: requestSender, refreshStateAfterControl: true, applyState: applyControlState)
                guard response.ok else { throw WorkspaceError.invalidArgument(message: response.message) }
            }
            let sendInputAction: @Sendable (String, Bool) throws -> TerminalControlResponse = { text, appendNewline in
                guard let clientID = remoteClientStore.current() else {
                    return TerminalControlResponse(ok: false, message: "Terminal pane is not attached.")
                }
                return try Self.sendDeviceTerminalControl(
                    sessionID: sessionID,
                    request: TerminalControlRequest(
                        command: .send(
                            TerminalControlSendPayload(text: text, bytes: nil, clientID: clientID, ownerEpoch: nil, appendNewline: appendNewline))),
                    requestSender: requestSender, applyState: applyControlState)
            }
            let sendKeyAction: @Sendable (String) throws -> TerminalControlResponse = { key in
                guard let clientID = remoteClientStore.current() else {
                    return TerminalControlResponse(ok: false, message: "Terminal pane is not attached.")
                }
                return try Self.sendDeviceTerminalControl(
                    sessionID: sessionID,
                    request: TerminalControlRequest(command: .key(TerminalControlKeyPayload(key: key, clientID: clientID, ownerEpoch: nil))),
                    requestSender: requestSender, applyState: applyControlState)
            }
            let pasteImageAction: @MainActor (TerminalPasteboardImage) async throws -> TerminalControlResponse = { image in
                guard let clientID = remoteClientStore.current() else {
                    return TerminalControlResponse(ok: false, message: "Terminal pane is not attached.")
                }
                // Send whatever owner epoch the cached payload carries, absent included: a payload with no
                // render owner epoch (an owner change, or an input-reason payload) means this paste is not
                // epoch-gated, exactly like every other input path this pane sends.
                return try await stateModel.pasteImage(image, clientID: clientID, ownerEpoch: stateModel.latestRemoteStatePayload?.renderOwnerEpoch)
            }
            let takeoverAction: @Sendable (String) throws -> TerminalControlResponse = { clientID in
                let response = try Self.sendDeviceTerminalControl(
                    sessionID: sessionID, request: TerminalControlRequest(command: .takeover(TerminalControlClientPayload(clientID: clientID))),
                    requestSender: requestSender, refreshStateAfterControl: true, applyState: applyControlState)
                // A successful takeover transfers ownership to this client on the daemon via
                // `transferOwnership` (not a re-attach through `attachClientAction`), so persist the
                // owner id here too — otherwise the reclaimed-after-takeover id would not survive a
                // relaunch.
                if response.ok { try? ownerClientIDStore.setClientID(sessionID: sessionID, clientID: clientID) }
                return response
            }
            // Re-themes this session to a new app appearance mid-session (see `applyAppearanceToLiveSession`).
            // Reuses the pane's captured request sender and `remoteClientStore` clientID, mirroring the input
            // closures above. The dedupe/desired state lives in `appearanceStore`, which the attach also reads,
            // so a change that arrives before attach is recorded here and carried by the pending attach.
            let setAppearanceAction: (ThemeAppearance) -> Void = { appearance in
                appearanceStore.set(
                    Self.applyAppearanceToLiveSession(
                        appearance, sessionID: sessionID, clientID: remoteClientStore.current(), lastAppliedAppearance: appearanceStore.current(),
                        requestSender: requestSender, applyState: applyControlState))
            }
            // The mirror view's link handler is captured when the pane is built, but the coordinator that
            // routes clicks needs the pane's view for its banner and so can only be built afterward. The
            // handler box bridges that ordering: the session-host provider reads it lazily on the first
            // link click, long after the coordinator has been attached below.
            let linkOpenBox = TerminalLinkOpenHandlerBox()
            let pane = TerminalSessionPaneViewController(
                sessionID: sessionID, paths: paths, stateProvider: stateModel, preferredAttachmentMode: .owner, performInitialRefresh: false,
                reusableOwnerClientID: reusableOwnerClientID, sendInputAction: sendInputAction, sendKeyAction: sendKeyAction,
                pasteImageAction: pasteImageAction, takeoverAction: takeoverAction, attachClientAction: attachClientAction,
                detachClientAction: detachClientAction,
                onCloseClientDetached: { [weak self] in self?.terminateUnattachedAdHocBuiltInTerminalSessionIfNeeded(sessionID: sessionID) },
                sessionHostProvider: { launchConfiguration, paths in
                    Self.terminalSessionHost(
                        launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: requestSender,
                        stateStreamSubscriber: stateModel.makeHostStateStreamSubscriber(),
                        transcriptProvider: { [weak stateModel] maxBytes in
                            guard let stateModel else { throw WorkspaceError.invalidArgument(message: "Terminal state model was released.") }
                            return try await stateModel.fetchTranscript(maxBytes: maxBytes)
                        }, agentSignalHandler: agentSignalHandler, linkOpenHandler: { [linkOpenBox] rawLink in linkOpenBox.open(rawLink) },
                        // A keystroke that cannot reach the device is the pane's earliest evidence its link
                        // is gone; the state model owns that verdict, so the raw failure goes there rather
                        // than being classified or acted on at the render host. `reportFailedInputSend` is
                        // main-actor-isolated and this handler is not, so `await` straight into it — its
                        // return value is exactly the `RemoteGhosttyInputFailureHandler` contract (whether
                        // the failure proves the link is gone), and the host awaits it to decide whether to
                        // drop this pane's queued input.
                        inputFailureHandler: { [weak stateModel] error in await stateModel?.reportFailedInputSend(error) ?? false })
                })
            let linkOpenCoordinator = TerminalLinkOpenCoordinator(
                sessionID: sessionID, deviceID: resolvedDeviceID, isLocalDevice: resolvedDeviceID == SpacesPairedDeviceRecord.localDeviceID,
                workingDirectoryProvider: { [weak stateModel] in
                    let payload = stateModel?.latestRemoteStatePayload
                    return Self.terminalLinkWorkingDirectory(
                        runtimeState: stateModel?.currentRuntimeState ?? payload?.runtimeState, streamedWorkingDirectory: payload?.workingDirectory,
                        launchWorkingDirectory: stateModel?.currentLaunchConfiguration?.workingDirectory,
                        requestWorkingDirectory: request.workingDirectory)
                }, requestSender: requestSender, banner: pane.banner,
                openSpacesTerminalLink: { [weak self] link in self?.handleTerminalDeepLink(link) })
            linkOpenBox.coordinator = linkOpenCoordinator
            let content = TerminalPaneContentController(
                descriptor: .terminalSession(deviceID: resolvedDeviceID, sessionID: sessionID), workspaceID: request.workspaceID,
                sessionID: sessionID, pane: pane, setAppearanceAction: setAppearanceAction,
                terminalTextZoomAction: { [weak self] command in self?.adjustTerminalTextSize(command) }, linkOpenCoordinator: linkOpenCoordinator)
            // The size is app-wide and already loaded, so a pane opens at it rather than at the default
            // and waiting for the next change.
            content.applyTerminalTextSize(terminalTextSize)
            return content
        } catch {
            showError(error)
            return nil
        }
    }

    nonisolated static func terminalLinkWorkingDirectory(
        runtimeState: TerminalSessionRuntimeState?, streamedWorkingDirectory: String?, launchWorkingDirectory: String?,
        requestWorkingDirectory: String
    ) -> String {
        if let liveWorkingDirectory = liveTerminalWorkingDirectory(runtimeState: runtimeState) { return liveWorkingDirectory }
        if let workingDirectory = normalizedTerminalWorkingDirectory(runtimeState?.workingDirectory) { return workingDirectory }
        if let workingDirectory = normalizedTerminalWorkingDirectory(streamedWorkingDirectory) { return workingDirectory }
        if let workingDirectory = normalizedTerminalWorkingDirectory(launchWorkingDirectory) { return workingDirectory }
        return requestWorkingDirectory
    }

    private nonisolated static func liveTerminalWorkingDirectory(runtimeState: TerminalSessionRuntimeState?) -> String? {
        guard let runtimeState else { return nil }
        if let foregroundPID = runtimeState.foregroundPID, let cwd = TerminalForegroundProcessInspector.workingDirectory(pid: foregroundPID) {
            return cwd
        }
        if let childPID = runtimeState.childPID, let cwd = TerminalForegroundProcessInspector.workingDirectory(pid: childPID) { return cwd }
        return nil
    }

    private nonisolated static func normalizedTerminalWorkingDirectory(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Starts a fresh ad hoc terminal session on the workspace's owning daemon and
    /// resolves the pane open request for panel entry points.
    func createTerminalSessionForPane(workspaceID: String, completion: @escaping (DeviceTerminalOpenRequest?) -> Void) {
        guard let device = deviceForWorkspaceMutation(workspaceID: workspaceID) else {
            showWorkspaceDeviceUnavailableError(workspaceID: workspaceID)
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
                self.applyDeviceMutationResponse(response, deviceID: device.id, selectedWorkspaceID: workspaceID)
                guard let request = self.terminalOpenRequest(fromMutationResponse: response, workspaceID: workspaceID) else {
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

    private func terminalOpenRequest(fromMutationResponse response: SpacesDeviceAPIResponse, workspaceID: String) -> DeviceTerminalOpenRequest? {
        guard let sessionID = response.sessionID else { return nil }
        return Self.deviceTerminalOpenRequest(
            workspaceID: workspaceID, sessionID: sessionID, overview: response.overview ?? overview(forWorkspaceID: workspaceID))
    }

    nonisolated static func deviceTerminalControlRequest(sessionID: String, controlRequest request: TerminalControlRequest) throws
        -> SpacesDeviceTerminalControlRequest
    {
        guard request.bytes == nil else {
            throw WorkspaceError.invalidArgument(message: "Raw byte terminal control is not supported for active remote devices.")
        }
        let command = request.commandValue
        guard let action = SpacesDeviceTerminalControlAction(rawValue: command.name) else {
            throw WorkspaceError.invalidArgument(message: "Unsupported remote terminal command '\(command.name)'.")
        }
        return SpacesDeviceTerminalControlRequest(
            action: action, sessionID: sessionID, clientID: request.clientID, client: request.client, attachmentMode: request.attachmentMode,
            text: request.text, key: request.key, columns: request.columns, rows: request.rows, ownerEpoch: request.ownerEpoch,
            resizeSerial: request.resizeSerial, scrollHorizontal: request.scrollHorizontal, scrollVertical: request.scrollVertical,
            scrollMods: request.scrollMods, scrollPointerX: request.scrollPointerX, scrollPointerY: request.scrollPointerY,
            scrollPointerMods: request.scrollPointerMods, mouseButton: request.mouseButton, mousePressed: request.mousePressed,
            mousePointerX: request.mousePointerX, mousePointerY: request.mousePointerY, mousePointerMods: request.mousePointerMods,
            appendNewline: request.appendNewline, asPaste: request.asPaste, appearance: request.appearance)
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

    /// Re-themes one live session to `appearance` by sending `setAppearance`, and returns the appearance the
    /// session's store should now carry. A redundant re-theme (already on `appearance`) sends nothing and keeps
    /// the value. When no client is attached yet the send is skipped but the value still advances to `appearance`
    /// so the pending attach carries it — otherwise a change that lands before attach would be lost, and later
    /// broadcasts of the actual variant would dedupe against a stale value until the next flip. `clientID` is
    /// trace-only for setAppearance — appearance is deliberately not owner-gated — but the daemon still expects
    /// one. Best-effort: a failed send returns `lastAppliedAppearance` unchanged so the next flip retries it.
    nonisolated static func applyAppearanceToLiveSession(
        _ appearance: ThemeAppearance, sessionID: String, clientID: String?, lastAppliedAppearance: ThemeAppearance,
        requestSender: RemoteGhosttyTerminalServiceRequestSender, applyState: @Sendable (GhosttyRemoteSessionStatePayload) -> Void
    ) -> ThemeAppearance {
        guard appearance != lastAppliedAppearance else { return lastAppliedAppearance }
        guard let clientID else { return appearance }
        do {
            _ = try sendDeviceTerminalControl(
                sessionID: sessionID,
                request: TerminalControlRequest(
                    command: .setAppearance(TerminalControlSetAppearancePayload(clientID: clientID, appearance: appearance))),
                requestSender: requestSender, applyState: applyState)
            return appearance
        } catch { return lastAppliedAppearance }
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

    func terminateUnattachedAdHocBuiltInTerminalSessionIfNeeded(sessionID: String) {
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
            let changedSessionID = TerminalSessionNotification.sessionID(from: notification)
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

    enum SidebarDeviceLoadState: Sendable, Hashable {
        case loading
        case offline(String)
        case loaded

        var isOffline: Bool {
            if case .offline = self { return true }
            return false
        }
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
        /// Bumped by `overview`'s `didSet` on every reassignment after this section already exists —
        /// once per overview-install event for this device, from whichever path installs it (a local
        /// snapshot refresh, a remote pull/subscription in `SidebarController`, or a mutation response
        /// in this file). A struct's own memberwise init never routes through property observers, so a
        /// section's initial construction leaves this at its default rather than counting as an install.
        ///
        /// `resolveAwaitingWorkspaceDeletions` uses this to tell "fresh evidence for the owning device
        /// arrived" apart from "some other device's refresh re-ran the `workspacesByProject` didSet,
        /// which reread this device's untouched, possibly stale, cached overview" — the bug this guards
        /// against: an offline owning device keeps its last-known overview, and a rebuild triggered by
        /// any other device would otherwise draw a delete verdict from evidence that predates the
        /// delete.
        ///
        /// The local device's section is not mutated in place on an ordinary refresh — it is rebuilt and
        /// assigned whole (`SidebarController.rebuildFlatSidebarData()`), which bypasses `didSet` — so that
        /// path carries the counter forward explicitly via `adoptingOverviewInstallGeneration(from:)`.
        /// Without that, the local counter would reset to zero on every refresh and a deferred delete for a
        /// local workspace would never see fresh evidence at all.
        private(set) var overviewInstallGeneration = 0
        var overview: SpacesDeviceOverviewPayload? { didSet { overviewInstallGeneration += 1 } }

        /// Carries `previous`'s install generation into this freshly built section, counting one new install
        /// when `carriesFreshInstall` says this rebuild is carrying an overview the daemon actually just
        /// returned.
        ///
        /// The caller states that fact rather than letting this infer it from payload equality. A fresh
        /// fetch that happens to be byte-identical to the cached one is real evidence — it is exactly what
        /// a delete that never reached the daemon looks like — and treating it as "nothing happened" would
        /// leave that deferred delete unresolvable for the rest of the run. Conversely an outage rebuild
        /// re-renders the retained overview without asking the daemon anything, and must not count.
        func adoptingOverviewInstallGeneration(from previous: DeviceSection?, carriesFreshInstall: Bool) -> DeviceSection {
            var section = self
            section.overviewInstallGeneration = (previous?.overviewInstallGeneration ?? 0) + (carriesFreshInstall ? 1 : 0)
            return section
        }
        /// Frozen-core handshake read for this device, refreshed alongside the overview. `nil` until
        /// the first successful handshake; drives the per-device compatibility banner and gating.
        var daemonStatus: TerminalServiceDaemonStatus?
        var compatibility: SpacesWireCompatibility?

        /// The label shown for this device everywhere in the UI. The local device always renders as
        /// "Local" regardless of its stored machine name; remote devices show their stored name.
        var displayName: String { isLocal ? "Local" : deviceName }
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
            workspaceID: workspaceID, pendingDeletionWorkspaceIDs: workspaceIDsPendingDeletion, deviceOverview: deviceOverview)
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
    @MainActor private final class ClickTarget: NSObject {
        let action: () async -> Void
        init(_ action: @escaping () async -> Void) { self.action = action }
        @objc func clicked(_ sender: NSGestureRecognizer) { Task { await self.action() } }
    }

    private static var clickTargetAssocKey: UInt8 = 0

    @MainActor static func terminalSessionHost(
        launchConfiguration: TerminalSessionLaunchConfiguration, paths: TerminalSessionPaths,
        terminalServiceRequestSender: RemoteGhosttyTerminalServiceRequestSender? = nil,
        stateStreamSubscriber: RemoteGhosttyStateStreamSubscriber? = nil, transcriptProvider: RemoteGhosttyTranscriptProvider? = nil,
        agentSignalHandler: RemoteGhosttyAgentSignalHandler? = nil, linkOpenHandler: (@MainActor (String) -> Void)? = nil,
        inputFailureHandler: RemoteGhosttyInputFailureHandler? = nil
    ) -> any TerminalGhosttySessionHosting {
        RemoteGhosttySessionHost(
            launchConfiguration: launchConfiguration, paths: paths, terminalServiceRequestSender: terminalServiceRequestSender,
            stateStreamSubscriber: stateStreamSubscriber, transcriptProvider: transcriptProvider, agentSignalHandler: agentSignalHandler,
            linkOpenHandler: linkOpenHandler, inputFailureHandler: inputFailureHandler)
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

    /// What a workspace awaiting deferred delete resolution (see `AwaitingWorkspaceDeletionResolution`)
    /// should do once `resolveAwaitingWorkspaceDeletions` finds a candidate overview for its device.
    enum AwaitingWorkspaceDeletionResolutionVerdict: Equatable {
        /// No overview for the owning device is installed yet (it is nil — offline, not yet loaded, or a
        /// wire-incompatible placeholder). Nothing was proved either way, so the entry keeps waiting.
        case stillAwaiting
        /// An overview resolved and did not list the workspace: the delete landed. Clear the marking
        /// silently; `showsBranchOutcomeNotice` says whether the caller also has to surface the notice
        /// that branch deletion's own result was lost.
        case gone(showsBranchOutcomeNotice: Bool)
        /// An overview resolved and still lists the workspace: the held-back error is real and has to be
        /// surfaced now.
        case present
    }

    /// The pure decision `resolveAwaitingWorkspaceDeletions` makes per entry, factored out so it is
    /// testable without a live `AppKitController` — mirroring `WorkspaceDeletionReconciler`, an I/O-free
    /// type driven by an injected overview rather than a live device connection. `overview` is whatever
    /// `deviceSections` currently has installed for the workspace's owning device — `nil` until that
    /// device's next overview install actually lands.
    ///
    /// `overviewInstallGeneration` and `overviewInstallGenerationAtDefer` gate the verdict on *fresh*
    /// evidence for the owning device: `resolveAwaitingWorkspaceDeletions` is hooked off a
    /// `workspacesByProject` rebuild that fires for every device's refresh, not just the owning device's,
    /// and an offline owning device keeps its last-known (pre-delete) overview rather than clearing it.
    /// Without this check, some other device's refresh would trigger a rebuild that rereads the owning
    /// device's untouched cached overview, sees the workspace still listed, and wrongly concludes
    /// `.present` — a verdict drawn from evidence that predates the delete. Requiring the generation to
    /// have advanced past its captured-at-defer snapshot means the verdict is only drawn once this
    /// specific device's overview has actually been reinstalled since the defer.
    nonisolated static func resolveAwaitingWorkspaceDeletion(
        overview: SpacesDeviceOverviewPayload?, overviewInstallGeneration: Int, overviewInstallGenerationAtDefer: Int, workspaceID: String,
        branchDeletionRequested: Bool
    ) -> AwaitingWorkspaceDeletionResolutionVerdict {
        guard let overview, overviewInstallGeneration > overviewInstallGenerationAtDefer else { return .stillAwaiting }
        guard overview.workspaces.contains(where: { $0.id == workspaceID }) else { return .gone(showsBranchOutcomeNotice: branchDeletionRequested) }
        // Listed, but the daemon reports it is still tearing this workspace down: that is not the delete
        // having failed, it is the delete still running. Keep waiting rather than telling the user a
        // workspace survived that the daemon is about to remove.
        return overview.workspaceIDsWithTeardownInFlight.contains(workspaceID) ? .stillAwaiting : .present
    }

    /// The delete landed, but the branch-deletion report existed only in the response that was lost —
    /// reconciliation (or, once deferred, the next installed overview) can prove the workspace is gone,
    /// not what happened to branches the user explicitly asked to delete. Shared verbatim between the
    /// immediate `.gone` verdict in `deleteWorkspace` and `resolveAwaitingWorkspaceDeletions`, so both
    /// paths report the exact same thing rather than two copies of the same sentence drifting apart.
    private static let workspaceDeletionBranchOutcomeUnknownMessage =
        "Deleted the workspace, but the connection dropped before the branch-deletion result arrived. Check the branch in the repository."

    /// Refetches `device`'s overview for `WorkspaceDeletionReconciler`, discarding the specific
    /// failure: a reconciliation refetch that fails is inconclusive rather than proof of anything, so
    /// the reconciler just tries again on its next attempt.
    nonisolated private static func deviceOverviewFetch(device: SpacesPairedDeviceRecord) async -> SpacesDeviceOverviewPayload? {
        await Task.detached(priority: .userInitiated) {
            (try? SpacesDeviceClient.overview(device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))?.overview
        }.value
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

    /// Loads a git repository's `spaces.yaml` (single file, no clone) plus any managed-directory
    /// replacement candidates. Routed through the Device API so the preview runs on the device that
    /// will own the project (local or remote), not always locally.
    nonisolated private static func previewGitProjectResult(gitURL: String, device: SpacesPairedDeviceRecord) async -> Result<
        SpacesDeviceGitProjectPreview, Error
    > {
        await Task.detached(priority: .userInitiated) {
            do {
                return .success(
                    try SpacesDeviceClient.previewGitProject(
                        gitURL: gitURL, device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short)))
            } catch { return .failure(error) }
        }.value
    }

    // Browser rows stay visible even when the workspace is stopped so the Run tab
    // remains a stable launch surface for configured browser sessions.
    nonisolated static func shouldShowConfiguredBrowserSessions(workspaceIsRunning _: Bool) -> Bool { true }

    nonisolated static func shouldShowWorkspaceSetupPanel(status: WorkspaceSetupStatus) -> Bool { status != .succeeded }

    nonisolated static func shouldShowWorkspaceSetupScriptEditor(status: WorkspaceSetupStatus) -> Bool { status == .failed }

    nonisolated static func shouldRequestNormalWorkspaceDetailRefresh(setupStatus: WorkspaceSetupStatus) -> Bool { setupStatus == .succeeded }

    // ISO8601DateFormatter construction is expensive and this is shared by the `nonisolated`
    // overview-mapping helpers below (buildOverviewAlertsGroups, agentWindows,
    // deviceTerminalWindows), which run off the main actor. ISO8601DateFormatter is documented
    // thread-safe, so a single nonisolated instance is safe to reuse instead of allocating a
    // fresh formatter per call. Kept separate from the instance-scoped `iso8601Formatter` lazy
    // var above, which isn't reachable from these static/nonisolated contexts.
    nonisolated(unsafe) private static let staticISO8601Formatter = ISO8601DateFormatter()

    /// Builds attention alerts for a device from its overview payload — used for both the local and
    /// remote devices so alerts aggregate identically across the sidebar without the client ever
    /// opening `spaces.db`. Window-role styling (browser/editor icons, per-window focus) is
    /// intentionally absent: desktop windows are client-local and not part of the daemon overview,
    /// so an exited process shows as a process alert and clicking it focuses the process. Recency
    /// (and dismissal identity) come from the daemon-supplied `exitedAt`/`updatedAt` timestamps.
    nonisolated static func buildOverviewAlertsGroups(from overview: SpacesDeviceOverviewPayload, deviceID: String) -> [AlertsGroup] {
        let iso8601Formatter = staticISO8601Formatter
        var groups: [AlertsGroup] = []
        for workspace in overview.workspaces {
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
                // Both states keep the cpu.fill agent identity; the tint alone carries the state —
                // `waiting` (blocked on the user) is the warning orange, `done` the success green
                // matching the status dots — so a finished agent doesn't read as still needing attention.
                let iconTint: AlertsIconTint = agent.activityState == .done ? .success : .warning
                items.append(
                    AlertsAttentionEntry(
                        attentionID: "alert:\(deviceID):agent:\(agent.agentID ?? agent.id):\(agent.activityState.rawValue):\(agent.updatedAt ?? "")",
                        icon: "cpu.fill", iconTint: iconTint, label: agent.name, detail: nil, shortcut: "", processStatus: nil,
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
            // Every session with a bell gets an entry, including one the user is looking at right now:
            // suppressing the focused session's bell is a consumption, not a filter (see
            // `AlertsController.consumeFocusedSessionBellAlerts`), and consumption needs the entry to
            // exist so its identity can be recorded and kept alive by the dismissal pruning rule.
            for session in overview.sessions where session.workspaceID == workspace.id {
                guard let bellAt = session.bellAt else { continue }
                // Not `iso8601Formatter`: a Linux daemon stamps runtime state with fractional seconds,
                // which the framework's default format rejects, and the age is the only recency this row
                // carries.
                let eventDate = GhosttyRemoteSessionStateTimestamp.date(from: bellAt)
                items.append(
                    AlertsAttentionEntry(
                        attentionID: "alert:\(deviceID):session:\(session.id):bell:\(bellAt)", icon: "terminal", iconTint: .terminal,
                        // The row reads exactly as the session's sidebar row does — name, then what the
                        // program is doing — because its presence under Alerts is what says the bell rang.
                        label: session.title, detail: session.liveTitle, shortcut: "", processStatus: nil, agentStatus: nil, countsTowardBadge: true,
                        eventDate: eventDate, focusRequest: .terminalSession(workspaceID: workspace.id, sessionID: session.id)))
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
                // fails writing the paired-device record or saving stored credentials is a real error, not
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
                    localOverview = SpacesDeviceOverviewPayload.offlinePlaceholder
                    localOfflineMessage = bootstrapOfflineMessage
                } else {
                    do {
                        let localResolution = try SpacesDeviceClient.resolveOverview(device: localDevice, clientApp: deviceClientApp)
                        localDaemonStatus = localResolution.daemonStatus
                        localCompatibility = localResolution.compatibility
                        // A blocked (incompatible) device has no decodable overview to show; render the block
                        // from an empty snapshot instead.
                        localOverview = localResolution.overview?.overview ?? SpacesDeviceOverviewPayload.offlinePlaceholder
                        localOfflineMessage = nil
                    } catch {
                        // Only a reachability failure degrades to offline. An error from a reachable daemon
                        // (a database/migration failure, an authorization rejection, a malformed overview)
                        // must surface through the snapshot's failure path, not be hidden behind the offline
                        // sidebar/restart flow.
                        guard SpacesDeviceClient.isLocalDaemonUnreachableError(error) else { throw error }
                        localDaemonStatus = nil
                        localCompatibility = nil
                        localOverview = SpacesDeviceOverviewPayload.offlinePlaceholder
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
            // `label` is the row's display name and may be a rename the user typed; only a configured row's
            // name is a launcher name, so only that row carries `claimedLauncherName`. See the launcher
            // matching in `resolvedCodingAgentRunEntries` for why the distinction matters.
            return AgentWindowRecord(
                id: row.agentID ?? row.id, workspaceID: row.workspaceID, provider: .spaces, label: row.name,
                terminalTarget: row.sessionID.map { TerminalTargetRecord(trackingID: $0) }, claimedLauncherID: row.launcherID,
                claimedLauncherName: row.isConfigured ? row.name : nil, status: agentStatus(from: row.activityState), createdAt: now, updatedAt: now)
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

    struct WorkspaceRuntimeTargetIndex: Sendable {
        let orderedTargets: [WorkspaceRunShortcutTarget]
        let targetsByProcessID: [String: WorkspaceRunShortcutTarget]
        let targetsByTerminalSessionID: [String: WorkspaceRunShortcutTarget]
        let targetsByAgentID: [String: WorkspaceRunShortcutTarget]
        let targetsByURL: [String: WorkspaceRunShortcutTarget]
        let shortcutIndices: WorkspaceDetailShortcutIndices

        init(
            browserSessions: [BrowserSession], processEntries: [WorkspaceRunProcessEntry], processesByID: [String: RunningProcessRecord],
            configuredAgentLaunchers: [AgentLauncher], agentWindows: [AgentWindowRecord]
        ) {
            let orderedTargets = AppKitController.orderedWorkspaceRunShortcutTargets(
                browserSessions: browserSessions, processEntries: processEntries, processesByID: processesByID,
                configuredAgentLaunchers: configuredAgentLaunchers, agentWindows: agentWindows)
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
                case .agentLauncher:
                    if let launcherName = target.launcherName, !launcherName.isEmpty, index <= 10 {
                        codingAgentsByName[launcherName] = index
                        codingAgentsByIdentity[AppKitController.codingAgentShortcutIdentity(launcherName: launcherName)] = index
                    }
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

    /// Whether saving a project's settings should sync the template to its workspaces. A non-git
    /// project stands in for its single workspace, so it always syncs (the edits are the config that
    /// runs); a git project syncs only when a pending import chose Update All Workspaces.
    static func projectSaveSyncsAllWorkspaces(isGitRepo: Bool, pendingImportUpdateAllWorkspaces: Bool) -> Bool {
        !isGitRepo || pendingImportUpdateAllWorkspaces
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
        //
        // Launcher association is the daemon's call, so matching only reads the identifiers the daemon
        // assigned: `claimedLauncherID`, and `claimedLauncherName`, which the daemon's rows carry only
        // when the row is a configured launcher's row. Display names are never matched: an unconfigured
        // row's name is whatever the user renamed it to, and renaming an agent to "codex" must not hand
        // it the "codex" launcher's slot.
        for launcher in configuredAgentLaunchers {
            let normalizedName = normalizedRunRowName(launcher.name)
            guard !normalizedName.isEmpty else { continue }
            let matchedAgent = agentWindows.first(where: { agentWindow in
                if agentWindow.claimedLauncherID == launcher.id { return true }
                guard agentWindow.claimedLauncherID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false else { return false }
                return normalizedRunRowName(agentWindow.claimedLauncherName ?? "") == normalizedName
            })
            entries.append(ResolvedCodingAgentRunEntry(launcher: launcher, agentWindow: matchedAgent))
        }

        for agentWindow in agentWindows {
            if let claimedLauncherID = agentWindow.claimedLauncherID?.trimmingCharacters(in: .whitespacesAndNewlines), !claimedLauncherID.isEmpty {
                if configuredAgentIDs.contains(claimedLauncherID) { continue }
            } else {
                guard !configuredAgentNames.contains(normalizedRunRowName(agentWindow.claimedLauncherName ?? "")) else { continue }
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
        configuredAgentLaunchers: [AgentLauncher], agentWindows: [AgentWindowRecord]
    ) -> [WorkspaceRunShortcutTarget] {
        var targets: [WorkspaceRunShortcutTarget] = []

        for session in browserSessions {
            guard let targetURL = session.url, !targetURL.isEmpty else { continue }
            targets.append(
                WorkspaceRunShortcutTarget(
                    kind: .browser, processID: nil, windowListIndex: nil, targetURL: targetURL, processKey: nil, launcherName: nil, agentWindow: nil))
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
                        kind: .process, processID: processID, windowListIndex: nil, targetURL: nil, processKey: nil, launcherName: nil,
                        agentWindow: nil))
            case .missingConfiguredProcess:
                guard let processKey = entry.processKey else { continue }
                targets.append(
                    WorkspaceRunShortcutTarget(
                        kind: .missingConfiguredProcess, processID: nil, windowListIndex: nil, targetURL: nil, processKey: processKey,
                        launcherName: nil, agentWindow: nil))
            case .window: continue
            }
        }

        for entry in resolvedCodingAgentRunEntries(configuredAgentLaunchers: configuredAgentLaunchers, agentWindows: agentWindows) {
            targets.append(
                WorkspaceRunShortcutTarget(
                    kind: entry.kind, processID: nil, windowListIndex: nil, targetURL: nil, processKey: nil,
                    launcherName: entry.agentWindow == nil ? entry.launcherName : nil, agentWindow: entry.agentWindow))
        }

        for entry in processEntries {
            guard case .window = entry.kind, let windowListIndex = entry.windowListIndex else { continue }
            targets.append(
                WorkspaceRunShortcutTarget(
                    kind: .window, processID: nil, windowListIndex: windowListIndex, targetURL: nil, processKey: nil, launcherName: nil,
                    agentWindow: nil))
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
            browserSessions: browserSessions, processEntries: processEntries, processesByID: processesByID,
            configuredAgentLaunchers: settings.agentLaunchers, agentWindows: agentWindows
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
        workspaceRuntimeTargetIndex(
            browserSessions: browserSessions, processEntries: processEntries, processesByID: processesByID,
            configuredAgentLaunchers: configuredAgentLaunchers, agentWindows: agentWindows
        ).shortcutIndices
    }

    nonisolated static func workspaceRuntimeTargetIndex(
        browserSessions: [BrowserSession], processEntries: [WorkspaceRunProcessEntry], processesByID: [String: RunningProcessRecord],
        configuredAgentLaunchers: [AgentLauncher], agentWindows: [AgentWindowRecord]
    ) -> WorkspaceRuntimeTargetIndex {
        WorkspaceRuntimeTargetIndex(
            browserSessions: browserSessions, processEntries: processEntries, processesByID: processesByID,
            configuredAgentLaunchers: configuredAgentLaunchers, agentWindows: agentWindows)
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
    private func focusedTerminalPaneContentForMenuAction() -> (any TerminalPaneContentHosting)? {
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
        window.backgroundColor = sidebarPanelBackgroundColor()
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
        bindAppearanceReactiveLayer(container) { [weak self] view in view.layer?.backgroundColor = self?.sidebarPanelBackgroundColor().cgColor }

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

        let alertsRow = sidebar.makeAlertsSidebarRow()
        alertsRow.translatesAutoresizingMaskIntoConstraints = false

        // The app identity row (logo, name, devices/settings/reload) is the sidebar's
        // footer; the Alerts row leads the content, which starts just below the
        // titlebar strip.
        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(alertsRow)
        container.addSubview(sectionHeader)
        container.addSubview(scroll)
        container.addSubview(footerSeparator)
        container.addSubview(topBarRow)

        NSLayoutConstraint.activate([
            alertsRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            alertsRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            alertsRow.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),

            sectionHeader.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            sectionHeader.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            sectionHeader.topAnchor.constraint(equalTo: alertsRow.bottomAnchor, constant: 10),

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

    // MARK: - Alerts forwarders
    // Thin pass-throughs that keep widely-used alerts entry points callable from
    // host and sidebar code. The implementations live on `alerts` (AlertsController).
    func alertsAttentionCount() -> Int { alerts.alertsAttentionCount() }
    func loadAlertsDismissedAttentionItemIDs() { alerts.loadAlertsDismissedAttentionItemIDs() }
    func pruneDismissedAlertsAttentionItemIDsIfNeeded() { alerts.pruneDismissedAlertsAttentionItemIDsIfNeeded() }
    func consumeFocusedSessionBellAlerts() { alerts.consumeFocusedSessionBellAlerts() }
    func showAlertsDetail(presentation: DetailPanePresentation = .backgroundRefresh) { alerts.showAlertsDetail(presentation: presentation) }

    private func makeRightPane() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        bindAppearanceReactiveLayer(container) { [weak self] view in view.layer?.backgroundColor = self?.sidebarPanelBackgroundColor().cgColor }

        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.wantsLayer = true
        bindAppearanceReactiveLayer(detailContainer) { [weak self] view in view.layer?.backgroundColor = self?.sidebarPanelBackgroundColor().cgColor }

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
    func updateAlertsRowAppearance() { sidebar.updateAlertsRowAppearance() }
    func refreshSidebarSelectionRows(previousProjectID: String?, currentProjectID: String?, previousWorkspaceID: String?, currentWorkspaceID: String?)
    {
        sidebar.refreshSidebarSelectionRows(
            previousProjectID: previousProjectID, currentProjectID: currentProjectID, previousWorkspaceID: previousWorkspaceID,
            currentWorkspaceID: currentWorkspaceID)
    }
    func sidebarPanelBackgroundColor() -> NSColor { sidebar.sidebarPanelBackgroundColor() }
    func sidebarCardBackgroundColor() -> NSColor { sidebar.sidebarCardBackgroundColor() }
    func sidebarSelectedCardBackgroundColor() -> NSColor { sidebar.sidebarSelectedCardBackgroundColor() }
    func sidebarCardBorderColor(isSelected: Bool) -> NSColor { sidebar.sidebarCardBorderColor(isSelected: isSelected) }
    func sidebarPrimaryTextColor(isSelected: Bool) -> NSColor { sidebar.sidebarPrimaryTextColor(isSelected: isSelected) }
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
        Task.detached(priority: .utility) { [weak self] in
            manager.reconcile(device: device, overview: overview, revision: revision)
            await self?.refreshVisibleServicePortDisplays(deviceID: device.id)
        }
    }

    func stopRemoteBrowserForwards(deviceID: String) {
        guard deviceID != localDeviceID else { return }
        let manager = browserSSHForwardManager
        let revision = nextRemoteBrowserForwardRevision(deviceID: deviceID)
        Task.detached(priority: .utility) { [weak self] in
            manager.stop(deviceID: deviceID, revision: revision)
            await self?.refreshVisibleServicePortDisplays(deviceID: deviceID)
        }
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

    /// The id of the device that owns a workspace/project, or nil when no loaded device
    /// section contains that row. These give every action its per-row device context so it
    /// routes to the daemon that actually hosts the workspace. The miss is deliberately
    /// visible: an unresolved id means "we do not know which daemon owns this", which is
    /// never the same thing as "the local daemon owns this" — resolving it to the local
    /// device would run local endpoints, credentials, paths, and panel state against a
    /// row that lives on another machine.
    func deviceID(forWorkspaceID workspaceID: String) -> String? { findWorkspace(id: workspaceID)?.0.deviceID }

    private func deviceID(forProjectID projectID: String) -> String? { projects.first(where: { $0.id == projectID })?.deviceID }

    private func isRemoteDeviceID(_ deviceID: String) -> Bool {
        deviceSection(id: deviceID).map { !$0.isLocal } ?? (deviceID != SpacesPairedDeviceRecord.localDeviceID)
    }

    func isLocalWorkspace(_ workspace: WorkspaceSummary) -> Bool { workspace.deviceID == SpacesPairedDeviceRecord.localDeviceID }

    /// Hides a workspace from the sidebar (stopping it first if it is running), routed through the
    /// workspace-visibility controller so the sidebar row's right-click menu and the visibility
    /// dialog share one hide path. The sidebar refreshes from the mutation response, so no explicit
    /// reload callback is needed here.
    func hideWorkspace(id: String) { workspaceVisibility.hideWorkspace(workspaceID: id) }

    /// The device that owns the current selection, so mutations route to the
    /// daemon that actually hosts the selected workspace/project rather than
    /// always defaulting to the local device.
    private func selectedRowDeviceID() -> String? {
        if let selectedWorkspaceID, let (project, _) = findWorkspace(id: selectedWorkspaceID) { return project.deviceID }
        if let selectedProjectID, let project = projects.first(where: { $0.id == selectedProjectID }) { return project.deviceID }
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
        if deviceID == SpacesPairedDeviceRecord.localDeviceID { return localPairedDevice }
        return deviceRecord(forDeviceID: deviceID)
    }

    /// Resolves the paired-device record for a mutation target by owning-device id, refusing any
    /// device that cannot service a daemon-backed action. An unreachable device keeps its section
    /// (and therefore its record) for the whole outage so its rows stay browsable, so resolution
    /// alone is not permission to act: this is the chokepoint where "browse, don't act" is enforced,
    /// and every caller surfaces the nil as an error rather than dialling a daemon that is not there.
    /// Nil therefore means either that no loaded section claims the id (unknown or still loading) or
    /// that its device is unreachable; `deviceUnavailableError` tells those two apart for the message.
    private func deviceForMutation(deviceID: String) -> SpacesPairedDeviceRecord? {
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

    /// Whether a terminal target may be acted on at all, given whether its session already occupies a
    /// pane and whether its owning device can service daemon-backed work. This is the line between the
    /// two operations `openOrFocusTerminalPane` performs.
    ///
    /// Focusing a pane that already exists is client-side: the pane owns its state model and renders
    /// its own disconnected notice, so an unreachable device never withholds it — an open pane on a
    /// device that dropped is exactly what that notice is for. Installing a pane the layout does not
    /// have yet can only work by attaching to the owning daemon, so it is refused while that device
    /// cannot act — and refused *before* the install, because installing adds the pane to the layout
    /// and persists it before credentials are prepared: a pane admitted here would be saved as
    /// permanently failed and would not retry when the device came back. Pure so the
    /// "focus, don't open" line is directly testable.
    nonisolated static func canOpenOrFocusTerminalPane(hasExistingPane: Bool, deviceAcceptsDaemonActions: Bool) -> Bool {
        hasExistingPane || deviceAcceptsDaemonActions
    }

    /// Whether re-showing a session can stop at foregrounding its panel and restoring the caret, instead of
    /// running the open path's state fetch, attach, and ownership reclaim. All three conditions are load
    /// bearing: the pane must be the focused one in the panel's selected tab (anything else has to move
    /// focus, which re-activates the content), and it must already hold the owner attachment on a live
    /// surface — when another client owns the session, reclaiming ownership is the whole request. Pure so
    /// the line between "already here" and "go get it" is directly testable.
    nonisolated static func canRefocusTerminalPaneWithoutReattaching(
        paneIsFocused: Bool, paneIsInSelectedTab: Bool, paneHoldsOwnerAttachedSurface: Bool
    ) -> Bool { paneIsFocused && paneIsInSelectedTab && paneHoldsOwnerAttachedSurface }

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
    /// daemon-backed controls are now wrong.
    func visibleWorkspaceDetailDeviceID() -> String? { visibleDetailWorkspaceID.flatMap(deviceID(forWorkspaceID:)) }

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

    private static func deviceNotLoadedError() -> NSError {
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
    private func deviceUnavailableError(deviceID: String?) -> NSError {
        guard let deviceID, let section = deviceSection(id: deviceID), section.loadState.isOffline else { return Self.deviceNotLoadedError() }
        return Self.deviceUnreachableError(deviceName: section.displayName, isLocal: section.isLocal)
    }

    /// Surfaces why a per-workspace daemon action could not resolve its device.
    func showWorkspaceDeviceUnavailableError(workspaceID: String) {
        showError(deviceUnavailableError(deviceID: deviceID(forWorkspaceID: workspaceID)))
    }

    /// Surfaces why a pane could not be opened for a terminal target, naming the device the request
    /// pinned rather than re-deriving it from a workspace the sidebar may not list.
    func showTerminalOpenRequestDeviceUnavailableError(_ request: DeviceTerminalOpenRequest) {
        showError(deviceUnavailableError(deviceID: request.deviceID ?? deviceID(forWorkspaceID: request.workspaceID)))
    }

    /// Surfaces why a selection-driven daemon action could not resolve its device.
    func showSelectedDeviceUnavailableError() {
        showError(deviceUnavailableError(deviceID: selectedRowDeviceID() ?? SpacesPairedDeviceRecord.localDeviceID))
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
        _ overview: SpacesDeviceOverviewPayload, deviceID: String, selectedProjectID preferredProjectID: String? = nil,
        selectedWorkspaceID preferredWorkspaceID: String? = nil, preserveDetailPane: Bool = false
    ) {
        let shouldPreserveDetailPane = preserveDetailPane && canPreserveDetailPaneAfterSidebarReload()
        // The mutation's overview belongs to the device that issued it (`deviceID`, threaded from the
        // call site). Update only that device's section and re-merge so the other devices' rows stay
        // intact. The originating device is passed explicitly rather than inferred from the current
        // selection: a mutation that clears the selection (e.g. a remote project delete) would
        // otherwise fall through to the local device and install a remote overview — and its
        // pane-prune keep-set — into the local section.
        let collapseStates = (try? SpacesClientDatabase.defaultDatabase().projectCollapseStates(deviceID: deviceID)) ?? [:]
        let mapped = Self.deviceSidebarData(from: overview, deviceID: deviceID, projectCollapseStates: collapseStates)
        if let index = deviceSections.firstIndex(where: { $0.deviceID == deviceID }) {
            deviceSections[index].projects = mapped.projects
            deviceSections[index].workspacesByProject = mapped.workspacesByProject
            deviceSections[index].workspaceRuntimeStatusByID = mapped.workspaceRuntimeStatusByID
            deviceSections[index].overview = overview
            if deviceSections[index].isLocal {
                deviceSections[index].alertsGroups = Self.buildOverviewAlertsGroups(from: overview, deviceID: deviceID)
            }
        }
        // This is an authoritative overview for `deviceID`: close any open pane whose session it no
        // longer retains (its product row was removed, possibly from another device), so the pane cannot
        // outlive the daemon's transcript garbage-collection. The keep-set is the daemon's own published
        // retention rule (`overview.retainedTerminalSessionIDs`), so an ended session still held by any
        // product row — including a `runtime_targets` row after its shell exits — stays open for scrollback.
        panelCoordinator.pruneOpenPanes(deviceID: deviceID, catalogSessionIDs: OpenPanePruning.referencedTerminalSessionIDs(overview: overview))
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
        fullReloadSidebarOutline()
        if !shouldPreserveDetailPane { refreshSelection() }
        updateAlertsSidebarBadge()
        if showingAlerts { showAlertsDetail() }
    }

    func applyDeviceMutationResponse(
        _ response: SpacesDeviceAPIResponse, deviceID: String, selectedProjectID preferredProjectID: String? = nil,
        selectedWorkspaceID preferredWorkspaceID: String? = nil
    ) {
        if let overview = response.overview {
            applyDeviceOverview(
                overview, deviceID: deviceID, selectedProjectID: preferredProjectID, selectedWorkspaceID: preferredWorkspaceID,
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
        let response = try SpacesDeviceClient.updateWorkspaceConfig(
            workspaceID: workspaceID,
            config: Self.deviceWorkspaceConfig(from: settings, resolvedBrowserSessions: workspace.config.resolvedBrowserSessions), device: device,
            clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
        applyDeviceMutationResponse(response, deviceID: device.id, selectedWorkspaceID: workspaceID)
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
            clearActiveAddFormStateAndCloseWindows()
        }
        detailPane = pane
        if pane.workspaceID == nil { hideWorkspacePanelTabStrip() }
        if pane.compatibilityBlockDeviceID == nil { visibleCompatibilityBlockRemedy = nil }
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
        activeShortcutCaptureSetting = nil
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

    /// What `reconcileCompatibilityBlock` should do with the visible compatibility block for the device
    /// whose verdict/status just changed: drop it (the device needs no block any more), rebuild it with a
    /// different remedy (the device still needs a block, but the wire facts driving its copy/action have
    /// moved on), or leave the rendered block exactly as it is.
    enum CompatibilityBlockReconciliation: Equatable {
        case clear
        case rerender(CompatibilityBlockView.BlockRemedy)
        case leaveAlone
    }

    /// Pure "should the visible compatibility block change" decision, factored out so it is testable
    /// without AppKit. `isVisibleBlockDevice` mirrors the identity check every caller needs — a device
    /// that doesn't own the currently-rendered block never touches it. Otherwise this always re-derives
    /// the remedy through `CompatibilityBlockView.blockRemedy(verdict:status:)`, the same function
    /// `showCompatibilityBlock` renders from, so the two can never disagree about what a given
    /// verdict/status pair means: a `nil` verdict (unknown/offline) or a compatible verdict both produce
    /// no remedy and therefore `.clear`.
    nonisolated static func reconcileCompatibilityBlockAction(
        isVisibleBlockDevice: Bool, renderedRemedy: CompatibilityBlockView.BlockRemedy, verdict: SpacesWireCompatibility?,
        status: TerminalServiceDaemonStatus?
    ) -> CompatibilityBlockReconciliation {
        guard isVisibleBlockDevice else { return .leaveAlone }
        guard let verdict, let newRemedy = CompatibilityBlockView.blockRemedy(verdict: verdict, status: status) else { return .clear }
        return newRemedy == renderedRemedy ? .leaveAlone : .rerender(newRemedy)
    }

    /// Reconciles the visible compatibility block (if any) against `deviceID`'s current verdict/status:
    /// drops an obsolete block and re-resolves the detail pane once the device is compatible again (e.g.
    /// after a restart updated its daemon), or re-renders the block once the device still needs one but
    /// under a different remedy (e.g. a too-old daemon with nothing staged now reports a staged update —
    /// the block must switch from "install it on that Mac" to "Update Daemon" without the user having to
    /// navigate away and back). Called from every apply path after a reload updates a section's
    /// verdict/status. See `reconcileCompatibilityBlockAction` for the pure decision.
    func reconcileCompatibilityBlock(deviceID: String) {
        let verdict = deviceCompatibility(forDeviceID: deviceID)
        let status = deviceDaemonStatus(forDeviceID: deviceID)
        // Runs ahead of the visible-block guard: an SSH update started from the block outlives whatever
        // the detail pane is showing, so the in-progress entry has to be retired from the device's own
        // facts rather than from the pane's. Only a verdict that resolves to something other than
        // "install an update on that device" clears it — an absent verdict is the device being offline,
        // which is exactly what a daemon mid-handoff looks like.
        if let verdict, CompatibilityBlockView.blockRemedy(verdict: verdict, status: status)?.isInstallUpdateOnDevice != true {
            daemonSSHUpdateInProgressDeviceIDs.remove(deviceID)
        }
        guard let renderedRemedy = visibleCompatibilityBlockRemedy else { return }
        let action = Self.reconcileCompatibilityBlockAction(
            isVisibleBlockDevice: visibleCompatibilityBlockDeviceID == deviceID, renderedRemedy: renderedRemedy, verdict: verdict, status: status)
        switch action {
        case .leaveAlone: return
        case .clear:
            // The block was established above to be this device's, so clearing it leaves the pane empty
            // until `refreshSelection` re-resolves it.
            presentDetailPane(.none)
            refreshSelection()
        case .rerender:
            // `verdict` is guaranteed non-nil here: `.rerender` only comes from `blockRemedy` returning a
            // remedy, which itself requires a non-optional verdict.
            guard let verdict else { return }
            showCompatibilityBlock(deviceID: deviceID, verdict: verdict)
        }
    }

    /// Renders the full-pane compatibility block for an incompatible device, with the restart-impact
    /// report and a restart action. Switching to a compatible device in the sidebar leaves it.
    func showCompatibilityBlock(deviceID: String, verdict: SpacesWireCompatibility, presentation: DetailPanePresentation = .backgroundRefresh) {
        let status = deviceDaemonStatus(forDeviceID: deviceID)
        guard let remedy = CompatibilityBlockView.blockRemedy(verdict: verdict, status: status) else {
            // A device with no remedy needs no block — leave the detail pane exactly as it is rather
            // than clearing it out for a card that would have nothing to say.
            return
        }
        visibleCompatibilityBlockRemedy = remedy

        stopWorkspaceSetupDetailRefreshTimer()
        presentDetailPane(.compatibilityBlock(deviceID: deviceID), presentation: presentation)
        showingSettings = false
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

        let isLocalDevice = deviceID == SpacesPairedDeviceRecord.localDeviceID
        let offersCheckForUpdates = Self.shouldOfferCheckForUpdatesAction(isLocalDevice: isLocalDevice, updaterAvailable: updaterController != nil)
        let canUpdateOverSSH = Self.shouldOfferUpdateOverSSH(
            isLocalDevice: isLocalDevice, isLinuxDaemon: status?.isLinuxDaemon == true,
            hasSSHDetails: Self.hasSSHDetails(deviceRecord(forDeviceID: deviceID)))
        let card = CompatibilityBlockView(
            remedy: remedy, deviceName: deviceSection(id: deviceID)?.deviceName ?? deviceID, isLocalDevice: isLocalDevice,
            isLinuxDaemon: status?.isLinuxDaemon == true, canUpdateOverSSH: canUpdateOverSSH,
            isUpdatingOverSSH: daemonSSHUpdateInProgressDeviceIDs.contains(deviceID),
            onRestart: remedy.offersDaemonUpdateAction ? { [weak self] in self?.requestDaemonRestart(deviceID: deviceID) } : nil,
            onCheckForUpdates: offersCheckForUpdates ? { [weak self] in self?.updaterController?.checkForUpdates(nil) } : nil,
            onUpdateOverSSH: canUpdateOverSSH ? { [weak self] in self?.updateRemoteDaemonOverSSH(deviceID: deviceID) } : nil)
        card.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: detailContainer.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: detailContainer.centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: detailContainer.leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(lessThanOrEqualTo: detailContainer.trailingAnchor, constant: -24),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])
    }

    /// Requests the device's daemon exec-in-place handoff through the `requestDaemonRestart` RPC (the
    /// daemon quiesces sessions, applies any update staged on disk, and re-execs at the same pid, so
    /// running terminals, agents, and processes survive), then reloads the sidebar after a short delay
    /// so the app re-handshakes against the new build. Shared by the compatibility block's Restart
    /// button, which reports RPC failures, and `maybeRequestSilentDaemonHandoff`, which stays silent —
    /// the only two daemon-restart entry points. A remote Linux daemon too old for this app has nothing
    /// staged to restart into, so it is updated by re-running the version-pinned installer instead:
    /// `updateRemoteDaemonOverSSH` runs it from here for a device whose pairing stored SSH details, and
    /// the compatibility block's copyable one-liner covers a device without them. Either way the
    /// installer pokes the live daemon for the same in-place handoff this RPC triggers.
    private func fireDaemonRestartRequest(device: SpacesPairedDeviceRecord, reportsFailure: Bool) {
        Task { @MainActor [weak self] in
            do { _ = try await Task.detached(priority: .userInitiated) { try SpacesDeviceClient.requestDaemonRestart(device: device) }.value } catch {
                guard let self else { return }
                if reportsFailure { self.showError(error) }
                return
            }
            guard let self else { return }
            // Give the daemon a moment to complete the handoff, then re-handshake.
            try? await Task.sleep(for: .seconds(2))
            self.requestSidebarReload(forceRemoteRefresh: true)
        }
    }

    /// The compatibility block's explicit Restart button: user-initiated, so an unresolved device
    /// record or a failed RPC is a visible error rather than a silent no-op.
    private func requestDaemonRestart(deviceID: String) {
        guard let device = deviceRecord(forDeviceID: deviceID) else {
            showDeviceNotLoadedError()
            return
        }
        fireDaemonRestartRequest(device: device, reportsFailure: true)
    }

    /// Pure fire/skip decision for the silent daemon-handoff trigger, factored out so it is testable
    /// without a device record or the RPC: fire only when the daemon reports a staged update, the
    /// daemon speaks a wire protocol this app can talk to (an incompatible daemon is handled by the
    /// compatibility block, not a silent restart), and this exact device/staged-version pair has not
    /// already been requested.
    nonisolated static func shouldFireSilentDaemonHandoff(updatePending: Bool, compatibilityIsCompatible: Bool, alreadyRequestedKey: Bool) -> Bool {
        updatePending && compatibilityIsCompatible && !alreadyRequestedKey
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
    private nonisolated static func hasSSHDetails(_ device: SpacesPairedDeviceRecord?) -> Bool {
        guard let host = device?.sshHost else { return false }
        return !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The compatibility block's "Update over SSH" action: runs the version-pinned Linux installer on the
    /// device over SSH, which lands the new release and pokes the live daemon into an in-place handoff, so
    /// the device's terminals, agents, and processes survive the update. User-initiated, so a missing
    /// record and a failed installer run are both visible errors rather than silent no-ops.
    private func updateRemoteDaemonOverSSH(deviceID: String) {
        guard let device = deviceRecord(forDeviceID: deviceID), Self.hasSSHDetails(device) else {
            showDeviceNotLoadedError()
            return
        }
        guard !daemonSSHUpdateInProgressDeviceIDs.contains(deviceID) else { return }
        daemonSSHUpdateInProgressDeviceIDs.insert(deviceID)
        rerenderCompatibilityBlockIfVisible(deviceID: deviceID)
        Task { @MainActor [weak self] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try SpacesDevicePairingClient.updateSpacesOnRemoteDevice(device: device, appVersion: AppVersion.short)
                }.value
            } catch {
                guard let self else { return }
                self.daemonSSHUpdateInProgressDeviceIDs.remove(deviceID)
                self.rerenderCompatibilityBlockIfVisible(deviceID: deviceID)
                self.showError(error)
                return
            }
            guard let self else { return }
            // Deliberately does not clear the in-progress entry: the installer returns as soon as the
            // daemon accepts the handoff, and for the moments it spends re-execing and replaying sessions
            // it still answers with the old wire version. Dropping the spinner here would put the
            // "Update over SSH" button back mid-update and invite a second run. `reconcileCompatibilityBlock`
            // retires the entry from the device's own next verdict instead.
            try? await Task.sleep(for: .seconds(2))
            self.requestSidebarReload(forceRemoteRefresh: true)
        }
    }

    /// Re-renders the compatibility block for `deviceID` when that block is the one on screen, so a
    /// change in this app's own in-progress state reaches the card without disturbing whatever the user
    /// navigated to instead.
    private func rerenderCompatibilityBlockIfVisible(deviceID: String) {
        guard visibleCompatibilityBlockDeviceID == deviceID, let verdict = deviceCompatibility(forDeviceID: deviceID) else { return }
        showCompatibilityBlock(deviceID: deviceID, verdict: verdict)
    }

    /// Drops any Update-over-SSH in-progress state for a device the app is about to stop tracking, so a
    /// later pairing of the same device cannot inherit a spinner from a run that is no longer observable.
    func forgetDaemonSSHUpdateProgress(deviceID: String) { daemonSSHUpdateInProgressDeviceIDs.remove(deviceID) }

    /// Silently requests a daemon exec-in-place handoff when a compatible daemon reports a staged
    /// update (`isUpdatePending` — the daemon's own installed-vs-running comparison; never this app's
    /// build version), instead of waiting for the daemon's own next restart. Called from every path
    /// where a fresh `TerminalServiceDaemonStatus` lands for a device (local snapshot apply, remote
    /// pull, remote push subscription). Deduped per (deviceID, staged version) for the app's lifetime
    /// so a failed or refused handoff is not retried on every subsequent status refresh; the "update
    /// pending" sidebar caption stays visible until the daemon actually comes back on the new build.
    func maybeRequestSilentDaemonHandoff(deviceID: String, status: TerminalServiceDaemonStatus?) {
        guard let status, let stagedVersion = status.installedVersion else { return }
        let key = "\(deviceID)|\(stagedVersion)"
        guard
            Self.shouldFireSilentDaemonHandoff(
                updatePending: status.isUpdatePending, compatibilityIsCompatible: SpacesWireCompatibility.evaluate(daemonStatus: status).isCompatible,
                alreadyRequestedKey: silentDaemonHandoffRequestedKeys.contains(key))
        else { return }
        silentDaemonHandoffRequestedKeys.insert(key)
        guard let device = deviceRecord(forDeviceID: deviceID) else { return }
        fireDaemonRestartRequest(device: device, reportsFailure: false)
    }

    private func showLoadingPlaceholder(message: String, detail: String?) {
        stopWorkspaceSetupDetailRefreshTimer()
        // A visible compatibility block survives the loading placeholder: the reload behind this loading
        // state re-resolves back to the block. Only a workspace or alerts pane is cleared.
        if case .compatibilityBlock = detailPane {} else { presentDetailPane(.none) }
        showingSettings = false
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
            view.layer?.backgroundColor = self?.sidebarCardBorderColor(isSelected: false).cgColor
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
        if closingWindow === addProjectWindow {
            clearActiveAddProjectFormState()
            return
        }
        if closingWindow === addWorkspaceWindow {
            clearActiveAddWorkspaceFormState()
            return
        }
        if closingWindow === projectSettingsWindow {
            projectSettingsFieldRefs = nil
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

    func settingsLabeledField(name: String, hint: String, control: NSView) -> NSView {
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = Typography.rowLabel

        let hintLabel = NSTextField(labelWithString: hint)
        hintLabel.font = Typography.metadata
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
        nameLabel.font = Typography.rowLabel

        let hintLabel = NSTextField(labelWithString: hint)
        hintLabel.font = Typography.metadata
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
        container.layer?.masksToBounds = true
        bindAppearanceReactiveLayer(container) { [weak self] view in view.layer?.borderColor = self?.sidebarCardBorderColor(isSelected: false).cgColor
        }

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
                bindAppearanceReactiveLayer(sep) { [weak self] view in
                    view.layer?.backgroundColor = self?.sidebarCardBorderColor(isSelected: false).withAlphaComponent(0.5).cgColor
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

            let captureButton = NSButton(title: "", target: self, action: #selector(beginShortcutCapture(_:)))
            captureButton.identifier = NSUserInterfaceItemIdentifier(setting.settingKey)
            captureButton.isBordered = false
            captureButton.alignment = .center
            captureButton.font = Typography.monoBody
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
        dirField.font = Typography.monoMetadata
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
            value: projectSettings.setupScript ?? "", subtitle: "Runs when each new workspace is created.")
        let stopScriptSection = ScriptSection(
            title: "Stop Script", editAccessibilityIdentifier: "stop-script-edit", formAccessibilityPrefix: "workspace-stop-script",
            value: projectSettings.stopScript ?? "", subtitle: "Runs after processes stop — on stop, restart, and delete.")
        let portsSection = PortsSection(
            ports: projectSettings.ports, subtitle: "Per-workspace services, routed through Caddy.", showsEnvironmentVariableHints: true)
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
        titleLabel.font = Typography.cardTitle
        titleLabel.textColor = .labelColor

        let subtitleLabel = NSTextField(labelWithString: subtitle)
        subtitleLabel.font = Typography.rowDetail
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
        bindAppearanceReactiveLayer(divider) { [weak self] view in
            view.layer?.backgroundColor = self?.sidebarCardBorderColor(isSelected: false).withAlphaComponent(0.55).cgColor
        }

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
        titleLabel.font = Typography.sectionTitle
        titleLabel.textColor = Theme.text

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 2
        titleStack.addArrangedSubview(titleLabel)
        if !subtitle.isEmpty {
            let subtitleLabel = NSTextField(labelWithString: subtitle)
            subtitleLabel.font = Typography.metadata
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

    /// The New Project title, naming the target device only when there is a choice to disambiguate.
    private func addProjectFlowTitle(deviceID: String) -> String {
        deviceSections.count > 1 ? "New Project · \(deviceDisplayName(id: deviceID))" : "New Project"
    }

    /// Step 2: choose the source — an existing folder or a repository to clone — and its location.
    /// Continue loads the configuration (Step 3). Splitting the source into its own step means it is
    /// fixed before configuration, so there is no source toggle to switch mid-config.
    private func showAddProjectSourceStep(deviceID: String) {
        clearActiveAddProjectFormState()

        let deviceName = deviceDisplayName(id: deviceID)
        let folderRow = addProjectSourceRow(
            icon: "folder", title: "Existing folder", subtitle: "Use a project already on \(deviceName)", accessibilityID: "add-project-source-folder"
        )
        let gitRow = addProjectSourceRow(
            icon: "chevron.left.forwardslash.chevron.right", title: "Clone a repo", subtitle: "Clone a Git repository into ~/spaces/repos",
            accessibilityID: "add-project-source-git")

        let dirField = NSTextField(string: "")
        dirField.placeholderString = "~/projects/my-app"
        dirField.delegate = self
        dirField.setAccessibilityIdentifier("add-project-directory-path")
        let repoURLField = NSTextField(string: "")
        repoURLField.placeholderString = "https://github.com/org/repo.git"
        repoURLField.delegate = self
        repoURLField.setAccessibilityIdentifier("add-project-repo-url")
        let folderInputRow = sourceInputRow(headerText: "Folder path", field: dirField)
        let gitInputRow = sourceInputRow(headerText: "Repository URL", field: repoURLField)
        folderInputRow.isHidden = true
        gitInputRow.isHidden = true

        // Config-step controls are built now and shown after Continue loads the config.
        let (setup, stop, ports, processes, browsers, agents) = makeAddProjectConfigSections()
        let createButton = actionButton(title: "Create", symbol: nil, tooltip: "Create project", action: #selector(createProject(_:)), primary: true)
        let spacesYAMLMissingLabel = NSTextField(
            wrappingLabelWithString: "No spaces.yaml found in this repository. Set up the configuration below as needed.")
        spacesYAMLMissingLabel.font = Typography.rowDetail
        spacesYAMLMissingLabel.textColor = .secondaryLabelColor
        spacesYAMLMissingLabel.setAccessibilityIdentifier("add-project-spaces-yaml-missing")

        let continueButton = actionButton(
            title: "Continue", symbol: nil, tooltip: "Load the project configuration", action: #selector(continueFromSourceStep(_:)), primary: true)
        continueButton.isEnabled = false
        continueButton.setAccessibilityIdentifier("add-project-source-continue")

        let id = storeAddProjectFields(
            folderRow: folderRow, gitRow: gitRow, folderInputRow: folderInputRow, gitInputRow: gitInputRow, dirField: dirField,
            repoURLField: repoURLField, continueButton: continueButton, setupScriptSection: setup, stopScriptSection: stop, portsSection: ports,
            processesSection: processes, browserSessionsSection: browsers, agentLaunchersSection: agents, createButton: createButton,
            spacesYAMLMissingLabel: spacesYAMLMissingLabel)
        activeAddProjectFormTag = id
        guard let refs = addProjectFieldRefs else { return }
        refs.selectedDeviceID = deviceID
        attachAddProjectSourceRowSelection(folderRow, kind: .folder, tag: id)
        attachAddProjectSourceRowSelection(gitRow, kind: .git, tag: id)

        presentAddProjectSourceStep(refs)
    }

    /// Renders the source step from the stored field views and presents it. Used for the initial
    /// presentation and to return to the source step (with the entered values intact) when a load fails
    /// or the managed-directory replacement prompt is declined.
    private func presentAddProjectSourceStep(_ refs: AddProjectFieldRefs) {
        let sourceCard = formSectionCard(
            icon: "folder.badge.plus", title: "Source", subtitle: "Where does your project live?",
            contentViews: [refs.folderRow, refs.gitRow, refs.folderInputRow, refs.gitInputRow])

        let cancelButton = actionButton(title: "Cancel", symbol: nil, tooltip: "Cancel", action: #selector(cancelProjectForm), primary: false)
        Theme.applySecondaryStyle(to: cancelButton)
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.setViews([cancelButton], in: .leading)
        buttonRow.setViews([refs.continueButton], in: .trailing)

        let stack = addProjectStepStack()
        stack.addArrangedSubview(sourceCard)
        stack.addArrangedSubview(buttonRow)
        constrainFormFieldToFillWidth(sourceCard, in: stack)
        constrainFormFieldToFillWidth(buttonRow, in: stack)

        presentAddProjectWindow(hosting: stack, title: addProjectFlowTitle(deviceID: refs.selectedDeviceID))
        updateAddProjectSourceStepUI(refs)
    }

    /// A brief loading step shown while the chosen source's `spaces.yaml` is fetched. It carries no
    /// editable inputs so the source cannot change while the preview is in flight.
    private func presentAddProjectLoadingStep(deviceID: String, detail: String) {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: detail)
        label.font = Typography.rowDetail
        label.textColor = .secondaryLabelColor

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.addArrangedSubview(spinner)
        row.addArrangedSubview(label)

        let card = formSectionCard(icon: "square.and.arrow.down", title: "Loading project settings", subtitle: "", contentViews: [row])

        let cancelButton = actionButton(title: "Cancel", symbol: nil, tooltip: "Cancel", action: #selector(cancelProjectForm), primary: false)
        Theme.applySecondaryStyle(to: cancelButton)
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.setViews([cancelButton], in: .leading)

        let stack = addProjectStepStack()
        stack.addArrangedSubview(card)
        stack.addArrangedSubview(buttonRow)
        constrainFormFieldToFillWidth(card, in: stack)
        constrainFormFieldToFillWidth(buttonRow, in: stack)

        presentAddProjectWindow(hosting: stack, title: addProjectFlowTitle(deviceID: deviceID))
    }

    /// Step 3: review and edit the configuration (loaded from the source on entry) and create.
    private func showAddProjectConfigStep(_ refs: AddProjectFieldRefs) {
        let cancelButton = actionButton(title: "Cancel", symbol: nil, tooltip: "Cancel", action: #selector(cancelProjectForm), primary: false)
        Theme.applySecondaryStyle(to: cancelButton)
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.setViews([cancelButton], in: .leading)
        buttonRow.setViews([refs.createButton], in: .trailing)

        refs.spacesYAMLMissingLabel.isHidden = !refs.spacesYAMLMissing

        let sectionViews = [
            refs.spacesYAMLMissingLabel, refs.setupScriptSection.view, refs.portsSection.view, refs.processesSection.view,
            refs.browserSessionsSection.view, refs.agentLaunchersSection.view, refs.stopScriptSection.view, buttonRow,
        ]
        let stack = addProjectStepStack()
        for view in sectionViews {
            view.isHidden = view === refs.spacesYAMLMissingLabel ? !refs.spacesYAMLMissing : false
            stack.addArrangedSubview(view)
            constrainFormFieldToFillWidth(view, in: stack)
        }

        presentAddProjectWindow(hosting: stack, title: addProjectFlowTitle(deviceID: refs.selectedDeviceID))
        refs.createButton.isEnabled = true
    }

    private func addProjectStepStack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func makeAddProjectConfigSections() -> (
        ScriptSection, ScriptSection, PortsSection, ProcessesSection, BrowserSessionsSection, AgentLaunchersSection
    ) {
        let setupScriptSection = ScriptSection(
            title: "Setup Script", editAccessibilityIdentifier: "setup-script-edit", formAccessibilityPrefix: "project-setup-script", value: "",
            subtitle: "Runs when each new workspace is created.")
        let stopScriptSection = ScriptSection(
            title: "Stop Script", editAccessibilityIdentifier: "stop-script-edit", formAccessibilityPrefix: "workspace-stop-script", value: "",
            subtitle: "Runs after processes stop — on stop, restart, and delete.")
        let portsSection = PortsSection(subtitle: "Per-workspace named ports, exposed as env vars.", showsEnvironmentVariableHints: true)
        let processesSection = ProcessesSection(subtitle: "Commands that run inside the workspace.", showsRuntimeControls: false)
        let browserSessionsSection = BrowserSessionsSection(subtitle: "Named URLs that open in Chrome when you focus them.")
        let agentLaunchersSection = AgentLaunchersSection(subtitle: "Coding agents that open in a Spaces terminal.", showsRuntimeControls: false)
        return (setupScriptSection, stopScriptSection, portsSection, processesSection, browserSessionsSection, agentLaunchersSection)
    }

    /// A left-aligned, hover-highlighted, selectable source row (icon, title, caption). Selecting it
    /// reveals its input below; the highlighted border marks the current choice.
    private func addProjectSourceRow(icon: String, title: String, subtitle: String, accessibilityID: String) -> ClickableRowView {
        let container = ClickableRowView(isInteractive: true)
        container.layer?.borderWidth = 1
        bindAppearanceReactiveLayer(container) { [weak self] view in view.layer?.borderColor = self?.sidebarCardBorderColor(isSelected: false).cgColor
        }
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.button)
        container.setAccessibilityLabel(title)
        container.setAccessibilityIdentifier(accessibilityID)

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        iconView.contentTintColor = sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleField = NSTextField(labelWithString: title)
        titleField.font = Typography.sectionTitle
        titleField.textColor = .labelColor
        let captionField = NSTextField(labelWithString: subtitle)
        captionField.font = Typography.metadata
        captionField.textColor = .secondaryLabelColor
        captionField.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [titleField, captionField])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        let row = NSStackView(views: [iconView, textStack, NSView()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor), row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor), row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        return container
    }

    private func sourceInputRow(headerText: String, field: NSTextField) -> NSView {
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [makeFieldHeader(headerText), field])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.detachesHiddenViews = true
        field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func attachAddProjectSourceRowSelection(_ row: ClickableRowView, kind: AddProjectSourceKind, tag: Int) {
        let target = ClickTarget { [weak self] in self?.selectAddProjectSourceKind(kind, tag: tag) }
        let recognizer = NSClickGestureRecognizer(target: target, action: #selector(ClickTarget.clicked(_:)))
        row.addGestureRecognizer(recognizer)
        objc_setAssociatedObject(row, &Self.clickTargetAssocKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    private func selectAddProjectSourceKind(_ kind: AddProjectSourceKind, tag: Int) {
        guard let refs = Self.liveFormRefs(addProjectFieldRefs, forSenderTag: tag) else { return }
        refs.selectedSourceKind = kind
        updateAddProjectSourceStepUI(refs)
        addProjectWindow?.makeFirstResponder(kind == .folder ? refs.dirField : refs.repoURLField)
    }

    private func updateAddProjectSourceStepUI(_ refs: AddProjectFieldRefs) {
        let kind = refs.selectedSourceKind
        setAddProjectSourceRowSelected(refs.folderRow, selected: kind == .folder)
        setAddProjectSourceRowSelected(refs.gitRow, selected: kind == .git)
        refs.folderInputRow.isHidden = kind != .folder
        refs.gitInputRow.isHidden = kind != .git
        let input: String
        switch kind {
        case .folder: input = refs.dirField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        case .git: input = refs.repoURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        case nil: input = ""
        }
        refs.continueButton.isEnabled = kind != nil && !input.isEmpty
    }

    private func setAddProjectSourceRowSelected(_ row: ClickableRowView, selected: Bool) {
        row.layer?.borderWidth = selected ? 2 : 1
        bindAppearanceReactiveLayer(row) { [weak self] view in
            view.layer?.borderColor =
                selected
                ? self?.sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184)).cgColor : self?.sidebarCardBorderColor(isSelected: false).cgColor
        }
    }

    /// The default device for new projects: the local Mac.
    private func localProjectCreationDeviceID() -> String {
        deviceSections.first(where: { $0.isLocal })?.deviceID ?? SpacesPairedDeviceRecord.localDeviceID
    }

    private func presentAddProjectWindow(hosting stack: NSStackView, title: String) {
        let header = buildFormWindowHeader(symbol: "square.and.pencil", title: title, closeAction: #selector(closeAddProjectWindow))
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
        bindAppearanceReactiveLayer(root) { [weak self] view in view.layer?.backgroundColor = self?.sidebarPanelBackgroundColor().cgColor }

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
        titleLabel.font = Typography.sheetTitle
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
        // Creating a workspace clones and configures it on the owning daemon, so an unreachable
        // device has no form to fill in — refuse before opening it, the way the add-project device
        // picker refuses an offline device. The sidebar's + button is disabled for the same reason,
        // but the add-workspace shortcut reaches this directly from the selection.
        guard deviceForMutation(deviceID: project.deviceID) != nil else {
            showError(deviceUnavailableError(deviceID: project.deviceID))
            return
        }
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
        contentStack.detachesHiddenViews = true

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
            newBranchField: newBranchField, baseBranchField: baseBranchField, baseBranchRow: baseRow, notesField: notesField,
            autoNameState: autoNameState, createButton: createButton)
        activeAddWorkspaceFormTag = createButton.tag
        if let refs = addWorkspaceFieldRefs {
            updateAddWorkspaceBranchInputUI(refs: refs)
            updateAddWorkspaceProgressiveDisclosure(refs: refs, branchValue: currentAddWorkspaceBranchValue(refs))
        }
        Task { @MainActor [weak self, weak newBranchField] in
            await Task.yield()
            guard let self else { return }
            self.addWorkspaceWindow?.makeFirstResponder(newBranchField)
        }
        let formTag = createButton.tag
        guard let device = deviceRecord(forDeviceID: project.deviceID) else {
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
            if let refs = Self.liveFormRefs(self.addWorkspaceFieldRefs, forSenderTag: formTag) {
                self.updateAddWorkspaceProgressiveDisclosure(refs: refs, branchValue: self.currentAddWorkspaceBranchValue(refs))
            }
        }
    }

    private func prepareWorkspaceDetailContainer(workspaceID: String, presentation: DetailPanePresentation) {
        presentDetailPane(.workspace(id: workspaceID), presentation: presentation)
        showingSettings = false
        updateAlertsRowAppearance()
        activeShortcutCaptureSetting = nil
        workspaceSetupLogTextView = nil
        // Only the workspace-panel detail shows the titlebar tab strip; the panel
        // branch of `showWorkspaceDetail` re-reveals it.
        hideWorkspacePanelTabStrip()
        for view in detailContainer.subviews { view.removeFromSuperview() }
        detailContainer.wantsLayer = true
        bindAppearanceReactiveLayer(detailContainer) { [weak self] view in view.layer?.backgroundColor = self?.sidebarPanelBackgroundColor().cgColor }
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
        // This workspace's device is compatible; every branch below presents the workspace pane
        // (`prepareWorkspaceDetailContainer`), which replaces any prior device's compatibility block.
        guard let deviceWorkspaceSummary = deviceWorkspaceSummary(workspaceID: workspace.id) else {
            prepareWorkspaceDetailContainer(workspaceID: workspace.id, presentation: presentation)
            showWorkspaceDetailLoadingPlaceholder(workspace: workspace)
            requestSidebarReload()
            return
        }
        let deviceWorkspace = SpacesDeviceWorkspaceDetailViewModel(workspace: deviceWorkspaceSummary)
        let setupState = Self.localSetupState(from: deviceWorkspace.setupState)
        if !Self.shouldRequestNormalWorkspaceDetailRefresh(setupStatus: setupState.status) {
            prepareWorkspaceDetailContainer(workspaceID: workspace.id, presentation: presentation)
            showWorkspaceSetupDetail(project: project, workspace: workspace, setupState: setupState, logTail: deviceWorkspace.setupState?.logTail)
            return
        }
        stopWorkspaceSetupDetailRefreshTimer()

        // The right panel is the workspace's panel (tabs of terminal panes) and
        // nothing else; workspace identity and actions live in the footer strip below.
        let scope = PanelScope.workspace(deviceID: workspaceDeviceID, workspaceID: workspace.id)
        panelCoordinator.restoreLayoutIfNeeded(scope: scope)
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
        prepareWorkspaceDetailContainer(workspaceID: workspace.id, presentation: presentation)
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
        titleLabel.font = Typography.compactTitle
        titleLabel.textColor = sidebarPrimaryTextColor(isSelected: false)
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

        // Git workspaces are named after their branch, so a branch label matching the
        // name would just duplicate it.
        let branch = (workspace.branch ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
        let notes = (workspace.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let notesButton = footerActionButton(
            symbol: "note.text", tooltip: notes.isEmpty ? "Add notes" : notes, action: #selector(showWorkspaceNotesEditor(_:)))
        notesButton.contentTintColor = notes.isEmpty ? .tertiaryLabelColor : accentColor
        notesButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        notesButton.setAccessibilityIdentifier("workspace-detail-notes")
        disableWhenDeviceCannotAct(notesButton, workspaceID: workspace.id)
        footer.addArrangedSubview(notesButton)

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
            let response = try SpacesDeviceClient.updateWorkspaceMetadata(
                workspaceID: workspaceID, notes: trimmed.isEmpty ? nil : trimmed, updatesNotes: true, device: device,
                clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
            workspaceNotesPopover?.close()
            workspaceNotesPopover = nil
            applyDeviceMutationResponse(response, deviceID: device.id, selectedWorkspaceID: workspaceID)
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

        let workspaceDeviceName = deviceSections.first(where: { $0.deviceID == workspace.deviceID })?.deviceName ?? localDeviceName
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
        titleLabel.textColor = sidebarPrimaryTextColor(isSelected: false)
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
            tooltip: "Run workspace setup", action: #selector(runWorkspaceSetupFromDetail(_:)), primary: setupState.status != .running)
        runButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        runButton.isEnabled = setupState.status != .running
        runButton.setAccessibilityIdentifier("workspace-setup-run")
        // Running setup and opening a terminal both run on the owning daemon; Reveal and Copy Log below
        // read what is already on this Mac, so they stay available through an outage.
        disableWhenDeviceCannotAct(runButton, workspaceID: workspace.id)

        let terminalButton = actionButton(
            title: "Terminal", symbol: "terminal", tooltip: "Open a workspace terminal", action: #selector(openWorkspaceTerminal(_:)), primary: false)
        terminalButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        terminalButton.setAccessibilityIdentifier("workspace-setup-terminal")
        disableWhenDeviceCannotAct(terminalButton, workspaceID: workspace.id)

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
                    // Saving the script writes it through the owning daemon, so it goes through the
                    // mutation chokepoint: an unreachable device keeps the editor readable and refuses
                    // only the commit.
                    if let device = deviceForMutation(deviceID: project.deviceID), let current = deviceProjectSummary(projectID: project.id)?.config {
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        let updated = SpacesDeviceProjectConfig(
                            setupScript: trimmed.isEmpty ? nil : value, stopScript: current.stopScript, ports: current.ports,
                            processes: current.processes, browserSessions: current.browserSessions, agentLaunchers: current.agentLaunchers)
                        let response = try SpacesDeviceClient.updateProjectConfig(
                            projectID: project.id, config: updated, device: device,
                            clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                        applyDeviceMutationResponse(response, deviceID: device.id, selectedWorkspaceID: workspace.id)
                    } else {
                        showError(deviceUnavailableError(deviceID: project.deviceID))
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
                    guard $0.roleValue == .terminal else { return false }
                    if let trackingID = agentWindow.terminalTrackingID, !trackingID.isEmpty, $0.terminalTrackingID == trackingID { return true }
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

    /// Live SSH-forward snapshots for a workspace's services: remote workspaces read the forward
    /// manager, local workspaces have no forwards (their assigned port is already local).
    func workspaceServiceForwards(workspaceID: String) -> [BrowserSSHForwardManager.ServiceForwardSnapshot] {
        guard let workspaceDeviceID = deviceID(forWorkspaceID: workspaceID), isRemoteDeviceID(workspaceDeviceID) else { return [] }
        return browserSSHForwardManager.forwardedServicePorts(deviceID: workspaceDeviceID, workspaceID: workspaceID)
    }

    /// Refreshes the open workspace settings dialog's Services rows' port texts after an SSH forward
    /// for `deviceID` starts or stops. Reloads the section in place (preserving open editors); when
    /// no workspace settings dialog is open the weak section reference is nil and this is a no-op.
    private func refreshVisibleServicePortDisplays(deviceID: String) {
        guard let section = visibleWorkspacePortsSection, let workspaceID = visiblePortsWorkspaceID,
            self.deviceID(forWorkspaceID: workspaceID) == deviceID, let workspace = deviceWorkspaceSummary(workspaceID: workspaceID)
        else { return }
        section.reload(
            ports: section.currentPorts,
            collapsedDisplayPortTexts: Self.servicePortDisplayTexts(
                assignedPorts: workspace.assignedPorts, forwards: workspaceServiceForwards(workspaceID: workspaceID)))
    }

    /// The Services row port text: `remote:local` while a remote service has a live SSH forward
    /// (e.g. "3000:52341"), otherwise the bare assigned port.
    nonisolated static func servicePortDisplay(assignedPort: Int?, forwardedLocalPort: Int?) -> String? {
        guard let assignedPort, assignedPort > 0 else { return nil }
        guard let forwardedLocalPort else { return String(assignedPort) }
        return "\(assignedPort):\(forwardedLocalPort)"
    }

    nonisolated static func servicePortDisplayTexts(
        assignedPorts: [SpacesDeviceAssignedPort], forwards: [BrowserSSHForwardManager.ServiceForwardSnapshot]
    ) -> [String?] {
        var localPorts: [String: Int] = [:]
        for forward in forwards { localPorts["\(forward.serviceName):\(forward.remotePort)"] = forward.localPort }
        return assignedPorts.map { servicePortDisplay(assignedPort: $0.port, forwardedLocalPort: localPorts["\($0.name):\($0.port)"]) }
    }

    private func clearActiveAddProjectFormState() {
        // Nothing is cloned until Create, so tearing down the form only clears its cached state.
        addProjectFieldRefs = nil
        activeAddProjectFormTag = nil
    }

    private func clearActiveAddWorkspaceFormState() {
        addWorkspaceFieldRefs = nil
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
        label.font = Typography.compactTitle
        label.textColor = .secondaryLabelColor
        return label
    }

    func helpTextLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Typography.metadata
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
                let statusIconName: String
                let statusColor: NSColor
                switch agentStatus {
                case .waiting:
                    statusIconName = "exclamationmark.triangle.fill"
                    statusColor = .systemOrange
                case .done:
                    statusIconName = "circle.fill"
                    statusColor = .systemGreen
                case .exited:
                    // Agent gone, terminal alive: hollow dimmed dot, distinct from idle's filled dot.
                    statusIconName = "circle"
                    statusColor = .tertiaryLabelColor
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
        label.font = Typography.compactTitle
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
        label.font = Typography.compactTitle
        let valueField = NSTextField(labelWithString: value)
        valueField.font = Typography.rowDetail
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
        label.font = Typography.compactTitle
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
        title.font = Typography.rowDetail
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let captureButton = actionButton(
            title: shortcutCaptureButtonTitle(setting: setting), symbol: nil, tooltip: "Click to capture shortcut",
            action: #selector(beginShortcutCapture(_:)), primary: false)
        captureButton.identifier = NSUserInterfaceItemIdentifier(setting.settingKey)
        captureButton.alignment = .center
        captureButton.font = Typography.monoBody
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
        if setting.usesDigitRangeCapture { return displayShortcutText(spec, keyText: "1-0") }
        return spec.normalized
    }

    private func actionTitle(base: String, setting: ShortcutSetting) -> String { "\(base) (\(shortcutHint(for: setting)))" }

    private func actionTooltip(base: String, setting: ShortcutSetting) -> String { "\(base) (\(shortcutHint(for: setting)))" }

    private func shortcutHint(for setting: ShortcutSetting) -> String {
        if setting == .guiLeaderHotkey { return displayShortcut(modifiers: shortcutLeaderModifiers) }
        guard let spec = shortcutSpec(for: setting) else { return setting.defaultSpec }
        if setting.usesDigitRangeCapture { return displayShortcut(spec, keyText: "1-0") }
        return displayShortcut(spec)
    }

    func footerShortcutHint(for setting: ShortcutSetting) -> String {
        if setting == .guiLeaderHotkey { return displayShortcut(modifiers: shortcutLeaderModifiers, separator: " ") }
        guard let spec = shortcutSpec(for: setting) else { return setting.defaultSpec }
        if setting.usesDigitRangeCapture { return displayShortcut(spec, separator: " ", keyText: "1-0") }
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
        bindAppearanceReactiveLayer(button) { [weak self] view in
            view.layer?.backgroundColor = self?.shortcutKeycapBackgroundColor(active: active).cgColor
            view.layer?.borderColor = self?.shortcutKeycapBorderColor(active: active).cgColor
        }
    }

    private func updateShortcutCaptureButtonText(_ button: NSButton, text: String, active: Bool) {
        let color: NSColor = active ? .white : .labelColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color, .font: Typography.monoBody, .paragraphStyle: paragraph]
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
        label.font = Typography.metadataTitle
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
        labelField.font = Typography.compactTitle
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
        bindAppearanceReactiveLayer(scroll) { [weak self] view in view.layer?.borderColor = self?.sidebarCardBorderColor(isSelected: false).cgColor }
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
        textView.font = Typography.monoBody
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        return textView
    }

    /// Resolves the live field references for a control's action, rejecting stale controls. A control
    /// carries the generation tag of the form it was built for; if that no longer matches the live
    /// form's `formTag` (the form was rebuilt or closed, or `liveRefs` is already nil), the action is
    /// dropped. This replaces the previous global tag-keyed caches now that each dialog is single-instance.
    static func liveFormRefs<Refs: FormGenerationTagged>(_ liveRefs: Refs?, forSenderTag senderTag: Int) -> Refs? {
        guard let liveRefs, liveRefs.formTag == senderTag else { return nil }
        return liveRefs
    }

    private func storeProjectFields(
        projectID: String, setupScriptSection: ScriptSection, stopScriptSection: ScriptSection, portsSection: PortsSection,
        processesSection: ProcessesSection, browserSessionsSection: BrowserSessionsSection, agentLaunchersSection: AgentLaunchersSection,
        importButton: NSButton, exportButton: NSButton, discardImportedConfigButton: NSButton
    ) -> Int {
        let id = projectID.hashValue
        projectSettingsFieldRefs = ProjectFieldRefs(
            formTag: id, projectID: projectID, setupScriptSection: setupScriptSection, stopScriptSection: stopScriptSection,
            portsSection: portsSection, processesSection: processesSection, browserSessionsSection: browserSessionsSection,
            agentLaunchersSection: agentLaunchersSection, importButton: importButton, exportButton: exportButton,
            discardImportedConfigButton: discardImportedConfigButton)
        return id
    }

    private func storeAddProjectFields(
        folderRow: ClickableRowView, gitRow: ClickableRowView, folderInputRow: NSView, gitInputRow: NSView, dirField: NSTextField,
        repoURLField: NSTextField, continueButton: NSButton, setupScriptSection: ScriptSection, stopScriptSection: ScriptSection,
        portsSection: PortsSection, processesSection: ProcessesSection, browserSessionsSection: BrowserSessionsSection,
        agentLaunchersSection: AgentLaunchersSection, createButton: NSButton, spacesYAMLMissingLabel: NSTextField
    ) -> Int {
        let id = UUID().uuidString.hashValue
        addProjectFieldRefs = AddProjectFieldRefs(
            formTag: id, folderRow: folderRow, gitRow: gitRow, folderInputRow: folderInputRow, gitInputRow: gitInputRow, dirField: dirField,
            repoURLField: repoURLField, continueButton: continueButton, setupScriptSection: setupScriptSection, stopScriptSection: stopScriptSection,
            portsSection: portsSection, processesSection: processesSection, browserSessionsSection: browserSessionsSection,
            agentLaunchersSection: agentLaunchersSection, createButton: createButton, spacesYAMLMissingLabel: spacesYAMLMissingLabel)
        continueButton.tag = id
        createButton.tag = id
        return id
    }

    private func storeAddWorkspaceFields(
        projectID: String, isGitRepo: Bool, branchModeSegmented: NSSegmentedControl?, existingBranchField: NSComboBox?, newBranchField: NSTextField?,
        baseBranchField: NSComboBox?, baseBranchRow: NSView?, notesField: NSTextField?, autoNameState: AddWorkspaceAutoNameState?,
        createButton: NSButton
    ) -> Int {
        let id = UUID().uuidString.hashValue
        addWorkspaceFieldRefs = AddWorkspaceFieldRefs(
            formTag: id, projectID: projectID, isGitRepo: isGitRepo, branchModeSegmented: branchModeSegmented,
            existingBranchField: existingBranchField, newBranchField: newBranchField, baseBranchField: baseBranchField, baseBranchRow: baseBranchRow,
            notesField: notesField, autoNameState: autoNameState, createButton: createButton)
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
    @objc func installSpacesOnRemoteDevice() { devicePairing.installSpacesOnRemoteDevice() }
    @objc func copyRemoteDeviceInstallCommand() { devicePairing.copyRemoteDeviceInstallCommand() }
    @objc func toggleRemoteDeviceAdvancedFields(_ sender: NSButton) { devicePairing.toggleRemoteDeviceAdvancedFields(sender) }
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
        guard let raw = (try? clientDatabase().setting(key: ClientSettingsKey.alertsDismissedAttentionItems)) ?? nil, !raw.isEmpty,
            let data = raw.data(using: .utf8), let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(decoded)
    }

    func storeDismissedAlertsAttentionItemIDs(_ ids: Set<String>) throws {
        guard !ids.isEmpty else {
            try clientDatabase().setSetting(key: ClientSettingsKey.alertsDismissedAttentionItems, value: nil)
            return
        }
        let encoded = try JSONEncoder().encode(ids.sorted())
        try clientDatabase().setSetting(key: ClientSettingsKey.alertsDismissedAttentionItems, value: String(decoding: encoded, as: UTF8.self))
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
            guard let device = deviceForDaemonStateMutation() else {
                sender?.isEnabled = true
                showSelectedDeviceUnavailableError()
                return
            }
            let result = await Self.deviceMutation(device: device) { device in
                try SpacesDeviceClient.runWorkspaceSetup(
                    workspaceID: workspaceID, device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
            }
            sender?.isEnabled = true
            switch result {
            // The response's overview belongs to the device the mutation was sent to, so it is
            // installed into that device's section — re-resolving from the workspace id could
            // name a different device and prune its panes against a foreign keep-set.
            case .success(let response): applyDeviceMutationResponse(response, deviceID: device.id, selectedWorkspaceID: workspaceID)
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

    /// Add Project is a two-step flow: pick the device, then configure the project. The device step is
    /// skipped when the local Mac is the only device. Splitting device selection out fixes the device
    /// for the configuration step, so the project's source always targets one daemon.
    @objc private func addProject() {
        if Self.addProjectRequiresDeviceSelection(deviceCount: deviceSections.count) {
            showAddProjectDeviceStep()
        } else {
            showAddProjectSourceStep(deviceID: localProjectCreationDeviceID())
        }
    }

    /// The device-selection step is shown only when there is a choice; a single device (the local Mac)
    /// goes straight to project configuration.
    nonisolated static func addProjectRequiresDeviceSelection(deviceCount: Int) -> Bool { deviceCount > 1 }

    /// Step 1: choose the device the project will be created on. Each device is a full-width,
    /// left-aligned row; clicking one advances to the configuration step. Closing the window cancels.
    private func showAddProjectDeviceStep() {
        clearActiveAddProjectFormState()

        let deviceRows = deviceSections.map { addProjectDeviceRow(section: $0) }
        let deviceCard = formSectionCard(
            icon: "desktopcomputer", title: "Device", subtitle: "Choose where this project will live.", contentViews: deviceRows)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(deviceCard)
        constrainFormFieldToFillWidth(deviceCard, in: stack)

        presentAddProjectWindow(hosting: stack, title: "New Project")
    }

    /// A left-aligned, hover-highlighted device row: platform icon, device name, and a `local`/`remote`
    /// caption, with a trailing chevron signaling that clicking advances to project configuration.
    /// A project can only be created on a reachable device; an offline daemon would make the source
    /// step's Continue hang on a request that just times out, so its row is shown disabled.
    nonisolated static func addProjectDeviceIsSelectable(loadState: SidebarDeviceLoadState) -> Bool { !loadState.isOffline }

    private func addProjectDeviceRow(section: DeviceSection) -> NSView {
        let selectable = Self.addProjectDeviceIsSelectable(loadState: section.loadState)
        let container = ClickableRowView(isInteractive: selectable)
        container.layer?.borderWidth = 1
        bindAppearanceReactiveLayer(container) { [weak self] view in view.layer?.borderColor = self?.sidebarCardBorderColor(isSelected: false).cgColor
        }
        container.alphaValue = selectable ? 1 : Self.unreachableDeviceAlpha
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.button)
        container.setAccessibilityLabel(section.displayName)
        container.setAccessibilityIdentifier("add-project-device-option")
        container.toolTip = selectable ? "Create the project on \(section.displayName)" : "\(section.displayName) is offline"

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: section.isLocal ? "desktopcomputer" : "server.rack", accessibilityDescription: nil)
        iconView.contentTintColor = sidebarThemeColor(light: (13, 95, 93), dark: (61, 198, 184))
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let nameField = NSTextField(labelWithString: section.displayName)
        nameField.font = Typography.sectionTitle
        nameField.textColor = .labelColor
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let caption = selectable ? (section.isLocal ? "This device" : "Remote device") : "Offline"
        let captionField = NSTextField(labelWithString: caption)
        captionField.font = Typography.metadata
        captionField.textColor = .secondaryLabelColor
        captionField.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: [nameField, captionField])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        // Selectable rows show a chevron (click advances); offline rows show a muted offline glyph.
        let trailingIcon = NSImageView()
        trailingIcon.image = NSImage(systemSymbolName: selectable ? "chevron.right" : "bolt.horizontal.circle", accessibilityDescription: nil)
        trailingIcon.contentTintColor = .tertiaryLabelColor
        trailingIcon.setContentHuggingPriority(.required, for: .horizontal)
        trailingIcon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [iconView, textStack, NSView(), trailingIcon])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor), row.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            row.topAnchor.constraint(equalTo: container.topAnchor), row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        // An offline device is not clickable, so no gesture is attached and Continue can never target it.
        guard selectable else { return container }
        let deviceID = section.deviceID
        let target = ClickTarget { [weak self] in self?.showAddProjectSourceStep(deviceID: deviceID) }
        let recognizer = NSClickGestureRecognizer(target: target, action: #selector(ClickTarget.clicked(_:)))
        container.addGestureRecognizer(recognizer)
        objc_setAssociatedObject(container, &Self.clickTargetAssocKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return container
    }

    @objc func addWorkspace(_ sender: NSButton) {
        guard let projectID = sender.identifier?.rawValue, let project = projects.first(where: { $0.id == projectID }) else { return }
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
        guard let refs = Self.liveFormRefs(projectSettingsFieldRefs, forSenderTag: sender.tag) else { return }
        guard validateServiceEditorsCommitted(refs.portsSection, before: "saving project settings") else { return }
        guard confirmProjectImportWorkspaceSyncIfNeeded(refs) else { return }
        do {
            try persistProjectFields(refs)
            projectHasUnsavedChanges = false
            reloadData()
            // Saving is the terminal action for this dialog, so close it; the header X / Escape remain
            // for dismissing without saving. performClose routes through windowWillClose cleanup.
            projectSettingsWindow?.performClose(nil)
        } catch { showError(error) }
    }

    @objc private func exportProjectSpacesYAML(_ sender: NSButton) {
        commitEditing()
        guard let refs = Self.liveFormRefs(projectSettingsFieldRefs, forSenderTag: sender.tag) else { return }
        guard !projectHasUnsavedChanges, !refs.hasOpenSectionEditor else {
            showInfoMessage(title: "Save project settings first", message: "Save or discard pending changes before exporting spaces.yaml.")
            return
        }
        do {
            if let device = deviceForDaemonStateMutation() {
                let response = try SpacesDeviceClient.exportProjectSpacesYAML(
                    projectID: refs.projectID, device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                applyDeviceMutationResponse(response, deviceID: device.id)
                showInfoMessage(title: "Exported spaces.yaml", message: response.message)
                return
            }
            showSelectedDeviceUnavailableError()
        } catch { showError(error) }
    }

    @objc private func importProjectSpacesYAML(_ sender: NSButton) {
        commitEditing()
        guard let refs = Self.liveFormRefs(projectSettingsFieldRefs, forSenderTag: sender.tag) else { return }
        do {
            if let device = deviceForDaemonStateMutation() {
                // A non-git project's template always syncs to its single workspace, so it takes the
                // sync path unprompted; git projects choose whether to update existing workspaces.
                let updateAllWorkspaces: Bool
                if isGitProject(refs.projectID) {
                    let decision = presentProjectImportWorkspaceSyncPrompt()
                    guard decision != .cancel else { return }
                    updateAllWorkspaces = decision == .updateAllWorkspaces
                } else {
                    updateAllWorkspaces = true
                }
                let response = try SpacesDeviceClient.importProjectSpacesYAML(
                    projectID: refs.projectID, updateAllWorkspaces: updateAllWorkspaces, device: device,
                    clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                refs.hasPendingImportedConfig = false
                refs.pendingImportUpdateAllWorkspaces = false
                refs.importButton.isHidden = false
                refs.exportButton.isHidden = false
                refs.discardImportedConfigButton.isHidden = true
                projectHasUnsavedChanges = false
                applyDeviceMutationResponse(response, deviceID: device.id)
                return
            }
            showSelectedDeviceUnavailableError()
        } catch { showError(error) }
    }

    @objc private func discardProjectConfigChanges(_ sender: NSButton) {
        commitEditing()
        guard let refs = Self.liveFormRefs(projectSettingsFieldRefs, forSenderTag: sender.tag) else { return }
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

    /// Whether the project is a git repo (vs a non-git project standing in for its single
    /// workspace). Unknown project ids default to git so the workspace-sync prompt is preserved.
    private func isGitProject(_ projectID: String) -> Bool { projects.first { $0.id == projectID }?.isGitRepo ?? true }

    private func confirmProjectImportWorkspaceSyncIfNeeded(_ refs: ProjectFieldRefs) -> Bool {
        guard refs.hasPendingImportedConfig else { return true }
        // A non-git project's template always syncs to its single workspace (see
        // updateProjectConfig), so there is no "project only" choice to offer — proceed unprompted.
        guard isGitProject(refs.projectID) else { return true }
        return Self.applyProjectImportWorkspaceSyncDecision(presentProjectImportWorkspaceSyncPrompt(), to: refs)
    }

    private func presentProjectImportWorkspaceSyncPrompt() -> ProjectImportWorkspaceSyncDecision {
        let alert = NSAlert()
        alert.messageText = "Update workspaces?"
        alert.informativeText = "Save the imported spaces.yaml settings to this project. Apply the same settings to every workspace in this project?"
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
                    // Pass the deleting device explicitly: the selection was just cleared, so any
                    // selection-based device inference would misroute a remote delete's overview (and
                    // its pane-prune keep-set) into the local section.
                    applyDeviceMutationResponse(response, deviceID: device.id)
                case .failure(let error): showError(error)
                }
            } else {
                showSelectedDeviceUnavailableError()
            }
        }
    }

    @objc private func createProject(_ sender: NSButton) {
        commitEditing()
        guard let refs = Self.liveFormRefs(addProjectFieldRefs, forSenderTag: sender.tag) else { return }
        guard validateServiceEditorsCommitted(refs.portsSection, before: "creating the project") else { return }
        do {
            // The project is created on the device fixed in step 1; folder autocomplete and preview
            // used the same device.
            if let device = deviceRecord(forDeviceID: refs.selectedDeviceID) {
                let projectDir: String?
                let gitURL: String?
                if refs.selectedSourceKind == .git {
                    let repoURL = refs.repoURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !repoURL.isEmpty else { throw WorkspaceError.invalidArgument(message: "Git repository URL is required.") }
                    projectDir = nil
                    gitURL = repoURL
                } else {
                    let dir = refs.dirField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !dir.isEmpty else { return }
                    projectDir = dir
                    gitURL = nil
                }
                let config = Self.deviceProjectConfig(from: refs)
                // For a git source the daemon clones the repository now and applies this config (the
                // preview only fetched spaces.yaml). Cloning at Create means nothing is left behind if
                // the user cancels, so there is no prepared clone to track or discard.
                let originalTitle = sender.title
                sender.isEnabled = false
                sender.title = "Creating..."
                showOperationProgressOverlay(
                    message: "Creating project...", detail: "Creating the project on \(deviceDisplayName(id: refs.selectedDeviceID)).",
                    context: .global)
                Task { @MainActor [weak self, weak sender] in
                    guard let self else { return }
                    defer {
                        sender?.isEnabled = true
                        sender?.title = originalTitle
                        hideOperationProgressOverlay()
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
                            applyDeviceMutationResponse(
                                response, deviceID: device.id, selectedProjectID: response.projectID, selectedWorkspaceID: response.workspaceID)
                        }
                    case .failure(let error):
                        // Nothing was cloned yet (the clone is part of the failed Create), so there is
                        // no prepared clone to restore or discard.
                        showError(error)
                    }
                }
                return
            }
            showDeviceNotLoadedError()
        } catch { showError(error) }
    }

    @objc private func continueFromSourceStep(_ sender: NSButton) {
        guard let refs = Self.liveFormRefs(addProjectFieldRefs, forSenderTag: sender.tag) else { return }
        advanceFromSourceStep(refs)
    }

    /// Loads the configuration from the chosen source and advances to the config step. For a folder the
    /// daemon validates the path and reads any `spaces.yaml`; for a repo it fetches `spaces.yaml` (single
    /// file, no clone). While loading, the source inputs are replaced by a loading step so nothing is
    /// editable in flight; a failure returns to the source step (values intact) with the error surfaced.
    private func advanceFromSourceStep(_ refs: AddProjectFieldRefs) {
        guard let kind = refs.selectedSourceKind else { return }
        // Loading against an offline daemon would hang until the request times out. Offline devices are
        // not selectable in the device step, but the device step is skipped for a lone local device, so
        // guard here too and surface the offline state instead.
        if let section = deviceSection(id: refs.selectedDeviceID), !Self.addProjectDeviceIsSelectable(loadState: section.loadState) {
            showError(Self.deviceUnreachableError(deviceName: section.displayName, isLocal: section.isLocal))
            return
        }
        guard let device = deviceRecord(forDeviceID: refs.selectedDeviceID) else {
            showDeviceNotLoadedError()
            return
        }
        let input = (kind == .folder ? refs.dirField : refs.repoURLField).stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        // Swap the source inputs for a loading step. With no editable source on screen during the fetch,
        // the loaded config cannot end up describing a source different from what Create will use, so no
        // separate staleness bookkeeping is needed.
        presentAddProjectLoadingStep(
            deviceID: refs.selectedDeviceID,
            detail: kind == .folder ? "Validating the folder and reading spaces.yaml…" : "Reading spaces.yaml from the repository…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch kind {
            case .folder:
                let result = await Self.deviceProjectPreview(dir: input, device: device)
                guard isActiveAddProjectForm(refs) else { return }
                switch result {
                case .success(let preview):
                    refs.spacesYAMLMissing = false
                    hydrateAddProjectSettings(refs, from: preview.config)
                    showAddProjectConfigStep(refs)
                case .failure(let error):
                    presentAddProjectSourceStep(refs)
                    showError(error)
                }
            case .git:
                let result = await Self.previewGitProjectResult(gitURL: input, device: device)
                guard isActiveAddProjectForm(refs) else { return }
                switch result {
                case .success(let preview):
                    // Managed directories already exist for this repo; Create replaces them, so confirm now.
                    if !preview.replacementCandidates.isEmpty, !presentManagedDirectoryReplacementPrompt(candidates: preview.replacementCandidates) {
                        presentAddProjectSourceStep(refs)
                        return
                    }
                    refs.spacesYAMLMissing = !preview.spacesYAMLFound
                    hydrateAddProjectSettings(refs, from: preview.config ?? SpacesDeviceProjectConfig())
                    showAddProjectConfigStep(refs)
                case .failure(let error):
                    presentAddProjectSourceStep(refs)
                    showError(error)
                }
            }
        }
    }

    private func isActiveAddProjectForm(_ refs: AddProjectFieldRefs) -> Bool {
        activeAddProjectFormTag == refs.formTag && addProjectFieldRefs === refs
    }

    private func addProjectRefs(forDirectoryField field: NSControl) -> AddProjectFieldRefs? {
        guard let refs = addProjectFieldRefs, refs.dirField === field else { return nil }
        return refs
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

    private func hydrateAddProjectSettings(_ refs: AddProjectFieldRefs, from config: SpacesDeviceProjectConfig) {
        let settings = Self.localProjectSettings(from: config)
        refs.setupScriptSection.replace(value: settings.setupScript ?? "")
        refs.stopScriptSection.replace(value: settings.stopScript ?? "")
        refs.portsSection.replace(ports: settings.ports)
        refs.processesSection.replace(processes: settings.processes)
        refs.browserSessionsSection.replace(sessions: settings.browserSessions)
        refs.agentLaunchersSection.replace(launchers: settings.agentLaunchers)
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
        // Base branch is the start point for a branch Spaces creates. Attaching to an existing
        // branch has no start point, so the whole row leaves the form in that mode.
        refs.baseBranchRow?.isHidden = !isCreatingBranch
    }

    private func updateAddWorkspaceProgressiveDisclosure(refs: AddWorkspaceFieldRefs, branchValue: String) {
        guard refs.isGitRepo else { return }
        let hasBranch = !branchValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        refs.createButton.isEnabled = hasBranch
    }

    @objc private func addWorkspaceBranchModeChanged(_ sender: NSSegmentedControl) {
        guard let refs = Self.liveFormRefs(addWorkspaceFieldRefs, forSenderTag: sender.tag) else { return }
        handleAddWorkspaceBranchFieldChange(refs: refs)
        if addWorkspaceBranchMode(refs: refs) == .create {
            window.makeFirstResponder(refs.newBranchField)
        } else {
            window.makeFirstResponder(refs.existingBranchField)
        }
    }

    @objc private func addWorkspaceBranchFieldChanged(_ sender: NSControl) {
        guard let refs = addWorkspaceFieldRefs, refs.existingBranchField === sender || refs.newBranchField === sender else { return }
        handleAddWorkspaceBranchFieldChange(refs: refs)
    }

    @objc private func createWorkspace(_ sender: NSButton) {
        guard let refs = Self.liveFormRefs(addWorkspaceFieldRefs, forSenderTag: sender.tag) else { return }
        do {
            let mode = addWorkspaceBranchMode(refs: refs)
            // Base branch only names the start point for a branch Spaces creates; attaching to an
            // existing branch checks that branch out directly and sends no base branch.
            let baseBranch = mode == .create ? refs.baseBranchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            let branch = currentAddWorkspaceBranchValue(refs).trimmingCharacters(in: .whitespacesAndNewlines)
            let notes = refs.notesField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedNotes: String?
            if let notes, notes.isEmpty { resolvedNotes = nil } else { resolvedNotes = notes }
            if refs.isGitRepo, branch.isEmpty { throw WorkspaceError.invalidArgument(message: "Branch name is required for git projects.") }
            if refs.isGitRepo, mode == .create, baseBranch == nil || baseBranch?.isEmpty == true {
                throw WorkspaceError.invalidArgument(message: "Base branch is required for git projects.")
            }
            if refs.isGitRepo, mode == .create, refs.autoNameState?.branchOptions.contains(branch) == true {
                throw WorkspaceError.invalidArgument(
                    message: "Branch '\(branch)' already exists. Choose it from Existing branch or enter a different new branch name.")
            }
            if let workspaceTargetDeviceID = deviceID(forProjectID: refs.projectID), let device = deviceForMutation(deviceID: workspaceTargetDeviceID)
            {
                let input = WorkspaceCreateInput(
                    projectID: refs.projectID, branch: branch, baseBranch: baseBranch, notes: resolvedNotes, allowRemoteBranchLookup: true,
                    allowExistingBranchReuse: mode == .existing, replaceExistingManagedDirectory: false)
                let originalTitle = sender.title
                sender.isEnabled = false
                sender.title = "Creating..."
                showOperationProgressOverlay(
                    message: "Creating workspace...", detail: "Creating the workspace on \(deviceDisplayName(id: workspaceTargetDeviceID)).",
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
                        applyDeviceMutationResponse(
                            response, deviceID: device.id, selectedProjectID: refs.projectID, selectedWorkspaceID: response.workspaceID)
                    case .failure(let error): showError(error)
                    }
                }
                return
            }
            showError(deviceUnavailableError(deviceID: deviceID(forProjectID: refs.projectID)))
        } catch { showError(error) }
    }

    public func controlTextDidChange(_ obj: Notification) {
        guard let changedField = obj.object as? NSTextField else { return }
        if changedField === commandPalette.commandPaletteSearchField {
            logHotkeyDebug("search_change query=\(changedField.stringValue)")
            commandPalette.applyCommandPaletteFilter()
            return
        }
        if let refs = addProjectFieldRefs, refs.repoURLField === changedField {
            updateAddProjectSourceStepUI(refs)
            return
        }
        if let refs = addProjectRefs(forDirectoryField: changedField) {
            updateAddProjectSourceStepUI(refs)
            scheduleAddProjectDirectorySuggestions(refs)
            return
        }
        if let refs = addWorkspaceFieldRefs, refs.existingBranchField === changedField || refs.newBranchField === changedField {
            if let existingBranchField = refs.existingBranchField, existingBranchField === changedField {
                Self.syncExistingWorkspaceBranchSelection(existingBranchField: existingBranchField)
            }
            handleAddWorkspaceBranchFieldChange(refs: refs)
            return
        }
    }

    public func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let comboBox = notification.object as? NSComboBox else { return }
        guard let refs = addWorkspaceFieldRefs, refs.existingBranchField === comboBox else { return }
        let selectedBranchValue = (comboBox.objectValueOfSelectedItem as? String) ?? comboBox.stringValue
        comboBox.stringValue = selectedBranchValue
        handleAddWorkspaceBranchFieldChange(refs: refs, branchValueOverride: selectedBranchValue)
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
        let result = await Self.deviceMutation(device: device) { device in
            try SpacesDeviceClient.launchWorkspace(
                workspaceID: id, device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
        }
        switch result {
        // The overview in the response is the one this device just published, so it is applied to
        // that device's section (`device.id`) rather than re-resolved from the workspace id.
        case .success(let response): applyDeviceMutationResponse(response, deviceID: device.id, selectedWorkspaceID: id)
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
        let browserSessionTargetURLs = configuredBrowserSessionTargetURLsForTeardown(workspaceID: id)
        guard let device = deviceForWorkspaceMutation(workspaceID: id) else {
            showWorkspaceDeviceUnavailableError(workspaceID: id)
            return
        }
        let result = await Self.deviceMutation(device: device) { device in
            try SpacesDeviceClient.restartWorkspace(
                workspaceID: id, device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
        }
        switch result {
        case .success(let response):
            // Restart goes through the daemon stop path; the daemon does not own the
            // client-side Chrome browser-session tabs, so close them here too for a clean
            // restarted state (a later browser focus then opens fresh tabs).
            self.closeLocalBrowserSessionWindows(workspaceID: id, configuredBrowserSessionTargetURLs: browserSessionTargetURLs)
            self.closeWorkspaceTerminalPanes(workspaceID: id)
            applyDeviceMutationResponse(response, deviceID: device.id, selectedWorkspaceID: id)
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
        let browserSessionTargetURLs = configuredBrowserSessionTargetURLsForTeardown(workspaceID: id)
        guard let device = deviceForWorkspaceMutation(workspaceID: id) else {
            showWorkspaceDeviceUnavailableError(workspaceID: id)
            return
        }
        let result = await Self.deviceMutation(device: device) { device in
            try SpacesDeviceClient.stopWorkspace(
                workspaceID: id, device: device, clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
        }
        switch result {
        case .success(let response):
            self.closeLocalBrowserSessionWindows(workspaceID: id, configuredBrowserSessionTargetURLs: browserSessionTargetURLs)
            self.closeWorkspaceTerminalPanes(workspaceID: id)
            applyDeviceMutationResponse(response, deviceID: device.id, selectedWorkspaceID: id)
        case .failure(let error): showError(error)
        }
    }

    /// Closes the workspace browser-session tabs the app opened or adopted and clears their
    /// tracking rows. Browser-session tab locations are client/desktop-local, so the
    /// daemon cannot close them when a workspace stops — the GUI tears them down here. A no-op when
    /// the workspace has no tracked browser-session tabs.
    ///
    /// Called from two disjoint triggers: the GUI's own stop/restart/delete handlers (eager, and
    /// the only reliable signal for a restart's transient stop), and the sidebar's daemon-observed
    /// transition diff (the net for stop/delete initiated outside this GUI — CLI, MCP, the Device
    /// API, or another device). Idempotent: it clears the tracking rows, so a later reload that
    /// re-observes the same stopped workspace finds nothing to close.
    func closeLocalBrowserSessionWindows(workspaceID: String, configuredBrowserSessionTargetURLs: [String]) {
        Task.detached(priority: .utility) {
            Self.closeLocalBrowserSessionWindowsSynchronously(
                workspaceID: workspaceID, configuredBrowserSessionTargetURLs: configuredBrowserSessionTargetURLs)
        }
    }

    /// Closes the workspace's open terminal panes after the owning daemon confirms a workspace
    /// stop/restart/delete. The terminal sessions are already being stopped by that mutation, so
    /// pane teardown skips the client-detach cleanup path.
    private func closeWorkspaceTerminalPanes(workspaceID: String) {
        panelCoordinator.closeTerminalPanes(workspaceID: workspaceID, sessionIsTerminating: true)
    }

    private func configuredBrowserSessionTargetURLsForTeardown(workspaceID: String) -> [String] {
        Self.browserSessionTargetURLs(workspaceID: workspaceID, overview: overview(forWorkspaceID: workspaceID))
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
        let browserSessionTargetURLs = configuredBrowserSessionTargetURLsForTeardown(workspaceID: id)
        // Route the delete to the daemon that owns the workspace's project rather than the local
        // device, so a remote workspace is deleted where it actually lives.
        let device = deviceForMutation(deviceID: project.deviceID)
        beginPendingWorkspaceDeletion(workspaceID: id, projectID: project.id)
        button?.isEnabled = false
        showOperationProgressOverlay(
            message: "Deleting workspace...", detail: "Stopping runtime state and cleaning up workspace files.", context: .workspace(id))
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
                    self.closeLocalBrowserSessionWindows(workspaceID: id, configuredBrowserSessionTargetURLs: browserSessionTargetURLs)
                    self.closeWorkspaceTerminalPanes(workspaceID: id)
                    // Install the post-delete overview first, then clear the marking: the workspace is
                    // already absent from that overview, so its row leaves the sidebar exactly once.
                    //
                    // Accepted risk: a remote overview pull that began before this response can land after
                    // the marking clears and re-add the row for one refresh cycle. That needs a pull in
                    // flight inside the seconds-wide delete window, shows a ghost row the next pull
                    // removes, and the fix — a mutation-generation fence across every overview install
                    // path like the iOS model's — is disproportionate to a self-healing flicker.
                    applyDeviceMutationResponse(response, deviceID: device.id, selectedProjectID: project.id)
                    self.endPendingWorkspaceDeletion(workspaceID: id)
                    // The daemon only sends a notice when branch deletion did not go as asked (a protected
                    // branch, no recorded branch, or a git failure), so any dialog here is reporting a
                    // problem; a clean delete, including branch boxes ticked with clean outcomes, stays silent.
                    if let notice = response.mutationNotice, !notice.isEmpty { self.showInfoMessage(title: "Deleted workspace", message: notice) }
                case .failure(let error):
                    guard Self.isIndeterminateDeleteOutcome(error) else {
                        // The daemon answered and refused: the workspace was never touched, so the row
                        // goes back to normal — its expansion state included — and the reload re-syncs
                        // whatever the daemon did get through.
                        self.endPendingWorkspaceDeletion(workspaceID: id)
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
                    let outcome = await reconciler.reconcile(
                        workspaceID: id, fetchOverview: { await Self.deviceOverviewFetch(device: device) },
                        applyOverview: { [weak self] overview in
                            self?.applyDeviceOverview(overview, deviceID: device.id, selectedProjectID: project.id)
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
                        // any other mutation's response — and resolves it (`resolveAwaitingWorkspaceDeletions`).
                        self.workspaceIDsAwaitingDeletionResolution[id] = AwaitingWorkspaceDeletionResolution(
                            deviceID: device.id, error: error, branchDeletionRequested: deleteLocalBranch || deleteRemoteBranch,
                            browserSessionTargetURLs: browserSessionTargetURLs,
                            overviewInstallGenerationAtDefer: self.deviceSections.first(where: { $0.deviceID == device.id })?
                                .overviewInstallGeneration ?? 0)
                    case .present:
                        // An overview resolved and still lists the workspace: the row goes back to normal
                        // and the held error is real.
                        self.endPendingWorkspaceDeletion(workspaceID: id)
                        requestSidebarReload()
                        showError(error)
                    case .gone:
                        // Reconciliation confirmed the delete landed, so the workspace gets the same client
                        // cleanup a direct success performs — otherwise its browser windows would outlive it
                        // indefinitely.
                        self.endPendingWorkspaceDeletion(workspaceID: id)
                        self.closeLocalBrowserSessionWindows(workspaceID: id, configuredBrowserSessionTargetURLs: browserSessionTargetURLs)
                        self.closeWorkspaceTerminalPanes(workspaceID: id)
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
                self.endPendingWorkspaceDeletion(workspaceID: id)
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
        if let context = Self.senderWorkspacePathActionContext(sender) {
            if showRemoteWorkspacePathActionErrorIfNeeded(.revealInFinder, workspaceID: context.workspaceID) { return }
            NSWorkspace.shared.selectFile(context.path, inFileViewerRootedAtPath: "")
            return
        }
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
        guard let workspaceID = sender.identifier?.rawValue, let workspace = workspaceIndex[workspaceID]?.workspace else { return }
        let menu = Self.makeWorkspaceOverflowMenu(
            workspaceID: workspaceID, path: workspace.dir, target: self, isLocalDevice: isLocalWorkspace(workspace),
            daemonActionsEnabled: deviceAcceptsDaemonActions(forWorkspaceID: workspaceID))
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
        let storedLocalDevice = localPairedDevice ?? (try? clientDatabase().pairedDevice(id: SpacesPairedDeviceRecord.localDeviceID))
        if let storedLocalDevice {
            localPairedDevice = storedLocalDevice
            localDeviceID = storedLocalDevice.id
            localDeviceName = storedLocalDevice.name
        }
        if let index = deviceSections.firstIndex(where: { $0.deviceID == localDeviceID }) {
            deviceSections[index].device = storedLocalDevice ?? deviceSections[index].device
            deviceSections[index].daemonStatus = incompatibility.status
            deviceSections[index].compatibility = incompatibility.verdict
            deviceSections[index].projects = []
            deviceSections[index].workspacesByProject = [:]
            deviceSections[index].workspaceRuntimeStatusByID = [:]
            deviceSections[index].alertsGroups = []
            deviceSections[index].overview = nil
            deviceSections[index].loadState = .loaded
        } else {
            deviceSections.insert(
                DeviceSection(
                    deviceID: localDeviceID, deviceName: localDeviceName, isLocal: true, loadState: .loaded, device: storedLocalDevice, overview: nil,
                    daemonStatus: incompatibility.status, compatibility: incompatibility.verdict), at: 0)
        }
        rebuildFlatSidebarData()
        fullReloadSidebarOutline()
        showCompatibilityBlock(deviceID: localDeviceID, verdict: incompatibility.verdict)
        if let window { revealTargetedHotkeyWindow(window) }
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
            guard let (project, workspace) = findWorkspace(id: workspaceID) else {
                throw WorkspaceError.invalidArgument(message: "Workspace not found.")
            }
            let target = try resolveEditorLaunch(try clientAppConfig().editor)
            // The owning device comes from the row the workspace was found in, so the
            // remote/local branch below can never run the local path for a remote workspace.
            let deviceID = project.deviceID
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
        guard beginNewTerminalSessionCreation(workspaceID: workspaceID) else {
            completion?()
            return
        }
        let startedAt = Date()
        createTerminalSessionForPane(workspaceID: workspaceID) { [weak self] request in
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
            hideAfterSuccessfulExternalWindowAction(.open(hidesApp: false))
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
                    applyDeviceMutationResponse(response, deviceID: device.id, selectedWorkspaceID: workspaceID)
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
            showWorkspaceDeviceUnavailableError(workspaceID: workspaceID)
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
                    applyDeviceMutationResponse(response, deviceID: device.id, selectedWorkspaceID: workspaceID)
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
                    let response = try SpacesDeviceClient.restartWorkspaceProcess(
                        workspaceID: workspaceID, processID: nil, processKey: processName, processTemplateID: nil, device: device,
                        clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                    logPerfMetric(
                        "workspace_process_restart_ui", target: "workspace=\(workspaceID)", elapsedMS: windowShortcutElapsedMS(since: startedAt),
                        success: true, detail: "route=ipc name=\(processName)")
                    applyDeviceMutationResponse(response, deviceID: device.id, selectedWorkspaceID: workspaceID)
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
                    applyDeviceMutationResponse(response, deviceID: device.id, selectedWorkspaceID: workspaceID)
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
            showWorkspaceDeviceUnavailableError(workspaceID: workspaceID)
        }
    }

    private func openWorkspaceFinder(workspaceID: String) {
        if showRemoteWorkspacePathActionErrorIfNeeded(.revealInFinder, workspaceID: workspaceID) { return }
        guard let (_, workspace) = findWorkspace(id: workspaceID) else { return }
        let url = URL(fileURLWithPath: workspace.dir, isDirectory: true)
        if NSWorkspace.shared.open(url) { hideAfterSuccessfulExternalWindowAction(.open(hidesApp: true)) }
    }

    /// Marks a workspace whose delete the user just confirmed, and moves the selection off it: a marked
    /// row is inert, so it must not stay selected with its detail pane open. The marking is read on every
    /// row build, so overview refreshes that land while the daemon works through the delete keep showing
    /// the row as deleting instead of restoring it to normal.
    private func beginPendingWorkspaceDeletion(workspaceID: String, projectID: String) {
        workspaceIDsPendingDeletion.insert(workspaceID)
        if selectedWorkspaceID == workspaceID {
            selectedWorkspaceID = nil
            selectedProjectID = projectID
        }
        applyPendingWorkspaceDeletionMarking()
    }

    /// Clears the marking once the delete resolves. After a successful delete the workspace is already
    /// gone from the refreshed overview, so the row leaves once; after a failed one the row returns to
    /// normal, with the user's expansion state intact because marking never touched it.
    private func endPendingWorkspaceDeletion(workspaceID: String) {
        guard workspaceIDsPendingDeletion.remove(workspaceID) != nil else { return }
        applyPendingWorkspaceDeletionMarking()
    }

    /// Rebuilds the rows against the current marking. The sidebar data itself is unchanged — a workspace
    /// being deleted keeps its row — so only the row views and the expansion state (a marked row hides
    /// its runtime targets) have to be reapplied.
    private func applyPendingWorkspaceDeletionMarking() {
        fullReloadSidebarOutline()
        refreshSelection()
    }

    /// Resolves every entry in `workspaceIDsAwaitingDeletionResolution` whose owning device now has an
    /// overview installed. Hooked off the `workspacesByProject` `didSet` (see its comment) because that
    /// is the nearest point in this file every overview-install path — the local snapshot, a remote
    /// pull/subscription, and a mutation response, including `deleteWorkspace`'s own reconciliation
    /// refetches — is guaranteed to reach, without requiring `SidebarController` to know this feature
    /// exists.
    ///
    /// Each entry is independent: an overview that resolves one device's workspace says nothing about
    /// another device's, and a device whose current overview is `nil` — offline, not yet loaded, or the
    /// empty placeholder a wire-incompatible daemon answers with — has proved nothing either way, so
    /// that entry is left waiting for a later install with real data.
    ///
    /// This `didSet` fires for a rebuild triggered by *any* device's refresh, not just the owning
    /// device's, so an overview alone is not enough evidence: an offline owning device keeps its
    /// last-known (pre-delete) overview rather than clearing it, and reading that stale snapshot on a
    /// rebuild some other device caused would draw a verdict that predates the delete. Each entry also
    /// captures the owning device's `overviewInstallGeneration` at defer time and only resolves once
    /// that device's own generation has advanced past it — i.e. once this specific device has actually
    /// reinstalled an overview since the defer, not merely been read again.
    private func resolveAwaitingWorkspaceDeletions() {
        guard !workspaceIDsAwaitingDeletionResolution.isEmpty else { return }
        for (workspaceID, pending) in workspaceIDsAwaitingDeletionResolution {
            // A missing section (device unpaired mid-defer) falls back to comparing the captured
            // generation against itself, i.e. `.stillAwaiting` — there is no fresher evidence to read.
            let section = deviceSections.first(where: { $0.deviceID == pending.deviceID })
            switch Self.resolveAwaitingWorkspaceDeletion(
                overview: section?.overview,
                overviewInstallGeneration: section?.overviewInstallGeneration ?? pending.overviewInstallGenerationAtDefer,
                overviewInstallGenerationAtDefer: pending.overviewInstallGenerationAtDefer, workspaceID: workspaceID,
                branchDeletionRequested: pending.branchDeletionRequested)
            {
            case .stillAwaiting: continue
            case .present:
                workspaceIDsAwaitingDeletionResolution.removeValue(forKey: workspaceID)
                endPendingWorkspaceDeletion(workspaceID: workspaceID)
                requestSidebarReload()
                showError(pending.error)
            case .gone(let showsBranchOutcomeNotice):
                workspaceIDsAwaitingDeletionResolution.removeValue(forKey: workspaceID)
                endPendingWorkspaceDeletion(workspaceID: workspaceID)
                // Same client cleanup an immediate `.gone` verdict performs in `deleteWorkspace` —
                // otherwise a deferred-but-confirmed delete would leave this workspace's browser windows
                // and terminal panes open indefinitely.
                closeLocalBrowserSessionWindows(workspaceID: workspaceID, configuredBrowserSessionTargetURLs: pending.browserSessionTargetURLs)
                closeWorkspaceTerminalPanes(workspaceID: workspaceID)
                if showsBranchOutcomeNotice {
                    showInfoMessage(title: "Deleted workspace", message: Self.workspaceDeletionBranchOutcomeUnknownMessage)
                }
            }
        }
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
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .flagsChanged { return self.handleLeaderShortcutCaptureFlagsChanged(event: event) ? nil : event }
            // A focused terminal pane owns ordinary terminal input; app shortcut
            // chords run first so leader-backed shortcuts still work inside panes.
            let focusedPaneContent = self.panelCoordinator.contentOwning(responder: NSApp.keyWindow?.firstResponder)
            var focusedTerminalDisposition: ShortcutMonitorDisposition?
            if let focusedPaneContent {
                self.panelCoordinator.noteContentFocused(focusedPaneContent)
                let disposition = Self.shortcutMonitorDisposition(
                    eventModifiers: event.modifierFlags, firstResponderIsTerminalPane: true, shortcutLeaderModifiers: self.shortcutLeaderModifiers)
                focusedTerminalDisposition = disposition
                if disposition == .passEventToTerminal { return focusedPaneContent.handleKeyEvent(event) ? nil : event }
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
            if self.handleNewTabSessionPickerShortcut(event: event) { return nil }
            if self.handleClosePaneShortcut(event: event) { return nil }
            if self.handleFocusedTextInputShortcut(event: event) { return nil }
            if self.isTextInputFocused() { return event }
            if self.handleSidebarNavigationShortcut(event: event) { return nil }
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
            // App shortcuts did not claim the chord. Command shortcuts fall through
            // to terminal command-equivalent handling; non-Command leader chords
            // fall through to the pane's normal key handling, including image paste.
            if let focusedPaneContent, focusedPaneContent.handleCommandKeyEquivalent(event) { return nil }
            if focusedTerminalDisposition == .runAppShortcutsThenTerminal, let focusedPaneContent {
                return focusedPaneContent.handleKeyEvent(event) ? nil : event
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

    enum ShortcutMonitorDisposition: Equatable, Sendable {
        /// Send the event directly to the focused terminal pane before the shortcut
        /// chain handles it.
        case passEventToTerminal
        /// Run the app-shortcut chain; unhandled events still fall through to the
        /// window, whose key routing forwards them to the focused pane.
        case runAppShortcuts
        /// Run the app-shortcut chain first, then send an unclaimed event directly
        /// to the focused terminal pane.
        case runAppShortcutsThenTerminal
    }

    /// Keyboard routing for the local shortcut monitor once terminals live inside app
    /// windows as panes: a focused terminal owns ordinary input, while ⌘ chords and
    /// configured leader chords run app shortcuts first. With no terminal focused,
    /// all shortcuts run as before.
    nonisolated static func shortcutMonitorDisposition(
        eventModifiers: NSEvent.ModifierFlags, firstResponderIsTerminalPane: Bool, shortcutLeaderModifiers: Set<HotkeyModifier> = []
    ) -> ShortcutMonitorDisposition {
        guard firstResponderIsTerminalPane else { return .runAppShortcuts }
        let modifiers = eventShortcutModifiers(from: eventModifiers)
        if modifiers.contains(.cmd) { return .runAppShortcuts }
        if !shortcutLeaderModifiers.isEmpty, modifiers.isSuperset(of: shortcutLeaderModifiers) { return .runAppShortcutsThenTerminal }
        return .passEventToTerminal
    }

    /// ⌘W closes the active panel's focused pane — the last pane of a tab takes the
    /// tab with it, and a global panel window's last tab closes the window. In the
    /// main window it targets the selected workspace's panel; with no pane to close,
    /// ⌘W keeps its default behavior.
    private func handleClosePaneShortcut(event: NSEvent) -> Bool {
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
    private func handleNewTabSessionPickerShortcut(event: NSEvent) -> Bool {
        guard let newTabShortcutSpec, matches(event: event, spec: newTabShortcutSpec) else { return false }
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

    func shortcutModifiers(from flags: NSEvent.ModifierFlags) -> Set<HotkeyModifier> { Self.eventShortcutModifiers(from: flags) }

    nonisolated static func eventShortcutModifiers(from flags: NSEvent.ModifierFlags) -> Set<HotkeyModifier> {
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

    /// Leader+↑/↓ moves the sidebar selection (Alerts and workspaces) from anywhere
    /// in the main window — including while a terminal pane owns the plain arrow
    /// keys. A matched chord is always consumed, so hitting a list edge doesn't leak
    /// the keystroke into the terminal.
    private func handleSidebarNavigationShortcut(event: NSEvent) -> Bool {
        if let sidebarPreviousShortcutSpec, matches(event: event, spec: sidebarPreviousShortcutSpec) {
            _ = sidebar.navigateSidebarSelection(direction: -1)
            return true
        }
        if let sidebarNextShortcutSpec, matches(event: event, spec: sidebarNextShortcutSpec) {
            _ = sidebar.navigateSidebarSelection(direction: 1)
            return true
        }
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

    // Reads every shortcut setting (up to twice each for leader-backed ones) against a single
    // resolver built once for the whole pass, instead of resolving the client database fresh per
    // setting: `shortcutSettingResolver()` resolves it once and every `value(key)` call below reuses
    // that same handle.
    func loadShortcutSpecs() {
        let resolver = shortcutSettingResolver()
        if let modifiers = try? resolver.leaderModifiers() {
            shortcutLeaderModifiers = modifiers
        } else {
            shortcutLeaderModifiers = (try? HotkeySpec.parseModifierSet(ClientSettingsKey.defaultGUILeaderHotkey)) ?? [.cmd, .alt]
        }
        toggleShortcutSpec = loadShortcutSpec(resolver, setting: .guiHotkey)
        commandPaletteShortcutSpec = loadShortcutSpec(resolver, setting: .guiCommandPaletteHotkey)
        alerts.alertsShortcutSpec = loadShortcutSpec(resolver, setting: .guiAlertsShortcut)
        addWorkspaceShortcutSpec = loadShortcutSpec(resolver, setting: .guiAddWorkspaceShortcut)
        reloadShortcutSpec = loadShortcutSpec(resolver, setting: .guiReloadShortcut)
        nextShortcutSpec = loadShortcutSpec(resolver, setting: .guiNextShortcut)
        previousShortcutSpec = loadShortcutSpec(resolver, setting: .guiPreviousShortcut)
        sidebarNextShortcutSpec = loadShortcutSpec(resolver, setting: .guiSidebarNextShortcut)
        sidebarPreviousShortcutSpec = loadShortcutSpec(resolver, setting: .guiSidebarPreviousShortcut)
        openEditorShortcutSpec = loadShortcutSpec(resolver, setting: .guiOpenEditorShortcut)
        openTerminalShortcutSpec = loadShortcutSpec(resolver, setting: .guiOpenTerminalShortcut)
        newTabShortcutSpec = loadShortcutSpec(resolver, setting: .guiNewTabShortcut)
        openFinderShortcutSpec = loadShortcutSpec(resolver, setting: .guiOpenFinderShortcut)
        openSettingsShortcutSpec = loadShortcutSpec(resolver, setting: .guiOpenSettingsShortcut)
        windowShortcutSpec = loadShortcutSpec(resolver, setting: .guiWindowShortcut)
    }

    private func loadShortcutSpec(_ resolver: ShortcutSettingResolver, setting: ShortcutSetting) -> HotkeySpec? {
        if let stored = try? HotkeySpec.parse(resolver.rawValue(for: setting)) { return stored }
        return try? HotkeySpec.parse(setting.defaultSpec)
    }

    private func setShortcutSetting(setting: ShortcutSetting, value: String?) throws {
        let normalized = try shortcutSettingResolver().normalizedValue(for: setting, rawValue: value)
        try clientDatabase().setSetting(key: setting.settingKey, value: normalized)
    }

    // The client database is resolved once, eagerly, when the resolver is built rather than lazily
    // inside `value` — so every setting this resolver reads (an entire `loadShortcutSpecs()` pass, or
    // a single `setShortcutSetting()` write) shares one handle instead of calling `clientDatabase()`
    // per read.
    private func shortcutSettingResolver() -> ShortcutSettingResolver {
        let database = Result { try self.clientDatabase() }
        return ShortcutSettingResolver(value: { key in try database.get().setting(key: key) })
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
        case .guiSidebarNextShortcut: return sidebarNextShortcutSpec
        case .guiSidebarPreviousShortcut: return sidebarPreviousShortcutSpec
        case .guiOpenEditorShortcut: return openEditorShortcutSpec
        case .guiOpenTerminalShortcut: return openTerminalShortcutSpec
        case .guiNewTabShortcut: return newTabShortcutSpec
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
        let targetContext = Self.windowFocusTarget(for: request, overview: overview)
        return await executeWindowFocusResolution(
            Self.windowFocusResolution(for: request, overview: overview), preferredTarget: targetContext?.target,
            preferredDetail: targetContext?.detail)
    }

    private func runWindowShortcut(index: Int, startedAt: Date) async {
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
    private func windowShortcutResolution(index: Int) -> DeviceWindowShortcutResolution { windowShortcutResolutionContext(index: index).resolution }

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

    /// Focuses the local Chrome tab for a workspace browser session. Browser-session window ids are
    /// client state keyed by resolved URL; multiple browser sessions in the same workspace may point
    /// at the same Chrome window so they stay grouped as tabs. Re-focus first uses the tracked window
    /// id for the fast path, then scans all Chrome windows for a matching URL so a tab the user moved
    /// by hand is adopted into tracking instead of duplicated. `NSWorkspace.open` is a last resort
    /// when Chrome cannot be scripted. Remote service sessions use this after their URL has been
    /// routed through the Mac Caddy router.
    private func focusLocalChromeTab(workspaceID: String, targetURL: String, siblingTargetURLs: [String], fallbackURL: URL) async {
        let startedAt = Date()
        let result: BrowserFocusResult = await Task.detached(priority: .userInitiated) {
            let chrome = ChromeAdapter()
            let store = ClientBrowserWindowIDStore()
            let dbLookupStartedAt = Date()
            let trackedEntries = ((try? store.windowIDs(workspaceID: workspaceID)) ?? []).filter { $0.windowID > 0 }
            let trackedID = trackedEntries.first(where: { AppKitController.browserSessionTargetURL($0.targetURL, matches: targetURL) })?.windowID
            let clientDBLookupMS = TerminalPerformance.elapsedMS(since: dbLookupStartedAt)
            var chromeAppleScriptMS = 0
            var clientDBWriteMS = 0
            if let trackedID {
                let chromeStartedAt = Date()
                let didFocus =
                    (try? chrome.focusMatchingTabInWindow(windowID: trackedID, urlPrefix: targetURL, excludingURLPrefixes: siblingTargetURLs))
                    ?? false
                chromeAppleScriptMS += TerminalPerformance.elapsedMS(since: chromeStartedAt)
                if didFocus {
                    return BrowserFocusResult(
                        focused: true, path: "focused_tracked", clientDBLookupMS: clientDBLookupMS, clientDBWriteMS: clientDBWriteMS,
                        chromeAppleScriptMS: chromeAppleScriptMS)
                }
            }

            let allWindowFocusStartedAt = Date()
            let relocatedMatch = try? chrome.focusFirstMatchingTabMatch(urlPrefix: targetURL, excludingURLPrefixes: siblingTargetURLs)
            chromeAppleScriptMS += TerminalPerformance.elapsedMS(since: allWindowFocusStartedAt)
            if let relocatedMatch {
                let dbWriteStartedAt = Date()
                try? store.setWindowID(workspaceID: workspaceID, targetURL: targetURL, windowID: relocatedMatch.windowID)
                clientDBWriteMS += TerminalPerformance.elapsedMS(since: dbWriteStartedAt)
                return BrowserFocusResult(
                    focused: true, path: "focused_all_windows", clientDBLookupMS: clientDBLookupMS, clientDBWriteMS: clientDBWriteMS,
                    chromeAppleScriptMS: chromeAppleScriptMS)
            }

            let candidateWindowIDs = trackedEntries.map(\.windowID)
            let candidateURLPrefixes = trackedEntries.map(\.targetURL)
            let groupedTabStartedAt = Date()
            let groupedWindowID = try? chrome.openTabInFirstAvailableWindow(
                windowIDs: candidateWindowIDs, containingAnyURLPrefix: candidateURLPrefixes, url: targetURL, background: false)
            chromeAppleScriptMS += TerminalPerformance.elapsedMS(since: groupedTabStartedAt)
            if let groupedWindowID {
                let dbWriteStartedAt = Date()
                try? store.setWindowID(workspaceID: workspaceID, targetURL: targetURL, windowID: groupedWindowID)
                clientDBWriteMS += TerminalPerformance.elapsedMS(since: dbWriteStartedAt)
                return BrowserFocusResult(
                    focused: true, path: "opened_grouped_tab", clientDBLookupMS: clientDBLookupMS, clientDBWriteMS: clientDBWriteMS,
                    chromeAppleScriptMS: chromeAppleScriptMS)
            }

            let chromeStartedAt = Date()
            let newWindowID = (try? chrome.openWindow(url: targetURL, background: false)) ?? -1
            chromeAppleScriptMS += TerminalPerformance.elapsedMS(since: chromeStartedAt)
            guard newWindowID > 0 else {
                return BrowserFocusResult(
                    focused: false, path: "fallback", clientDBLookupMS: clientDBLookupMS, clientDBWriteMS: clientDBWriteMS,
                    chromeAppleScriptMS: chromeAppleScriptMS)
            }
            let dbWriteStartedAt = Date()
            try? store.setWindowID(workspaceID: workspaceID, targetURL: targetURL, windowID: newWindowID)
            clientDBWriteMS += TerminalPerformance.elapsedMS(since: dbWriteStartedAt)
            return BrowserFocusResult(
                focused: true, path: "opened_window", clientDBLookupMS: clientDBLookupMS, clientDBWriteMS: clientDBWriteMS,
                chromeAppleScriptMS: chromeAppleScriptMS)
        }.value
        if !result.focused { NSWorkspace.shared.open(fallbackURL) }
        logPerfMetric(
            "browser_focus", target: URL(string: targetURL)?.host ?? targetURL, elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            success: result.focused,
            detail:
                "path=\(result.path) client_db_lookup_ms=\(result.clientDBLookupMS) client_db_write_ms=\(result.clientDBWriteMS) chrome_applescript_ms=\(result.chromeAppleScriptMS)"
        )
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
        case .workspaceAgentLauncher(_, let name):
            target = targets.first { $0.kind == .agentLauncher && normalizedRunRowName($0.launcherName ?? "") == normalizedRunRowName(name) }
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

    nonisolated private static func workspaceDetail(_ workspaceID: String, in overview: SpacesDeviceOverviewPayload)
        -> SpacesDeviceWorkspaceDetailViewModel?
    { overview.workspaces.first(where: { $0.id == workspaceID }).map(SpacesDeviceWorkspaceDetailViewModel.init) }

    /// The single window-shortcut dispatcher for every device. It executes the resolved
    /// target, then applies the window-shortcut profiling and app-hide handling. The
    /// focus work itself lives in `executeWindowFocusResolution` so the cycle and
    /// command-palette paths reuse it.
    private func dispatchWindowShortcut(
        _ context: WindowFocusResolutionContext, index: Int, startedAt: Date, shortcutDispatchMS: Int, targetResolutionMS: Int
    ) async {
        let routeStartedAt = Date()
        let resolution = context.resolution
        let kind = Self.windowShortcutKind(for: resolution)
        guard let action = await executeWindowFocusResolution(resolution, preferredTarget: context.target, preferredDetail: context.detail) else {
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
        hideAfterSuccessfulExternalWindowAction(action)
        activeWindowShortcutProfile = nil
    }

    /// Executes a resolved focus target on the client and reports the resulting window
    /// action, or nil when nothing was focused (the executor surfaces its own errors).
    /// Shared by the numbered-shortcut, command-palette, and cycle focus paths so all
    /// three behave identically. Only two leaves depend on where the workspace's daemon
    /// runs: browser URLs may need remote-service routing before local Chrome focus, and
    /// terminal windows use native sessions locally vs Device API mirrors remotely.
    @discardableResult func executeWindowFocusResolution(
        _ resolution: DeviceWindowShortcutResolution, requestID: String? = nil, preferredTarget: WorkspaceRunShortcutTarget? = nil,
        preferredDetail: SpacesDeviceWorkspaceDetailViewModel? = nil, preserveWindowCycleSession: Bool = false
    ) async -> ExternalWindowAction? {
        switch resolution {
        case .openURL(let workspaceID, let targetURL):
            guard let url = URL(string: targetURL) else {
                showError(WorkspaceError.invalidArgument(message: "Browser session URL is invalid."))
                return nil
            }
            // Whether the URL needs remote-service routing depends on the owning device. With no
            // known owner there is no answer, and opening the raw URL would point this Mac's
            // Chrome at a localhost port that belongs to another machine's workspace.
            guard let workspaceDeviceID = deviceID(forWorkspaceID: workspaceID) else {
                showDeviceNotLoadedError()
                return nil
            }
            let browserSessionTargetURLs = Self.browserSessionTargetURLs(
                workspaceID: workspaceID, targetURL: targetURL, overview: overview(forWorkspaceID: workspaceID))
            let siblingTargetURLs = Self.browserSessionSiblingTargetURLs(targetURL: targetURL, targetURLs: browserSessionTargetURLs)
            if isRemoteDeviceID(workspaceDeviceID) {
                guard let device = deviceForWorkspaceMutation(workspaceID: workspaceID) else {
                    showWorkspaceDeviceUnavailableError(workspaceID: workspaceID)
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
                    refreshVisibleServicePortDisplays(deviceID: device.id)
                    await focusLocalChromeTab(
                        workspaceID: workspaceID, targetURL: routedTarget.targetURL.absoluteString, siblingTargetURLs: routedTarget.siblingTargetURLs,
                        fallbackURL: routedTarget.targetURL)
                case .failure(let error):
                    showError(error)
                    return nil
                }
            } else {
                await focusLocalChromeTab(workspaceID: workspaceID, targetURL: targetURL, siblingTargetURLs: siblingTargetURLs, fallbackURL: url)
            }
            Self.setClientActiveWorkspaceID(workspaceID)
            rememberWindowNavigationFocus(
                resolution: resolution, preferredTarget: preferredTarget, preferredDetail: preferredDetail,
                preserveWindowCycleSession: preserveWindowCycleSession)
            return .focus(hidesApp: true)
        case .openTerminal(let request):
            guard await openOrFocusTerminalTarget(request, requestID: requestID) else { return nil }
            rememberWindowNavigationFocus(
                resolution: resolution, preferredTarget: preferredTarget, preferredDetail: preferredDetail,
                preserveWindowCycleSession: preserveWindowCycleSession)
            return .focus(hidesApp: false)
        case .runProcess(let workspaceID, let processKey, let processTemplateID):
            guard
                let action = await runTerminalSessionMutationAndOpenPane(
                    workspaceID: workspaceID,
                    operation: { device in
                        try SpacesDeviceClient.runWorkspaceProcess(
                            workspaceID: workspaceID, processKey: processKey, processTemplateID: processTemplateID, device: device,
                            clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                    })
            else { return nil }
            rememberWindowNavigationFocus(
                resolution: resolution, preferredTarget: preferredTarget, preferredDetail: preferredDetail,
                preserveWindowCycleSession: preserveWindowCycleSession)
            return action
        case .runCodingAgent(let workspaceID, let agentName, let agentLauncherID):
            guard
                let action = await runTerminalSessionMutationAndOpenPane(
                    workspaceID: workspaceID,
                    operation: { device in
                        try SpacesDeviceClient.runCodingAgent(
                            workspaceID: workspaceID, agentName: agentName, agentLauncherID: agentLauncherID, device: device,
                            clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
                    })
            else { return nil }
            rememberWindowNavigationFocus(
                resolution: resolution, preferredTarget: preferredTarget, preferredDetail: preferredDetail,
                preserveWindowCycleSession: preserveWindowCycleSession)
            return action
        case .noWorkspace, .noMatch: return nil
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
        func logTerminalPaneFocus(success: Bool, reason: String = "") {
            let reasonDetail = reason.isEmpty ? "" : " reason=\(reason)"
            logPerfMetric(
                "terminal_pane_focus", target: "session=\(request.sessionID)", elapsedMS: windowShortcutElapsedMS(since: startedAt), success: success,
                detail:
                    "request_resolution_ms=\(requestResolveMS) existing_pane_focus_ms=\(existingPaneFocusMS) pane_open_ms=\(paneOpenMS) ownership_request_ms=\(ownershipRequestMS) focus_observation_ms=\(focusObservationMS) focus_observed=\(focusObserved ? 1 : 0)\(requestDetail)\(reasonDetail)"
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
        // Focusing a terminal supersedes a still-pending "hide Spaces after a browser focus"
        // deferred task (a preceding `open <browser>` schedules one). Without this, that hide
        // fires just after we foreground the terminal and re-hides the app, leaving
        // `NSApp.isActive` false — which breaks window-cycle current-target resolution
        // (`focusedBuiltInTerminalSessionIDForGlobalNavigation`). Mirrors `openTerminalSessionPane`.
        cancelDeferredExternalWindowHide()
        // A row-built resolution can predate the session's overview entry and lack the
        // real shell/command. Only recover that metadata when opening a new pane: an
        // already-open pane already has its state model and can focus entirely client-side.
        let existingPaneBeforeResolution = panelCoordinator.placement(forSessionID: request.sessionID) != nil
        let requestResolveStartedAt = Date()
        let openRequest: DeviceTerminalOpenRequest
        if Self.terminalOpenRequestNeedsColdResolution(request, hasExistingPane: existingPaneBeforeResolution) {
            openRequest = await resolveTerminalSessionPaneOpenRequest(sessionID: request.sessionID) ?? request
        } else {
            openRequest = request
        }
        requestResolveMS = windowShortcutElapsedMS(since: requestResolveStartedAt)
        let reusedExistingPane = existingPaneBeforeResolution || panelCoordinator.placement(forSessionID: openRequest.sessionID) != nil
        let paneFocusStartedAt = Date()
        guard panelCoordinator.openOrFocusTerminalPane(openRequest) else {
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
        switch await Self.deviceMutation(device: device, operation: operation) {
        case .success(let response):
            applyDeviceMutationResponse(response, deviceID: device.id, selectedWorkspaceID: workspaceID)
            return terminalOpenRequest(fromMutationResponse: response, workspaceID: workspaceID)
        case .failure(let error):
            showError(error)
            return nil
        }
    }

    private func runTerminalSessionMutationAndOpenPane(
        workspaceID: String, operation: @Sendable @escaping (SpacesPairedDeviceRecord) throws -> SpacesDeviceAPIResponse
    ) async -> ExternalWindowAction? {
        guard let request = await runTerminalSessionMutation(workspaceID: workspaceID, operation: operation), await openOrFocusTerminalTarget(request)
        else { return nil }
        return .focus(hidesApp: false)
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
                workspaceID: workspaceID, delta: direction > 0 ? 1 : -1, preferredTerminalSessionID: preferredFocusedBuiltInTerminalSessionID,
                requestID: requestID)
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
        return Self.workspaceIDForObservedBrowserURL(activeURL, in: deviceSections.compactMap(\.overview))
    }

    nonisolated static func workspaceIDForObservedBrowserURL(_ activeURL: String, in overviews: [SpacesDeviceOverviewPayload]) -> String? {
        var best: (workspaceID: String, prefixLength: Int)?
        for overview in overviews {
            for workspace in overview.workspaces {
                let configuredTargetURLs = browserSessionTargetURLs(resolvedSessions: workspace.config.resolvedBrowserSessions)
                for session in workspace.config.resolvedBrowserSessions {
                    guard let url = session.url, !url.isEmpty else { continue }
                    let siblingTargetURLs = browserSessionSiblingTargetURLs(targetURL: url, targetURLs: configuredTargetURLs)
                    guard
                        let matchLength = browserObservedURLMatchLength(
                            activeURL, targetURL: url, siblingTargetURLs: siblingTargetURLs, assignedPorts: workspace.assignedPorts)
                    else { continue }
                    if best == nil || matchLength > best!.prefixLength { best = (workspace.id, matchLength) }
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
                "toggle_window_selection_refresh", target: "workspace=\(focusedWorkspaceID ?? "keep_current")",
                elapsedMS: self.windowShortcutElapsedMS(since: refreshStartedAt), success: true, detail: "source=\(source)")
        }
    }

    private func refreshWorkspaceSelectionForActivation(focusedWorkspaceID: String?) {
        guard case .workspace(let targetWorkspaceID)? = Self.activationSelectionTarget(focusedWorkspaceID: focusedWorkspaceID) else {
            // No tracked focused window: re-render the current pane so its contents are fresh, without
            // changing which pane is shown.
            refreshSelection()
            return
        }
        guard let (_, workspace) = findWorkspace(id: targetWorkspaceID) else { return }
        if selectedWorkspaceID == targetWorkspaceID, !showingAlerts, !showingSettings {
            refreshSelection()
            return
        }
        selectWorkspace(workspace)
    }

    @objc func showProjectSettings(_ sender: NSButton) {
        guard let projectID = sender.identifier?.rawValue, let project = projects.first(where: { $0.id == projectID }) else { return }
        showProjectSettingsDialog(project: project)
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
            // A non-git project stands in for its single workspace, so its project settings are the
            // config that runs: sync the saved template to that workspace unconditionally. Git
            // projects keep the template/per-workspace split and only sync a pending import when the
            // user chose Update All Workspaces.
            let updateAllWorkspaces = Self.projectSaveSyncsAllWorkspaces(
                isGitRepo: isGitProject(refs.projectID), pendingImportUpdateAllWorkspaces: refs.pendingImportUpdateAllWorkspaces)
            let response = try SpacesDeviceClient.updateProjectConfig(
                projectID: refs.projectID, config: Self.deviceProjectConfig(from: refs), updateAllWorkspaces: updateAllWorkspaces, device: device,
                clientApp: SpacesDeviceClient.macOSClientApp(appVersion: AppVersion.short))
            refs.hasPendingImportedConfig = false
            refs.pendingImportUpdateAllWorkspaces = false
            refs.discardImportedConfigButton.isHidden = true
            applyDeviceMutationResponse(response, deviceID: device.id)
            return
        }
        throw deviceUnavailableError(deviceID: selectedRowDeviceID() ?? SpacesPairedDeviceRecord.localDeviceID)
    }

    private func commitEditing() {
        let windows = [window, NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
        for window in windows {
            window.endEditing(for: nil)
            _ = window.makeFirstResponder(nil)
        }
    }

    private func validateServiceEditorsCommitted(_ portsSection: PortsSection, before action: String) -> Bool {
        guard !portsSection.hasOpenEditor else {
            showInfoMessage(
                title: "Finish service name",
                message:
                    "Service names cannot be empty and must use lowercase letters, digits, or hyphens, starting and ending with a letter or digit, before \(action)."
            )
            return false
        }
        return true
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
        case .terminalSession(let workspaceID, let sessionID): return "terminal-session:\(workspaceID):\(sessionID)"
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
        case .terminalSession(let workspaceID, let sessionID): return "terminal-session:\(workspaceID):\(sessionID)"
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
            case .exited: return RowPrimitives.statusDot(.exited)
            }
        }
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

    /// Session-picker visibility: the rows are host-ordered ("New terminal session"
    /// first, then the sessions in scope) and each row is a distinct choice, so an
    /// empty query shows the list head directly. The normal palette's recency ranking
    /// and focus-identity dedup would collapse picker rows, which are all built
    /// around the same placeholder focus request.
    nonisolated static func visibleSessionPickerItems(allItems: [CommandPaletteItem], query: String, maxEmptyQueryItems: Int = 10)
        -> [CommandPaletteItem]
    {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty { return Array(allItems.prefix(maxEmptyQueryItems)) }
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
        case .terminalSession: return .window
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
                        let rowText = terminalFallbackRowText(
                            name: windows[windowListIndex].name, detail: windows[windowListIndex].detail, app: windows[windowListIndex].app)
                        items.append(
                            CommandPaletteItem(
                                id: itemID, source: .workspaceTarget, alertsAttentionID: nil, workspaceID: workspace.id,
                                workspaceTitle: workspace.displayName, workspaceBranch: workspace.branch, projectTitle: project.name,
                                kind: target.kind, label: rowText.label, detail: rowText.detail, status: .none,
                                focusRequest: .workspaceWindow(workspaceID: workspace.id, index: windowListIndex + 1),
                                // Recency is keyed off the row's name: which row was last focused must not
                                // turn on what its program happens to be printing.
                                recentFocusIdentity: CommandPaletteItem.recentFocusIdentity(
                                    for: .workspaceWindow(workspaceID: workspace.id, index: windowListIndex + 1), detail: rowText.label)))
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
