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

@MainActor public final class TerminalSessionWindowController: NSWindowController, NSWindowDelegate, NSUserInterfaceValidations {
    private static let ownerGhosttyRefreshInterval: Duration = .seconds(2)
    private static let fallbackRefreshInterval: Duration = .milliseconds(100)
    private static let passiveOutputRefreshCoalescingInterval: Duration = .milliseconds(16)
    private static let passiveOutputRefreshHighChurnInterval: Duration = .milliseconds(2)
    private static let passiveOutputRefreshHighChurnNotificationThreshold = 3
    private static let passiveOutputRefreshHighChurnByteThreshold = 16 * 1024
    private static let isRunningUnderXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private enum VisibleRenderer {
        case ghosttyOwner
        case ghosttyViewerSnapshot
        case outputFallback
    }

    private struct TransportRenderedOutput {
        let text: String
        let attributedText: NSAttributedString
        let replayMode: String
        let replayBytes: Int64
        let usesAlternateScreen: Bool
        let mouseTrackingMode: TerminalMouseTrackingMode
        let usesSGRMouseEncoding: Bool
        let usesAlternateScrollMode: Bool
        let usesBracketedPasteMode: Bool
    }

    private struct OutputViewportState {
        let wasPinnedToBottom: Bool
        let horizontalOffset: CGFloat
        let offsetFromBottom: CGFloat
        let selectedRange: NSRange
    }

    private let sessionID: String
    private let paths: TerminalSessionPaths
    private let transport: TerminalSessionClientTransport
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
    private let outputView = TransportTerminalTranscriptView(frame: NSRect(x: 0, y: 0, width: 880, height: 400))
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
    private let copySelectionAction: (@MainActor () -> Bool)?
    private let pasteClipboardAction: (@MainActor () -> Bool)?
    private let ownerWindowFocusAction: (@MainActor (NSWindow?) -> Void)?
    private let ownerSurfaceFocusAction: (@MainActor (Bool) -> Void)?
    private let onWindowClose: (@MainActor (String, String) -> Void)?
    private var refreshTask: Task<Void, Never>?
    private var takeoverTask: Task<Void, Never>?
    private var pendingWindowFramePersistTask: Task<Void, Never>?
    private var lastRenderedOutput = ""
    private var lastRenderedAttributedOutput = NSAttributedString()
    private var lastRenderedUsedAlternateScreen = false
    private var lastRenderedMouseTrackingMode = TerminalMouseTrackingMode.disabled
    private var lastRenderedUsesSGRMouseEncoding = false
    private var lastRenderedUsesAlternateScrollMode = false
    private var lastRenderedUsesBracketedPasteMode = false
    private var lastTransportOutput = ""
    private var transportScreenBuffer = TerminalScreenBuffer()
    private var transportScreenBufferByteCount: Int64 = 0
    private var isClientAttached = false
    private var didCloseWindow = false
    private var lastObservedAttachmentMode: TerminalAttachmentMode?
    private var ghosttySessionHost: GhosttyEmbeddedSessionHost?
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
    private var appWillTerminateObserver: NSObjectProtocol?
    private var transportObservation: TerminalSessionClientTransportObservation?
    private var hasHeadlessPresentation = false
    private var pendingPassiveOutputRefreshTask: Task<Void, Never>?
    private var pendingPassiveOutputRefreshScheduledAt: Date?
    private var pendingPassiveOutputRefreshInterval: Duration?
    private var pendingPassiveOutputStartedAt: Date?
    private var pendingPassiveOutputByteCount = 0
    private var pendingPassiveOutputNotificationCount = 0
    private var isApplicationTerminating = false
    private var lastSentTranscriptSize: (columns: Int, rows: Int)?

