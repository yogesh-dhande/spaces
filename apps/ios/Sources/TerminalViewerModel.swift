import CryptoKit
import Darwin
import Foundation
import Network
import Observation
import UIKit
import spacesdevicecore
import spacesterminalcore
import spacesterminalmobileghostty

private let terminalViewerTraceEnabled = ProcessInfo.processInfo.environment["SPACES_MOBILE_TERMINAL_TRACE"] == "1"

private func terminalViewerTrace(_ sessionID: String, _ message: @autoclosure () -> String) {
    guard terminalViewerTraceEnabled else { return }
    fputs("spaces-mobile-terminal-trace t=\(terminalViewerTraceSeconds()) ios-viewer session=\(sessionID) \(message())\n", stderr)
    fflush(stderr)
}

private func terminalViewerTraceSeconds() -> String { String(format: "%.3f", Date().timeIntervalSince1970) }

private enum TerminalViewerRenderMode: String {
    case status
    case ownerBootstrapping
    case ownerLive = "ghostty-mirror"
    case ended
}

enum TerminalViewerPhase: Equatable {
    case unavailable
    case ended
    case starting
    case connecting(owner: Bool)
    case ownerBusy
    case ownerSynchronizing
    case ownerInteractive
    case takingOver
    case viewingOtherOwner
}

private enum TerminalLinkPreviewRequestError: Error { case stale }

/// What a resolved terminal link previews as. Every case carries the on-device URL the sheet renders:
/// a local cache file for `quickLook`/`text`/`markdown`/`htmlFile`, or the original remote URL for
/// `webPage`. `TerminalLinkPreviewSheet` switches on this to pick the viewer.
enum TerminalLinkPreviewContent: Equatable {
    case quickLook(URL)
    case text(URL)
    case markdown(URL)
    case htmlFile(URL)
    case webPage(URL)

    var url: URL {
        switch self {
        case .quickLook(let url), .text(let url), .markdown(let url), .htmlFile(let url), .webPage(let url): return url
        }
    }

    /// Stable case name for the e2e render dump; not user-facing.
    var caseName: String {
        switch self {
        case .quickLook: return "quickLook"
        case .text: return "text"
        case .markdown: return "markdown"
        case .htmlFile: return "htmlFile"
        case .webPage: return "webPage"
        }
    }
}

struct TerminalLinkPreview: Identifiable, Equatable {
    let id: String
    let title: String
    /// `nil` only for `.webPage`: a plain web URL has no device-previewable artifact kind.
    let kind: SpacesDeviceTerminalLinkArtifactKind?
    let content: TerminalLinkPreviewContent
}

extension SpacesDeviceTerminalLinkArtifactKind {
    /// User-facing noun for error copy, e.g. "The media link did not return \(previewNoun) content."
    fileprivate var previewNoun: String {
        switch self {
        case .image: return "image"
        case .video: return "video"
        case .pdf: return "PDF"
        case .markdown: return "Markdown"
        case .text: return "text"
        case .html: return "HTML"
        }
    }
}

@MainActor @Observable final class TerminalViewerModel {
    let session: SpacesDeviceTerminalSessionSummary
    let settings: SpacesMobileConnectionSettings
    /// Demo Mode is view-only: the backend serves a recorded transcript and rejects every write. The
    /// viewer honors that by rendering the recorded frame through the read-only ended-surface path,
    /// never attempting ownership takeover, and never offering an input affordance — so the recorded
    /// transcript stays visible and scrollable while typing, take-over, and the composer are absent.
    let isDemoMode: Bool
    private let onAuthenticationRequired: @MainActor @Sendable (String) -> Void
    private let onOpenTerminalDeepLink: @MainActor @Sendable (SpacesTerminalDeepLink) -> Void

    var latestState: GhosttyRemoteSessionStatePayload?
    /// Unit tests inject a uniquely-named pasteboard here so an owner-targeted OSC 52 write never
    /// touches the device's real clipboard. Nil in the app, where the write goes to
    /// `UIPasteboard.general`.
    var pasteboardOverrideForTesting: UIPasteboard?
    var isConnecting = false
    var isBusy = false
    var isSessionUnavailable = false
    var isSynchronizingOwnership = false {
        didSet {
            guard isSynchronizingOwnership != oldValue else { return }
            trace("ownership_sync active=\(isSynchronizingOwnership ? 1 : 0)")
        }
    }
    var isOwnershipSynchronizationScheduled = false {
        didSet {
            guard isOwnershipSynchronizationScheduled != oldValue else { return }
            trace("ownership_sync scheduled=\(isOwnershipSynchronizationScheduled ? 1 : 0)")
        }
    }
    var isInputSurfaceReady = false {
        didSet {
            guard isInputSurfaceReady != oldValue else { return }
            trace("input_surface_ready value=\(isInputSurfaceReady ? 1 : 0) accepts_input=\(acceptsInput ? 1 : 0) owner=\(isOwner ? 1 : 0)")
        }
    }
    var errorMessage: String? {
        didSet {
            guard errorMessage != oldValue else { return }
            trace("error_message value=\(sanitizedTraceDetail(errorMessage ?? "nil"))")
        }
    }
    var isPreparingLinkPreview = false
    var linkPreviewErrorMessage: String?
    var linkPreview: TerminalLinkPreview?
    /// Set when a tapped terminal link resolves to a loopback host (e.g. `http://localhost:3000`):
    /// that address only makes sense on the session's host Mac, so this shows an explanatory banner
    /// instead of attempting a resolve round trip or a preview. Cleared at the start of the next link
    /// open attempt and on stop/auth-failure resets, alongside `linkPreviewErrorMessage`.
    var linkNotice: String?

    /// Rich-composer draft. The draft text is a two-way binding for the composer's text field; the
    /// attachments and sending/error flags are mutated only through the composer API below. The draft
    /// survives the composer sheet being dismissed and reopened because the model outlives the sheet
    /// (it is `@State` on the detail view), so a partially composed message is not lost on dismiss.
    var composerDraftText = ""
    private(set) var composerAttachments: [TerminalComposerAttachment] = []
    private(set) var isSendingComposedMessage = false
    var composerErrorMessage: String?
    private var linkPreviewRequestGeneration: UInt64 = 0
    @ObservationIgnored private var externalLinkPreviewDownloadTask: Task<URL, Error>?
    @ObservationIgnored private var localLinkPreviewDownloadTask: Task<Int64, Error>?

    private let bridgeClient: SpacesDeviceAPIClient
    private var commandChannel: SpacesDeviceAPICommandChannel
    @ObservationIgnored private let remoteMediaDownloader: @Sendable (URL, SpacesDeviceTerminalLinkArtifactKind) async throws -> URL
    @ObservationIgnored private let linkPreviewCacheDirectory: URL
    private var remoteClient: TerminalClient
    private var e2eConfig: SpacesMobileE2EConfig { .shared }
    private var streamHandle: SpacesDeviceAPIStreamHandle?
    private var reconnectTask: Task<Void, Never>?
    private var bufferedInputText = ""
    private var bufferedInputFlushTask: Task<Void, Never>?
    private let inputSendQueue = TerminalInputSerialQueue()
    private var ownershipSynchronizationTask: Task<Void, Never>?
    private var viewportSize: (columns: Int, rows: Int)?
    private var lastSentResizeSize: (columns: Int, rows: Int)?
    private var resizeSerial: UInt64 = 0
    private var needsOwnershipSynchronizationAfterCurrentRun = false
    private var isAwaitingTakeoverConfirmation = false {
        didSet {
            guard isAwaitingTakeoverConfirmation != oldValue else { return }
            trace("awaiting_takeover_confirmation value=\(isAwaitingTakeoverConfirmation ? 1 : 0)")
        }
    }
    private var isStopping = false
    private var hasSentStopDetach = false
    private var hasAttachedToSession = false
    /// The light/dark appearance the session currently carries — set from the value sent on attach and on
    /// each live push. `sendAppearance` dedupes against it so an unchanged app appearance costs no request;
    /// the daemon would no-op a same-value setAppearance anyway, but skipping it avoids the round-trip.
    private var lastAppearanceSentToSession: ThemeAppearance?
    private var hasAttemptedAutomaticTakeover = false
    private var hasConfirmedOwnerInputReadiness = false
    private var ownerRecoveryGraceDeadline: Date?
    private var ownerRenderEpochState: GhosttyRemoteTerminalOwnerEpoch?
    /// Reduces incoming payloads off the main actor, in arrival order across every route into this
    /// model: the live subscription, the direct `.state` fetch, and the state a takeover returns. It
    /// owns the reducer, so the render-update baseline and the previous stored payload the next reduce
    /// chains from live there rather than here, and this model only applies what it hands back.
    ///
    /// One instance for the model's whole life, including across `beginStop()`/`start()`: the chain it
    /// holds describes the same session either way, and a reconnect's `initial`/`.state` full frame
    /// reseeds the baseline. `applyReducedState` is what makes a stopped model's pending applies inert.
    @ObservationIgnored private lazy var statePipeline = TerminalRemoteStateReductionPipeline(
        // Every materialized frame is rendered. The mac mirror gates frames against the surface it is
        // resizing underneath; this viewer has no such local surface race — it renders whatever grid the
        // daemon exports and re-measures its own viewport from the frame that arrives.
        shouldUseFrame: { _, _ in true }, apply: { [weak self] output in self?.applyReducedState(output) })
    /// Payloads handed to the pipeline, and how many of those the main actor has accounted for. The
    /// apply mailbox collapses runs of consecutive frames, so one apply stands for itself plus every
    /// submission it superseded; counting that way is what lets `applyLatestState` wait on a payload
    /// that may never apply under its own name. Unobserved on purpose: they change on every payload and
    /// nothing on screen reads them, so observing them would rebuild the terminal's body at the
    /// session's flush rate.
    @ObservationIgnored private var submittedStateCount: UInt64 = 0
    @ObservationIgnored private var appliedStateCount: UInt64 = 0
    @ObservationIgnored private var stateApplyWaiters: [(target: UInt64, continuation: CheckedContinuation<Void, Never>)] = []
    private var reportedOwnerReadyEpochID: String?
    private var reportedOwnerNonblankEpochID: String?
    private var hasRetriedEndedStateAfterStreamClose = false
    @ObservationIgnored private lazy var scrollCoalescer = TerminalScrollCoalescer(frameInterval: Self.scrollCoalescingInterval) {
        [weak self] batch, finish in
        guard let self else {
            finish()
            return
        }
        self.enqueueCoalescedScrollBatch(batch, onFinished: finish)
    }

    private static let inputBatchDelay: Duration = .milliseconds(35)
    private static let scrollCoalescingInterval: Duration = .milliseconds(16)
    private static let inputRequestTimeout: Duration = .seconds(6)
    /// Pasting a multi-MiB image takes meaningfully longer to transmit than interactive text/key input,
    /// so composer image steps use a larger timeout than `inputRequestTimeout`.
    private static let pasteImageRequestTimeout: Duration = .seconds(30)
    private static let stateRequestTimeout: Duration = .seconds(12)
    private static let ownerRecoveryGraceInterval: TimeInterval = 2
    private static let silentReconnectDelay: Duration = .milliseconds(150)
    private static let viewportSyncWaitStep: Duration = .milliseconds(50)
    private static let viewportSyncWaitIterations = 8
    private static let ownershipSyncDebounce: Duration = .milliseconds(120)
    private static let postResizeStateSettleStep: Duration = .milliseconds(50)
    private static let postResizeStateSettleIterations = 6
    private static let dismissalDetachTimeout: Duration = .seconds(3)
    /// Text-family previews (text/markdown/html) download the whole file into memory-adjacent local
    /// storage before rendering, unlike image/video/PDF which QuickLook streams from disk; this caps
    /// that download so an oversized log file can't stall the preview or balloon device storage.
    private static let textPreviewByteCountLimit: Int64 = 4 * 1024 * 1024
    private static let loopbackLinkNoticeMessage = "This address runs on the session's host machine and isn't reachable from this device yet."

    /// Which step of the composed-send burst (see `enqueueComposedInputSend`) a failure occurred in, so
    /// `finishComposedSend` can surface a message that matches what actually happened rather than always
    /// describing an image failure.
    private enum ComposedSendStep {
        case text
        case image
        case enter
    }

    init(
        session: SpacesDeviceTerminalSessionSummary, settings: SpacesMobileConnectionSettings,
        onAuthenticationRequired: @escaping @MainActor @Sendable (String) -> Void,
        onOpenTerminalDeepLink: @escaping @MainActor @Sendable (SpacesTerminalDeepLink) -> Void, bridgeClient: SpacesDeviceAPIClient? = nil,
        isDemoMode: Bool = false,
        remoteMediaDownloader: @escaping @Sendable (URL, SpacesDeviceTerminalLinkArtifactKind) async throws -> URL = TerminalViewerModel
            .defaultRemoteMediaDownloader, linkPreviewCacheDirectory: URL? = nil
    ) {
        self.session = session
        self.settings = settings
        self.isDemoMode = isDemoMode
        self.onAuthenticationRequired = onAuthenticationRequired
        self.onOpenTerminalDeepLink = onOpenTerminalDeepLink
        let resolvedBridgeClient = bridgeClient ?? SpacesDeviceAPIClient(settings: settings, deviceName: UIDevice.current.name)
        self.bridgeClient = resolvedBridgeClient
        commandChannel = resolvedBridgeClient.makeCommandChannel()
        self.remoteMediaDownloader = remoteMediaDownloader
        self.linkPreviewCacheDirectory =
            linkPreviewCacheDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("SpacesTerminalLinkPreviews", isDirectory: true)
        remoteClient = Self.makeRemoteClient(settings: settings)
    }

    private static func makeRemoteClient(settings: SpacesMobileConnectionSettings) -> TerminalClient {
        TerminalClient(
            kind: .remoteViewer,
            identity: TerminalClientIdentity(
                label: UIDevice.current.name, hostName: nil, deviceName: UIDevice.current.name, networkAddress: settings.primaryHost),
            connectedAt: ISO8601DateFormatter().string(from: Date()))
    }

    nonisolated static func defaultRemoteMediaDownloader(_ url: URL, expectedArtifactKind: SpacesDeviceTerminalLinkArtifactKind) async throws -> URL {
        let (downloadedURL, response) = try await URLSession.shared.download(from: url)
        do {
            return try validatedRemoteMediaDownloadURL(downloadedURL, response: response, expectedArtifactKind: expectedArtifactKind, sourceURL: url)
        } catch {
            try? FileManager.default.removeItem(at: downloadedURL)
            throw error
        }
    }

