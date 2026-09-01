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

/// What a resolved terminal link previews as. Every case carries the on-device local cache file the
/// sheet renders. A plain web page has no device-previewable artifact kind and is not represented
/// here; it opens through `TerminalSafariLink` instead (see `TerminalViewerModel.safariLink`).
enum TerminalLinkPreviewContent: Equatable {
    case quickLook(URL)
    case text(URL)
    case markdown(URL)
    case htmlFile(URL)

    var url: URL {
        switch self {
        case .quickLook(let url), .text(let url), .markdown(let url), .htmlFile(let url): return url
        }
    }

    /// Stable case name for the e2e render dump; not user-facing.
    var caseName: String {
        switch self {
        case .quickLook: return "quickLook"
        case .text: return "text"
        case .markdown: return "markdown"
        case .htmlFile: return "htmlFile"
        }
    }
}

struct TerminalLinkPreview: Identifiable, Equatable {
    let id: String
    let title: String
    let kind: SpacesDeviceTerminalLinkArtifactKind?
    let content: TerminalLinkPreviewContent
}

/// A resolved plain web page link, presented in an in-app Safari sheet (`SFSafariViewController`)
/// rather than the isolated preview viewer: Safari's per-app persistent website data gives
/// authenticated links (e.g. claude.ai artifacts) working cookies and autofill, which the isolated
/// web view cannot offer.
struct TerminalSafariLink: Identifiable, Equatable {
    let id: String
    let url: URL
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
    /// The one viewer-attach operation allowed for one model lifecycle. Both reconnect and foreground
    /// resume await this operation, so a late reconnect cannot reattach over a completed takeover.
    private struct ViewerAttachmentOperation {
        let lifecycle: UInt64
        let clientID: String
        let commandChannel: SpacesDeviceAPICommandChannel
        let appearance: ThemeAppearance
        let task: Task<Void, Error>
    }

    private struct AutomaticTakeoverContext {
        let generation: UInt64
        let lifecycle: UInt64
        let clientID: String
    }