    public init(
        sessionID: String, paths: TerminalSessionPaths, preferredAttachmentMode: TerminalAttachmentMode = .owner, performInitialRefresh: Bool = true,
        transport: TerminalSessionClientTransport? = nil, sendInputAction: (@Sendable (String, Bool) throws -> TerminalControlResponse)? = nil,
        sendKeyAction: (@Sendable (String) throws -> TerminalControlResponse)? = nil,
        sendMouseAction: (@Sendable (String, String) throws -> TerminalControlResponse)? = nil,
        resizeAction: (@Sendable (Int, Int, String) throws -> TerminalControlResponse)? = nil,
        takeoverAction: (@Sendable (String) throws -> TerminalControlResponse)? = nil,
        terminateSessionAction: (@Sendable (String?) throws -> TerminalControlResponse)? = nil,
        attachClientAction: (@Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void)? = nil,
        detachClientAction: (@Sendable (String) throws -> Void)? = nil, copySelectionAction: (@MainActor () -> Bool)? = nil,
        pasteClipboardAction: (@MainActor () -> Bool)? = nil, ownerWindowFocusAction: (@MainActor (NSWindow?) -> Void)? = nil,
        ownerSurfaceFocusAction: (@MainActor (Bool) -> Void)? = nil, onWindowClose: (@MainActor (String, String) -> Void)? = nil,
        loadWindowFrameAction: ((TerminalAttachmentMode) throws -> TerminalSessionWindowFrame?)? = nil,
        saveWindowFrameAction: ((TerminalSessionWindowFrame, TerminalAttachmentMode) throws -> Void)? = nil
    ) {
        self.sessionID = sessionID
        self.paths = paths
        self.preferredAttachmentMode = preferredAttachmentMode
        let resolvedLaunchConfiguration = try? TerminalSessionPersistence.readLaunchConfiguration(paths: paths)
        launchConfiguration = resolvedLaunchConfiguration
        let resolvedBackend = resolvedLaunchConfiguration?.backend ?? .scriptPTY
        backend = resolvedBackend
        rendererMode = TerminalRendererResolver.resolveGhosttyEmbeddedMode(backend: resolvedBackend)
        let now = ISO8601DateFormatter().string(from: Date())
        client = TerminalClient(
            kind: .localWindow,
            identity: TerminalClientIdentity(label: "Spaces window", hostName: Host.current().name, deviceName: Host.current().localizedName),
            connectedAt: now)
        let resolvedSendInputAction: @Sendable (String, Bool, String) throws -> TerminalControlResponse = { text, appendNewline, clientID in
            if let sendInputAction { return try sendInputAction(text, appendNewline) }
            return try TerminalControlClient.send(
                request: TerminalControlRequest(command: "send", text: text, clientID: clientID, appendNewline: appendNewline),
                socketPath: paths.controlSocketPath)
        }
        let resolvedSendKeyAction: @Sendable (String, String) throws -> TerminalControlResponse = { key, clientID in
            if let sendKeyAction { return try sendKeyAction(key) }
            return try TerminalControlClient.send(
                request: TerminalControlRequest(command: "key", key: key, clientID: clientID), socketPath: paths.controlSocketPath)
        }
        let resolvedResizeAction: @Sendable (Int, Int, String) throws -> TerminalControlResponse = { columns, rows, clientID in
            if let resizeAction { return try resizeAction(columns, rows, clientID) }
            return try TerminalControlClient.send(
                request: TerminalControlRequest(command: "resize", clientID: clientID, columns: columns, rows: rows),
                socketPath: paths.controlSocketPath)
        }
        let resolvedTakeoverAction: @Sendable (String) throws -> TerminalControlResponse =
            takeoverAction ?? { clientID in
                try TerminalControlClient.send(
                    request: TerminalControlRequest(command: "takeover", clientID: clientID), socketPath: paths.controlSocketPath)
            }
        let resolvedTerminateAction: @Sendable (String?) throws -> TerminalControlResponse =
            terminateSessionAction ?? { clientID in
                try TerminalControlClient.send(
                    request: TerminalControlRequest(command: "terminate", clientID: clientID), socketPath: paths.controlSocketPath)
            }
        let resolvedAttachClientAction: @Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void =
            attachClientAction ?? { client, mode in
                try TerminalSessionPersistence.attachClient(
                    sessionID: sessionID, client: client, mode: mode, paths: paths, attachedAt: ISO8601DateFormatter().string(from: Date()))
            }
        let resolvedDetachClientAction: @Sendable (String) throws -> Void =
            detachClientAction ?? { clientID in
                try TerminalSessionPersistence.detachClient(id: clientID, paths: paths, detachedAt: ISO8601DateFormatter().string(from: Date()))
            }
        self.transport =
            transport
            ?? .local(
                sessionID: sessionID, paths: paths, sendInputAction: resolvedSendInputAction, sendKeyAction: resolvedSendKeyAction,
                sendMouseAction: sendMouseAction, resizeAction: resolvedResizeAction, takeoverAction: resolvedTakeoverAction,
                terminateAction: resolvedTerminateAction, attachClientAction: resolvedAttachClientAction,
                detachClientAction: resolvedDetachClientAction, loadWindowFrameAction: loadWindowFrameAction,
                saveWindowFrameAction: saveWindowFrameAction)
        self.copySelectionAction = copySelectionAction
        self.pasteClipboardAction = pasteClipboardAction
        self.ownerWindowFocusAction = ownerWindowFocusAction
        self.ownerSurfaceFocusAction = ownerSurfaceFocusAction
        self.onWindowClose = onWindowClose

        let contentRect = NSRect(x: 0, y: 0, width: 980, height: 640)
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = TerminalSessionWindow(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Terminal \(sessionID)"
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

    public func show() {
        guard let window else { return }
        let wasVisible = isWindowPresented(window) && !didCloseWindow
        didCloseWindow = false
        attachLocalClientIfNeeded()
        refreshNow(allowGhosttyOwnerAttach: false)
        if !wasVisible {
            restorePersistedWindowFrame(window)
            constrainWindowToVisibleFrame(window)
        }
        presentWindow(window)
        if backend == .ghosttyEmbedded { ensureGhosttyHostAttached() }
        refreshNow()
        syncTranscriptSizeIfNeeded(force: true)
        startRefreshing()
        assignPreferredFirstResponder()
    }

    public func focusWindow() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        presentWindow(window)
        if backend == .ghosttyEmbedded {
            ensureGhosttyHostAttached()
            syncGhosttyOwnerFocus(reason: "window_focus_ipc", requestWindowFocus: true)
        }
    }

    public func windowWillClose(_ notification: Notification) {
        didCloseWindow = true
        hasHeadlessPresentation = false
        persistCurrentWindowFrame(immediately: true)
        terminateOwnedScriptSessionIfNeeded()
        if backend == .ghosttyEmbedded {
            syncGhosttyOwnerFocus(reason: "window_close", requestWindowFocus: false, focused: false)
            ghosttySessionHost?.parkSurfaceInHiddenHostWindow()
        }
        detachLocalClientIfNeeded()
        refreshTask?.cancel()
        refreshTask = nil
        onWindowClose?(sessionID, client.id)
    }

    public func windowDidBecomeKey(_ notification: Notification) { syncGhosttyOwnerFocus(reason: "window_key", requestWindowFocus: true) }

    public func windowDidResignKey(_ notification: Notification) {
        syncGhosttyOwnerFocus(reason: "window_key_lost", requestWindowFocus: false, focused: false)
    }

    public func windowDidBecomeMain(_ notification: Notification) { syncGhosttyOwnerFocus(reason: "window_main", requestWindowFocus: true) }

    public func windowDidResignMain(_ notification: Notification) {
        syncGhosttyOwnerFocus(reason: "window_main_lost", requestWindowFocus: false, focused: false)
    }

    public func windowDidMove(_ notification: Notification) { persistCurrentWindowFrame() }

    public func windowDidResize(_ notification: Notification) {
        persistCurrentWindowFrame()
        syncGhosttyOwnerFocus(reason: "window_resize", requestWindowFocus: false)
        syncTranscriptSizeIfNeeded()
    }

    public func windowDidEndLiveResize(_ notification: Notification) {
        persistCurrentWindowFrame(immediately: true)
        syncGhosttyOwnerFocus(reason: "window_resize_end", requestWindowFocus: true)
        syncTranscriptSizeIfNeeded(force: true)
    }

    public func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(NSText.copy(_:)):
            switch visibleRenderer {
            case .ghosttyOwner: return preferredAttachmentMode == .owner
            case .ghosttyViewerSnapshot: return true
            case .outputFallback: return true
            }
        case #selector(NSText.paste(_:)):
            switch visibleRenderer {
            case .ghosttyOwner: return preferredAttachmentMode == .owner && isInteractiveRuntimeState(lastObservedRuntimeState)
            case .ghosttyViewerSnapshot: return false
            case .outputFallback: return preferredAttachmentMode == .owner && isInteractiveRuntimeState(lastObservedRuntimeState)
            }
        case #selector(selectAll(_:)): return visibleRenderer != .ghosttyOwner
        default: return true
        }
    }

    @objc public func copy(_ sender: Any?) {
        switch visibleRenderer {
        case .ghosttyOwner:
            guard preferredAttachmentMode == .owner else {
                updateInputStatus(message: "Viewer windows cannot copy from the active terminal. Take over ownership first.", isError: true)
                NSSound.beep()
                return
            }
            guard copySelectionAction?() ?? ghosttySessionHost?.copySelectionToPasteboard() ?? false else {
                NSSound.beep()
                return
            }
        case .ghosttyViewerSnapshot, .outputFallback: outputView.copy(sender)
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
                updateInputStatus(message: "Viewer windows cannot paste into the terminal. Take over ownership first.", isError: true)
                NSSound.beep()
                return
            }
            guard pasteClipboardAction?() ?? ghosttySessionHost?.pasteClipboardContents() ?? false else {
                NSSound.beep()
                return
            }
        case .ghosttyViewerSnapshot:
            updateInputStatus(message: "Viewer windows cannot paste into the terminal. Take over ownership first.", isError: true)
            NSSound.beep()
            return
        case .outputFallback:
            guard isInteractiveRuntimeState(lastObservedRuntimeState) else {
                updateInputStatus(message: "Session is not running.", isError: true)
                NSSound.beep()
                return
            }
            guard preferredAttachmentMode == .owner else {
                updateInputStatus(message: "Viewer windows cannot paste into the terminal. Take over ownership first.", isError: true)
                NSSound.beep()
                return
            }
            guard sendFallbackPasteFromClipboard() else {
                NSSound.beep()
                return
            }
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
        let transport = self.transport
        takeoverTask = Task(priority: .userInitiated) {
            let controlStartedAt = Date()
            do {
                let response = try transport.takeover(clientID)
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
                    self.ensureGhosttyHostAttached()
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

        outputView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        outputView.backgroundColor = .textBackgroundColor
        outputView.textColor = .textColor
        outputView.drawsBackground = true
        outputView.autoresizingMask = [.width]
        outputView.minSize = .zero
        outputView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        outputView.textContainerInset = NSSize(width: 8, height: 10)
        outputView.lineFragmentPadding = 5
        outputView.enclosingScrollView?.drawsBackground = false
        outputView.terminalInputHandler = { [weak self] input in self?.sendFallbackTranscriptInput(input) ?? false }
        outputView.terminalPasteHandler = { [weak self] in self?.sendFallbackPasteFromClipboard() ?? false }
        outputView.terminalMouseHandler = { [weak self] input in self?.sendFallbackTranscriptMouse(input) ?? false }

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

        updateInputOwnershipUI(isOwner: preferredAttachmentMode == .owner, isInteractive: false)
        updateRendererVisibility()
    }

    private func ensureGhosttyHostAttached() {
        guard backend == .ghosttyEmbedded, let launchConfiguration else { return }
        do {
            window?.contentView?.layoutSubtreeIfNeeded()
            terminalContainer.layoutSubtreeIfNeeded()
            let host = GhosttyEmbeddedSessionRegistry.shared.host(for: launchConfiguration, paths: paths)
            ghosttySessionHost = host
            try host.attach(client: client, mode: preferredAttachmentMode, into: preferredAttachmentMode == .owner ? terminalContainer : nil)
            lastObservedAttachmentMode = preferredAttachmentMode
            lastObservedOwnerClientID = host.activeOwnerClientID()
            syncGhosttyOwnerFocus(reason: "attach_owner_surface", requestWindowFocus: preferredAttachmentMode == .owner)
            updateRendererVisibility()
        } catch { updateInputStatus(message: String(describing: error), isError: true) }
    }

    private func isWindowPresented(_ window: NSWindow) -> Bool {
        if Self.isRunningUnderXCTest { return hasHeadlessPresentation }
        return window.isVisible
    }

    private func presentWindow(_ window: NSWindow) {
        if Self.isRunningUnderXCTest {
            hasHeadlessPresentation = true
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
            let snapshot = try transport.loadSnapshot()
            let currentLaunchConfiguration: TerminalSessionLaunchConfiguration
            if let snapshotLaunchConfiguration = snapshot.launchConfiguration {
                currentLaunchConfiguration = snapshotLaunchConfiguration
            } else if let launchConfiguration {
                currentLaunchConfiguration = launchConfiguration
            } else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            launchConfiguration = currentLaunchConfiguration
            if backend != currentLaunchConfiguration.backend {
                backend = currentLaunchConfiguration.backend
                rendererMode = TerminalRendererResolver.resolveGhosttyEmbeddedMode(backend: currentLaunchConfiguration.backend)
            }
            let runtimeState = snapshot.runtimeState
            lastObservedRuntimeState = runtimeState
            updateGhosttySessionHostReference(for: currentLaunchConfiguration)
            let attachmentSnapshot = snapshot.attachmentSnapshot
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
                        lastObservedAttachmentMode = activeAttachment.mode
                        if activeAttachment.mode == .owner {
                            if allowGhosttyOwnerAttach { ensureGhosttyHostAttached() }
                        } else {
                            syncGhosttyOwnerFocus(reason: "ownership_demoted", requestWindowFocus: false, focused: false)
                        }
                    }
                }
                if lastObservedOwnerClientID != currentOwnerClient?.id {
                    lastObservedOwnerClientID = currentOwnerClient?.id
                    if isOwner { syncGhosttyOwnerFocus(reason: "ownership_promoted", requestWindowFocus: true) }
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
            guard visibleRenderer != .ghosttyOwner else { return }
            let viewportState = captureOutputViewportState()
            let passiveRefreshStartedAt = Date()
            var didUpdatePassivePresentation = false
            switch visibleRenderer {
            case .ghosttyViewerSnapshot:
                logPendingPassiveOutputWaitToRender(startedAt: passiveRefreshStartedAt, renderer: "viewer_snapshot")
                if let snapshot = ghosttySessionHost?.snapshot() {
                    let renderedSnapshot = GhosttyTerminalSnapshotRenderer.render(snapshot, defaultBackgroundOverride: outputView.backgroundColor)
                    let plainSnapshot = GhosttyTerminalSnapshotRenderer.plainText(snapshot)
                    outputView.setRenderedOutput(plainText: plainSnapshot, attributedText: renderedSnapshot)
                    outputView.sizeToFit()
                    lastRenderedOutput = plainSnapshot
                    lastRenderedAttributedOutput = renderedSnapshot
                    lastRenderedUsedAlternateScreen = false
                    lastRenderedMouseTrackingMode = .disabled
                    lastRenderedUsesSGRMouseEncoding = false
                    lastRenderedUsesAlternateScrollMode = false
                    lastRenderedUsesBracketedPasteMode = false
                    restoreOutputViewportState(viewportState)
                    didUpdatePassivePresentation = true
                    completePendingPassiveOutputMeasurement(renderer: "viewer_snapshot", changedOutput: true)
                    return
                }
                fallthrough
            case .outputFallback:
                logPendingPassiveOutputWaitToRender(startedAt: passiveRefreshStartedAt, renderer: "transport_canvas")
                let renderOutputStartedAt = Date()
                let renderedOutputResult: TransportRenderedOutput
                do { renderedOutputResult = try renderedOutput(snapshot: snapshot) } catch {
                    let fallbackText = lastTransportOutput.isEmpty ? snapshot.recentOutput : lastTransportOutput
                    renderedOutputResult = TransportRenderedOutput(
                        text: fallbackText,
                        attributedText: NSAttributedString(
                            string: fallbackText, attributes: [.font: outputView.font, .foregroundColor: outputView.textColor]),
                        replayMode: "fallback_recent_output", replayBytes: 0, usesAlternateScreen: false, mouseTrackingMode: .disabled,
                        usesSGRMouseEncoding: false, usesAlternateScrollMode: false, usesBracketedPasteMode: false)
                }
                TerminalPerformance.logMetric(
                    "terminal_viewer_refresh_render_output", target: "session=\(sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: renderOutputStartedAt), success: true,
                    detail: "renderer=transport_canvas mode=\(renderedOutputResult.replayMode) replay_bytes=\(renderedOutputResult.replayBytes)")
                let assignTextStartedAt = Date()
                let alternateScreenChanged = renderedOutputResult.usesAlternateScreen != lastRenderedUsedAlternateScreen
                lastRenderedMouseTrackingMode = renderedOutputResult.mouseTrackingMode
                lastRenderedUsesSGRMouseEncoding = renderedOutputResult.usesSGRMouseEncoding
                lastRenderedUsesAlternateScrollMode = renderedOutputResult.usesAlternateScrollMode
                lastRenderedUsesBracketedPasteMode = renderedOutputResult.usesBracketedPasteMode
                if renderedOutputResult.text != lastRenderedOutput || !renderedOutputResult.attributedText.isEqual(lastRenderedAttributedOutput) {
                    outputView.setRenderedOutput(plainText: renderedOutputResult.text, attributedText: renderedOutputResult.attributedText)
                    TerminalPerformance.logMetric(
                        "terminal_viewer_refresh_text_assign", target: "session=\(sessionID)",
                        elapsedMS: TerminalPerformance.elapsedMS(since: assignTextStartedAt), success: true,
                        detail: "renderer=transport_canvas changed=1 chars=\(renderedOutputResult.text.count)")
                    let layoutStartedAt = Date()
                    outputView.sizeToFit()
                    TerminalPerformance.logMetric(
                        "terminal_viewer_refresh_layout", target: "session=\(sessionID)",
                        elapsedMS: TerminalPerformance.elapsedMS(since: layoutStartedAt), success: true, detail: "renderer=transport_canvas changed=1"
                    )
                    lastRenderedOutput = renderedOutputResult.text
                    lastRenderedAttributedOutput = renderedOutputResult.attributedText
                    lastRenderedUsedAlternateScreen = renderedOutputResult.usesAlternateScreen
                    didUpdatePassivePresentation = true
                } else {
                    TerminalPerformance.logMetric(
                        "terminal_viewer_refresh_text_assign", target: "session=\(sessionID)",
                        elapsedMS: TerminalPerformance.elapsedMS(since: assignTextStartedAt), success: true,
                        detail: "renderer=transport_canvas changed=0 chars=\(renderedOutputResult.text.count)")
                }
                let restoreViewportStartedAt = Date()
                if alternateScreenChanged {
                    outputView.setSelectedRange(NSRange(location: 0, length: 0))
                    outputScrollView.contentView.scroll(to: .zero)
                    outputScrollView.reflectScrolledClipView(outputScrollView.contentView)
                } else {
                    restoreOutputViewportState(viewportState)
                }
                TerminalPerformance.logMetric(
                    "terminal_viewer_refresh_viewport_restore", target: "session=\(sessionID)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: restoreViewportStartedAt), success: true,
                    detail:
                        "renderer=transport_canvas changed=\(didUpdatePassivePresentation ? 1 : 0) alt_screen_changed=\(alternateScreenChanged ? 1 : 0)"
                )
                if backend != .ghosttyEmbedded, !isOwner, didUpdatePassivePresentation {
                    TerminalPerformance.logMetric(
                        "terminal_viewer_output_present", target: "session=\(sessionID)",
                        elapsedMS: TerminalPerformance.elapsedMS(since: passiveRefreshStartedAt), success: true,
                        detail: "renderer=transport_canvas_poll changed=1")
                }
                completePendingPassiveOutputMeasurement(renderer: "transport_canvas", changedOutput: didUpdatePassivePresentation)
            case .ghosttyOwner: break
            }
        } catch {
            summaryLabel.stringValue = "Unable to load terminal session metadata."
            stateLabel.stringValue = String(describing: error)
            outputView.string = ""
            lastRenderedOutput = ""
            lastRenderedAttributedOutput = NSAttributedString()
            lastRenderedUsedAlternateScreen = false
            lastRenderedMouseTrackingMode = .disabled
            lastRenderedUsesSGRMouseEncoding = false
            lastRenderedUsesAlternateScrollMode = false
            lastRenderedUsesBracketedPasteMode = false
            lastTransportOutput = ""
        }
    }

    @objc private func submitInputFromButton() { submitInput() }
    @objc private func submitInputFromField() { submitInput() }
    @objc private func sendInterrupt() { sendKey("ctrl+c") }
    @objc private func sendNewline() { sendKey("enter") }
    @objc private func takeoverOwnershipAction() { takeOverOwnership() }

    private func submitInput() {
        guard !inputRowStackView.isHidden else { return }
        let text = inputField.stringValue.trimmingCharacters(in: .newlines)
        guard !text.isEmpty else {
            updateInputStatus(message: "Enter text to send.", isError: false)
            return
        }
        guard sendFallbackTranscriptInput(.text(text), appendNewline: true) else { return }
        inputField.stringValue = ""
    }

    private func sendKey(_ key: String) {
        guard !inputRowStackView.isHidden else { return }
        _ = sendFallbackTranscriptInput(.key(key))
    }

    private func syncTranscriptSizeIfNeeded(force: Bool = false) {
        guard backend != .ghosttyEmbedded else { return }
        guard preferredAttachmentMode == .owner else { return }
        guard isInteractiveRuntimeState(lastObservedRuntimeState) else { return }
        guard let size = currentTranscriptTerminalSize() else { return }
        if !force, let lastSentTranscriptSize, lastSentTranscriptSize.columns == size.columns, lastSentTranscriptSize.rows == size.rows { return }
        do {
            let response = try transport.resize(size.columns, size.rows, client.id)
            if response.ok { lastSentTranscriptSize = size }
        } catch {}
    }

    @discardableResult private func sendFallbackTranscriptInput(_ input: TransportTerminalTranscriptInput, appendNewline: Bool = false) -> Bool {
        if case .key(let key) = input, preferredAttachmentMode != .owner, handleViewerLocalNavigation(key: key) { return true }
        guard isInteractiveRuntimeState(lastObservedRuntimeState) else {
            updateInputStatus(message: "Session is not running.", isError: true)
            return false
        }
        guard preferredAttachmentMode == .owner else {
            let message: String
            switch input {
            case .text: message = "Viewer windows cannot send input. Take over ownership first."
            case .key: message = "Viewer windows cannot send keys. Take over ownership first."
            }
            updateInputStatus(message: message, isError: true)
            return false
        }
        do {
            let response: TerminalControlResponse
            switch input {
            case .text(let text): response = try transport.sendInput(text, appendNewline, client.id)
            case .key(let key): response = try transport.sendKey(key, client.id)
            }
            let shouldSuppressSuccessStatus = response.ok && visibleRenderer == .outputFallback
            updateInputStatus(message: shouldSuppressSuccessStatus ? "" : response.message, isError: !response.ok)
            refreshNow()
            return response.ok
        } catch {
            updateInputStatus(message: String(describing: error), isError: true)
            return false
        }
    }

    @discardableResult private func sendFallbackTranscriptMouse(_ input: TransportTerminalTranscriptMouseInput) -> Bool {
        if shouldTranslateTranscriptScrollToAlternateNavigation(for: input) {
            let key = input.action == .scrollUp ? "up" : "down"
            return sendFallbackTranscriptInput(.key(key))
        }
        guard shouldForwardTranscriptMouseInput(for: input) else { return false }
        guard isInteractiveRuntimeState(lastObservedRuntimeState) else { return false }
        guard preferredAttachmentMode == .owner else { return false }
        let sequence = TerminalMouseInput.sgrSequence(
            action: input.action, button: input.button, column: input.column, row: input.row, shift: input.shift, option: input.option,
            control: input.control)
        do {
            let response = try transport.sendMouse(sequence, client.id)
            if !response.ok { updateInputStatus(message: response.message, isError: true) }
            refreshNow()
            return response.ok
        } catch {
            updateInputStatus(message: String(describing: error), isError: true)
            return false
        }
    }

    private func shouldForwardTranscriptMouseInput(for input: TransportTerminalTranscriptMouseInput) -> Bool {
        guard visibleRenderer == .outputFallback else { return false }
        guard lastRenderedUsesSGRMouseEncoding else { return false }
        guard lastRenderedMouseTrackingMode != .disabled else { return false }
        switch input.action {
        case .scrollUp, .scrollDown: return true
        case .press, .release: return lastRenderedMouseTrackingMode != .disabled
        case .move: return lastRenderedMouseTrackingMode == .drag || lastRenderedMouseTrackingMode == .move
        }
    }

    private func shouldTranslateTranscriptScrollToAlternateNavigation(for input: TransportTerminalTranscriptMouseInput) -> Bool {
        guard visibleRenderer == .outputFallback else { return false }
        guard preferredAttachmentMode == .owner else { return false }
        guard isInteractiveRuntimeState(lastObservedRuntimeState) else { return false }
        guard lastRenderedUsedAlternateScreen else { return false }
        guard lastRenderedUsesAlternateScrollMode else { return false }
        guard lastRenderedMouseTrackingMode == .disabled else { return false }
        switch input.action {
        case .scrollUp, .scrollDown: return true
        case .press, .release, .move: return false
        }
    }

    @discardableResult private func sendFallbackPasteFromClipboard() -> Bool {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            NSSound.beep()
            return false
        }
        let prepared = TerminalPasteInput.wrapped(text, usesBracketedPasteMode: lastRenderedUsesBracketedPasteMode)
        return sendFallbackTranscriptInput(.text(prepared))
    }

    private func handleViewerLocalNavigation(key: String) -> Bool {
        guard visibleRenderer != .ghosttyOwner else { return false }
        switch key {
        case "pageup":
            scrollOutputByViewportPages(-1)
            return true
        case "pagedown":
            scrollOutputByViewportPages(1)
            return true
        case "home":
            scrollOutputVertically(to: 0)
            return true
        case "end":
            scrollOutputToBottom()
            return true
        default: return false
        }
    }

    private func scrollOutputByViewportPages(_ pageDelta: Int) {
        let visibleRect = outputScrollView.contentView.documentVisibleRect
        let pageHeight = max(visibleRect.height - outputView.measuredLineHeight * 2, outputView.measuredLineHeight * 4)
        scrollOutputVertically(to: visibleRect.minY + CGFloat(pageDelta) * pageHeight)
    }

    private func scrollOutputVertically(to originY: CGFloat) {
        guard let documentView = outputScrollView.documentView else { return }
        let visibleRect = outputScrollView.contentView.documentVisibleRect
        let maxOriginY = max(0, documentView.bounds.height - visibleRect.height)
        outputScrollView.contentView.scroll(to: NSPoint(x: visibleRect.minX, y: max(0, min(originY, maxOriginY))))
        outputScrollView.reflectScrolledClipView(outputScrollView.contentView)
        if !inputStatusIsError, !inputStatusLabel.stringValue.isEmpty {
            inputStatusLabel.stringValue = ""
            inputStatusLabel.isHidden = true
            updateHeaderLayoutVisibility()
        }
    }

    private func currentTranscriptTerminalSize() -> (columns: Int, rows: Int)? {
        let contentSize = outputScrollView.contentSize
        guard contentSize.width > 0, contentSize.height > 0 else { return nil }
        let sampleWidth = outputView.measuredCellWidth
        let lineHeight = outputView.measuredLineHeight
        guard sampleWidth > 0, lineHeight > 0 else { return nil }
        let horizontalInsets = outputView.horizontalInsets
        let verticalInsets = outputView.verticalInsets
        let usableWidth = max(1, contentSize.width - horizontalInsets)
        let usableHeight = max(1, contentSize.height - verticalInsets)
        let columns = max(1, Int(floor(usableWidth / sampleWidth)))
        let rows = max(1, Int(floor(usableHeight / lineHeight)))
        return (columns, rows)
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
        let startedAt = Date()
        do {
            try transport.attachClient(client, preferredAttachmentMode)
            isClientAttached = true
            if backend != .ghosttyEmbedded {
                TerminalPerformance.logMetric(
                    "terminal_window_attach", target: "session=\(sessionID) client=\(client.id)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true, detail: "mode=\(preferredAttachmentMode.rawValue)")
            }
        } catch {
            if backend != .ghosttyEmbedded {
                TerminalPerformance.logMetric(
                    "terminal_window_attach", target: "session=\(sessionID) client=\(client.id)",
                    elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false, detail: "mode=\(preferredAttachmentMode.rawValue)")
            }
            updateInputStatus(message: String(describing: error), isError: true)
        }
    }

    private func detachLocalClientIfNeeded() {
        guard isClientAttached else { return }
        do {
            try transport.detachClient(client.id)
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
        transportObservation = transport.observe { [weak self] event in
            let handleEvent = { @MainActor [weak self] in
                guard let self else { return }
                switch event {
                case .snapshotChanged: self.refreshNow()
                case .outputChanged(let byteCount, let recentOutput):
                    self.lastTransportOutput = recentOutput
                    self.recordPassiveOutputNotification(byteCount: byteCount)
                    self.schedulePassiveOutputRefresh()
                }
            }
            if Thread.isMainThread { MainActor.assumeIsolated { handleEvent() } } else { Task { @MainActor in handleEvent() } }
        }
        appWillTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: NSApp, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.isApplicationTerminating = true } }
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
        appWillTerminateObserver.flatMap { NotificationCenter.default.removeObserver($0) }
        appWillTerminateObserver = nil
        transportObservation?.cancel()
        transportObservation = nil
        pendingPassiveOutputRefreshTask?.cancel()
        pendingPassiveOutputRefreshTask = nil
        pendingPassiveOutputRefreshScheduledAt = nil
        pendingPassiveOutputRefreshInterval = nil
    }

    private func schedulePassiveOutputRefresh() {
        guard visibleRenderer != .ghosttyOwner else { return }
        let refreshInterval = passiveOutputRefreshInterval()
        if let existingInterval = pendingPassiveOutputRefreshInterval {
            guard refreshInterval < existingInterval else { return }
            pendingPassiveOutputRefreshTask?.cancel()
            pendingPassiveOutputRefreshTask = nil
        } else if pendingPassiveOutputRefreshTask != nil {
            return
        }
        let scheduledAt = Date()
        pendingPassiveOutputRefreshScheduledAt = scheduledAt
        pendingPassiveOutputRefreshInterval = refreshInterval
        pendingPassiveOutputRefreshTask = Task { @MainActor [weak self] in
            defer {
                self?.pendingPassiveOutputRefreshTask = nil
                self?.pendingPassiveOutputRefreshScheduledAt = nil
                self?.pendingPassiveOutputRefreshInterval = nil
            }
            do { try await Task.sleep(for: refreshInterval) } catch { return }
            self?.refreshNow()
        }
    }

    private func recordPassiveOutputNotification(byteCount: Int) {
        guard visibleRenderer != .ghosttyOwner else { return }
        if pendingPassiveOutputStartedAt == nil { pendingPassiveOutputStartedAt = Date() }
        pendingPassiveOutputByteCount += byteCount
        pendingPassiveOutputNotificationCount += 1
    }

    private func completePendingPassiveOutputMeasurement(renderer: String, changedOutput: Bool) {
        guard let startedAt = pendingPassiveOutputStartedAt else { return }
        let byteCount = pendingPassiveOutputByteCount
        let notificationCount = pendingPassiveOutputNotificationCount
        pendingPassiveOutputStartedAt = nil
        pendingPassiveOutputByteCount = 0
        pendingPassiveOutputNotificationCount = 0
        TerminalPerformance.logMetric(
            "terminal_viewer_output_present", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            success: true, detail: "renderer=\(renderer) bytes=\(byteCount) notifications=\(notificationCount) changed=\(changedOutput ? 1 : 0)")
    }

    private func passiveOutputRefreshInterval() -> Duration {
        if pendingPassiveOutputNotificationCount >= Self.passiveOutputRefreshHighChurnNotificationThreshold
            || pendingPassiveOutputByteCount >= Self.passiveOutputRefreshHighChurnByteThreshold
        {
            return Self.passiveOutputRefreshHighChurnInterval
        }
        return Self.passiveOutputRefreshCoalescingInterval
    }

    private func logPendingPassiveOutputWaitToRender(startedAt: Date, renderer: String) {
        guard let pendingStartedAt = pendingPassiveOutputStartedAt else { return }
        let scheduledWaitMS: Int
        if let scheduledAt = pendingPassiveOutputRefreshScheduledAt {
            scheduledWaitMS = max(Int(startedAt.timeIntervalSince(scheduledAt) * 1000), 0)
        } else {
            scheduledWaitMS = 0
        }
        TerminalPerformance.logMetric(
            "terminal_viewer_refresh_wait_to_render", target: "session=\(sessionID)",
            elapsedMS: max(Int(startedAt.timeIntervalSince(pendingStartedAt) * 1000), 0), success: true,
            detail: "renderer=\(renderer) notifications=\(pendingPassiveOutputNotificationCount) bytes=\(pendingPassiveOutputByteCount) "
                + "scheduled_wait_ms=\(scheduledWaitMS)")
    }

    private func syncGhosttyOwnerFocus(reason: String, requestWindowFocus: Bool, focused explicitFocused: Bool? = nil) {
        guard backend == .ghosttyEmbedded, preferredAttachmentMode == .owner else { return }
        let startedAt = Date()
        let focused = explicitFocused ?? (NSApp.isActive && window?.isMainWindow == true && window?.isKeyWindow == true)
        if requestWindowFocus { if let ownerWindowFocusAction { ownerWindowFocusAction(window) } else { ghosttySessionHost?.focusWindow(window) } }
        if let ownerSurfaceFocusAction { ownerSurfaceFocusAction(focused) } else { ghosttySessionHost?.setFocused(focused, for: client.id) }
        TerminalPerformance.logMetric(
            "terminal_owner_focus_sync", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true,
            detail: "reason=\(reason) focused=\(focused ? 1 : 0) request_window_focus=\(requestWindowFocus ? 1 : 0)")
    }

    private func updateRendererVisibility() {
        switch visibleRenderer {
        case .ghosttyOwner:
            terminalContainer.isHidden = false
            outputScrollView.isHidden = true
        case .ghosttyViewerSnapshot, .outputFallback:
            outputScrollView.isHidden = false
            terminalContainer.isHidden = true
        }
        let isGhosttyOwner = visibleRenderer == .ghosttyOwner && preferredAttachmentMode == .owner
        let isGhosttyViewer = backend == .ghosttyEmbedded && preferredAttachmentMode != .owner
        let isTransportCanvas = visibleRenderer == .outputFallback
        let shouldCollapseTransportChrome = isTransportCanvas && inputStatusLabel.isHidden
        let shouldCollapseOwnerChrome = isGhosttyOwner && !shouldShowOwnerStateLabel
        let shouldCollapseViewerChrome = isGhosttyViewer && inputStatusLabel.isHidden
        let usesTerminalSurfaceChrome = isGhosttyOwner || isGhosttyViewer || shouldCollapseTransportChrome
        let collapsedInset: CGFloat = 0
        titleLabel.isHidden = usesTerminalSurfaceChrome
        summaryLabel.isHidden = shouldCollapseOwnerChrome || shouldCollapseViewerChrome || shouldCollapseTransportChrome
        rendererLabel.isHidden = usesTerminalSurfaceChrome
        stateLabel.isHidden = shouldCollapseOwnerChrome || shouldCollapseViewerChrome || shouldCollapseTransportChrome
        outputScrollView.borderType = (isGhosttyViewer || shouldCollapseTransportChrome) ? .noBorder : .bezelBorder
        bodyStackView.spacing = usesTerminalSurfaceChrome ? 0 : 12
        bodyLeadingConstraint?.constant = usesTerminalSurfaceChrome ? collapsedInset : 16
        bodyTrailingConstraint?.constant = usesTerminalSurfaceChrome ? -collapsedInset : -16
        bodyTopToContentConstraint?.constant = usesTerminalSurfaceChrome ? collapsedInset : 12
        bodyBottomToContentConstraint?.constant = usesTerminalSurfaceChrome ? -collapsedInset : -16
        outputView.textContainerInset = isGhosttyViewer ? .zero : (shouldCollapseTransportChrome ? .zero : NSSize(width: 8, height: 10))
        outputView.lineFragmentPadding = (isGhosttyViewer || shouldCollapseTransportChrome) ? 0 : 5
        updateHeaderLayoutVisibility()
    }

    private func updateInputOwnershipUI(isOwner: Bool, isInteractive: Bool) {
        let usesInlineControls = false
        inputRowStackView.isHidden = !usesInlineControls
        takeoverContainerView.isHidden = isOwner || !isInteractive
        takeoverRowStackView.isHidden = takeoverContainerView.isHidden
        inputField.isEnabled = usesInlineControls && isOwner && isInteractive
        sendButton.isEnabled = usesInlineControls && isOwner && isInteractive
        interruptButton.isEnabled = usesInlineControls && isOwner && isInteractive
        newlineButton.isEnabled = usesInlineControls && isOwner && isInteractive
        takeoverButton.isHidden = isOwner
        takeoverButton.isEnabled = !isOwner && isInteractive
        if !isInteractive {
            inputField.placeholderString = "Session is not running"
        } else {
            inputField.placeholderString = isOwner ? "Send input to the session" : "Viewer window"
        }
        if !usesInlineControls && isOwner && (isInteractive || (!inputStatusIsError && inputStatusLabel.stringValue.isEmpty == false)) {
            inputStatusLabel.stringValue = ""
            inputStatusLabel.isHidden = true
            inputStatusIsError = false
        }
        updateHeaderLayoutVisibility()
    }

    private func terminateOwnedScriptSessionIfNeeded() {
        guard backend == .scriptPTY else { return }
        guard preferredAttachmentMode == .owner else { return }
        guard !isApplicationTerminating else { return }
        guard isInteractiveRuntimeState(lastObservedRuntimeState) else { return }
        _ = try? transport.terminate(client.id)
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
        case .ghosttyViewerSnapshot, .outputFallback: window.makeFirstResponder(outputView)
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
        guard let frame = try? transport.loadWindowFrame(preferredAttachmentMode) else { return }
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
        try? transport.saveWindowFrame(persistedFrame, preferredAttachmentMode)
    }

    private func resolveVisibleRenderer(isOwner: Bool?) -> VisibleRenderer {
        guard backend == .ghosttyEmbedded else { return .outputFallback }
        if isOwner == true { return .ghosttyOwner }
        if ghosttySessionHost?.hasRenderableSurface() == true { return .ghosttyViewerSnapshot }
        return .outputFallback
    }

    private func currentRefreshInterval() -> Duration {
        visibleRenderer == .ghosttyOwner && !shouldShowOwnerStateLabel ? Self.ownerGhosttyRefreshInterval : Self.fallbackRefreshInterval
    }

    private func renderedOutput(snapshot: TerminalSessionClientSnapshot) throws -> TransportRenderedOutput {
        let outputByteCount = snapshot.outputByteCount
        guard outputByteCount > 0 else {
            transportScreenBuffer.reset()
            transportScreenBufferByteCount = 0
            let attributedText = NSAttributedString(
                string: snapshot.recentOutput, attributes: [.font: outputView.font, .foregroundColor: outputView.textColor])
            return TransportRenderedOutput(
                text: snapshot.recentOutput, attributedText: attributedText, replayMode: "recent_output_empty", replayBytes: 0,
                usesAlternateScreen: false, mouseTrackingMode: .disabled, usesSGRMouseEncoding: false, usesAlternateScrollMode: false,
                usesBracketedPasteMode: false)
        }

        var replayMode = "reuse"
        var replayBytes: Int64 = 0
        if outputByteCount < transportScreenBufferByteCount {
            replayMode = "rebuild_shrink"
            replayBytes = try rebuildTransportScreenBuffer(totalBytes: outputByteCount)
        } else if transportScreenBufferByteCount == 0 {
            replayMode = "rebuild_initial"
            replayBytes = try rebuildTransportScreenBuffer(totalBytes: outputByteCount)
        } else if outputByteCount > transportScreenBufferByteCount {
            replayMode = "append"
            replayBytes = try appendTransportOutputChunks(from: transportScreenBufferByteCount, to: outputByteCount)
        }

        let renderedScreen = transportScreenBuffer.renderedScreen()
        let rendered = renderedScreen.plainText
        let attributed = TerminalRenderedScreenAttributedRenderer.render(
            renderedScreen, defaultForeground: outputView.textColor, defaultBackground: outputView.backgroundColor, font: outputView.font)
        if rendered.isEmpty, !lastTransportOutput.isEmpty {
            let fallback = NSAttributedString(
                string: lastTransportOutput, attributes: [.font: outputView.font, .foregroundColor: outputView.textColor])
            return TransportRenderedOutput(
                text: lastTransportOutput, attributedText: fallback, replayMode: "recent_output_fallback", replayBytes: replayBytes,
                usesAlternateScreen: renderedScreen.usesAlternateScreen, mouseTrackingMode: renderedScreen.mouseTrackingMode,
                usesSGRMouseEncoding: renderedScreen.usesSGRMouseEncoding, usesAlternateScrollMode: renderedScreen.usesAlternateScrollMode,
                usesBracketedPasteMode: renderedScreen.usesBracketedPasteMode)
        }
        return TransportRenderedOutput(
            text: rendered, attributedText: attributed, replayMode: replayMode, replayBytes: replayBytes,
            usesAlternateScreen: renderedScreen.usesAlternateScreen, mouseTrackingMode: renderedScreen.mouseTrackingMode,
            usesSGRMouseEncoding: renderedScreen.usesSGRMouseEncoding, usesAlternateScrollMode: renderedScreen.usesAlternateScrollMode,
            usesBracketedPasteMode: renderedScreen.usesBracketedPasteMode)
    }

    private func rebuildTransportScreenBuffer(totalBytes: Int64) throws -> Int64 {
        transportScreenBuffer.reset()
        transportScreenBufferByteCount = 0
        return try appendTransportOutputChunks(from: 0, to: totalBytes)
    }

    private func appendTransportOutputChunks(from startOffset: Int64, to endOffset: Int64) throws -> Int64 {
        guard endOffset > startOffset else { return 0 }
        var offset = startOffset
        var replayBytes: Int64 = 0
        while offset < endOffset {
            let remainingBytes = endOffset - offset
            let chunkSize = Int(min(64 * 1024, remainingBytes))
            guard let chunk = try transport.readOutputChunk(offset, chunkSize) else { break }
            guard !chunk.bytes.isEmpty else { break }
            if let text = String(data: chunk.bytes, encoding: .utf8), !text.isEmpty {
                transportScreenBuffer.ingest(text)
            } else {
                let decoded = String(decoding: chunk.bytes, as: UTF8.self)
                if !decoded.isEmpty { transportScreenBuffer.ingest(decoded) }
            }
            offset += Int64(chunk.bytes.count)
            replayBytes += Int64(chunk.bytes.count)
        }
        transportScreenBufferByteCount = max(transportScreenBufferByteCount, offset)
        return replayBytes
    }

    private func rendererSummary(isOwner: Bool?) -> String {
        guard isOwner == true else {
            switch visibleRenderer {
            case .ghosttyViewerSnapshot: return "Renderer: libghostty snapshot (viewer)"
            case .outputFallback: return "Renderer: transport canvas (viewer)"
            case .ghosttyOwner: return "Renderer: libghostty (owner)"
            }
        }
        switch visibleRenderer {
        case .ghosttyOwner: return "Renderer: libghostty (owner)"
        case .ghosttyViewerSnapshot: return "Renderer: libghostty snapshot (viewer)"
        case .outputFallback: return "Renderer: transport canvas (owner)"
        }
    }

    private func currentWindowTitle(fallback: String, isOwner: Bool) -> String {
        guard backend == .ghosttyEmbedded else { return fallback }
        let baseTitle = ghosttySessionHost?.effectiveTitle ?? fallback
        return isOwner ? baseTitle : "\(baseTitle) (viewer)"
    }

    private func currentSummaryWorkingDirectory(fallback: String) -> String {
        guard backend == .ghosttyEmbedded else { return fallback }
        return ghosttySessionHost?.effectiveWorkingDirectory ?? fallback
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
        if let existingHost = GhosttyEmbeddedSessionRegistry.shared.existingHost(sessionID: launchConfiguration.sessionID) {
            ghosttySessionHost = existingHost
        }
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

    var debugRenderedOutput: String { outputView.string }
    var debugRendererSummary: String { rendererLabel.stringValue }
    var debugSummary: String { summaryLabel.stringValue }
    var debugState: String { stateLabel.stringValue }
    var debugWindowTitle: String { window?.title ?? "" }
    var debugWindowRepresentedPath: String? { window?.representedURL?.path }
    var debugWindowFrame: NSRect { window?.frame ?? .zero }
    public var attachmentMode: TerminalAttachmentMode { preferredAttachmentMode }
    public var didClose: Bool { didCloseWindow }
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
    @discardableResult func debugSendTranscriptText(_ text: String) -> Bool { sendFallbackTranscriptInput(.text(text)) }
    @discardableResult func debugSendTranscriptKey(_ key: String) -> Bool { sendFallbackTranscriptInput(.key(key)) }
    @discardableResult func debugSendTranscriptMouse(
        action: TerminalMouseAction, button: TerminalMouseButton = .none, column: Int = 1, row: Int = 1, shift: Bool = false, option: Bool = false,
        control: Bool = false
    ) -> Bool {
        sendFallbackTranscriptMouse(.init(action: action, button: button, column: column, row: row, shift: shift, option: option, control: control))
    }
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
        lastTransportOutput = (try? TerminalOutputTail.tail(path: paths.outputPath, lineCount: 200)) ?? lastTransportOutput
        recordPassiveOutputNotification(byteCount: 1)
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
        default: 100
        }
    }
    @discardableResult func debugSendGhosttyScroll(horizontal: CGFloat = 0, vertical: CGFloat) -> Bool {
        ghosttySessionHost?.debugSendScroll(horizontal: horizontal, vertical: vertical) ?? false
    }
    var debugGhosttyHasRenderableSurface: Bool { ghosttySessionHost?.hasRenderableSurface() ?? false }
    var debugGhosttySurfaceRefreshRequestCount: Int { ghosttySessionHost?.debugSurfaceRefreshRequestCount ?? 0 }
    var debugOutputDisablesSmartSubstitutions: Bool { true }
}
