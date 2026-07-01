import AppKit
import Carbon
import Foundation
import spacesterminalcore
import spacesterminalghostty

/// Raised when the injected state provider has no device-owned state to render
/// yet. The window controller surfaces the existing "unavailable" UI rather than
/// reading the daemon's `spaces.db` directly.
enum TerminalSessionStateUnavailableError: Error {
    case launchConfigurationUnavailable
}

@MainActor private final class TerminalSessionWindow: NSWindow {
    var terminalKeyEventHandler: ((NSEvent) -> Bool)?
    var terminalCommandKeyEquivalentHandler: ((NSEvent) -> Bool)?

    private var terminalController: TerminalSessionWindowController? { windowController as? TerminalSessionWindowController }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, terminalKeyEventHandler?(event) == true { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.command] || flags == [.command, .shift] else { return super.performKeyEquivalent(with: event) }

        switch Int(event.keyCode) {
        case kVK_ANSI_Q where flags == [.command], kVK_ANSI_W where flags == [.command]:
            performClose(nil)
            return true
        default:
            if terminalCommandKeyEquivalentHandler?(event) == true { return true }
            return super.performKeyEquivalent(with: event)
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        terminalController?.validateUserInterfaceItem(item) ?? true
    }

    @objc func copy(_ sender: Any?) { terminalController?.copy(sender) }

    @objc func paste(_ sender: Any?) { terminalController?.paste(sender) }

    override func selectAll(_ sender: Any?) { terminalController?.selectAll(sender) }

    @objc func find(_ sender: Any?) { terminalController?.find(sender) }

    @objc func findNext(_ sender: Any?) { terminalController?.findNext(sender) }

    @objc func findPrevious(_ sender: Any?) { terminalController?.findPrevious(sender) }

    @objc func useSelectionForFind(_ sender: Any?) { terminalController?.useSelectionForFind(sender) }

    @objc func hideFind(_ sender: Any?) { terminalController?.hideFind(sender) }
}

public struct TerminalSessionWindowDebugState: Sendable, Codable, Equatable {
    public let renderedOutput: String
    public let visibleSurfaceOutput: String?
    public let showsTerminalSurface: Bool
    public let showsTextRenderer: Bool
    public let rendererSummary: String
    public let summary: String
    public let state: String
    public let windowTitle: String
    public let didCloseWindow: Bool
    public let surfaceColumns: Int?
    public let surfaceRows: Int?
    public let windowIsKey: Bool
    public let firstResponderTypeName: String?
    public let searchVisible: Bool
    public let searchQuery: String
    public let searchTotal: Int?
    public let searchSelected: Int?
    public let attachmentMode: String
    public let takeoverPending: Bool
    public let takeoverButtonVisible: Bool
    public let takeoverButtonEnabled: Bool
    public let takeoverMessage: String
}

@MainActor public struct TerminalSessionRuntimeControls {
    public let title: String
    public let canRun: Bool
    public let canStop: Bool
    public let canRestart: Bool
    public let onRun: (@MainActor @Sendable () -> Void)?
    public let onStop: (@MainActor @Sendable () -> Void)?
    public let onRestart: (@MainActor @Sendable () -> Void)?

    public init(
        title: String, canRun: Bool, canStop: Bool, canRestart: Bool, onRun: (@MainActor @Sendable () -> Void)? = nil,
        onStop: (@MainActor @Sendable () -> Void)? = nil, onRestart: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.title = title
        self.canRun = canRun
        self.canStop = canStop
        self.canRestart = canRestart
        self.onRun = onRun
        self.onStop = onStop
        self.onRestart = onRestart
    }

    public var hasActions: Bool { canRun || canStop || canRestart }
}

@MainActor public final class TerminalSessionWindowController: NSWindowController, NSWindowDelegate, NSUserInterfaceValidations {
    private static let takeoverAttemptTimeout: TimeInterval = 10
    static let isRunningUnderXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    enum VisibleRenderer {
        case ghosttyOwner
        case ghosttyTakeoverStatus
        case ghosttyEndedFinalRender
        case unavailable
        case textView
    }

    private enum OwnershipTransitionTarget: String {
        case owner
        case viewer
    }

    private enum PendingGhosttyHostAttachment {
        case owner(requestID: String?, reason: String, requestWindowFocus: Bool)
        case finalRender(reason: String)
    }

    struct OutputViewportState {
        let wasPinnedToBottom: Bool
        let horizontalOffset: CGFloat
        let offsetFromBottom: CGFloat
        let selectedRange: NSRange
    }

