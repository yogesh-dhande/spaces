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

    private struct PendingOwnershipTransition {
        let startedAt: Date
        let target: OwnershipTransitionTarget
        let reason: String
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
    /// The pane's single top-trailing banner. The pane drives its persistent notice (session ended
    /// or failed); the host hands the same instance to this pane's `TerminalLinkOpenCoordinator` for
    /// transient link activity, so the two can never fight over the corner.
    public private(set) lazy var banner = TerminalPaneBanner(hostView: view)
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
    /// Serializes this pane's attach and detach control sends. Both are blocking device round-trips
    /// that must stay off the main actor, and the daemon has to see them in the order the pane issued
    /// them: a close's detach overtaken by the attach it followed would leave the daemon holding an
    /// attachment for a pane that is gone. One queue per pane, so no pane waits on another's link.
    /// Internal (not `private`) so the debug extension can expose its drain to tests.
    let clientControlQueue = TerminalInputSerialQueue()
    /// When true, presenting the pane does not eagerly attach the live Ghostty
    /// client; the deferred-presentation path attaches it once the owner surface is
    /// ready. The app passes false so an injected attach happens immediately;
    /// metadata-only callers (and tests) pass true to refresh title/ownership
    /// without a live surface.
    let defersInitialOwnerClientAttach: Bool
    let copySelectionAction: (@MainActor () -> Bool)?
    let pasteClipboardAction: (@MainActor () -> Bool)?
    /// Asks the host to move the app-wide terminal text size by one step. The pane does not own the
    /// size: it is one value shared by every pane and persisted per profile, so a zoom key press is
    /// reported upwards and comes back to every pane through `applyTerminalTextSize`.
    public var terminalTextZoomAction: (@MainActor (TerminalTextZoomCommand) -> Void)?
    /// The size this pane renders terminal content at, both in the Ghostty mirror and in the
    /// plain-text fallback renderer. Set by the host at creation and on every change.
    private(set) var terminalTextSize: TerminalTextSize = .default
    /// Unit tests inject a uniquely-named pasteboard here so copy/paste tests never touch the user's
    /// real clipboard. Nil in the app, where copy/paste keep using `NSPasteboard.general`.
    public var pasteboardOverrideForTesting: NSPasteboard?
    private let ownerWindowFocusAction: (@MainActor (NSWindow?) -> Void)?
    private let ownerSurfaceFocusAction: (@MainActor (Bool) -> Void)?
    let onWindowFocus: (@MainActor (String) -> Void)?
    let onWindowClose: (@MainActor (String, String, Bool) -> Void)?
    /// Runs after a user close has detached this pane's client and the daemon has processed that
    /// detach (fired off the async detach's completion), carrying whether the pane held the session's
    /// owner attachment when it was closed. The host uses it to ask the daemon to stop an ad hoc shell
    /// the user closed at a bare prompt, since tearing the pane down also tears down the state stream
    /// that would otherwise surface the detach as an attachment-state change.
    let onCloseClientDetached: (@MainActor @Sendable (Bool) -> Void)?
    private let sessionHostProvider: @MainActor (TerminalSessionLaunchConfiguration, TerminalSessionPaths) -> any TerminalGhosttySessionHosting
    private var clientGhosttySessionHost: (any TerminalGhosttySessionHosting)?
    private var isResolvingGhosttySessionHost = false
    private var pendingGhosttyHostAttachment: PendingGhosttyHostAttachment?
    private var activeGhosttySessionHost: (any TerminalGhosttySessionHosting)?
    var takeoverAttemptStartedAt: Date?
    private var takeoverAttemptID: UUID?
    /// Whether a takeover control this pane issued is still queued or in flight. Every completion path
    /// is keyed by `takeoverAttemptID`, so the id is also what says an attempt is outstanding.
    var isTakeoverAttemptPending: Bool { takeoverAttemptID != nil }
    var lastRenderedOutput = ""
    var isClientAttached = false
    var lastRequestedAttachmentMode: TerminalAttachmentMode?
    /// The attach send that is queued or in flight, if any. A refresh running before that send lands
    /// still reads a snapshot without this client's attachment and clears the optimistic flags above,
    /// so this — not those flags — is what keeps such a refresh from queueing a second attach for the
    /// same mode behind the first. The id distinguishes a superseded attach's late completion from
    /// the current one's.
    private var pendingAttach: (id: UUID, mode: TerminalAttachmentMode)?
    /// The message a failed attach put in the input status, so a later successful attach can retire it
    /// (see `clearAttachErrorStatusIfShowing`). Nil whenever no attach failure is on display.
    private var attachErrorStatusMessage: String?
    /// The attachment mode the pane hands its session host. Owner interactivity — the host accepting
    /// keystrokes, and the owner-attach viewport it sends — follows the attachment the daemon has
    /// CONFIRMED, not the optimistic intent above: until the queued attach lands this client is not the
    /// owner, so keystrokes and a viewport resize riding the host's own queues would reach the daemon
    /// ahead of it and be rejected. The host is still attached, as a viewer, so the pane keeps
    /// presenting the session's last known frame throughout; `finishAttach` re-runs the host attach
    /// when the daemon answers, which is where the host flips to owner and the viewport goes out.
    private var confirmedHostAttachmentMode: TerminalAttachmentMode { pendingAttach == nil ? preferredAttachmentMode : .viewer }
    /// Set by the host when the pane's hosting window (or container) closes, and
    /// cleared when it is presented again; refresh loops stop while it is true.
    var didCloseWindow = false
    private var lastObservedAttachmentMode: TerminalAttachmentMode?
    var ghosttyRendererHost: (any TerminalGhosttyRendererHosting)?
    var ghosttySessionInfoProvider: (any TerminalGhosttySessionInfoProviding)?
    var visibleRenderer: VisibleRenderer = .textView
    /// Whether the session host had a renderable surface when this pane last resolved what to
    /// present; `nil` until it has resolved one. `refreshNow` records it on every exit — including
    /// the owner-surface early return and the failure path — so it always describes the surface the
    /// currently presented renderer was chosen from, across ownership changes, renderer transitions,
    /// and a host that is swapped or released underneath the pane. Screen-content payloads compare
    /// against it (`screenContentCanChangePresentation`) to tell a first frame arriving from an
    /// unchanged blank pane.
    private var surfaceAvailabilityAtLastPresentation: Bool?
    private var lastObservedOwnerClientID: String?
    /// Whether this pane's client holds the session's owner attachment, as of the last snapshot it
    /// observed. Read at close time, before the detach, so the close can report an owner close: only an
    /// owner close asks the daemon to stop an ad hoc terminal, and closing a viewer never stops one.
    var holdsOwnerAttachment: Bool { lastObservedOwnerClientID == client.id || lastObservedAttachmentMode == .owner }
    var lastObservedRuntimeState: TerminalSessionRuntimeState?
    var shouldShowOwnerStateLabel = true
    var inputStatusIsError = false
    private let notificationObservers = NotificationObserverBag()
    private var pendingOwnershipTransition: PendingOwnershipTransition?
    /// Set by the host while it defers the pane's initial owner presentation; the
    /// layout collapses to a full-bleed blank surface until presentation completes.
    var isDeferringInitialOwnerPresentation = false
    // An extra retain on the pane's view-hierarchy root, dropped on the main queue by deinit so an
    // off-main last release of the pane cannot deallocate AppKit objects on a background thread.
    // The root suffices — every UI member below is one of its descendants, so releasing the stored
    // properties off-main drops none of them to zero, and views added later are covered without
    // touching this.
    private nonisolated(unsafe) var mainThreadReleaseBag: [AnyObject] = []
    // The view root above does not cover the session host: a viewer pane never attaches the host's
    // Ghostty terminal view, and releasing the surface strips `terminalContainer`'s subviews, so the
    // host and its C-backed view can outlive the hierarchy. Replaced rather than appended in step
    // with `activeGhosttySessionHost` — appending would pin every past host's mirror alive.
    private nonisolated(unsafe) var activeGhosttySessionHostForMainThreadRelease: AnyObject?

    /// Title the host should display for this pane (window title today, tab title
    /// later). Updated on every refresh together with `representedWorkingDirectoryURL`,
    /// after which `onDisplayTitleChanged` fires.
    public private(set) var displayTitle: String
    public private(set) var representedWorkingDirectoryURL: URL?
    public var onDisplayTitleChanged: (@MainActor (String, URL?) -> Void)?

    public init(
        sessionID: String, paths: TerminalSessionPaths, stateProvider: any TerminalSessionStateProviding,
        preferredAttachmentMode: TerminalAttachmentMode = .owner, performInitialRefresh: Bool = true, reusableOwnerClientID: String? = nil,
        sendInputAction: (@Sendable (String, Bool) throws -> TerminalControlResponse)? = nil,
        sendKeyAction: (@Sendable (String) throws -> TerminalControlResponse)? = nil,
        pasteImageAction: (@MainActor (TerminalPasteboardImage) async throws -> TerminalControlResponse)? = nil,
        pasteboardImageReadAction: (@MainActor () -> TerminalPasteboardImageReadResult)? = nil,
        takeoverAction: (@Sendable (String) throws -> TerminalControlResponse)? = nil,
        attachClientAction: @escaping @Sendable (TerminalClient, TerminalAttachmentMode) throws -> Void,
        detachClientAction: @escaping @Sendable (String) throws -> Void, copySelectionAction: (@MainActor () -> Bool)? = nil,
        defersInitialOwnerClientAttach: Bool = false, pasteClipboardAction: (@MainActor () -> Bool)? = nil,
        ownerWindowFocusAction: (@MainActor (NSWindow?) -> Void)? = nil, ownerSurfaceFocusAction: (@MainActor (Bool) -> Void)? = nil,
        onWindowFocus: (@MainActor (String) -> Void)? = nil, onWindowClose: (@MainActor (String, String, Bool) -> Void)? = nil,
        onCloseClientDetached: (@MainActor @Sendable (Bool) -> Void)? = nil,
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
        let now = TerminalSessionTimestamp.string(from: Date())
        // Reuse the owner client id this device stored on its last successful owner attach/takeover
        // for this session, when the caller supplies one; otherwise mint a fresh id. A relaunched
        // window (e.g. after an app upgrade) then presents the SAME id to the daemon, so its
        // orphaned `localWindow` owner attachment — which never expires — matches and the pane
        // silently reclaims ownership instead of attaching as a viewer behind the manual takeover UI.
        // Safety: the stored UUID exists only on this Mac, so it can only ever match THIS device's own
        // prior attachment. If another device owns the session, the ids differ and the pane attaches
        // as a viewer with the takeover UI unchanged.
        client = TerminalClient(
            id: reusableOwnerClientID ?? UUID().uuidString, kind: .localWindow,
            identity: TerminalClientIdentity(label: "Spaces window", hostName: Host.current().name, deviceName: Host.current().localizedName),
            connectedAt: now)
        self.sendInputAction =
            sendInputAction ?? { [socketPath = paths.controlSocketPath, client] text, appendNewline in
                try TerminalControlClient.send(
                    request: TerminalControlRequest(
                        command: .send(.init(text: text, bytes: nil, clientID: client.id, ownerEpoch: nil, appendNewline: appendNewline))),
                    socketPath: socketPath)
            }
        self.sendKeyAction =
            sendKeyAction ?? { [socketPath = paths.controlSocketPath, client] key in
                try TerminalControlClient.send(
                    request: TerminalControlRequest(command: .key(.init(key: key, clientID: client.id, ownerEpoch: nil))), socketPath: socketPath)
            }
        self.pasteImageAction = pasteImageAction
        self.pasteboardImageReadAction = pasteboardImageReadAction ?? { TerminalPasteboardImageReader.readImage() }
        self.takeoverAction =
            takeoverAction ?? { clientID in
                try TerminalControlClient.send(
                    request: TerminalControlRequest(command: .takeover(.init(clientID: clientID))), socketPath: paths.controlSocketPath)
            }
        self.attachClientAction = attachClientAction
        self.detachClientAction = detachClientAction
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
        mainThreadReleaseBag = [view]
    }

    deinit { MainThreadRelease.release(mainThreadReleaseBag + [activeGhosttySessionHostForMainThreadRelease].compactMap { $0 }) }

    /// Renders this pane's terminal content at `size`. Covers both renderers a pane can present: the
    /// Ghostty mirror (which keeps the size across its own surface rebuilds) and the plain-text
    /// fallback the pane shows when no surface exists, such as an ended session's final render.
    public func applyTerminalTextSize(_ size: TerminalTextSize) {
        terminalTextSize = size
        outputView.font = .monospacedSystemFont(ofSize: CGFloat(size.points), weight: .regular)
        ghosttyRendererHost?.applyTerminalTextSize(size)
    }

    public func requestOwnershipIfNeeded() {
        guard backend == .ghosttyEmbedded else { return }
        ownerAttachmentRequested = true
        preferredAttachmentMode = .owner
        if let launchConfiguration { updateGhosttySessionHostReference(for: launchConfiguration) }
        lastObservedRuntimeState = (stateProvider.currentRuntimeState) ?? lastObservedRuntimeState
        let attachmentSnapshot = stateProvider.currentAttachmentSnapshot
        let currentOwnerClient = activeOwnerClient(snapshot: attachmentSnapshot)
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
        if currentOwnerClient?.id == client.id, activeAttachment(snapshot: attachmentSnapshot)?.mode == .owner {
            isClientAttached = true
            lastRequestedAttachmentMode = .owner
            lastObservedAttachmentMode = .owner
            ensureGhosttyHostAttached(reason: "request_owner_mode")
            refreshNow()
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
        // A retry supersedes an outstanding attempt only once that attempt has been *sending* for longer
        // than the timeout. An attempt still queued behind other controls has stamped no start and is
        // not stale however long it has waited: treating the wait as the attempt would duplicate the
        // takeover on the wire the moment a busy queue outlasted the budget. Superseding is the new
        // attempt id assigned below; every completion path is keyed by it, so whatever the stale attempt
        // eventually answers is inert.
        if isTakeoverAttemptPending {
            guard let takeoverAttemptStartedAt, now.timeIntervalSince(takeoverAttemptStartedAt) >= Self.takeoverAttemptTimeout else { return }
        }
        let startedAt = now
        let attemptID = UUID()
        let clientID = client.id
        takeoverButton.isEnabled = false
        takeoverAttemptStartedAt = nil
        takeoverAttemptID = attemptID
        // The takeover rides the pane's client-control queue for the same reason attach and detach do:
        // the daemon has to see it behind the attach this pane already issued. Sent on its own it could
        // overtake that attach, and the daemon would either refuse a takeover naming a client it has not
        // seen attach, or grant it and then have the late attach demote this client straight back to
        // viewer — leaving the session with no owner.
        //
        // Unlike the attach, the send needs no current-intent check of its own: an attempt can only be
        // superseded after it has stamped a start, which happens here immediately before the send, so a
        // superseded takeover is always one already on the wire. A retry then names the same client the
        // stale attempt did, which is why the daemon seeing both is harmless.
        clientControlQueue.enqueue(priority: .userInitiated) { [weak self, takeoverAction] in
            await self?.beginTakeoverAttempt(id: attemptID)
            let controlStartedAt = Date()
            do {
                let response = try takeoverAction(clientID)
                await MainActor.run {
                    guard let self, self.takeoverAttemptID == attemptID else { return }
                    defer { self.clearTakeoverAttempt(id: attemptID) }
                    guard response.ok else {
                        TerminalPerformance.logMetric(
                            "terminal_viewer_takeover", target: "session=\(self.sessionID) client=\(clientID)",
                            elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false, detail: "stage=control_response")
                        self.finishFailedTakeoverAttempt(id: attemptID, message: response.message)
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
                    guard let self, self.takeoverAttemptID == attemptID else { return }
                    TerminalPerformance.logMetric(
                        "terminal_viewer_takeover", target: "session=\(self.sessionID) client=\(clientID)",
                        elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: false, detail: "stage=exception")
                    self.finishFailedTakeoverAttempt(id: attemptID, message: String(describing: error))
                }
            }
        }
        refreshNow(allowGhosttyOwnerAttach: false)
    }

    /// Stamps the moment a queued takeover starts sending, which is what the retry timeout measures.
    /// Skipped for an attempt that is no longer current, so a stale attempt cannot restamp the one that
    /// replaced it.
    private func beginTakeoverAttempt(id: UUID) {
        guard takeoverAttemptID == id else { return }
        takeoverAttemptStartedAt = Date()
    }

    private func finishFailedTakeoverAttempt(id: UUID, message: String) {
        guard takeoverAttemptID == id else { return }
        clearTakeoverAttempt(id: id)
        let attachmentSnapshot = stateProvider.currentAttachmentSnapshot
        if activeOwnerClient(snapshot: attachmentSnapshot)?.id != client.id {
            ownerAttachmentRequested = false
            preferredAttachmentMode = activeAttachment(snapshot: attachmentSnapshot)?.mode ?? .viewer
        }
        refreshNow(allowGhosttyOwnerAttach: false)
        updateInputStatus(message: message, isError: true)
    }

    private func clearTakeoverAttempt(id: UUID) {
        guard takeoverAttemptID == id else { return }
        takeoverAttemptStartedAt = nil
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
            let attachmentMode = confirmedHostAttachmentMode
            try host.attach(client: client, mode: attachmentMode, into: terminalContainer)
            if defersInitialOwnerClientAttach { isClientAttached = true }
            // The pane's own record of its attachment stays the requested mode even while the host is
            // held at viewer: it is what the attachment-transition rules in `refreshNow` compare a
            // snapshot against, and recording a momentary viewer here would hide a real demotion.
            lastObservedAttachmentMode = preferredAttachmentMode
            lastObservedOwnerClientID = host.activeOwnerClientID()
            syncGhosttyOwnerFocus(reason: "attach_owner_surface", requestWindowFocus: requestWindowFocus && attachmentMode == .owner)
            completeOwnershipTransitionIfNeeded(target: .owner, renderer: "ghostty_owner")
            updateRendererVisibility()
            logFocusMetric(
                "terminal_window_attach_owner_surface", startedAt: startedAt, requestID: requestID,
                detail: "reason=\(reason) mode=\(attachmentMode.rawValue)")
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

    /// Whether this pane holds the session's owner attachment on a live surface right now: it asked for
    /// owner mode, it is showing the owner renderer, that surface has content, and the session's active
    /// owner is this pane's client. False whenever the owner is another client (or is not yet known), which
    /// is what keeps a re-show of the pane from skipping the ownership reclaim that is the point of the
    /// request.
    public var holdsOwnerAttachedSurface: Bool {
        guard backend == .ghosttyEmbedded, preferredAttachmentMode == .owner, visibleRenderer == .ghosttyOwner, let host = ghosttyRendererHost,
            host.hasRenderableSurface()
        else { return false }
        guard let ownerClientID = ghosttySessionInfoProvider?.activeOwnerClientID() ?? lastObservedOwnerClientID else { return false }
        return ownerClientID == client.id
    }

    func logFocusMetric(_ metric: String, startedAt: Date, requestID: String?, detail: String) {
        let requestDetail = requestID.map { " request_id=\($0)" } ?? ""
        TerminalPerformance.logMetric(
            metric, target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), success: true,
            detail: "\(detail)\(requestDetail)")
    }

    private func beginOwnershipTransition(_ target: OwnershipTransitionTarget, reason: String) {
        pendingOwnershipTransition = PendingOwnershipTransition(startedAt: Date(), target: target, reason: reason)
    }

    private func completeOwnershipTransitionIfNeeded(target: OwnershipTransitionTarget, renderer: String) {
        guard let pending = pendingOwnershipTransition, pending.target == target else { return }
        let startedAt = pending.startedAt
        let reason = pending.reason
        pendingOwnershipTransition = nil
        TerminalPerformance.logMetric(
            "terminal_ownership_transition", target: "session=\(sessionID)", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            success: true, detail: "target=\(target.rawValue) renderer=\(renderer) reason=\(reason)")
    }

    func refreshNow(allowGhosttyOwnerAttach: Bool = true) {
        // A refresh is where the pane resolves what it presents, so it is also where the surface
        // availability that resolution was made from is recorded. Recording on exit captures a
        // surface this refresh attached or released.
        defer { surfaceAvailabilityAtLastPresentation = hasRenderableGhosttySurface }
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
            let attachmentSnapshot = stateProvider.currentAttachmentSnapshot
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
                    // An attach the daemon has not answered yet cannot show up in this snapshot, so its
                    // absence says nothing about a pending one. Keeping the intent is what makes a close
                    // during the attach still send the detach (ordered behind it) rather than leave the
                    // daemon holding an attachment for a pane that is gone.
                    if pendingAttach == nil {
                        isClientAttached = false
                        lastRequestedAttachmentMode = nil
                    }
                    lastObservedAttachmentMode = nil
                    if wasObservedAsAttachedOwner, preferredAttachmentMode == .owner, let currentOwnerClient, currentOwnerClient.id != client.id {
                        // The pane presents as a viewer behind whoever the snapshot says owns the session,
                        // but it gives up SEEKING ownership only on evidence that it lost an attachment it
                        // held. With an attach still outstanding this snapshot carries no such evidence —
                        // it cannot describe this client's attachment at all — and giving up on it would
                        // park an owner-seeking pane as a viewer for good, since nothing short of a user
                        // request asks again. That mirrors `shouldPreserveOwnerRequest` below, which keeps
                        // the request across an observed viewer attachment for the same reason.
                        if pendingAttach == nil { ownerAttachmentRequested = false }
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
                // The attach is sent off the main actor, so the rest of this refresh deliberately
                // resolves against the snapshot as it stands: the request cannot be reflected in it
                // yet. The daemon broadcasts the attachment change once the send lands, which brings
                // the pane back through here with an authoritative snapshot.
                if let attachmentModeToRequest { attachLocalClientIfNeeded(mode: attachmentModeToRequest) }
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
                    } else if !canKeepOwnerRequest && !isTakeoverAttemptPending {
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
            updatePersistentBanner(runtimeState: runtimeState, isStateStreamDisconnected: isStateStreamDisconnected)
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

    /// Records the attachment intent and sends the attach off the main actor, so presenting a pane
    /// never waits on a device round-trip. The pane keeps presenting its last known state meanwhile;
    /// the landed attach reaches it as an attachment-state broadcast, the same way any other client's
    /// attachment change does.
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
        // An attach already queued for this mode covers the request; only an explicit reclaim
        // (`force`) re-sends behind it.
        guard force || pendingAttach?.mode != attachmentMode else { return }
        let requestedMode = attachmentMode
        // Optimistic: the intent is recorded before the send so the pane presents as attached right
        // away and no later refresh re-issues the same attach. `finishAttach` rolls it back when the
        // send fails, so the next show retries.
        isClientAttached = true
        lastRequestedAttachmentMode = requestedMode
        let attachID = UUID()
        pendingAttach = (id: attachID, mode: requestedMode)
        let attachingClient = client
        clientControlQueue.enqueue(priority: .userInitiated) { [weak self, attachClientAction] in
            // Ordering the sends is not enough on its own: a queued attach the pane has already replaced
            // asks the daemon for a mode that is wrong by definition. An owner attach superseded by the
            // viewer attach a lost-ownership refresh issued would, if it still went out, displace the
            // session's new owner — and the viewer attach behind it then demotes this client, leaving
            // the session with nobody owning it. So only the newest intent gets to send.
            // Accepted residual: the check runs at send time, so an owner attach superseded while
            // ALREADY IN FLIGHT can still land, and the same ownerless corner exists inside that one
            // network round trip. Both clients then read the true state off the attachment broadcast
            // and either's takeover prompt restores it in one action; closing the window needs the
            // attach request to carry an ownership precondition the daemon checks — a wire change a
            // two-client race inside one RTT does not justify.
            let isCurrentIntent = await self?.isCurrentPendingAttach(id: attachID) ?? false
            guard isCurrentIntent else { return }
            do {
                try attachClientAction(attachingClient, requestedMode)
                await self?.finishAttach(id: attachID, mode: requestedMode, error: nil)
            } catch { await self?.finishAttach(id: attachID, mode: requestedMode, error: error) }
        }
    }

    /// Whether `id` is still the attach the pane wants sent. Its queued send checks this immediately
    /// before going out, so a superseded attach is dropped rather than delivered; `pendingAttach` is
    /// left alone either way, since by then it belongs to the intent that replaced this one.
    private func isCurrentPendingAttach(id: UUID) -> Bool { pendingAttach?.id == id }

    /// Completion for an attach send that has landed. An attach superseded while it was in flight — the
    /// window the pre-send check in `attachLocalClientIfNeeded` cannot cover — is inert here: its
    /// outcome describes a request the pane has already moved on from, so it neither rolls back the
    /// current intent nor reports anything, which is what keeps a stale failure from sitting on a pane
    /// the daemon has since answered.
    ///
    /// A confirmed attach is where the pane's host becomes interactive: clearing `pendingAttach` moves
    /// `confirmedHostAttachmentMode` to the requested mode, and re-running the host attach is what
    /// promotes the host from viewer to owner — the same funnel the daemon's attachment broadcast
    /// drives. It claims no window focus: the show that issued this attach already made whatever claim
    /// it intended, and the surface reclaims first responder itself once it accepts input.
    ///
    /// A failure clears the optimistic attachment state so a later show retries the attach.
    private func finishAttach(id: UUID, mode: TerminalAttachmentMode, error: (any Error)?) {
        guard pendingAttach?.id == id else { return }
        pendingAttach = nil
        guard let error else {
            clearAttachErrorStatusIfShowing()
            ensureGhosttyHostAttached(reason: "client_attach_confirmed", requestWindowFocus: false)
            return
        }
        if lastRequestedAttachmentMode == mode {
            isClientAttached = false
            lastRequestedAttachmentMode = nil
        }
        let message = String(describing: error)
        attachErrorStatusMessage = message
        updateInputStatus(message: message, isError: true)
    }

    /// Retires the message a failed attach left in the input status once a later attach succeeds.
    /// Mirrors `clearDisconnectedInputStatusIfResolved`: the row holds one message at a time and every
    /// writer owns its own, so this clears only its exact text — an unrelated status the user is
    /// looking at (a send error, an ownership refusal) had no part in the attach and must survive it.
    private func clearAttachErrorStatusIfShowing() {
        guard let attachErrorStatusMessage, inputStatusLabel.stringValue == attachErrorStatusMessage else { return }
        self.attachErrorStatusMessage = nil
        updateInputStatus(message: "", isError: false)
    }

    /// Sends the detach off the main actor, ordered behind whatever attach this pane already issued.
    /// `onDetached`, when provided, runs once the detach has landed — after the daemon has processed
    /// it — so a caller that then reads the authoritative attachment snapshot sees this client
    /// already gone. It also runs when there is nothing to detach, so a close always gets its
    /// post-detach hook.
    func detachLocalClientIfNeeded(onDetached: (@MainActor @Sendable () -> Void)? = nil) {
        guard isClientAttached else {
            onDetached?()
            return
        }
        let clientID = client.id
        isClientAttached = false
        lastRequestedAttachmentMode = nil
        // The detach supersedes any attach still in flight, so a re-show of this pane must be free to
        // issue a fresh attach behind it rather than be deduplicated against the superseded one.
        pendingAttach = nil
        clientControlQueue.enqueue(priority: .utility) { [detachClientAction] in
            try? detachClientAction(clientID)
            if let onDetached { await MainActor.run { onDetached() } }
        }
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
        // A borderless NSButton has no bezel for AppKit's default focus ring to hug, so the ring
        // draws around the title cell instead — a rectangle mismatched with the rounded teal fill.
        // Suppress it; the teal layer is the button's own affordance.
        button.focusRingType = .none
        button.wantsLayer = true
        // Same fill/ink in both appearances (see the theme's primary-button tokens).
        button.layer?.backgroundColor = NSColor(themeColor: ActiveTheme.descriptor.dark.primaryButtonFill).cgColor
        button.layer?.cornerRadius = 6
        button.layer?.masksToBounds = true
        let ink = NSColor(themeColor: ActiveTheme.descriptor.dark.primaryButtonText)
        button.contentTintColor = ink
        button.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: ink, .font: Typography.primaryButtonLabel])
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

    /// True while the provider has lost its live subscription to the owning device and is retrying.
    /// Read from the provider at use time rather than cached: unlike runtime state, which arrives on
    /// the stream this describes, it changes precisely when there is no stream to carry it.
    var isStateStreamDisconnected: Bool { stateProvider.isStateStreamDisconnected }

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
        activeGhosttySessionHostForMainThreadRelease = hostObject
        let resolvedHostComponents = Self.resolveGhosttyHostComponents(host)
        ghosttyRendererHost = resolvedHostComponents.rendererHost
        ghosttySessionInfoProvider = resolvedHostComponents.sessionInfoProvider
        // A host is resolved lazily, long after the pane was told what size to render at, so the
        // current size is pushed here rather than only when it changes.
        ghosttyRendererHost?.applyTerminalTextSize(terminalTextSize)
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

    private func activeAttachment(snapshot: TerminalSessionAttachmentSnapshot?) -> TerminalAttachment? {
        snapshot?.attachments.last { $0.clientID == client.id && $0.detachedAt == nil }
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
        return isPresentingLiveGhosttyMirror
    }

    private var hasRenderableGhosttySurface: Bool { ghosttyRendererHost?.hasRenderableSurface() == true }

    /// True when the pane is already showing the live Ghostty mirror: it holds the owner surface
    /// and that surface has a frame. Every other renderer state is either presenting something
    /// derived elsewhere (the plain-text tail, the frozen final render) or waiting for a first
    /// frame it cannot see until the pane re-resolves its renderer.
    private var isPresentingLiveGhosttyMirror: Bool { visibleRenderer == .ghosttyOwner && hasRenderableGhosttySurface }

    /// Whether a screen-content payload can change what this pane presents, and so whether it is
    /// worth a refresh. Screen content arrives at interaction frequency, and a refresh re-resolves
    /// attachment, ownership, and the renderer and re-derives every title in the panel, so a pane
    /// that would present exactly what it already presents must not pay for one.
    ///
    /// - The live mirror has painted the payload itself.
    /// - The takeover status screen presents no session content at all: a mostly blank pane behind
    ///   a Take Over button, shown to a viewer watching a session another client owns and to an
    ///   owner whose first frame has not landed. Its message is derived from runtime state,
    ///   ownership, and metadata, each broadcast under its own state reason, so the only change a
    ///   screen-content payload can make to it is the surface becoming renderable — which promotes
    ///   the pane to the mirror. While surface availability is unchanged there is nothing to
    ///   re-present, however chatty the session is.
    /// - Every other renderer re-derives what it presents from the session host on each refresh, so
    ///   it keeps refreshing: the ended session's final render refills the pane's copy buffer from
    ///   the host snapshot as an ended-scrollback replay scrolls it, and the "render unavailable"
    ///   and plain-text screens are waiting for a final render that reaches them as a host snapshot
    ///   without the pane ever holding a renderable surface of its own.
    private var screenContentCanChangePresentation: Bool {
        if isPresentingLiveGhosttyMirror { return false }
        if visibleRenderer == .ghosttyTakeoverStatus { return hasRenderableGhosttySurface != surfaceAvailabilityAtLastPresentation }
        return true
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
                let changedSessionID = TerminalSessionNotification.sessionID(from: notification)
                Task { @MainActor [weak self] in
                    guard let self, let changedSessionID, changedSessionID == self.sessionID else { return }
                    self.refreshNow()
                }
            })
        notificationObservers.tokens.append(
            NotificationCenter.default.addObserver(forName: .spacesTerminalSessionMetadataDidChange, object: nil, queue: .main) {
                [weak self] notification in
                let changedSessionID = TerminalSessionNotification.sessionID(from: notification)
                MainActor.assumeIsolated {
                    guard let self, let changedSessionID, changedSessionID == self.sessionID else { return }
                    self.refreshNow()
                }
            })
        notificationObservers.tokens.append(
            NotificationCenter.default.addObserver(forName: .spacesTerminalRuntimeStateDidChange, object: nil, queue: .main) {
                [weak self] notification in
                let changedSessionID = TerminalSessionNotification.sessionID(from: notification)
                MainActor.assumeIsolated {
                    guard let self, let changedSessionID, changedSessionID == self.sessionID else { return }
                    self.refreshNow()
                }
            })
        // The provider's subscription to the owning device dropped or came back. Nothing else fires
        // during an outage — the stream that would carry a state change is the thing that is gone —
        // so this is what puts the pane's disconnected notice up and takes it down again.
        //
        // Deliberately the banner alone, not a full `refreshNow()`: the link state is the only thing
        // that moved (with no stream, nothing else can have), so a full refresh would only re-derive
        // presentation from state that has not changed and queue an attach against the very device
        // this notification says is unreachable.
        notificationObservers.tokens.append(
            NotificationCenter.default.addObserver(forName: .spacesTerminalStateStreamConnectionDidChange, object: nil, queue: .main) {
                [weak self] notification in
                let changedSessionID = TerminalSessionNotification.sessionID(from: notification)
                MainActor.assumeIsolated {
                    guard let self, let changedSessionID, changedSessionID == self.sessionID else { return }
                    self.refreshRuntimeStateFromProvider()
                    self.updatePersistentBanner(
                        runtimeState: self.lastObservedRuntimeState, isStateStreamDisconnected: self.isStateStreamDisconnected)
                    self.clearDisconnectedInputStatusIfResolved()
                }
            })
        notificationObservers.tokens.append(
            NotificationCenter.default.addObserver(forName: .spacesTerminalOutputDidChange, object: nil, queue: .main) { [weak self] notification in
                let changedSessionID = TerminalSessionNotification.sessionID(from: notification)
                MainActor.assumeIsolated {
                    guard let self, let changedSessionID, changedSessionID == self.sessionID else { return }
                    // Screen content changed. Refresh only when that can change what this pane
                    // presents: typing, scrolling, and resizing must stay off the refresh path both
                    // for the pane whose mirror painted them and for a pane parked on the takeover
                    // screen, which shows no session content. A pane still waiting for its first
                    // renderable frame does pick it up here — the payload that supplies it arrives
                    // under a screen-content reason (the catch-up `.state` response is stamped
                    // `state_change`).
                    guard self.screenContentCanChangePresentation else { return }
                    self.refreshNow()
                }
            })
    }
}
