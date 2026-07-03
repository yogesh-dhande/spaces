import AppKit
import Carbon
import Foundation
import spacesterminalcore
import spacesterminalghostty

/// Raised when the injected state provider has no device-owned state to render
/// yet. The pane controller surfaces the existing "unavailable" UI rather than
/// reading the daemon's `spaces.db` directly.
enum TerminalSessionStateUnavailableError: Error { case launchConfigurationUnavailable }

/// Removes the pane's NotificationCenter observers when the pane deallocates. The
/// last pane reference can be dropped off the main actor (e.g. a finished detached
/// takeover task), so teardown must not require main-actor isolation;
/// NotificationCenter observer removal is thread-safe.
private final class NotificationObserverBag: @unchecked Sendable {
    var tokens: [any NSObjectProtocol] = []
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}

/// Window-independent terminal session content: the terminal container hosting a
/// Ghostty surface, the text-renderer fallback, input row, takeover UI, find
/// handling, keyboard translation, runtime toolbar, and attachment lifecycle.
/// Hosts embed `view` into a tabbed pane container and route key events through
/// `handleKeyEvent(_:)` / `handleCommandKeyEquivalent(_:)`.
@MainActor public final class TerminalSessionPaneViewController: NSObject, NSUserInterfaceValidations {
    private static let takeoverAttemptTimeout: TimeInterval = 10

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

    /// Root view owning the whole pane content tree; hosts embed this view.
    public let view = NSView()
    /// The window currently hosting the pane's view. Pane behavior that depends on
    /// window state (key/main status, first responder) reads it through here so the
    /// pane stays window-independent.
    var window: NSWindow? { view.window }