    /// Validates that a downloaded external link actually returned the artifact kind the daemon's resolve
    /// step promised, rather than merely returning some previewable kind. Without this, a URL that
    /// resolved as (say) `.image` but that actually redirects to an HTML sign-in page would pass a looser
    /// "is this any previewable kind" check — text/HTML is itself a previewable kind now that the
    /// classifier covers documents, not just media — and get cached and shown as if it were the image.
    /// If the server reports a generic or plain-text type, the resolved/final URL extension is allowed
    /// to confirm the promised artifact kind; a conflicting specific type such as an HTML sign-in page
    /// still fails before caching.
    nonisolated static func validatedRemoteMediaDownloadURL(
        _ downloadedURL: URL, response: URLResponse, expectedArtifactKind: SpacesDeviceTerminalLinkArtifactKind, sourceURL: URL? = nil
    ) throws -> URL {
        guard response.url?.scheme?.lowercased() == "https" else {
            throw SpacesDeviceAPIClientError.requestFailed("The media link redirected to a non-HTTPS URL.")
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpacesDeviceAPIClientError.requestFailed("The media link did not return an HTTP response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SpacesDeviceAPIClientError.requestFailed("The media link returned HTTP status \(httpResponse.statusCode).")
        }
        let mimeType = httpResponse.mimeType?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            downloadedArtifactKindMatches(
                contentType: mimeType?.isEmpty == false ? mimeType : nil, responseURL: response.url, sourceURL: sourceURL,
                expectedArtifactKind: expectedArtifactKind)
        else { throw SpacesDeviceAPIClientError.requestFailed("The media link did not return \(expectedArtifactKind.previewNoun) content.") }
        return downloadedURL
    }

    private nonisolated static func downloadedArtifactKindMatches(
        contentType: String?, responseURL: URL?, sourceURL: URL?, expectedArtifactKind: SpacesDeviceTerminalLinkArtifactKind
    ) -> Bool {
        let responseKind = contentType.flatMap { SpacesDeviceTerminalLinkClassifier.artifactKind(contentType: $0, pathExtension: nil) }
        if responseKind == expectedArtifactKind { return true }
        guard resolvedExtensionMatchesExpectedArtifactKind(responseURL: responseURL, sourceURL: sourceURL, expectedArtifactKind: expectedArtifactKind)
        else { return false }
        guard let responseKind else { return contentType.map(isGenericDownloadContentType) ?? true }
        return responseKind == .text && Self.isTextFamilyArtifact(expectedArtifactKind)
    }

    private nonisolated static func isGenericDownloadContentType(_ contentType: String) -> Bool {
        let lowercased = contentType.lowercased()
        let baseType = lowercased.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? lowercased
        switch baseType.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "application/octet-stream", "binary/octet-stream", "application/x-download", "application/force-download": return true
        default: return false
        }
    }

    private nonisolated static func resolvedExtensionMatchesExpectedArtifactKind(
        responseURL: URL?, sourceURL: URL?, expectedArtifactKind: SpacesDeviceTerminalLinkArtifactKind
    ) -> Bool {
        [responseURL, sourceURL].contains { url in
            guard let url else { return false }
            return SpacesDeviceTerminalLinkClassifier.artifactKind(contentType: nil, pathExtension: url.pathExtension) == expectedArtifactKind
        }
    }

    var title: String { latestState?.title ?? session.title }
    var renderMode: String { renderModeValue.rawValue }
    var ownerRenderEpoch: GhosttyRemoteTerminalOwnerEpoch? { ownerRenderEpochState }
    var endedRender: GhosttyRemoteTerminalEndedRender? {
        guard shouldRenderEndedTerminalSurface, let snapshot = latestState?.renderSnapshot else { return nil }
        return GhosttyRemoteTerminalEndedRender(id: endedRenderID(for: snapshot), snapshot: snapshot)
    }
    var latestScreenStateRevision: UInt64? { latestState?.screenStateRevision }
    var snapshotText: String? { latestState?.renderText }
    var renderStateKey: String {
        if let ownerRenderEpochState { return "owner|\(ownerRenderEpochState.id)" }
        if let endedRender { return "ended|\(endedRender.id)" }
        return "status"
    }
    var showsTerminalSurface: Bool { isOwner || ownerRenderEpochState != nil || endedRender != nil }
    var shouldPresentLiveSurface: Bool { showsTerminalSurface }
    var visibleText: String {
        if shouldRenderEndedTerminalSurface, let snapshotText = latestState?.renderText { return snapshotText }
        if isSessionUnavailable { return "This terminal session is no longer available.\nReturn to Terminals to open the current live session." }
        if renderModeValue == .ended { return "This terminal session ended before a final render was available." }
        if renderModeValue == .ownerBootstrapping { return "Preparing terminal…" }
        if isStartingState { return "Preparing terminal…" }
        if isTakingOver { return "Attempting takeover…" }
        let ownerLabel = activeOwnerDisplayLabel ?? "another client"
        return "Live terminal rendering is limited to the active owner.\nCurrent owner: \(ownerLabel)"
    }
    var attachmentSnapshot: TerminalSessionAttachmentSnapshot { latestState?.attachmentSnapshot ?? session.attachmentSnapshot }
    var isOwner: Bool { !isEndedState && activeOwnerClientID == remoteClient.id }
    var isOwnershipSynchronizationPending: Bool { isOwnershipSynchronizationScheduled || isSynchronizingOwnership }
    var phase: TerminalViewerPhase {
        if isSessionUnavailable { return .unavailable }
        if isEndedState { return .ended }
        if isConnecting { return .connecting(owner: isOwner) }
        if isOwner {
            if isBusy { return .ownerBusy }
            if isOwnershipSynchronizationPending { return .ownerSynchronizing }
            return .ownerInteractive
        }
        if isStartingState { return .starting }
        if isAwaitingTakeoverConfirmation || isBusy || isOwnershipSynchronizationPending { return .takingOver }
        return .viewingOtherOwner
    }
    var isTakingOver: Bool { phase == .takingOver }
    var acceptsInput: Bool { phase == .ownerInteractive }
    var keepsTerminalInputSurfaceActive: Bool {
        switch phase {
        case .ownerInteractive, .ownerBusy, .ownerSynchronizing: true
        case .unavailable, .ended, .starting, .connecting, .takingOver, .viewingOtherOwner: false
        }
    }
    var showsTakeOverAction: Bool { !isDemoMode && phase == .viewingOtherOwner }
    var isPreparingInput: Bool {
        switch phase {
        case .connecting(owner: true), .ownerBusy: return true
        case .ownerInteractive, .ownerSynchronizing: return ownerRenderEpochState == nil || !isInputSurfaceReady
        case .unavailable, .ended, .starting, .connecting(owner: false), .takingOver, .viewingOtherOwner: return false
        }
    }
    var viewportColumns: Int? { viewportSize?.columns }
    var viewportRows: Int? { viewportSize?.rows }
    var lastSentResizeColumns: Int? { lastSentResizeSize?.columns }
    var lastSentResizeRows: Int? { lastSentResizeSize?.rows }
    var runtimeColumns: Int? { latestState?.runtimeState?.columns }
    var runtimeRows: Int? { latestState?.runtimeState?.rows }
    var snapshotColumns: Int? { latestState?.renderSnapshot?.columns }
    var snapshotRows: Int? { latestState?.renderSnapshot?.rows }

    func start() {
        guard streamHandle == nil, reconnectTask == nil else { return }
        if hasSentStopDetach {
            // A retained navigation destination can disappear with its tab and later reappear. Give
            // that new lifecycle its own channel and client identity so the prior stop task cannot
            // close or detach the new stream.
            commandChannel = bridgeClient.makeCommandChannel()
            remoteClient = Self.makeRemoteClient(settings: settings)
            hasSentStopDetach = false
        }
        isStopping = false
        isSessionUnavailable = false
        hasAttemptedAutomaticTakeover = false
        hasRetriedEndedStateAfterStreamClose = false
        trace("start")
        if isEndedState {
            reconnectTask = Task { [weak self] in await self?.loadEndedState() }
            return
        }
        scheduleReconnect(after: .zero)
    }

    func stop() {
        guard let stopContext = beginStop() else { return }
        trace("stop")
        Task { await detachForStop(using: stopContext.channel, shouldDetach: stopContext.shouldDetach, timeout: Self.dismissalDetachTimeout) }
    }

    func prepareForBackNavigation() async {
        guard let stopContext = beginStop() else { return }
        trace("back_detach_begin")
        await detachForStop(using: stopContext.channel, shouldDetach: stopContext.shouldDetach, timeout: Self.dismissalDetachTimeout)
        trace("back_detach_end")
    }

    private func beginStop() -> (channel: SpacesDeviceAPICommandChannel, shouldDetach: Bool)? {
        guard !hasSentStopDetach else { return nil }
        hasSentStopDetach = true
        let shouldDetach = hasAttachedToSession && !isEndedState
        isStopping = true
        isAwaitingTakeoverConfirmation = false
        hasAttachedToSession = false
        hasAttemptedAutomaticTakeover = false
        hasConfirmedOwnerInputReadiness = false
        isInputSurfaceReady = false
        reconnectTask?.cancel()
        reconnectTask = nil
        streamHandle?.cancel()
        streamHandle = nil
        bufferedInputFlushTask?.cancel()
        bufferedInputFlushTask = nil
        scrollCoalescer.cancel()
        cancelQueuedInputSends()
        ownershipSynchronizationTask?.cancel()
        ownershipSynchronizationTask = nil
        bufferedInputText = ""
        viewportSize = nil
        lastSentResizeSize = nil
        resizeSerial = 0
        needsOwnershipSynchronizationAfterCurrentRun = false
        ownerRenderEpochState = nil
        invalidateLinkPreviewRequests()
        isPreparingLinkPreview = false
        linkPreviewErrorMessage = nil
        linkPreview = nil
        linkNotice = nil
        ownerRecoveryGraceDeadline = nil
        reportedOwnerReadyEpochID = nil
        reportedOwnerNonblankEpochID = nil
        hasRetriedEndedStateAfterStreamClose = false
        isOwnershipSynchronizationScheduled = false
        isSynchronizingOwnership = false
        return (commandChannel, shouldDetach)
    }

    private func detachForStop(using currentChannel: SpacesDeviceAPICommandChannel, shouldDetach: Bool, timeout: Duration) async {
        if shouldDetach {
            do {
                try await detachTerminal(timeout: timeout, commandChannel: currentChannel)
                trace("detach_success")
            } catch { trace("detach_failure error=\(sanitizedTraceDetail(error.localizedDescription))") }
        }
        await currentChannel.close()
    }

    private func detachTerminal(timeout: Duration, commandChannel: SpacesDeviceAPICommandChannel) async throws {
        try await bridgeClient.detach(sessionID: session.id, clientID: remoteClient.id, timeout: timeout, commandChannel: commandChannel)
    }

    private func loadEndedState() async {
        isConnecting = true
        defer {
            isConnecting = false
            reconnectTask = nil
        }
        trace("ended_state_load")
        _ = await refreshLatestState(timeout: Self.stateRequestTimeout, ignoreTransientTimeout: false, reason: "ended_initial")
    }

    private var renderModeValue: TerminalViewerRenderMode {
        if isEndedState { return .ended }
        if isOwner { return hasConfirmedOwnerInputReadiness && ownerRenderEpochState != nil ? .ownerLive : .ownerBootstrapping }
        return .status
    }

    func takeOver() async {
        // Demo Mode is view-only; the backend rejects takeover, so never enter the input path.
        guard !isDemoMode else { return }
        guard !isEndedState else { return }
        guard !isBusy else { return }
        hasAttemptedAutomaticTakeover = true
        isBusy = true
        hasConfirmedOwnerInputReadiness = false
        isInputSurfaceReady = false
        isAwaitingTakeoverConfirmation = true
        defer { isBusy = false }
        trace("takeover_begin")
        do {
            let takeoverState = try await takeOverTerminal(timeout: Self.inputRequestTimeout)
            // This await sits behind the reduction pipeline's strict FIFO: whatever the live subscription
            // already submitted ahead of this response reduces first, and only then does the takeover
            // response reduce and apply. That is accepted rather than worked around: reduction is off the
            // main actor and keeps up with a single subscription's flush rate, so the backlog it can be
            // behind is small and draining, and the alternative — jumping this response to the front of the
            // queue — would apply it against a reduction chain that has not yet seen everything submitted
            // before it, corrupting the delta baseline the chain depends on staying in submission order.
            // `isBusy` and `isAwaitingTakeoverConfirmation` are held across the wait by design, so the UI
            // stays in its "taking over" state for the whole ride rather than settling early on stale state.
            if let takeoverState { await applyLatestState(takeoverState) }
            if !isOwner { await refreshLatestState(timeout: Self.inputRequestTimeout, ignoreTransientTimeout: true, reason: "takeover_confirmation") }
            errorMessage = nil
            if !isOwner {
                isAwaitingTakeoverConfirmation = false
                trace("takeover_unconfirmed")
                return
            }
            isAwaitingTakeoverConfirmation = false
            trace("takeover_success state=\(takeoverState == nil ? 0 : 1) owner=\(isOwner ? 1 : 0)")
        } catch {
            isAwaitingTakeoverConfirmation = false
            if Self.isTransientReconnectError(error) {
                trace("takeover_transient_failure error=\(sanitizedTraceDetail(error.localizedDescription))")
                errorMessage = nil
                return
            }
            if handleAuthenticationFailure(error) { return }
            trace("takeover_failure error=\(sanitizedTraceDetail(error.localizedDescription))")
            errorMessage = error.localizedDescription
        }
    }

    private func takeOverTerminal(timeout: Duration) async throws -> GhosttyRemoteSessionStatePayload? {
        let takeoverState = try await bridgeClient.takeOver(sessionID: session.id, clientID: remoteClient.id, timeout: timeout)
        replaceCommandChannel()
        return takeoverState
    }