    /// A direct state read either admits its own payload, is overtaken by an accepted stream payload
    /// after the read began, or cannot supply a usable state at all. Only foreground ownership needs to
    /// distinguish the first two; other callers retain their existing optional-result contract.
    private enum StateRefreshOutcome {
        case accepted(GhosttyRemoteSessionStatePayload)
        case superseded(GhosttyRemoteSessionStatePayload)
        case unavailable
    }

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
    /// Shadow of `isConnecting`. See `TerminalViewerState.swift`; not read by product code yet.
    @ObservationIgnored private var connectionState = TerminalViewerConnectionState.idle
    var isBusy = false
    /// Shadow of `isBusy` + `isAwaitingTakeoverConfirmation`. See `TerminalViewerState.swift`; not read
    /// by product code yet.
    @ObservationIgnored private var takeoverAttemptState = TerminalViewerTakeoverAttemptState.none
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
    /// Shadow of `isOwnershipSynchronizationScheduled` + `isSynchronizingOwnership`. See
    /// `TerminalViewerState.swift`; not read by product code yet.
    @ObservationIgnored private var ownershipSyncState = TerminalViewerOwnershipSyncState.idle
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
    /// Drives the in-app Safari sheet for a resolved plain web page link (see `TerminalSafariLink`).
    var safariLink: TerminalSafariLink?
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
    /// The one command connection this viewer's requests ride: attach, the state reads, takeover, the
    /// foreground heartbeat, the ownership-sync resize, and every input send. The transport caches its
    /// pinned-TLS connection, so passing this channel to a request is what keeps a cold open to two dials
    /// (this channel and the session stream) instead of one per call, which over a LAN or a tunnel is a
    /// TCP plus TLS handshake each.
    private var commandChannel: SpacesDeviceAPICommandChannel
    @ObservationIgnored private let remoteMediaDownloader: @Sendable (URL, SpacesDeviceTerminalLinkArtifactKind) async throws -> URL
    @ObservationIgnored private let linkPreviewCacheDirectory: URL
    private var remoteClient: TerminalClient
    private var e2eConfig: SpacesMobileE2EConfig { .shared }
    private var streamHandle: SpacesDeviceAPIStreamHandle?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttemptGeneration: UInt64 = 0
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
    /// Shadow of `isStopping` + `hasSentStopDetach`. See `TerminalViewerState.swift`; not read by
    /// product code yet.
    @ObservationIgnored private var runState = TerminalViewerRunState.running
    private var hasAttachedToSession = false
    private var viewerAttachmentLifecycle: UInt64 = 0
    /// `viewerAttachmentLifecycle` at the moment `latestState` last received a payload that actually
    /// contributed a frame (`reduction.frameToApply != nil`), not every `latestState = reduction.storedPayload`
    /// assignment and not the ownership-loss scrub that only clears screen state. A frameless or refused
    /// reduce carries the prior snapshot forward unchanged, so it must not advance this stamp: doing so
    /// would credit the current lifecycle with a snapshot an earlier lifecycle actually produced. A
    /// retained detail's model survives `stop()`/`start()`: `beginStop` bumps the lifecycle but, for a
    /// non-owner, leaves `latestState` holding the previous lifecycle's render snapshot so the retained
    /// view keeps something to draw while stopped. This stamp is how a hold-release decision on restart
    /// can tell that snapshot apart from one the new lifecycle actually produced.
    private var latestStateLifecycle: UInt64 = 0
    @ObservationIgnored private var viewerAttachmentOperation: ViewerAttachmentOperation?
    private var automaticTakeoverGeneration: UInt64 = 0
    @ObservationIgnored private var automaticTakeoverTask: Task<Void, Never>?
    /// The light/dark appearance the session currently carries — set from the value sent on attach and on
    /// each live push. `sendAppearance` dedupes against it so an unchanged app appearance costs no request;
    /// the daemon would no-op a same-value setAppearance anyway, but skipping it avoids the round-trip.
    private var lastAppearanceSentToSession: ThemeAppearance?
    private var hasAttemptedAutomaticTakeover = false
    /// Foreground ownership is decided by one explicit state read after the scene is active. A payload
    /// reduced while iOS still runs the app in the background cannot settle that decision, because its
    /// lease may expire during the rest of the suspension.
    private var isSceneActive = true
    private var foregroundResumeCycle: UInt64 = 0
    private var isForegroundResumeEvaluationPending = false
    /// Shadow of `isSceneActive` + `isForegroundResumeEvaluationPending`. See
    /// `TerminalViewerState.swift`; not read by product code yet.
    @ObservationIgnored private var sceneState = TerminalViewerSceneState.active(resume: .none)
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
        //
        // The open hold reads every frame here rather than at apply because this is the last point before
        // the mailbox: ending the hold from here leaves the rest of the open burst still queued, so it
        // collapses onto the frame that ended it instead of painting ahead of it. The release itself
        // still waits for `didSubmit`, below: `shouldUseFrame` runs before this frame's own output has
        // reached the mailbox, and releasing here would risk the mailbox draining an older held frame
        // first.
        //
        // Two narrow races on this seam are accepted rather than closed. A viewport report can land in
        // the gap between the post-submit release and the released frame's main-actor apply, so the
        // first paint can be at a grid the surface just moved past; and because this pipeline spans
        // `beginStop()`/`start()`, a payload still draining from the previous lifecycle can match a
        // freshly re-armed hold whose apply then rejects it as stale, leaving the new lifecycle's first
        // frame unheld. Both windows are milliseconds wide against events that occur once per open,
        // both cost at most one transient reflow that the ordinary viewport-report → resize path
        // corrects in the next round trip, and neither can strand the hold; closing them would need a
        // revocable release re-validated at apply time, which puts bookkeeping on the apply hot path
        // for a race the bounded timeout already caps.
        shouldUseFrame: { [openScreenHold] frame, _ in
            openScreenHold.noteReducedFrame(frame)
            return true
        }, apply: { [weak self] output in self?.applyReducedState(output) },
        didSubmit: { [openScreenHold] in openScreenHold.releasePendingAfterSubmit() })
    /// The viewer paints once per open, at the phone's grid: see `TerminalViewerOpenScreenHold`.
    @ObservationIgnored private let openScreenHold = TerminalViewerOpenScreenHold()
    /// Bounds the open hold. Armed with the hold and cancelled by whatever releases it.
    @ObservationIgnored private var openScreenHoldTimeoutTask: Task<Void, Never>?
    /// Payloads handed to the pipeline, and how many of those the main actor has accounted for. The
    /// apply mailbox collapses runs of consecutive frames, so one apply stands for itself plus every
    /// submission it superseded; counting that way is what lets `applyLatestState` wait on a payload
    /// that may never apply under its own name. Unobserved on purpose: they change on every payload and
    /// nothing on screen reads them, so observing them would rebuild the terminal's body at the
    /// session's flush rate.
    @ObservationIgnored private var submittedStateCount: UInt64 = 0
    @ObservationIgnored private var appliedStateCount: UInt64 = 0
    /// Each submission belongs to the viewer lifecycle that admitted it. The reducer keeps its baseline
    /// across a stop/start, but an old lifecycle's direct read must not publish into its replacement after
    /// that baseline work completes.
    @ObservationIgnored private var stateSubmissionLifecycles: [UInt64: UInt64] = [:]
    @ObservationIgnored private var stateApplyWaiters:
        [(target: UInt64, continuation: CheckedContinuation<TerminalRemoteStateReductionOutput, Never>)] = []
    private var reportedOwnerReadyEpochID: String?
    private var reportedOwnerNonblankEpochID: String?
    private var hasRetriedEndedStateAfterStreamClose = false
    /// When the last resync `.state` read was sent, and whether one is still outstanding. Only the resync
    /// route is tracked here: it is the one a failing session can fire per payload, and the pacing below
    /// is what keeps that from becoming one read per payload.
    private var lastRenderUpdateResyncAt: Date?
    private var isRenderUpdateResyncFetchInFlight = false
    /// The one delayed `.state` request owed to a resync the throttle turned away; see
    /// `scheduleTrailingRenderUpdateResync`.
    private var pendingRenderUpdateResyncTask: Task<Void, Never>?
    /// What a landing frame must cover for that delayed request to count as answered. Non-nil exactly
    /// while `pendingRenderUpdateResyncTask` is armed; see `TerminalResyncOwedOrdering` for why a frame
    /// alone is not proof.
    private var owedRenderUpdateResyncOrdering: TerminalResyncOwedOrdering?
    /// How long one resync request paces the next. Only a test overrides it
    /// (`renderUpdateResyncIntervalForTesting`), so a suite can drive the trailing retry to its boundary
    /// instead of waiting out a real second.
    private static let defaultRenderUpdateResyncInterval: TimeInterval = 1
    var renderUpdateResyncIntervalForTesting: TimeInterval?
    private var renderUpdateResyncInterval: TimeInterval { renderUpdateResyncIntervalForTesting ?? Self.defaultRenderUpdateResyncInterval }
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
    /// How long the open hold waits for a frame at this viewer's grid before painting whatever is newest.
    /// The wait it bounds is the ownership-sync resize round trip, so it is that request's own timeout: a
    /// resize that has not been answered by then is not going to produce the frame the hold waits for.
    /// Only a test overrides it (`openScreenHoldTimeoutForTesting`), so a suite can drive the expiry
    /// instead of waiting out the real one.
    private static let defaultOpenScreenHoldTimeout: Duration = inputRequestTimeout
    var openScreenHoldTimeoutForTesting: Duration?
    private var openScreenHoldTimeout: Duration { openScreenHoldTimeoutForTesting ?? Self.defaultOpenScreenHoldTimeout }
    /// Whether the open hold is still waiting for a frame at this viewer's grid. Read by tests, which
    /// assert the release conditions directly rather than inferring them from what happened to paint.
    var isHoldingOpenScreenUpdatesForTesting: Bool { openScreenHold.isHolding }
    /// This viewer's own client record, so a suite can build the attachment snapshot that makes this
    /// viewer the session's owner exactly as the daemon's payload does. `configureOwnerInteractiveForTesting`
    /// cannot stand in for it here: it injects an owner render epoch along with the ownership, and whether
    /// that epoch begins at all is what the open-paint rules are about.
    var remoteClientForTesting: TerminalClient { remoteClient }
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
        guard activeOwnerAttachment != nil else { return "This terminal has no active owner.\nTake over to start typing." }
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
        runState = .running
        isSessionUnavailable = false
        hasAttemptedAutomaticTakeover = false
        hasRetriedEndedStateAfterStreamClose = false
        assertShadowConsistency()
        trace("start")
        if isEndedState {
            reconnectTask = Task { [weak self] in await self?.loadEndedState() }
            return
        }
        beginOpenScreenHold()
        scheduleReconnect(after: .zero)
    }

    /// Holds this viewer's screen updates until a frame at its own grid has reduced, so opening a
    /// terminal paints once, already at the phone's size, instead of painting the daemon's grid and
    /// repainting after the ownership-sync resize round trip.
    ///
    /// Only the paint waits. Every payload still reduces in order, and every reason that carries a state
    /// transition still applies as it arrives (see `TerminalRemoteStateReductionPipeline`), so ownership,
    /// runtime state and the ended transition keep up with the session while the screen waits.
    ///
    /// Demo Mode never holds: it takes no ownership, so it issues no resize and the recorded frame it
    /// serves for the reported viewport is the only frame it will ever paint.
    private func beginOpenScreenHold() {
        guard !isDemoMode, !isEndedState else { return }
        guard !openScreenHold.isHolding else { return }
        let pipeline = statePipeline
        // Weakly, because the pipeline's own `shouldUseFrame` holds the box: a strong capture here would
        // make the two retain each other for as long as the hold is armed, outliving the model that owns
        // them if it is torn down before anything releases the hold.
        openScreenHold.begin(viewport: viewportSize) { [weak pipeline] in pipeline?.setHoldsScreenUpdates(false) }
        pipeline.setHoldsScreenUpdates(true)
        trace("open_screen_hold_begin viewport=\(traceSize(columns: viewportSize?.columns, rows: viewportSize?.rows))")
        openScreenHoldTimeoutTask?.cancel()
        // One bound for the whole open rather than one per viewport report: the reports all land inside
        // the first second, so restarting this with each of them would only ever move the deadline by
        // less than it already allows, at the cost of a second thing to reason about.
        let timeout = openScreenHoldTimeout
        openScreenHoldTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            releaseOpenScreenHold(reason: "timeout")
            paintFirstScreenAfterOpenScreenHoldRelease()
        }
    }

    /// Ends the open hold and the timeout that bounds it. Idempotent, and safe to call after the reduce
    /// loop has already ended the hold by matching a frame: the timer still has to be retired there.
    private func releaseOpenScreenHold(reason: String) {
        guard openScreenHoldTimeoutTask != nil || openScreenHold.isHolding else { return }
        cancelOpenScreenHoldTimers()
        openScreenHold.end()
        trace("open_screen_hold_release reason=\(reason)")
    }

    /// Paints the screen the first-paint gate suppressed, once the hold that suppressed it is over.
    ///
    /// A payload whose reason is a barrier applies even while the pipeline holds its screen updates, so
    /// its frame is consumed by the apply the gate refused to paint from and is left queued nowhere. When
    /// the hold then ends on something other than a newly reduced frame — the surface reporting a grid the
    /// stored screen already matches, or the bounded wait expiring — nothing is left to wake the screen,
    /// and a quiet session would sit on its preparing state until a payload that may never come. The
    /// stored state is that frame, so this paints from it, and when there is no usable one the ownership
    /// handshake runs again and its own bootstrap read fetches one.
    ///
    /// Runs as its own main-actor task so it lands after the drain the release just triggered: when that
    /// drain painted, there is an owner render epoch by the time this reads one and it does nothing.
    private func paintFirstScreenAfterOpenScreenHoldRelease() {
        Task { @MainActor [weak self] in
            guard let self, !openScreenHold.isHolding, ownerRenderEpochState == nil, isOwner, !isEndedState else { return }
            // The timeout release (the other caller of this method) ends the hold without regard to
            // `latestState` at all, so a retained detail's leftover snapshot from a previous
            // `stop()`/`start()` lifecycle can still be sitting here and coincidentally match this
            // lifecycle's reported grid. Painting from it would draw a frame this restarted subscription
            // never produced, so the lifecycle stamp gates this the same way it gates the hold release.
            if latestStateLifecycle == viewerAttachmentLifecycle, let latestState, latestState.renderSnapshot != nil,
                matchesReportedViewport(latestState)
            {
                trace("open_screen_paint_from_stored_state")
                beginOwnerRenderEpoch(from: latestState)
                return
            }
            trace("open_screen_bootstrap_after_release")
            scheduleOwnershipSynchronization()
        }
    }

    private func cancelOpenScreenHoldTimers() {
        openScreenHoldTimeoutTask?.cancel()
        openScreenHoldTimeoutTask = nil
    }

    /// Releases the open hold once nothing can produce the frame it waits for: an ended session paints
    /// its final transcript, and a session another client owns exports its owner's grid and will never
    /// answer a resize from here. Called after `attemptAutomaticTakeoverIfNeeded`, so a viewer that is
    /// about to take the session over is still counted as an owner-to-be rather than released early.
    private func releaseOpenScreenHoldIfNoViewportFrameIsComing() {
        guard openScreenHold.isHolding else { return }
        if isEndedState {
            releaseOpenScreenHold(reason: "session_ended")
            return
        }
        guard !isOwner else { return }
        guard !isBusy, !isAwaitingTakeoverConfirmation, automaticTakeoverTask == nil else { return }
        releaseOpenScreenHold(reason: "not_owner")
    }

    /// Ends the open hold when the ownership handshake settled without producing a frame at this viewer's
    /// grid. True when this call is what ended it.
    @discardableResult private func releaseOpenScreenHoldIfTheHandshakeProducedNoFrame() -> Bool {
        guard openScreenHold.releaseIfNoMatchingFrameArrived() else { return false }
        cancelOpenScreenHoldTimers()
        trace("open_screen_hold_release reason=handshake_without_frame")
        return true
    }

    /// Whether `payload`'s screen is at the grid this viewer reported, which is the frame the open hold
    /// waits for. A viewer that has not measured its surface yet has no grid to match, so nothing does.
    private func matchesReportedViewport(_ payload: GhosttyRemoteSessionStatePayload) -> Bool {
        guard let viewportSize, let snapshot = payload.renderSnapshot else { return false }
        return snapshot.columns == viewportSize.columns && snapshot.rows == viewportSize.rows
    }

    /// Arms the one foreground ownership evaluation for a detail that stays open while iOS suspends the
    /// app. State that arrives before the next `.active` is not authoritative for that evaluation.
    func prepareForBackgrounding() {
        guard !isStopping, !isEndedState else { return }
        cancelAutomaticTakeover()
        isSceneActive = false
        foregroundResumeCycle &+= 1
        isForegroundResumeEvaluationPending = true
        sceneState = .backgrounded(resume: .pending)
        trace("background_arm_foreground_state_evaluation cycle=\(foregroundResumeCycle)")
        assertShadowConsistency()
    }

    /// Evaluates the ownership result associated with the foreground resume. Its stream reconnects without
    /// a new `start()` call, but the daemon may have expired this device's remote-client lease while it
    /// was away, so this always reads state after the scene is active instead of trusting background work.
    func resumeAfterBackgrounding() {
        guard !isStopping, !isEndedState else { return }
        let needsForegroundEvaluation = isForegroundResumeEvaluationPending || !isSceneActive
        isSceneActive = true
        sceneState = isForegroundResumeEvaluationPending ? .active(resume: .pending) : .active(resume: .none)
        guard needsForegroundEvaluation else {
            assertShadowConsistency()
            return
        }
        if !isForegroundResumeEvaluationPending {
            foregroundResumeCycle &+= 1
            isForegroundResumeEvaluationPending = true
            sceneState = .active(resume: .pending)
            trace("foreground_arm_remounted_state_evaluation cycle=\(foregroundResumeCycle)")
        }
        assertShadowConsistency()
        let resumeCycle = foregroundResumeCycle
        let lifecycle = viewerAttachmentLifecycle
        let clientID = remoteClient.id
        Task { [weak self] in
            guard let self else { return }
            guard self.isCurrentForegroundResume(lifecycle: lifecycle, clientID: clientID, resumeCycle: resumeCycle) else { return }
            var hasLiveAttachment = true
            do {
                try await self.bridgeClient.heartbeat(
                    sessionID: self.session.id, clientID: self.remoteClient.id, timeout: Self.stateRequestTimeout, commandChannel: self.commandChannel
                )
                self.trace("foreground_resume_heartbeat_success cycle=\(resumeCycle)")
            } catch {
                if Self.isAttachmentNotFound(error) {
                    guard self.isCurrentForegroundResume(lifecycle: lifecycle, clientID: clientID, resumeCycle: resumeCycle) else { return }
                    self.hasAttachedToSession = false
                    do {
                        try await self.attachViewerForCurrentLifecycle()
                        self.trace("foreground_resume_attach_success cycle=\(resumeCycle)")
                    } catch {
                        self.finishForegroundStateEvaluation(resumeCycle: resumeCycle, acceptedState: nil)
                        return
                    }
                } else if Self.isTerminalNoLongerLiveError(error) {
                    hasLiveAttachment = false
                    self.hasAttachedToSession = false
                    self.trace("foreground_resume_heartbeat_terminal_not_running cycle=\(resumeCycle)")
                } else {
                    _ = self.handleAuthenticationFailure(error)
                    self.finishForegroundStateEvaluation(resumeCycle: resumeCycle, acceptedState: nil)
                    return
                }
            }
            guard self.isCurrentForegroundResume(lifecycle: lifecycle, clientID: clientID, resumeCycle: resumeCycle) else { return }
            if hasLiveAttachment { self.hasAttachedToSession = true }
            let refreshOutcome = await self.refreshLatestStateOutcome(
                timeout: Self.stateRequestTimeout, ignoreTransientTimeout: true, reason: "foreground_resume", lifecycle: lifecycle,
                clientID: clientID, isCurrent: { self.isCurrentForegroundResume(lifecycle: lifecycle, clientID: clientID, resumeCycle: resumeCycle) })
            let acceptedState: GhosttyRemoteSessionStatePayload?
            switch refreshOutcome {
            case .accepted(let payload), .superseded(let payload): acceptedState = payload
            case .unavailable: acceptedState = nil
            }
            self.finishForegroundStateEvaluation(resumeCycle: resumeCycle, acceptedState: acceptedState)
        }
    }

    func stop() {
        guard let stopContext = beginStop() else { return }
        trace("stop")
        Task {
            await detachForStop(
                using: stopContext.channel, clientID: stopContext.clientID, pendingAttachment: stopContext.pendingAttachment,
                pendingAutomaticTakeover: stopContext.pendingAutomaticTakeover, shouldDetach: stopContext.shouldDetach,
                timeout: Self.dismissalDetachTimeout)
        }
    }

    func prepareForBackNavigation() async {
        guard let stopContext = beginStop() else { return }
        trace("back_detach_begin")
        await detachForStop(
            using: stopContext.channel, clientID: stopContext.clientID, pendingAttachment: stopContext.pendingAttachment,
            pendingAutomaticTakeover: stopContext.pendingAutomaticTakeover, shouldDetach: stopContext.shouldDetach,
            timeout: Self.dismissalDetachTimeout)
        trace("back_detach_end")
    }

    private func beginStop() -> (
        channel: SpacesDeviceAPICommandChannel, clientID: String, pendingAttachment: ViewerAttachmentOperation?,
        pendingAutomaticTakeover: Task<Void, Never>?, shouldDetach: Bool
    )? {
        guard !hasSentStopDetach else { return nil }
        hasSentStopDetach = true
        // `isStopping`/`runState` land here, immediately after `hasSentStopDetach`, so that by the time
        // `cancelAutomaticTakeover()` runs below the whole Axis A transition (and this call's Axis C
        // clears) has already landed: everything in between (`shouldDetach` etc.) reads neither flag, so
        // this reordering is behavior-preserving and lets `cancelAutomaticTakeover()` assert its own
        // consistency instead of needing an exemption.
        isStopping = true
        runState = .stopped(detachSent: true)
        let pendingAttachment = viewerAttachmentOperation
        let pendingAutomaticTakeover = automaticTakeoverTask
        let shouldDetach = (hasAttachedToSession || pendingAttachment != nil || pendingAutomaticTakeover != nil) && !isEndedState
        let channel = pendingAttachment?.commandChannel ?? commandChannel
        let clientID = pendingAttachment?.clientID ?? remoteClient.id
        viewerAttachmentOperation = nil
        viewerAttachmentLifecycle &+= 1
        cancelAutomaticTakeover()
        isBusy = false
        isAwaitingTakeoverConfirmation = false
        takeoverAttemptState = .none
        hasAttachedToSession = false
        hasAttemptedAutomaticTakeover = false
        isForegroundResumeEvaluationPending = false
        sceneState = isSceneActive ? .active(resume: .none) : .backgrounded(resume: .none)
        hasConfirmedOwnerInputReadiness = false
        isInputSurfaceReady = false
        reconnectTask?.cancel()
        reconnectTask = nil
        streamHandle?.cancel()
        streamHandle = nil
        releaseOpenScreenHold(reason: "stop")
        cancelTrailingRenderUpdateResync()
        isRenderUpdateResyncFetchInFlight = false
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
        safariLink = nil
        linkNotice = nil
        ownerRecoveryGraceDeadline = nil
        reportedOwnerReadyEpochID = nil
        reportedOwnerNonblankEpochID = nil
        hasRetriedEndedStateAfterStreamClose = false
        isOwnershipSynchronizationScheduled = false
        isSynchronizingOwnership = false
        ownershipSyncState = .idle
        assertShadowConsistency()
        return (channel, clientID, pendingAttachment, pendingAutomaticTakeover, shouldDetach)
    }

    private func detachForStop(
        using currentChannel: SpacesDeviceAPICommandChannel, clientID: String, pendingAttachment: ViewerAttachmentOperation?,
        pendingAutomaticTakeover: Task<Void, Never>?, shouldDetach: Bool, timeout: Duration
    ) async {
        if let pendingAttachment { _ = try? await pendingAttachment.task.value }
        if let pendingAutomaticTakeover { await pendingAutomaticTakeover.value }
        if shouldDetach {
            do {
                try await detachTerminal(clientID: clientID, timeout: timeout, commandChannel: currentChannel)
                trace("detach_success")
            } catch { trace("detach_failure error=\(sanitizedTraceDetail(error.localizedDescription))") }
        }
        await currentChannel.close()
    }

    private func detachTerminal(clientID: String, timeout: Duration, commandChannel: SpacesDeviceAPICommandChannel) async throws {
        try await bridgeClient.detach(sessionID: session.id, clientID: clientID, timeout: timeout, commandChannel: commandChannel)
    }

    private func loadEndedState() async {
        let lifecycle = viewerAttachmentLifecycle
        let clientID = remoteClient.id
        guard isCurrentStateRefresh(lifecycle: lifecycle, clientID: clientID) else { return }
        isConnecting = true
        connectionState = .connecting
        defer {
            if isCurrentStateRefresh(lifecycle: lifecycle, clientID: clientID) {
                isConnecting = false
                reconnectTask = nil
            }
            // Derived from the flag rather than assumed `.idle`: on the stale-lifecycle path above,
            // `isConnecting` is left as whatever another, current lifecycle's connect/reconnect set it
            // to, and this keeps `connectionState` exactly mirroring that value instead of the state
            // this call started with.
            connectionState = isConnecting ? .connecting : .idle
            assertShadowConsistency()
        }
        trace("ended_state_load")
        _ = await refreshLatestState(
            timeout: Self.stateRequestTimeout, ignoreTransientTimeout: false, reason: "ended_initial", lifecycle: lifecycle, clientID: clientID)
    }

    private var renderModeValue: TerminalViewerRenderMode {
        if isEndedState { return .ended }
        if isOwner { return hasConfirmedOwnerInputReadiness && ownerRenderEpochState != nil ? .ownerLive : .ownerBootstrapping }
        return .status
    }

    func takeOver() async { await takeOver(automaticContext: nil) }

    private func takeOver(automaticContext: AutomaticTakeoverContext?) async {
        // Demo Mode is view-only; the backend rejects takeover, so never enter the input path.
        guard !isDemoMode else { return }
        guard !isEndedState else { return }
        guard !isBusy else { return }
        guard automaticContext.map(isCurrentAutomaticTakeover) ?? true else { return }
        let clientID = automaticContext?.clientID ?? remoteClient.id
        let lifecycle = automaticContext?.lifecycle ?? viewerAttachmentLifecycle
        guard isCurrentStateRefresh(lifecycle: lifecycle, clientID: clientID) else { return }
        hasAttemptedAutomaticTakeover = true
        isBusy = true
        hasConfirmedOwnerInputReadiness = false
        isInputSurfaceReady = false
        isAwaitingTakeoverConfirmation = true
        takeoverAttemptState = .awaitingConfirmation
        // Runs on every exit (normal return, early guard return, or throw), so this is the one place
        // that reliably observes this attempt's final `isBusy`/`isAwaitingTakeoverConfirmation` pair
        // regardless of which branch below produced it.
        defer {
            if isCurrentStateRefresh(lifecycle: lifecycle, clientID: clientID), automaticContext.map(isCurrentAutomaticTakeover) ?? true {
                isBusy = false
            }
            takeoverAttemptState = TerminalViewerTakeoverAttemptState(isBusy: isBusy, isAwaitingTakeoverConfirmation: isAwaitingTakeoverConfirmation)
            assertShadowConsistency()
        }
        trace("takeover_begin")
        do {
            let takeoverState = try await takeOverTerminal(clientID: clientID, timeout: Self.inputRequestTimeout)
            guard isCurrentStateRefresh(lifecycle: lifecycle, clientID: clientID) else { return }
            guard automaticContext.map(isCurrentAutomaticTakeover) ?? true else { return }
            // This await sits behind the reduction pipeline's strict FIFO: whatever the live subscription
            // already submitted ahead of this response reduces first, and only then does the takeover
            // response reduce and apply. That is accepted rather than worked around: reduction is off the
            // main actor and keeps up with a single subscription's flush rate, so the backlog it can be
            // behind is small and draining, and the alternative — jumping this response to the front of the
            // queue — would apply it against a reduction chain that has not yet seen everything submitted
            // before it, corrupting the delta baseline the chain depends on staying in submission order.
            // `isBusy` and `isAwaitingTakeoverConfirmation` are held across the wait by design, so the UI
            // stays in its "taking over" state for the whole ride rather than settling early on stale state.
            // In-band, unlike every other response this model reads state out of: this payload is the
            // acknowledgment of a mutation this client just made, and it carries the attachment snapshot
            // naming this device the owner — the state the lines below decide the takeover's outcome
            // from. The out-of-band ordering exists for a response that describes a session the stream has
            // moved past, which this one cannot be; applying that rule here would let a stream payload
            // that raced it refuse the snapshot on `emittedAt` alone and leave a successful takeover
            // reading as unconfirmed.
            //
            // The accepted residual of applying in band: output the session emitted after it captured
            // this response, but delivered before the response is submitted, is overwritten by this apply,
            // which walks the delta baseline back to the screen the takeover was answered with. The next
            // delta then fails its base-revision check and the paced resync repairs it, so what this costs
            // is a transient stale window, not a stuck pane. It is preferred to the alternative: ordering
            // the acknowledgment out of band would let those same racing payloads refuse the snapshot the
            // lines below read the takeover's outcome from.
            if let takeoverState { await applyLatestState(takeoverState, isOutOfBand: false, lifecycle: lifecycle) }
            guard isCurrentStateRefresh(lifecycle: lifecycle, clientID: clientID) else { return }
            guard automaticContext.map(isCurrentAutomaticTakeover) ?? true else { return }
            if !isOwner {
                await refreshLatestState(
                    timeout: Self.inputRequestTimeout, ignoreTransientTimeout: true, reason: "takeover_confirmation", lifecycle: lifecycle,
                    clientID: clientID)
            }
            guard isCurrentStateRefresh(lifecycle: lifecycle, clientID: clientID) else { return }
            guard automaticContext.map(isCurrentAutomaticTakeover) ?? true else { return }
            errorMessage = nil
            if !isOwner {
                isAwaitingTakeoverConfirmation = false
                takeoverAttemptState = TerminalViewerTakeoverAttemptState(
                    isBusy: isBusy, isAwaitingTakeoverConfirmation: isAwaitingTakeoverConfirmation)
                trace("takeover_unconfirmed")
                return
            }
            isAwaitingTakeoverConfirmation = false
            takeoverAttemptState = TerminalViewerTakeoverAttemptState(isBusy: isBusy, isAwaitingTakeoverConfirmation: isAwaitingTakeoverConfirmation)
            trace("takeover_success state=\(takeoverState == nil ? 0 : 1) owner=\(isOwner ? 1 : 0)")
        } catch {
            guard isCurrentStateRefresh(lifecycle: lifecycle, clientID: clientID) else { return }
            guard automaticContext.map(isCurrentAutomaticTakeover) ?? true else { return }
            // Mirrored immediately (not left to the defer below): `handleAuthenticationFailure` a few
            // lines down calls `cancelAutomaticTakeover()`, whose own consistency assert would otherwise
            // observe this clear before the defer's mirror has run.
            isAwaitingTakeoverConfirmation = false
            takeoverAttemptState = TerminalViewerTakeoverAttemptState(isBusy: isBusy, isAwaitingTakeoverConfirmation: isAwaitingTakeoverConfirmation)
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

    private func takeOverTerminal(clientID: String, timeout: Duration) async throws -> GhosttyRemoteSessionStatePayload? {
        try await bridgeClient.takeOver(sessionID: session.id, clientID: clientID, timeout: timeout, commandChannel: commandChannel)
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
            let lifecycle = viewerAttachmentLifecycle
            let clientID = remoteClient.id
            Task { [weak self] in
                await self?.applyDemoViewportResize(columns: resolved.columns, rows: resolved.rows, lifecycle: lifecycle, clientID: clientID)
            }
            return
        }
        guard !isEndedState else { return }
        viewportSize = resolved
        // The surface reports its grid after the first payloads have already been reduced, so a session
        // already running at this grid delivered the frame the hold waits for before there was anything to
        // match it against; `matchesLatestFrame` is how that frame still counts, and it ends the hold here
        // because no later frame would match it either and a quiet session sends no later frame at all.
        //
        // `latestStateLifecycle == viewerAttachmentLifecycle` gates this: a retained detail's model
        // survives `stop()`/`start()`, and for a non-owner viewer `beginStop` leaves `latestState` holding
        // the previous lifecycle's render snapshot so the view still has something to draw while stopped.
        // A frame stored by a previous lifecycle says nothing about what the restarted subscription will
        // deliver, so it must not release this lifecycle's hold just because its grid happens to match.
        if openScreenHold.isHolding,
            openScreenHold.setViewport(
                columns: resolved.columns, rows: resolved.rows,
                matchesLatestFrame: latestStateLifecycle == viewerAttachmentLifecycle ? latestState.map(matchesReportedViewport) ?? false : false)
        {
            cancelOpenScreenHoldTimers()
            trace("open_screen_hold_release reason=viewport_matches_stored_frame")
            paintFirstScreenAfterOpenScreenHoldRelease()
        }
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
    ///
    /// That last part is why this response alone is applied in-band: each recorded grid is an independent
    /// capture with its own revisions and owner epoch, not one session's chain, so a viewport that shrinks
    /// back to a smaller grid asks for a recording the out-of-band ordering would read as a delayed
    /// response and refuse — leaving the wide recording on a narrow screen. Nothing races this read
    /// either: the demo stream emits its recording once and never updates.
    private func applyDemoViewportResize(columns: Int, rows: Int, lifecycle: UInt64, clientID: String) async {
        guard isCurrentStateRefresh(lifecycle: lifecycle, clientID: clientID) else { return }
        do {
            try await bridgeClient.resize(
                context: TerminalCommandContext(sessionID: session.id, clientID: clientID, ownerEpoch: currentOwnerEpoch), columns: columns,
                rows: rows, resizeSerial: nil, timeout: Self.stateRequestTimeout)
        } catch {
            // A demo resize only records the viewport in memory; a failure leaves the current frame in
            // place, so there is nothing to recover.
            trace("demo_viewport_resize_failure error=\(sanitizedTraceDetail(error.localizedDescription))")
        }
        let refreshedState = await refreshLatestState(
            timeout: Self.stateRequestTimeout, ignoreTransientTimeout: true, applyToLatestState: false, reason: "demo_viewport_resize",
            lifecycle: lifecycle, clientID: clientID)
        guard isCurrentStateRefresh(lifecycle: lifecycle, clientID: clientID) else { return }
        if let refreshedState { await applyLatestState(refreshedState, isOutOfBand: false, lifecycle: lifecycle) }
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
        let context = TerminalCommandContext(sessionID: session.id, clientID: remoteClient.id, ownerEpoch: currentOwnerEpoch)
        try await performRequestUsingInputChannel { [bridgeClient, context, payload] commandChannel in
            try await bridgeClient.pasteImage(
                context: context, fileExtension: payload.fileExtension, imageData: payload.imageData, timeout: Self.pasteImageRequestTimeout,
                commandChannel: commandChannel)
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

    func dismissLinkPreview() {
        invalidateLinkPreviewRequests()
        isPreparingLinkPreview = false
        linkPreviewErrorMessage = nil
        linkPreview = nil
    }

    func dismissSafariLink() { safariLink = nil }

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

    /// Clears the daemon's shared selection for every viewer of the session. Never owner-gated: iOS
    /// never creates a selection (#514), it only ever asks to clear the one the daemon already has, and
    /// any attached client may do that regardless of who owns input. Uses its own short-lived command
    /// channel, matching `openTerminalLink`, rather than the owner-only input channel `sendText`/
    /// `sendKey` share.
    ///
    /// Best-effort: a failed clear leaves the shared selection painted until the next daemon frame or a
    /// retap resolves it, so there is nothing to surface to the user for a gesture this transient.
    func clearSelection() async {
        // The daemon rejects selection commands for ended sessions with sessionNotRunning; the UI
        // hides these controls, and this guard keeps any other caller honest.
        guard !isEndedState else { return }
        let commandChannel = bridgeClient.makeCommandChannel()
        defer { Task { await commandChannel.close() } }
        try? await bridgeClient.clearSelection(sessionID: session.id, clientID: remoteClient.id, commandChannel: commandChannel)
    }

    /// Reads the daemon's shared selection and writes it to the pasteboard. Returns whether the copy
    /// succeeded so the Copy pill can swap its label to "Copied" only on success; a failure leaves the
    /// pill reading "Copy" with no alert, so the user can simply retap.
    @discardableResult func copySelection() async -> Bool {
        guard !isEndedState else { return false }
        let commandChannel = bridgeClient.makeCommandChannel()
        defer { Task { await commandChannel.close() } }
        guard let text = try? await bridgeClient.readSelectionText(sessionID: session.id, clientID: remoteClient.id, commandChannel: commandChannel)
        else { return false }
        (pasteboardOverrideForTesting ?? .general).string = text
        return true
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
        let context = TerminalCommandContext(sessionID: session.id, clientID: remoteClient.id, ownerEpoch: currentOwnerEpoch)
        try await performRequestUsingInputChannel { [bridgeClient, context, appendNewline, asPaste] commandChannel in
            try await bridgeClient.sendText(
                context: context, text: text, appendNewline: appendNewline, asPaste: asPaste, timeout: Self.inputRequestTimeout,
                commandChannel: commandChannel)
        }
    }

    private func performSendKeyRequest(_ key: String) async throws {
        let context = TerminalCommandContext(sessionID: session.id, clientID: remoteClient.id, ownerEpoch: currentOwnerEpoch)
        if TerminalKeyInput.hostAction(for: key) == .clearScreenAndScrollback {
            try await performRequestUsingInputChannel { [bridgeClient, context] commandChannel in
                try await bridgeClient.clearScreen(context: context, timeout: Self.inputRequestTimeout, commandChannel: commandChannel)
            }
            return
        }
        try await performRequestUsingInputChannel { [bridgeClient, context] commandChannel in
            try await bridgeClient.sendKey(context: context, key: key, timeout: Self.inputRequestTimeout, commandChannel: commandChannel)
        }
    }

    private func performSendScrollRequest(horizontal: Double, vertical: Double, scrollMods: Int32, pointerPosition: TerminalScrollPointerPosition?)
        async throws
    {
        let context = TerminalCommandContext(sessionID: session.id, clientID: remoteClient.id, ownerEpoch: currentOwnerEpoch)
        try await performRequestUsingInputChannel { [bridgeClient, context] commandChannel in
            try await bridgeClient.scroll(
                context: context, horizontal: horizontal, vertical: vertical, scrollMods: scrollMods == 0 ? nil : scrollMods,
                pointerPosition: pointerPosition, timeout: Self.inputRequestTimeout, commandChannel: commandChannel)
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
                // No previewable artifact kind: this is a plain web page, so it opens in an in-app
                // Safari sheet, which carries persistent cookies and autofill unlike the isolated
                // preview web view used for the artifact kinds below.
                try ensureCurrentLinkPreviewRequest(requestGeneration)
                linkPreviewErrorMessage = nil
                linkPreview = nil
                safariLink = TerminalSafariLink(id: metadata.id, url: url)
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
        safariLink = nil
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

    /// Drops this viewer's command connection and dials a new one. The transport caches its pinned-TLS
    /// connection for the channel's life, so a connection that failed mid-request stays failed until it is
    /// replaced; this is that replacement, and the input retry above is its only caller. A takeover needs
    /// none of it: the channel carries no ownership of its own, since every request names its client ID and
    /// owner epoch, so replacing a warm connection after a successful takeover only costs another dial.
    private func replaceCommandChannel() {
        let previousChannel = commandChannel
        commandChannel = bridgeClient.makeCommandChannel()
        trace("replace_command_channel")
        Task { await previousChannel.close() }
    }

    private func scheduleReconnect(after delay: Duration) {
        guard !isStopping else { return }
        guard !isEndedState else { return }
        reconnectAttemptGeneration &+= 1
        let reconnectAttempt = reconnectAttemptGeneration
        let lifecycle = viewerAttachmentLifecycle
        let clientID = remoteClient.id
        trace("schedule_reconnect delay_ms=\(Self.traceDurationMilliseconds(delay)) silent=\(shouldReconnectSilently ? 1 : 0)")
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.connect(lifecycle: lifecycle, clientID: clientID, reconnectAttempt: reconnectAttempt)
        }
    }

    private func connect(lifecycle: UInt64, clientID: String, reconnectAttempt: UInt64) async {
        guard isCurrentConnect(lifecycle: lifecycle, clientID: clientID, reconnectAttempt: reconnectAttempt) else { return }
        if isEndedState {
            await loadEndedState()
            return
        }

        let reconnectSilently = shouldReconnectSilently
        trace("connect_begin silent=\(reconnectSilently ? 1 : 0) attach_before_subscribe=\(shouldAttachBeforeSubscribing ? 1 : 0)")
        if reconnectSilently { isConnecting = false } else { isConnecting = true }
        connectionState = isConnecting ? .connecting : .idle
        do {
            if shouldAttachBeforeSubscribing {
                try await attachViewerForCurrentLifecycle()
                guard isCurrentConnect(lifecycle: lifecycle, clientID: clientID, reconnectAttempt: reconnectAttempt) else {
                    assertShadowConsistency()
                    return
                }
                trace("connect_attach_success")
            }
            guard isCurrentConnect(lifecycle: lifecycle, clientID: clientID, reconnectAttempt: reconnectAttempt) else {
                assertShadowConsistency()
                return
            }
            let handle = try await bridgeClient.subscribe(sessionID: session.id, clientID: clientID) { [weak self] payload in
                guard let self else { return }
                guard self.isCurrentConnect(lifecycle: lifecycle, clientID: clientID, reconnectAttempt: reconnectAttempt) else { return }
                // Hand off and return. This is the session's flush rate — up to a few hundred payloads a
                // second under a streaming agent — and everything expensive about a payload (decoding the
                // render update, applying it to the baseline, re-encoding the full frame) happens in the
                // pipeline, off this actor.
                submitLatestState(payload, isOutOfBand: false)
            } onDisconnect: { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrentConnect(lifecycle: lifecycle, clientID: clientID, reconnectAttempt: reconnectAttempt) else {
                        return
                    }
                    await self.handleDisconnect(error)
                }
            }
            guard isCurrentConnect(lifecycle: lifecycle, clientID: clientID, reconnectAttempt: reconnectAttempt) else {
                handle.cancel()
                assertShadowConsistency()
                return
            }
            streamHandle = handle
            errorMessage = nil
            reconnectTask = nil
            trace("connect_subscribe_success")
            // Every connect bootstraps from a direct read, an owner's included. `isOwner` can only be true
            // here on a reconnect — at first connect `latestState` is nil and the fallback snapshot cannot
            // name this model's freshly minted client ID as the owner — and that is exactly the case that
            // needs the read: an owner whose stream dropped and reconnected silently would otherwise resume
            // the new subscription's deltas on the frame it still holds, with nothing confirming that
            // baseline is still the one the daemon is sending deltas against. The reducer's guards would
            // catch a divergent delta and drive a resync, but only after a wrong-frame window plus a round
            // trip this read avoids. The response is ordered out-of-band, so one that lands behind the new
            // subscription's initial refuses instead of regressing what the stream already delivered.
            let refreshedState = await refreshLatestState(
                timeout: Self.stateRequestTimeout, ignoreTransientTimeout: true, reason: "connect_bootstrap", lifecycle: lifecycle,
                clientID: clientID, isCurrent: { self.isCurrentConnect(lifecycle: lifecycle, clientID: clientID, reconnectAttempt: reconnectAttempt) }
            )
            guard isCurrentConnect(lifecycle: lifecycle, clientID: clientID, reconnectAttempt: reconnectAttempt) else {
                assertShadowConsistency()
                return
            }
            // Only a non-owner settles `isConnecting` on a bootstrap that answered nothing: an owner
            // reconnects silently, so it never raised the flag in the first place.
            if refreshedState == nil, !isOwner, !isStopping {
                isConnecting = false
                connectionState = .idle
            }
            assertShadowConsistency()
        } catch {
            guard isCurrentConnect(lifecycle: lifecycle, clientID: clientID, reconnectAttempt: reconnectAttempt) else {
                assertShadowConsistency()
                return
            }
            reconnectTask = nil
            isConnecting = false
            connectionState = .idle
            trace("connect_failure error=\(sanitizedTraceDetail(error.localizedDescription))")
            await handleConnectError(error)
            assertShadowConsistency()
        }
    }

    private func isCurrentConnect(lifecycle: UInt64, clientID: String, reconnectAttempt: UInt64) -> Bool {
        !isStopping && viewerAttachmentLifecycle == lifecycle && remoteClient.id == clientID && reconnectAttemptGeneration == reconnectAttempt
    }

    private func isCurrentStateRefresh(lifecycle: UInt64, clientID: String) -> Bool {
        !isStopping && viewerAttachmentLifecycle == lifecycle && remoteClient.id == clientID
    }

    private func isCurrentForegroundResume(lifecycle: UInt64, clientID: String, resumeCycle: UInt64) -> Bool {
        !isStopping && isSceneActive && viewerAttachmentLifecycle == lifecycle && remoteClient.id == clientID && foregroundResumeCycle == resumeCycle
            && isForegroundResumeEvaluationPending
    }

    /// Starts or joins this lifecycle's sole viewer attach. The operation captures the client and command
    /// channel that created it, so stopping or restarting cannot let its late completion mutate a newer
    /// lifecycle. Stop awaits a captured operation before detaching that same client and channel.
    private func attachViewerForCurrentLifecycle() async throws {
        guard !hasAttachedToSession else { return }
        let operation: ViewerAttachmentOperation
        if let existing = viewerAttachmentOperation {
            operation = existing
        } else {
            let lifecycle = viewerAttachmentLifecycle
            let client = remoteClient
            let channel = commandChannel
            let appearance = AppAppearanceStorage.current.resolvedThemeAppearance
            let task = Task { [bridgeClient, sessionID = session.id] in
                try await bridgeClient.attach(sessionID: sessionID, client: client, mode: .viewer, appearance: appearance, commandChannel: channel)
            }
            operation = ViewerAttachmentOperation(
                lifecycle: lifecycle, clientID: client.id, commandChannel: channel, appearance: appearance, task: task)
            viewerAttachmentOperation = operation
        }

        do { try await operation.task.value } catch {
            if viewerAttachmentOperation?.lifecycle == operation.lifecycle { viewerAttachmentOperation = nil }
            throw error
        }
        guard viewerAttachmentOperation?.lifecycle == operation.lifecycle else { return }
        viewerAttachmentOperation = nil
        guard viewerAttachmentLifecycle == operation.lifecycle, !isStopping, remoteClient.id == operation.clientID else { return }
        hasAttachedToSession = true
        lastAppearanceSentToSession = operation.appearance
    }

    @discardableResult private func refreshLatestState(
        timeout: Duration = .seconds(3), ignoreTransientTimeout: Bool = false, applyToLatestState: Bool = true, reason: String = "state_refresh",
        lifecycle: UInt64? = nil, clientID: String? = nil, isCurrent: (() -> Bool)? = nil
    ) async -> GhosttyRemoteSessionStatePayload? {
        guard
            case .accepted(let payload) = await refreshLatestStateOutcome(
                timeout: timeout, ignoreTransientTimeout: ignoreTransientTimeout, applyToLatestState: applyToLatestState, reason: reason,
                lifecycle: lifecycle, clientID: clientID, isCurrent: isCurrent)
        else { return nil }
        return payload
    }

    private func refreshLatestStateOutcome(
        timeout: Duration = .seconds(3), ignoreTransientTimeout: Bool = false, applyToLatestState: Bool = true, reason: String = "state_refresh",
        lifecycle: UInt64? = nil, clientID: String? = nil, isCurrent: (() -> Bool)? = nil
    ) async -> StateRefreshOutcome {
        let refreshLifecycle = lifecycle ?? viewerAttachmentLifecycle
        let refreshClientID = clientID ?? remoteClient.id
        let refreshIsCurrent = { self.isCurrentStateRefresh(lifecycle: refreshLifecycle, clientID: refreshClientID) && (isCurrent?() ?? true) }
        trace(
            "fetch_state_begin timeout_ms=\(Self.traceDurationMilliseconds(timeout)) ignore_transient_timeout=\(ignoreTransientTimeout ? 1 : 0) reason=\(reason)"
        )
        logPerformanceEvent(name: "explicit_state_refresh_begin", attributes: ["reason": reason])
        let startedAt = Date()
        let appliedGenerationBeforeFetch = appliedStateCount
        do {
            let fetchedState = try await fetchTerminalState(timeout: timeout)
            guard refreshIsCurrent() else {
                trace("fetch_state_stale_lifecycle reason=\(reason)")
                return .unavailable
            }
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
            //
            // Out-of-band: every fetch that reaches here — the connect bootstrap, a resync, the ownership
            // handshake's owner-bootstrap read, the ended/stopped-state recovery refreshes — is a response
            // describing the session as it was when it was asked, re-entering beside a subscription that
            // never stopped. The reducer orders it against what it has already reduced, so one that was
            // overtaken by the stream refuses rather than regressing the screen or the metadata.
            if applyToLatestState {
                let output = await applyLatestState(fetchedState, isOutOfBand: true, lifecycle: refreshLifecycle)
                // A response the reducer refused whole judged its raw payload stale against a newer state
                // the stream has already delivered. Returning the raw payload is what let callers derive
                // state the apply itself refuses to derive — the ownership handshake seeding the owner
                // render epoch (and with it the epoch every input and resize request quotes) from a
                // superseded session generation, and the ended-state recovery reading a delayed exit
                // report from a run that has already been relaunched as this session being dead. The
                // ordinary wrapper therefore still answers nil. Foreground ownership is the sole caller
                // that can use the accepted stored payload, and only when a stream output actually landed
                // after this read started.
                if output.reduction?.isRefusedOutOfBandPayload == true {
                    trace("fetch_state_refused reason=\(reason)")
                    guard let storedPayload = output.reduction?.storedPayload, appliedStateCount > appliedGenerationBeforeFetch + 1 else {
                        return .unavailable
                    }
                    return .superseded(storedPayload)
                }
                // What a caller gets back is the reduction's own payload, not the response as it arrived:
                // it is the response as the reducer actually admitted it, its render update resolved to
                // the materialized frame where the frame applied and stripped where it did not. A partial
                // refusal is what makes that distinction load-bearing. A frame at or below the revision
                // this client already retains in the same owner epoch is refused on its own while the
                // payload's metadata is ordered separately and genuinely merges, so
                // `isRefusedOutOfBandPayload` stays false and the check above lets the response through —
                // with the refused frame still on it. Read from the raw response, that frame is what the
                // ownership handshake would seed the owner render epoch's bootstrap snapshot from; read
                // from the reduced payload there is no screen on it at all, and the handshake falls back
                // to `latestState`, which holds the newer frame the refusal was measured against.
                //
                // A nil reduction is no more readable than a refusal, so it answers the same way. The
                // pipeline reduces every payload it is handed except a `clipboard_write`, which carries an
                // event and no state — and no `.state` response is stamped with that reason (see
                // `applyLatestState`), so this is unreachable rather than a fallback. Returning the
                // unreduced response here would be the one way back to handing out a frame nothing
                // admitted.
                guard let reducedPayload = output.reduction?.payload else {
                    trace("fetch_state_unreduced reason=\(reason)")
                    return .unavailable
                }
                return .accepted(reducedPayload)
            }
            return .accepted(fetchedState)
        } catch {
            guard refreshIsCurrent() else {
                trace("fetch_state_stale_lifecycle_failure reason=\(reason)")
                return .unavailable
            }
            trace(
                "fetch_state_failure error=\(sanitizedTraceDetail(error.localizedDescription)) ignore_transient_timeout=\(ignoreTransientTimeout ? 1 : 0) reason=\(reason)"
            )
            logPerformanceEvent(
                name: "explicit_state_refresh_failure", elapsedMS: TerminalPerformance.elapsedMS(since: startedAt), attributes: ["reason": reason])
            if ignoreTransientTimeout, Self.isTransientReconnectError(error) {
                errorMessage = nil
                return .unavailable
            }
            if handleAuthenticationFailure(error) { return .unavailable }
            if let unavailableMessage = unavailableMessage(for: error) {
                isSessionUnavailable = true
                errorMessage = unavailableMessage
                return .unavailable
            }
            errorMessage = error.localizedDescription
            return .unavailable
        }
    }

    private func fetchTerminalState(timeout: Duration) async throws -> GhosttyRemoteSessionStatePayload {
        try await bridgeClient.fetchState(sessionID: session.id, timeout: timeout, commandChannel: commandChannel)
    }

    private func handleDisconnect(_ error: Error?) async {
        let reconnectSilently = shouldReconnectSilently
        trace("disconnect error=\(sanitizedTraceDetail(error?.localizedDescription ?? "nil")) silent=\(reconnectSilently ? 1 : 0)")
        streamHandle = nil
        isConnecting = false
        connectionState = .idle
        if !reconnectSilently {
            isAwaitingTakeoverConfirmation = false
            takeoverAttemptState = TerminalViewerTakeoverAttemptState(isBusy: isBusy, isAwaitingTakeoverConfirmation: isAwaitingTakeoverConfirmation)
            hasConfirmedOwnerInputReadiness = false
            isInputSurfaceReady = false
        }
        if isStopping {
            assertShadowConsistency()
            return
        }
        if isEndedState {
            isBusy = false
            isConnecting = false
            isAwaitingTakeoverConfirmation = false
            connectionState = .idle
            takeoverAttemptState = .none
            errorMessage = nil
            if latestState?.renderSnapshot == nil, !hasRetriedEndedStateAfterStreamClose {
                hasRetriedEndedStateAfterStreamClose = true
                await loadEndedState()
            }
            assertShadowConsistency()
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
                assertShadowConsistency()
                return
            }
            if isTransient, latestState != nil { errorMessage = nil } else { errorMessage = error.localizedDescription }
        }
        scheduleReconnect(after: reconnectSilently ? Self.silentReconnectDelay : .seconds(1))
        assertShadowConsistency()
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
        let lifecycle = viewerAttachmentLifecycle
        let clientID = remoteClient.id
        trace("missing_live_stream_state_refresh reason=\(reason)")
        isBusy = false
        // A concurrent `takeOver()` may be suspended awaiting its own network response while this
        // recovery runs (see `TerminalViewerTakeoverAttemptState.confirmationPendingAfterRecoveryClearedBusy`'s
        // doc comment, which names this call site): `isAwaitingTakeoverConfirmation` is left untouched
        // here, so the derivation below reads whatever that other attempt's flag currently holds and
        // maps the pair exactly, rather than assuming either flag's value.
        takeoverAttemptState = TerminalViewerTakeoverAttemptState(isBusy: isBusy, isAwaitingTakeoverConfirmation: isAwaitingTakeoverConfirmation)
        isConnecting = true
        connectionState = .connecting
        let refreshedState = await refreshLatestState(
            timeout: Self.stateRequestTimeout, ignoreTransientTimeout: true, reason: reason, lifecycle: lifecycle, clientID: clientID)
        guard isCurrentStateRefresh(lifecycle: lifecycle, clientID: clientID) else {
            assertShadowConsistency()
            return false
        }
        isConnecting = false
        connectionState = .idle
        guard let refreshedState else {
            assertShadowConsistency()
            return false
        }
        if refreshedState.reasonKind == .terminated || Self.isEndedRuntimeState(refreshedState.runtimeState?.state) {
            isSessionUnavailable = false
            // A fresh `takeOver()` may have started during this recovery's own await above, passing its
            // `guard !isBusy` while `isBusy` read `false` here (see
            // `TerminalViewerTakeoverAttemptState.sendingAfterRecoveryClearedConfirmation`'s doc comment,
            // which names this call site); clearing only `isAwaitingTakeoverConfirmation` and deriving
            // from both current flags exactly (rather than assuming `isBusy` is still this recovery's own)
            // is what makes that interleaving representable instead of approximated away.
            isAwaitingTakeoverConfirmation = false
            takeoverAttemptState = TerminalViewerTakeoverAttemptState(isBusy: isBusy, isAwaitingTakeoverConfirmation: isAwaitingTakeoverConfirmation)
            errorMessage = nil
            assertShadowConsistency()
            return true
        }
        assertShadowConsistency()
        return false
    }

    private func retryStartingStateIfLaunchIsNotReady(_ error: Error, reason: String) async -> Bool {
        guard Self.isStartingSessionLaunchNotReadyError(error), !isStopping, isStartingState else { return false }
        trace("starting_launch_not_ready_retry reason=\(reason)")
        isBusy = false
        // Same reachable race as `recoverEndedStateIfLiveStreamIsMissing`'s `isBusy = false` above: see
        // `TerminalViewerTakeoverAttemptState.confirmationPendingAfterRecoveryClearedBusy`'s doc comment.
        takeoverAttemptState = TerminalViewerTakeoverAttemptState(isBusy: isBusy, isAwaitingTakeoverConfirmation: isAwaitingTakeoverConfirmation)
        isConnecting = false
        connectionState = .idle
        isSessionUnavailable = false
        errorMessage = nil
        scheduleReconnect(after: Self.silentReconnectDelay)
        assertShadowConsistency()
        return true
    }

    private func recoverStartingStateAfterTerminalStopped(_ error: Error, reason: String) async -> Bool {
        guard isStartingState else { return false }
        return await recoverEndedStateAfterTerminalStopped(error, reason: reason)
    }

    private func recoverEndedStateAfterTerminalStopped(_ error: Error, reason: String) async -> Bool {
        guard Self.isTerminalNoLongerLiveError(error), !isStopping else { return false }
        let lifecycle = viewerAttachmentLifecycle
        let clientID = remoteClient.id
        trace("terminal_stopped_state_refresh reason=\(reason)")
        isBusy = false
        // Same reachable race as `recoverEndedStateIfLiveStreamIsMissing`'s `isBusy = false` above: see
        // `TerminalViewerTakeoverAttemptState.confirmationPendingAfterRecoveryClearedBusy`'s doc comment.
        // This method is also reachable from `routeInputSendRecovery`'s failed-input path, which the
        // enum's doc comment names as one of the three callers that can leave the race window open.
        takeoverAttemptState = TerminalViewerTakeoverAttemptState(isBusy: isBusy, isAwaitingTakeoverConfirmation: isAwaitingTakeoverConfirmation)
        isConnecting = true
        connectionState = .connecting
        let refreshedState = await refreshLatestState(
            timeout: Self.stateRequestTimeout, ignoreTransientTimeout: true, reason: reason, lifecycle: lifecycle, clientID: clientID)
        guard isCurrentStateRefresh(lifecycle: lifecycle, clientID: clientID) else {
            assertShadowConsistency()
            return false
        }
        isConnecting = false
        connectionState = .idle
        guard let refreshedState else {
            assertShadowConsistency()
            return false
        }
        if refreshedState.reasonKind == .terminated || Self.isEndedRuntimeState(refreshedState.runtimeState?.state) {
            isSessionUnavailable = false
            // Same reachable race as `recoverEndedStateIfLiveStreamIsMissing`'s terminated branch above:
            // see `TerminalViewerTakeoverAttemptState.sendingAfterRecoveryClearedConfirmation`'s doc comment.
            isAwaitingTakeoverConfirmation = false
            takeoverAttemptState = TerminalViewerTakeoverAttemptState(isBusy: isBusy, isAwaitingTakeoverConfirmation: isAwaitingTakeoverConfirmation)
            errorMessage = nil
            assertShadowConsistency()
            return true
        }
        assertShadowConsistency()
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
        guard let ownerAttachment = activeOwnerAttachment else { return nil }
        return attachmentSnapshot.clients.first(where: { $0.id == ownerAttachment.clientID })?.identity.deviceName ?? attachmentSnapshot.clients
            .first(where: { $0.id == ownerAttachment.clientID })?.identity.hostName
            ?? attachmentSnapshot.clients.first(where: { $0.id == ownerAttachment.clientID })?.identity.label
    }

    private func finishForegroundStateEvaluation(resumeCycle: UInt64, acceptedState: GhosttyRemoteSessionStatePayload?) {
        guard foregroundResumeCycle == resumeCycle, isForegroundResumeEvaluationPending, isSceneActive else { return }
        isForegroundResumeEvaluationPending = false
        // `isSceneActive` is guaranteed true by the guard above (nothing async runs between it and here).
        sceneState = .active(resume: .none)
        assertShadowConsistency()
        guard let acceptedState else {
            trace("foreground_resume_state_evaluation_finished_without_accepted_state cycle=\(resumeCycle)")
            return
        }
        let fetchedRuntimeState = acceptedState.runtimeState?.state ?? session.state
        if fetchedRuntimeState == .starting {
            hasAttemptedAutomaticTakeover = false
            trace("foreground_resume_starting_state cycle=\(resumeCycle)")
            return
        }
        guard fetchedRuntimeState == .running else {
            hasAttemptedAutomaticTakeover = true
            trace("foreground_resume_nonrunning_state cycle=\(resumeCycle)")
            return
        }
        let fetchedOwnerClientID = acceptedState.attachmentSnapshot?.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })?.clientID
        guard fetchedOwnerClientID != remoteClient.id else {
            hasAttemptedAutomaticTakeover = true
            trace("foreground_resume_owner_confirmed cycle=\(resumeCycle)")
            return
        }
        trace("foreground_resume_rearm_auto_takeover cycle=\(resumeCycle) ownerless=\(fetchedOwnerClientID == nil ? 1 : 0)")
        beginAutomaticTakeover()
    }

    private func attemptAutomaticTakeoverIfNeeded() {
        // Demo Mode never takes over: the recorded frame renders read-only and the backend would reject
        // the attempt anyway.
        guard !isDemoMode else { return }
        guard !isEndedState else { return }
        guard isSceneActive else { return }
        guard !isForegroundResumeEvaluationPending else { return }
        guard !hasAttemptedAutomaticTakeover else { return }
        guard !isOwner else { return }
        guard !isSessionUnavailable else { return }
        let state = latestState?.runtimeState?.state ?? session.state
        guard state == .running else { return }
        beginAutomaticTakeover()
    }

    private func beginAutomaticTakeover() {
        guard !isStopping, isSceneActive else { return }
        cancelAutomaticTakeover()
        let context = AutomaticTakeoverContext(
            generation: automaticTakeoverGeneration, lifecycle: viewerAttachmentLifecycle, clientID: remoteClient.id)
        hasAttemptedAutomaticTakeover = true
        trace("auto_takeover_begin")
        automaticTakeoverTask = Task { [weak self] in
            guard let self, self.isCurrentAutomaticTakeover(context) else { return }
            await self.takeOver(automaticContext: context)
            if self.automaticTakeoverGeneration == context.generation { self.automaticTakeoverTask = nil }
        }
    }

    // Every caller — including `beginStop()`, which now completes its own Axis A transition
    // (`isStopping`/`runState`) before reaching this call — invokes this with otherwise-settled shadow
    // state, so the `defer` below holds at both exits (the early `guard let task` return and the full path).
    private func cancelAutomaticTakeover() {
        defer { assertShadowConsistency() }
        automaticTakeoverGeneration &+= 1
        guard let task = automaticTakeoverTask else { return }
        automaticTakeoverTask = nil
        task.cancel()
        isBusy = false
        isAwaitingTakeoverConfirmation = false
        takeoverAttemptState = .none
    }

    private func isCurrentAutomaticTakeover(_ context: AutomaticTakeoverContext) -> Bool {
        !Task.isCancelled && !isStopping && isSceneActive && automaticTakeoverGeneration == context.generation
            && viewerAttachmentLifecycle == context.lifecycle && remoteClient.id == context.clientID
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
        // `isSynchronizingOwnership` is guaranteed false here: `scheduleOwnershipSynchronization` only
        // calls this when it is not already true.
        ownershipSyncState = .scheduled
        assertShadowConsistency()
        ownershipSynchronizationTask?.cancel()
        ownershipSynchronizationTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: Self.ownershipSyncDebounce)
            guard !Task.isCancelled else { return }
            await self.runOwnershipSynchronization()
        }
    }

    /// How a `synchronizeOwnershipState` run concluded, which is what tells `runOwnershipSynchronization`'s
    /// defer whether releasing the open-screen hold is safe.
    ///
    /// - `noViewportTarget`: `awaitViewportSizeIfNeeded()` returned nil, so the run had no grid to test
    ///   against and issued no resize. The surface's report, the sync it triggers, and the frame that
    ///   would match it are all still coming; releasing here paints whatever stale grid the daemon last
    ///   reported instead.
    /// - `resizedAwaitingFrame`: the resize succeeded (`ownership_resize_success`) but
    ///   `awaitOwnerStateFromStream`'s bounded wait returned nil before the resized frame reduced. That
    ///   frame is en route; releasing paints the stale content it would have replaced.
    /// - `settled`: nothing further is coming from this run, so it is safe to ask the hold whether a
    ///   matching frame ever reduced. Covers a failed or skipped resize, a stream wait that did find a
    ///   fresh state, and every early return (lifecycle mismatch, ended-state recovery, an authentication
    ///   failure) — none of those leave a frame in flight either.
    private enum OwnershipSynchronizationOutcome {
        case noViewportTarget
        case resizedAwaitingFrame
        case settled
    }

    private func runOwnershipSynchronization() async {
        var shouldScheduleFollowUp = false
        var outcome = OwnershipSynchronizationOutcome.settled
        defer {
            // Releasing only makes sense when this run had a grid to test and confirmed nothing else is
            // going to produce a frame for it: `.noViewportTarget` never had one to test, and
            // `.resizedAwaitingFrame` has one en route from the resize this run just sent. Only `.settled`
            // asks the hold whether a matching frame ever reduced — and `releaseIfNoMatchingFrameArrived`
            // is already a no-op once one has, so calling it here for an already-satisfied or
            // already-released hold costs nothing. Once it does release, nothing else is going to produce
            // the frame the hold waited for, so the run that follows bootstraps the screen the ordinary
            // way rather than leaving the viewer preparing until the bounded wait expires.
            if case .settled = outcome, !shouldScheduleFollowUp, releaseOpenScreenHoldIfTheHandshakeProducedNoFrame(), ownerRenderEpochState == nil {
                shouldScheduleFollowUp = true
            }
            isSynchronizingOwnership = false
            ownershipSynchronizationTask = nil
            isOwnershipSynchronizationScheduled = false
            ownershipSyncState = .idle
            assertShadowConsistency()
            if shouldScheduleFollowUp {
                needsOwnershipSynchronizationAfterCurrentRun = false
                scheduleOwnershipSynchronization()
            }
        }
        guard isOwner else { return }
        isSynchronizingOwnership = true
        ownershipSyncState = .running
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
        outcome = await synchronizeOwnershipState(targetViewportSize: targetViewportSize)
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

    private func synchronizeOwnershipState(targetViewportSize: (columns: Int, rows: Int)?) async -> OwnershipSynchronizationOutcome {
        let lifecycle = viewerAttachmentLifecycle
        let clientID = remoteClient.id
        guard isCurrentStateRefresh(lifecycle: lifecycle, clientID: clientID) else { return .settled }
        let previousEmittedAt = latestState?.emittedAt
        let previousScreenRevision = latestState?.screenStateRevision
        let previousRuntimeSize = latestState.map { ($0.runtimeState?.columns, $0.runtimeState?.rows) }
        let stateWaitTargetViewportSize: (columns: Int, rows: Int)?
        // Nil until this run has a grid to test against, which is the run's default outcome: nothing
        // resized, so nothing in flight from this run either.
        var outcome: OwnershipSynchronizationOutcome = targetViewportSize == nil ? .noViewportTarget : .settled
        if let targetViewportSize {
            if shouldResizeOwnerRuntime(to: targetViewportSize) {
                trace("ownership_resize_begin columns=\(targetViewportSize.columns) rows=\(targetViewportSize.rows)")
                stateWaitTargetViewportSize = targetViewportSize
                do {
                    lastSentResizeSize = targetViewportSize
                    resizeSerial &+= 1
                    let currentResizeSerial = resizeSerial
                    try await bridgeClient.resize(
                        context: TerminalCommandContext(sessionID: session.id, clientID: clientID, ownerEpoch: currentOwnerEpoch),
                        columns: targetViewportSize.columns, rows: targetViewportSize.rows, resizeSerial: currentResizeSerial,
                        timeout: Self.inputRequestTimeout, commandChannel: commandChannel)
                    trace("ownership_resize_success columns=\(targetViewportSize.columns) rows=\(targetViewportSize.rows)")
                    // Provisional: a matching frame reducing before the stream wait ends downgrades this
                    // to `.settled` below. Left as `.resizedAwaitingFrame` it means the wait is what times
                    // out, and that frame is still en route.
                    outcome = .resizedAwaitingFrame
                } catch {
                    trace(
                        "ownership_resize_failure columns=\(targetViewportSize.columns) rows=\(targetViewportSize.rows) error=\(sanitizedTraceDetail(error.localizedDescription))"
                    )
                    if await recoverEndedStateAfterTerminalStopped(error, reason: "ownership_resize_terminal_stopped") { return .settled }
                    if !Self.isTransientReconnectError(error) {
                        if handleAuthenticationFailure(error) { return .settled }
                        errorMessage = error.localizedDescription
                    }
                }
                guard isCurrentStateRefresh(lifecycle: lifecycle, clientID: clientID) else { return .settled }
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
        // The provisional `.resizedAwaitingFrame` only holds if the wait is what timed out; a matching
        // state found within it means the resize is no longer the reason nothing further is coming.
        // `.noViewportTarget` is untouched by this: `stateWaitTargetViewportSize` is nil in that case, so
        // `streamedState` is just whatever was already cached, not a resolution of the run's grid.
        if case .resizedAwaitingFrame = outcome, streamedState != nil { outcome = .settled }
        guard isCurrentStateRefresh(lifecycle: lifecycle, clientID: clientID), isOwner else { return .settled }
        // While the open hold is on, the first paint belongs to the hold's release and not to this
        // bootstrap: the grid this run targeted may already have been superseded by a newer report, and
        // painting it here would put that superseded screen up exactly as if there were no hold.
        if ownerRenderEpochState == nil, !openScreenHold.isHolding {
            if streamedState != nil {
                trace("ownership_sync_using_streamed_state")
                beginOwnerRenderEpoch(from: streamedState)
                return outcome
            }
            if hasUsableOwnerBootstrapState(latestState, targetViewportSize: targetViewportSize) {
                trace("ownership_sync_using_existing_state")
                beginOwnerRenderEpoch(from: latestState)
                return outcome
            }
            let refreshedState = await refreshLatestState(
                timeout: Self.stateRequestTimeout, ignoreTransientTimeout: true, reason: "owner_bootstrap_refresh", lifecycle: lifecycle,
                clientID: clientID)
            guard isCurrentStateRefresh(lifecycle: lifecycle, clientID: clientID) else { return .settled }
            trace(
                "ownership_sync_using_fetched_state render_update=\(refreshedState?.renderUpdate == nil ? 0 : 1) output_bytes=\(refreshedState?.outputByteCount ?? 0)"
            )
            let fallbackState: GhosttyRemoteSessionStatePayload? =
                if hasUsableOwnerBootstrapState(refreshedState, targetViewportSize: targetViewportSize) {
                    refreshedState
                } else if hasUsableOwnerBootstrapState(latestState, targetViewportSize: targetViewportSize) { latestState } else { nil }
            beginOwnerRenderEpoch(from: fallbackState)
        }
        return outcome
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
        cancelAutomaticTakeover()
        isStopping = true
        // `hasSentStopDetach` is not touched here (unlike `beginStop()`): this tears the viewer down
        // without going through `beginStop()`'s detach bookkeeping, which is exactly the
        // `.stopped(detachSent: false)` case documented on `TerminalViewerRunState`.
        runState = .stopped(detachSent: hasSentStopDetach)
        isAwaitingTakeoverConfirmation = false
        // `isBusy` is not touched here, so if a `takeOver()` is in flight this derives
        // `.sendingAfterRecoveryClearedConfirmation` rather than assuming the attempt is settled.
        takeoverAttemptState = TerminalViewerTakeoverAttemptState(isBusy: isBusy, isAwaitingTakeoverConfirmation: isAwaitingTakeoverConfirmation)
        reconnectTask?.cancel()
        reconnectTask = nil
        streamHandle?.cancel()
        streamHandle = nil
        bufferedInputFlushTask?.cancel()
        bufferedInputFlushTask = nil
        cancelQueuedInputSends()
        ownershipSynchronizationTask?.cancel()
        ownershipSynchronizationTask = nil
        cancelTrailingRenderUpdateResync()
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
        safariLink = nil
        linkNotice = nil
        isOwnershipSynchronizationScheduled = false
        isSynchronizingOwnership = false
        ownershipSyncState = .idle
        errorMessage = nil
        assertShadowConsistency()
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

    private static func isAttachmentNotFound(_ error: Error) -> Bool {
        guard case SpacesDeviceAPIClientError.requestFailed(_, let code) = error else { return false }
        return code == .notFound
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

    private var activeOwnerAttachment: TerminalAttachment? {
        guard !isEndedState else { return nil }
        return attachmentSnapshot.attachments.first(where: { $0.mode == .owner && $0.detachedAt == nil })
    }

    private var activeOwnerClientID: String? { activeOwnerAttachment?.clientID }

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
    ///
    /// - Parameter isOutOfBand: True for a payload that did not arrive on the session's stream — the
    ///   response to a direct `.state` read, which the reducer orders against what it has already reduced
    ///   so a delayed response cannot walk this viewer back to a screen it is already past. Stated by every
    ///   call site rather than defaulted: nothing on the wire distinguishes a fetch response from a
    ///   subscriber's initial, and the routes into this model disagree — the takeover response is a read
    ///   answer that must nonetheless apply in-band (see `takeOver`).
    func submitLatestState(_ payload: GhosttyRemoteSessionStatePayload, isOutOfBand: Bool, lifecycle: UInt64? = nil) {
        submittedStateCount += 1
        stateSubmissionLifecycles[submittedStateCount] = lifecycle ?? viewerAttachmentLifecycle
        statePipeline.submit(payload, isOutOfBand: isOutOfBand)
    }

    /// Submits `payload` and returns the pipeline output that accounted for it, once that apply has run.
    /// The routes that read this model's own state immediately afterwards use this rather than
    /// `submitLatestState`: takeover asks whether it actually became the owner, and the connect
    /// bootstrap asks whether it is still connecting, and an apply that had not landed yet would answer
    /// both from the state the payload was meant to replace.
    ///
    /// The returned output is what the fetch route reads the reduction's verdict from
    /// (`refreshLatestState`), so how exactly it corresponds to `payload` matters. In general an apply
    /// stands for itself plus every submission the mailbox coalesced into it, so a waiter can be released
    /// by a later output than its own. It cannot happen here: a `.state` response is stamped `initial`
    /// (a live session's export) or `terminated` (an ended one's), and neither is output-shaped, which
    /// makes it a coalescing barrier in both directions — `ApplyMailbox.mayCollapse` requires the
    /// incoming output AND the pending one to be coalescible. So a fetch's output covers exactly its own
    /// submission, and the verdict read off it is that payload's own.
    ///
    /// The waiter is registered before the submit rather than after, so there is no window to guard: this
    /// body runs synchronously on the main actor (`withCheckedContinuation` inherits the caller's
    /// isolation and nothing here suspends), and the mailbox drain that resumes waiters always hops
    /// through a `Task`, so no apply can land between the two lines below.
    @discardableResult func applyLatestState(_ payload: GhosttyRemoteSessionStatePayload, isOutOfBand: Bool, lifecycle: UInt64? = nil) async
        -> TerminalRemoteStateReductionOutput
    {
        let target = submittedStateCount + 1
        return await withCheckedContinuation { continuation in
            stateApplyWaiters.append((target: target, continuation: continuation))
            submitLatestState(payload, isOutOfBand: isOutOfBand, lifecycle: lifecycle)
        }
    }

    /// Accounts one apply against every submission it stands for, and releases whoever was waiting on
    /// those submissions with the output that covered them. Runs for every output the pipeline hands
    /// back, including the ones a stopped model drops, so a stop can never strand an `applyLatestState`
    /// caller.
    private func noteStateApplied(_ output: TerminalRemoteStateReductionOutput) {
        appliedStateCount += UInt64(output.coalescedAwayCount) + 1
        let applied = appliedStateCount
        stateSubmissionLifecycles = stateSubmissionLifecycles.filter { $0.key > applied }
        guard !stateApplyWaiters.isEmpty else { return }
        let released = stateApplyWaiters.filter { $0.target <= applied }
        stateApplyWaiters.removeAll { $0.target <= applied }
        for waiter in released { waiter.continuation.resume(returning: output) }
    }

    /// Applies one payload the pipeline reduced. Everything left here needs the main actor: the model's
    /// observable state, the clipboard one-shot, the resync request, and the metrics.
    private func applyReducedState(_ output: TerminalRemoteStateReductionOutput) {
        defer { noteStateApplied(output) }
        let incomingPayload = output.incomingPayload
        // The one-shot runs before lifecycle rejection: a clipboard write is an event, not session state,
        // and the direct `.state` refresh runs alongside the live subscription, so a refresh can install
        // newer state before an older stream event carrying the copy arrives. It reads ownership from the
        // state installed so far, which is why it runs ahead of the `latestState` move further down. A
        // payload reduced after `beginStop` still carries a copy the user made before navigation, so the
        // write must land even though its stale session state will not.
        applyClipboardWrite(from: incomingPayload)
        let applicationSubmission = appliedStateCount + UInt64(output.coalescedAwayCount) + 1
        let applicationLifecycle = stateSubmissionLifecycles[applicationSubmission]
        guard applicationLifecycle == nil || applicationLifecycle == viewerAttachmentLifecycle else {
            trace("drop_state_from_stale_lifecycle submission=\(applicationSubmission)")
            return
        }
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
        //
        // The ordering the resync is owed at comes from this output's own decoded update even when the
        // request was inherited from an output the mailbox coalesced away: the surviving output is never
        // older than the one it replaced, so its target is at or past the failure's, and an output with no
        // decodable target records `unknown`, which no frame retires.
        if output.requestsResync { requestRenderUpdateResync(owedBy: .forFailedUpdate(reduction.decodedUpdate)) }
        // A materialized frame that covers the failure the pending resync was armed for repaired the chain,
        // so that resync is no longer owed. `frameToApply` is the signal rather than the stored payload's
        // snapshot: the stored payload carries a frame forward through every merge, including the frameless
        // payloads that follow a break, while this is non-nil only for a payload whose own render update
        // decoded and applied. Covering the failure is what makes the retirement sound — a fetch answered
        // before the failure was owed lands a frame that applies and yet leaves the client behind the
        // session (see `TerminalResyncOwedOrdering`). Ordered after the request above so an output that
        // both carries a frame and inherits a coalesced-away resync retires that request rather than
        // leaving it armed.
        if let frame = reduction.frameToApply, let owed = owedRenderUpdateResyncOrdering,
            owed.isSatisfied(byFrameOwnerEpoch: frame.ownerEpoch, sessionRevision: frame.sessionRevision)
        {
            cancelTrailingRenderUpdateResync()
        }
        latestState = reduction.storedPayload
        // A frameless or refused reduce carries the prior snapshot forward untouched, so it must not
        // refresh the snapshot's provenance: only a payload whose own render update decoded and applied
        // (`frameToApply != nil`) gets credit for this lifecycle, matching `latestStateLifecycle`'s doc.
        if reduction.frameToApply != nil { latestStateLifecycle = viewerAttachmentLifecycle }
        // A payload the reducer refused whole carries the attachment snapshot as it was when the `.state`
        // read was answered, which is before whatever superseded it — a handoff, or this device's own
        // attach. Reading it here would rewrite this client's attachment from that pre-handoff snapshot
        // (leaving the next dismissal with nothing to detach, and the next connect free to skip attaching)
        // and clear a takeover this payload has no say over. `storedPayload`, which every other line below
        // reads through `latestState`, is the previous state untouched, so the refusal changes nothing.
        if !reduction.isRefusedOutOfBandPayload, payload.attachmentSnapshot != nil {
            isAwaitingTakeoverConfirmation = false
            // `isBusy` is not touched here, so this derives whichever case a concurrently in-flight
            // `takeOver()` currently holds instead of assuming the attempt is settled.
            takeoverAttemptState = TerminalViewerTakeoverAttemptState(isBusy: isBusy, isAwaitingTakeoverConfirmation: isAwaitingTakeoverConfirmation)
            hasAttachedToSession = activeAttachmentExists(in: payload.attachmentSnapshot)
        }
        if isEndedState {
            streamHandle?.cancel()
            streamHandle = nil
            reconnectTask?.cancel()
            reconnectTask = nil
            cancelTrailingRenderUpdateResync()
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
            connectionState = .idle
            takeoverAttemptState = .none
            hasConfirmedOwnerInputReadiness = false
            isInputSurfaceReady = false
            isOwnershipSynchronizationScheduled = false
            isSynchronizingOwnership = false
            ownershipSyncState = .idle
        }
        let isOwnerAfterMerge = isOwner
        // Same rule for the screen: a refused payload's render snapshot belongs to a session generation
        // the reducer just refused, so feeding it to the owner render epoch would repaint this viewer with
        // stale geometry the pane has already moved past.
        // The open hold defers the FIRST paint until it releases, whatever grid the payload carries: the
        // hold releases on the frame at the grid the surface last reported, so anything reaching here
        // before that is a screen at a grid the viewer has moved past and painting it is the reflow this
        // hold exists to remove. A barrier still
        // applies while the pipeline holds, so this is where such a payload's screen is kept off the
        // surface; everything else on it lands as usual.
        let holdsFirstPaint = openScreenHold.isHolding && ownerRenderEpochState == nil
        if !reduction.isRefusedOutOfBandPayload, isOwnerAfterMerge, payload.renderSnapshot != nil, !holdsFirstPaint {
            if ownerRenderEpochState == nil || !wasOwner { beginOwnerRenderEpoch(from: payload) } else { updateOwnerRenderSnapshot(from: payload) }
        }
        // The reduce loop ends the hold without going through the main actor, so the bound armed with it is
        // retired here instead of being left to fire six seconds into a session that is already painting.
        if openScreenHoldTimeoutTask != nil, !openScreenHold.isHolding { cancelOpenScreenHoldTimers() }
        if isOwnerAfterMerge, wasTakingOver {
            isAwaitingTakeoverConfirmation = false
            isBusy = false
            takeoverAttemptState = .none
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
            ownershipSyncState = .idle
        }
        isSessionUnavailable = false
        errorMessage = nil
        isConnecting = false
        connectionState = .idle
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
        // `ownerRenderEpochState` stays nil for as long as the open hold defers the first paint, so it is
        // not on its own the "this owner still needs its handshake" signal it is outside the hold:
        // rescheduling on it would cancel and restart the synchronization debounce on every payload of the
        // open burst, and the resize the hold is waiting for would never be sent.
        if isOwnerAfterMerge, !wasOwner || (ownerRenderEpochState == nil && !openScreenHold.isHolding) {
            beginOwnerRecoveryGracePeriod()
            scheduleOwnershipSynchronization()
        }
        attemptAutomaticTakeoverIfNeeded()
        releaseOpenScreenHoldIfNoViewportFrameIsComing()
        assertShadowConsistency()
    }

    /// Asks the daemon for a full frame after a delta failed to apply against the pipeline's baseline.
    /// The fetched payload re-enters through the same pipeline, so it cannot overtake a delta already
    /// queued behind it, and it is ordered there as an out-of-band response.
    ///
    /// Each read costs the daemon a unicast full-frame export, and a session that keeps producing
    /// unappliable payloads (a device-side restart window, say) asks for one per payload, so the reads
    /// are paced: an unthrottled retry loop floods the daemon without converging, and the stream's own
    /// recovery — the forced full-frame broadcast — needs room to land in between.
    ///
    /// The throttle paces requests; it never discards one. A `.state` read can answer with no render
    /// update at all — the session exports none while its capture holds nothing visible — and it stamps
    /// the throttle just the same, so the next resync can fall inside a window that repaired nothing.
    /// Dropping it there would leave a session that emits one delta and goes quiet showing a stale grid
    /// until some unrelated later event, so a suppressed request arms exactly one delayed retry at the
    /// window boundary instead.
    private func requestRenderUpdateResync(owedBy ordering: TerminalResyncOwedOrdering) {
        if let lastRenderUpdateResyncAt {
            let elapsed = Date().timeIntervalSince(lastRenderUpdateResyncAt)
            if elapsed < renderUpdateResyncInterval {
                scheduleTrailingRenderUpdateResync(after: renderUpdateResyncInterval - elapsed, owedBy: ordering)
                return
            }
        }
        // The open-throttle path owes the same guarantee as the throttled one: a resync read already in
        // flight was issued before this resync was owed, so it can answer with no render update and repair
        // nothing. Letting it stand in for this request would consume the request unsent, so arm the
        // trailing retry instead, exactly as a throttled request does.
        guard !isRenderUpdateResyncFetchInFlight else {
            scheduleTrailingRenderUpdateResync(after: renderUpdateResyncInterval, owedBy: ordering)
            return
        }
        sendRenderUpdateResyncFetch()
    }

    /// Arms the one delayed request a throttled resync is owed, and records the ordering that request has
    /// to be answered at. Coalesced: a second suppressed request while this is pending is already covered
    /// by the same timer, so it must not stack a competing one — it only raises the debt to whichever
    /// failure is later (`TerminalResyncOwedOrdering.merged`).
    ///
    /// Cancelled when a materialized frame covering the recorded ordering lands (`applyReducedState`),
    /// when the session ends, on stop, and when a revoked pairing tears the viewer down
    /// (`handleAuthenticationFailure`) — so a viewer the user has left, one whose pane is already
    /// repaired, or one the device no longer authenticates, never dials the device.
    private func scheduleTrailingRenderUpdateResync(after delay: TimeInterval, owedBy ordering: TerminalResyncOwedOrdering) {
        owedRenderUpdateResyncOrdering = owedRenderUpdateResyncOrdering?.merged(with: ordering) ?? ordering
        armTrailingRenderUpdateResync(after: delay)
    }

    /// The timer behind a request already recorded as owed.
    ///
    /// The request stays owed until a fetch genuinely starts. A resync read already in flight refuses this
    /// one, and that read was issued before this resync was owed, so treating the refusal as delivery is
    /// how the owed request would go missing. A retry that lands on one waits out another full window
    /// instead — no spin, the pacing is unchanged since nothing was sent, and the recorded ordering rides
    /// along untouched because the same debt is still outstanding.
    private func armTrailingRenderUpdateResync(after delay: TimeInterval) {
        guard pendingRenderUpdateResyncTask == nil else { return }
        pendingRenderUpdateResyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            pendingRenderUpdateResyncTask = nil
            guard !isRenderUpdateResyncFetchInFlight else {
                armTrailingRenderUpdateResync(after: renderUpdateResyncInterval)
                return
            }
            owedRenderUpdateResyncOrdering = nil
            sendRenderUpdateResyncFetch()
        }
    }

    private func cancelTrailingRenderUpdateResync() {
        pendingRenderUpdateResyncTask?.cancel()
        pendingRenderUpdateResyncTask = nil
        owedRenderUpdateResyncOrdering = nil
    }

    /// Stamps the throttle and sends the resync read. Both the stamp and the in-flight mark are set before
    /// the request is started, so a burst of failing payloads arriving in the same turn as this one sees
    /// the window already open rather than each sending a read of its own.
    private func sendRenderUpdateResyncFetch() {
        lastRenderUpdateResyncAt = Date()
        isRenderUpdateResyncFetchInFlight = true
        let lifecycle = viewerAttachmentLifecycle
        let clientID = remoteClient.id
        Task { [weak self] in
            guard let self else { return }
            await self.refreshLatestState(
                timeout: Self.inputRequestTimeout, ignoreTransientTimeout: true, reason: "render_update_resync", lifecycle: lifecycle,
                clientID: clientID)
            guard self.isCurrentStateRefresh(lifecycle: lifecycle, clientID: clientID) else { return }
            self.isRenderUpdateResyncFetchInFlight = false
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

    /// Checked at the end of every method that writes one of the absorbed flags below, never after an
    /// individual write: a method's own body can leave a flag and its shadow briefly disagreeing between
    /// two of its own statements, and that window is not a bug. Each shadow enum is DEBUG-only ballast
    /// until commit 3 makes it authoritative and deletes the flag it mirrors — nothing here is read by
    /// product code yet.
    private func assertShadowConsistency() {
        #if DEBUG
            switch runState {
            case .running:
                if isStopping || hasSentStopDetach {
                    assertionFailure("runState=\(runState) but isStopping=\(isStopping) hasSentStopDetach=\(hasSentStopDetach)")
                }
            case .stopped(let detachSent):
                if !isStopping || hasSentStopDetach != detachSent {
                    assertionFailure("runState=\(runState) but isStopping=\(isStopping) hasSentStopDetach=\(hasSentStopDetach)")
                }
            }
            switch connectionState {
            case .idle: if isConnecting { assertionFailure("connectionState=\(connectionState) but isConnecting=\(isConnecting)") }
            case .connecting: if !isConnecting { assertionFailure("connectionState=\(connectionState) but isConnecting=\(isConnecting)") }
            }
            switch takeoverAttemptState {
            case .none:
                if isBusy || isAwaitingTakeoverConfirmation {
                    assertionFailure(
                        "takeoverAttemptState=\(takeoverAttemptState) but isBusy=\(isBusy) isAwaitingTakeoverConfirmation=\(isAwaitingTakeoverConfirmation)"
                    )
                }
            case .awaitingConfirmation:
                if !isBusy || !isAwaitingTakeoverConfirmation {
                    assertionFailure(
                        "takeoverAttemptState=\(takeoverAttemptState) but isBusy=\(isBusy) isAwaitingTakeoverConfirmation=\(isAwaitingTakeoverConfirmation)"
                    )
                }
            case .confirmationPendingAfterRecoveryClearedBusy:
                if isBusy || !isAwaitingTakeoverConfirmation {
                    assertionFailure(
                        "takeoverAttemptState=\(takeoverAttemptState) but isBusy=\(isBusy) isAwaitingTakeoverConfirmation=\(isAwaitingTakeoverConfirmation)"
                    )
                }
            case .sendingAfterRecoveryClearedConfirmation:
                if !isBusy || isAwaitingTakeoverConfirmation {
                    assertionFailure(
                        "takeoverAttemptState=\(takeoverAttemptState) but isBusy=\(isBusy) isAwaitingTakeoverConfirmation=\(isAwaitingTakeoverConfirmation)"
                    )
                }
            }
            switch ownershipSyncState {
            case .idle:
                if isOwnershipSynchronizationScheduled || isSynchronizingOwnership {
                    assertionFailure(
                        "ownershipSyncState=\(ownershipSyncState) but isOwnershipSynchronizationScheduled=\(isOwnershipSynchronizationScheduled) isSynchronizingOwnership=\(isSynchronizingOwnership)"
                    )
                }
            case .scheduled:
                if !isOwnershipSynchronizationScheduled || isSynchronizingOwnership {
                    assertionFailure(
                        "ownershipSyncState=\(ownershipSyncState) but isOwnershipSynchronizationScheduled=\(isOwnershipSynchronizationScheduled) isSynchronizingOwnership=\(isSynchronizingOwnership)"
                    )
                }
            case .running:
                if !isOwnershipSynchronizationScheduled || !isSynchronizingOwnership {
                    assertionFailure(
                        "ownershipSyncState=\(ownershipSyncState) but isOwnershipSynchronizationScheduled=\(isOwnershipSynchronizationScheduled) isSynchronizingOwnership=\(isSynchronizingOwnership)"
                    )
                }
            }
            switch sceneState {
            case .active(let resume):
                if !isSceneActive || (resume == .pending) != isForegroundResumeEvaluationPending {
                    assertionFailure(
                        "sceneState=\(sceneState) but isSceneActive=\(isSceneActive) isForegroundResumeEvaluationPending=\(isForegroundResumeEvaluationPending)"
                    )
                }
            case .backgrounded(let resume):
                if isSceneActive || (resume == .pending) != isForegroundResumeEvaluationPending {
                    assertionFailure(
                        "sceneState=\(sceneState) but isSceneActive=\(isSceneActive) isForegroundResumeEvaluationPending=\(isForegroundResumeEvaluationPending)"
                    )
                }
            }
        #endif
    }

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
        stateSubmissionLifecycles[submittedStateCount] = viewerAttachmentLifecycle
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
            sessionID: session.id, reason: TerminalRemoteSessionStateReason.initial.rawValue, emittedAt: "2026-01-01T00:00:00Z",
            sessionStateRevision: nil, sessionStateFlags: nil, screenStateRevision: nil, runtimeState: runtime,
            attachmentSnapshot: TerminalSessionAttachmentSnapshot(clients: [remoteClient], attachments: [ownerAttachment]), title: session.title,
            workingDirectory: session.workingDirectory, outputByteCount: 0)
        await applyLatestState(payload, isOutOfBand: false)
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
        ownershipSyncState = .idle
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
        assertShadowConsistency()
    }
}