    let sessionID: String
    private let paths: TerminalSessionPaths
    /// Device-owned terminal state (launch config, runtime state, attachment
    /// ownership, latest render payload), reached through the Device API by the
    /// injected provider. The window controller never opens the daemon's
    /// `spaces.db`; all session state reads go through this provider.
    private let stateProvider: any TerminalSessionStateProviding
    private var launchConfiguration: TerminalSessionLaunchConfiguration?
    let client: TerminalClient
    var rendererMode: TerminalRendererMode
    var backend: TerminalSessionBackendKind
    var preferredAttachmentMode: TerminalAttachmentMode
    private var ownerAttachmentRequested: Bool
    let titleLabel = NSTextField(labelWithString: "")
    let summaryLabel = NSTextField(labelWithString: "")
    let stateLabel = NSTextField(labelWithString: "")
    let rendererLabel = NSTextField(labelWithString: "")
    let runtimeToolbarStackView = NSStackView()
    let runtimeToolbarTitleLabel = NSTextField(labelWithString: "")
    let runtimeToolbarRunButton = NSButton()
    let runtimeToolbarStopButton = NSButton()
    let runtimeToolbarRestartButton = NSButton()
    let runtimeToolbarButtonStackView = NSStackView()
    let runtimeToolbarSpacerView = NSView()
    let inputField = NSTextField(string: "")
    let inputStatusLabel = NSTextField(labelWithString: "")
    let sendButton = NSButton(title: "Send", target: nil, action: nil)
    let interruptButton = NSButton(title: "Ctrl+C", target: nil, action: nil)
    let newlineButton = NSButton(title: "Enter", target: nil, action: nil)
    let takeoverButton = NSButton(title: "Take Over", target: nil, action: nil)
    let takeoverMessageLabel = NSTextField(labelWithString: "")
    let inputRowStackView = NSStackView()
    let actionButtonStackView = NSStackView()
    let takeoverRowStackView = NSStackView()
    let takeoverContainerView = NSView()
    let outputView = NSTextView(frame: NSRect(x: 0, y: 0, width: 880, height: 400))
    let outputScrollView = NSScrollView()
    let terminalContainer = NSView()
    let headerStackView = NSStackView()
    let bodyStackView = NSStackView()
    var bodyTopToHeaderConstraint: NSLayoutConstraint?
    var bodyTopToContentConstraint: NSLayoutConstraint?
    var bodyBottomToContentConstraint: NSLayoutConstraint?
    var bodyBottomToTakeoverConstraint: NSLayoutConstraint?
    var bodyLeadingConstraint: NSLayoutConstraint?
    var bodyTrailingConstraint: NSLayoutConstraint?
    var takeoverLeadingConstraint: NSLayoutConstraint?
    var takeoverTrailingConstraint: NSLayoutConstraint?
    var takeoverBottomConstraint: NSLayoutConstraint?
    var takeoverCenterYConstraint: NSLayoutConstraint?
    /// When a non-owner is viewing an interactive session, the window collapses
    /// to a centered message plus the Take Over button instead of the full
    /// header/output detail stack.
    var isViewerTakeoverShellActive = false
    let sendInputAction: @Sendable (String, Bool) throws -> TerminalControlResponse
    let sendKeyAction: @Sendable (String) throws -> TerminalControlResponse
    private let takeoverAction: @Sendable (String) throws -> TerminalControlResponse
    private let attachClientAction: @Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void
    private let detachClientAction: @Sendable (String) throws -> Void
    let detachClientSynchronouslyOnClose: Bool
    /// When true, `show()` does not eagerly attach the live Ghostty client; the
    /// deferred-presentation path attaches it once the owner surface is ready. The
    /// app passes false so an injected attach happens immediately; metadata-only
    /// callers (and tests) pass true to refresh title/ownership without a live surface.
    private let defersInitialOwnerClientAttach: Bool
    let copySelectionAction: (@MainActor () -> Bool)?
    let pasteClipboardAction: (@MainActor () -> Bool)?
    private let ownerWindowFocusAction: (@MainActor (NSWindow?) -> Void)?
    private let ownerSurfaceFocusAction: (@MainActor (Bool) -> Void)?
    let onWindowFocus: (@MainActor (String) -> Void)?
    let onWindowClose: (@MainActor (String, String, Bool) -> Void)?
    let runtimeControlsProvider: (@MainActor (String) -> TerminalSessionRuntimeControls?)?
    let loadWindowFrameAction: (TerminalAttachmentMode) throws -> TerminalSessionWindowFrame?
    let saveWindowFrameAction: (TerminalSessionWindowFrame, TerminalAttachmentMode) throws -> Void
    private let sessionHostProvider: @MainActor (TerminalSessionLaunchConfiguration, TerminalSessionPaths) -> any TerminalGhosttySessionHosting
    private var clientGhosttySessionHost: (any TerminalGhosttySessionHosting)?
    private var isResolvingGhosttySessionHost = false
    private var pendingGhosttyHostAttachment: PendingGhosttyHostAttachment?
    private var activeGhosttySessionHost: (any TerminalGhosttySessionHosting)?
    var takeoverTask: Task<Void, Never>?
    var takeoverTaskStartedAt: Date?
    private var takeoverAttemptID: UUID?
    var pendingWindowFramePersistTask: Task<Void, Never>?
    var lastRenderedOutput = ""
    var isClientAttached = false
    var lastRequestedAttachmentMode: TerminalAttachmentMode?
    var closesForSessionTermination = false
    var didCloseWindow = false
    private var lastObservedAttachmentMode: TerminalAttachmentMode?
    var ghosttyRendererHost: (any TerminalGhosttyRendererHosting)?
    var ghosttySessionInfoProvider: (any TerminalGhosttySessionInfoProviding)?
    var visibleRenderer: VisibleRenderer = .textView
    private var lastObservedOwnerClientID: String?
    var lastObservedRuntimeState: TerminalSessionRuntimeState?
    var shouldShowOwnerStateLabel = true
    var runtimeControls: TerminalSessionRuntimeControls?
    var runtimeControlsDirty = true
    var inputStatusIsError = false
    var appDidBecomeActiveObserver: NSObjectProtocol?
    var appDidResignActiveObserver: NSObjectProtocol?
    var attachmentStateDidChangeObserver: NSObjectProtocol?
    var sessionMetadataDidChangeObserver: NSObjectProtocol?
    var runtimeStateDidChangeObserver: NSObjectProtocol?
    var outputDidChangeObserver: NSObjectProtocol?
    var hasTestWindowPresentation = false
    private var pendingOwnershipTransitionStartedAt: Date?
    private var pendingOwnershipTransitionTarget: OwnershipTransitionTarget?
    private var pendingOwnershipTransitionReason: String?
    private var pendingFocusObservationStartedAt: Date?
    private var pendingFocusObservationRequestID: String?
    private var pendingFocusObservationRoute: String?
    private var deferredInitialPresentationTask: Task<Void, Never>?
    var isDeferringInitialOwnerPresentation = false
    private var shouldActivateDeferredInitialOwnerPresentation = false
    private static let deferredInitialOwnerPresentationTimeout: TimeInterval = 5

    public convenience init(
        sessionID: String, paths: TerminalSessionPaths, stateProvider: any TerminalSessionStateProviding,
        preferredAttachmentMode: TerminalAttachmentMode = .owner, performInitialRefresh: Bool = true,
        sendInputAction: (@Sendable (String, Bool) throws -> TerminalControlResponse)? = nil,
        sendKeyAction: (@Sendable (String) throws -> TerminalControlResponse)? = nil,
        takeoverAction: (@Sendable (String) throws -> TerminalControlResponse)? = nil,
        attachClientAction: @escaping @Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void,
        detachClientAction: @escaping @Sendable (String) throws -> Void, copySelectionAction: (@MainActor () -> Bool)? = nil,
        detachClientSynchronouslyOnClose: Bool = true, defersInitialOwnerClientAttach: Bool = false,
        pasteClipboardAction: (@MainActor () -> Bool)? = nil,
        ownerWindowFocusAction: (@MainActor (NSWindow?) -> Void)? = nil, ownerSurfaceFocusAction: (@MainActor (Bool) -> Void)? = nil,
        onWindowFocus: (@MainActor (String) -> Void)? = nil, onWindowClose: (@MainActor (String, String, Bool) -> Void)? = nil,
        runtimeControlsProvider: (@MainActor (String) -> TerminalSessionRuntimeControls?)? = nil,
        loadWindowFrameAction: @escaping (TerminalAttachmentMode) throws -> TerminalSessionWindowFrame?,
        saveWindowFrameAction: @escaping (TerminalSessionWindowFrame, TerminalAttachmentMode) throws -> Void,
        sessionHostProvider: (@MainActor (TerminalSessionLaunchConfiguration, TerminalSessionPaths) -> any TerminalGhosttySessionHosting)? = nil
    ) {
        self.init(
            sessionID: sessionID, paths: paths, stateProvider: stateProvider, preferredAttachmentMode: preferredAttachmentMode,
            performInitialRefresh: performInitialRefresh,
            sendInputAction: sendInputAction, sendKeyAction: sendKeyAction, takeoverAction: takeoverAction, attachClientAction: attachClientAction,
            detachClientAction: detachClientAction, copySelectionAction: copySelectionAction,
            detachClientSynchronouslyOnClose: detachClientSynchronouslyOnClose, defersInitialOwnerClientAttach: defersInitialOwnerClientAttach,
            pasteClipboardAction: pasteClipboardAction,
            ownerWindowFocusAction: ownerWindowFocusAction, ownerSurfaceFocusAction: ownerSurfaceFocusAction, onWindowFocus: onWindowFocus,
            onWindowClose: onWindowClose, runtimeControlsProvider: runtimeControlsProvider, loadWindowFrameAction: loadWindowFrameAction,
            saveWindowFrameAction: saveWindowFrameAction,
            sessionHostProvider: sessionHostProvider ?? { launchConfiguration, paths in
                RemoteGhosttySessionHost(launchConfiguration: launchConfiguration, paths: paths)
            })
    }