    func updateViewportSize(columns: Int, rows: Int) {
        let resolved = (columns: max(columns, 1), rows: max(rows, 1))
        guard viewportSize?.columns != resolved.columns || viewportSize?.rows != resolved.rows else { return }
        if isDemoMode {
            // Demo Mode never takes ownership, so the owner resize handshake below never runs and the
            // in-memory backend would only ever serve its smallest (phone) recording. Report the viewport
            // to the backend and refresh so it serves the recording captured nearest this size. Applies
            // regardless of run state: the read-only recorded surface reports its viewport once mounted.
            viewportSize = resolved
            Task { [weak self] in await self?.applyDemoViewportResize(columns: resolved.columns, rows: resolved.rows) }
            return
        }
        guard !isEndedState else { return }
        viewportSize = resolved
        trace(
            "viewport_update columns=\(resolved.columns) rows=\(resolved.rows) owner=\(isOwner ? 1 : 0) busy=\(isBusy ? 1 : 0) syncing=\(isSynchronizingOwnership ? 1 : 0) sync_scheduled=\(isOwnershipSynchronizationScheduled ? 1 : 0)"
        )
        if isOwner && !isBusy {
            if isSynchronizingOwnership {
                needsOwnershipSynchronizationAfterCurrentRun = true
                trace("ownership_sync_reschedule_after_current")
            } else {
                scheduleOwnershipSynchronization()
            }
        }
    }

    /// Tells the demo backend the current viewport and refreshes so it swaps in the recording captured
    /// nearest this size. The demo backend ignores the epoch/serial and just records the requested grid,
    /// so the available (nil) owner state is fine to pass. A full-frame recording always replaces the
    /// prior frame in the state reducer, so the refreshed grid's frame renders without any revision
    /// bookkeeping.
    private func applyDemoViewportResize(columns: Int, rows: Int) async {
        do {
            try await bridgeClient.resize(
                sessionID: session.id, clientID: remoteClient.id, columns: columns, rows: rows, ownerEpoch: currentOwnerEpoch, resizeSerial: nil,
                timeout: Self.stateRequestTimeout)
        } catch {
            // A demo resize only records the viewport in memory; a failure leaves the current frame in
            // place, so there is nothing to recover.
            trace("demo_viewport_resize_failure error=\(sanitizedTraceDetail(error.localizedDescription))")
        }
        await refreshLatestState(timeout: Self.stateRequestTimeout, ignoreTransientTimeout: true, reason: "demo_viewport_resize")
    }

    func sendText(_ text: String, appendNewline: Bool = false, asPaste: Bool = false) async {
        guard isOwner else { return }
        guard acceptsInput, hasConfirmedOwnerInputReadiness else { return }
        guard !text.isEmpty else { return }
        flushPendingScroll()
        if appendNewline {
            flushBufferedInputText()
            enqueueInputSend(kind: "send_text", detail: "\(text)\\n") { [weak self, text] in
                guard let self else { return }
                try await self.performSendTextRequest(text, appendNewline: true, asPaste: asPaste)
            }
            return
        }
        if asPaste {
            flushBufferedInputText()
            enqueueInputSend(kind: "send_text", detail: text) { [weak self, text] in
                guard let self else { return }
                try await self.performSendTextRequest(text, asPaste: true)
            }
            return
        }
        bufferInputText(text)
    }

    func sendKey(_ key: String) async {
        guard isOwner else { return }
        guard acceptsInput, hasConfirmedOwnerInputReadiness else { return }
        flushPendingScroll()
        flushBufferedInputText()
        enqueueInputSend(kind: "send_key", detail: key) { [weak self, key] in
            guard let self else { return }
            try await self.performSendKeyRequest(key)
        }
    }

    func attachComposerImage(_ attachment: TerminalComposerAttachment) {
        guard !isSendingComposedMessage else { return }
        composerAttachments.append(attachment)
        composerErrorMessage = nil
    }

    /// Stages a clipboard image in the composer: a valid image becomes an attachment, a rejected one
    /// surfaces its reason. Returns whether the clipboard actually held an image, so a caller that pastes
    /// text otherwise (the composer's own paste, the terminal's paste routes) can fall through.
    func pasteClipboardImageIntoComposer(from pasteboard: UIPasteboard = .general) -> Bool {
        switch TerminalUIPasteboardImageReader.readImage(from: pasteboard) {
        case .image(let attachment):
            attachComposerImage(attachment)
            return true
        case .rejected(let message):
            composerErrorMessage = message
            return true
        case .noImage: return false
        }
    }

    func removeComposerAttachment(id: UUID) {
        guard !isSendingComposedMessage else { return }
        composerAttachments.removeAll { $0.id == id }
    }

    /// The composer can send when the session accepts owner input (same gating as typing) and the draft
    /// has content — either non-whitespace text or at least one attachment — and no send is in flight.
    var canSendComposedMessage: Bool {
        guard acceptsInput, hasConfirmedOwnerInputReadiness, !isSendingComposedMessage else { return false }
        let hasText = !composerDraftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || !composerAttachments.isEmpty
    }

    /// Sends the composed message as a single ordered burst: the typed text, then each image, then Enter.
    /// The whole sequence runs inside one serial-queue closure so it stays ordered relative to any other
    /// input and never interleaves. Enter is only sent after every prior step succeeds, so a partial
    /// failure leaves the draft intact and nothing is submitted.
    func sendComposedMessage() async {
        guard canSendComposedMessage, isOwner else { return }
        flushPendingScroll()
        flushBufferedInputText()
        let draftText = composerDraftText
        // Capture only the Sendable payloads (not the attachments, whose UIImage thumbnails are not
        // Sendable) for the detached serial-queue closure.
        let attachments = composerAttachments
        let payloads = attachments.map(\.payload)
        let attachmentIDs = attachments.map(\.id)
        isSendingComposedMessage = true
        composerErrorMessage = nil
        enqueueComposedInputSend(text: draftText, payloads: payloads, attachmentIDs: attachmentIDs)
    }

    private func enqueueComposedInputSend(text: String, payloads: [TerminalImageAttachmentPayload], attachmentIDs: [UUID]) {
        let detail = "text_bytes=\(text.utf8.count) attachments=\(payloads.count)"
        logPerformanceEvent(
            name: "input_command_enqueue", count: detail.utf8.count, attributes: inputCommandAttributes(kind: "composer_send", detail: detail))
        // A dedicated enqueue (rather than the generic `enqueueInputSend`) because the composer owns its
        // own completion: a partial failure must surface via `composerErrorMessage` and preserve the draft
        // rather than the generic `errorMessage` path, and success must clear the draft — while still
        // sharing `inputSendQueue` so it stays ordered with any buffered text/keys.
        inputSendQueue.enqueue(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            if Task.isCancelled {
                await MainActor.run { self.finishCanceledComposedSend() }
                return
            }
            await MainActor.run { self.writeE2EEventIfNeeded(kind: "composer_send_begin", detail: detail) }
            let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // Ordering rationale: text first, then image paths, then Enter. Trailing paths read as
            // arguments to the typed text, and the risky large upload happens after the cheap text
            // send. A separator space follows the text (when images follow) and separates images.
            if hasText {
                do { try await self.performSendTextRequest(text + (payloads.isEmpty ? "" : " "), asPaste: true) } catch {
                    await MainActor.run { self.finishComposedSend(with: error, failedStep: .text) }
                    return
                }
            }
            for (index, payload) in payloads.enumerated() {
                if index > 0 {
                    do { try await self.performSendTextRequest(" ", asPaste: true) } catch {
                        await MainActor.run { self.finishComposedSend(with: error, failedStep: .image) }
                        return
                    }
                }
                do { try await self.performPasteImageRequest(payload) } catch {
                    await MainActor.run { self.finishComposedSend(with: error, failedStep: .image) }
                    return
                }
            }
            do { try await self.performSendKeyRequest("enter") } catch {
                await MainActor.run { self.finishComposedSend(with: error, failedStep: .enter) }
                return
            }
            await MainActor.run { self.finishComposedSend(with: nil, sentDraftText: text, sentAttachmentIDs: attachmentIDs) }
        }
    }

    private func finishComposedSend(
        with error: Error?, failedStep: ComposedSendStep? = nil, sentDraftText: String? = nil, sentAttachmentIDs: [UUID] = []
    ) {
        isSendingComposedMessage = false
        guard let error else {
            writeE2EEventIfNeeded(kind: "composer_send_success", detail: nil)
            if composerDraftText == sentDraftText { composerDraftText = "" }
            let sentAttachmentIDs = Set(sentAttachmentIDs)
            composerAttachments.removeAll { sentAttachmentIDs.contains($0.id) }
            composerErrorMessage = nil
            if isOwner {
                hasConfirmedOwnerInputReadiness = true
                isInputSurfaceReady = true
            }
            return
        }
        writeE2EEventIfNeeded(kind: "composer_send_failure", detail: error.localizedDescription)
        // Keep the entire draft (text + all attachments) so the user can retry without recomposing.
        if routeInputSendRecovery(error) {
            composerErrorMessage = nil
            return
        }
        switch failedStep {
        case .text: composerErrorMessage = "Couldn't send the message. Nothing was submitted."
        case .enter: composerErrorMessage = "The message was sent but couldn't be submitted. Retrying will send the whole message again."
        case .image, nil: composerErrorMessage = "Couldn't send an image. Nothing was submitted — the terminal line may contain partial text."
        }
    }

    private func finishCanceledComposedSend() {
        guard isSendingComposedMessage else { return }
        isSendingComposedMessage = false
        composerErrorMessage = nil
    }

    private func cancelQueuedInputSends() {
        inputSendQueue.cancelAll()
        finishCanceledComposedSend()
    }

    private func performPasteImageRequest(_ payload: TerminalImageAttachmentPayload) async throws {
        // Carries the current owner epoch when there is one and none when there is not, like every other
        // input this viewer sends: an absent epoch means the paste is not epoch-gated, not that the
        // terminal is unready.
        let ownerEpoch = currentOwnerEpoch
        try await performRequestUsingInputChannel {
            [bridgeClient, sessionID = session.id, clientID = remoteClient.id, ownerEpoch, payload] commandChannel in
            try await bridgeClient.pasteImage(
                sessionID: sessionID, clientID: clientID, ownerEpoch: ownerEpoch, fileExtension: payload.fileExtension, imageData: payload.imageData,
                timeout: Self.pasteImageRequestTimeout, commandChannel: commandChannel)
        }
    }

    /// Pushes the app's effective light/dark appearance to the live session so the daemon re-themes it
    /// while the terminal is open. Called when the resolved appearance changes (a mode flip, or an OS trait
    /// change while the mode follows the system). Not owner-gated: appearance is a per-client view
    /// preference, and last-writer-wins across clients is the accepted semantic. Best-effort — a failed
    /// re-theme leaves the session on its prior appearance until the next attach or appearance change.
    func sendAppearance(_ appearance: ThemeAppearance) async {
        guard appearance != lastAppearanceSentToSession else { return }
        lastAppearanceSentToSession = appearance
        trace("send_appearance value=\(appearance == .dark ? "dark" : "light")")
        do { try await bridgeClient.setAppearance(sessionID: session.id, clientID: remoteClient.id, appearance: appearance) } catch {
            trace("send_appearance_failure error=\(sanitizedTraceDetail(error.localizedDescription))")
        }
    }

    func sendScroll(horizontal: Double, vertical: Double, scrollMods: Int32 = 0, pointerPosition: TerminalScrollPointerPosition? = nil) async {
        guard isOwner else { return }
        guard keepsTerminalInputSurfaceActive else { return }
        flushBufferedInputText()
        scrollCoalescer.append(horizontal: horizontal, vertical: vertical, scrollMods: scrollMods, pointerPosition: pointerPosition)
    }

    func flushPendingScroll() { scrollCoalescer.flush() }

    /// Sends one button press or release. Deliberately not coalesced the way scroll is: a click is a
    /// discrete event whose press/release ordering the application depends on, so it flushes any
    /// pending scroll batch first and rides the same input queue as a key send.
    // Synchronous (no async hop) so a tap's press and release enqueue in call order: the serial
    // input queue preserves enqueue order, but two Tasks racing to enqueue would not.
    func sendMouseButton(button: UInt8, pressed: Bool, pointerPosition: TerminalScrollPointerPosition?) {
        guard isOwner else { return }
        guard keepsTerminalInputSurfaceActive else { return }
        flushPendingScroll()
        flushBufferedInputText()
        enqueueInputSend(kind: "send_mouse_button", detail: "\(button),\(pressed)") { [weak self, button, pressed, pointerPosition] in
            guard let self else { return }
            try await self.performSendMouseButtonRequest(button: button, pressed: pressed, pointerPosition: pointerPosition)
        }
    }

    func dismissLinkPreview() {
        invalidateLinkPreviewRequests()
        isPreparingLinkPreview = false
        linkPreviewErrorMessage = nil
        linkPreview = nil
    }

    func openTerminalLink(_ link: String) async {
        let normalizedLink = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLink.isEmpty else { return }
        // Route on the raw link text before touching the daemon: an unrecognized scheme (e.g.
        // `mailto:`) needs no round trip at all, and a loopback host (e.g. `http://localhost:3000`)
        // only makes sense on the session's host Mac, so both short-circuit without a resolve call or
        // preview sheet. `.webURL` and `.fileLink` still go through `resolveTerminalLink` below because
        // the daemon may classify an https URL as a previewable artifact (image/pdf/markdown/etc.)
        // rather than a plain web page.
        guard let route = SpacesDeviceTerminalLinkClassifier.route(for: normalizedLink) else {
            cancelAndClearLinkPreviewState()
            linkNotice = nil
            return
        }
        if case .loopbackURL = route {
            cancelAndClearLinkPreviewState()
            linkNotice = Self.loopbackLinkNoticeMessage
            return
        }
        if case .spacesTerminal(let deepLink) = route {
            // A spaces://terminal/… link tapped inside the terminal is an in-app navigation, not an
            // external artifact: focus the linked session through the same navigator RootTabView uses
            // for these links, instead of round-tripping to the daemon resolver (which rejects the scheme).
            cancelAndClearLinkPreviewState()
            linkNotice = nil
            onOpenTerminalDeepLink(deepLink)
            return
        }
        linkNotice = nil

        let requestGeneration = beginLinkPreviewRequest()
        isPreparingLinkPreview = true
        linkPreviewErrorMessage = nil
        defer { completeLinkPreviewRequest(requestGeneration) }

        do {
            let previewCommandChannel = bridgeClient.makeCommandChannel()
            defer { Task { await previewCommandChannel.close() } }
            let metadata = try await bridgeClient.resolveTerminalLink(
                sessionID: session.id, link: normalizedLink, commandChannel: previewCommandChannel)
            try Task.checkCancellation()
            try ensureCurrentLinkPreviewRequest(requestGeneration)
            try await handleResolvedTerminalLink(metadata, commandChannel: previewCommandChannel, requestGeneration: requestGeneration)
        } catch {
            if error is TerminalLinkPreviewRequestError { return }
            if Task.isCancelled { return }
            guard isCurrentLinkPreviewRequest(requestGeneration) else { return }
            if handleAuthenticationFailure(error) { return }
            guard linkPreview == nil else { return }
            linkPreviewErrorMessage = error.localizedDescription
        }
    }