    let sessionID: String
    private let paths: TerminalSessionPaths
    /// Device-owned terminal state (launch config, runtime state, attachment
    /// ownership, latest render payload), reached through the Device API by the
    /// injected provider. The pane controller never opens the daemon's
    /// `spaces.db`; all session state reads go through this provider.
    let stateProvider: any TerminalSessionStateProviding
    var launchConfiguration: TerminalSessionLaunchConfiguration?
    let client: TerminalClient
    var rendererMode: TerminalRendererMode
    var backend: TerminalSessionBackendKind
    var preferredAttachmentMode: TerminalAttachmentMode
    private var ownerAttachmentRequested: Bool
    let titleLabel = NSTextField(labelWithString: "")
    let summaryLabel = NSTextField(labelWithString: "")
    let stateLabel = NSTextField(labelWithString: "")
    let rendererLabel = NSTextField(labelWithString: "")
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
    var bodyTopToContentConstraint: NSLayoutConstraint?
    var bodyBottomToContentConstraint: NSLayoutConstraint?
    var bodyBottomToTakeoverConstraint: NSLayoutConstraint?
    var bodyLeadingConstraint: NSLayoutConstraint?
    var bodyTrailingConstraint: NSLayoutConstraint?
    var takeoverLeadingConstraint: NSLayoutConstraint?
    var takeoverTrailingConstraint: NSLayoutConstraint?
    var takeoverBottomConstraint: NSLayoutConstraint?
    var takeoverCenterYConstraint: NSLayoutConstraint?
    /// When a non-owner is viewing an interactive session, the pane collapses
    /// to a centered message plus the Take Over button instead of the full
    /// header/output detail stack.
    var isViewerTakeoverShellActive = false
    let sendInputAction: @Sendable (String, Bool) throws -> TerminalControlResponse
    let sendKeyAction: @Sendable (String) throws -> TerminalControlResponse
    let pasteImageAction: (@MainActor (TerminalPasteboardImage) async throws -> TerminalControlResponse)?
    let pasteboardImageReadAction: @MainActor () -> TerminalPasteboardImageReadResult
    private let takeoverAction: @Sendable (String) throws -> TerminalControlResponse
    private let attachClientAction: @Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void
    private let detachClientAction: @Sendable (String) throws -> Void
    let detachClientSynchronouslyOnClose: Bool
    /// When true, presenting the pane does not eagerly attach the live Ghostty
    /// client; the deferred-presentation path attaches it once the owner surface is
    /// ready. The app passes false so an injected attach happens immediately;
    /// metadata-only callers (and tests) pass true to refresh title/ownership
    /// without a live surface.
    let defersInitialOwnerClientAttach: Bool
    let copySelectionAction: (@MainActor () -> Bool)?
    let pasteClipboardAction: (@MainActor () -> Bool)?
    private let ownerWindowFocusAction: (@MainActor (NSWindow?) -> Void)?
    private let ownerSurfaceFocusAction: (@MainActor (Bool) -> Void)?
    let onWindowFocus: (@MainActor (String) -> Void)?
    let onWindowClose: (@MainActor (String, String, Bool) -> Void)?
    /// Runs after a user close has detached this pane's client and the daemon has processed that
    /// detach (fired off the async detach's completion). The owner uses it to stop an ad hoc shell
    /// that no longer has any attached client, since tearing the pane down also tears down the state
    /// stream that would otherwise surface the detach as an attachment-state change.
    let onCloseClientDetached: (@MainActor @Sendable () -> Void)?
    private let sessionHostProvider: @MainActor (TerminalSessionLaunchConfiguration, TerminalSessionPaths) -> any TerminalGhosttySessionHosting
    private var clientGhosttySessionHost: (any TerminalGhosttySessionHosting)?
    private var isResolvingGhosttySessionHost = false
    private var pendingGhosttyHostAttachment: PendingGhosttyHostAttachment?
    private var activeGhosttySessionHost: (any TerminalGhosttySessionHosting)?
    var takeoverTask: Task<Void, Never>?
    var takeoverTaskStartedAt: Date?
    private var takeoverAttemptID: UUID?
    var lastRenderedOutput = ""
    var isClientAttached = false
    var lastRequestedAttachmentMode: TerminalAttachmentMode?
    /// Set by the host when the pane's hosting window (or container) closes, and
    /// cleared when it is presented again; refresh loops stop while it is true.
    var didCloseWindow = false
    private var lastObservedAttachmentMode: TerminalAttachmentMode?
    var ghosttyRendererHost: (any TerminalGhosttyRendererHosting)?
    var ghosttySessionInfoProvider: (any TerminalGhosttySessionInfoProviding)?
    var visibleRenderer: VisibleRenderer = .textView
    private var lastObservedOwnerClientID: String?
    var lastObservedRuntimeState: TerminalSessionRuntimeState?
    var shouldShowOwnerStateLabel = true
    var inputStatusIsError = false
    private let notificationObservers = NotificationObserverBag()
    private var pendingOwnershipTransitionStartedAt: Date?
    private var pendingOwnershipTransitionTarget: OwnershipTransitionTarget?
    private var pendingOwnershipTransitionReason: String?
    /// Set by the host while it defers the pane's initial owner presentation; the
    /// layout collapses to a full-bleed blank surface until presentation completes.
    var isDeferringInitialOwnerPresentation = false

    /// Title the host should display for this pane (window title today, tab title
    /// later). Updated on every refresh together with `representedWorkingDirectoryURL`,
    /// after which `onDisplayTitleChanged` fires.
    public private(set) var displayTitle: String
    public private(set) var representedWorkingDirectoryURL: URL?
    public var onDisplayTitleChanged: (@MainActor (String, URL?) -> Void)?