    init(
        sessionID: String, paths: TerminalSessionPaths, stateProvider: any TerminalSessionStateProviding,
        preferredAttachmentMode: TerminalAttachmentMode = .owner, performInitialRefresh: Bool = true,
        sendInputAction: (@Sendable (String, Bool) throws -> TerminalControlResponse)? = nil,
        sendKeyAction: (@Sendable (String) throws -> TerminalControlResponse)? = nil,
        takeoverAction: (@Sendable (String) throws -> TerminalControlResponse)? = nil,
        attachClientAction: @escaping @Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void,
        detachClientAction: @escaping @Sendable (String) throws -> Void, copySelectionAction: (@MainActor () -> Bool)? = nil,
        detachClientSynchronouslyOnClose: Bool = true, defersInitialOwnerClientAttach: Bool = false,
        pasteClipboardAction: (@MainActor () -> Bool)? = nil,
        ownerWindowFocusAction: (@MainActor (NSWindow?) -> Void)? = nil, ownerSurfaceFocusAction: (@MainActor (Bool) -> Void)? = nil,
        onWindowFocus: (@MainActor (String) -> Void)? = nil, onWindowClose: (@MainActor (String, String, Bool) -> Void)? = nil,
        runtimeControlsProvider: (@MainActor (String) -> TerminalSessionRuntimeControls?)? = nil,
        loadWindowFrameAction: @escaping (TerminalAttachmentMode) throws -> TerminalSessionWindowFrame?,
        saveWindowFrameAction: @escaping (TerminalSessionWindowFrame, TerminalAttachmentMode) throws -> Void,
        sessionHostProvider: @escaping @MainActor (TerminalSessionLaunchConfiguration, TerminalSessionPaths) -> any TerminalGhosttySessionHosting
    ) {
        self.sessionID = sessionID
        self.paths = paths
        self.stateProvider = stateProvider
        self.preferredAttachmentMode = preferredAttachmentMode
        ownerAttachmentRequested = preferredAttachmentMode == .owner
        let resolvedLaunchConfiguration = stateProvider.currentLaunchConfiguration
        launchConfiguration = resolvedLaunchConfiguration
        let resolvedBackend = resolvedLaunchConfiguration?.backend ?? .ghosttyEmbedded
        backend = resolvedBackend
        rendererMode = TerminalRendererResolver.resolveGhosttyEmbeddedMode(backend: resolvedBackend)
        let now = ISO8601DateFormatter().string(from: Date())
        client = TerminalClient(
            kind: .localWindow,
            identity: TerminalClientIdentity(label: "Spaces window", hostName: Host.current().name, deviceName: Host.current().localizedName),
            connectedAt: now)
        self.sendInputAction =
            sendInputAction ?? { [socketPath = paths.controlSocketPath, client] text, appendNewline in
                try TerminalControlClient.send(
                    request: TerminalControlRequest(command: "send", text: text, clientID: client.id, appendNewline: appendNewline),
                    socketPath: socketPath)
            }
        self.sendKeyAction =
            sendKeyAction ?? { [socketPath = paths.controlSocketPath, client] key in
                try TerminalControlClient.send(request: TerminalControlRequest(command: "key", key: key, clientID: client.id), socketPath: socketPath)
            }
        self.takeoverAction =
            takeoverAction ?? { clientID in
                try TerminalControlClient.send(
                    request: TerminalControlRequest(command: "takeover", clientID: clientID), socketPath: paths.controlSocketPath)
            }
        self.attachClientAction = attachClientAction
        self.detachClientAction = detachClientAction
        self.detachClientSynchronouslyOnClose = detachClientSynchronouslyOnClose
        self.defersInitialOwnerClientAttach = defersInitialOwnerClientAttach
        self.copySelectionAction = copySelectionAction
        self.pasteClipboardAction = pasteClipboardAction
        self.ownerWindowFocusAction = ownerWindowFocusAction
        self.ownerSurfaceFocusAction = ownerSurfaceFocusAction
        self.onWindowFocus = onWindowFocus
        self.onWindowClose = onWindowClose
        self.runtimeControlsProvider = runtimeControlsProvider
        self.loadWindowFrameAction = loadWindowFrameAction
        self.saveWindowFrameAction = saveWindowFrameAction
        self.sessionHostProvider = sessionHostProvider

        let contentRect = NSRect(x: 0, y: 0, width: 980, height: 640)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = TerminalSessionWindow(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Terminal \(sessionID)"
        window.setAccessibilityIdentifier("spaces-terminal:\(sessionID)")
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 760, height: 420)
        super.init(window: window)
        window.delegate = self
        window.terminalKeyEventHandler = { [weak self] event in self?.handleTerminalWindowKeyEvent(event) ?? false }
        window.terminalCommandKeyEquivalentHandler = { [weak self] event in self?.handleTerminalWindowCommandKeyEquivalent(event) ?? false }
        startObservingApplicationActivation()
        buildUI()
        refreshRuntimeControlsIfNeeded(force: true)
        if performInitialRefresh { refreshNow() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { MainActor.assumeIsolated { stopObservingApplicationActivation() } }

    public func show(requestID: String? = nil, route: String? = nil) {
        guard let window else { return }
        stateProvider.refreshState()
        let startedAt = Date()
        let wasVisible = isWindowPresented(window) && !didCloseWindow
        let defersGhosttyClientAttach = backend == .ghosttyEmbedded && defersInitialOwnerClientAttach
        didCloseWindow = false
        if let launchConfiguration { updateGhosttySessionHostReference(for: launchConfiguration) }
        lastObservedRuntimeState = (stateProvider.currentRuntimeState) ?? lastObservedRuntimeState
        let attachStartedAt = Date()
        if !defersGhosttyClientAttach, backend != .ghosttyEmbedded || canAttachToGhosttyRuntime(lastObservedRuntimeState) {
            attachLocalClientIfNeeded(mode: initialAttachmentModeForShow())
        }
        logShowStage(startedAt: attachStartedAt, requestID: requestID, detail: "stage=attach_client deferred=\(defersGhosttyClientAttach ? 1 : 0)")
        let preRefreshStartedAt = Date()
        refreshNow(allowGhosttyOwnerAttach: false)
        logShowStage(startedAt: preRefreshStartedAt, requestID: requestID, detail: "stage=refresh_before_show")
        if !wasVisible {
            restorePersistedWindowFrame(window)
            constrainWindowToVisibleFrame(window)
        }
        if shouldDeferInitialOwnerPresentation(wasVisible: wasVisible) {
            startDeferredInitialOwnerPresentation(window: window, startedAt: startedAt, requestID: requestID, route: route)
            return
        }
        let presentStartedAt = Date()
        presentWindow(window, forceFrontmost: !wasVisible)
        logShowStage(startedAt: presentStartedAt, requestID: requestID, detail: "stage=present_window visible=\(wasVisible ? 1 : 0)")
        let attachSurfaceStartedAt = Date()
        if backend == .ghosttyEmbedded, canAttachToGhosttyRuntime(lastObservedRuntimeState) {
            ensureGhosttyHostAttached(requestID: requestID, reason: "show")
        }
        logShowStage(startedAt: attachSurfaceStartedAt, requestID: requestID, detail: "stage=attach_surface")
        let postRefreshStartedAt = Date()
        refreshNow()
        logShowStage(startedAt: postRefreshStartedAt, requestID: requestID, detail: "stage=refresh_after_show")
        let firstResponderStartedAt = Date()
        assignPreferredFirstResponder()
        logShowStage(startedAt: firstResponderStartedAt, requestID: requestID, detail: "stage=assign_first_responder")
        logFocusMetric("terminal_window_show", startedAt: startedAt, requestID: requestID, detail: "route=\(route ?? "show")")
    }

    private func initialAttachmentModeForShow() -> TerminalAttachmentMode {
        guard backend == .ghosttyEmbedded, preferredAttachmentMode == .owner else { return preferredAttachmentMode }
        guard let ownerClient = activeOwnerClient(snapshot: stateProvider.currentAttachmentSnapshot) else {
            return preferredAttachmentMode
        }
        return ownerClient.id == client.id ? .owner : .viewer
    }

    func shouldDeferInitialOwnerPresentation(wasVisible: Bool) -> Bool {
        shouldDeferInitialOwnerPresentation(wasVisible: wasVisible, runningUnderXCTest: Self.isRunningUnderXCTest)
    }

    func shouldDeferInitialOwnerPresentation(wasVisible: Bool, runningUnderXCTest: Bool) -> Bool {
        guard !isStartingRuntimeState(lastObservedRuntimeState) else { return false }
        return !runningUnderXCTest && !wasVisible && launchConfiguration != nil && backend == .ghosttyEmbedded && preferredAttachmentMode == .owner
            && !ownerRendererReadyForInitialPresentation()
    }

    private func ownerRendererReadyForInitialPresentation() -> Bool {
        guard backend == .ghosttyEmbedded, preferredAttachmentMode == .owner else { return true }
        guard !isExplicitlyNonInteractiveRuntimeState(lastObservedRuntimeState) else { return true }
        return visibleRenderer == .ghosttyOwner && ghosttyRendererHost?.hasRenderableSurface() == true
    }

    private func startDeferredInitialOwnerPresentation(window: NSWindow, startedAt: Date, requestID: String?, route: String?) {
        deferredInitialPresentationTask?.cancel()
        isDeferringInitialOwnerPresentation = true
        shouldActivateDeferredInitialOwnerPresentation = false
        updateRendererVisibility()
        let attachSurfaceStartedAt = Date()
        ensureGhosttyHostAttached(requestID: requestID, reason: "deferred_show_prepare", requestWindowFocus: false)
        logShowStage(startedAt: attachSurfaceStartedAt, requestID: requestID, detail: "stage=attach_surface deferred=1")
        let refreshStartedAt = Date()
        refreshNow(allowGhosttyOwnerAttach: false)
        logShowStage(startedAt: refreshStartedAt, requestID: requestID, detail: "stage=refresh_deferred")
        if ownerRendererReadyForInitialPresentation() {
            completeDeferredInitialOwnerPresentation(window: window, startedAt: startedAt, requestID: requestID, route: route)
            return
        }
        let deadline = Date().addingTimeInterval(Self.deferredInitialOwnerPresentationTimeout)
        deferredInitialPresentationTask = Task { @MainActor [weak self, weak window] in
            while !Task.isCancelled {
                guard let self, let window, !self.didCloseWindow else { return }
                guard !self.isExplicitlyNonInteractiveRuntimeState(self.lastObservedRuntimeState) else {
                    self.completeDeferredInitialOwnerPresentation(window: window, startedAt: startedAt, requestID: requestID, route: route)
                    return
                }
                self.attachLocalClientIfNeeded()
                self.ensureGhosttyHostAttached(requestID: requestID, reason: "deferred_show_wait", requestWindowFocus: false)
                self.refreshNow(allowGhosttyOwnerAttach: false)
                if self.ownerRendererReadyForInitialPresentation() {
                    self.completeDeferredInitialOwnerPresentation(window: window, startedAt: startedAt, requestID: requestID, route: route)
                    return
                }
                if Date() >= deadline {
                    self.presentDeferredInitialOwnerPresentationError(window: window, startedAt: startedAt, requestID: requestID, route: route)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
    }

    nonisolated static func shouldActivateDeferredInitialOwnerPresentation(appIsActive: Bool, requestID: String?) -> Bool {
        appIsActive || requestID?.isEmpty == false
    }

    private func completeDeferredInitialOwnerPresentation(window: NSWindow, startedAt: Date, requestID: String?, route: String?) {
        deferredInitialPresentationTask?.cancel()
        deferredInitialPresentationTask = nil
        isDeferringInitialOwnerPresentation = false
        let shouldActivateWindow =
            shouldActivateDeferredInitialOwnerPresentation
            || Self.shouldActivateDeferredInitialOwnerPresentation(appIsActive: NSApp.isActive, requestID: requestID)
        shouldActivateDeferredInitialOwnerPresentation = false
        let postRefreshStartedAt = Date()
        refreshNow()
        window.contentView?.layoutSubtreeIfNeeded()
        terminalContainer.layoutSubtreeIfNeeded()
        logShowStage(startedAt: postRefreshStartedAt, requestID: requestID, detail: "stage=refresh_before_present deferred=1")
        let presentStartedAt = Date()
        if shouldActivateWindow {
            presentWindow(window, forceFrontmost: true, isDeferredOwnerPresentation: true)
        } else {
            presentWindowWithoutActivating(window)
        }
        logShowStage(
            startedAt: presentStartedAt, requestID: requestID,
            detail: "stage=present_window visible=0 deferred=1 activating=\(shouldActivateWindow ? 1 : 0)")
        syncGhosttyOwnerFocus(reason: "deferred_show_present", requestWindowFocus: shouldActivateWindow)
        let firstResponderStartedAt = Date()
        if shouldActivateWindow { assignPreferredFirstResponder() }
        logShowStage(
            startedAt: firstResponderStartedAt, requestID: requestID,
            detail: "stage=assign_first_responder deferred=1 activating=\(shouldActivateWindow ? 1 : 0)")
        logFocusMetric("terminal_window_show", startedAt: startedAt, requestID: requestID, detail: "route=\(route ?? "show") deferred=1")
    }

    private func presentDeferredInitialOwnerPresentationError(window: NSWindow, startedAt: Date, requestID: String?, route: String?) {
        deferredInitialPresentationTask?.cancel()
        deferredInitialPresentationTask = nil
        isDeferringInitialOwnerPresentation = false
        shouldActivateDeferredInitialOwnerPresentation = false
        let message =
            "The live terminal renderer did not become ready within \(Int(Self.deferredInitialOwnerPresentationTimeout)) seconds.\n\nThe terminal session may still be running, but Spaces could not attach the native renderer. Close this window and reopen the terminal to retry."
        shouldShowOwnerStateLabel = true
        visibleRenderer = .textView
        updateOutputPlainText(message)
        updateInputStatus(message: "Live terminal renderer failed to become ready.", isError: true)
        updateRendererVisibility()
        let presentStartedAt = Date()
        presentWindow(window, forceFrontmost: true, isDeferredOwnerPresentation: true)
        logShowStage(startedAt: presentStartedAt, requestID: requestID, detail: "stage=present_window_error deferred=1")
        assignPreferredFirstResponder()
        logFocusMetric(
            "terminal_window_show", startedAt: startedAt, requestID: requestID, detail: "route=\(route ?? "show") deferred=1 error=renderer_not_ready"
        )
    }

    public func focusWindow(requestID: String? = nil, route: String? = nil) {
        guard let window else { return }
        let startedAt = Date()
        beginPendingFocusObservation(startedAt: startedAt, requestID: requestID, route: route ?? "focus")
        if window.isMiniaturized { window.deminiaturize(nil) }
        refreshNow(allowGhosttyOwnerAttach: false)
        if isDeferringInitialOwnerPresentation { shouldActivateDeferredInitialOwnerPresentation = true }
        presentWindow(window, forceFrontmost: true)
        if backend == .ghosttyEmbedded {
            let reusedSurface = hasAttachedGhosttyOwnerSurface()
            logFocusMetric(
                "terminal_window_focus_stage", startedAt: startedAt, requestID: requestID,
                detail: "stage=pre_focus reused_surface=\(reusedSurface ? 1 : 0) route=\(route ?? "focus")")
            if !reusedSurface, canAttachToGhosttyRuntime(lastObservedRuntimeState) {
                ensureGhosttyHostAttached(requestID: requestID, reason: "focus_window")
            }
            if reusedSurface { ghosttyRendererHost?.synchronizeSurfaceGeometry() }
            let syncStartedAt = Date()
            syncGhosttyOwnerFocus(reason: "window_focus_ipc", requestWindowFocus: true)
            logFocusMetric(
                "terminal_window_focus_stage", startedAt: syncStartedAt, requestID: requestID, detail: "stage=sync_focus route=\(route ?? "focus")")
        }
        // Refresh immediately after focus so the window title and visible owner
        // metadata are not left waiting for the background refresh interval.
        refreshNow()
        logFocusMetric("terminal_window_focus", startedAt: startedAt, requestID: requestID, detail: "route=\(route ?? "focus")")
    }

    public func requestOwnershipIfNeeded() {
        guard backend == .ghosttyEmbedded else { return }
        ownerAttachmentRequested = true
        preferredAttachmentMode = .owner
        if let launchConfiguration { updateGhosttySessionHostReference(for: launchConfiguration) }
        lastObservedRuntimeState = (stateProvider.currentRuntimeState) ?? lastObservedRuntimeState
        let currentOwnerClient = activeOwnerClient(snapshot: stateProvider.currentAttachmentSnapshot)
        lastObservedOwnerClientID = currentOwnerClient?.id
        let hasDifferentActiveOwner = currentOwnerClient != nil && currentOwnerClient?.id != client.id
        if hasDifferentActiveOwner && isInteractiveRuntimeState(lastObservedRuntimeState) {
            takeOverOwnership()
            return
        }
        guard canAttachToGhosttyRuntime(lastObservedRuntimeState) else {
            refreshNow(allowGhosttyOwnerAttach: false)
            return
        }
        attachLocalClientIfNeeded(mode: .owner, force: true)
        ensureGhosttyHostAttached(reason: "request_owner_mode")
        refreshNow()
    }

    public func closeForSessionTermination() {
        closesForSessionTermination = true
        window?.close()
    }

    public func takeOverOwnership(now: Date = Date()) {
        guard isInteractiveRuntimeState(lastObservedRuntimeState) else {
            updateInputStatus(message: "Session is not running.", isError: true)
            return
        }
        guard canAttachToGhosttyRuntime(lastObservedRuntimeState) else {
            updateInputStatus(message: "Terminal is still preparing.", isError: false)
            return
        }
        if let takeoverTask {
            guard let takeoverTaskStartedAt, now.timeIntervalSince(takeoverTaskStartedAt) >= Self.takeoverAttemptTimeout else { return }
            takeoverTask.cancel()
            self.takeoverTask = nil
            self.takeoverTaskStartedAt = nil
            takeoverAttemptID = nil
        }
        let startedAt = now
        let attemptID = UUID()
        let clientID = client.id
        takeoverButton.isEnabled = false
        takeoverTaskStartedAt = startedAt
        takeoverAttemptID = attemptID
        takeoverTask = Task.detached(priority: .userInitiated) { [takeoverAction] in
            let controlStartedAt = Date()
            do {
                let response = try takeoverAction(clientID)
                await MainActor.run {
                    guard self.takeoverAttemptID == attemptID else { return }
                    defer { self.clearTakeoverAttempt(id: attemptID) }
                    guard response.ok else {
                        TerminalPerformance.logMetric(
                            "terminal_viewer_takeover", target: "session=\(self.sessionID) client=\(clientID)",
                            elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false, detail: "stage=control_response")
                        self.updateInputStatus(message: response.message, isError: true)
                        return
                    }
                    self.ownerAttachmentRequested = true
                    self.preferredAttachmentMode = .owner
                    let attachStartedAt = Date()
                    self.ensureGhosttyHostAttached(reason: "takeover")
                    let attachElapsedMS = TerminalPerformance.elapsedMS(since: attachStartedAt)
                    let refreshStartedAt = Date()
                    self.updateInputStatus(message: response.message, isError: false)
                    self.refreshNow()
                    TerminalPerformance.logMetric(
                        "terminal_viewer_takeover", target: "session=\(self.sessionID) client=\(clientID)",
                        elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true,
                        detail:
                            "control_ms=\(TerminalPerformance.elapsedMS(since: controlStartedAt)) attach_ms=\(attachElapsedMS) refresh_ms=\(TerminalPerformance.elapsedMS(since: refreshStartedAt))"
                    )
                }
            } catch {
                await MainActor.run {
                    guard self.takeoverAttemptID == attemptID else { return }
                    self.clearTakeoverAttempt(id: attemptID)
                    TerminalPerformance.logMetric(
                        "terminal_viewer_takeover", target: "session=\(self.sessionID) client=\(clientID)",
                        elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false, detail: "stage=exception")
                    self.updateInputStatus(message: String(describing: error), isError: true)
                }
            }
        }
    }

    private func clearTakeoverAttempt(id: UUID) {
        guard takeoverAttemptID == id else { return }
        takeoverTask = nil
        takeoverTaskStartedAt = nil
        takeoverAttemptID = nil
        let isCurrentOwner = lastObservedOwnerClientID == client.id
        takeoverButton.isEnabled = !isCurrentOwner && isInteractiveRuntimeState(lastObservedRuntimeState)
    }

    private func ensureGhosttyHostAttached(requestID: String? = nil, reason: String, requestWindowFocus: Bool = true) {
        guard backend == .ghosttyEmbedded, preferredAttachmentMode == .owner, let launchConfiguration else { return }
        guard isInteractiveRuntimeState(lastObservedRuntimeState) else { return }
        let startedAt = Date()
        do {
            window?.contentView?.layoutSubtreeIfNeeded()
            terminalContainer.layoutSubtreeIfNeeded()
            guard let host = resolvedGhosttySessionHost(for: launchConfiguration) else {
                pendingGhosttyHostAttachment = .owner(requestID: requestID, reason: reason, requestWindowFocus: requestWindowFocus)
                return
            }
            switchGhosttySessionHostIfNeeded(host)
            try host.attach(client: client, mode: preferredAttachmentMode, into: terminalContainer)
            if defersInitialOwnerClientAttach { isClientAttached = true }
            lastObservedAttachmentMode = preferredAttachmentMode
            lastObservedOwnerClientID = host.activeOwnerClientID()
            syncGhosttyOwnerFocus(reason: "attach_owner_surface", requestWindowFocus: requestWindowFocus && preferredAttachmentMode == .owner)
            completeOwnershipTransitionIfNeeded(target: .owner, renderer: "ghostty_owner")
            updateRendererVisibility()
            logFocusMetric(
                "terminal_window_attach_owner_surface", startedAt: startedAt, requestID: requestID,
                detail: "reason=\(reason) mode=\(preferredAttachmentMode.rawValue)")
        } catch { updateInputStatus(message: String(describing: error), isError: true) }
    }

    private func ensureGhosttyFinalRenderSurfaceAttached(reason: String) {
        guard backend == .ghosttyEmbedded, let launchConfiguration else { return }
        guard !isInteractiveRuntimeState(lastObservedRuntimeState) else { return }
        guard hasGhosttyFinalRenderStateAvailable() else { return }
        let startedAt = Date()
        do {
            window?.contentView?.layoutSubtreeIfNeeded()
            terminalContainer.layoutSubtreeIfNeeded()
            guard let host = resolvedGhosttySessionHost(for: launchConfiguration) else {
                pendingGhosttyHostAttachment = .finalRender(reason: reason)
                return
            }
            switchGhosttySessionHostIfNeeded(host)
            try host.attach(client: client, mode: .viewer, into: terminalContainer)
            ghosttyRendererHost?.requestSurfaceRefresh()
            logFocusMetric(
                "terminal_window_attach_final_surface", startedAt: startedAt, requestID: nil,
                detail: "reason=\(reason) mode=\(TerminalAttachmentMode.viewer.rawValue)")
        } catch { updateOutputPlainText("Final terminal render unavailable.") }
    }

    private func releaseGhosttySurfaceIfNeeded() {
        ghosttyRendererHost?.releaseRendererSurface()
        terminalContainer.subviews.forEach { $0.removeFromSuperview() }
    }

    private func hasAttachedGhosttyOwnerSurface() -> Bool {
        guard backend == .ghosttyEmbedded, preferredAttachmentMode == .owner, visibleRenderer == .ghosttyOwner, let host = ghosttyRendererHost,
            host.hasRenderableSurface()
        else { return false }
        if let ownerClientID = ghosttySessionInfoProvider?.activeOwnerClientID() ?? lastObservedOwnerClientID { return ownerClientID == client.id }
        return true
    }

    private func logFocusMetric(_ metric: String, startedAt: Date, requestID: String?, detail: String) {
        let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
        TerminalPerformance.logMetric(
            metric, target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true,
            detail: "\(detail)\(requestDetail)")
    }

    private func logShowStage(startedAt: Date, requestID: String?, detail: String) {
        logFocusMetric("terminal_window_show_stage", startedAt: startedAt, requestID: requestID, detail: detail)
    }

    private func beginPendingFocusObservation(startedAt: Date, requestID: String?, route: String) {
        pendingFocusObservationStartedAt = requestID == nil ? nil : startedAt
        pendingFocusObservationRequestID = requestID
        pendingFocusObservationRoute = requestID == nil ? nil : route
    }

    func completePendingFocusObservationIfNeeded(reason: String) {
        guard let startedAt = pendingFocusObservationStartedAt, let requestID = pendingFocusObservationRequestID else { return }
        let route = pendingFocusObservationRoute ?? "focus"
        pendingFocusObservationStartedAt = nil
        pendingFocusObservationRequestID = nil
        pendingFocusObservationRoute = nil
        logFocusMetric("terminal_window_focus_observed", startedAt: startedAt, requestID: requestID, detail: "reason=\(reason) route=\(route)")
    }

    private func beginOwnershipTransition(_ target: OwnershipTransitionTarget, reason: String) {
        pendingOwnershipTransitionStartedAt = Date()
        pendingOwnershipTransitionTarget = target
        pendingOwnershipTransitionReason = reason
    }

    private func completeOwnershipTransitionIfNeeded(target: OwnershipTransitionTarget, renderer: String) {
        guard pendingOwnershipTransitionTarget == target, let startedAt = pendingOwnershipTransitionStartedAt else { return }
        let reason = pendingOwnershipTransitionReason ?? "unknown"
        pendingOwnershipTransitionStartedAt = nil
        pendingOwnershipTransitionTarget = nil
        pendingOwnershipTransitionReason = nil
        TerminalPerformance.logMetric(
            "terminal_ownership_transition", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            success: true, detail: "target=\(target.rawValue) renderer=\(renderer) reason=\(reason)")
    }

    func refreshNow(allowGhosttyOwnerAttach: Bool = true) {
        do {
            refreshRuntimeControlsIfNeeded()
            let currentLaunchConfiguration: TerminalSessionLaunchConfiguration
            if let launchConfiguration {
                currentLaunchConfiguration = launchConfiguration
            } else if let providerLaunchConfiguration = stateProvider.currentLaunchConfiguration {
                currentLaunchConfiguration = providerLaunchConfiguration
            } else {
                throw TerminalSessionStateUnavailableError.launchConfigurationUnavailable
            }
            launchConfiguration = currentLaunchConfiguration
            if backend != currentLaunchConfiguration.backend {
                backend = currentLaunchConfiguration.backend
                rendererMode = TerminalRendererResolver.resolveGhosttyEmbeddedMode(backend: currentLaunchConfiguration.backend)
            }
            let runtimeState = stateProvider.currentRuntimeState
            lastObservedRuntimeState = runtimeState
            updateGhosttySessionHostReference(for: currentLaunchConfiguration)
            var attachmentSnapshot = stateProvider.currentAttachmentSnapshot
            var currentOwnerClient = activeOwnerClient(snapshot: attachmentSnapshot)
            let isInteractive = isInteractiveRuntimeState(runtimeState)
            let canAttachToRuntime = canAttachToGhosttyRuntime(runtimeState)
            if !canAttachToRuntime { currentOwnerClient = nil }
            if backend == .ghosttyEmbedded {
                let activeAttachment =
                    canAttachToRuntime ? attachmentSnapshot?.attachments.last { $0.clientID == client.id && $0.detachedAt == nil } : nil
                if let activeAttachment {
                    isClientAttached = true
                    lastRequestedAttachmentMode = activeAttachment.mode
                } else {
                    let wasObservedAsAttachedOwner =
                        isClientAttached || lastObservedAttachmentMode == .owner || lastObservedOwnerClientID == client.id
                    isClientAttached = false
                    lastRequestedAttachmentMode = nil
                    lastObservedAttachmentMode = nil
                    if wasObservedAsAttachedOwner, preferredAttachmentMode == .owner, let currentOwnerClient, currentOwnerClient.id != client.id {
                        ownerAttachmentRequested = false
                        preferredAttachmentMode = .viewer
                    }
                }
                let canAttachAsOwner = canAttachToRuntime && (currentOwnerClient == nil || currentOwnerClient?.id == client.id)
                let wantsOwnerAttachment = ownerAttachmentRequested || preferredAttachmentMode == .owner
                let attachmentModeToRequest: TerminalAttachmentMode?
                if !canAttachToRuntime {
                    attachmentModeToRequest = nil
                } else if wantsOwnerAttachment {
                    if canAttachAsOwner {
                        attachmentModeToRequest = allowGhosttyOwnerAttach && activeAttachment?.mode != .owner ? .owner : nil
                    } else {
                        attachmentModeToRequest = activeAttachment == nil ? .viewer : nil
                    }
                } else {
                    attachmentModeToRequest = activeAttachment == nil ? preferredAttachmentMode : nil
                }
                if let attachmentModeToRequest {
                    attachLocalClientIfNeeded(mode: attachmentModeToRequest)
                    attachmentSnapshot = stateProvider.currentAttachmentSnapshot
                    currentOwnerClient = activeOwnerClient(snapshot: attachmentSnapshot)
                }
            }
            let isOwner =
                canAttachToRuntime
                && (currentOwnerClient?.id == client.id
                    || (currentOwnerClient == nil && (ownerAttachmentRequested || preferredAttachmentMode == .owner)))
            let currentTitle = currentWindowTitle(fallback: currentLaunchConfiguration.title, isOwner: isOwner)
            let currentWorkingDirectory = currentSummaryWorkingDirectory(fallback: currentLaunchConfiguration.workingDirectory)
            if let window {
                window.title = currentTitle
                window.representedURL = currentRepresentedURL(workingDirectory: currentWorkingDirectory)
            }
            summaryLabel.stringValue = Self.summaryText(
                workingDirectory: currentWorkingDirectory, shell: currentLaunchConfiguration.shell, command: currentLaunchConfiguration.command)
            let stateText = runtimeStateText(runtimeState: runtimeState, ownerClient: currentOwnerClient, isOwner: isOwner)
            stateLabel.stringValue = stateText

            if backend == .ghosttyEmbedded {
                let activeAttachment = attachmentSnapshot?.attachments.last(where: { $0.clientID == client.id && $0.detachedAt == nil })
                if let activeAttachment {
                    let canKeepOwnerRequest = canAttachToRuntime && (currentOwnerClient == nil || currentOwnerClient?.id == client.id)
                    let lostOwnershipToAnotherClient =
                        currentOwnerClient != nil && currentOwnerClient?.id != client.id
                        && (lastObservedAttachmentMode == .owner || lastObservedOwnerClientID == client.id)
                    let shouldPreserveOwnerRequest = ownerAttachmentRequested && activeAttachment.mode == .viewer && !lostOwnershipToAnotherClient
                    if !shouldPreserveOwnerRequest {
                        if currentOwnerClient != nil, currentOwnerClient?.id != client.id { ownerAttachmentRequested = false }
                        preferredAttachmentMode = activeAttachment.mode
                    } else if !canKeepOwnerRequest {
                        preferredAttachmentMode = activeAttachment.mode
                    }
                    if lastObservedAttachmentMode != activeAttachment.mode {
                        beginOwnershipTransition(activeAttachment.mode == .owner ? .owner : .viewer, reason: "attachment_mode_changed")
                        lastObservedAttachmentMode = activeAttachment.mode
                        if activeAttachment.mode == .owner {
                            if allowGhosttyOwnerAttach { ensureGhosttyHostAttached(reason: "attachment_mode_changed") }
                        } else {
                            releaseGhosttySurfaceIfNeeded()
                            updateGhosttySessionHostReference(for: currentLaunchConfiguration)
                            syncGhosttyOwnerFocus(reason: "ownership_demoted", requestWindowFocus: false, focused: false)
                        }
                    }
                } else if preferredAttachmentMode != .owner {
                    releaseGhosttySurfaceIfNeeded()
                }
                if lastObservedOwnerClientID != currentOwnerClient?.id {
                    if isOwner {
                        beginOwnershipTransition(.owner, reason: "ownership_promoted")
                    } else if lastObservedOwnerClientID == client.id {
                        beginOwnershipTransition(.viewer, reason: "ownership_demoted")
                        releaseGhosttySurfaceIfNeeded()
                    }
                    lastObservedOwnerClientID = currentOwnerClient?.id
                    if isOwner {
                        if allowGhosttyOwnerAttach { ensureGhosttyHostAttached(reason: "attachment_mode_changed") }
                        syncGhosttyOwnerFocus(reason: "ownership_promoted", requestWindowFocus: true)
                    }
                }
                shouldShowOwnerStateLabel = shouldShowCompactOwnerStateLabel(runtimeState: runtimeState, isOwner: isOwner)
                visibleRenderer = resolveVisibleRenderer(isOwner: isOwner)
                updateRendererVisibility()
                updateInputOwnershipUI(isOwner: isOwner, isInteractive: isInteractive && canAttachToRuntime)
                rendererLabel.stringValue = rendererSummary(isOwner: isOwner)
            } else {
                shouldShowOwnerStateLabel = true
                visibleRenderer = .textView
                updateRendererVisibility()
                updateInputOwnershipUI(isOwner: isOwner, isInteractive: isInteractive && canAttachToRuntime)
                rendererLabel.stringValue = rendererMode.statusSummary
            }
            guard visibleRenderer != .ghosttyOwner else {
                restoreGhosttyOwnerInputFocusIfReady()
                completeOwnershipTransitionIfNeeded(target: .owner, renderer: "owner_surface")
                return
            }
            let viewportState = captureOutputViewportState()
            switch visibleRenderer {
            case .ghosttyTakeoverStatus:
                let statusMessage = currentGhosttyStatusMessage(isOwner: isOwner, runtimeState: runtimeState, ownerClient: currentOwnerClient)
                takeoverMessageLabel.stringValue = statusMessage
                updateOutputPlainText(statusMessage)
                restoreOutputViewportState(viewportState)
                completeOwnershipTransitionIfNeeded(target: .viewer, renderer: "takeover_status")
            case .ghosttyEndedFinalRender:
                ensureGhosttyFinalRenderSurfaceAttached(reason: "final_render")
                updateFinalRenderCopyBuffer()
                completeOwnershipTransitionIfNeeded(target: transitionTarget(isOwner: isOwner), renderer: "final_render_surface")
            case .unavailable:
                updateOutputPlainText("Terminal render unavailable.")
                restoreOutputViewportState(viewportState)
                completeOwnershipTransitionIfNeeded(target: transitionTarget(isOwner: isOwner), renderer: "unavailable")
            case .textView:
                updateOutputPlainText("Terminal render unavailable.")
                restoreOutputViewportState(viewportState)
                completeOwnershipTransitionIfNeeded(target: transitionTarget(isOwner: isOwner), renderer: "owner_render_unavailable")
            case .ghosttyOwner: break
            }
        } catch {
            summaryLabel.stringValue = "Unable to load terminal session metadata."
            stateLabel.stringValue = String(describing: error)
            outputView.string = ""
            lastRenderedOutput = ""
        }
    }

    @objc func takeoverOwnershipAction() { takeOverOwnership() }

    func attachLocalClientIfNeeded(mode: TerminalAttachmentMode? = nil, force: Bool = false) {
        guard backend != .ghosttyEmbedded || canAttachToGhosttyRuntime(lastObservedRuntimeState) else { return }
        var attachmentMode = mode ?? (ownerAttachmentRequested ? .owner : preferredAttachmentMode)
        if backend == .ghosttyEmbedded, attachmentMode == .owner, !force {
            let currentOwnerClient = activeOwnerClient(snapshot: stateProvider.currentAttachmentSnapshot)
            if let currentOwnerClient, currentOwnerClient.id != client.id {
                ownerAttachmentRequested = false
                preferredAttachmentMode = .viewer
                attachmentMode = .viewer
            }
        }
        guard force || !isClientAttached || lastRequestedAttachmentMode != attachmentMode else { return }
        do {
            try attachClientAction(client, attachmentMode)
            isClientAttached = true
            lastRequestedAttachmentMode = attachmentMode
        } catch { updateInputStatus(message: String(describing: error), isError: true) }
    }

    func detachLocalClientIfNeeded(synchronously: Bool = true) {
        guard isClientAttached else { return }
        guard synchronously else {
            let clientID = client.id
            isClientAttached = false
            lastRequestedAttachmentMode = nil
            Task.detached(priority: .utility) { [detachClientAction] in try? detachClientAction(clientID) }
            return
        }
        do {
            try detachClientAction(client.id)
            isClientAttached = false
            lastRequestedAttachmentMode = nil
        } catch { updateInputStatus(message: String(describing: error), isError: true) }
    }

    func syncGhosttyOwnerFocus(reason: String, requestWindowFocus: Bool, focused explicitFocused: Bool? = nil) {
        guard backend == .ghosttyEmbedded, preferredAttachmentMode == .owner else { return }
        guard isInteractiveRuntimeState(lastObservedRuntimeState) else { return }
        let startedAt = Date()
        let focused = explicitFocused ?? (NSApp.isActive && window?.isMainWindow == true && window?.isKeyWindow == true)
        if requestWindowFocus { if let ownerWindowFocusAction { ownerWindowFocusAction(window) } else { ghosttyRendererHost?.focusWindow(window) } }
        if let ownerSurfaceFocusAction { ownerSurfaceFocusAction(focused) } else { ghosttyRendererHost?.setFocused(focused, for: client.id) }
        TerminalPerformance.logMetric(
            "terminal_owner_focus_sync", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true,
            detail: "reason=\(reason) focused=\(focused ? 1 : 0) request_window_focus=\(requestWindowFocus ? 1 : 0)")
    }

    /// Applies the Spaces brand primary-button look (bright-teal fill, dark ink) to a button.
    /// The brand `Theme` lives in `spacesui`, which depends on this module, so the teal
    /// values are mirrored locally to avoid a dependency cycle. They match
    /// `Theme.primaryButtonFill` / `Theme.primaryButtonText` and are appearance-independent.
    static func applyBrandPrimaryStyle(to button: NSButton, title: String) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = CGColor(srgbRed: 61 / 255, green: 198 / 255, blue: 184 / 255, alpha: 1)
        button.layer?.cornerRadius = 6
        button.layer?.masksToBounds = true
        let ink = NSColor(srgbRed: 15 / 255, green: 21 / 255, blue: 23 / 255, alpha: 1)
        button.contentTintColor = ink
        button.attributedTitle = NSAttributedString(
            string: title, attributes: [.foregroundColor: ink, .font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(equalToConstant: 30), button.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
    }

    func restoreGhosttyOwnerInputFocusIfReady() {
        guard backend == .ghosttyEmbedded, preferredAttachmentMode == .owner, visibleRenderer == .ghosttyOwner,
            isInteractiveRuntimeState(lastObservedRuntimeState), window?.isKeyWindow == true
        else { return }
        ghosttyRendererHost?.setFocused(true, for: client.id)
    }

    private func resolveVisibleRenderer(isOwner: Bool?) -> VisibleRenderer {
        guard case .ghosttyEmbedded = rendererMode else { return .textView }
        if isExplicitlyNonInteractiveRuntimeState(lastObservedRuntimeState) {
            return hasGhosttyFinalRenderStateAvailable() ? .ghosttyEndedFinalRender : .unavailable
        }
        if isOwner == true {
            if ghosttyRendererHost?.hasRenderableSurface() == true { return .ghosttyOwner }
            if isInteractiveRuntimeState(lastObservedRuntimeState) { return .ghosttyTakeoverStatus }
            return hasGhosttyFinalRenderStateAvailable() ? .ghosttyEndedFinalRender : .unavailable
        }
        return .ghosttyTakeoverStatus
    }

    private func transitionTarget(isOwner: Bool?) -> OwnershipTransitionTarget { isOwner == true ? .owner : .viewer }

    private func hasGhosttyFinalRenderStateAvailable() -> Bool { ghosttyRendererHost?.snapshot() != nil }

    var canPerformLiveTerminalEditAction: Bool {
        canPerformLiveTerminalReadOnlyAction && visibleRenderer == .ghosttyOwner && isInteractiveRuntimeState(lastObservedRuntimeState)
    }

    var canPerformLiveTerminalReadOnlyAction: Bool {
        backend == .ghosttyEmbedded && preferredAttachmentMode == .owner
            && (visibleRenderer == .ghosttyOwner || visibleRenderer == .ghosttyEndedFinalRender)
    }

    func isInteractiveRuntimeState(_ runtimeState: TerminalSessionRuntimeState?) -> Bool { runtimeState?.state.isInteractive == true }

    private func isStartingRuntimeState(_ runtimeState: TerminalSessionRuntimeState?) -> Bool { runtimeState?.state == .starting }

    func isExplicitlyNonInteractiveRuntimeState(_ runtimeState: TerminalSessionRuntimeState?) -> Bool {
        guard let runtimeState else { return false }
        return !runtimeState.state.isInteractive
    }

    private func canAttachToGhosttyRuntime(_ runtimeState: TerminalSessionRuntimeState?) -> Bool {
        guard !isStartingRuntimeState(runtimeState) else { return false }
        guard !isExplicitlyNonInteractiveRuntimeState(runtimeState) else { return false }
        return true
    }

    private func updateGhosttySessionHostReference(for launchConfiguration: TerminalSessionLaunchConfiguration) {
        guard launchConfiguration.backend == .ghosttyEmbedded else { return }
        guard let host = resolvedGhosttySessionHost(for: launchConfiguration) else { return }
        switchGhosttySessionHostIfNeeded(host)
    }

    private func resolvedGhosttySessionHost(for launchConfiguration: TerminalSessionLaunchConfiguration) -> (any TerminalGhosttySessionHosting)? {
        if let clientGhosttySessionHost { return clientGhosttySessionHost }
        guard !isResolvingGhosttySessionHost else { return nil }
        isResolvingGhosttySessionHost = true
        defer {
            isResolvingGhosttySessionHost = false
            retryPendingGhosttyHostAttachmentIfNeeded()
        }
        let created = sessionHostProvider(launchConfiguration, paths)
        clientGhosttySessionHost = created
        return created
    }

    private func retryPendingGhosttyHostAttachmentIfNeeded() {
        guard let pendingGhosttyHostAttachment, clientGhosttySessionHost != nil else { return }
        self.pendingGhosttyHostAttachment = nil
        switch pendingGhosttyHostAttachment {
        case .owner(let requestID, let reason, let requestWindowFocus):
            ensureGhosttyHostAttached(requestID: requestID, reason: reason, requestWindowFocus: requestWindowFocus)
        case .finalRender(let reason): ensureGhosttyFinalRenderSurfaceAttached(reason: reason)
        }
    }

    private func switchGhosttySessionHostIfNeeded(_ host: any TerminalGhosttySessionHosting) {
        let hostObject = host as AnyObject
        if let activeGhosttySessionHost, activeGhosttySessionHost as AnyObject === hostObject { return }
        ghosttyRendererHost?.releaseRendererSurface()
        terminalContainer.subviews.forEach { $0.removeFromSuperview() }
        activeGhosttySessionHost = host
        let resolvedHostComponents = Self.resolveGhosttyHostComponents(host)
        ghosttyRendererHost = resolvedHostComponents.rendererHost
        ghosttySessionInfoProvider = resolvedHostComponents.sessionInfoProvider
    }

    private static func resolveGhosttyHostComponents(_ host: any TerminalGhosttySessionHosting) -> (
        sessionInfoProvider: any TerminalGhosttySessionInfoProviding, rendererHost: any TerminalGhosttyRendererHosting
    ) { return (host, host) }

    private func activeOwnerClient(snapshot: TerminalSessionAttachmentSnapshot?) -> TerminalClient? {
        guard let snapshot else { return nil }
        let activeAttachments = snapshot.attachments
        guard let ownerAttachment = activeAttachments.last(where: { $0.mode == .owner && $0.detachedAt == nil }) else { return nil }
        return snapshot.clients.first(where: { $0.id == ownerAttachment.clientID })
    }

}
