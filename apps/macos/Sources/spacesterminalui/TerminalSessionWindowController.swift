import AppKit
import Carbon
import Foundation
import spacesterminalcore
import spacesterminalghostty

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

/// Thin window shell around a `TerminalSessionPaneViewController`. It owns the
/// NSWindow (frame persistence, presentation/close behavior, window-level shortcut
/// routing) and forwards session content behavior to the embedded pane.
@MainActor public final class TerminalSessionWindowController: NSWindowController, NSWindowDelegate, NSUserInterfaceValidations {
    static let isRunningUnderXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Window-independent terminal session content embedded in this window.
    let pane: TerminalSessionPaneViewController
    var sessionID: String { pane.sessionID }
    let loadWindowFrameAction: (TerminalAttachmentMode) throws -> TerminalSessionWindowFrame?
    let saveWindowFrameAction: (TerminalSessionWindowFrame, TerminalAttachmentMode) throws -> Void
    var pendingWindowFramePersistTask: Task<Void, Never>?
    var closesForSessionTermination = false
    var hasTestWindowPresentation = false
    private var pendingFocusObservationStartedAt: Date?
    private var pendingFocusObservationRequestID: String?
    private var pendingFocusObservationRoute: String?
    private var deferredInitialPresentationTask: Task<Void, Never>?
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
        pasteClipboardAction: (@MainActor () -> Bool)? = nil, ownerWindowFocusAction: (@MainActor (NSWindow?) -> Void)? = nil,
        ownerSurfaceFocusAction: (@MainActor (Bool) -> Void)? = nil, onWindowFocus: (@MainActor (String) -> Void)? = nil,
        onWindowClose: (@MainActor (String, String, Bool) -> Void)? = nil,
        runtimeControlsProvider: (@MainActor (String) -> TerminalSessionRuntimeControls?)? = nil,
        loadWindowFrameAction: @escaping (TerminalAttachmentMode) throws -> TerminalSessionWindowFrame?,
        saveWindowFrameAction: @escaping (TerminalSessionWindowFrame, TerminalAttachmentMode) throws -> Void,
        sessionHostProvider: (@MainActor (TerminalSessionLaunchConfiguration, TerminalSessionPaths) -> any TerminalGhosttySessionHosting)? = nil
    ) {
        self.init(
            sessionID: sessionID, paths: paths, stateProvider: stateProvider, preferredAttachmentMode: preferredAttachmentMode,
            performInitialRefresh: performInitialRefresh, sendInputAction: sendInputAction, sendKeyAction: sendKeyAction,
            takeoverAction: takeoverAction, attachClientAction: attachClientAction, detachClientAction: detachClientAction,
            copySelectionAction: copySelectionAction, detachClientSynchronouslyOnClose: detachClientSynchronouslyOnClose,
            defersInitialOwnerClientAttach: defersInitialOwnerClientAttach, pasteClipboardAction: pasteClipboardAction,
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
        pasteClipboardAction: (@MainActor () -> Bool)? = nil, ownerWindowFocusAction: (@MainActor (NSWindow?) -> Void)? = nil,
        ownerSurfaceFocusAction: (@MainActor (Bool) -> Void)? = nil, onWindowFocus: (@MainActor (String) -> Void)? = nil,
        onWindowClose: (@MainActor (String, String, Bool) -> Void)? = nil,
        runtimeControlsProvider: (@MainActor (String) -> TerminalSessionRuntimeControls?)? = nil,
        loadWindowFrameAction: @escaping (TerminalAttachmentMode) throws -> TerminalSessionWindowFrame?,
        saveWindowFrameAction: @escaping (TerminalSessionWindowFrame, TerminalAttachmentMode) throws -> Void,
        sessionHostProvider: @escaping @MainActor (TerminalSessionLaunchConfiguration, TerminalSessionPaths) -> any TerminalGhosttySessionHosting
    ) {
        self.loadWindowFrameAction = loadWindowFrameAction
        self.saveWindowFrameAction = saveWindowFrameAction
        // The shell triggers the initial refresh itself after the pane's view is
        // embedded in the window so the first refresh runs with a hosting window,
        // matching the pre-split behavior.
        let pane = TerminalSessionPaneViewController(
            sessionID: sessionID, paths: paths, stateProvider: stateProvider, preferredAttachmentMode: preferredAttachmentMode,
            performInitialRefresh: false, sendInputAction: sendInputAction, sendKeyAction: sendKeyAction, takeoverAction: takeoverAction,
            attachClientAction: attachClientAction, detachClientAction: detachClientAction, copySelectionAction: copySelectionAction,
            detachClientSynchronouslyOnClose: detachClientSynchronouslyOnClose, defersInitialOwnerClientAttach: defersInitialOwnerClientAttach,
            pasteClipboardAction: pasteClipboardAction, ownerWindowFocusAction: ownerWindowFocusAction,
            ownerSurfaceFocusAction: ownerSurfaceFocusAction, onWindowFocus: onWindowFocus, onWindowClose: onWindowClose,
            runtimeControlsProvider: runtimeControlsProvider, sessionHostProvider: sessionHostProvider)
        self.pane = pane

        let contentRect = NSRect(x: 0, y: 0, width: 980, height: 640)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = TerminalSessionWindow(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Terminal \(sessionID)"
        window.setAccessibilityIdentifier("spaces-terminal:\(sessionID)")
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 760, height: 420)
        window.contentView = pane.view
        super.init(window: window)
        window.delegate = self
        window.terminalKeyEventHandler = { [weak pane] event in pane?.handleKeyEvent(event) ?? false }
        window.terminalCommandKeyEquivalentHandler = { [weak pane] event in pane?.handleCommandKeyEquivalent(event) ?? false }
        pane.onDisplayTitleChanged = { [weak self] title, representedURL in
            guard let window = self?.window else { return }
            window.title = title
            window.representedURL = representedURL
        }
        if performInitialRefresh { pane.refreshNow() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func show(requestID: String? = nil, route: String? = nil) {
        guard let window else { return }
        pane.stateProvider.refreshState()
        let startedAt = Date()
        let wasVisible = isWindowPresented(window) && !pane.didCloseWindow
        let defersGhosttyClientAttach = pane.backend == .ghosttyEmbedded && pane.defersInitialOwnerClientAttach
        pane.didCloseWindow = false
        if let launchConfiguration = pane.launchConfiguration { pane.updateGhosttySessionHostReference(for: launchConfiguration) }
        pane.refreshRuntimeStateFromProvider()
        let attachStartedAt = Date()
        if !defersGhosttyClientAttach, pane.backend != .ghosttyEmbedded || pane.canAttachToGhosttyRuntime(pane.lastObservedRuntimeState) {
            pane.attachLocalClientIfNeeded(mode: pane.initialAttachmentModeForShow())
        }
        logShowStage(startedAt: attachStartedAt, requestID: requestID, detail: "stage=attach_client deferred=\(defersGhosttyClientAttach ? 1 : 0)")
        let preRefreshStartedAt = Date()
        pane.refreshNow(allowGhosttyOwnerAttach: false)
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
        if pane.backend == .ghosttyEmbedded, pane.canAttachToGhosttyRuntime(pane.lastObservedRuntimeState) {
            pane.ensureGhosttyHostAttached(requestID: requestID, reason: "show")
        }
        logShowStage(startedAt: attachSurfaceStartedAt, requestID: requestID, detail: "stage=attach_surface")
        let postRefreshStartedAt = Date()
        pane.refreshNow()
        logShowStage(startedAt: postRefreshStartedAt, requestID: requestID, detail: "stage=refresh_after_show")
        let firstResponderStartedAt = Date()
        pane.assignPreferredFirstResponder()
        logShowStage(startedAt: firstResponderStartedAt, requestID: requestID, detail: "stage=assign_first_responder")
        logFocusMetric("terminal_window_show", startedAt: startedAt, requestID: requestID, detail: "route=\(route ?? "show")")
    }

    func shouldDeferInitialOwnerPresentation(wasVisible: Bool) -> Bool {
        pane.shouldDeferInitialOwnerPresentation(wasVisible: wasVisible, runningUnderXCTest: Self.isRunningUnderXCTest)
    }

    private func startDeferredInitialOwnerPresentation(window: NSWindow, startedAt: Date, requestID: String?, route: String?) {
        deferredInitialPresentationTask?.cancel()
        pane.isDeferringInitialOwnerPresentation = true
        shouldActivateDeferredInitialOwnerPresentation = false
        pane.updateRendererVisibility()
        let attachSurfaceStartedAt = Date()
        pane.ensureGhosttyHostAttached(requestID: requestID, reason: "deferred_show_prepare", requestWindowFocus: false)
        logShowStage(startedAt: attachSurfaceStartedAt, requestID: requestID, detail: "stage=attach_surface deferred=1")
        let refreshStartedAt = Date()
        pane.refreshNow(allowGhosttyOwnerAttach: false)
        logShowStage(startedAt: refreshStartedAt, requestID: requestID, detail: "stage=refresh_deferred")
        if pane.ownerRendererReadyForInitialPresentation() {
            completeDeferredInitialOwnerPresentation(window: window, startedAt: startedAt, requestID: requestID, route: route)
            return
        }
        let deadline = Date().addingTimeInterval(Self.deferredInitialOwnerPresentationTimeout)
        deferredInitialPresentationTask = Task { @MainActor [weak self, weak window] in
            while !Task.isCancelled {
                guard let self, let window, !self.pane.didCloseWindow else { return }
                guard !self.pane.isExplicitlyNonInteractiveRuntimeState(self.pane.lastObservedRuntimeState) else {
                    self.completeDeferredInitialOwnerPresentation(window: window, startedAt: startedAt, requestID: requestID, route: route)
                    return
                }
                self.pane.attachLocalClientIfNeeded()
                self.pane.ensureGhosttyHostAttached(requestID: requestID, reason: "deferred_show_wait", requestWindowFocus: false)
                self.pane.refreshNow(allowGhosttyOwnerAttach: false)
                if self.pane.ownerRendererReadyForInitialPresentation() {
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
        pane.isDeferringInitialOwnerPresentation = false
        let shouldActivateWindow =
            shouldActivateDeferredInitialOwnerPresentation
            || Self.shouldActivateDeferredInitialOwnerPresentation(appIsActive: NSApp.isActive, requestID: requestID)
        shouldActivateDeferredInitialOwnerPresentation = false
        let postRefreshStartedAt = Date()
        pane.refreshNow()
        window.contentView?.layoutSubtreeIfNeeded()
        pane.terminalContainer.layoutSubtreeIfNeeded()
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
        pane.syncGhosttyOwnerFocus(reason: "deferred_show_present", requestWindowFocus: shouldActivateWindow)
        let firstResponderStartedAt = Date()
        if shouldActivateWindow { pane.assignPreferredFirstResponder() }
        logShowStage(
            startedAt: firstResponderStartedAt, requestID: requestID,
            detail: "stage=assign_first_responder deferred=1 activating=\(shouldActivateWindow ? 1 : 0)")
        logFocusMetric("terminal_window_show", startedAt: startedAt, requestID: requestID, detail: "route=\(route ?? "show") deferred=1")
    }

    private func presentDeferredInitialOwnerPresentationError(window: NSWindow, startedAt: Date, requestID: String?, route: String?) {
        deferredInitialPresentationTask?.cancel()
        deferredInitialPresentationTask = nil
        pane.isDeferringInitialOwnerPresentation = false
        shouldActivateDeferredInitialOwnerPresentation = false
        let message =
            "The live terminal renderer did not become ready within \(Int(Self.deferredInitialOwnerPresentationTimeout)) seconds.\n\nThe terminal session may still be running, but Spaces could not attach the native renderer. Close this window and reopen the terminal to retry."
        pane.shouldShowOwnerStateLabel = true
        pane.visibleRenderer = .textView
        pane.updateOutputPlainText(message)
        pane.updateInputStatus(message: "Live terminal renderer failed to become ready.", isError: true)
        pane.updateRendererVisibility()
        let presentStartedAt = Date()
        presentWindow(window, forceFrontmost: true, isDeferredOwnerPresentation: true)
        logShowStage(startedAt: presentStartedAt, requestID: requestID, detail: "stage=present_window_error deferred=1")
        pane.assignPreferredFirstResponder()
        logFocusMetric(
            "terminal_window_show", startedAt: startedAt, requestID: requestID, detail: "route=\(route ?? "show") deferred=1 error=renderer_not_ready"
        )
    }

    public func focusWindow(requestID: String? = nil, route: String? = nil) {
        guard let window else { return }
        let startedAt = Date()
        beginPendingFocusObservation(startedAt: startedAt, requestID: requestID, route: route ?? "focus")
        if window.isMiniaturized { window.deminiaturize(nil) }
        pane.refreshNow(allowGhosttyOwnerAttach: false)
        if pane.isDeferringInitialOwnerPresentation { shouldActivateDeferredInitialOwnerPresentation = true }
        presentWindow(window, forceFrontmost: true)
        if pane.backend == .ghosttyEmbedded {
            let reusedSurface = pane.hasAttachedGhosttyOwnerSurface()
            logFocusMetric(
                "terminal_window_focus_stage", startedAt: startedAt, requestID: requestID,
                detail: "stage=pre_focus reused_surface=\(reusedSurface ? 1 : 0) route=\(route ?? "focus")")
            if !reusedSurface, pane.canAttachToGhosttyRuntime(pane.lastObservedRuntimeState) {
                pane.ensureGhosttyHostAttached(requestID: requestID, reason: "focus_window")
            }
            if reusedSurface { pane.ghosttyRendererHost?.synchronizeSurfaceGeometry() }
            let syncStartedAt = Date()
            pane.syncGhosttyOwnerFocus(reason: "window_focus_ipc", requestWindowFocus: true)
            logFocusMetric(
                "terminal_window_focus_stage", startedAt: syncStartedAt, requestID: requestID, detail: "stage=sync_focus route=\(route ?? "focus")")
        }
        // Refresh immediately after focus so the window title and visible owner
        // metadata are not left waiting for the background refresh interval.
        pane.refreshNow()
        logFocusMetric("terminal_window_focus", startedAt: startedAt, requestID: requestID, detail: "route=\(route ?? "focus")")
    }

    public func requestOwnershipIfNeeded() { pane.requestOwnershipIfNeeded() }

    public func closeForSessionTermination() {
        closesForSessionTermination = true
        window?.close()
    }

    public func takeOverOwnership(now: Date = Date()) { pane.takeOverOwnership(now: now) }

    public func setRuntimeControls(_ controls: TerminalSessionRuntimeControls?) { pane.setRuntimeControls(controls) }

    public func markRuntimeControlsDirty() { pane.markRuntimeControlsDirty() }

    public func performShortcutForTesting(action: String, text: String? = nil) { pane.performShortcutForTesting(action: action, text: text) }

    public func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool { pane.validateUserInterfaceItem(item) }

    @objc public func copy(_ sender: Any?) { pane.copy(sender) }

    @objc public func paste(_ sender: Any?) { pane.paste(sender) }

    public override func selectAll(_ sender: Any?) { pane.selectAll(sender) }

    @objc public func find(_ sender: Any?) { pane.find(sender) }

    @objc public func findNext(_ sender: Any?) { pane.findNext(sender) }

    @objc public func findPrevious(_ sender: Any?) { pane.findPrevious(sender) }

    @objc public func useSelectionForFind(_ sender: Any?) { pane.useSelectionForFind(sender) }

    @objc public func hideFind(_ sender: Any?) { pane.hideFind(sender) }

    func logFocusMetric(_ metric: String, startedAt: Date, requestID: String?, detail: String) {
        pane.logFocusMetric(metric, startedAt: startedAt, requestID: requestID, detail: detail)
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
}