    public init(
        sessionID: String, paths: TerminalSessionPaths, stateProvider: any TerminalSessionStateProviding,
        preferredAttachmentMode: TerminalAttachmentMode = .owner, performInitialRefresh: Bool = true,
        sendInputAction: (@Sendable (String, Bool) throws -> TerminalControlResponse)? = nil,
        sendKeyAction: (@Sendable (String) throws -> TerminalControlResponse)? = nil,
        pasteImageAction: (@MainActor (TerminalPasteboardImage) async throws -> TerminalControlResponse)? = nil,
        pasteboardImageReadAction: (@MainActor () -> TerminalPasteboardImageReadResult)? = nil,
        takeoverAction: (@Sendable (String) throws -> TerminalControlResponse)? = nil,
        attachClientAction: @escaping @Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void,
        detachClientAction: @escaping @Sendable (String) throws -> Void, copySelectionAction: (@MainActor () -> Bool)? = nil,
        detachClientSynchronouslyOnClose: Bool = true, defersInitialOwnerClientAttach: Bool = false,
        pasteClipboardAction: (@MainActor () -> Bool)? = nil, ownerWindowFocusAction: (@MainActor (NSWindow?) -> Void)? = nil,
        ownerSurfaceFocusAction: (@MainActor (Bool) -> Void)? = nil, onWindowFocus: (@MainActor (String) -> Void)? = nil,
        onWindowClose: (@MainActor (String, String, Bool) -> Void)? = nil,
        onCloseClientDetached: (@MainActor @Sendable () -> Void)? = nil,
        sessionHostProvider: (@MainActor (TerminalSessionLaunchConfiguration, TerminalSessionPaths) -> any TerminalGhosttySessionHosting)? = nil
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
        self.pasteImageAction = pasteImageAction
        self.pasteboardImageReadAction = pasteboardImageReadAction ?? { TerminalPasteboardImageReader.readImage() }
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
        self.onCloseClientDetached = onCloseClientDetached
        self.sessionHostProvider =
            sessionHostProvider ?? { launchConfiguration, paths in RemoteGhosttySessionHost(launchConfiguration: launchConfiguration, paths: paths) }
        displayTitle = "Terminal \(sessionID)"
        super.init()
        startObservingApplicationActivation()
        buildUI()
        if performInitialRefresh { refreshNow() }
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

    func ensureGhosttyHostAttached(requestID: String? = nil, reason: String, requestWindowFocus: Bool = true) {
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

    func hasAttachedGhosttyOwnerSurface() -> Bool {
        guard backend == .ghosttyEmbedded, preferredAttachmentMode == .owner, visibleRenderer == .ghosttyOwner, let host = ghosttyRendererHost,
            host.hasRenderableSurface()
        else { return false }
        if let ownerClientID = ghosttySessionInfoProvider?.activeOwnerClientID() ?? lastObservedOwnerClientID { return ownerClientID == client.id }
        return true
    }

    func logFocusMetric(_ metric: String, startedAt: Date, requestID: String?, detail: String) {
        let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
        TerminalPerformance.logMetric(
            metric, target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true,
            detail: "\(detail)\(requestDetail)")
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
            let currentTitle = currentDisplayTitle(fallback: currentLaunchConfiguration.title, isOwner: isOwner)
            let currentWorkingDirectory = currentSummaryWorkingDirectory(fallback: currentLaunchConfiguration.workingDirectory)
            displayTitle = currentTitle
            representedWorkingDirectoryURL = currentRepresentedURL(workingDirectory: currentWorkingDirectory)
            onDisplayTitleChanged?(currentTitle, representedWorkingDirectoryURL)
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

    /// `onDetached`, when provided, runs once the detach has landed — after the daemon has
    /// processed it in the async case — so a caller that then reads the authoritative attachment
    /// snapshot sees this client already gone. It also runs when there is nothing to detach, so a
    /// close always gets its post-detach hook.
    func detachLocalClientIfNeeded(synchronously: Bool = true, onDetached: (@MainActor @Sendable () -> Void)? = nil) {
        guard isClientAttached else {
            onDetached?()
            return
        }
        guard synchronously else {
            let clientID = client.id
            isClientAttached = false
            lastRequestedAttachmentMode = nil
            Task.detached(priority: .utility) { [detachClientAction] in
                try? detachClientAction(clientID)
                if let onDetached { await MainActor.run { onDetached() } }
            }
            return
        }
        do {
            try detachClientAction(client.id)
            isClientAttached = false
            lastRequestedAttachmentMode = nil
        } catch { updateInputStatus(message: String(describing: error), isError: true) }
        onDetached?()
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
        // Same fill/ink in both appearances (see the theme's primary-button tokens).
        button.layer?.backgroundColor = NSColor(themeColor: ActiveTheme.descriptor.dark.primaryButtonFill).cgColor
        button.layer?.cornerRadius = 6
        button.layer?.masksToBounds = true
        let ink = NSColor(themeColor: ActiveTheme.descriptor.dark.primaryButtonText)
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

    func isStartingRuntimeState(_ runtimeState: TerminalSessionRuntimeState?) -> Bool { runtimeState?.state == .starting }

    func isExplicitlyNonInteractiveRuntimeState(_ runtimeState: TerminalSessionRuntimeState?) -> Bool {
        guard let runtimeState else { return false }
        return !runtimeState.state.isInteractive
    }

    func canAttachToGhosttyRuntime(_ runtimeState: TerminalSessionRuntimeState?) -> Bool {
        guard !isStartingRuntimeState(runtimeState) else { return false }
        guard !isExplicitlyNonInteractiveRuntimeState(runtimeState) else { return false }
        return true
    }

    func updateGhosttySessionHostReference(for launchConfiguration: TerminalSessionLaunchConfiguration) {
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

    /// Refreshes `lastObservedRuntimeState` from the provider, keeping the previous
    /// value when the provider has none.
    func refreshRuntimeStateFromProvider() { lastObservedRuntimeState = (stateProvider.currentRuntimeState) ?? lastObservedRuntimeState }

    func initialAttachmentModeForShow() -> TerminalAttachmentMode {
        guard backend == .ghosttyEmbedded, preferredAttachmentMode == .owner else { return preferredAttachmentMode }
        guard let ownerClient = activeOwnerClient(snapshot: stateProvider.currentAttachmentSnapshot) else { return preferredAttachmentMode }
        return ownerClient.id == client.id ? .owner : .viewer
    }

    func shouldDeferInitialOwnerPresentation(wasVisible: Bool, runningUnderXCTest: Bool) -> Bool {
        guard !isStartingRuntimeState(lastObservedRuntimeState) else { return false }
        return !runningUnderXCTest && !wasVisible && launchConfiguration != nil && backend == .ghosttyEmbedded && preferredAttachmentMode == .owner
            && !ownerRendererReadyForInitialPresentation()
    }

    func ownerRendererReadyForInitialPresentation() -> Bool {
        guard backend == .ghosttyEmbedded, preferredAttachmentMode == .owner else { return true }
        guard !isExplicitlyNonInteractiveRuntimeState(lastObservedRuntimeState) else { return true }
        return visibleRenderer == .ghosttyOwner && ghosttyRendererHost?.hasRenderableSurface() == true
    }

    private func startObservingApplicationActivation() {
        notificationObservers.tokens.append(
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncGhosttyOwnerFocus(reason: "app_active", requestWindowFocus: false) }
            })
        notificationObservers.tokens.append(
            NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncGhosttyOwnerFocus(reason: "app_inactive", requestWindowFocus: false, focused: false) }
            })
        notificationObservers.tokens.append(
            NotificationCenter.default.addObserver(forName: .spacesTerminalAttachmentStateDidChange, object: nil, queue: .main) {
                [weak self] notification in
                let changedSessionID = notification.userInfo?["sessionID"] as? String
                Task { @MainActor [weak self] in
                    guard let self, let changedSessionID, changedSessionID == self.sessionID else { return }
                    self.refreshNow()
                }
            })
        notificationObservers.tokens.append(
            NotificationCenter.default.addObserver(forName: .spacesTerminalSessionMetadataDidChange, object: nil, queue: .main) {
                [weak self] notification in
                let changedSessionID = notification.userInfo?["sessionID"] as? String
                MainActor.assumeIsolated {
                    guard let self, let changedSessionID, changedSessionID == self.sessionID else { return }
                    self.refreshNow()
                }
            })
        notificationObservers.tokens.append(
            NotificationCenter.default.addObserver(forName: .spacesTerminalRuntimeStateDidChange, object: nil, queue: .main) {
                [weak self] notification in
                let changedSessionID = notification.userInfo?["sessionID"] as? String
                MainActor.assumeIsolated {
                    guard let self, let changedSessionID, changedSessionID == self.sessionID else { return }
                    self.refreshNow()
                }
            })
        notificationObservers.tokens.append(
            NotificationCenter.default.addObserver(forName: .spacesTerminalOutputDidChange, object: nil, queue: .main) { [weak self] notification in
                let changedSessionID = notification.userInfo?["sessionID"] as? String
                MainActor.assumeIsolated {
                    guard let self, let changedSessionID, changedSessionID == self.sessionID else { return }
                    guard self.visibleRenderer == .ghosttyEndedFinalRender || self.visibleRenderer == .textView else { return }
                    self.refreshNow()
                }
            })
    }
}