    func recordRenderedText(_ text: String) {
        guard isOwner, let ownerRenderEpochState else { return }
        guard Self.hasVisibleRenderedContent(text) else { return }
        guard reportedOwnerNonblankEpochID != ownerRenderEpochState.id else { return }
        reportedOwnerNonblankEpochID = ownerRenderEpochState.id
        logPerformanceEvent(
            name: "owner_first_nonblank_render", count: text.utf8.count,
            attributes: ["epoch_id": ownerRenderEpochState.id, "render_mode": renderMode])
    }

    private func bufferInputText(_ text: String) {
        bufferedInputText.append(text)
        guard text.count != 1 else {
            flushBufferedInputText()
            return
        }
        bufferedInputFlushTask?.cancel()
        bufferedInputFlushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.inputBatchDelay)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.flushBufferedInputTextFromTask() }
        }
    }

    private func flushBufferedInputTextFromTask() {
        guard !bufferedInputText.isEmpty else { return }
        flushBufferedInputText()
    }

    private func flushBufferedInputText() {
        bufferedInputFlushTask?.cancel()
        bufferedInputFlushTask = nil
        let text = bufferedInputText
        bufferedInputText.removeAll(keepingCapacity: true)
        guard !text.isEmpty else { return }
        enqueueInputSend(kind: "send_text", detail: text) { [weak self, text] in
            guard let self else { return }
            try await self.performSendTextRequest(text)
        }
    }

    private func performSendTextRequest(_ text: String, appendNewline: Bool = false, asPaste: Bool = false) async throws {
        let ownerEpoch = currentOwnerEpoch
        try await performRequestUsingInputChannel {
            [bridgeClient, sessionID = session.id, clientID = remoteClient.id, ownerEpoch, appendNewline, asPaste] commandChannel in
            try await bridgeClient.sendText(
                sessionID: sessionID, clientID: clientID, text: text, ownerEpoch: ownerEpoch, appendNewline: appendNewline, asPaste: asPaste,
                timeout: Self.inputRequestTimeout, commandChannel: commandChannel)
        }
    }

    private func performSendKeyRequest(_ key: String) async throws {
        let ownerEpoch = currentOwnerEpoch
        if TerminalKeyInput.hostAction(for: key) == .clearScreenAndScrollback {
            try await performRequestUsingInputChannel {
                [bridgeClient, sessionID = session.id, clientID = remoteClient.id, ownerEpoch] commandChannel in
                try await bridgeClient.clearScreen(
                    sessionID: sessionID, clientID: clientID, ownerEpoch: ownerEpoch, timeout: Self.inputRequestTimeout,
                    commandChannel: commandChannel)
            }
            return
        }
        try await performRequestUsingInputChannel { [bridgeClient, sessionID = session.id, clientID = remoteClient.id, ownerEpoch] commandChannel in
            try await bridgeClient.sendKey(
                sessionID: sessionID, clientID: clientID, key: key, ownerEpoch: ownerEpoch, timeout: Self.inputRequestTimeout,
                commandChannel: commandChannel)
        }
    }

    private func performSendScrollRequest(horizontal: Double, vertical: Double, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition?)
        async throws
    {
        let ownerEpoch = currentOwnerEpoch
        try await performRequestUsingInputChannel { [bridgeClient, sessionID = session.id, clientID = remoteClient.id, ownerEpoch] commandChannel in
            try await bridgeClient.scroll(
                sessionID: sessionID, clientID: clientID, horizontal: horizontal, vertical: vertical, ownerEpoch: ownerEpoch,
                scrollMods: scrollMods == 0 ? nil : scrollMods, pointerPosition: pointerPosition, timeout: Self.inputRequestTimeout,
                commandChannel: commandChannel)
        }
    }

    private func performSendMouseButtonRequest(button: UInt8, pressed: Bool, pointerPosition: TerminalScrollPointerPosition?) async throws {
        let ownerEpoch = currentOwnerEpoch
        try await performRequestUsingInputChannel { [bridgeClient, sessionID = session.id, clientID = remoteClient.id, ownerEpoch] commandChannel in
            try await bridgeClient.mouseButton(
                sessionID: sessionID, clientID: clientID, button: button, pressed: pressed, ownerEpoch: ownerEpoch, pointerPosition: pointerPosition,
                timeout: Self.inputRequestTimeout, commandChannel: commandChannel)
        }
    }

    private func enqueueCoalescedScrollBatch(_ batch: TerminalScrollCoalescer.Batch, onFinished: @escaping TerminalScrollCoalescer.FinishHandler) {
        let detail = "\(batch.horizontal),\(batch.vertical)"
        enqueueInputSend(kind: "send_scroll", detail: detail) { [weak self, batch] in
            guard let self else {
                await MainActor.run { onFinished() }
                return
            }
            defer { Task { @MainActor in onFinished() } }
            try await self.performSendScrollRequest(
                horizontal: batch.horizontal, vertical: batch.vertical, scrollMods: batch.scrollMods, pointerPosition: batch.pointerPosition)
        }
    }

    private func performRequestUsingInputChannel(_ request: @escaping @Sendable (SpacesDeviceAPICommandChannel) async throws -> Void) async throws {
        do { try await request(commandChannel) } catch {
            guard Self.isTransientInputTransportError(error) else { throw error }
            replaceCommandChannel()
            try await Task.sleep(for: .milliseconds(120))
            try await request(commandChannel)
        }
    }

    private func enqueueInputSend(kind: String, detail: String, _ request: @escaping @Sendable () async throws -> Void) {
        let enqueuedAt = Date()
        logPerformanceEvent(name: "input_command_enqueue", count: detail.utf8.count, attributes: inputCommandAttributes(kind: kind, detail: detail))
        inputSendQueue.enqueue(priority: .userInitiated) { [weak self, enqueuedAt] in
            guard let self, !Task.isCancelled else { return }
            let rpcStartedAt = Date()
            do {
                await MainActor.run {
                    self.logPerformanceEvent(
                        name: "input_command_rpc_begin", elapsedMS: TerminalPerformance.elapsedMS(since: enqueuedAt), count: detail.utf8.count,
                        attributes: self.inputCommandAttributes(kind: kind, detail: detail))
                    self.writeE2EEventIfNeeded(kind: "\(kind)_begin", detail: detail)
                }
                try await request()
                let rpcMS = TerminalPerformance.elapsedMS(since: rpcStartedAt)
                await MainActor.run {
                    if self.isOwner {
                        self.hasConfirmedOwnerInputReadiness = true
                        self.isInputSurfaceReady = true
                    }
                    var attributes = self.inputCommandAttributes(kind: kind, detail: detail)
                    attributes["success"] = "1"
                    self.logPerformanceEvent(name: "input_command_rpc_end", elapsedMS: rpcMS, count: detail.utf8.count, attributes: attributes)
                    self.writeE2EEventIfNeeded(kind: "\(kind)_success", detail: detail)
                }
            } catch {
                let rpcMS = TerminalPerformance.elapsedMS(since: rpcStartedAt)
                await MainActor.run {
                    var attributes = self.inputCommandAttributes(kind: kind, detail: detail)
                    attributes["success"] = "0"
                    attributes["error"] = Self.sanitizedPerformanceDetail(error.localizedDescription)
                    self.logPerformanceEvent(name: "input_command_rpc_end", elapsedMS: rpcMS, count: detail.utf8.count, attributes: attributes)
                    self.writeE2EEventIfNeeded(kind: "\(kind)_failure", detail: "\(detail) :: \(error.localizedDescription)")
                    self.handleInputSendError(error)
                }
            }
        }
    }

    private func inputCommandAttributes(kind: String, detail: String) -> [String: String] {
        ["input_kind": kind, "input_bytes": String(detail.utf8.count)]
    }

    private func handleInputSendError(_ error: Error) {
        guard !Self.isTransientInputTransportError(error) else { return }
        if routeInputSendRecovery(error) { return }
        errorMessage = error.localizedDescription
    }

    private func routeInputSendRecovery(_ error: Error) -> Bool {
        if handleAuthenticationFailure(error) { return true }
        if Self.isTerminalNoLongerLiveError(error) {
            Task { [weak self] in await self?.recoverEndedStateAfterTerminalStopped(error, reason: "input_terminal_stopped") }
            return true
        }
        return false
    }

    private func handleResolvedTerminalLink(
        _ metadata: SpacesDeviceTerminalLinkMetadata, commandChannel: SpacesDeviceAPICommandChannel?, requestGeneration: UInt64
    ) async throws {
        try ensureCurrentLinkPreviewRequest(requestGeneration)
        switch metadata.source {
        case .externalURL:
            guard let externalURLValue = metadata.externalURL, let url = URL(string: externalURLValue) else {
                throw SpacesDeviceAPIClientError.requestFailed("The terminal link URL is invalid.")
            }
            guard let artifactKind = metadata.artifactKind else {
                // No previewable artifact kind: this is a plain web page, so it renders in-app rather
                // than handing off to Safari.
                try ensureCurrentLinkPreviewRequest(requestGeneration)
                linkPreviewErrorMessage = nil
                linkPreview = TerminalLinkPreview(id: metadata.id, title: metadata.displayName, kind: nil, content: .webPage(url))
                return
            }
            guard !exceedsTextPreviewSizeCap(artifactKind: artifactKind, metadata: metadata) else {
                linkPreviewErrorMessage = "\(metadata.displayName) is too large to preview on this device."
                return
            }
            let localURL = try await downloadExternalPreview(
                metadata: metadata, url: url, artifactKind: artifactKind, requestGeneration: requestGeneration)
            try ensureCurrentLinkPreviewRequest(requestGeneration)
            linkPreviewErrorMessage = nil
            linkPreview = TerminalLinkPreview(
                id: metadata.id, title: metadata.displayName, kind: artifactKind, content: Self.previewContent(for: artifactKind, fileURL: localURL))
        case .localFile:
            guard let artifactKind = metadata.artifactKind else {
                throw SpacesDeviceAPIClientError.requestFailed("Only image, video, PDF, Markdown, text, and HTML files can be previewed on iOS.")
            }
            guard !exceedsTextPreviewSizeCap(artifactKind: artifactKind, metadata: metadata) else {
                linkPreviewErrorMessage = "\(metadata.displayName) is too large to preview on this device."
                return
            }
            let localURL = try await downloadLocalPreview(metadata: metadata, commandChannel: commandChannel, requestGeneration: requestGeneration)
            try ensureCurrentLinkPreviewRequest(requestGeneration)
            linkPreviewErrorMessage = nil
            linkPreview = TerminalLinkPreview(
                id: metadata.id, title: metadata.displayName, kind: artifactKind, content: Self.previewContent(for: artifactKind, fileURL: localURL))
        }
    }

    /// Maps a resolved artifact kind to the preview content case: image/video/pdf preview through
    /// QuickLook; text/markdown/html get dedicated renderers instead of QuickLook's generic file
    /// preview. Applies identically to local-file and downloaded-external artifacts.
    private static func previewContent(for artifactKind: SpacesDeviceTerminalLinkArtifactKind, fileURL: URL) -> TerminalLinkPreviewContent {
        switch artifactKind {
        case .image, .video, .pdf: return .quickLook(fileURL)
        case .text: return .text(fileURL)
        case .markdown: return .markdown(fileURL)
        case .html: return .htmlFile(fileURL)
        }
    }

    /// Metadata byte counts reject oversized text-family local files before transfer. External text
    /// files are measured after download and before they move into the preview cache.
    private func exceedsTextPreviewSizeCap(artifactKind: SpacesDeviceTerminalLinkArtifactKind, metadata: SpacesDeviceTerminalLinkMetadata) -> Bool {
        guard Self.isTextFamilyArtifact(artifactKind), let byteCount = metadata.byteCount else { return false }
        return byteCount > Self.textPreviewByteCountLimit
    }

    private func exceedsTextPreviewSizeCap(artifactKind: SpacesDeviceTerminalLinkArtifactKind, fileURL: URL) throws -> Bool {
        guard Self.isTextFamilyArtifact(artifactKind) else { return false }
        guard let byteCount = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return Int64(byteCount) > Self.textPreviewByteCountLimit
    }

    private nonisolated static func isTextFamilyArtifact(_ kind: SpacesDeviceTerminalLinkArtifactKind) -> Bool {
        switch kind {
        case .text, .markdown, .html: return true
        case .image, .video, .pdf: return false
        }
    }

    private func downloadExternalPreview(
        metadata: SpacesDeviceTerminalLinkMetadata, url: URL, artifactKind: SpacesDeviceTerminalLinkArtifactKind, requestGeneration: UInt64
    ) async throws -> URL {
        try ensureCurrentLinkPreviewRequest(requestGeneration)
        let downloadTask = Task { try await remoteMediaDownloader(url, artifactKind) }
        externalLinkPreviewDownloadTask = downloadTask
        defer { if isCurrentLinkPreviewRequest(requestGeneration) { externalLinkPreviewDownloadTask = nil } }

        let downloadedURL: URL
        do { downloadedURL = try await downloadTask.value } catch {
            if error is CancellationError { throw TerminalLinkPreviewRequestError.stale }
            throw error
        }
        var didMoveDownloadedFile = false
        defer { if !didMoveDownloadedFile { try? FileManager.default.removeItem(at: downloadedURL) } }
        try ensureCurrentLinkPreviewRequest(requestGeneration)
        if try exceedsTextPreviewSizeCap(artifactKind: artifactKind, fileURL: downloadedURL) {
            throw SpacesDeviceAPIClientError.requestFailed("\(metadata.displayName) is too large to preview on this device.")
        }
        try ensureCurrentLinkPreviewRequest(requestGeneration)
        let localURL = try previewCacheURL(for: metadata)
        try ensureCurrentLinkPreviewRequest(requestGeneration)
        try? FileManager.default.removeItem(at: localURL)
        try ensureCurrentLinkPreviewRequest(requestGeneration)
        try FileManager.default.moveItem(at: downloadedURL, to: localURL)
        didMoveDownloadedFile = true
        try ensureCurrentLinkPreviewRequest(requestGeneration)
        cleanupStalePreviewCache()
        return localURL
    }

    /// Downloads a local-file terminal link's contents into the preview cache using the shared chunked
    /// transfer helper. The hand-rolled loop this replaced re-checked the request generation before and
    /// after every chunk; that per-chunk check is now `Task.checkCancellation()` inside the helper, driven
    /// by running the download as its own cancellable `Task` that `invalidateLinkPreviewRequests()`
    /// interrupts mid-transfer, the same way it already interrupts an in-flight external download. The
    /// generation check after the transfer completes stays as an explicit guard so a request superseded in
    /// the instant between the last chunk and this function returning still can't publish a stale preview.
    private func downloadLocalPreview(
        metadata: SpacesDeviceTerminalLinkMetadata, commandChannel: SpacesDeviceAPICommandChannel?, requestGeneration: UInt64
    ) async throws -> URL {
        try ensureCurrentLinkPreviewRequest(requestGeneration)
        let localURL = try previewCacheURL(for: metadata)
        let temporaryURL = temporaryPreviewDownloadURL(for: localURL)
        var didMoveTemporaryFile = false
        defer { if !didMoveTemporaryFile { try? FileManager.default.removeItem(at: temporaryURL) } }

        let downloadTask = Task { [bridgeClient, sessionID = session.id] in
            try await SpacesDeviceTerminalLinkChunkTransfer.download(linkID: metadata.id, expectedByteCount: metadata.byteCount, to: temporaryURL) {
                offset, limit in
                try await bridgeClient.readTerminalLinkChunk(
                    sessionID: sessionID, linkID: metadata.id, offset: offset, limit: limit, commandChannel: commandChannel)
            }
        }
        localLinkPreviewDownloadTask = downloadTask
        defer { if isCurrentLinkPreviewRequest(requestGeneration) { localLinkPreviewDownloadTask = nil } }

        do { _ = try await downloadTask.value } catch {
            if error is CancellationError { throw TerminalLinkPreviewRequestError.stale }
            throw error
        }

        try ensureCurrentLinkPreviewRequest(requestGeneration)
        try? FileManager.default.removeItem(at: localURL)
        try FileManager.default.moveItem(at: temporaryURL, to: localURL)
        didMoveTemporaryFile = true
        cleanupStalePreviewCache()
        return localURL
    }

    private func previewCacheURL(for metadata: SpacesDeviceTerminalLinkMetadata) throws -> URL {
        try FileManager.default.createDirectory(at: linkPreviewCacheDirectory, withIntermediateDirectories: true)
        let fallbackExtension = URL(fileURLWithPath: metadata.displayName).pathExtension
        let fileExtension = SpacesDeviceTerminalLinkClassifier.preferredFilenameExtension(
            contentType: metadata.contentType, fallback: fallbackExtension)
        let identity = Data("\(session.id)\u{0}\(metadata.id)".utf8)
        let digest = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        return linkPreviewCacheDirectory.appendingPathComponent("\(digest).\(fileExtension)")
    }

    private func temporaryPreviewDownloadURL(for cacheURL: URL) -> URL {
        cacheURL.deletingLastPathComponent().appendingPathComponent(".\(cacheURL.lastPathComponent).\(UUID().uuidString).download")
    }

    private func beginLinkPreviewRequest() -> UInt64 {
        linkPreviewRequestGeneration &+= 1
        cancelLinkPreviewDownloads()
        return linkPreviewRequestGeneration
    }

    private func invalidateLinkPreviewRequests() {
        linkPreviewRequestGeneration &+= 1
        cancelLinkPreviewDownloads()
    }

    private func cancelAndClearLinkPreviewState() {
        invalidateLinkPreviewRequests()
        isPreparingLinkPreview = false
        linkPreviewErrorMessage = nil
        linkPreview = nil
    }

    private func cancelLinkPreviewDownloads() {
        externalLinkPreviewDownloadTask?.cancel()
        externalLinkPreviewDownloadTask = nil
        localLinkPreviewDownloadTask?.cancel()
        localLinkPreviewDownloadTask = nil
    }

    private func completeLinkPreviewRequest(_ requestGeneration: UInt64) {
        guard isCurrentLinkPreviewRequest(requestGeneration) else { return }
        isPreparingLinkPreview = false
    }

    private func isCurrentLinkPreviewRequest(_ requestGeneration: UInt64) -> Bool { linkPreviewRequestGeneration == requestGeneration }

    private func ensureCurrentLinkPreviewRequest(_ requestGeneration: UInt64) throws {
        guard isCurrentLinkPreviewRequest(requestGeneration) else { throw TerminalLinkPreviewRequestError.stale }
    }

    private func cleanupStalePreviewCache(now: Date = Date()) {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: linkPreviewCacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        for file in files {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modifiedAt = values?.contentModificationDate, modifiedAt < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func replaceCommandChannel() {
        let previousChannel = commandChannel
        commandChannel = bridgeClient.makeCommandChannel()
        trace("replace_command_channel")
        Task { await previousChannel.close() }
    }

    private func scheduleReconnect(after delay: Duration) {
        guard !isStopping else { return }
        guard !isEndedState else { return }
        trace("schedule_reconnect delay_ms=\(Self.traceDurationMilliseconds(delay)) silent=\(shouldReconnectSilently ? 1 : 0)")
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.connect()
        }
    }

    private func connect() async {
        guard !isStopping else {
            reconnectTask = nil
            return
        }
        if isEndedState {
            await loadEndedState()
            return
        }

        let reconnectSilently = shouldReconnectSilently
        trace("connect_begin silent=\(reconnectSilently ? 1 : 0) attach_before_subscribe=\(shouldAttachBeforeSubscribing ? 1 : 0)")
        if reconnectSilently { isConnecting = false } else { isConnecting = true }
        do {
            if shouldAttachBeforeSubscribing {
                let attachAppearance = AppAppearanceStorage.current.resolvedThemeAppearance
                try await bridgeClient.attach(sessionID: session.id, client: remoteClient, mode: .viewer, appearance: attachAppearance)
                hasAttachedToSession = true
                lastAppearanceSentToSession = attachAppearance
                trace("connect_attach_success")
            }
            let handle = try await bridgeClient.subscribe(sessionID: session.id, clientID: remoteClient.id) { [weak self] payload in
                guard let self else { return }
                // Hand off and return. This is the session's flush rate — up to a few hundred payloads a
                // second under a streaming agent — and everything expensive about a payload (decoding the
                // render update, applying it to the baseline, re-encoding the full frame) happens in the
                // pipeline, off this actor.
                submitLatestState(payload)
            } onDisconnect: { [weak self] error in
                Task { @MainActor [weak self] in await self?.handleDisconnect(error) }
            }
            streamHandle = handle
            errorMessage = nil
            reconnectTask = nil
            trace("connect_subscribe_success")
            if !isOwner {
                let refreshedState = await refreshLatestState(
                    timeout: Self.stateRequestTimeout, ignoreTransientTimeout: true, reason: "connect_bootstrap")
                if refreshedState == nil, !isOwner, !isStopping { isConnecting = false }
            }
        } catch {
            reconnectTask = nil
            isConnecting = false
            trace("connect_failure error=\(sanitizedTraceDetail(error.localizedDescription))")
            await handleConnectError(error)
        }
    }

    @discardableResult private func refreshLatestState(
        timeout: Duration = .seconds(3), ignoreTransientTimeout: Bool = false, applyToLatestState: Bool = true, reason: String = "state_refresh"
    ) async -> GhosttyRemoteSessionStatePayload? {
        trace(
            "fetch_state_begin timeout_ms=\(Self.traceDurationMilliseconds(timeout)) ignore_transient_timeout=\(ignoreTransientTimeout ? 1 : 0) reason=\(reason)"
        )
        logPerformanceEvent(name: "explicit_state_refresh_begin", attributes: ["reason": reason])
        let startedAt = Date()
        do {
            let fetchedState = try await fetchTerminalState(timeout: timeout)
            trace(
                "fetch_state_success reason=\(fetchedState.reason) runtime=\(traceSize(columns: fetchedState.runtimeState?.columns, rows: fetchedState.runtimeState?.rows)) frame=\(traceSize(columns: fetchedState.renderSnapshot?.columns, rows: fetchedState.renderSnapshot?.rows)) owner=\(traceOwnerID(fetchedState.attachmentSnapshot))"
            )
            logPerformanceEvent(
                name: "explicit_state_refresh_end", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), count: fetchedState.outputByteCount,
                attributes: ["reason": reason, "render_update": fetchedState.renderUpdate == nil ? "0" : "1"])
            // Same trade as the takeover apply: this await rides the reduction pipeline's strict FIFO
            // behind whatever the live subscription queued ahead of it — for the connect bootstrap fetch,
            // behind whatever the subscription flushed while the fetch was in flight — rather than jumping
            // the queue, because reduction is off-main, keeps up with a single subscription's rate, and
            // depends on seeing every payload in submission order to keep its delta baseline valid. Callers
            // hold their own transitional flag across the wait by design (`isConnecting` for the connect
            // bootstrap, `isBusy` for takeover confirmation), so the UI does not settle out of that state
            // until the fetched payload has actually landed.
            if applyToLatestState { await applyLatestState(fetchedState) }
            return fetchedState
        } catch {
            trace(
                "fetch_state_failure error=\(sanitizedTraceDetail(error.localizedDescription)) ignore_transient_timeout=\(ignoreTransientTimeout ? 1 : 0) reason=\(reason)"
            )
            logPerformanceEvent(
                name: "explicit_state_refresh_failure", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), attributes: ["reason": reason])
            if ignoreTransientTimeout, Self.isTransientReconnectError(error) {
                errorMessage = nil
                return nil
            }
            if handleAuthenticationFailure(error) { return nil }
            if let unavailableMessage = unavailableMessage(for: error) {
                isSessionUnavailable = true
                errorMessage = unavailableMessage
                return nil
            }
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func fetchTerminalState(timeout: Duration) async throws -> GhosttyRemoteSessionStatePayload {
        try await bridgeClient.fetchState(sessionID: session.id, timeout: timeout)
    }

    private func handleDisconnect(_ error: Error?) async {
        let reconnectSilently = shouldReconnectSilently
        trace("disconnect error=\(sanitizedTraceDetail(error?.localizedDescription ?? "nil")) silent=\(reconnectSilently ? 1 : 0)")
        streamHandle = nil
        isConnecting = false
        if !reconnectSilently {
            isAwaitingTakeoverConfirmation = false
            hasConfirmedOwnerInputReadiness = false
            isInputSurfaceReady = false
        }
        if isStopping { return }
        if isEndedState {
            isBusy = false
            isConnecting = false
            isAwaitingTakeoverConfirmation = false
            errorMessage = nil
            if latestState?.renderSnapshot == nil, !hasRetriedEndedStateAfterStreamClose {
                hasRetriedEndedStateAfterStreamClose = true
                await loadEndedState()
            }
            return
        }
        if let error {
            let isTransient = Self.isTransientReconnectError(error)
            // Transient first: a stream the OS tore down while the app was suspended comes back dead and
            // reconnects immediately, so it must never be read as a revoked pairing and sent to the
            // re-pair screen. Only a failure that is not already known-retryable is offered to the
            // authentication classification.
            if !isTransient, handleAuthenticationFailure(error) { return }
            if await retryStartingStateIfLaunchIsNotReady(error, reason: "disconnect_starting_launch_not_ready") { return }
            if await recoverEndedStateIfLiveStreamIsMissing(error, reason: "disconnect_missing_live_stream") { return }
            if let unavailableMessage = unavailableMessage(for: error) {
                isSessionUnavailable = true
                errorMessage = unavailableMessage
                return
            }
            if isTransient, latestState != nil { errorMessage = nil } else { errorMessage = error.localizedDescription }
        }
        scheduleReconnect(after: reconnectSilently ? Self.silentReconnectDelay : .seconds(1))
    }

    private func handleConnectError(_ error: Error) async {
        trace("connect_error error=\(sanitizedTraceDetail(error.localizedDescription)) silent=\(shouldReconnectSilently ? 1 : 0)")
        let isTransient = Self.isTransientReconnectError(error)
        // Transient first, for the same reason as `handleDisconnect`: a connect that failed on a network
        // still settling after a foreground resume is retried, not read as revocation.
        if !isTransient, handleAuthenticationFailure(error) { return }
        if await retryStartingStateIfLaunchIsNotReady(error, reason: "connect_starting_launch_not_ready") { return }
        if await recoverStartingStateAfterTerminalStopped(error, reason: "connect_starting_terminal_stopped") { return }
        if await recoverEndedStateIfLiveStreamIsMissing(error, reason: "connect_missing_live_stream") { return }
        if let unavailableMessage = unavailableMessage(for: error) {
            isSessionUnavailable = true
            errorMessage = unavailableMessage
            return
        }
        if isTransient, latestState != nil { errorMessage = nil } else { errorMessage = error.localizedDescription }
        scheduleReconnect(after: shouldReconnectSilently ? Self.silentReconnectDelay : .seconds(1))
    }

    private func recoverEndedStateIfLiveStreamIsMissing(_ error: Error, reason: String) async -> Bool {
        guard Self.isMissingLiveStateStreamError(error), !isStopping else { return false }
        trace("missing_live_stream_state_refresh reason=\(reason)")
        isBusy = false
        isConnecting = true
        let refreshedState = await refreshLatestState(timeout: Self.stateRequestTimeout, ignoreTransientTimeout: true, reason: reason)
        isConnecting = false
        guard let refreshedState else { return false }
        if refreshedState.reason == TerminalRemoteSessionStateReason.terminated || Self.isEndedRuntimeState(refreshedState.runtimeState?.state) {
            isSessionUnavailable = false
            isAwaitingTakeoverConfirmation = false
            errorMessage = nil
            return true
        }
        return false
    }

    private func retryStartingStateIfLaunchIsNotReady(_ error: Error, reason: String) async -> Bool {
        guard Self.isStartingSessionLaunchNotReadyError(error), !isStopping, isStartingState else { return false }
        trace("starting_launch_not_ready_retry reason=\(reason)")
        isBusy = false
        isConnecting = false
        isSessionUnavailable = false
        errorMessage = nil
        scheduleReconnect(after: Self.silentReconnectDelay)
        return true
    }

    private func recoverStartingStateAfterTerminalStopped(_ error: Error, reason: String) async -> Bool {
        guard isStartingState else { return false }
        return await recoverEndedStateAfterTerminalStopped(error, reason: reason)
    }

    private func recoverEndedStateAfterTerminalStopped(_ error: Error, reason: String) async -> Bool {
        guard Self.isTerminalNoLongerLiveError(error), !isStopping else { return false }
        trace("terminal_stopped_state_refresh reason=\(reason)")
        isBusy = false
        isConnecting = true
        let refreshedState = await refreshLatestState(timeout: Self.stateRequestTimeout, ignoreTransientTimeout: true, reason: reason)
        isConnecting = false
        guard let refreshedState else { return false }
        if refreshedState.reason == TerminalRemoteSessionStateReason.terminated || Self.isEndedRuntimeState(refreshedState.runtimeState?.state) {
            isSessionUnavailable = false
            isAwaitingTakeoverConfirmation = false
            errorMessage = nil
            return true
        }
        return false
    }

    private var shouldReconnectSilently: Bool {
        guard !isEndedState else { return false }
        return latestState != nil && (isWithinOwnerRecoveryGracePeriod || isAwaitingTakeoverConfirmation || isOwner)
    }

    private var isEndedState: Bool {
        let state = latestState?.runtimeState?.state ?? session.state
        return Self.isEndedRuntimeState(state)
    }

    private var isStartingState: Bool { (latestState?.runtimeState?.state ?? session.state) == .starting }

    private static func isEndedRuntimeState(_ state: TerminalSessionState?) -> Bool {
        guard let state else { return false }
        return state != .running && state != .starting
    }

    private var shouldRenderEndedTerminalSurface: Bool {
        // Demo terminals are never owned and never mutate, so they render their recorded frame through
        // the same read-only, locally-scrollable surface an ended session uses — regardless of whether
        // the recorded runtime state reads as running or exited.
        if isDemoMode { return latestState?.renderSnapshot != nil }
        guard isOwner == false, isEndedState else { return false }
        return latestState?.renderSnapshot != nil
    }

    private var activeOwnerDisplayLabel: String? {
        guard let ownerAttachment = attachmentSnapshot.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil }) else { return nil }
        return attachmentSnapshot.clients.first(where: { $0.id == ownerAttachment.clientID })?.identity.deviceName ?? attachmentSnapshot.clients
            .first(where: { $0.id == ownerAttachment.clientID })?.identity.hostName
            ?? attachmentSnapshot.clients.first(where: { $0.id == ownerAttachment.clientID })?.identity.label
    }

    private func attemptAutomaticTakeoverIfNeeded() {
        // Demo Mode never takes over: the recorded frame renders read-only and the backend would reject
        // the attempt anyway.
        guard !isDemoMode else { return }
        guard !isEndedState else { return }
        guard !hasAttemptedAutomaticTakeover else { return }
        guard !isOwner else { return }
        guard !isSessionUnavailable else { return }
        let state = latestState?.runtimeState?.state ?? session.state
        guard state == .running else { return }
        hasAttemptedAutomaticTakeover = true
        trace("auto_takeover_begin")
        Task { [weak self] in await self?.takeOver() }
    }

    private var isWithinOwnerRecoveryGracePeriod: Bool {
        guard let ownerRecoveryGraceDeadline else { return false }
        return ownerRecoveryGraceDeadline.timeIntervalSinceNow > 0
    }

    private func beginOwnerRecoveryGracePeriod(now: Date = Date()) {
        ownerRecoveryGraceDeadline = now.addingTimeInterval(Self.ownerRecoveryGraceInterval)
    }

    private func scheduleOwnershipSynchronization() {
        guard !isEndedState else { return }
        guard isOwner else { return }
        guard !isBusy else { return }
        if isSynchronizingOwnership {
            needsOwnershipSynchronizationAfterCurrentRun = true
            trace("ownership_sync_reschedule_after_current")
            return
        }
        trace(
            "schedule_ownership_sync viewport=\(traceSize(columns: viewportSize?.columns, rows: viewportSize?.rows)) runtime=\(traceSize(columns: latestState?.runtimeState?.columns, rows: latestState?.runtimeState?.rows))"
        )
        startOwnershipSynchronization()
    }

    private func startOwnershipSynchronization() {
        guard isOwner else { return }
        isOwnershipSynchronizationScheduled = true
        ownershipSynchronizationTask?.cancel()
        ownershipSynchronizationTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: Self.ownershipSyncDebounce)
            guard !Task.isCancelled else { return }
            await self.runOwnershipSynchronization()
        }
    }

    private func runOwnershipSynchronization() async {
        var shouldScheduleFollowUp = false
        defer {
            isSynchronizingOwnership = false
            ownershipSynchronizationTask = nil
            isOwnershipSynchronizationScheduled = false
            if shouldScheduleFollowUp {
                needsOwnershipSynchronizationAfterCurrentRun = false
                scheduleOwnershipSynchronization()
            }
        }
        guard isOwner else { return }
        isSynchronizingOwnership = true
        errorMessage = nil
        let targetViewportSize = await awaitViewportSizeIfNeeded()
        logPerformanceEvent(
            name: "resize_reconciliation_begin",
            attributes: [
                "viewport_columns": String(targetViewportSize?.columns ?? 0), "viewport_rows": String(targetViewportSize?.rows ?? 0),
                "runtime_columns": String(latestState?.runtimeState?.columns ?? 0), "runtime_rows": String(latestState?.runtimeState?.rows ?? 0),
            ])
        let startedAt = Date()
        trace(
            "ownership_sync_begin viewport=\(traceSize(columns: targetViewportSize?.columns, rows: targetViewportSize?.rows)) runtime_before=\(traceSize(columns: latestState?.runtimeState?.columns, rows: latestState?.runtimeState?.rows))"
        )
        await synchronizeOwnershipState(targetViewportSize: targetViewportSize)
        logPerformanceEvent(
            name: "resize_reconciliation_end", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt),
            attributes: [
                "viewport_columns": String(targetViewportSize?.columns ?? 0), "viewport_rows": String(targetViewportSize?.rows ?? 0),
                "runtime_columns": String(latestState?.runtimeState?.columns ?? 0), "runtime_rows": String(latestState?.runtimeState?.rows ?? 0),
            ])
        trace(
            "ownership_sync_end runtime_after=\(traceSize(columns: latestState?.runtimeState?.columns, rows: latestState?.runtimeState?.rows)) owner=\(isOwner ? 1 : 0)"
        )
        shouldScheduleFollowUp = shouldResynchronizeOwnership(afterTargeting: targetViewportSize)
    }

    private func shouldResynchronizeOwnership(afterTargeting targetViewportSize: (columns: Int, rows: Int)?) -> Bool {
        guard isOwner, !isBusy else { return false }
        if needsOwnershipSynchronizationAfterCurrentRun { return true }
        guard let targetViewportSize, let viewportSize else { return false }
        return targetViewportSize.columns != viewportSize.columns || targetViewportSize.rows != viewportSize.rows
    }

    private func awaitViewportSizeIfNeeded() async -> (columns: Int, rows: Int)? {
        if let viewportSize { return viewportSize }
        for _ in 0..<Self.viewportSyncWaitIterations {
            try? await Task.sleep(for: Self.viewportSyncWaitStep)
            guard isOwner else { return nil }
            if let viewportSize { return viewportSize }
        }
        return viewportSize
    }

    private func synchronizeOwnershipState(targetViewportSize: (columns: Int, rows: Int)?) async {
        let previousEmittedAt = latestState?.emittedAt
        let previousScreenRevision = latestState?.screenStateRevision
        let previousRuntimeSize = latestState.map { ($0.runtimeState?.columns, $0.runtimeState?.rows) }
        let stateWaitTargetViewportSize: (columns: Int, rows: Int)?
        if let targetViewportSize {
            if shouldResizeOwnerRuntime(to: targetViewportSize) {
                trace("ownership_resize_begin columns=\(targetViewportSize.columns) rows=\(targetViewportSize.rows)")
                stateWaitTargetViewportSize = targetViewportSize
                do {
                    lastSentResizeSize = targetViewportSize
                    resizeSerial &+= 1
                    let currentResizeSerial = resizeSerial
                    try await bridgeClient.resize(
                        sessionID: session.id, clientID: remoteClient.id, columns: targetViewportSize.columns, rows: targetViewportSize.rows,
                        ownerEpoch: currentOwnerEpoch, resizeSerial: currentResizeSerial, timeout: Self.inputRequestTimeout)
                    trace("ownership_resize_success columns=\(targetViewportSize.columns) rows=\(targetViewportSize.rows)")
                } catch {
                    trace(
                        "ownership_resize_failure columns=\(targetViewportSize.columns) rows=\(targetViewportSize.rows) error=\(sanitizedTraceDetail(error.localizedDescription))"
                    )
                    if await recoverEndedStateAfterTerminalStopped(error, reason: "ownership_resize_terminal_stopped") { return }
                    if !Self.isTransientReconnectError(error) {
                        if handleAuthenticationFailure(error) { return }
                        errorMessage = error.localizedDescription
                    }
                }
            } else {
                lastSentResizeSize = targetViewportSize
                stateWaitTargetViewportSize = nil
                trace("ownership_resize_skip_matching_runtime columns=\(targetViewportSize.columns) rows=\(targetViewportSize.rows)")
            }
        } else {
            stateWaitTargetViewportSize = nil
        }
        let streamedState = await awaitOwnerStateFromStream(
            targetViewportSize: stateWaitTargetViewportSize, previousEmittedAt: previousEmittedAt, previousScreenRevision: previousScreenRevision,
            previousRuntimeSize: previousRuntimeSize)
        guard isOwner else { return }
        if ownerRenderEpochState == nil {
            if streamedState != nil {
                trace("ownership_sync_using_streamed_state")
                beginOwnerRenderEpoch(from: streamedState)
                return
            }
            if hasUsableOwnerBootstrapState(latestState, targetViewportSize: targetViewportSize) {
                trace("ownership_sync_using_existing_state")
                beginOwnerRenderEpoch(from: latestState)
                return
            }
            let refreshedState = await refreshLatestState(
                timeout: Self.stateRequestTimeout, ignoreTransientTimeout: true, reason: "owner_bootstrap_refresh")
            trace(
                "ownership_sync_using_fetched_state render_update=\(refreshedState?.renderUpdate == nil ? 0 : 1) output_bytes=\(refreshedState?.outputByteCount ?? 0)"
            )
            let fallbackState: GhosttyRemoteSessionStatePayload? =
                if hasUsableOwnerBootstrapState(refreshedState, targetViewportSize: targetViewportSize) {
                    refreshedState
                } else if hasUsableOwnerBootstrapState(latestState, targetViewportSize: targetViewportSize) { latestState } else { nil }
            beginOwnerRenderEpoch(from: fallbackState)
        }
    }

    private func shouldResizeOwnerRuntime(to targetViewportSize: (columns: Int, rows: Int)) -> Bool {
        guard ownerRenderEpochState != nil else { return true }
        let runtimeColumns = latestState?.runtimeState?.columns
        let runtimeRows = latestState?.runtimeState?.rows
        return runtimeColumns != targetViewportSize.columns || runtimeRows != targetViewportSize.rows
    }

    private func awaitOwnerStateFromStream(
        targetViewportSize: (columns: Int, rows: Int)?, previousEmittedAt: String?, previousScreenRevision: UInt64?,
        previousRuntimeSize: (Int?, Int?)?
    ) async -> GhosttyRemoteSessionStatePayload? {
        guard targetViewportSize != nil else { return latestState }
        for _ in 0..<Self.postResizeStateSettleIterations {
            guard isOwner else { return nil }
            if let latestState,
                ownerStateLooksFresh(
                    latestState, targetViewportSize: targetViewportSize, previousEmittedAt: previousEmittedAt,
                    previousScreenRevision: previousScreenRevision, previousRuntimeSize: previousRuntimeSize)
            {
                return latestState
            }
            try? await Task.sleep(for: Self.postResizeStateSettleStep)
        }
        return nil
    }

    private func ownerStateLooksFresh(
        _ payload: GhosttyRemoteSessionStatePayload, targetViewportSize: (columns: Int, rows: Int)?, previousEmittedAt: String?,
        previousScreenRevision: UInt64?, previousRuntimeSize: (Int?, Int?)?
    ) -> Bool {
        guard hasUsableOwnerBootstrapState(payload, targetViewportSize: targetViewportSize) else { return false }
        if let targetViewportSize {
            let runtimeColumns = payload.runtimeState?.columns
            let runtimeRows = payload.runtimeState?.rows
            let matchesTargetViewport = runtimeColumns == targetViewportSize.columns && runtimeRows == targetViewportSize.rows
            let runtimeChanged = runtimeColumns != previousRuntimeSize?.0 || runtimeRows != previousRuntimeSize?.1
            let emittedChanged = payload.emittedAt != previousEmittedAt
            let screenRevisionChanged = payload.screenStateRevision != previousScreenRevision
            return matchesTargetViewport && (runtimeChanged || emittedChanged || screenRevisionChanged)
        }
        return payload.emittedAt != previousEmittedAt || payload.screenStateRevision != previousScreenRevision
    }

    private func hasUsableOwnerBootstrapState(_ payload: GhosttyRemoteSessionStatePayload?, targetViewportSize: (columns: Int, rows: Int)? = nil)
        -> Bool
    {
        TerminalRemoteSessionStatePolicy.hasUsableOwnerBootstrapState(
            payload, viewportColumns: targetViewportSize?.columns, viewportRows: targetViewportSize?.rows)
    }

    private func unavailableMessage(for error: Error) -> String? {
        guard Self.isTerminalSessionUnavailableError(error) else { return nil }
        return "This terminal session ended. Return to Terminals to open the current live session."
    }

    private static func isTerminalSessionUnavailableError(_ error: Error) -> Bool {
        switch error {
        // Kept on the message: the daemon's `.sessionNotAvailable` code is coarser than this iOS
        // distinction — it also covers a still-starting session with no live state stream yet — so
        // branching on it would show "session ended" for a session that is merely not ready.
        case SpacesDeviceAPIClientError.requestFailed(let message, _), SpacesDeviceAPIClientError.streamFailed(let message, _):
            return message.localizedStandardContains("terminal session") && message.localizedStandardContains("is not available")
        default: return false
        }
    }

    private func handleAuthenticationFailure(_ error: Error) -> Bool {
        guard let recoveryMessage = SpacesDeviceAPIAuthentication.recoveryMessage(for: error) else { return false }
        isStopping = true
        isAwaitingTakeoverConfirmation = false
        reconnectTask?.cancel()
        reconnectTask = nil
        streamHandle?.cancel()
        streamHandle = nil
        bufferedInputFlushTask?.cancel()
        bufferedInputFlushTask = nil
        cancelQueuedInputSends()
        ownershipSynchronizationTask?.cancel()
        ownershipSynchronizationTask = nil
        bufferedInputText = ""
        hasAttachedToSession = false
        hasConfirmedOwnerInputReadiness = false
        isInputSurfaceReady = false
        reportedOwnerReadyEpochID = nil
        needsOwnershipSynchronizationAfterCurrentRun = false
        invalidateLinkPreviewRequests()
        isPreparingLinkPreview = false
        linkPreviewErrorMessage = nil
        linkPreview = nil
        linkNotice = nil
        isOwnershipSynchronizationScheduled = false
        isSynchronizingOwnership = false
        errorMessage = nil
        onAuthenticationRequired(recoveryMessage)
        return true
    }

    private static func isTransientInputTransportError(_ error: Error) -> Bool {
        if let code = transientPOSIXErrorCode(error),
            code == Int(EAGAIN) || code == Int(EWOULDBLOCK) || code == Int(ETIMEDOUT) || code == Int(ECONNRESET) || code == Int(ECONNABORTED)
                || code == Int(EPIPE) || code == Int(ECONNREFUSED) || code == Int(EBADF) || code == Int(ENOTSOCK) || code == Int(ENOTCONN)
        {
            return true
        }
        switch error {
        // `allCandidatesUnreachable` is the same retry class as a timeout: the endpoint resolver could
        // not reach the daemon at any of its addresses this instant, which a moment later it often can
        // (a Wi-Fi handoff, a tailnet path still coming up). It must not surface as a hard error.
        case SpacesDeviceAPIClientError.requestTimedOut, SpacesDeviceAPIClientError.allCandidatesUnreachable: return true
        case SpacesDeviceAPIClientError.requestFailed(let message, _):
            return message.localizedStandardContains("cancelled") || message.localizedStandardContains("timed out")
                || message.localizedStandardContains("The operation couldn’t be completed. Operation timed out")
                || message.localizedStandardContains("temporarily unavailable") || message.localizedStandardContains("bad file descriptor")
                || message.localizedStandardContains("socket operation on non-socket")
        default: return false
        }
    }

    /// `ENOTCONN` belongs with the rest: a session's live-state stream is its own connection, outside the
    /// request transport that drops its socket when the app backgrounds, so it comes back from suspension
    /// dead and reports "socket is not connected" on the way to a reconnect that immediately succeeds.
    private static func isTransientReconnectError(_ error: Error) -> Bool {
        if let code = transientPOSIXErrorCode(error),
            code == Int(EAGAIN) || code == Int(EWOULDBLOCK) || code == Int(ETIMEDOUT) || code == Int(ECONNRESET) || code == Int(ECONNABORTED)
                || code == Int(EPIPE) || code == Int(ECONNREFUSED) || code == Int(ENOTCONN)
        {
            return true
        }
        switch error {
        // See `isTransientInputTransportError`: an unreachable-at-every-address failure is retryable,
        // so a reconnect attempt during a network change stays silent instead of banner-ing an error.
        case SpacesDeviceAPIClientError.requestTimedOut, SpacesDeviceAPIClientError.allCandidatesUnreachable: return true
        case SpacesDeviceAPIClientError.requestFailed(let message, _), SpacesDeviceAPIClientError.streamFailed(let message, _):
            return message.localizedStandardContains("cancelled") || message.localizedStandardContains("timed out")
                || message.localizedStandardContains("The operation couldn’t be completed. Operation timed out")
                || message.localizedStandardContains("temporarily unavailable")
        default: return false
        }
    }

    private static func isMissingLiveStateStreamError(_ error: Error) -> Bool {
        switch error {
        // Kept on the message: "no live state stream" shares the daemon's `.sessionNotAvailable` code
        // with an ended/unavailable session, so the code cannot single out the still-starting case.
        case SpacesDeviceAPIClientError.requestFailed(let message, _), SpacesDeviceAPIClientError.streamFailed(let message, _):
            return message.localizedStandardContains("no live state stream")
        default: return false
        }
    }

    private static func isStartingSessionLaunchNotReadyError(_ error: Error) -> Bool {
        isMissingLiveStateStreamError(error) || isTerminalSessionUnavailableError(error)
    }

    private static func isTerminalNoLongerLiveError(_ error: Error) -> Bool {
        switch error {
        case SpacesDeviceAPIClientError.requestFailed(let message, let code), SpacesDeviceAPIClientError.streamFailed(let message, let code):
            // The daemon's `.sessionNotRunning` maps 1:1 to "is not running" / "is not live", so branch
            // on the code when the response carries one and fall back to the message otherwise.
            if let code { return code == .sessionNotRunning }
            return message.localizedStandardContains("terminal session")
                && (message.localizedStandardContains("not running") || message.localizedStandardContains("not live"))
        default: return false
        }
    }

    /// The errno behind a failure, whichever way it is reported. Network.framework raises `NWError.posix`,
    /// which bridges to its own error domain rather than `NSPOSIXErrorDomain` — and the live-state stream
    /// is an `NWConnection`, so every errno it reports arrives that way. Reading only the POSIX domain
    /// made the classifiers above blind to stream failures: a socket the OS aborted during suspension
    /// carried `ECONNABORTED`, was listed as transient, and still reached the error banner.
    private static func transientPOSIXErrorCode(_ error: Error) -> Int? {
        if let networkError = error as? NWError, case .posix(let code) = networkError { return Int(code.rawValue) }
        let nsError = error as NSError
        guard nsError.domain == NSPOSIXErrorDomain else { return nil }
        return nsError.code
    }

    private var shouldAttachBeforeSubscribing: Bool {
        guard !isEndedState else { return false }
        guard !hasAttachedToSession else { return false }
        guard let latestState else { return true }
        return !activeAttachmentExists(in: latestState.attachmentSnapshot)
    }

    /// Applies a program's OSC 52 copy to this device's pasteboard when this client owns the session
    /// and the write is addressed to it.
    ///
    /// The payload fans out to every subscriber, so the target check is what makes it the owner's
    /// clipboard and nobody else's. Read from the incoming payload rather than `latestState`: the merge
    /// deliberately drops the field, so the write is applied exactly once, on arrival. Empty text is an
    /// OSC 52 clear, which empties the pasteboard.
    ///
    /// Ownership is read from the state this model already holds, never from the payload's own snapshot:
    /// the write can arrive out of order with the state around it, and the question being answered is
    /// whether this device owns the session NOW — an event's stale snapshot is not evidence of that.
    func applyClipboardWrite(from payload: GhosttyRemoteSessionStatePayload) {
        guard let clipboardWrite = payload.clipboardWrite else { return }
        guard clipboardWrite.targetClientID == remoteClient.id, activeOwnerClientID == remoteClient.id else { return }
        let pasteboard = pasteboardOverrideForTesting ?? .general
        pasteboard.items = []
        guard !clipboardWrite.text.isEmpty else { return }
        pasteboard.string = clipboardWrite.text
    }

    private var activeOwnerClientID: String? {
        guard !isEndedState else { return nil }
        return attachmentSnapshot.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })?.clientID
    }

    private func activeAttachmentExists(in snapshot: TerminalSessionAttachmentSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return snapshot.attachments.contains { attachment in attachment.clientID == remoteClient.id && attachment.detachedAt == nil }
    }

    private func payloadByClearingScreenState(_ payload: GhosttyRemoteSessionStatePayload) -> GhosttyRemoteSessionStatePayload {
        GhosttyRemoteSessionStatePayload(
            sessionID: payload.sessionID, reason: payload.reason, emittedAt: payload.emittedAt, sessionStateRevision: payload.sessionStateRevision,
            sessionStateFlags: payload.sessionStateFlags, screenStateRevision: nil, runtimeState: payload.runtimeState,
            attachmentSnapshot: payload.attachmentSnapshot, title: payload.title, workingDirectory: payload.workingDirectory,
            outputByteCount: payload.outputByteCount, outputEndByteOffset: payload.outputEndByteOffset, renderUpdate: nil)
    }

    /// Hands one payload to the reduction pipeline without waiting for it to be applied. The live
    /// subscription's callback uses this: it runs at the session's flush rate, and nothing it does next
    /// depends on the payload having landed.
    func submitLatestState(_ payload: GhosttyRemoteSessionStatePayload) {
        submittedStateCount += 1
        statePipeline.submit(payload)
    }

    /// Submits `payload` and returns once the pipeline has applied it (or folded it into a later apply).
    /// The routes that read this model's own state immediately afterwards use this rather than
    /// `submitLatestState`: takeover asks whether it actually became the owner, and the connect
    /// bootstrap asks whether it is still connecting, and an apply that had not landed yet would answer
    /// both from the state the payload was meant to replace.
    func applyLatestState(_ payload: GhosttyRemoteSessionStatePayload) async {
        let target = submittedStateCount + 1
        submitLatestState(payload)
        await withCheckedContinuation { continuation in
            // Defensive, not a race guard: `withCheckedContinuation` inherits the caller's main-actor
            // isolation, so this body runs synchronously in the same run as `submitLatestState` above, and
            // `appliedStateCount < target` holds by construction here. The mailbox drain that would advance
            // `appliedStateCount` always hops through a `Task`, so it cannot land in this gap. Kept as a
            // guard anyway so the invariant stays checked rather than assumed.
            guard appliedStateCount < target else {
                continuation.resume()
                return
            }
            stateApplyWaiters.append((target: target, continuation: continuation))
        }
    }

    /// Accounts one apply against every submission it stands for, and releases whoever was waiting on
    /// those submissions. Runs for every output the pipeline hands back, including the ones a stopped
    /// model drops, so a stop can never strand an `applyLatestState` caller.
    private func noteStateApplied(coalescedAwayCount: Int) {
        appliedStateCount += UInt64(coalescedAwayCount) + 1
        guard !stateApplyWaiters.isEmpty else { return }
        let applied = appliedStateCount
        let released = stateApplyWaiters.filter { $0.target <= applied }
        stateApplyWaiters.removeAll { $0.target <= applied }
        for waiter in released { waiter.continuation.resume() }
    }

    /// Applies one payload the pipeline reduced. Everything left here needs the main actor: the model's
    /// observable state, the clipboard one-shot, the resync request, and the metrics.
    private func applyReducedState(_ output: TerminalRemoteStateReductionOutput) {
        defer { noteStateApplied(coalescedAwayCount: output.coalescedAwayCount) }
        let incomingPayload = output.incomingPayload
        // The one-shot runs first and unconditionally, ahead of the stop guard below: a clipboard write is
        // an event, not state, and the direct `.state` refresh runs alongside the live subscription, so a
        // refresh can install newer state before an older stream event carrying the copy arrives. It reads
        // ownership from the state installed so far, which is why it runs ahead of the `latestState` move
        // further down. A payload reduced after `beginStop` still carries a copy the user made before the
        // stop, so the write must land even though everything past the guard below will not.
        applyClipboardWrite(from: incomingPayload)
        // A stopped model has already released the stream, the queued input, and the ownership state this
        // would touch; a payload the pipeline was still reducing when `beginStop` ran must land nowhere
        // rather than resurrect an attachment the stop tore down. Ordering is unaffected: the pipeline
        // keeps chaining, so a later `start()` resumes from the same reduction chain.
        guard !isStopping else { return }
        // A `clipboard_write` payload carries nothing else to apply — the reason exports no screen state,
        // and its runtime/attachment snapshot is a repeat of the output turn that carried the escape
        // sequence — so the pipeline reduces nothing for it. Reducing an out-of-order one would rewind
        // `latestState` to the event's timestamp and could hand ownership back to whoever held it then.
        guard let reduction = output.reduction else { return }
        let applyStartedAt = Date()
        let payload = reduction.payload
        let wasOwner = isOwner
        let wasTakingOver = isBusy || isAwaitingTakeoverConfirmation
        // Covers a resync inherited from an output the apply mailbox coalesced away: the superseded frame
        // is not worth drawing, but the full frame its failed delta could not build is.
        if output.requestsResync { requestRenderUpdateResync() }
        latestState = reduction.storedPayload
        if payload.attachmentSnapshot != nil {
            isAwaitingTakeoverConfirmation = false
            hasAttachedToSession = activeAttachmentExists(in: payload.attachmentSnapshot)
        }
        if isEndedState {
            streamHandle?.cancel()
            streamHandle = nil
            reconnectTask?.cancel()
            reconnectTask = nil
            bufferedInputFlushTask?.cancel()
            bufferedInputFlushTask = nil
            scrollCoalescer.cancel()
            cancelQueuedInputSends()
            ownershipSynchronizationTask?.cancel()
            ownershipSynchronizationTask = nil
            bufferedInputText = ""
            viewportSize = nil
            lastSentResizeSize = nil
            resizeSerial = 0
            needsOwnershipSynchronizationAfterCurrentRun = false
            ownerRecoveryGraceDeadline = nil
            ownerRenderEpochState = nil
            reportedOwnerReadyEpochID = nil
            reportedOwnerNonblankEpochID = nil
            isBusy = false
            isConnecting = false
            isAwaitingTakeoverConfirmation = false
            hasConfirmedOwnerInputReadiness = false
            isInputSurfaceReady = false
            isOwnershipSynchronizationScheduled = false
            isSynchronizingOwnership = false
        }
        let isOwnerAfterMerge = isOwner
        if isOwnerAfterMerge, payload.renderSnapshot != nil {
            if ownerRenderEpochState == nil || !wasOwner { beginOwnerRenderEpoch(from: payload) } else { updateOwnerRenderSnapshot(from: payload) }
        }
        if isOwnerAfterMerge, wasTakingOver {
            isAwaitingTakeoverConfirmation = false
            isBusy = false
            trace("takeover_confirmed_by_stream")
        }
        if !isOwnerAfterMerge {
            // The frame this model holds was exported for the ownership it just lost, so drop it from the
            // state the viewer presents. Only this main-actor mirror is cleared; the pipeline's reduction
            // chain is left alone. That is not because `merged(with:)` scrubs the render update out of the
            // chain across the handoff — it does not: `ownerChanged` only gates the one merge where the
            // incoming payload itself carries the new attachment snapshot, so the pipeline's own
            // `previousPayload` can still be carrying a render update stamped with the old owner epoch, and
            // the very next frameless payload merges that value straight back in (`ownerChanged` reads
            // false on every merge afterwards, since the attachment snapshot no longer changes). What
            // actually keeps a stale frame off the screen is the owner-epoch gate on both ends of the wire:
            // the daemon's `GhosttyRenderUpdateFactory.canDelta` refuses to build a delta once the export
            // baseline's `ownerEpoch` no longer matches the frame's, forcing the first export after a
            // handoff to a full frame (GhosttyRenderUpdate.swift:326-329), and `GhosttyRenderUpdateApplier`
            // enforces the same equality when applying a delta on this client, so a delta stamped for an
            // epoch this client's baseline never saw throws `ownerEpochMismatch` and drives a resync
            // instead of drawing it.
            if wasOwner, !isEndedState, let latestState { self.latestState = payloadByClearingScreenState(latestState) }
            hasConfirmedOwnerInputReadiness = false
            isInputSurfaceReady = false
            lastSentResizeSize = nil
            ownerRenderEpochState = nil
            needsOwnershipSynchronizationAfterCurrentRun = false
            ownershipSynchronizationTask?.cancel()
            ownershipSynchronizationTask = nil
            reportedOwnerReadyEpochID = nil
            isOwnershipSynchronizationScheduled = false
            isSynchronizingOwnership = false
        }
        isSessionUnavailable = false
        errorMessage = nil
        isConnecting = false
        // ~20 string conversions per payload on a path that runs at the session's flush rate, so the
        // dictionary is built only when something is listening. `emittedAt` is parsed inside the same
        // gate for the same reason: it feeds nothing but these metrics.
        if SpacesDeviceTerminalPerformanceLogger.isEnabled() {
            let emittedAt = GhosttyRemoteSessionStateTimestamp.date(from: payload.emittedAt) ?? Date()
            let decodedFrame = reduction.frameToApply
            let decodedUpdate = reduction.decodedUpdate
            var renderUpdateAttributes = GhosttyRenderFrameMetrics.attributes(
                reason: payload.reason, frame: decodedFrame, frameByteCount: incomingPayload.renderUpdate?.count, decodeMS: output.reduceMS,
                outputByteCount: payload.outputByteCount, screenStateRevision: payload.screenStateRevision,
                dropped: incomingPayload.renderUpdate == nil ? nil : decodedFrame == nil,
                dropReason: reduction.dropReason ?? (incomingPayload.renderUpdate != nil && decodedFrame == nil ? "decode_failed" : nil),
                renderMode: renderMode, frameKind: decodedUpdate?.frameKindMetricValue, baseRevision: decodedUpdate?.baseRevision,
                targetRevision: decodedUpdate?.targetRevision ?? payload.screenStateRevision,
                appliedRevision: decodedFrame == nil && incomingPayload.renderUpdate != nil ? nil : payload.screenStateRevision,
                applyMS: TerminalPerformance.elapsedMS(since: applyStartedAt), operationCount: decodedUpdate?.operationCount,
                changedCellCount: decodedUpdate?.changedCellCount, scrollOperationCount: decodedUpdate?.scrollOperationCount,
                fullFrameFallbackReason: decodedUpdate?.fallbackReason, droppedDeltaCount: reduction.dropReason == nil ? nil : 1,
                resyncCount: output.requestsResync ? 1 : nil)
            renderUpdateAttributes["owner_before"] = wasOwner ? "1" : "0"
            renderUpdateAttributes["owner_after"] = isOwnerAfterMerge ? "1" : "0"
            renderUpdateAttributes["render_update"] = incomingPayload.renderUpdate == nil ? "0" : "1"
            renderUpdateAttributes["render_update_bytes"] = String(incomingPayload.renderUpdate?.count ?? 0)
            // The payloads this apply superseded report nothing of their own; this is their trace.
            renderUpdateAttributes["coalesced_applies"] = String(output.coalescedAwayCount)
            logPerformanceEvent(
                name: "render_frame_payload_receive", elapsedMS: TerminalPerformance.elapsedMS(since: emittedAt),
                count: incomingPayload.renderUpdate?.count, attributes: renderUpdateAttributes)
        }
        trace(
            "apply_state reason=\(payload.reason) owner_before=\(wasOwner ? 1 : 0) owner_after=\(isOwnerAfterMerge ? 1 : 0) awaiting_takeover=\(isAwaitingTakeoverConfirmation ? 1 : 0) runtime=\(traceSize(columns: latestState?.runtimeState?.columns, rows: latestState?.runtimeState?.rows)) frame=\(traceSize(columns: latestState?.renderSnapshot?.columns, rows: latestState?.renderSnapshot?.rows)) screen_revision=\(latestState?.screenStateRevision.map(String.init) ?? "nil") owner_client=\(traceOwnerID(latestState?.attachmentSnapshot))"
        )
        if isOwnerAfterMerge, !wasOwner || ownerRenderEpochState == nil {
            beginOwnerRecoveryGracePeriod()
            scheduleOwnershipSynchronization()
        }
        attemptAutomaticTakeoverIfNeeded()
    }

    /// Asks the daemon for a full frame after a delta failed to apply against the pipeline's baseline.
    /// The fetched payload re-enters through the same pipeline, so it cannot overtake a delta already
    /// queued behind it.
    private func requestRenderUpdateResync() {
        Task { [weak self] in
            await self?.refreshLatestState(timeout: Self.inputRequestTimeout, ignoreTransientTimeout: true, reason: "render_update_resync")
        }
    }

    func setInputSurfaceReady(_ ready: Bool) {
        guard !isEndedState else {
            trace("host_input_readiness ready=\(ready ? 1 : 0) ignored_after_end")
            isInputSurfaceReady = false
            return
        }
        if ready {
            trace("host_input_readiness ready=1 accepts_input=\(acceptsInput ? 1 : 0)")
            isInputSurfaceReady = true
            handleOwnerInputSurfaceReady()
            return
        }
        guard !(isOwner && hasConfirmedOwnerInputReadiness && ownerRenderEpochState != nil && !isSessionUnavailable) else {
            trace("host_input_readiness ready=0 ignored_after_owner_ready")
            return
        }
        guard !(hasConfirmedOwnerInputReadiness && acceptsInput) else { return }
        guard !(shouldReconnectSilently && acceptsInput) else { return }
        trace("host_input_readiness ready=0 accepts_input=\(acceptsInput ? 1 : 0)")
        isInputSurfaceReady = false
    }

    private func handleOwnerInputSurfaceReady() {
        guard isOwner, let ownerRenderEpochState else { return }
        hasConfirmedOwnerInputReadiness = true
        if reportedOwnerReadyEpochID != ownerRenderEpochState.id {
            reportedOwnerReadyEpochID = ownerRenderEpochState.id
            logPerformanceEvent(name: "owner_first_input_ready", attributes: ["epoch_id": ownerRenderEpochState.id, "render_mode": renderMode])
        }
    }

    private func writeE2EEventIfNeeded(kind: String, detail: String?) {
        guard e2eConfig.isEnabled, e2eConfig.matches(sessionID: session.id) else { return }
        SpacesMobileE2EDumpWriter.appendEvent(
            .init(sessionID: session.id, kind: kind, detail: detail, emittedAt: ISO8601DateFormatter().string(from: Date())), config: e2eConfig)
    }

    private func logPerformanceEvent(name: String, elapsedMS: Int? = nil, count: Int? = nil, attributes: [String: String] = [:]) {
        SpacesDeviceTerminalPerformanceLogger.emit(
            .init(sessionID: session.id, source: "ios-viewer", name: name, elapsedMS: elapsedMS, count: count, attributes: attributes))
    }

    private func trace(_ message: @autoclosure () -> String) { terminalViewerTrace(session.id, message()) }

    private func traceSize(columns: Int?, rows: Int?) -> String {
        guard let columns, let rows else { return "nil" }
        return "\(columns)x\(rows)"
    }

    private func traceOwnerID(_ snapshot: TerminalSessionAttachmentSnapshot?) -> String {
        snapshot?.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })?.clientID ?? "nil"
    }

    private func sanitizedTraceDetail(_ value: String) -> String { value.replacingOccurrences(of: "\n", with: "\\n") }

    private static func sanitizedPerformanceDetail(_ value: String) -> String { value.replacingOccurrences(of: "\n", with: "\\n") }

    private static func traceDurationMilliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let seconds = components.seconds
        let attoseconds = components.attoseconds
        return Int(seconds * 1_000) + Int(attoseconds / 1_000_000_000_000_000)
    }

    private func beginOwnerRenderEpoch(from payload: GhosttyRemoteSessionStatePayload?) {
        guard let payload, isOwner else { return }
        guard let bootstrapSnapshot = payload.renderSnapshot else { return }
        reportedOwnerReadyEpochID = nil
        reportedOwnerNonblankEpochID = nil
        hasConfirmedOwnerInputReadiness = false
        let epochID = ownerRenderEpochID(for: payload)
        ownerRenderEpochState = GhosttyRemoteTerminalOwnerEpoch(
            sessionID: session.id, id: epochID, ownerEpoch: payload.renderOwnerEpoch ?? 0, bootstrapSnapshot: bootstrapSnapshot)
        trace("owner_render_epoch_begin id=\(epochID) snapshot=1")
        logPerformanceEvent(
            name: "owner_bootstrap_state_received",
            attributes: [
                "epoch_id": epochID, "payload_reason": payload.reason, "snapshot_columns": String(bootstrapSnapshot.columns),
                "snapshot_rows": String(bootstrapSnapshot.rows),
            ])
        if isInputSurfaceReady { handleOwnerInputSurfaceReady() }
    }

    private func updateOwnerRenderSnapshot(from payload: GhosttyRemoteSessionStatePayload) {
        guard let ownerRenderEpochState, let snapshot = payload.renderSnapshot else { return }
        guard ownerRenderEpochState.bootstrapSnapshot != snapshot else { return }
        self.ownerRenderEpochState = GhosttyRemoteTerminalOwnerEpoch(
            sessionID: ownerRenderEpochState.sessionID, id: ownerRenderEpochState.id,
            ownerEpoch: payload.renderOwnerEpoch ?? ownerRenderEpochState.ownerEpoch, bootstrapSnapshot: snapshot)
        trace("owner_render_snapshot_update id=\(ownerRenderEpochState.id) snapshot=1")
    }

    private static func hasVisibleRenderedContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in scalar != "\u{00A0}" && !CharacterSet.whitespacesAndNewlines.contains(scalar) }
    }

    private func ownerRenderEpochID(for payload: GhosttyRemoteSessionStatePayload) -> String {
        let runtimeColumns = payload.runtimeState?.columns ?? 0
        let runtimeRows = payload.runtimeState?.rows ?? 0
        let screenRevision = payload.screenStateRevision ?? 0
        let ownerEpoch = payload.renderOwnerEpoch ?? 0
        return "owner|\(ownerEpoch)|\(payload.emittedAt)|\(screenRevision)|\(runtimeColumns)x\(runtimeRows)"
    }

    private var currentOwnerEpoch: UInt64? { ownerRenderEpochState?.ownerEpoch ?? latestState?.renderOwnerEpoch }

    private func endedRenderID(for snapshot: GhosttyTerminalSnapshot) -> String {
        let screenRevision = latestState?.screenStateRevision ?? 0
        return "ended|\(screenRevision)|\(snapshot.columns)x\(snapshot.rows)|\(latestState?.emittedAt ?? "unknown")"
    }

    /// Applies one reduction output exactly as the pipeline's mailbox would, so the consumption rules —
    /// which payload's state is installed, whose resync request is honored, what a stopped model drops —
    /// can be asserted against a constructed output instead of against a reduce task's timing.
    func applyReducedStateForTesting(_ output: TerminalRemoteStateReductionOutput) {
        // Keeps `submittedStateCount` in step with the `appliedStateCount` bump `applyReducedState` makes
        // below, so an `applyLatestState` awaited later in the same test still resolves against a real
        // submission instead of resolving early because the counters drifted apart.
        submittedStateCount += UInt64(output.coalescedAwayCount) + 1
        applyReducedState(output)
    }

    /// Injects an owner-interactive state so composer/input send sequencing can be exercised without a
    /// live subscribe stream (whose owner-bootstrap render update the unit tests cannot synthesize).
    /// Sets the same preconditions the real owner-bootstrap path establishes: this client owns the
    /// session, input readiness is confirmed, and an owner render epoch carries `ownerEpoch`.
    ///
    /// Submitted through `applyLatestState` rather than assigned to `latestState` directly, so the
    /// reduction pipeline's own chain is seeded with this payload. An unseeded chain has no
    /// `previousPayload` to merge the next real submission against, so that submission would replace
    /// this owner attachment outright instead of carrying it forward — silently dropping ownership out
    /// from under whatever the test does next, rather than raising anything a caller would notice.
    func configureOwnerInteractiveForTesting(ownerEpoch: UInt64) async {
        let ownerAttachment = TerminalAttachment(sessionID: session.id, clientID: remoteClient.id, mode: .owner, attachedAt: "2026-01-01T00:00:00Z")
        let runtime = TerminalSessionRuntimeState(
            sessionID: session.id, servicePID: 100, childPID: 200, state: .running, updatedAt: "2026-01-01T00:00:00Z")
        let payload = GhosttyRemoteSessionStatePayload(
            sessionID: session.id, reason: TerminalRemoteSessionStateReason.initial, emittedAt: "2026-01-01T00:00:00Z", sessionStateRevision: nil,
            sessionStateFlags: nil, screenStateRevision: nil, runtimeState: runtime,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [remoteClient], attachments: [ownerAttachment]), title: session.title,
            workingDirectory: session.workingDirectory, outputByteCount: 0)
        await applyLatestState(payload)
        // A real apply that turns this client into the owner (`wasOwner` false going in) schedules the
        // live ownership-synchronization round trip the owner-bootstrap path always runs after taking
        // over — see the `scheduleOwnershipSynchronization()` call in `applyReducedState`. That round
        // trip needs a subscribe stream and daemon responses this helper does not set up, and while it
        // is pending, `phase` reads `.ownerSynchronizing` rather than `.ownerInteractive`, so
        // `acceptsInput` is false and every send silently no-ops. This helper's whole point is handing
        // the caller an owner that is already past that handshake, so the scheduled work is cancelled
        // immediately behind it rather than left to race whatever the test does next.
        ownershipSynchronizationTask?.cancel()
        ownershipSynchronizationTask = nil
        isOwnershipSynchronizationScheduled = false
        isSynchronizingOwnership = false
        needsOwnershipSynchronizationAfterCurrentRun = false
        // The payload above carries no render update, so the apply above never sets an owner render
        // epoch on its own; that piece is still injected directly, same as before.
        let bootstrapSnapshot = GhosttyTerminalSnapshot(
            columns: 80, rows: 24, cursorColumn: 0, cursorRow: 0, cursorVisible: true, defaultForegroundRGB: 0xFFFF_FFFF, defaultBackgroundRGB: 0,
            cells: [])
        ownerRenderEpochState = GhosttyRemoteTerminalOwnerEpoch(
            sessionID: session.id, id: "owner|test", ownerEpoch: ownerEpoch, bootstrapSnapshot: bootstrapSnapshot)
        hasAttemptedAutomaticTakeover = true
        hasConfirmedOwnerInputReadiness = true
        isInputSurfaceReady = true
    }
}
