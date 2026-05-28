import AppKit
import Carbon
import Foundation
import spacesterminalcore
import spacesterminalghostty

@MainActor private final class TerminalSessionWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.command] else { return super.performKeyEquivalent(with: event) }

        switch Int(event.keyCode) {
        case kVK_ANSI_Q, kVK_ANSI_W:
            performClose(nil)
            return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

public struct TerminalSessionWindowDebugState: Sendable, Codable, Equatable {
    public let renderedOutput: String
    public let showsTerminalSurface: Bool
    public let showsOutputFallback: Bool
    public let rendererSummary: String
    public let summary: String
    public let state: String
    public let windowTitle: String
    public let didCloseWindow: Bool
}

@MainActor public final class TerminalSessionWindowController: NSWindowController, NSWindowDelegate, NSUserInterfaceValidations {
    private static let ownerGhosttyRefreshInterval: Duration = .seconds(2)
    private static let fallbackRefreshInterval: Duration = .milliseconds(500)
    private static let isRunningUnderXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private enum VisibleRenderer {
        case ghosttyOwner
        case ghosttyTakeoverStatus
        case ghosttyEndedFinalRender
        case unavailable
        case outputFallback
    }

    private enum OwnershipTransitionTarget: String {
        case owner
        case viewer
    }

    private struct OutputViewportState {
        let wasPinnedToBottom: Bool
        let horizontalOffset: CGFloat
        let offsetFromBottom: CGFloat
        let selectedRange: NSRange
    }

    private let sessionID: String
    private let paths: TerminalSessionPaths
    private var launchConfiguration: TerminalSessionLaunchConfiguration?
    private let client: TerminalClient
    private var rendererMode: TerminalRendererMode
    private var backend: TerminalSessionBackendKind
    private var preferredAttachmentMode: TerminalAttachmentMode
    private let titleLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let rendererLabel = NSTextField(labelWithString: "")
    private let inputField = NSTextField(string: "")
    private let inputStatusLabel = NSTextField(labelWithString: "")
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let interruptButton = NSButton(title: "Ctrl+C", target: nil, action: nil)
    private let newlineButton = NSButton(title: "Enter", target: nil, action: nil)
    private let takeoverButton = NSButton(title: "Take Over", target: nil, action: nil)
    private let inputRowStackView = NSStackView()
    private let actionButtonStackView = NSStackView()
    private let takeoverRowStackView = NSStackView()
    private let takeoverContainerView = NSView()
    private let outputView = NSTextView(frame: NSRect(x: 0, y: 0, width: 880, height: 400))
    private let outputScrollView = NSScrollView()
    private let terminalContainer = NSView()
    private let headerStackView = NSStackView()
    private let bodyStackView = NSStackView()
    private var bodyTopToHeaderConstraint: NSLayoutConstraint?
    private var bodyTopToContentConstraint: NSLayoutConstraint?
    private var bodyBottomToContentConstraint: NSLayoutConstraint?
    private var bodyBottomToTakeoverConstraint: NSLayoutConstraint?
    private var bodyLeadingConstraint: NSLayoutConstraint?
    private var bodyTrailingConstraint: NSLayoutConstraint?
    private var takeoverLeadingConstraint: NSLayoutConstraint?
    private var takeoverTrailingConstraint: NSLayoutConstraint?
    private let sendInputAction: @Sendable (String, Bool) throws -> TerminalControlResponse
    private let sendKeyAction: @Sendable (String) throws -> TerminalControlResponse
    private let takeoverAction: @Sendable (String) throws -> TerminalControlResponse
    private let attachClientAction: @Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void
    private let detachClientAction: @Sendable (String) throws -> Void
    private let detachClientSynchronouslyOnClose: Bool
    private let usesCustomAttachClientAction: Bool
    private let copySelectionAction: (@MainActor () -> Bool)?
    private let pasteClipboardAction: (@MainActor () -> Bool)?
    private let ownerWindowFocusAction: (@MainActor (NSWindow?) -> Void)?
    private let ownerSurfaceFocusAction: (@MainActor (Bool) -> Void)?
    private let onWindowFocus: (@MainActor (String) -> Void)?
    private let onWindowClose: (@MainActor (String, String) -> Void)?
    private let loadWindowFrameAction: (TerminalAttachmentMode) throws -> TerminalSessionWindowFrame?
    private let saveWindowFrameAction: (TerminalSessionWindowFrame, TerminalAttachmentMode) throws -> Void
    private let sessionHostProvider: @MainActor (TerminalSessionLaunchConfiguration, TerminalSessionPaths) -> any TerminalGhosttySessionHosting
    private var ownerGhosttySessionHost: (any TerminalGhosttySessionHosting)?
    private var activeGhosttySessionHost: (any TerminalGhosttySessionHosting)?
    private var viewerGhosttySessionHost: (any TerminalGhosttySessionHosting)?
    private var refreshTask: Task<Void, Never>?
    private var takeoverTask: Task<Void, Never>?
    private var pendingWindowFramePersistTask: Task<Void, Never>?
    private var lastRenderedOutput = ""
    private var isClientAttached = false
    private var closesForSessionTermination = false
    private var didCloseWindow = false
    private var lastObservedAttachmentMode: TerminalAttachmentMode?
    private var ghosttyRendererHost: (any TerminalGhosttyRendererHosting)?
    private var ghosttySessionInfoProvider: (any TerminalGhosttySessionInfoProviding)?
    private var visibleRenderer: VisibleRenderer = .outputFallback
    private var lastObservedOwnerClientID: String?
    private var lastObservedRuntimeState: TerminalSessionRuntimeState?
    private var shouldShowOwnerStateLabel = true
    private var inputStatusIsError = false
    private var appDidBecomeActiveObserver: NSObjectProtocol?
    private var appDidResignActiveObserver: NSObjectProtocol?
    private var attachmentStateDidChangeObserver: NSObjectProtocol?
    private var sessionMetadataDidChangeObserver: NSObjectProtocol?
    private var runtimeStateDidChangeObserver: NSObjectProtocol?
    private var outputDidChangeObserver: NSObjectProtocol?
    private var hasHeadlessPresentation = false
    private var pendingOwnershipTransitionStartedAt: Date?
    private var pendingOwnershipTransitionTarget: OwnershipTransitionTarget?
    private var pendingOwnershipTransitionReason: String?
    private var pendingFocusObservationStartedAt: Date?
    private var pendingFocusObservationRequestID: String?
    private var pendingFocusObservationRoute: String?

    public convenience init(
        sessionID: String, paths: TerminalSessionPaths, preferredAttachmentMode: TerminalAttachmentMode = .owner, performInitialRefresh: Bool = true,
        sendInputAction: (@Sendable (String, Bool) throws -> TerminalControlResponse)? = nil,
        sendKeyAction: (@Sendable (String) throws -> TerminalControlResponse)? = nil,
        takeoverAction: (@Sendable (String) throws -> TerminalControlResponse)? = nil,
        attachClientAction: (@Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void)? = nil,
        detachClientAction: (@Sendable (String) throws -> Void)? = nil, copySelectionAction: (@MainActor () -> Bool)? = nil,
        detachClientSynchronouslyOnClose: Bool = true, pasteClipboardAction: (@MainActor () -> Bool)? = nil,
        ownerWindowFocusAction: (@MainActor (NSWindow?) -> Void)? = nil, ownerSurfaceFocusAction: (@MainActor (Bool) -> Void)? = nil,
        onWindowFocus: (@MainActor (String) -> Void)? = nil, onWindowClose: (@MainActor (String, String) -> Void)? = nil,
        loadWindowFrameAction: ((TerminalAttachmentMode) throws -> TerminalSessionWindowFrame?)? = nil,
        saveWindowFrameAction: ((TerminalSessionWindowFrame, TerminalAttachmentMode) throws -> Void)? = nil,
        sessionHostProvider: (@MainActor (TerminalSessionLaunchConfiguration, TerminalSessionPaths) -> any TerminalGhosttySessionHosting)? = nil
    ) {
        self.init(
            sessionID: sessionID, paths: paths, preferredAttachmentMode: preferredAttachmentMode, performInitialRefresh: performInitialRefresh,
            sendInputAction: sendInputAction, sendKeyAction: sendKeyAction, takeoverAction: takeoverAction, attachClientAction: attachClientAction,
            detachClientAction: detachClientAction, copySelectionAction: copySelectionAction,
            detachClientSynchronouslyOnClose: detachClientSynchronouslyOnClose, pasteClipboardAction: pasteClipboardAction,
            ownerWindowFocusAction: ownerWindowFocusAction, ownerSurfaceFocusAction: ownerSurfaceFocusAction, onWindowFocus: onWindowFocus,
            onWindowClose: onWindowClose, loadWindowFrameAction: loadWindowFrameAction, saveWindowFrameAction: saveWindowFrameAction,
            sessionHostProvider: sessionHostProvider ?? { launchConfiguration, paths in
                GhosttyEmbeddedSessionRegistry.shared.host(for: launchConfiguration, paths: paths)
            })
    }

    init(
        sessionID: String, paths: TerminalSessionPaths, preferredAttachmentMode: TerminalAttachmentMode = .owner, performInitialRefresh: Bool = true,
        sendInputAction: (@Sendable (String, Bool) throws -> TerminalControlResponse)? = nil,
        sendKeyAction: (@Sendable (String) throws -> TerminalControlResponse)? = nil,
        takeoverAction: (@Sendable (String) throws -> TerminalControlResponse)? = nil,
        attachClientAction: (@Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void)? = nil,
        detachClientAction: (@Sendable (String) throws -> Void)? = nil, copySelectionAction: (@MainActor () -> Bool)? = nil,
        detachClientSynchronouslyOnClose: Bool = true, pasteClipboardAction: (@MainActor () -> Bool)? = nil,
        ownerWindowFocusAction: (@MainActor (NSWindow?) -> Void)? = nil, ownerSurfaceFocusAction: (@MainActor (Bool) -> Void)? = nil,
        onWindowFocus: (@MainActor (String) -> Void)? = nil, onWindowClose: (@MainActor (String, String) -> Void)? = nil,
        loadWindowFrameAction: ((TerminalAttachmentMode) throws -> TerminalSessionWindowFrame?)? = nil,
        saveWindowFrameAction: ((TerminalSessionWindowFrame, TerminalAttachmentMode) throws -> Void)? = nil,
        sessionHostProvider: @escaping @MainActor (TerminalSessionLaunchConfiguration, TerminalSessionPaths) -> any TerminalGhosttySessionHosting
    ) {
        self.sessionID = sessionID
        self.paths = paths
        self.preferredAttachmentMode = preferredAttachmentMode
        let resolvedLaunchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths)
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
        usesCustomAttachClientAction = attachClientAction != nil
        self.attachClientAction =
            attachClientAction ?? { client, mode in
                try TerminalSessionPersistence.attachClient(
                    sessionID: sessionID, client: client, mode: mode, paths: paths, attachedAt: ISO8601DateFormatter().string(from: Date()))
            }
        self.detachClientAction =
            detachClientAction ?? { clientID in
                try TerminalSessionPersistence.detachClient(id: clientID, paths: paths, detachedAt: ISO8601DateFormatter().string(from: Date()))
            }
        self.detachClientSynchronouslyOnClose = detachClientSynchronouslyOnClose
        self.copySelectionAction = copySelectionAction
        self.pasteClipboardAction = pasteClipboardAction
        self.ownerWindowFocusAction = ownerWindowFocusAction
        self.ownerSurfaceFocusAction = ownerSurfaceFocusAction
        self.onWindowFocus = onWindowFocus
        self.onWindowClose = onWindowClose
        self.loadWindowFrameAction = loadWindowFrameAction ?? { mode in try TerminalSessionPersistence.readWindowFrame(mode: mode, paths: paths) }
        self.saveWindowFrameAction =
            saveWindowFrameAction ?? { frame, mode in try TerminalSessionPersistence.writeWindowFrame(frame, mode: mode, paths: paths) }
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
        startObservingApplicationActivation()
        buildUI()
        if performInitialRefresh { refreshNow() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { MainActor.assumeIsolated { stopObservingApplicationActivation() } }

    public func show(requestID: String? = nil, route: String? = nil) {
        guard let window else { return }
        let startedAt = Date()
        let wasVisible = isWindowPresented(window) && !didCloseWindow
        let defersGhosttyClientAttach = backend == .ghosttyEmbedded && !usesCustomAttachClientAction
        didCloseWindow = false
        if let launchConfiguration { updateGhosttySessionHostReference(for: launchConfiguration) }
        let attachStartedAt = Date()
        if !defersGhosttyClientAttach { attachLocalClientIfNeeded() }
        logShowStage(startedAt: attachStartedAt, requestID: requestID, detail: "stage=attach_client deferred=\(defersGhosttyClientAttach ? 1 : 0)")
        let preRefreshStartedAt = Date()
        refreshNow(allowGhosttyOwnerAttach: false)
        logShowStage(startedAt: preRefreshStartedAt, requestID: requestID, detail: "stage=refresh_before_show")
        if !wasVisible {
            restorePersistedWindowFrame(window)
            constrainWindowToVisibleFrame(window)
        }
        let presentStartedAt = Date()
        presentWindow(window, forceFrontmost: !wasVisible)
        logShowStage(startedAt: presentStartedAt, requestID: requestID, detail: "stage=present_window visible=\(wasVisible ? 1 : 0)")
        let attachSurfaceStartedAt = Date()
        if backend == .ghosttyEmbedded { ensureGhosttyHostAttached(requestID: requestID, reason: "show") }
        logShowStage(startedAt: attachSurfaceStartedAt, requestID: requestID, detail: "stage=attach_surface")
        let postRefreshStartedAt = Date()
        refreshNow()
        logShowStage(startedAt: postRefreshStartedAt, requestID: requestID, detail: "stage=refresh_after_show")
        let startRefreshingStartedAt = Date()
        startRefreshing()
        logShowStage(startedAt: startRefreshingStartedAt, requestID: requestID, detail: "stage=start_refresh")
        let firstResponderStartedAt = Date()
        assignPreferredFirstResponder()
        logShowStage(startedAt: firstResponderStartedAt, requestID: requestID, detail: "stage=assign_first_responder")
        logFocusMetric("terminal_window_show", startedAt: startedAt, requestID: requestID, detail: "route=\(route ?? "show")")
    }

    public func focusWindow(requestID: String? = nil, route: String? = nil) {
        guard let window else { return }
        let startedAt = Date()
        beginPendingFocusObservation(startedAt: startedAt, requestID: requestID, route: route ?? "focus")
        if window.isMiniaturized { window.deminiaturize(nil) }
        refreshNow(allowGhosttyOwnerAttach: false)
        presentWindow(window, forceFrontmost: true)
        if backend == .ghosttyEmbedded {
            let reusedSurface = hasAttachedGhosttyOwnerSurface()
            logFocusMetric(
                "terminal_window_focus_stage", startedAt: startedAt, requestID: requestID,
                detail: "stage=pre_focus reused_surface=\(reusedSurface ? 1 : 0) route=\(route ?? "focus")")
            if !reusedSurface { ensureGhosttyHostAttached(requestID: requestID, reason: "focus_window") }
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
        preferredAttachmentMode = .owner
        if let launchConfiguration { updateGhosttySessionHostReference(for: launchConfiguration) }
        refreshNow(allowGhosttyOwnerAttach: false)
        let hasDifferentActiveOwner = lastObservedOwnerClientID != nil && lastObservedOwnerClientID != client.id
        if hasDifferentActiveOwner && isInteractiveRuntimeState(lastObservedRuntimeState) {
            takeOverOwnership()
            return
        }
        ensureGhosttyHostAttached(reason: "request_owner_mode")
        refreshNow()
    }

    public func closeForSessionTermination() {
        closesForSessionTermination = true
        window?.close()
    }

    public func windowWillClose(_ notification: Notification) {
        let sessionIsTerminating = closesForSessionTermination
        closesForSessionTermination = false
        didCloseWindow = true
        hasHeadlessPresentation = false
        persistCurrentWindowFrame(immediately: true)
        if backend == .ghosttyEmbedded {
            syncGhosttyOwnerFocus(reason: "window_close", requestWindowFocus: false, focused: false)
            if !sessionIsTerminating { ghosttyRendererHost?.parkSurfaceInHiddenHostWindow() }
        }
        if sessionIsTerminating { isClientAttached = false } else { detachLocalClientIfNeeded(synchronously: detachClientSynchronouslyOnClose) }
        refreshTask?.cancel()
        refreshTask = nil
        onWindowClose?(sessionID, client.id)
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        onWindowFocus?(sessionID)
        completePendingFocusObservationIfNeeded(reason: "window_key")
        syncGhosttyOwnerFocus(reason: "window_key", requestWindowFocus: true)
    }

    public func windowDidResignKey(_ notification: Notification) {
        syncGhosttyOwnerFocus(reason: "window_key_lost", requestWindowFocus: false, focused: false)
    }

    public func windowDidBecomeMain(_ notification: Notification) {
        onWindowFocus?(sessionID)
        completePendingFocusObservationIfNeeded(reason: "window_main")
        syncGhosttyOwnerFocus(reason: "window_main", requestWindowFocus: true)
    }

    public func windowDidResignMain(_ notification: Notification) {
        syncGhosttyOwnerFocus(reason: "window_main_lost", requestWindowFocus: false, focused: false)
    }

    public func windowDidMove(_ notification: Notification) { persistCurrentWindowFrame() }

    public func windowDidResize(_ notification: Notification) {
        persistCurrentWindowFrame()
        syncGhosttyOwnerFocus(reason: "window_resize", requestWindowFocus: false)
    }

    public func windowDidEndLiveResize(_ notification: Notification) {
        persistCurrentWindowFrame(immediately: true)
        syncGhosttyOwnerFocus(reason: "window_resize_end", requestWindowFocus: true)
    }

    public func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(NSText.copy(_:)):
            switch visibleRenderer {
            case .ghosttyOwner: return preferredAttachmentMode == .owner
            case .ghosttyTakeoverStatus, .ghosttyEndedFinalRender, .unavailable: return true
            case .outputFallback: return true
            }
        case #selector(NSText.paste(_:)):
            switch visibleRenderer {
            case .ghosttyOwner: return preferredAttachmentMode == .owner && isInteractiveRuntimeState(lastObservedRuntimeState)
            case .ghosttyTakeoverStatus, .ghosttyEndedFinalRender, .unavailable: return false
            case .outputFallback: return !inputRowStackView.isHidden && inputField.isEnabled
            }
        case #selector(selectAll(_:)): return visibleRenderer != .ghosttyOwner
        default: return true
        }
    }

    @objc public func copy(_ sender: Any?) {
        switch visibleRenderer {
        case .ghosttyOwner:
            guard preferredAttachmentMode == .owner else {
                updateInputStatus(message: "Only the active owner can copy from the live terminal.", isError: true)
                NSSound.beep()
                return
            }
            guard copySelectionAction?() ?? ghosttyRendererHost?.copySelectionToPasteboard() ?? false else {
                NSSound.beep()
                return
            }
        case .ghosttyTakeoverStatus, .ghosttyEndedFinalRender, .unavailable, .outputFallback: outputView.copy(sender)
        }
    }

    @objc public func paste(_ sender: Any?) {
        switch visibleRenderer {
        case .ghosttyOwner:
            guard isInteractiveRuntimeState(lastObservedRuntimeState) else {
                updateInputStatus(message: "Session is not running.", isError: true)
                NSSound.beep()
                return
            }
            guard preferredAttachmentMode == .owner else {
                updateInputStatus(message: "Only the active owner can paste into the terminal.", isError: true)
                NSSound.beep()
                return
            }
            guard pasteClipboardAction?() ?? ghosttyRendererHost?.pasteClipboardContents() ?? false else {
                NSSound.beep()
                return
            }
        case .ghosttyTakeoverStatus, .ghosttyEndedFinalRender, .unavailable:
            updateInputStatus(message: "Take over ownership before sending terminal input.", isError: true)
            NSSound.beep()
            return
        case .outputFallback:
            guard !inputRowStackView.isHidden, inputField.isEnabled else {
                NSSound.beep()
                return
            }
            guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
                NSSound.beep()
                return
            }
            window?.makeFirstResponder(inputField)
            inputField.stringValue.append(text)
        }
    }

    public override func selectAll(_ sender: Any?) {
        guard visibleRenderer != .ghosttyOwner else {
            NSSound.beep()
            return
        }
        window?.makeFirstResponder(outputView)
        outputView.selectAll(sender)
    }

    public func takeOverOwnership() {
        guard isInteractiveRuntimeState(lastObservedRuntimeState) else {
            updateInputStatus(message: "Session is not running.", isError: true)
            return
        }
        guard takeoverTask == nil else { return }
        let startedAt = Date()
        let clientID = client.id
        takeoverButton.isEnabled = false
        takeoverTask = Task.detached(priority: .userInitiated) { [takeoverAction] in
            let controlStartedAt = Date()
            do {
                let response = try takeoverAction(clientID)
                await MainActor.run {
                    defer {
                        self.takeoverTask = nil
                        self.takeoverButton.isEnabled =
                            self.preferredAttachmentMode != .owner && self.isInteractiveRuntimeState(self.lastObservedRuntimeState)
                    }
                    guard response.ok else {
                        TerminalPerformance.logMetric(
                            "terminal_viewer_takeover", target: "session=\(self.sessionID) client=\(clientID)",
                            elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false, detail: "stage=control_response")
                        self.updateInputStatus(message: response.message, isError: true)
                        return
                    }
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
                    self.takeoverTask = nil
                    self.takeoverButton.isEnabled =
                        self.preferredAttachmentMode != .owner && self.isInteractiveRuntimeState(self.lastObservedRuntimeState)
                    TerminalPerformance.logMetric(
                        "terminal_viewer_takeover", target: "session=\(self.sessionID) client=\(clientID)",
                        elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false, detail: "stage=exception")
                    self.updateInputStatus(message: String(describing: error), isError: true)
                }
            }
        }
    }

    private func buildUI() {
        guard let window else { return }
        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView

        titleLabel.stringValue = sessionID
        titleLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .systemFont(ofSize: 13)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        stateLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stateLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        rendererLabel.font = .systemFont(ofSize: 12)
        rendererLabel.textColor = .tertiaryLabelColor
        rendererLabel.translatesAutoresizingMaskIntoConstraints = false
        rendererLabel.lineBreakMode = .byTruncatingTail
        rendererLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rendererLabel.stringValue = rendererMode.statusSummary

        inputField.translatesAutoresizingMaskIntoConstraints = false
        inputField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        inputField.placeholderString = "Send input to the session"
        inputField.target = self
        inputField.action = #selector(submitInputFromField)

        inputStatusLabel.font = .systemFont(ofSize: 12)
        inputStatusLabel.textColor = .secondaryLabelColor
        inputStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        inputStatusLabel.isHidden = true

        for button in [sendButton, interruptButton, newlineButton, takeoverButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .rounded
        }
        sendButton.target = self
        sendButton.action = #selector(submitInputFromButton)
        interruptButton.target = self
        interruptButton.action = #selector(sendInterrupt)
        newlineButton.target = self
        newlineButton.action = #selector(sendNewline)
        takeoverButton.target = self
        takeoverButton.action = #selector(takeoverOwnershipAction)

        outputView.isEditable = false
        outputView.isSelectable = true
        outputView.isRichText = false
        outputView.importsGraphics = false
        outputView.usesFindPanel = true
        outputView.isAutomaticQuoteSubstitutionEnabled = false
        outputView.isAutomaticDashSubstitutionEnabled = false
        outputView.isAutomaticTextReplacementEnabled = false
        outputView.isAutomaticSpellingCorrectionEnabled = false
        outputView.isContinuousSpellCheckingEnabled = false
        outputView.isGrammarCheckingEnabled = false
        outputView.isAutomaticTextCompletionEnabled = false
        outputView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        outputView.backgroundColor = .textBackgroundColor
        outputView.textColor = .textColor
        outputView.drawsBackground = true
        outputView.isHorizontallyResizable = true
        outputView.isVerticallyResizable = true
        outputView.autoresizingMask = [.width]
        outputView.minSize = .zero
        outputView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        outputView.textContainerInset = NSSize(width: 8, height: 10)
        outputView.textContainer?.widthTracksTextView = false
        outputView.textContainer?.heightTracksTextView = false
        outputView.textContainer?.lineBreakMode = .byClipping
        outputView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        outputView.enclosingScrollView?.drawsBackground = false

        outputScrollView.translatesAutoresizingMaskIntoConstraints = false
        outputScrollView.borderType = .bezelBorder
        outputScrollView.hasVerticalScroller = true
        outputScrollView.hasHorizontalScroller = true
        outputScrollView.autohidesScrollers = true
        outputScrollView.drawsBackground = false
        outputScrollView.documentView = outputView
        outputScrollView.borderType = .bezelBorder

        actionButtonStackView.translatesAutoresizingMaskIntoConstraints = false
        actionButtonStackView.orientation = .horizontal
        actionButtonStackView.alignment = .centerY
        actionButtonStackView.spacing = 8
        for button in [sendButton, interruptButton, newlineButton] {
            actionButtonStackView.addArrangedSubview(button)
            button.widthAnchor.constraint(equalToConstant: 72).isActive = true
        }

        inputRowStackView.translatesAutoresizingMaskIntoConstraints = false
        inputRowStackView.orientation = .horizontal
        inputRowStackView.alignment = .centerY
        inputRowStackView.spacing = 8
        inputRowStackView.addArrangedSubview(inputField)
        inputRowStackView.addArrangedSubview(actionButtonStackView)

        takeoverRowStackView.translatesAutoresizingMaskIntoConstraints = false
        takeoverRowStackView.orientation = .horizontal
        takeoverRowStackView.alignment = .centerY
        takeoverRowStackView.spacing = 8
        takeoverRowStackView.addArrangedSubview(takeoverButton)
        takeoverButton.widthAnchor.constraint(equalToConstant: 92).isActive = true

        takeoverContainerView.translatesAutoresizingMaskIntoConstraints = false
        takeoverContainerView.addSubview(takeoverRowStackView)
        NSLayoutConstraint.activate([
            takeoverRowStackView.centerXAnchor.constraint(equalTo: takeoverContainerView.centerXAnchor),
            takeoverRowStackView.topAnchor.constraint(equalTo: takeoverContainerView.topAnchor),
            takeoverRowStackView.bottomAnchor.constraint(equalTo: takeoverContainerView.bottomAnchor),
        ])

        headerStackView.translatesAutoresizingMaskIntoConstraints = false
        headerStackView.orientation = .vertical
        headerStackView.alignment = .leading
        headerStackView.distribution = .fill
        headerStackView.spacing = 6
        for view in [titleLabel, summaryLabel, stateLabel, rendererLabel, inputRowStackView, inputStatusLabel] {
            headerStackView.addArrangedSubview(view)
        }

        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.wantsLayer = true
        terminalContainer.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        terminalContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        bodyStackView.translatesAutoresizingMaskIntoConstraints = false
        bodyStackView.orientation = .vertical
        bodyStackView.alignment = .width
        bodyStackView.distribution = .fill
        bodyStackView.spacing = 12
        bodyStackView.addArrangedSubview(terminalContainer)
        bodyStackView.addArrangedSubview(outputScrollView)
        outputScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        [headerStackView, bodyStackView, takeoverContainerView].forEach(contentView.addSubview)

        bodyTopToHeaderConstraint = bodyStackView.topAnchor.constraint(equalTo: headerStackView.bottomAnchor, constant: 12)
        bodyTopToContentConstraint = bodyStackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12)
        bodyBottomToContentConstraint = bodyStackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16)
        bodyBottomToTakeoverConstraint = bodyStackView.bottomAnchor.constraint(equalTo: takeoverContainerView.topAnchor, constant: -12)
        bodyLeadingConstraint = bodyStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        bodyTrailingConstraint = bodyStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)
        takeoverLeadingConstraint = takeoverContainerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16)
        takeoverTrailingConstraint = takeoverContainerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16)

        NSLayoutConstraint.activate([
            headerStackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            headerStackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            headerStackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),

            bodyLeadingConstraint!, bodyTrailingConstraint!, takeoverLeadingConstraint!, takeoverTrailingConstraint!,
            takeoverContainerView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            takeoverContainerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])

        updateRendererVisibility()
    }

    private func ensureGhosttyHostAttached(requestID: String? = nil, reason: String) {
        guard backend == .ghosttyEmbedded, preferredAttachmentMode == .owner, let launchConfiguration else { return }
        let startedAt = Date()
        do {
            window?.contentView?.layoutSubtreeIfNeeded()
            terminalContainer.layoutSubtreeIfNeeded()
            let host = resolvedGhosttySessionHost(for: launchConfiguration)
            switchGhosttySessionHostIfNeeded(host)
            try host.attach(client: client, mode: preferredAttachmentMode, into: terminalContainer)
            isClientAttached = true
            lastObservedAttachmentMode = preferredAttachmentMode
            lastObservedOwnerClientID = host.activeOwnerClientID()
            syncGhosttyOwnerFocus(reason: "attach_owner_surface", requestWindowFocus: preferredAttachmentMode == .owner)
            completeOwnershipTransitionIfNeeded(target: .owner, renderer: "ghostty_owner")
            updateRendererVisibility()
            logFocusMetric(
                "terminal_window_attach_owner_surface", startedAt: startedAt, requestID: requestID,
                detail: "reason=\(reason) mode=\(preferredAttachmentMode.rawValue)")
        } catch { updateInputStatus(message: String(describing: error), isError: true) }
    }

    private func parkGhosttySurfaceIfNeeded() {
        ghosttyRendererHost?.parkSurfaceInHiddenHostWindow()
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

    private func completePendingFocusObservationIfNeeded(reason: String) {
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

    private func isWindowPresented(_ window: NSWindow) -> Bool {
        if Self.isRunningUnderXCTest { return hasHeadlessPresentation }
        return window.isVisible
    }

    private func presentWindow(_ window: NSWindow, forceFrontmost: Bool = false) {
        if Self.isRunningUnderXCTest {
            hasHeadlessPresentation = true
            return
        }
        let appWasActive = NSApp.isActive
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        guard forceFrontmost || !appWasActive else { return }
        window.orderFrontRegardless()
        Task { @MainActor [weak window] in
            await Task.yield()
            guard let window, window.isVisible, !window.isMiniaturized else { return }
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func startRefreshing() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.refreshNow()
                do { try await Task.sleep(for: self.currentRefreshInterval()) } catch { break }
            }
        }
    }

    private func refreshNow(allowGhosttyOwnerAttach: Bool = true) {
        do {
            let currentLaunchConfiguration: TerminalSessionLaunchConfiguration
            if let launchConfiguration {
                currentLaunchConfiguration = launchConfiguration
            } else {
                currentLaunchConfiguration = try TerminalSessionPersistence.readLaunchConfiguration(paths: paths)
            }
            launchConfiguration = currentLaunchConfiguration
            if backend != currentLaunchConfiguration.backend {
                backend = currentLaunchConfiguration.backend
                rendererMode = TerminalRendererResolver.resolveGhosttyEmbeddedMode(backend: currentLaunchConfiguration.backend)
            }
            let runtimeState = try? TerminalSessionPersistence.readRuntimeState(paths: paths)
            lastObservedRuntimeState = runtimeState
            updateGhosttySessionHostReference(for: currentLaunchConfiguration)
            let attachmentSnapshot = try? TerminalSessionPersistence.readAttachmentSnapshot(paths: paths)
            let currentOwnerClient = activeOwnerClient(snapshot: attachmentSnapshot)
            let isOwner = currentOwnerClient?.id == client.id || (currentOwnerClient == nil && preferredAttachmentMode == .owner)
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
                    preferredAttachmentMode = activeAttachment.mode
                    if lastObservedAttachmentMode != activeAttachment.mode {
                        beginOwnershipTransition(activeAttachment.mode == .owner ? .owner : .viewer, reason: "attachment_mode_changed")
                        lastObservedAttachmentMode = activeAttachment.mode
                        if activeAttachment.mode == .owner {
                            if allowGhosttyOwnerAttach { ensureGhosttyHostAttached(reason: "attachment_mode_changed") }
                        } else {
                            parkGhosttySurfaceIfNeeded()
                            updateGhosttySessionHostReference(for: currentLaunchConfiguration)
                            syncGhosttyOwnerFocus(reason: "ownership_demoted", requestWindowFocus: false, focused: false)
                        }
                    }
                } else if preferredAttachmentMode != .owner {
                    parkGhosttySurfaceIfNeeded()
                }
                if lastObservedOwnerClientID != currentOwnerClient?.id {
                    if isOwner {
                        beginOwnershipTransition(.owner, reason: "ownership_promoted")
                    } else if lastObservedOwnerClientID == client.id {
                        beginOwnershipTransition(.viewer, reason: "ownership_demoted")
                        parkGhosttySurfaceIfNeeded()
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
                updateInputOwnershipUI(isOwner: isOwner, isInteractive: isInteractiveRuntimeState(runtimeState))
                rendererLabel.stringValue = rendererSummary(isOwner: isOwner)
            } else {
                shouldShowOwnerStateLabel = true
                visibleRenderer = .outputFallback
                updateRendererVisibility()
                updateInputOwnershipUI(isOwner: isOwner, isInteractive: isInteractiveRuntimeState(runtimeState))
                rendererLabel.stringValue = rendererMode.statusSummary
            }
            guard visibleRenderer != .ghosttyOwner else {
                completeOwnershipTransitionIfNeeded(target: .owner, renderer: "owner_surface")
                return
            }
            let viewportState = captureOutputViewportState()
            switch visibleRenderer {
            case .ghosttyTakeoverStatus:
                updateOutputPlainText(currentGhosttyStatusMessage(isOwner: isOwner, runtimeState: runtimeState, ownerClient: currentOwnerClient))
                restoreOutputViewportState(viewportState)
                completeOwnershipTransitionIfNeeded(target: .viewer, renderer: "takeover_status")
            case .ghosttyEndedFinalRender:
                if let snapshot = ghosttyRendererHost?.snapshot() {
                    updateOutputSnapshot(snapshot)
                    restoreOutputViewportState(viewportState)
                    completeOwnershipTransitionIfNeeded(target: transitionTarget(isOwner: isOwner), renderer: "final_render")
                    return
                }
                if let snapshotText = ghosttyRendererHost?.snapshotText(), !snapshotText.isEmpty {
                    updateOutputPlainText(snapshotText)
                    restoreOutputViewportState(viewportState)
                    completeOwnershipTransitionIfNeeded(target: transitionTarget(isOwner: isOwner), renderer: "final_render_text")
                    return
                }
                updateOutputPlainText("Final terminal render unavailable.")
                restoreOutputViewportState(viewportState)
                completeOwnershipTransitionIfNeeded(target: transitionTarget(isOwner: isOwner), renderer: "final_render_unavailable")
            case .unavailable:
                updateOutputPlainText("Terminal render unavailable.")
                restoreOutputViewportState(viewportState)
                completeOwnershipTransitionIfNeeded(target: transitionTarget(isOwner: isOwner), renderer: "unavailable")
            case .outputFallback:
                if let snapshot = ghosttyRendererHost?.snapshot() {
                    updateOutputSnapshot(snapshot)
                    restoreOutputViewportState(viewportState)
                    completeOwnershipTransitionIfNeeded(target: transitionTarget(isOwner: isOwner), renderer: "owner_snapshot_fallback")
                    return
                }
                if let snapshotText = ghosttyRendererHost?.snapshotText() {
                    updateOutputPlainText(snapshotText)
                    restoreOutputViewportState(viewportState)
                    completeOwnershipTransitionIfNeeded(target: transitionTarget(isOwner: isOwner), renderer: "owner_snapshot_text_fallback")
                    return
                }
                let output = (try? TerminalOutputTail.tail(path: paths.outputPath, lineCount: 200)) ?? ""
                updateOutputPlainText(output)
                restoreOutputViewportState(viewportState)
                completeOwnershipTransitionIfNeeded(target: transitionTarget(isOwner: isOwner), renderer: "output_tail")
            case .ghosttyOwner: break
            }
        } catch {
            summaryLabel.stringValue = "Unable to load terminal session metadata."
            stateLabel.stringValue = String(describing: error)
            outputView.string = ""
            lastRenderedOutput = ""
        }
    }

    @objc private func submitInputFromButton() { submitInput() }
    @objc private func submitInputFromField() { submitInput() }
    @objc private func sendInterrupt() { sendKey("ctrl+c") }
    @objc private func sendNewline() { sendKey("enter") }
    @objc private func takeoverOwnershipAction() { takeOverOwnership() }

    private func submitInput() {
        guard !inputRowStackView.isHidden else { return }
        guard isInteractiveRuntimeState(lastObservedRuntimeState) else {
            updateInputStatus(message: "Session is not running.", isError: true)
            return
        }
        guard preferredAttachmentMode == .owner else {
            updateInputStatus(message: "Take over ownership before sending input.", isError: true)
            return
        }
        let text = inputField.stringValue.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else {
            updateInputStatus(message: "Enter text to send.", isError: false)
            return
        }

        do {
            let response = try sendInputAction(text, true)
            inputField.stringValue = ""
            updateInputStatus(message: response.message, isError: !response.ok)
            refreshNow()
        } catch { updateInputStatus(message: String(describing: error), isError: true) }
    }

    private func sendKey(_ key: String) {
        guard !inputRowStackView.isHidden else { return }
        guard isInteractiveRuntimeState(lastObservedRuntimeState) else {
            updateInputStatus(message: "Session is not running.", isError: true)
            return
        }
        guard preferredAttachmentMode == .owner else {
            updateInputStatus(message: "Take over ownership before sending keys.", isError: true)
            return
        }
        do {
            let response = try sendKeyAction(key)
            updateInputStatus(message: response.message, isError: !response.ok)
            refreshNow()
        } catch { updateInputStatus(message: String(describing: error), isError: true) }
    }

    private func updateInputStatus(message: String, isError: Bool) {
        inputStatusIsError = isError
        inputStatusLabel.stringValue = message
        inputStatusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        inputStatusLabel.isHidden = message.isEmpty
        updateHeaderLayoutVisibility()
    }

    private func attachLocalClientIfNeeded() {
        guard !isClientAttached else { return }
        do {
            try attachClientAction(client, preferredAttachmentMode)
            isClientAttached = true
        } catch { updateInputStatus(message: String(describing: error), isError: true) }
    }

    private func detachLocalClientIfNeeded(synchronously: Bool = true) {
        guard isClientAttached else { return }
        guard synchronously else {
            let clientID = client.id
            isClientAttached = false
            Task.detached(priority: .utility) { [detachClientAction] in try? detachClientAction(clientID) }
            return
        }
        do {
            try detachClientAction(client.id)
            isClientAttached = false
        } catch { updateInputStatus(message: String(describing: error), isError: true) }
    }

    private func startObservingApplicationActivation() {
        appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.syncGhosttyOwnerFocus(reason: "app_active", requestWindowFocus: false) } }
        appDidResignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncGhosttyOwnerFocus(reason: "app_inactive", requestWindowFocus: false, focused: false) }
        }
        attachmentStateDidChangeObserver = NotificationCenter.default.addObserver(
            forName: .spacesTerminalAttachmentStateDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            let changedSessionID = notification.userInfo?["sessionID"] as? String
            Task { @MainActor [weak self] in
                guard let self, let changedSessionID, changedSessionID == self.sessionID else { return }
                self.refreshNow()
            }
        }
        sessionMetadataDidChangeObserver = NotificationCenter.default.addObserver(
            forName: .spacesTerminalSessionMetadataDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            let changedSessionID = notification.userInfo?["sessionID"] as? String
            MainActor.assumeIsolated {
                guard let self, let changedSessionID, changedSessionID == self.sessionID else { return }
                self.refreshNow()
            }
        }
        runtimeStateDidChangeObserver = NotificationCenter.default.addObserver(
            forName: .spacesTerminalRuntimeStateDidChange, object: nil, queue: .main
        ) { [weak self] notification in
            let changedSessionID = notification.userInfo?["sessionID"] as? String
            MainActor.assumeIsolated {
                guard let self, let changedSessionID, changedSessionID == self.sessionID else { return }
                self.refreshNow()
            }
        }
        outputDidChangeObserver = NotificationCenter.default.addObserver(forName: .spacesTerminalOutputDidChange, object: nil, queue: .main) {
            [weak self] notification in
            let changedSessionID = notification.userInfo?["sessionID"] as? String
            MainActor.assumeIsolated {
                guard let self, let changedSessionID, changedSessionID == self.sessionID else { return }
                guard self.visibleRenderer == .ghosttyEndedFinalRender || self.visibleRenderer == .outputFallback else { return }
                self.refreshNow()
            }
        }
    }

    private func stopObservingApplicationActivation() {
        appDidBecomeActiveObserver.flatMap { NotificationCenter.default.removeObserver($0) }
        appDidBecomeActiveObserver = nil
        appDidResignActiveObserver.flatMap { NotificationCenter.default.removeObserver($0) }
        appDidResignActiveObserver = nil
        attachmentStateDidChangeObserver.flatMap { NotificationCenter.default.removeObserver($0) }
        attachmentStateDidChangeObserver = nil
        sessionMetadataDidChangeObserver.flatMap { NotificationCenter.default.removeObserver($0) }
        sessionMetadataDidChangeObserver = nil
        runtimeStateDidChangeObserver.flatMap { NotificationCenter.default.removeObserver($0) }
        runtimeStateDidChangeObserver = nil
        outputDidChangeObserver.flatMap { NotificationCenter.default.removeObserver($0) }
        outputDidChangeObserver = nil
    }

    private func syncGhosttyOwnerFocus(reason: String, requestWindowFocus: Bool, focused explicitFocused: Bool? = nil) {
        guard backend == .ghosttyEmbedded, preferredAttachmentMode == .owner else { return }
        let startedAt = Date()
        let focused = explicitFocused ?? (NSApp.isActive && window?.isMainWindow == true && window?.isKeyWindow == true)
        if requestWindowFocus { if let ownerWindowFocusAction { ownerWindowFocusAction(window) } else { ghosttyRendererHost?.focusWindow(window) } }
        if let ownerSurfaceFocusAction { ownerSurfaceFocusAction(focused) } else { ghosttyRendererHost?.setFocused(focused, for: client.id) }
        TerminalPerformance.logMetric(
            "terminal_owner_focus_sync", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true,
            detail: "reason=\(reason) focused=\(focused ? 1 : 0) request_window_focus=\(requestWindowFocus ? 1 : 0)")
    }

    private func updateRendererVisibility() {
        switch visibleRenderer {
        case .ghosttyOwner:
            terminalContainer.isHidden = false
            outputScrollView.isHidden = true
        case .ghosttyTakeoverStatus, .ghosttyEndedFinalRender, .unavailable, .outputFallback:
            outputScrollView.isHidden = false
            terminalContainer.isHidden = true
        }
        let isGhosttyOwner = visibleRenderer == .ghosttyOwner && preferredAttachmentMode == .owner
        let shouldCollapseOwnerChrome = isGhosttyOwner && !shouldShowOwnerStateLabel
        titleLabel.isHidden = isGhosttyOwner
        summaryLabel.isHidden = shouldCollapseOwnerChrome
        rendererLabel.isHidden = isGhosttyOwner
        stateLabel.isHidden = shouldCollapseOwnerChrome
        outputScrollView.borderType = backend == .ghosttyEmbedded && visibleRenderer != .outputFallback ? .noBorder : .bezelBorder
        bodyStackView.spacing = isGhosttyOwner ? 0 : 12
        bodyLeadingConstraint?.constant = isGhosttyOwner ? 0 : 16
        bodyTrailingConstraint?.constant = isGhosttyOwner ? 0 : -16
        bodyTopToContentConstraint?.constant = isGhosttyOwner ? 0 : 12
        bodyBottomToContentConstraint?.constant = isGhosttyOwner ? 0 : -16
        outputView.textContainerInset =
            backend == .ghosttyEmbedded && visibleRenderer != .outputFallback ? NSSize(width: 14, height: 14) : NSSize(width: 8, height: 10)
        outputView.textContainer?.lineFragmentPadding = backend == .ghosttyEmbedded && visibleRenderer != .outputFallback ? 0 : 5
        updateHeaderLayoutVisibility()
    }

    private func updateInputOwnershipUI(isOwner: Bool, isInteractive: Bool) {
        let usesInlineControls = visibleRenderer == .outputFallback && isOwner
        inputRowStackView.isHidden = !usesInlineControls
        let showsTakeoverShell = visibleRenderer == .ghosttyTakeoverStatus && backend == .ghosttyEmbedded
        takeoverContainerView.isHidden = !(showsTakeoverShell && !isOwner && isInteractive)
        takeoverRowStackView.isHidden = takeoverContainerView.isHidden
        inputField.isEnabled = usesInlineControls && isInteractive
        sendButton.isEnabled = usesInlineControls && isInteractive
        interruptButton.isEnabled = usesInlineControls && isInteractive
        newlineButton.isEnabled = usesInlineControls && isInteractive
        takeoverButton.isHidden = isOwner
        takeoverButton.isEnabled = !isOwner && isInteractive
        if !isInteractive {
            inputField.placeholderString = "Session is not running"
        } else {
            inputField.placeholderString = isOwner ? "Send input to the session" : "Take over to send input"
        }
        if !usesInlineControls && isOwner && (isInteractive || (!inputStatusIsError && inputStatusLabel.stringValue.isEmpty == false)) {
            inputStatusLabel.stringValue = ""
            inputStatusLabel.isHidden = true
            inputStatusIsError = false
        }
        updateHeaderLayoutVisibility()
    }

    private func updateHeaderLayoutVisibility() {
        let hasVisibleHeaderContent = [titleLabel, summaryLabel, stateLabel, rendererLabel, inputRowStackView, inputStatusLabel].contains {
            !$0.isHidden
        }
        headerStackView.isHidden = !hasVisibleHeaderContent
        bodyTopToHeaderConstraint?.isActive = hasVisibleHeaderContent
        bodyTopToContentConstraint?.isActive = !hasVisibleHeaderContent
        bodyBottomToTakeoverConstraint?.isActive = !takeoverContainerView.isHidden
        bodyBottomToContentConstraint?.isActive = takeoverContainerView.isHidden
    }

    private func assignPreferredFirstResponder() {
        guard let window else { return }
        switch visibleRenderer {
        case .ghosttyOwner: break
        case .ghosttyTakeoverStatus, .ghosttyEndedFinalRender, .unavailable, .outputFallback:
            if !takeoverContainerView.isHidden, takeoverButton.isEnabled {
                window.makeFirstResponder(takeoverButton)
            } else if !inputRowStackView.isHidden, inputField.isEnabled {
                window.makeFirstResponder(inputField)
            } else {
                window.makeFirstResponder(outputView)
            }
        }
    }

    private func scrollOutputToBottom() {
        let length = outputView.string.utf16.count
        outputView.scrollRangeToVisible(NSRange(location: length, length: 0))
    }

    private func captureOutputViewportState() -> OutputViewportState {
        let visibleRect = outputScrollView.contentView.documentVisibleRect
        let documentHeight = outputView.bounds.height
        let offsetFromBottom = max(0, documentHeight - visibleRect.maxY)
        return OutputViewportState(
            wasPinnedToBottom: offsetFromBottom <= 24, horizontalOffset: max(0, visibleRect.minX), offsetFromBottom: offsetFromBottom,
            selectedRange: outputView.selectedRange())
    }

    private func restoreOutputViewportState(_ state: OutputViewportState) {
        let outputLength = outputView.string.utf16.count
        let clampedLocation = min(state.selectedRange.location, outputLength)
        let remainingLength = max(0, outputLength - clampedLocation)
        let clampedLength = min(state.selectedRange.length, remainingLength)
        outputView.setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))

        guard let documentView = outputScrollView.documentView else {
            scrollOutputToBottom()
            return
        }
        let visibleRect = outputScrollView.contentView.documentVisibleRect
        let maxOriginX = max(0, documentView.bounds.width - visibleRect.width)
        let targetOriginX = max(0, min(state.horizontalOffset, maxOriginX))

        guard !state.wasPinnedToBottom else {
            scrollOutputToBottom()
            outputScrollView.contentView.scroll(to: NSPoint(x: targetOriginX, y: outputScrollView.contentView.documentVisibleRect.minY))
            outputScrollView.reflectScrolledClipView(outputScrollView.contentView)
            return
        }

        let maxOriginY = max(0, documentView.bounds.height - visibleRect.height)
        let targetOriginY = max(0, maxOriginY - state.offsetFromBottom)
        outputScrollView.contentView.scroll(to: NSPoint(x: targetOriginX, y: min(targetOriginY, maxOriginY)))
        outputScrollView.reflectScrolledClipView(outputScrollView.contentView)
    }

    private func constrainWindowToVisibleFrame(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame.insetBy(dx: 24, dy: 24)
        var frame = window.frame
        frame.size.width = min(frame.width, visibleFrame.width)
        frame.size.height = min(frame.height, visibleFrame.height)
        frame.origin.x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - frame.height)
        window.setFrame(frame, display: false)
    }

    private func restorePersistedWindowFrame(_ window: NSWindow) {
        guard let frame = try? loadWindowFrameAction(preferredAttachmentMode) else { return }
        let restoredFrame = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        guard restoredFrame.width >= window.minSize.width, restoredFrame.height >= window.minSize.height else { return }
        window.setFrame(restoredFrame, display: false)
    }

    private func persistCurrentWindowFrame(immediately: Bool = false) {
        pendingWindowFramePersistTask?.cancel()
        if immediately {
            writeCurrentWindowFrame()
            return
        }
        pendingWindowFramePersistTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            self?.writeCurrentWindowFrame()
        }
    }

    private func writeCurrentWindowFrame() {
        guard let window else { return }
        let frame = window.frame
        let persistedFrame = TerminalSessionWindowFrame(x: frame.origin.x, y: frame.origin.y, width: frame.size.width, height: frame.size.height)
        try? saveWindowFrameAction(persistedFrame, preferredAttachmentMode)
    }

    private func resolveVisibleRenderer(isOwner: Bool?) -> VisibleRenderer {
        guard case .ghosttyEmbedded = rendererMode else { return .outputFallback }
        if isOwner == true {
            if ghosttyRendererHost?.hasRenderableSurface() == true { return .ghosttyOwner }
            if hasGhosttyVisibleRenderStateAvailable() { return .outputFallback }
            if isInteractiveRuntimeState(lastObservedRuntimeState) { return .ghosttyTakeoverStatus }
            return hasGhosttyFinalRenderStateAvailable() ? .ghosttyEndedFinalRender : .unavailable
        }
        if isInteractiveRuntimeState(lastObservedRuntimeState) { return .ghosttyTakeoverStatus }
        return hasGhosttyFinalRenderStateAvailable() ? .ghosttyEndedFinalRender : .unavailable
    }

    private func currentRefreshInterval() -> Duration {
        visibleRenderer == .ghosttyOwner && !shouldShowOwnerStateLabel ? Self.ownerGhosttyRefreshInterval : Self.fallbackRefreshInterval
    }

    private func transitionTarget(isOwner: Bool?) -> OwnershipTransitionTarget { isOwner == true ? .owner : .viewer }

    private func hasGhosttyFinalRenderStateAvailable() -> Bool {
        if ghosttyRendererHost?.snapshot() != nil { return true }
        guard let snapshotText = ghosttyRendererHost?.snapshotText() else { return false }
        return !snapshotText.isEmpty
    }

    private func hasGhosttyVisibleRenderStateAvailable() -> Bool {
        if let snapshot = ghosttyRendererHost?.snapshot(),
            TerminalRemoteSessionStatePolicy.hasVisibleScreenContent(snapshot: snapshot, snapshotText: nil)
        {
            return true
        }
        guard let snapshotText = ghosttyRendererHost?.snapshotText() else { return false }
        return TerminalRemoteSessionStatePolicy.hasVisibleScreenContent(snapshot: nil, snapshotText: snapshotText)
    }

    private func currentGhosttyStatusMessage(isOwner: Bool, runtimeState: TerminalSessionRuntimeState?, ownerClient: TerminalClient?) -> String {
        if isInteractiveRuntimeState(runtimeState) {
            if isOwner { return "Preparing the live terminal renderer…" }
            let ownerLabel = ownerClient.map(Self.displayLabel(for:)) ?? "another client"
            if takeoverTask != nil || preferredAttachmentMode == .owner { return "Waiting for terminal ownership…\nCurrent owner: \(ownerLabel)" }
            return "Live terminal rendering is limited to the active owner.\nCurrent owner: \(ownerLabel)"
        }

        guard let runtimeState else { return "Terminal session state unavailable." }
        return "Terminal session \(runtimeState.state.rawValue)."
    }

    private func updateOutputSnapshot(_ snapshot: GhosttyTerminalSnapshot) {
        outputView.textStorage?.setAttributedString(
            GhosttyTerminalSnapshotRenderer.render(snapshot, defaultBackgroundOverride: outputView.backgroundColor))
        if let textContainer = outputView.textContainer { outputView.layoutManager?.ensureLayout(for: textContainer) }
        outputView.sizeToFit()
        lastRenderedOutput = outputView.string
    }

    private func updateOutputPlainText(_ text: String) {
        guard text != lastRenderedOutput else { return }
        outputView.string = text
        if let textContainer = outputView.textContainer { outputView.layoutManager?.ensureLayout(for: textContainer) }
        outputView.sizeToFit()
        lastRenderedOutput = text
    }

    private func rendererSummary(isOwner: Bool?) -> String {
        guard isOwner == true else {
            switch visibleRenderer {
            case .ghosttyTakeoverStatus: return "Renderer: takeover status"
            case .ghosttyEndedFinalRender: return "Renderer: final Ghostty render"
            case .unavailable: return "Renderer: unavailable"
            case .outputFallback: return "Renderer: output tail"
            case .ghosttyOwner: return "Renderer: libghostty (owner)"
            }
        }
        switch visibleRenderer {
        case .ghosttyOwner: return "Renderer: libghostty (owner)"
        case .ghosttyTakeoverStatus: return "Renderer: preparing owner surface"
        case .ghosttyEndedFinalRender: return "Renderer: final Ghostty render"
        case .unavailable: return "Renderer: unavailable"
        case .outputFallback:
            if backend == .ghosttyEmbedded, ghosttyRendererHost?.prefersOutputFallbackWhenSurfaceUnavailable == false,
                ghosttyRendererHost?.snapshot() != nil || ghosttyRendererHost?.snapshotText() != nil
            {
                return "Renderer: libghostty snapshot (owner fallback)"
            }
            return "Renderer: output tail (owner fallback)"
        }
    }

    private func currentWindowTitle(fallback: String, isOwner: Bool) -> String {
        guard backend == .ghosttyEmbedded else { return fallback }
        let baseTitle = ghosttySessionInfoProvider?.effectiveTitle ?? lastObservedRuntimeState?.title ?? fallback
        return isOwner ? baseTitle : "\(baseTitle) (viewer)"
    }

    private func currentSummaryWorkingDirectory(fallback: String) -> String {
        guard backend == .ghosttyEmbedded else { return fallback }
        return ghosttySessionInfoProvider?.effectiveWorkingDirectory ?? lastObservedRuntimeState?.workingDirectory ?? fallback
    }

    private func currentRepresentedURL(workingDirectory: String) -> URL? {
        let url = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return url
    }

    private func shouldShowCompactOwnerStateLabel(runtimeState: TerminalSessionRuntimeState?, isOwner: Bool) -> Bool {
        guard backend == .ghosttyEmbedded, isOwner else { return true }
        guard let runtimeState else { return true }
        return runtimeState.state != .running
    }

    private func isInteractiveRuntimeState(_ runtimeState: TerminalSessionRuntimeState?) -> Bool { runtimeState?.state == .running }

    private func runtimeStateText(runtimeState: TerminalSessionRuntimeState?, ownerClient: TerminalClient?, isOwner: Bool) -> String {
        guard let runtimeState else { return "state: unknown" }
        if backend == .ghosttyEmbedded && isOwner {
            let childText = runtimeState.childPID.map { "    child: \($0)" } ?? ""
            return "state: \(runtimeState.state.rawValue)\(childText)"
        }
        let clientLabel = client.identity.deviceName ?? client.identity.hostName ?? client.identity.label
        let ownerLabel = ownerClient.map(Self.displayLabel(for:)) ?? "-"
        return
            "backend: \(runtimeState.backend.rawValue)    state: \(runtimeState.state.rawValue)    child: \(runtimeState.childPID.map(String.init) ?? "-")    owner: \(ownerLabel)    client: \(clientLabel)    updated: \(runtimeState.updatedAt)"
    }

    private static func summaryText(for launchConfiguration: TerminalSessionLaunchConfiguration) -> String {
        summaryText(workingDirectory: launchConfiguration.workingDirectory, shell: launchConfiguration.shell, command: launchConfiguration.command)
    }

    private func updateGhosttySessionHostReference(for launchConfiguration: TerminalSessionLaunchConfiguration) {
        guard launchConfiguration.backend == .ghosttyEmbedded else { return }
        let host = resolvedGhosttySessionHost(for: launchConfiguration)
        switchGhosttySessionHostIfNeeded(host)
    }

    private func resolvedGhosttySessionHost(for launchConfiguration: TerminalSessionLaunchConfiguration) -> any TerminalGhosttySessionHosting {
        if GhosttyEmbeddedSessionRegistry.shared.existingCore(sessionID: launchConfiguration.sessionID) != nil {
            if let ownerGhosttySessionHost { return ownerGhosttySessionHost }
            let created = sessionHostProvider(launchConfiguration, paths)
            ownerGhosttySessionHost = created
            return created
        }
        if preferredAttachmentMode == .owner {
            if let ownerGhosttySessionHost { return ownerGhosttySessionHost }
            let created = sessionHostProvider(launchConfiguration, paths)
            ownerGhosttySessionHost = created
            return created
        }
        if let viewerGhosttySessionHost { return viewerGhosttySessionHost }
        let created = RemoteGhosttySessionHost(launchConfiguration: launchConfiguration, paths: paths)
        viewerGhosttySessionHost = created
        return created
    }

    private func switchGhosttySessionHostIfNeeded(_ host: any TerminalGhosttySessionHosting) {
        let hostObject = host as AnyObject
        if let activeGhosttySessionHost, activeGhosttySessionHost as AnyObject === hostObject { return }
        ghosttyRendererHost?.parkSurfaceInHiddenHostWindow()
        terminalContainer.subviews.forEach { $0.removeFromSuperview() }
        activeGhosttySessionHost = host
        let resolvedHostComponents = Self.resolveGhosttyHostComponents(host)
        ghosttyRendererHost = resolvedHostComponents.rendererHost
        ghosttySessionInfoProvider = resolvedHostComponents.sessionInfoProvider
    }

    private static func resolveGhosttyHostComponents(_ host: any TerminalGhosttySessionHosting) -> (
        sessionInfoProvider: any TerminalGhosttySessionInfoProviding, rendererHost: any TerminalGhosttyRendererHosting
    ) {
        if let embeddedHost = host as? GhosttyEmbeddedSessionHost { return (embeddedHost, embeddedHost.rendererHost) }
        return (host, host)
    }

    private func activeOwnerClient(snapshot: TerminalSessionAttachmentSnapshot?) -> TerminalClient? {
        guard let snapshot else { return nil }
        let activeAttachments = snapshot.attachments
        guard let ownerAttachment = activeAttachments.last(where: { $0.mode == .owner && $0.detachedAt == nil }) else { return nil }
        return snapshot.clients.first(where: { $0.id == ownerAttachment.clientID })
    }

    private static func displayLabel(for client: TerminalClient) -> String {
        client.identity.deviceName ?? client.identity.hostName ?? client.identity.label
    }

    private static func summaryText(workingDirectory: String, shell: String, command: String?) -> String {
        let cwd = abbreviatedPath(workingDirectory)
        let shell = URL(fileURLWithPath: shell).lastPathComponent
        let command = summarizedCommand(command)
        return "cwd: \(cwd)    shell: \(shell)    command: \(command)"
    }

    private static func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private static func summarizedCommand(_ command: String?) -> String {
        guard let command, !command.isEmpty else { return "-" }
        let strippedSegments = command.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
            !$0.hasPrefix("export ")
        }
        let cleaned = strippedSegments.isEmpty ? command : strippedSegments.joined(separator: "; ")
        if cleaned.count <= 140 { return cleaned }
        return "\(cleaned.prefix(72))…\(cleaned.suffix(48))"
    }

    public func debugRefreshStateForTesting(skipOwnerAttach: Bool = false) {
        if skipOwnerAttach { debugForceRefreshSkippingOwnerAttach() } else { debugForceRefresh() }
    }

    public func debugStateDump() -> TerminalSessionWindowDebugState {
        let renderedOutput: String
        if !terminalContainer.isHidden, let snapshotText = ghosttyRendererHost?.sessionSnapshotText(), !snapshotText.isEmpty {
            renderedOutput = snapshotText
        } else {
            renderedOutput = outputView.string
        }
        return .init(
            renderedOutput: renderedOutput, showsTerminalSurface: !terminalContainer.isHidden, showsOutputFallback: !outputScrollView.isHidden,
            rendererSummary: rendererLabel.stringValue, summary: summaryLabel.stringValue, state: stateLabel.stringValue,
            windowTitle: window?.title ?? "", didCloseWindow: didCloseWindow)
    }

    var debugRenderedOutput: String { outputView.string }
    var debugShowsTerminalSurface: Bool { !terminalContainer.isHidden }
    var debugShowsOutputFallback: Bool { !outputScrollView.isHidden }
    var debugRendererSummary: String { rendererLabel.stringValue }
    var debugSummary: String { summaryLabel.stringValue }
    var debugState: String { stateLabel.stringValue }
    var debugWindowTitle: String { window?.title ?? "" }
    var debugWindowRepresentedPath: String? { window?.representedURL?.path }
    var debugWindowFrame: NSRect { window?.frame ?? .zero }
    public var attachmentMode: TerminalAttachmentMode { preferredAttachmentMode }
    public var didClose: Bool { didCloseWindow }
    public var terminalSessionID: String { sessionID }
    var debugDidCloseWindow: Bool { didCloseWindow }
    func debugForceRefresh() { refreshNow() }
    func debugForceRefreshSkippingOwnerAttach() { refreshNow(allowGhosttyOwnerAttach: false) }
    public var clientID: String { client.id }
    var debugShowsInlineControls: Bool { !inputRowStackView.isHidden }
    var debugShowsTakeoverButton: Bool { !takeoverRowStackView.isHidden }
    var debugInlineInputEnabled: Bool { inputField.isEnabled }
    var debugTakeoverEnabled: Bool { takeoverButton.isEnabled }
    var debugShowsRendererLabel: Bool { !rendererLabel.isHidden }
    var debugShowsTitleLabel: Bool { !titleLabel.isHidden }
    var debugShowsSummaryLabel: Bool { !summaryLabel.isHidden }
    var debugShowsStateLabel: Bool { !stateLabel.isHidden }
    var debugShowsHeader: Bool { !headerStackView.isHidden }
    var debugInputStatus: String { inputStatusLabel.stringValue }
    var debugShowsInputStatus: Bool { !inputStatusLabel.isHidden }
    func debugSubmitInput() { submitInput() }
    var debugInputFieldValue: String { inputField.stringValue }
    func debugSimulateApplicationDidBecomeActive() { NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp) }
    func debugSimulateApplicationDidResignActive() { NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp) }
    func debugSimulateAttachmentStateDidChange() {
        NotificationCenter.default.post(name: .spacesTerminalAttachmentStateDidChange, object: nil, userInfo: ["sessionID": sessionID])
    }
    func debugSimulateSessionMetadataDidChange() {
        NotificationCenter.default.post(name: .spacesTerminalSessionMetadataDidChange, object: nil, userInfo: ["sessionID": sessionID])
    }
    func debugSimulateRuntimeStateDidChange() {
        NotificationCenter.default.post(name: .spacesTerminalRuntimeStateDidChange, object: nil, userInfo: ["sessionID": sessionID])
    }
    func debugSimulateOutputDidChange() {
        NotificationCenter.default.post(name: .spacesTerminalOutputDidChange, object: nil, userInfo: ["sessionID": sessionID, "byteCount": 1])
        refreshNow()
    }
    func debugSelectRenderedRange(_ range: NSRange) { outputView.setSelectedRange(range) }
    var debugSelectedRange: NSRange { outputView.selectedRange() }
    func debugScrollOutputToOffsetFromBottom(_ offset: CGFloat) {
        guard let documentView = outputScrollView.documentView else { return }
        let visibleRect = outputScrollView.contentView.documentVisibleRect
        let maxOriginY = max(0, documentView.bounds.height - visibleRect.height)
        let targetOriginY = max(0, maxOriginY - offset)
        outputScrollView.contentView.scroll(to: NSPoint(x: 0, y: min(targetOriginY, maxOriginY)))
        outputScrollView.reflectScrolledClipView(outputScrollView.contentView)
    }
    var debugOutputOffsetFromBottom: CGFloat {
        let visibleRect = outputScrollView.contentView.documentVisibleRect
        return max(0, outputView.bounds.height - visibleRect.maxY)
    }
    func debugScrollOutputHorizontally(to offset: CGFloat) {
        guard let documentView = outputScrollView.documentView else { return }
        let visibleRect = outputScrollView.contentView.documentVisibleRect
        let maxOriginX = max(0, documentView.bounds.width - visibleRect.width)
        outputScrollView.contentView.scroll(to: NSPoint(x: max(0, min(offset, maxOriginX)), y: visibleRect.minY))
        outputScrollView.reflectScrolledClipView(outputScrollView.contentView)
    }
    var debugOutputHorizontalOffset: CGFloat { outputScrollView.contentView.documentVisibleRect.minX }
    var debugContentWidth: CGFloat { window?.contentView?.frame.width ?? 0 }
    var debugTerminalContainerWidth: CGFloat { terminalContainer.frame.width }
    var debugBodyWidth: CGFloat { bodyStackView.frame.width }
    var debugTakeoverContainerWidth: CGFloat { takeoverContainerView.frame.width }
    var debugFirstResponderTypeName: String? {
        guard let firstResponder = window?.firstResponder else { return nil }
        return String(describing: type(of: firstResponder))
    }
    var debugFirstResponderTargetsInputField: Bool {
        guard let fieldEditor = inputField.currentEditor() else { return false }
        return window?.firstResponder === fieldEditor
    }
    var debugFirstResponderTargetsOutputView: Bool { window?.firstResponder === outputView }
    var debugRefreshIntervalMS: Int {
        switch currentRefreshInterval() {
        case Self.ownerGhosttyRefreshInterval: 2000
        default: 500
        }
    }
    @discardableResult func debugSendGhosttyScroll(horizontal: CGFloat = 0, vertical: CGFloat) -> Bool {
        ghosttyRendererHost?.debugSendScroll(horizontal: horizontal, vertical: vertical) ?? false
    }
    var debugGhosttyHasRenderableSurface: Bool { ghosttyRendererHost?.hasRenderableSurface() ?? false }
    var debugGhosttySurfaceRefreshRequestCount: Int { ghosttyRendererHost?.debugSurfaceRefreshRequestCount ?? 0 }
    var debugOutputDisablesSmartSubstitutions: Bool {
        !outputView.isAutomaticQuoteSubstitutionEnabled && !outputView.isAutomaticDashSubstitutionEnabled
            && !outputView.isAutomaticTextReplacementEnabled && !outputView.isAutomaticSpellingCorrectionEnabled
            && !outputView.isContinuousSpellCheckingEnabled && !outputView.isGrammarCheckingEnabled && !outputView.isAutomaticTextCompletionEnabled
    }
}
