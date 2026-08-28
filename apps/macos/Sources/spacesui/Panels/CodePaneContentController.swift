import AppKit
import WebKit
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import spacesterminalghostty

/// The Editor pane's current view: reviewing working-tree changes, or editing a file. An explicit
/// Editor navigation starts in `.diff`; ordinary controller replacement and app relaunch restore the
/// workspace-local mode.
enum CodePaneMode: Equatable, Sendable {
    case diff
    case editor
}

/// Whether a controller is being built for an explicit Editor navigation or only to restore an
/// existing pane. The requested mode is authoritative only for navigation; recovery otherwise keeps
/// the user's last mode alongside the rest of the workspace-local snapshot.
enum CodePaneInitialModePolicy: Equatable, Sendable {
    case useRequestedMode
    case restoreWorkspaceMode
}

/// Code-pane implementation of `PaneContentHosting`: a diff/editor surface backed by a `WKWebView`
/// running the bundle in `Resources/CodePane` (see `CodePaneWeb/README.md` for the wire protocol
/// this implements). All bridge decode/mapping/JS-generation logic lives in `CodePaneBridge`; this
/// controller only owns the `WKWebView`, the `WKScriptMessageHandler`, and the actual
/// `SpacesDeviceClient` calls the web app's RPCs resolve to.
///
/// Hibernation seam: `contentView` (`rootView`) is a plain container that survives for the
/// controller's whole lifetime, so the pane tree can re-parent it across layout rebuilds without
/// recreating the controller — exactly like a terminal pane's view. The `WKWebView` itself is the
/// expensive resource: `activate()` creates it (installing the message handler and loading the
/// bundle fresh), `deactivate()` tears it down (removing the handler and stopping the live
/// diff-signature subscription). A hidden tab therefore holds no live web process and no open
/// daemon stream; showing the pane again pays a fresh page load and a fresh `ready` handshake.
@MainActor final class CodePaneContentController: NSObject, PaneContentHosting {
    /// Keeps the exact page that started a teardown collection alive until WebKit returns the page's
    /// final recovery snapshot. `teardownWebView()` releases its regular references immediately so a
    /// hidden pane does not retain a web process, but WebKit's asynchronous callback still requires
    /// both the concrete view and its evaluator to remain alive until that one collection settles.
    private final class TeardownWorkspaceStateCollector {
        let webView: WKWebView
        let scriptEvaluator: any CodePaneScriptEvaluator

        init(webView: WKWebView, scriptEvaluator: any CodePaneScriptEvaluator) {
            self.webView = webView
            self.scriptEvaluator = scriptEvaluator
        }
    }

    private static let messageHandlerName = "spacesBridge"
    private static let initEventName = "spaces:init"
    private static let themeEventName = "spaces:theme"
    private static let diffSignatureEventName = "spaces:diffSignature"
    private static let fileSignatureEventName = "spaces:fileSignature"
    private static let agentsEventName = "spaces:agents"
    private static let agentStartStatusEventName = "spaces:agentStartStatus"
    private static let setModeEventName = "spaces:setMode"

    let descriptor: PaneContentDescriptor
    let initialMode: CodePaneMode
    /// This pane's id — a code pane's only identity (see `PanelCoordinator.codePaneControllers`).
    let paneID: String
    let workspaceID: String

    private let rootView = NSView()
    private var webView: WKWebView?
    /// Where a reply or pushed event is actually sent. Kept in lockstep with `webView` in production —
    /// set together in `installWebView()`, cleared together in `teardownWebView()` — so this is
    /// always the live page's evaluator there. Not `private`: a test substitutes a recording double
    /// here, after the real `activate()`/`deactivate()` lifecycle has run for real, to observe exactly
    /// what a reply would have evaluated without needing the bundle's JS to run (see
    /// `CodePaneScriptEvaluator`'s doc comment for why this seam exists at all).
    var scriptEvaluator: (any CodePaneScriptEvaluator)?
    /// Weak: a test double's lifetime isn't guaranteed to outlive this controller, and a live
    /// `AppKitController` outlives every pane it hosts anyway, so `nil` here just means "treat this
    /// like the device being unavailable" rather than something to force-unwrap.
    private weak var hosting: (any CodePaneHosting)?
    private let deviceGateway: any CodePaneDeviceGateway
    /// The durable, client-local home for workspace state. It is separate from `hosting` because
    /// unsaved source and view state must never become daemon-synchronized workspace data.
    private let workspaceStateStore: any CodePaneWorkspaceStateStoring
    /// Ordered write-behind for `workspaceStateStore`. It owns the expensive JSON encoding and
    /// SQLite write, while this controller remains the main-actor authority for the live snapshot.
    private let workspaceStatePersistence: CodePaneWorkspaceStatePersistence
    /// Guards this short-lived controller's writes against an outgoing controller for the same
    /// workspace. See `CodePaneWorkspaceStateHandoff` for the A → B → A handoff contract.
    private let workspaceStateOwner: CodePaneWorkspaceStateHandoff.Owner

    /// Set once the web app's `ready` message arrives; the host must wait for it before dispatching
    /// `spaces:init` (see README) and must not push `spaces:theme`/`spaces:diffSignature` before
    /// the page has a listener attached for them either.
    private(set) var isReady = false
    private var currentTheme: ThemeAppearance?
    /// The running-agent set last pushed via `spaces:agents` (or folded into the pending
    /// `spaces:init` payload before the page was ready) — `nil` until the first push/init, so the
    /// first call after activation always sends. Not reset on hibernation: the running-agent set is a
    /// fact about the workspace, not the page, so a reactivated pane's `spaces:init` should reuse
    /// whatever was last known rather than re-querying and potentially re-sending the same set as if
    /// it were new (mirrors `currentTheme`, which is the same kind of workspace/app-level fact).
    private var currentAgents: [CodePaneRunningAgent]?

    /// Pending Start Agent commands keyed by the terminal session their immediate response created.
    /// The native observer is tied to the visible Editor page; hibernation/retarget cancels it and a
    /// returned page reconciles the persisted session exactly once before it can report a timeout.
    /// The gateway uses the same overview payload for local and remote devices.
    private var agentStartTasks: [String: Task<Void, Never>] = [:]
    private var agentStartTaskGenerations: [String: Int] = [:]
    private var nextAgentStartTaskGeneration = 0
    /// Mirrors the established `spaces agent spawn` readiness budget. Tests shorten both values rather
    /// than introducing a product-facing timing option.
    var agentStartReadinessTimeout: TimeInterval = 90
    var agentStartPollInterval: Duration = .seconds(1)
    var agentStartNow: () -> Date = Date.init

    /// Bumped every time `installWebView()` creates a fresh page. The web app's own JS request-id
    /// counter (`realBridge.ts`) restarts at 1 on every page load, so an id alone can't disambiguate a
    /// reply meant for a hibernation cycle's torn-down page from one meant for the page that replaced
    /// it. `dispatch(_:)` captures the generation live at the moment a request arrives and threads it
    /// through to `reply(id:generation:...)`, which drops the reply once the page has moved on.
    private var pageGeneration = 0

    /// Bumped on every initial `workspaceDiffManifestChunk` call; the captured value lets only the
    /// latest request's final metadata chunk retarget the live diff-signature stream
    /// (`resubscribeDiffSignature`). This is a different concern from `pageGeneration` above: a stale
    /// diff response's JS reply must still always go out (the web side matches replies by id and
    /// doesn't care which scope is "current"), but pointing the shared stream at a scope the user has
    /// already navigated away from would visibly regress the live view even on the very same page.
    private var latestDiffRequestToken = 0

    /// The (workspace, ref) scope the live diff-signature stream is pointed at. Every initial `workspaceDiffManifestChunk`
    /// call is the signal to (re)point this: `realBridge.ts`'s `subscribeDiffSignature` never messages
    /// Swift at all (see its doc comment), so the resolved scope of each diff fetch is the only place
    /// scope changes are observable from the host side. Also cleared by an actual stream disconnect
    /// (see `handleDiffSignatureDisconnect`), so a same-scope `workspaceDiffManifestChunk` after a daemon restart
    /// resubscribes instead of silently no-op'ing forever.
    private enum DiffSignatureScope: Equatable {
        case none
        case scope(refName: String?, lastCommit: Bool)
    }
    private var subscribedScope: DiffSignatureScope = .none
    /// The `scopeSignature` of the last diff the web app is known to have fetched for the current
    /// scope — set when the final `workspaceDiffManifestChunk` reply for the still-current request is delivered (see
    /// `performWorkspaceDiffManifestChunk`), paired with the scope it was recorded for so a resubscribe that
    /// targets a different scope can tell it's stale (defensive: in practice `performWorkspaceDiffManifestChunk`
    /// always refreshes both before `resubscribeDiffSignature` runs for the new scope, so this branch
    /// is not expected to fire — see `handleDiffSignatureFrame`). `nil` (both) means "no diff fetched
    /// yet for any scope this pane life has subscribed to" — a frame always forwards in that state.
    private var lastActedScopeSignature: String?
    private var lastActedScope: DiffSignatureScope = .none
    private var diffSignatureStream: (any CodePaneDiffSignatureStreamHandle)?
    /// Bumped at the top of every real (non-no-op) `resubscribeDiffSignature` call and captured by
    /// that call's `onDisconnect` closure, so a disconnect belonging to a subscription that a newer
    /// resubscribe already superseded can't clobber the newer subscription's state — a stale client
    /// can disconnect at any time, including after it has already been replaced.
    private var diffSignatureSubscriptionGeneration = 0
    /// Consecutive disconnects/failed-resubscribe-attempts since the last successful resubscribe;
    /// the exponent behind `scheduleDiffSignatureReconnect`'s backoff. Reset to 0 whenever a
    /// subscription actually opens (`resubscribeDiffSignature`'s success arm) or the pane hibernates
    /// (`teardownWebView`) — a fresh pane life starts its own curve from the floor.
    private var diffSignatureReconnectFailures = 0
    /// Floor of the diff-signature stream's reconnect backoff (the delay before the first retry after
    /// a disconnect). Internal, not private, so a test can pin this to a short delay instead of
    /// waiting out real seconds — see `CodePaneContentControllerTests`.
    var diffSignatureReconnectFloor: Duration = .seconds(1)
    /// Ceiling of the backoff: a device that stays unreachable settles into a slow, indefinite probe
    /// rather than being redialed every second for as long as the pane stays open. Internal for the
    /// same reason as the floor above.
    var diffSignatureReconnectCap: Duration = .seconds(30)

    /// Bumped on every `workspaceFileRead` call whose dispatch is a NAVIGATION — i.e. it changes which
    /// path the pane is showing (`pathChanged == true`), as opposed to a same-path reread of the file
    /// already open (e.g. `EditorView.handleExternalChange`'s live-reload re-read after a
    /// `spaces:fileSignature` push). `performFileRead` captures this as `navToken` at dispatch time and
    /// its success arm checks it before letting a navigation's completion (re)point
    /// `resubscribeFileSignature` at its path — deliberately narrower than `latestDiffRequestToken`
    /// (which every diff fetch bumps): a same-path reread must NOT bump this, or a slower navigation to
    /// a different path in flight at the same time would see its own already-captured token look stale
    /// once the reread bumps past it. A same-path reread's completion is instead guarded by
    /// `subscribedFilePath == path` — see `performFileRead`'s success-arm comment for the full set of
    /// interleavings this two-branch scheme closes (this replaced a single request-token guard that
    /// covered every read indiscriminately and could let a stale reread's completion resubscribe the
    /// stream to the wrong file after a navigation had already moved on).
    private var latestFileNavigationToken = 0

    /// The workspace-relative path the live file-signature stream is pointed at, or `nil` when nothing
    /// is subscribed. Unlike `DiffSignatureScope`, a plain `String?` is enough here: a path (unlike a
    /// `refName`) is never itself a legitimate "no scope" value, so `nil` unambiguously means "not
    /// subscribed" rather than needing a wrapper case. Every `workspaceFileRead` call is the signal to
    /// (re)point this — mirrors `subscribedScope`'s doc comment exactly, substituting
    /// `subscribeFileSignature`'s architecture (the web app's bridge method never messages Swift; see
    /// `CodePaneWeb/src/bridge/realBridge.ts`'s doc comment) for `subscribeDiffSignature`'s.
    private var subscribedFilePath: String?

    /// Mirrors `SpacesDeviceAPIServer.WorkspaceFileSignatureValue`: Swift tuples aren't `Equatable`, and
    /// this needs to be compared as a whole (`sha256` alone can't distinguish "still missing" from "a
    /// brand-new empty file", so both fields matter) to decide whether to forward a frame.
    private struct FileSignatureValue: Equatable {
        let sha256: String?
        let missing: Bool
    }
    /// The `(sha256, missing)` pair of the last file read the web app is known to have fetched for the
    /// current path — mirrors `lastActedScopeSignature`/`lastActedScope` exactly.
    private var lastActedFileSignatureValue: FileSignatureValue?
    private var lastActedFilePath: String?
    private var fileSignatureStream: (any CodePaneFileSignatureStreamHandle)?
    /// Mirrors `diffSignatureSubscriptionGeneration` exactly.
    private var fileSignatureSubscriptionGeneration = 0
    /// Mirrors `diffSignatureReconnectFailures` exactly.
    private var fileSignatureReconnectFailures = 0
    /// Mirrors `diffSignatureReconnectFloor`/`diffSignatureReconnectCap` exactly — internal so a test
    /// can pin these to a short delay too.
    var fileSignatureReconnectFloor: Duration = .seconds(1)
    var fileSignatureReconnectCap: Duration = .seconds(30)

    /// The open-editor buffer held inside the complete workspace recovery snapshot.
    private var editorState: CodePaneBridge.EditorState?
    /// A stale page's asynchronous teardown collection must never replace a later page's complete
    /// recovery snapshot.
    private var workspaceStateGeneration = 0
    /// `close()` is nonblocking, but its final WebKit collection is part of the close operation: the
    /// callback retains this controller until it has applied the page's last complete snapshot. A
    /// termination caller appends a finalizer which drains durable persistence only after that same
    /// collection has settled.
    private var closeStarted = false
    private var closeFinalizers: [() -> Void] = []
    /// The final WebKit callback retains the controller while it is pending, but mutation tasks hold
    /// it weakly. Keep the close handoff alive after that callback until every mutation has refined
    /// the final snapshot and released the workspace owner.
    private var closeLifetimeRetainer: CodePaneContentController?
    /// The normal `webView`/`scriptEvaluator` properties are cleared as soon as a pane hibernates.
    /// Keep each old pair here only while its complete-state collection is outstanding, then remove it
    /// from the callback that settles the corresponding flush.
    private var teardownWorkspaceStateCollectors: [Int: TeardownWorkspaceStateCollector] = [:]
    private var nextTeardownWorkspaceStateCollectorID = 0
    /// A replacement for this workspace waits for an older controller's asynchronous collector
    /// before building `spaces:init`; otherwise A → B → A can rehydrate A from stale cache.
    private var waitingForWorkspaceStateHandoff = false

    /// The most recently committed `workspaceFileWrite` outcome, used to fold that write into a
    /// teardown-flushed `editorState` snapshot that still carries the pre-write baseline — see
    /// `adoptCommittedWriteIntoEditorState`. It lives only for the duration of the write/flush
    /// race it bridges — cleared by `clearCommittedFileWriteIfSettled()` once both
    /// `outstandingFileWriteCount` and `outstandingTeardownFlushCount` are back at zero. The CAS-chain
    /// guard inside `adoptCommittedWriteIntoEditorState` is not sufficient on its own across time:
    /// hashes can recur (an ABA hazard — see `clearCommittedFileWriteIfSettled`'s doc comment for the
    /// full scenario), so the record must not survive past the race window it exists to bridge.
    private var lastCommittedFileWrite: (path: String, expectedBase: String?, sha256: String, content: String, pageGeneration: Int)?

    /// Clears `lastCommittedFileWrite` once neither an in-flight `workspaceFileWrite` nor an in-flight
    /// teardown flush remains outstanding — i.e. once every party that could legitimately consume the
    /// record to bridge their settle-order race against each other has already had its adoption attempt
    /// (see `adoptCommittedWriteIntoEditorState`'s doc comment for the two call sites and why both are
    /// needed). Once both counters are back at zero, the CAS-chain guard alone is NOT sufficient to keep
    /// a stale record inert across time: hash values can recur — a save from H0 records
    /// `(expectedBase: H0, sha256: H1, content: C1)`, a later `git checkout` (or an agent revert)
    /// restores disk to H0, the live pane reloads cleanly at baseline H0, the user types (dirty), and a
    /// later teardown flush stores a snapshot with `baseSHA256 == H0` — the stale record would still
    /// match that guard and wrongly rewrite the snapshot to the false H1/C1 ancestry (an ABA hazard), so
    /// the record must not survive past the race window it was created to bridge.
    ///
    /// Safe to call unconditionally at every settlement site: a flush or write that starts after this
    /// point can never legitimately need the cleared record anyway — `evaluateJavaScript` calls execute
    /// in issue order and a write's success reply is issued before any subsequent flush's collect, so a
    /// later flush's snapshot already carries the post-save baseline on its own.
    private func clearCommittedFileWriteIfSettled() {
        if outstandingFileWriteCount == 0, outstandingTeardownFlushCount == 0 { lastCommittedFileWrite = nil }
    }

    /// The web app's last-known teardown snapshot of comment text typed but not yet
    /// persisted (see `CodePaneBridge.ReviewCommentEntryPayload`) — mirrors `editorState` above exactly,
    /// including its lifecycle (survives `deactivate()`, discarded by `close()`) and its rehydration
    /// via `spaces:init`'s `pendingReviewComments` field. `nil` means "nothing pending", the same
    /// meaning as the `'__none__'` sentinel on the wire.
    ///
    /// A CREATE upsert (`commentID == nil`) that completes after this snapshot was taken corrects the
    /// snapshot's matching provisional entry before any deferred `ready` resumes, so the replacement
    /// page's `spaces:init` doesn't replay it as a duplicate of the row `loadInitial()` will already
    /// list: dropped entirely if the create's committed body already matches the snapshot entry's body
    /// (the listed row already carries this text), or rewritten in place as non-provisional with the
    /// server-assigned id if the snapshot's body has since diverged (the user kept typing after the
    /// create's RPC went out, so the snapshot's newer text is what should overlay the listed row). See
    /// `reconcilePendingReviewCommentStateAfterCreate(comment:)`.
    private var pendingReviewCommentState: [CodePaneBridge.ReviewCommentEntryPayload]?
    /// Count of complete workspace-state teardown collections not yet answered. Bumped when the
    /// collector starts and decremented once its completion applies (or discards) its result.
    /// `handleReady()` reads this to know whether a flush from the just-torn-down page could still
    /// overwrite the complete recovery state with fresher content than
    /// whatever is on hand right now — see `deferredReadyGeneration` below for why that matters. A
    /// counter, not a flag, because a pane can in principle rack up more than one outstanding flush
    /// (teardown → reactivate → teardown again, all before the first flush's `evaluateJavaScript` round
    /// trip returns); `handleReady()`
    /// must wait for all of them, not just the most recent. `evaluateJavaScript` (what
    /// `evaluateCodePaneScript` wraps) always calls its completion, success or failure, so this is
    /// guaranteed to return to zero and never strands a deferred `ready` forever. Folded into one
    /// counter (renamed from `outstandingEditorFlushCount`) rather than tracked separately per flush
    /// kind: every flush gates the exact same `ready` decision, so one shared count is the cleaner
    /// mirror and there is nothing any one flush kind needs to know about another's count.
    private var outstandingTeardownFlushCount = 0
    /// Count of in-flight review-comment mutation RPCs (`reviewCommentUpsert`/
    /// `reviewCommentDelete`/`reviewCommentsSend`) — kept separate from `outstandingTeardownFlushCount`
    /// above rather than folded into it, since this counts a different thing (an RPC round trip to the
    /// daemon, not a teardown flush) even though both gate the same `ready` decision below. Bumped
    /// right before each RPC's `Task` starts, decremented — unconditionally, success or failure — in its
    /// completion, mirroring the teardown flush's own unconditional decrement. `handleReady()`/
    /// `resumeDeferredReadyIfNeeded()` also wait for this to reach zero: answering `ready` while a send/
    /// upsert/delete is still in flight would let the web app's rehydrated comment state (from
    /// `pendingReviewCommentState`, or the next `loadInitial()`) race the mutation's own effect on the
    /// daemon. See the tradeoff noted at each `perform*` call site below.
    private var outstandingReviewCommentMutationCount = 0
    /// Count of in-flight `workspaceFileWrite` RPCs. A write outstanding at `ready` time can
    /// still change what `editorState` should read once it completes — its completion adopts the
    /// committed baseline into the flushed snapshot (see `adoptCommittedWriteIntoEditorState`), and
    /// answering `ready` first would rehydrate the page against the pre-save baseline, making it treat
    /// its own save as an external change (a false diff3 merge or conflict banner — the fresh page has
    /// no `pendingSaveSubmitted` to recognize its own just-landed save). Mirrors
    /// `outstandingReviewCommentMutationCount` exactly: bumped right before the RPC's `Task` starts,
    /// decremented — unconditionally, success or failure — in its completion.
    private var outstandingFileWriteCount = 0
    /// A Start Agent request can create a terminal after its page has closed. It therefore shares the
    /// close handoff fence: releasing the owner first would lose the session association needed to
    /// resume tracking from the replacement pane or after app restart.
    private var outstandingStartWorkspaceCommandCount = 0

    /// Owner release has the same recovery ordering requirement as `ready`: the final WebKit
    /// collection and every mutation that can refine it must settle before a replacement may restore
    /// the workspace or termination may drain persistence.
    private var closeLifecycleWorkIsSettled: Bool {
        outstandingTeardownFlushCount == 0 && outstandingReviewCommentMutationCount == 0 && outstandingFileWriteCount == 0
            && outstandingStartWorkspaceCommandCount == 0
    }

    /// The page generation `handleReady()` was called for when it deferred sending `spaces:init`
    /// because `outstandingTeardownFlushCount`/`outstandingReviewCommentMutationCount`/
    /// `outstandingFileWriteCount` was nonzero —
    /// `nil` when nothing is deferred. Sending init immediately in that state would ship the stale
    /// pre-flush `editorState`/`pendingReviewCommentState`, and once the flush's completion did land,
    /// `storeFlushedWorkspaceState`'s `generation >= workspaceStateGeneration` guard would silently drop
    /// it (this page's own activity can
    /// have already moved the generation past the flush's captured value), losing the just-typed
    /// content for good rather than merely delaying it. Re-checked against `pageGeneration` when the
    /// last outstanding flush/mutation finally settles (`resumeDeferredReadyIfNeeded`), since the page
    /// that was waiting can itself be torn down again before that happens. Only the newest deferral is
    /// ever kept: a second `ready` arriving while one is already pending can only be from a newer page
    /// (a same-page repeat is blocked by `isReady`), so overwriting here is correct — there is nothing
    /// to queue.
    private var deferredReadyGeneration: Int?

    /// The pane's live mode, distinct from the immutable `initialMode` it was constructed with: the
    /// user can toggle Diff/Editor from the in-page toolbar afterward, and this tracks wherever
    /// they left it (via the complete `workspaceStateChanged` notification). Survives hibernation
    /// like `editorState` above (cleared only by `close()`), so a pane hibernated in Editor mode
    /// comes back in Editor mode instead of resetting to whichever mode originally created it.
    private var currentMode: CodePaneMode
    /// An explicit global-Editor navigation starts in its requested mode. It is retained only until a
    /// delayed outgoing collector has handed off the target workspace's complete snapshot, so that
    /// collector restores every other field without overriding the navigation mode.
    private let forcedInitialMode: CodePaneMode?
    /// Navigation may select a mode while a returning page is waiting for an older controller's
    /// final collection. It is an intent, not a complete snapshot: persisting it immediately would
    /// make the replacement authoritative and discard the collector's newer dirty buffer. Once the
    /// handoff finishes, the intent is overlaid onto that complete snapshot and persisted together.
    private var preReadyRequestedMode: CodePaneMode?
    /// The rest of the workspace-local snapshot, separate from `currentMode` only because the
    /// controller still needs a convenient native mode enum for panel navigation.
    private var currentScope: CodePaneBridge.WorkspaceState.Scope
    private var diffLayout: String
    private var diffSelectedPath: String?
    private var diffTreeExpandedPaths: [String]?
    private var diffTreeSelectedPath: String?
    private var fileTreeExpandedPaths: [String]
    private var fileTreeSelectedPath: String?
    private var editorSidebarMode: String
    private var editorRecentPaths: [String]
    private var diffScrollLine: Int?
    private var diffScrollSide: String?
    private var diffFocusedPath: String?
    private var diffFocusedLine: Int?
    private var diffFocusedSide: String?
    private var editorScrollLine: Int?
    private var editorFocusedLine: Int?
    private var diffEditorState: CodePaneBridge.DiffEditorState?
    /// Kept independently from the current agent list so app restart can restore the user's explicit
    /// assignment, then pruned as soon as the owning session is no longer a running hook-backed agent.
    private var selectedAgentSessionId: String?
    /// A command launch survives hibernation/restart. `.starting` causes the web app to ask native to
    /// resume observing the terminal; `.failed` preserves the typed command and explanatory status.
    private var pendingAgentLaunch: CodePaneBridge.PendingAgentLaunch?

    var onTitleChanged: ((String) -> Void)?

    init(
        paneID: String, deviceID: String, workspaceID: String, initialMode: CodePaneMode, hosting: any CodePaneHosting,
        initialModePolicy: CodePaneInitialModePolicy = .useRequestedMode,
        deviceGateway: any CodePaneDeviceGateway = LiveCodePaneDeviceGateway(), workspaceStateStore: (any CodePaneWorkspaceStateStoring)? = nil
    ) {
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.descriptor = .codePane(deviceID: deviceID, workspaceID: workspaceID)
        let workspaceStateStore = workspaceStateStore ?? ClientCodePaneWorkspaceStateStorage(deviceID: deviceID)
        let restoredState = Self.loadWorkspaceState(from: workspaceStateStore, workspaceID: workspaceID)
        self.initialMode = initialMode
        switch initialModePolicy {
        case .useRequestedMode:
            currentMode = initialMode
            forcedInitialMode = initialMode
        case .restoreWorkspaceMode:
            currentMode = restoredState?.codePaneMode ?? initialMode
            forcedInitialMode = nil
        }
        self.currentScope = restoredState?.scope ?? .uncommitted
        self.diffLayout = restoredState?.diffLayout ?? "unified"
        self.diffSelectedPath = restoredState?.diffSelectedPath
        self.diffTreeExpandedPaths = restoredState?.diffTreeExpandedPaths
        self.diffTreeSelectedPath = restoredState?.diffTreeSelectedPath
        self.fileTreeExpandedPaths = restoredState?.fileTreeExpandedPaths ?? []
        self.fileTreeSelectedPath = restoredState?.fileTreeSelectedPath
        self.editorSidebarMode = restoredState?.editorSidebarMode ?? "files"
        self.editorRecentPaths = restoredState?.editorRecentPaths ?? []
        self.diffScrollLine = restoredState?.diffScrollLine
        self.diffScrollSide = restoredState?.diffScrollSide
        self.diffFocusedPath = restoredState?.diffFocusedPath
        self.diffFocusedLine = restoredState?.diffFocusedLine
        self.diffFocusedSide = restoredState?.diffFocusedSide
        self.editorScrollLine = restoredState?.editorScrollLine
        self.editorFocusedLine = restoredState?.editorFocusedLine
        self.diffEditorState = restoredState?.diffEditorState
        self.selectedAgentSessionId = restoredState?.selectedAgentSessionId
        self.pendingAgentLaunch = restoredState?.pendingAgentLaunch
        self.hosting = hosting
        self.deviceGateway = deviceGateway
        self.workspaceStateStore = workspaceStateStore
        workspaceStateOwner = CodePaneWorkspaceStateHandoff.claimOwner(
            storageKey: workspaceStateStore.workspaceStateStorageKey, workspaceID: workspaceID)
        workspaceStatePersistence = CodePaneWorkspaceStatePersistence(
            label: "spaces.code-pane.workspace-state.\(deviceID).\(workspaceID)", storageKey: workspaceStateStore.workspaceStateStorageKey,
            write: { [workspaceStateStore] stateJSON, workspaceID in
                // Persistence is recovery-only. A failure leaves this launch's in-memory snapshot
                // authoritative and must not interfere with editing or pane navigation.
                try? workspaceStateStore.setStateJSON(stateJSON, workspaceID: workspaceID)
            })
        editorState = restoredState?.editorState
        pendingReviewCommentState = restoredState?.pendingReviewComments
        super.init()
        rootView.wantsLayer = true
        rootView.setAccessibilityIdentifier("code-pane-\(paneID)")
        bindAppearanceReactiveLayer(rootView) { view in view.layer?.backgroundColor = NSColor.activeTheme(\.terminal.background).cgColor }
    }

    var contentView: NSView { rootView }
    /// "Editor — <workspace name>" for every code pane, not only ones in a global panel window's
    /// retargeting monitor: a workspace panel's code pane already reads unambiguously from its tab
    /// bar's own workspace context, but a uniform title is simpler than a scope-conditional one and
    /// still correct there, and it is what a monitor's retarget needs to actually change when it
    /// swaps workspaces (see `PanelCoordinator.retargetGlobalWindowCodePanes`). Falls back to the raw
    /// workspace id, mirroring `sendInitPayload`'s `workspaceName` resolution, for the brief window
    /// before the workspace's overview data has loaded.
    var displayTitle: String {
        let workspaceName = hosting?.codePaneWorkspaceInfo(workspaceID: workspaceID)?.name ?? workspaceID
        return "Editor — \(workspaceName)"
    }

    func activate(focus: Bool) {
        if webView == nil { installWebView() }
        if focus { _ = makeContentFirstResponder() }
    }

    /// Tears the web view down; `rootView` is left in place so the pane tree keeps a stable view to
    /// re-parent the next time this pane becomes visible. `editorState`/`currentMode` are left
    /// untouched — hibernation must not lose them (see their doc comments).
    func deactivate() { teardownWebView() }

    /// The pane itself is going away. The final WebKit collection remains live until its callback
    /// supplies the page's latest complete snapshot; this method itself stays nonblocking.
    func close() { beginClose(finalizer: nil) }

    /// App termination supplies the only synchronous durable fence. It runs after the asynchronous
    /// page collection has applied and enqueued the final document, never before it. The fence is
    /// app-wide because a retarget may already have detached another controller with a live collector.
    func closeForTermination(completion: @escaping () -> Void) {
        beginClose {
            CodePaneWorkspaceStatePersistence.finishTermination(completion)
        }
    }

    private func beginClose(finalizer: (() -> Void)?) {
        if let finalizer {
            if closeStarted, closeLifecycleWorkIsSettled {
                finalizer()
                return
            }
            closeFinalizers.append(finalizer)
        }
        guard !closeStarted else { return }
        closeStarted = true
        closeLifetimeRetainer = self
        CodePaneWorkspaceStateHandoff.collectorStarted(
            storageKey: workspaceStateStore.workspaceStateStorageKey, workspaceID: workspaceID)
        teardownWebView()
        finishCloseIfReady()
    }

    private func finishCloseIfReady() {
        guard closeStarted, closeLifecycleWorkIsSettled else { return }
        persistWorkspaceState(fromOutgoingHandoff: true)
        CodePaneWorkspaceStateHandoff.releaseOwner(workspaceStateOwner)
        editorState = nil
        pendingReviewCommentState = nil
        diffEditorState = nil
        currentMode = initialMode
        let finalizers = closeFinalizers
        closeFinalizers.removeAll()
        for finalizer in finalizers { finalizer() }
        CodePaneWorkspaceStateHandoff.collectorFinished(
            storageKey: workspaceStateStore.workspaceStateStorageKey, workspaceID: workspaceID)
        closeLifetimeRetainer = nil
    }

    private func settleFileWrite() {
        outstandingFileWriteCount -= 1
        clearCommittedFileWriteIfSettled()
        finishCloseIfReady()
        resumeDeferredReadyIfNeeded()
    }

    private func settleReviewCommentMutation() {
        outstandingReviewCommentMutationCount -= 1
        finishCloseIfReady()
        resumeDeferredReadyIfNeeded()
    }

    private func settleStartWorkspaceCommand() {
        outstandingStartWorkspaceCommandCount -= 1
        finishCloseIfReady()
        resumeDeferredReadyIfNeeded()
    }

    @discardableResult func makeContentFirstResponder() -> Bool {
        guard let webView else { return false }
        return webView.window?.makeFirstResponder(webView) ?? false
    }

    func owns(responder: NSResponder) -> Bool {
        guard let webView, let view = responder as? NSView else { return false }
        return view === webView || view.isDescendant(of: webView)
    }

    /// The web view handles its own keyboard input (typing, its native find, etc.) through the
    /// ordinary AppKit responder chain, so this controller never intercepts a key event itself —
    /// there is no Ghostty-style translation layer to run the way a terminal pane's does.
    func handleKeyEvent(_ event: NSEvent) -> Bool { false }
    func handleCommandKeyEquivalent(_ event: NSEvent) -> Bool { false }

    /// Called by `PanelCoordinator.broadcastAppearance` when the app's effective appearance
    /// changes. Not part of `PaneContentHosting` — see that method's doc comment for why this is a
    /// plain method the coordinator downcasts to, rather than a protocol requirement.
    func applyAppearance(_ appearance: ThemeAppearance) {
        guard currentTheme != appearance else { return }
        currentTheme = appearance
        guard isReady, let scriptEvaluator else { return }
        guard
            let script = CodePaneBridge.dispatchEventScript(
                name: Self.themeEventName, detail: CodePaneBridge.ThemePayload(theme: appearance.rawValue))
        else { return }
        scriptEvaluator.evaluateCodePaneScript(script)
    }

    /// Called by `PanelCoordinator.updateCodePaneAgents` whenever the host reprocesses an overview
    /// for this pane's device — the same overview-apply call sites that already call
    /// `pruneOpenCodePanes`. Dedupes on the full running-agent set (array equality) so a routine
    /// overview refresh that didn't touch this workspace's agents doesn't spam the page with a
    /// no-op push, mirroring `applyAppearance`'s `currentTheme` guard above.
    func applyRunningAgents(_ agents: [CodePaneRunningAgent]) {
        // The host installs a newly-started command through a synchronous overview apply. Hooks can
        // register before the start RPC's completion reaches the page, so publish that session only
        // after the keyed readiness observer has confirmed it. Otherwise the page has not received
        // `pendingAgentLaunch` yet and its one-agent auto-default would assign the not-yet-ready agent.
        let publishableAgents: [CodePaneRunningAgent]
        if let pendingAgentLaunch, pendingAgentLaunch.status == "starting" {
            publishableAgents = agents.filter { $0.sessionID != pendingAgentLaunch.sessionId }
        } else {
            publishableAgents = agents
        }
        let selectedAssignmentExpired = selectedAgentSessionId.map { selected in
            !publishableAgents.contains(where: { $0.sessionID == selected })
        } ?? false
        if selectedAssignmentExpired {
            selectedAgentSessionId = nil
            persistWorkspaceState()
        }
        guard currentAgents != publishableAgents else { return }
        currentAgents = publishableAgents
        guard isReady, let scriptEvaluator else { return }
        let payload = CodePaneBridge.AgentsPayload(
            agents: publishableAgents.map { CodePaneBridge.AgentPayload(id: $0.id, label: $0.label, sessionId: $0.sessionID) })
        guard let script = CodePaneBridge.dispatchEventScript(name: Self.agentsEventName, detail: payload) else { return }
        scriptEvaluator.evaluateCodePaneScript(script)
    }

    /// Pushes a mode switch into the page, or — if the page isn't live to receive a push — arranges
    /// for the pane's next load to open directly in `mode`. Called by `PanelCoordinator`'s navigation
    /// resolver to apply a reused/focused pane's requested mode (see docs/implementation.md).
    ///
    /// Deliberately does not set `currentMode` on the live-push path: `currentMode` is a
    /// single-source-of-truth mirror of the page's own live state (see its doc comment), fed only by
    /// the following complete `workspaceStateChanged` notification — this method just asks the page to
    /// switch, the same way a toolbar click does, and waits for that notification to confirm it landed. The not-live path
    /// (page torn down, or never loaded yet) has no page to echo back from, so it sets `currentMode`
    /// directly — exactly what `close()` already does when resetting to `initialMode`, and what
    /// `sendInitPayload` already reads (`currentMode`, not `initialMode`) to seed the next load.
    func requestMode(_ mode: CodePaneMode) {
        let waitingForOutgoingWorkspaceState = !isReady && CodePaneWorkspaceStateHandoff.hasOutstandingCollector(
            storageKey: workspaceStateStore.workspaceStateStorageKey, workspaceID: workspaceID)
        guard currentMode != mode || waitingForOutgoingWorkspaceState else { return }
        guard isReady, let scriptEvaluator else {
            currentMode = mode
            if waitingForOutgoingWorkspaceState {
                preReadyRequestedMode = mode
                return
            }
            persistWorkspaceState()
            return
        }
        guard
            let script = CodePaneBridge.dispatchEventScript(name: Self.setModeEventName, detail: CodePaneBridge.SetModePayload(mode: mode.wireValue))
        else { return }
        scriptEvaluator.evaluateCodePaneScript(script)
    }

    // MARK: - Web view lifecycle

    /// Resolves the built web bundle's `index.html` inside this package's resource bundle. A static
    /// helper (rather than inlined in `installWebView()`) so a test can assert it against the real,
    /// built `Bundle.module` without needing a `WKWebView` at all. This is the regression guard for
    /// the `.copy` resource's actual on-disk layout: `Package.swift`'s `spacesui` target declares
    /// `.copy("Resources/CodePane")`, and SwiftPM keeps only the LAST path component (`CodePane`)
    /// inside the built resource bundle, not the full source-relative path — confirmed by inspecting
    /// `spaces_spacesui.bundle/CodePane/index.html` in a built `.build` tree.
    static func codePaneIndexURL() -> URL? { Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "CodePane") }

    private func installWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: Self.messageHandlerName)
        // The built bundle's `index.html` loads its entry as `<script type="module" crossorigin>` plus
        // a `crossorigin` stylesheet, both of which are CORS-fetched. A `file://` load gives the page an
        // opaque origin, which WebKit blocks both requests against, so the module script and stylesheet
        // never run and the page renders blank. Registering `CodePaneSchemeHandler` on a custom scheme
        // instead gives the page a stable, non-opaque origin the module script, stylesheet, and any
        // Shiki dynamic-import chunks can all load same-origin from.
        let baseDirectory = Self.codePaneIndexURL()?.deletingLastPathComponent()
        if let baseDirectory {
            configuration.setURLSchemeHandler(CodePaneSchemeHandler(baseDirectory: baseDirectory), forURLScheme: CodePaneSchemeHandler.scheme)
        }
        let webView = WKWebView(frame: rootView.bounds, configuration: configuration)
        #if DEBUG
            // Lets Safari's Web Inspector attach to the code pane in dev builds, which is the only
            // way to probe the live page (computed styles, CSS variable resolution) inside the
            // shadow DOM the diff library renders into.
            webView.isInspectable = true
        #endif
        webView.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor), webView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: rootView.topAnchor), webView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])
        self.webView = webView
        scriptEvaluator = webView
        isReady = false
        pageGeneration += 1
        // The built web bundle is checked into the package as a `.copy` resource; it must always be
        // present in a built app, so there is nothing to fall back to if it's missing, and the page
        // just stays blank.
        if baseDirectory != nil { webView.load(URLRequest(url: CodePaneSchemeHandler.entryURL)) }
    }

    private func teardownWebView() {
        cancelAgentStartTracking()
        flushPendingWorkspaceState()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageHandlerName)
        webView?.removeFromSuperview()
        webView = nil
        scriptEvaluator = nil
        isReady = false
        diffSignatureStream?.stop()
        diffSignatureStream = nil
        subscribedScope = .none
        lastActedScopeSignature = nil
        lastActedScope = .none
        // Invalidates any in-flight reconnect backoff (see `scheduleDiffSignatureReconnect`): a
        // pending retry captured the generation that was live when it was scheduled, and hibernating
        // must stop it from resubscribing a pane the user is no longer looking at.
        diffSignatureSubscriptionGeneration += 1
        diffSignatureReconnectFailures = 0
        // Invalidates any in-flight diff fetch: without this, a completion that lands after
        // deactivate() still owns its token (the guard in `performWorkspaceDiffManifestChunk`'s completion would
        // pass) and would reopen a daemon subscription for a pane the user is no longer looking at —
        // and a fast reactivate could then inherit that stale stream ahead of its own fresh fetch.
        latestDiffRequestToken += 1
        // Mirrors the diff-signature reset block immediately above, for the file-signature stream.
        fileSignatureStream?.stop()
        fileSignatureStream = nil
        subscribedFilePath = nil
        lastActedFileSignatureValue = nil
        lastActedFilePath = nil
        fileSignatureSubscriptionGeneration += 1
        fileSignatureReconnectFailures = 0
        // Teardown is itself a "no path is active" transition: `subscribedFilePath = nil` above already
        // invalidates any outstanding same-path REREAD on its own (its guard checks
        // `subscribedFilePath == path`, which can never hold once it's `nil`), but a REREAD is only
        // half of `performFileRead`'s success-arm guard — an outstanding NAVIGATION checks
        // `latestFileNavigationToken` instead, which `subscribedFilePath` going `nil` does nothing to.
        // This bump is what invalidates that half: a navigation completing after this point must not
        // resubscribe a pane that has since hibernated.
        latestFileNavigationToken += 1
    }

    private func cancelAgentStartTracking() {
        for task in agentStartTasks.values { task.cancel() }
        agentStartTasks.removeAll()
        agentStartTaskGenerations.removeAll()
    }

    private func flushPendingWorkspaceState() {
        guard let webView, let scriptEvaluator else { return }
        let flushGeneration = pageGeneration
        nextTeardownWorkspaceStateCollectorID += 1
        let collectorID = nextTeardownWorkspaceStateCollectorID
        let collector = TeardownWorkspaceStateCollector(webView: webView, scriptEvaluator: scriptEvaluator)
        teardownWorkspaceStateCollectors[collectorID] = collector
        outstandingTeardownFlushCount += 1
        collector.scriptEvaluator.evaluateCodePaneScript(CodePaneBridge.collectWorkspaceStateScript) { [self] result in
            teardownWorkspaceStateCollectors.removeValue(forKey: collectorID)
            self.storeFlushedWorkspaceState(CodePaneBridge.decodeCollectedWorkspaceState(result), generation: flushGeneration)
            self.outstandingTeardownFlushCount -= 1
            self.clearCommittedFileWriteIfSettled()
            self.resumeDeferredReadyIfNeeded()
            self.finishCloseIfReady()
        }
    }

    /// Folds a committed write into either recovery buffer for the same file, so a page rehydrated
    /// after hibernation starts from the baseline its save established instead of treating itself as an
    /// external change. A matching CAS base proves the snapshot predates the write. A create write has
    /// no disk base; it is admitted only for a snapshot from the same page generation, which is the
    /// native proof that this is still the page that issued the write rather than a later replacement.
    /// The record's lifetime is bounded separately by
    /// `clearCommittedFileWriteIfSettled()` (see its doc comment for why the CAS-chain guard alone is
    /// not enough across time). Called from both the write completion and `storeFlushedWorkspaceState`,
    /// because the flush and the write settle in either order — patching only at completion would be overwritten by
    /// a later-arriving flush that stored the pre-write snapshot; patching only at flush time would miss
    /// a write that completes and commits its baseline AFTER the flush already stored a snapshot at
    /// that exact pre-write baseline.
    ///
    private func adoptCommittedWriteIntoEditorState() {
        guard let write = lastCommittedFileWrite else { return }
        func adoptEditor(_ state: CodePaneBridge.EditorState?) -> CodePaneBridge.EditorState? {
            guard let state, state.path == write.path else { return state }
            let matchesWrite = state.baseSHA256 == write.expectedBase ||
                (write.expectedBase == nil && write.pageGeneration == workspaceStateGeneration)
            guard matchesWrite else { return state }
            var newDirty = state.dirty
            var newConflict = state.conflict
            if state.content == write.content {
                // Nothing was typed after the save click: the buffer is exactly the committed content — a
                // clean file at the new baseline (this also covers a Keep-mine write that was in flight at
                // teardown: its snapshot's content IS the mine buffer it wrote).
                newDirty = false
                newConflict = false
            }
            // Post-click typing stays dirty against the committed baseline; this applies equally to
            // the standalone Editor and an inline Diff editor.
            return CodePaneBridge.EditorState(
                path: state.path, baseSHA256: write.sha256, baseContent: write.content, content: state.content, dirty: newDirty, conflict: newConflict)
        }
        func adoptDiffEditor(_ state: CodePaneBridge.DiffEditorState?) -> CodePaneBridge.DiffEditorState? {
            guard let state, state.path == write.path else { return state }
            let matchesWrite = state.baseSHA256 == write.expectedBase ||
                (write.expectedBase == nil && write.pageGeneration == workspaceStateGeneration)
            guard matchesWrite else { return state }
            var newDirty = state.dirty
            var newConflict = state.conflict
            if state.content == write.content {
                newDirty = false
                newConflict = false
            }
            // A successful write resolves any prior disk-vs-buffer comparison. If post-click
            // typing leaves the diff buffer dirty, its future conflict target is obtained by a
            // fresh comparison rather than carrying the old disk hash into a new baseline.
            return CodePaneBridge.DiffEditorState(
                path: state.path, baseSHA256: write.sha256, baseContent: write.content, content: state.content, dirty: newDirty,
                conflict: newConflict, conflictBaseSHA256: nil)
        }
        editorState = adoptEditor(editorState)
        diffEditorState = adoptDiffEditor(diffEditorState)
    }

    private func storeFlushedWorkspaceState(_ collected: CodePaneBridge.CollectedWorkspaceState, generation: Int) {
        guard generation >= workspaceStateGeneration else { return }
        switch collected {
        case .notReported: return
        case .none:
            editorState = nil
            diffEditorState = nil
            pendingReviewCommentState = nil
        case .state(let state): applyWorkspaceState(state)
        }
        workspaceStateGeneration = generation
        adoptCommittedWriteIntoEditorState()
        persistWorkspaceState(fromOutgoingHandoff: true)
    }

    // MARK: - Bridge dispatch

    /// The actual body of `WKScriptMessageHandler.userContentController(_:didReceive:)`, split out
    /// because `WKScriptMessage` has no public initializer a test can construct (see below) — this
    /// takes its three relevant fields directly so a test can drive the sender-identity guard without
    /// needing a real `WKScriptMessage`.
    ///
    /// `senderWebView === webView` is checked once here, ahead of every kind of message (`ready`, a
    /// complete workspace-state push, or an RPC request): WebKit can deliver a message a page queued before
    /// it was itself torn down (a rapid deactivate→reactivate hibernation cycle is the case that
    /// matters — see the class doc comment) *after* its replacement page is already installed, and
    /// message ordering across that transition is not guaranteed. Sender identity is the only reliable
    /// way to tell that stale message apart from a live one — a `ready` from the old page marking the
    /// new page ready before its own JS listener even exists would hang the pane, and a stale RPC
    /// executing under the replacement's generation would reply to a request nobody sent. `webView`
    /// being `nil` (no live page installed at all) also fails this comparison, correctly — there is
    /// nothing live to process for.
    ///
    func handleScriptMessage(name: String, body: Any, senderWebView: WKWebView?) {
        guard name == Self.messageHandlerName else { return }
        guard senderWebView != nil, senderWebView === webView else { return }
        if CodePaneBridge.isReady(body: body) {
            handleReady()
            return
        }
        if let metric = CodePaneBridge.decodeRenderMetric(body: body) {
            let fetchDetail = metric.fetchElapsedMS.map { " fetch_ms=\($0)" } ?? ""
            let phaseDetail = [
                metric.bridgeElapsedMS.map { " bridge_ms=\($0)" }, metric.decodeElapsedMS.map { " decode_ms=\($0)" },
                metric.updateElapsedMS.map { " update_ms=\($0)" }, metric.paintElapsedMS.map { " paint_ms=\($0)" },
            ].compactMap { $0 }.joined()
            let detail: String
            if metric.trigger == .workspaceStateRestored {
                // Keep the restored-state dimensions ordered so the performance harness can compare
                // workspace recovery runs without parsing a free-form diagnostic message.
                detail = "files=\(metric.fileCount) content_bytes=\(metric.contentBytes)\(fetchDetail)\(phaseDetail)" + [
                    metric.mode.map { " mode=\($0)" }, metric.scope.map { " scope=\($0)" }, metric.layout.map { " layout=\($0)" },
                    " path=\(metric.path ?? "")", metric.scrollTop.map { " scroll_top=\($0)" },
                    metric.focusedLine.map { " focused_line=\($0)" }, metric.dirty.map { " dirty=\($0 ? 1 : 0)" },
                ].compactMap { $0 }.joined()
            } else {
                detail = "files=\(metric.fileCount) content_bytes=\(metric.contentBytes)\(fetchDetail)\(phaseDetail)" + [
                    metric.path.map { " path=\($0)" }, metric.fileIndex.map { " file_index=\($0)" },
                    metric.selectedPriority ? " selected_priority=1" : nil, metric.chunkCount.map { " chunk_count=\($0)" },
                ].compactMap { $0 }.joined()
            }
            TerminalPerformance.logWorkspaceMetric(
                "code_pane_\(metric.kind.rawValue)_render", workspaceID: workspaceID, target: "trigger=\(metric.trigger.rawValue)",
                elapsedMS: metric.elapsedMS, success: true, detail: detail)
            return
        }
        if let state = CodePaneBridge.decodeWorkspaceStateChanged(body: body) {
            handleWorkspaceStateChanged(state, senderWebView: senderWebView)
            return
        }
        guard let request = CodePaneBridge.decodeRequest(body: body) else { return }
        dispatch(request)
    }

    /// Not `private`: `WKScriptMessage` has no public initializer a test can construct, so a test
    /// simulates the web app's `ready` handshake by calling this directly instead of going through
    /// `WKScriptMessageHandler` — matching the pattern `scriptEvaluator`/`diffSignatureReconnectFloor`
    /// already use to give tests a seam without adding any new product-facing surface.
    func handleReady() {
        guard !isReady, let scriptEvaluator, let hosting else { return }
        // Flips here, not after the deferral check below: a second `ready` from THIS SAME page while
        // a flush-deferred send is pending must not re-enter (there is nothing new to capture, and
        // `guard !isReady` above is what blocks it). A stale `true` left over from a torn-down page
        // never wrongly blocks a genuinely new page's `ready`, either — `teardownWebView()` always
        // resets `isReady = false` before a replacement page can load, so this self-corrects across a
        // hibernation cycle.
        isReady = true
        guard outstandingTeardownFlushCount == 0, outstandingReviewCommentMutationCount == 0, outstandingFileWriteCount == 0,
            outstandingStartWorkspaceCommandCount == 0
        else {
            // A complete-state flush kicked off by tearing down the page before this one, a review-comment mutation
            // RPC still in flight from before that, or a `workspaceFileWrite` RPC still in flight, or a Start
            // Agent RPC which can establish its durable terminal association after hibernation, may
            // still refine the recovery document. See `deferredReadyGeneration`'s doc comment for why
            // sending `spaces:init` before that lands would lose content for good rather than merely
            // delay it. Capture the generation this `ready` belongs to and let the outstanding work's
            // completion resume this once settled (`resumeDeferredReadyIfNeeded`).
            deferredReadyGeneration = pageGeneration
            return
        }
        sendInitPayloadAfterWorkspaceStateHandoff(scriptEvaluator: scriptEvaluator, hosting: hosting)
    }

    /// Fires the `handleReady()` continuation deferred while a teardown flush, review-comment mutation
    /// RPC, file-write RPC, or Start Agent RPC was outstanding (see `deferredReadyGeneration`), once every such
    /// flush/RPC has settled (`outstandingTeardownFlushCount`, `outstandingReviewCommentMutationCount`,
    /// `outstandingFileWriteCount`, and `outstandingStartWorkspaceCommandCount` all back at zero — see
    /// their doc comments for why counts, not flags). Re-verifies the deferred generation
    /// is still the live page: the page that was waiting can itself have been torn down again (a second
    /// `deactivate()`/`activate()` cycle) before this flush's completion landed, in which case there is
    /// nothing to resume — that page is gone, `scriptEvaluator` no longer points at it, and whichever
    /// page is current now will get its own `ready` → `handleReady()` call in due course.
    private func resumeDeferredReadyIfNeeded() {
        guard outstandingTeardownFlushCount == 0, outstandingReviewCommentMutationCount == 0, outstandingFileWriteCount == 0,
            outstandingStartWorkspaceCommandCount == 0,
            let generation = deferredReadyGeneration
        else { return }
        deferredReadyGeneration = nil
        guard generation == pageGeneration, let scriptEvaluator, let hosting else { return }
        sendInitPayloadAfterWorkspaceStateHandoff(scriptEvaluator: scriptEvaluator, hosting: hosting)
    }

    /// Makes a returning controller consume an outgoing instance's final collector before it sends
    /// its sole init payload. The wait is main-actor-only and does not block UI or persistence work.
    private func sendInitPayloadAfterWorkspaceStateHandoff(
        scriptEvaluator: any CodePaneScriptEvaluator, hosting: any CodePaneHosting
    ) {
        guard !waitingForWorkspaceStateHandoff else { return }
        if CodePaneWorkspaceStateHandoff.waitUntilCollectorFinishes(
            storageKey: workspaceStateStore.workspaceStateStorageKey, workspaceID: workspaceID,
            { [weak self] in self?.resumeInitAfterWorkspaceStateHandoff() })
        {
            if preReadyRequestedMode == nil { preReadyRequestedMode = forcedInitialMode }
            waitingForWorkspaceStateHandoff = true
            return
        }
        mergePreReadyModeWithCompletedWorkspaceStateHandoff()
        sendInitPayload(scriptEvaluator: scriptEvaluator, hosting: hosting)
    }

    private func resumeInitAfterWorkspaceStateHandoff() {
        waitingForWorkspaceStateHandoff = false
        guard isReady, let scriptEvaluator, let hosting else { return }
        let recovered = Self.loadWorkspaceState(from: workspaceStateStore, workspaceID: workspaceID)
        if preReadyRequestedMode != nil {
            mergePreReadyModeWithCompletedWorkspaceStateHandoff(recovered)
        } else if let recovered {
            applyWorkspaceState(recovered.bridgePayload)
        }
        sendInitPayloadAfterWorkspaceStateHandoff(scriptEvaluator: scriptEvaluator, hosting: hosting)
    }

    /// The delayed collector owns every field except a pre-ready navigation mode. Its snapshot is
    /// loaded first so a fast A → B → A retarget keeps the fresher dirty buffer, then the user's
    /// explicit mode request is applied and persisted as part of that complete state.
    private func mergePreReadyModeWithCompletedWorkspaceStateHandoff(_ recovered: CodePaneWorkspaceState? = nil) {
        guard let requestedMode = preReadyRequestedMode else { return }
        if let recovered = recovered ?? Self.loadWorkspaceState(from: workspaceStateStore, workspaceID: workspaceID) {
            applyWorkspaceState(recovered.bridgePayload)
        }
        currentMode = requestedMode
        preReadyRequestedMode = nil
        persistWorkspaceState()
    }

    /// Builds and sends `spaces:init` from the controller's current state. Split out of `handleReady()`
    /// so the same send can run either immediately (the common case) or later, once a teardown flush
    /// `handleReady()` deferred behind has settled (`resumeDeferredReadyIfNeeded`) — both call sites
    /// have already confirmed `isReady` and re-resolved `scriptEvaluator`/`hosting` as needed.
    private func sendInitPayload(scriptEvaluator: any CodePaneScriptEvaluator, hosting: any CodePaneHosting) {
        let appearance = currentTheme ?? hosting.codePaneCurrentAppearance()
        currentTheme = appearance
        let workspaceInfo = hosting.codePaneWorkspaceInfo(workspaceID: workspaceID)
        let workspaceName = workspaceInfo?.name ?? workspaceID
        // An empty string reads as "no base branch configured", not a literal branch named "" — this
        // is display-only (the toolbar's base preset and ref-dialog badge); it does not feed `refName(for:)`, which
        // no longer resolves a scope against the workspace's base branch at all.
        let baseBranch = workspaceInfo?.baseBranch.flatMap { $0.isEmpty ? nil : $0 }
        // Reuses whatever `applyRunningAgents` already recorded (e.g. from an overview that landed
        // while this pane was still loading) instead of re-querying, so init and the dedupe guard
        // agree on the same value — matches `currentTheme`'s `??` fallback just above.
        let agents = currentAgents ?? hosting.codePaneRunningAgents(workspaceID: workspaceID)
        currentAgents = agents
        if let selectedAgentSessionId, !agents.contains(where: { $0.sessionID == selectedAgentSessionId }) {
            self.selectedAgentSessionId = nil
            persistWorkspaceState()
        }
        let payload = CodePaneBridge.InitPayload(
            workspaceId: workspaceID, workspaceName: workspaceName, theme: appearance.rawValue, baseBranch: baseBranch,
            workspaceState: workspaceStatePayload(), agents: agents.map { CodePaneBridge.AgentPayload(id: $0.id, label: $0.label, sessionId: $0.sessionID) })
        guard let script = CodePaneBridge.dispatchEventScript(name: Self.initEventName, detail: payload) else { return }
        scriptEvaluator.evaluateCodePaneScript(script)
    }

    /// Writes only durable workspace-local state. Diff results and WebKit/DOM state are intentionally
    /// absent: a restored page refetches and streams fresh patches, while this document preserves the
    /// user's location and unsaved recovery data across an app restart or workspace retarget.
    private func persistWorkspaceState(fromOutgoingHandoff: Bool = false) {
        let mayPersist = if fromOutgoingHandoff {
            CodePaneWorkspaceStateHandoff.outgoingCollectorMayPersistState(workspaceStateOwner)
        } else {
            CodePaneWorkspaceStateHandoff.ownerMayPersistState(workspaceStateOwner)
        }
        guard mayPersist else { return }
        let state = CodePaneWorkspaceState(
            mode: currentMode, scope: currentScope, diffLayout: diffLayout, diffSelectedPath: diffSelectedPath,
            diffTreeExpandedPaths: diffTreeExpandedPaths, diffTreeSelectedPath: diffTreeSelectedPath,
            fileTreeExpandedPaths: fileTreeExpandedPaths, fileTreeSelectedPath: fileTreeSelectedPath,
            editorSidebarMode: editorSidebarMode, editorRecentPaths: editorRecentPaths, diffScrollLine: diffScrollLine,
            diffScrollSide: diffScrollSide, diffFocusedPath: diffFocusedPath, diffFocusedLine: diffFocusedLine, diffFocusedSide: diffFocusedSide,
            editorScrollLine: editorScrollLine, editorFocusedLine: editorFocusedLine, editorState: editorState,
            diffEditorState: diffEditorState, pendingReviewComments: pendingReviewCommentState,
            selectedAgentSessionId: selectedAgentSessionId, pendingAgentLaunch: pendingAgentLaunch)
        CodePaneWorkspaceStateCache.store(state, storageKey: workspaceStateStore.workspaceStateStorageKey, workspaceID: workspaceID)
        workspaceStatePersistence.enqueue(state, workspaceID: workspaceID)
    }

    private func workspaceStatePayload() -> CodePaneBridge.WorkspaceState {
        .init(
            mode: currentMode.wireValue, scope: currentScope, diffLayout: diffLayout, diffSelectedPath: diffSelectedPath,
            diffTreeExpandedPaths: diffTreeExpandedPaths, diffTreeSelectedPath: diffTreeSelectedPath,
            fileTreeExpandedPaths: fileTreeExpandedPaths, fileTreeSelectedPath: fileTreeSelectedPath,
            editorSidebarMode: editorSidebarMode, editorRecentPaths: editorRecentPaths, diffScrollLine: diffScrollLine,
            diffScrollSide: diffScrollSide, diffFocusedPath: diffFocusedPath, diffFocusedLine: diffFocusedLine, diffFocusedSide: diffFocusedSide,
            editorScrollLine: editorScrollLine, editorFocusedLine: editorFocusedLine, editorState: editorState,
            diffEditorState: diffEditorState, pendingReviewComments: pendingReviewCommentState,
            selectedAgentSessionId: selectedAgentSessionId, pendingAgentLaunch: pendingAgentLaunch)
    }

    private static func loadWorkspaceState(
        from store: any CodePaneWorkspaceStateStoring, workspaceID: String
    ) -> CodePaneWorkspaceState? {
        if let state = CodePaneWorkspaceStateCache.state(storageKey: store.workspaceStateStorageKey, workspaceID: workspaceID) { return state }
        do {
            guard let stateJSON = try store.stateJSON(workspaceID: workspaceID),
                let state = try? JSONDecoder().decode(CodePaneWorkspaceState.self, from: Data(stateJSON.utf8)), state.isCurrentVersion,
                state.isValid
            else { return nil }
            CodePaneWorkspaceStateCache.store(state, storageKey: store.workspaceStateStorageKey, workspaceID: workspaceID)
            return state
        } catch {
            return nil
        }
    }

    /// Stores every user-facing piece of workspace-local state in one operation. This is deliberately
    /// not decomposed into individual callbacks: a web debounce may coalesce a mode switch, sidebar
    /// selection, and a dirty line edit, and persisting a partial snapshot would restore an impossible
    /// combination after a workspace retarget.
    func handleWorkspaceStateChanged(_ state: CodePaneBridge.WorkspaceState, senderWebView: WKWebView?) {
        guard senderWebView != nil, senderWebView === webView, CodePaneBridge.isValidWorkspaceState(state) else { return }
        preReadyRequestedMode = nil
        applyWorkspaceState(state)
        workspaceStateGeneration = pageGeneration
        persistWorkspaceState()
    }

    private func applyWorkspaceState(_ state: CodePaneBridge.WorkspaceState) {
        currentMode = CodePaneMode(wireValue: state.mode)
        currentScope = state.scope
        diffLayout = state.diffLayout
        diffSelectedPath = state.diffSelectedPath
        diffTreeExpandedPaths = state.diffTreeExpandedPaths
        diffTreeSelectedPath = state.diffTreeSelectedPath
        fileTreeExpandedPaths = state.fileTreeExpandedPaths
        fileTreeSelectedPath = state.fileTreeSelectedPath
        editorSidebarMode = state.editorSidebarMode
        editorRecentPaths = state.editorRecentPaths
        diffScrollLine = state.diffScrollLine
        diffScrollSide = state.diffScrollSide
        diffFocusedPath = state.diffFocusedPath
        diffFocusedLine = state.diffFocusedLine
        diffFocusedSide = state.diffFocusedSide
        editorScrollLine = state.editorScrollLine
        editorFocusedLine = state.editorFocusedLine
        editorState = state.editorState
        diffEditorState = state.diffEditorState
        pendingReviewCommentState = state.pendingReviewComments
        selectedAgentSessionId = state.selectedAgentSessionId
        pendingAgentLaunch = state.pendingAgentLaunch
    }

    /// Not `private`: a test drives this directly (bypassing `WKScriptMessageHandler`, which can't be
    /// fed a real `WKScriptMessage` from test code) to simulate an RPC arriving.
    func dispatch(_ request: CodePaneBridge.Request) {
        // Captured once per request, live at the moment it arrives: see `pageGeneration`'s doc
        // comment for why every reply below must be tagged with it.
        let generation = pageGeneration
        switch CodePaneBridge.plan(for: request) {
        case .failure(let error): reply(id: request.id, generation: generation, error: error)
        case .success(let plan): execute(plan, id: request.id, generation: generation)
        }
    }

    private func execute(_ plan: CodePaneBridge.Plan, id: String, generation: Int) {
        guard let hosting else {
            reply(
                id: id, generation: generation,
                error: CodePaneBridge.BridgeError(code: .unavailable, message: "The Editor's host is no longer available."))
            return
        }
        switch plan {
        case .workspaceFileList: performFileList(id: id, generation: generation, hosting: hosting)
        case .workspaceRefList: performRefList(id: id, generation: generation, hosting: hosting)
        case .workspaceDiffManifestChunk(let scope, let manifestID, let fileIndex):
            performWorkspaceDiffManifestChunk(
                scope: scope, manifestID: manifestID, fileIndex: fileIndex, id: id, generation: generation, hosting: hosting)
        case .workspaceDiffFileChunk(let scope, let manifestID, let relativePath, let byteOffset, let transferID):
            performWorkspaceDiffFileChunk(
                scope: scope, manifestID: manifestID, relativePath: relativePath, byteOffset: byteOffset, transferID: transferID, id: id, generation: generation,
                hosting: hosting)
        case .workspaceDiffFileChunkCancel(let scope, let manifestID, let relativePath, let byteOffset, let transferID):
            performWorkspaceDiffFileChunkCancel(
                scope: scope, manifestID: manifestID, relativePath: relativePath, byteOffset: byteOffset, transferID: transferID, id: id, generation: generation,
                hosting: hosting)
        case .workspaceDiffManifestRelease(let scope, let manifestID):
            performWorkspaceDiffManifestRelease(scope: scope, manifestID: manifestID, id: id, generation: generation, hosting: hosting)
        case .workspaceFileRead(let path): performFileRead(path: path, id: id, generation: generation, hosting: hosting)
        case .workspaceFileWrite(let path, let content, let baseSHA256):
            performFileWrite(path: path, content: content, baseSHA256: baseSHA256, id: id, generation: generation, hosting: hosting)
        case .reviewCommentList: performReviewCommentList(id: id, generation: generation, hosting: hosting)
        case .reviewCommentUpsert(let commentID, let filePath, let side, let lineNumber, let lineText, let body):
            performReviewCommentUpsert(
                commentID: commentID, filePath: filePath, side: side, lineNumber: lineNumber, lineText: lineText, body: body, id: id,
                generation: generation, hosting: hosting)
        case .reviewCommentDelete(let commentID): performReviewCommentDelete(commentID: commentID, id: id, generation: generation, hosting: hosting)
        case .reviewCommentsSend(let sessionID, let text, let comments):
            performReviewCommentsSend(sessionID: sessionID, text: text, comments: comments, id: id, generation: generation, hosting: hosting)
        case .startWorkspaceCommand(let command):
            performStartWorkspaceCommand(command: command, id: id, generation: generation, hosting: hosting)
        case .resumeWorkspaceCommandTracking(let sessionID):
            performResumeWorkspaceCommandTracking(sessionID: sessionID, id: id, generation: generation, hosting: hosting)
        }
    }

    private func performWorkspaceDiffManifestChunk(
        scope: CodePaneBridge.DiffScope, manifestID: String?, fileIndex: Int, id: String, generation: Int, hosting: any CodePaneHosting
    ) {
        guard let device = hosting.codePaneDevice(workspaceID: workspaceID) else {
            reply(
                id: id, generation: generation,
                error: CodePaneBridge.BridgeError(code: .unavailable, message: "This workspace's device is not available."))
            return
        }
        let (refName, lastCommit) = CodePaneBridge.refName(for: scope)
        // Only an initial metadata chunk claims "latest scope"; continuations belong to that same
        // web-side generation and must not invalidate the signature stream while the metadata list is read.
        // A response for an earlier scope must not retarget the live diff-signature stream below (see
        // `latestDiffRequestToken`'s doc comment) even though its reply still always goes out.
        if manifestID == nil { latestDiffRequestToken += 1 }
        let requestToken = latestDiffRequestToken
        // Invalidate a pending old-scope backoff retry HERE, at dispatch time, rather than
        // waiting for `resubscribeDiffSignature` to bump the same generation on this fetch's
        // completion below: a retry already scheduled for the scope this call is superseding
        // captured its generation before this dispatch, so without this it stays generation-
        // valid for the ENTIRE fetch window and is free to wake mid-fetch and resubscribe the
        // now-stale ref.
        //
        // Conditional on an actual scope change, not unconditional: bumping on every dispatch
        // would also stale the LIVE stream's own `onDisconnect` handler (it closed over the
        // generation current when that stream opened) on every same-scope refetch — e.g. the
        // ordinary `refreshDiff` a `spaces:diffSignature` frame triggers — so a later real
        // disconnect on a healthy, unchanged-scope stream would be silently ignored and never
        // reconnect. `subscribedScope != .scope(...)` only trips for a genuine scope change,
        // or a refetch dispatched while already disconnected (a disconnect already cleared
        // `subscribedScope` to `.none`) — never for a refetch against a stream that is still
        // current and alive. Resetting `diffSignatureReconnectFailures` alongside starts the new
        // scope's subscription lifecycle at the backoff floor rather than wherever the old
        // scope's retry loop had climbed to.
        //
        // The generation bump and the old subscription's teardown happen atomically, right here at
        // dispatch time: there is no window where a half-alive stale stream can silently die and
        // leave nothing to reconnect it. `subscribedScope` and `diffSignatureStream` immediately and
        // accurately reflect "nothing subscribed" the instant a scope change is dispatched,
        // regardless of whether the new scope's fetch ever succeeds. This is also what fixes
        // returning to the OLD scope after a failed fetch for the new one: since `subscribedScope`
        // was actually cleared (not left pointing at the old scope), both this bump's own condition
        // above and `resubscribeDiffSignature`'s guard correctly see a fresh state and resubscribe
        // from scratch, instead of the old scope's now-generation-stale stream being mistaken for
        // still current.
        //
        // `performFileRead`'s identical-shaped bump stays bump-only, without a matching teardown,
        // because a failed file open actively RESTORES the previous path's monitoring instead — see
        // `restoreFileSignatureMonitoringAfterFailedOpen`, which reinstalls a live stream for
        // whatever file the pane is still showing. The diff side has no equivalent restore target:
        // there is no "previous scope's stream" worth reinstalling, so it tears down at dispatch and
        // relies on the next initial `workspaceDiffManifestChunk` call — same scope or different — to
        // resubscribe from a clean `.none` state.
        if manifestID == nil, subscribedScope != .scope(refName: refName, lastCommit: lastCommit) {
            diffSignatureSubscriptionGeneration += 1
            diffSignatureReconnectFailures = 0
            diffSignatureStream?.stop()
            diffSignatureStream = nil
            subscribedScope = .none
        }
        let workspaceID = workspaceID
        let deviceGateway = deviceGateway
        Task { [weak self] in
            do {
                let result = try await deviceGateway.workspaceDiffManifestChunk(
                    workspaceID: workspaceID, refName: refName, lastCommit: lastCommit, manifestID: manifestID, fileIndex: fileIndex, device: device)
                guard let self else { return }
                self.reply(id: id, generation: generation, result: result)
                // The list is metadata-first: only its final page represents a complete sidebar and
                // may establish the signature baseline/subscription for this generation.
                guard result.nextFileIndex == nil, self.latestDiffRequestToken == requestToken else { return }
                // Recorded before resubscribing, and only for a still-current request (a
                // superseded fetch's result is not what the web app is actually showing, so it
                // must not poison the dedupe baseline for whatever scope is current now).
                self.lastActedScopeSignature = result.scopeSignature
                self.lastActedScope = .scope(refName: refName, lastCommit: lastCommit)
                self.resubscribeDiffSignature(refName: refName, lastCommit: lastCommit, device: device)
            } catch {
                guard let self else { return }
                self.reply(id: id, generation: generation, error: CodePaneBridge.mapClientError(error))
            }
        }
    }

    private func performWorkspaceDiffFileChunk(
        scope: CodePaneBridge.DiffScope, manifestID: String, relativePath: String, byteOffset: Int, transferID: String?, id: String, generation: Int,
        hosting: any CodePaneHosting
    ) {
        guard let device = hosting.codePaneDevice(workspaceID: workspaceID) else {
            reply(
                id: id, generation: generation,
                error: CodePaneBridge.BridgeError(code: .unavailable, message: "This workspace's device is not available."))
            return
        }
        let (refName, lastCommit) = CodePaneBridge.refName(for: scope)
        let workspaceID = workspaceID
        let deviceGateway = deviceGateway
        Task { [weak self] in
            do {
                let result = try await deviceGateway.workspaceDiffFileChunk(
                    workspaceID: workspaceID, refName: refName, lastCommit: lastCommit, manifestID: manifestID, relativePath: relativePath,
                    byteOffset: byteOffset, transferID: transferID, device: device)
                self?.reply(id: id, generation: generation, result: result)
            } catch {
                self?.reply(id: id, generation: generation, error: CodePaneBridge.mapClientError(error))
            }
        }
    }

    private func performWorkspaceDiffFileChunkCancel(
        scope: CodePaneBridge.DiffScope, manifestID: String, relativePath: String, byteOffset: Int, transferID: String, id: String, generation: Int,
        hosting: any CodePaneHosting
    ) {
        guard let device = hosting.codePaneDevice(workspaceID: workspaceID) else {
            reply(
                id: id, generation: generation,
                error: CodePaneBridge.BridgeError(code: .unavailable, message: "This workspace's device is not available."))
            return
        }
        let (refName, lastCommit) = CodePaneBridge.refName(for: scope)
        let workspaceID = workspaceID
        let deviceGateway = deviceGateway
        Task { [weak self] in
            do {
                try await deviceGateway.cancelWorkspaceDiffFileChunk(
                    workspaceID: workspaceID, refName: refName, lastCommit: lastCommit, manifestID: manifestID, relativePath: relativePath,
                    byteOffset: byteOffset, transferID: transferID, device: device)
                self?.reply(id: id, generation: generation, result: CodePaneBridge.AckPayload())
            } catch {
                self?.reply(id: id, generation: generation, error: CodePaneBridge.mapClientError(error))
            }
        }
    }

    private func performWorkspaceDiffManifestRelease(
        scope: CodePaneBridge.DiffScope, manifestID: String, id: String, generation: Int, hosting: any CodePaneHosting
    ) {
        guard let device = hosting.codePaneDevice(workspaceID: workspaceID) else {
            reply(
                id: id, generation: generation,
                error: CodePaneBridge.BridgeError(code: .unavailable, message: "This workspace's device is not available."))
            return
        }
        let (refName, lastCommit) = CodePaneBridge.refName(for: scope)
        let workspaceID = workspaceID
        let deviceGateway = deviceGateway
        Task { [weak self] in
            do {
                try await deviceGateway.cancelWorkspaceDiffManifest(
                    workspaceID: workspaceID, refName: refName, lastCommit: lastCommit, manifestID: manifestID, device: device)
                self?.reply(id: id, generation: generation, result: CodePaneBridge.AckPayload())
            } catch {
                self?.reply(id: id, generation: generation, error: CodePaneBridge.mapClientError(error))
            }
        }
    }

    private func performFileRead(path: String, id: String, generation: Int, hosting: any CodePaneHosting) {
        guard let device = hosting.codePaneDevice(workspaceID: workspaceID) else {
            reply(
                id: id, generation: generation,
                error: CodePaneBridge.BridgeError(code: .unavailable, message: "This workspace's device is not available."))
            return
        }
        // Whether THIS dispatch is changing the monitored path, captured before any of the conditional
        // bumps below run — a failed open below only needs to restore anything when it was the one that
        // just tore down the previous path's monitoring in the first place (see
        // `restoreFileSignatureMonitoringAfterFailedOpen`'s doc comment), and the success arm further
        // down uses it to pick which "am I still current" guard applies.
        let pathChanged = subscribedFilePath != path
        // Known accepted gap: a return-navigation to this same path, dispatched while a DIFFERENT
        // file's navigation is still in flight (open A → open B → re-open A within B's read RTT), is
        // indistinguishable here from a same-path reread of A — both arrive with `pathChanged == false`,
        // since `subscribedFilePath` is still A at dispatch time. Classified as a reread, the
        // return-navigation claims no fresh `latestFileNavigationToken` below, so B's still-in-flight
        // navigation wins the file-signature subscription once it completes, while the web app's own
        // latest-request-wins guard displays the return-navigation's (A's) reply — the editor shows A
        // while external-change monitoring points at B. Left as-is: distinguishing the two would need a
        // navigation-vs-reread intent flag threaded from the web layer (only `EditorView.open` vs.
        // `EditorView.handleExternalChange` know which this dispatch actually is), a bridge-protocol
        // change disproportionate to a one-file-read-RTT edge that self-heals on the very next
        // `performFileRead` for a genuinely different path, drops a wrong-path signature frame harmlessly
        // via the web app's own path guard, and still routes a save of the shown file through the
        // existing CAS-conflict arm — so no data is ever lost, only proactive external-change detection
        // is delayed for that one window.
        // Only a navigation (an actual path change) claims a fresh "latest navigation wins" token — a
        // same-path reread of the file already open (`EditorView.handleExternalChange`'s live-reload
        // re-read) must NOT bump this, or a slower navigation to a different path in flight at the same
        // time would see its own already-captured `navToken` look stale once the reread bumps past it.
        // See `latestFileNavigationToken`'s doc comment and the success arm below for why.
        if pathChanged { latestFileNavigationToken += 1 }
        let navToken = latestFileNavigationToken
        // Mirrors `performWorkspaceDiffManifestChunk`'s `diffSignatureSubscriptionGeneration` bump: invalidate a
        // pending old-path backoff retry HERE, at dispatch time, only on an actual path change — see
        // that call site's doc comment for why this must be conditional, not unconditional.
        if pathChanged {
            fileSignatureSubscriptionGeneration += 1
            fileSignatureReconnectFailures = 0
        }
        // The generation as of this dispatch's bump (a no-op read of the current value when
        // `pathChanged` is false). A failed open below only restores if this is still the current
        // generation when it runs — see `restoreFileSignatureMonitoringAfterFailedOpen`.
        let dispatchGeneration = fileSignatureSubscriptionGeneration
        let workspaceID = workspaceID
        let deviceGateway = deviceGateway
        Task { [weak self] in
            do {
                let result = try await deviceGateway.workspaceFileRead(workspaceID: workspaceID, relativePath: path, device: device)
                guard let self else { return }
                switch CodePaneBridge.fileReadPayload(result) {
                case .success(let payload):
                    self.reply(id: id, generation: generation, result: payload)
                    // Subscription ownership keys off the latest NAVIGATION, not the latest arbitrary
                    // read: a same-path reread of the file already open (dispatched with
                    // `pathChanged == false`) can complete after a *different* file's navigation has
                    // already taken over, and must not steal the subscription back. Four interleavings
                    // motivate the two branches below (see also `latestFileNavigationToken`'s doc
                    // comment):
                    //  (a) nav to B completes, then A's reread (dispatched while A was still current)
                    //      completes after it → A's reread is skipped, since `subscribedFilePath` is
                    //      now B and its `== path` check (path == A) fails.
                    //  (b) A's reread completes BEFORE B's navigation does → it passes
                    //      (`subscribedFilePath` is still A at that moment), but the
                    //      `resubscribeFileSignature` call below is a no-op for it — that method guards
                    //      on `subscribedFilePath != path`, already equal — so it's just a harmless
                    //      baseline refresh. B's navigation resubscribes normally once its own read
                    //      lands.
                    //  (c) two navigations, B then C, in flight concurrently → B's completion carries
                    //      the now-stale `navToken` and is skipped once C's navigation has bumped
                    //      `latestFileNavigationToken` past it; C's (latest) completion passes. This
                    //      mirrors the web side's own latest-request-wins guard for navigation.
                    //  (d) teardown nils `subscribedFilePath` and bumps `latestFileNavigationToken`,
                    //      invalidating both branches for anything still in flight.
                    if pathChanged {
                        guard self.latestFileNavigationToken == navToken else { return }
                    } else {
                        guard self.subscribedFilePath == path else { return }
                    }
                    // Recorded before resubscribing, mirroring `performWorkspaceDiffManifestChunk`'s
                    // `lastActedScopeSignature`/`lastActedScope` bookkeeping.
                    self.lastActedFileSignatureValue = FileSignatureValue(sha256: result.sha256, missing: false)
                    self.lastActedFilePath = path
                    self.resubscribeFileSignature(path: path, device: device)
                case .failure(let error):
                    self.reply(id: id, generation: generation, error: error)
                    self.restoreFileSignatureMonitoringAfterFailedOpen(
                        path: path, error: error, pathChanged: pathChanged, dispatchGeneration: dispatchGeneration, device: device)
                }
            } catch {
                guard let self else { return }
                let bridgeError = CodePaneBridge.mapClientError(error)
                self.reply(id: id, generation: generation, error: bridgeError)
                self.restoreFileSignatureMonitoringAfterFailedOpen(
                    path: path, error: bridgeError, pathChanged: pathChanged, dispatchGeneration: dispatchGeneration, device: device)
            }
        }
    }

    /// Restores file-signature monitoring for the PREVIOUSLY-open file after `performFileRead` fails to
    /// open a new one (either `fileReadPayload`'s `.failure` arm, or the outer `catch`) — called from
    /// both failure arms with the `pathChanged`/`dispatchGeneration` values `performFileRead` captured at
    /// dispatch time.
    ///
    /// The stranding this undoes: opening file B while A is open trips `performFileRead`'s dispatch-time
    /// generation bump (conditional on the path actually changing), which staled A's live stream's
    /// `onDisconnect` closure and cancelled any pending backoff retry for A. If B's read then fails,
    /// nothing else would ever restore A — no resubscribe runs, so external-change monitoring for A
    /// silently dies for good even though the web pane still shows A (a failed open keeps the prior file
    /// displayed). Restoring here re-arms it, and the fresh `resubscribeFileSignature` call below installs
    /// a current-generation `onDisconnect`/backoff closure, closing the stale-handler window too.
    ///
    /// Deliberately asymmetric with `performWorkspaceDiffManifestChunk`'s scope-change bump, which tears down
    /// the old subscription at dispatch time instead of restoring it (see the comment there): the diff
    /// side has no "previous scope's stream" worth reinstalling, so it simply relies on the next
    /// initial `workspaceDiffManifestChunk` call to resubscribe from a clean `.none` state. The editor has no equivalent
    /// fetch-retry loop — nothing else will ever re-arm external-change monitoring for a file still open
    /// in the pane — so a failed open must proactively restore it here instead. See that comment for the
    /// reverse cross-reference.
    ///
    /// `pathChanged` (captured at dispatch time, before this read even started) is what already keeps
    /// this from ever touching a live, still-subscribed stream: a re-read of the file the pane is ALREADY
    /// showing — e.g. `EditorView.handleExternalChange`'s own re-read after a live `spaces:fileSignature`
    /// push, including the file being deleted while the pane is visible — dispatches with
    /// `subscribedFilePath == path`, so `pathChanged` is false and this whole function is a no-op. Only a
    /// read for a DIFFERENT path than whatever was last subscribed reaches the guard below.
    private func restoreFileSignatureMonitoringAfterFailedOpen(
        path: String, error: CodePaneBridge.BridgeError, pathChanged: Bool, dispatchGeneration: Int, device: SpacesPairedDeviceRecord
    ) {
        // Not this dispatch's path change (nothing was torn down for it to restore, and no live stream
        // for THIS path needs installing either — see this method's doc comment), or a newer
        // path-changing dispatch has since bumped the generation again and its own success/failure arm
        // now owns this state — either way, this stale completion must not interfere.
        guard pathChanged, fileSignatureSubscriptionGeneration == dispatchGeneration else { return }
        // `lastActedFilePath` is still the previous file's path in both stranding sub-cases: the
        // live-stream case (nothing on this failed path ever clears it), and the disconnected-with-
        // pending-retry case (cleared only by a different-path resubscribe, which never ran since this
        // dispatch's read failed). `nil` means no file was ever successfully read yet this pane's life.
        guard let restorePath = lastActedFilePath else {
            // Nothing to restore — but a nil `lastActedFilePath` also covers a post-hibernation
            // rehydration reconcile read: teardown clears it unconditionally (see `teardownWebView`), so
            // the pane's very first read after rehydrating always lands here regardless of whether a
            // file was open before hibernation. If that read's answer is the daemon's authoritative
            // notFound for a file deleted during hibernation, install a stream for it anyway rather than
            // leaving the pane with no live monitoring at all: the web side's resulting deleted-file
            // placeholder/conflict has no other way to learn the file reappears — its recovery contract
            // is "the same live-reload branch catches it," which needs a signature event to ever fire.
            // The daemon's signature poll intentionally handles a missing path (that's how a
            // deleted-then-recreated file is caught at all), so subscribing to a currently-missing path
            // is the intended shape here, not a workaround.
            //
            // notFound and invalidArgument only, deliberately: these are the two error codes that are
            // both (a) an AUTHORITATIVE per-file answer — the daemon actually examined the path and
            // determined either "missing" or "oversized/non-regular" (`CodePaneBridge.bridgeErrorCode`
            // collapses the daemon's own `payloadTooLarge` — a file that grew past 10 MiB while the pane
            // was hibernated — into this same bridge-side `.invalidArgument`, alongside the daemon's
            // `invalidArgument` for a path replaced by a non-regular file, e.g. a directory or a
            // symlink-to-nowhere) — and (b) DURABLE on the web side: the web side's typed-error-code retry
            // contract in `root.ts` never automatically retries `.notFound`/`.invalidArgument`, only
            // `.unavailable`/`.internalError`. Because of that combination, the file-signature stream is
            // the ONLY channel that can ever announce the file became readable again for these two cases
            // (shrinks back under 10 MiB, or gets replaced back with a regular file) — so both need a
            // recovery subscription installed here. The signature provider is safe to subscribe to in
            // this state: per `SpacesDeviceAPIServer`, the provider stat-gates at the same 10 MiB read cap
            // and reports a stable "oversized" sentinel above it instead of hashing, and skips ticks for a
            // non-regular-file path — resuming real hashes once the file shrinks back under the cap, or
            // ticks again once the path becomes a regular file again. Either readable transition still
            // produces a changed frame the web side refetches on, and the sentinel's own stability plus
            // existing dedupe (`lastActedFileSignatureValue`) prevent both broadcast churn and refetch
            // loops for as long as the file stays oversized.
            //
            // Any other failure (offline device, daemon hiccup, a transport error like `.unavailable`) is
            // not an authoritative answer about the path — the daemon may not have even examined it — so
            // installing a recovery subscription for those would be premature/wrong. The web side already
            // schedules its own bounded-backoff re-read for those (see `EditorView.handleExternalChange`'s
            // catch branch), and that retry's own eventual success installs the stream through the normal
            // path.
            //
            // Accepted micro-cost: a fresh pane's first-ever open of a typo'd path also lands here (no
            // `lastActedFilePath`, notFound) and installs a stream for a path that will never exist. The
            // web side filters signature events by `currentPath`, so nothing misfires, and the next
            // successful open replaces the subscription — one lstat poll every 2s until then isn't worth
            // a special case to avoid.
            guard error.code == .notFound || error.code == .invalidArgument else { return }
            resubscribeFileSignature(path: path, device: device)
            return
        }
        // Stop and drop whatever is (or isn't) currently installed, then resubscribe fresh. Clearing
        // `subscribedFilePath` first is what lets `resubscribeFileSignature`'s own `!= path` guard pass.
        // Restoring over a still-healthy A stream (failure arrived before any disconnect ever happened)
        // just stops and reopens it — brief, harmless churn, not special-cased away.
        //
        // Deliberately NOT cleared here: `lastActedFileSignatureValue` for `restorePath`.
        // `resubscribeFileSignature`'s own `lastActedFilePath == path` case (see its
        // `if lastActedFilePath != path { lastActedFileSignatureValue = nil; lastActedFilePath = nil }`)
        // skips the clear when the restore target is the same path already recorded there, keeping the
        // existing dedupe baseline intact. That means a signature change the web app fetched but
        // discarded during the failed open (because it lost the reconcile race — its own read landed
        // after the `openGeneration` bump from the newer, now-failed, open attempt) is suppressed as a
        // duplicate once this restored stream reconnects and the daemon resends that same current value,
        // since the value on record here never moved. Recovery for that exact window is intentionally
        // NOT this restore's job: it's owned by `EditorView.open()`'s failed/refused-open fix, which
        // fires `handleExternalChange()` at both of its early returns to re-fetch and reconcile the file
        // directly, rather than this Swift side force-forwarding a synthetic connect frame to paper over
        // a dedupe value it deliberately left untouched.
        fileSignatureStream?.stop()
        fileSignatureStream = nil
        subscribedFilePath = nil
        resubscribeFileSignature(path: restorePath, device: device)
    }

    private func performFileWrite(path: String, content: String, baseSHA256: String?, id: String, generation: Int, hosting: any CodePaneHosting) {
        guard let device = hosting.codePaneDevice(workspaceID: workspaceID) else {
            reply(
                id: id, generation: generation,
                error: CodePaneBridge.BridgeError(code: .unavailable, message: "This workspace's device is not available."))
            return
        }
        let base64Data = Data(content.utf8).base64EncodedString()
        let workspaceID = workspaceID
        let deviceGateway = deviceGateway
        // Bumped before the RPC starts, decremented — unconditionally, success or failure —
        // in its completion below. See `outstandingFileWriteCount`'s doc comment for why a deferred
        // `ready` also waits on this.
        outstandingFileWriteCount += 1
        Task { [weak self] in
            do {
                let result = try await deviceGateway.workspaceFileWrite(
                    workspaceID: workspaceID, relativePath: path, base64Data: base64Data, expectedSHA256: baseSHA256, device: device)
                switch CodePaneBridge.fileWritePayload(result) {
                case .success(let payload):
                    // Only an actually-committed write (never a CAS conflict, which wrote
                    // nothing to disk) has a baseline worth adopting into a flushed snapshot. `sha256`
                    // is documented to be populated whenever `didWrite == true`, but the type is
                    // Optional — skip adoption defensively if it somehow isn't.
                    if result.didWrite, let sha = result.sha256 {
                        self?.lastCommittedFileWrite = (path: path, expectedBase: baseSHA256, sha256: sha, content: content, pageGeneration: generation)
                        self?.adoptCommittedWriteIntoEditorState()
                        self?.persistWorkspaceState()
                    }
                    self?.reply(id: id, generation: generation, result: payload)
                case .failure(let error): self?.reply(id: id, generation: generation, error: error)
                }
                self?.settleFileWrite()
            } catch {
                self?.reply(id: id, generation: generation, error: CodePaneBridge.mapClientError(error))
                self?.settleFileWrite()
            }
        }
    }

    /// Lists every path in the workspace's checkout for the Editor pane's file tree and quick-open —
    /// mirrors `performReviewCommentList`'s shape exactly (no subscription-token tracking, unlike
    /// `performFileRead`/`performWorkspaceDiffManifestChunk`, since this has no live-signature stream to repoint).
    /// `SpacesDeviceWorkspaceFileListResult`'s own `{paths, truncated}` shape already matches the wire
    /// contract the web app expects, so the daemon result is replied directly with no bridge-owned
    /// payload struct in between.
    private func performFileList(id: String, generation: Int, hosting: any CodePaneHosting) {
        guard let device = hosting.codePaneDevice(workspaceID: workspaceID) else {
            reply(
                id: id, generation: generation,
                error: CodePaneBridge.BridgeError(code: .unavailable, message: "This workspace's device is not available."))
            return
        }
        let workspaceID = workspaceID
        let deviceGateway = deviceGateway
        Task { [weak self] in
            do {
                let result = try await deviceGateway.workspaceFileList(workspaceID: workspaceID, device: device)
                self?.reply(id: id, generation: generation, result: result)
            } catch { self?.reply(id: id, generation: generation, error: CodePaneBridge.mapClientError(error)) }
        }
    }

    /// Mirrors `performFileList` exactly: `SpacesDeviceWorkspaceRefListResult` is already the wire
    /// contract the Compare dialog's ref search expects, so the daemon result is replied directly.
    private func performRefList(id: String, generation: Int, hosting: any CodePaneHosting) {
        guard let device = hosting.codePaneDevice(workspaceID: workspaceID) else {
            reply(
                id: id, generation: generation,
                error: CodePaneBridge.BridgeError(code: .unavailable, message: "This workspace's device is not available."))
            return
        }
        let workspaceID = workspaceID
        let deviceGateway = deviceGateway
        Task { [weak self] in
            do {
                let result = try await deviceGateway.workspaceRefList(workspaceID: workspaceID, device: device)
                self?.reply(id: id, generation: generation, result: result)
            } catch { self?.reply(id: id, generation: generation, error: CodePaneBridge.mapClientError(error)) }
        }
    }

    private func performReviewCommentList(id: String, generation: Int, hosting: any CodePaneHosting) {
        guard let device = hosting.codePaneDevice(workspaceID: workspaceID) else {
            reply(
                id: id, generation: generation,
                error: CodePaneBridge.BridgeError(code: .unavailable, message: "This workspace's device is not available."))
            return
        }
        let workspaceID = workspaceID
        let deviceGateway = deviceGateway
        Task { [weak self] in
            do {
                let comments = try await deviceGateway.workspaceReviewCommentList(workspaceID: workspaceID, device: device)
                self?.reply(id: id, generation: generation, result: comments)
            } catch { self?.reply(id: id, generation: generation, error: CodePaneBridge.mapClientError(error)) }
        }
    }

    private func performReviewCommentUpsert(
        commentID: String?, filePath: String, side: SpacesDeviceReviewCommentSide, lineNumber: Int, lineText: String, body: String, id: String,
        generation: Int, hosting: any CodePaneHosting
    ) {
        guard let device = hosting.codePaneDevice(workspaceID: workspaceID) else {
            reply(
                id: id, generation: generation,
                error: CodePaneBridge.BridgeError(code: .unavailable, message: "This workspace's device is not available."))
            return
        }
        let workspaceID = workspaceID
        let deviceGateway = deviceGateway
        // Bumped before the RPC starts, decremented — unconditionally, success or
        // failure — in its completion below. See `outstandingReviewCommentMutationCount`'s doc comment
        // for why a deferred `ready` also waits on this, not just on `outstandingTeardownFlushCount`.
        outstandingReviewCommentMutationCount += 1
        Task { [weak self] in
            do {
                let comment = try await deviceGateway.workspaceReviewCommentUpsert(
                    workspaceID: workspaceID, id: commentID, filePath: filePath, side: side, lineNumber: lineNumber, lineText: lineText, body: body,
                    device: device)
                self?.reply(id: id, generation: generation, result: comment)
                // Only a CREATE (`commentID == nil` on the call this Task is completing) can have raced a
                // teardown flush that snapshotted this same draft while it was still provisional — an
                // UPDATE's snapshot entry, if any, was already non-provisional and needs no correction.
                if commentID == nil { self?.reconcilePendingReviewCommentStateAfterCreate(comment: comment) }
                self?.settleReviewCommentMutation()
            } catch {
                self?.reply(id: id, generation: generation, error: CodePaneBridge.mapClientError(error))
                self?.settleReviewCommentMutation()
            }
        }
    }

    /// Corrects a stale `pendingReviewCommentState` snapshot after a CREATE upsert (never an UPDATE —
    /// see the call site) commits server-side, closing the race described on `pendingReviewCommentState`'s
    /// doc comment: a blur fires this CREATE, the same gesture (or an unrelated race) hibernates the pane
    /// before the RPC replies, and the complete-state collector snapshots the still-provisional
    /// entry because it looked unpersisted at that instant. Left uncorrected, the replacement page's
    /// `spaces:init` would restore that stale provisional entry *alongside* the new server row the
    /// replacement page's own `loadInitial()` already lists — two cards for one comment — and the
    /// restored provisional card's next blur would fire another CREATE, minting a second real
    /// server-side row.
    ///
    /// Runs unconditionally, even when the page is still alive (not torn down): if so,
    /// `pendingReviewCommentState` is necessarily a stale snapshot from some *previous* teardown that the
    /// live page has already moved past — a live page holds its own in-memory draft state, not this
    /// snapshot — so correcting stale-but-harmless data here is harmless. Nothing reads this snapshot
    /// except a future `spaces:init` construction, so there is nothing to gate this against.
    ///
    /// At most one entry is touched, matched against `comment`'s `(filePath, side, lineNumber, lineText)`
    /// anchor: a body-equal provisional match (nothing was typed after the CREATE went out) is removed
    /// outright, since the listed server row already carries this exact text; an anchor-only match with a
    /// different body (the user kept typing while the CREATE was in flight) is rewritten in place as
    /// non-provisional with the server-assigned id, keeping its own (newer) body so it still overlays the
    /// listed row as unsaved text. Left untouched — same generation, same value — if nothing matches.
    private func reconcilePendingReviewCommentStateAfterCreate(comment: SpacesDeviceReviewComment) {
        guard var entries = pendingReviewCommentState else { return }
        var bodyEqualIndex: Int?
        var anchorOnlyIndex: Int?
        for (index, entry) in entries.enumerated() {
            guard entry.provisional, entry.filePath == comment.filePath, entry.side == comment.side, entry.lineNumber == comment.lineNumber,
                entry.lineText == comment.lineText
            else { continue }
            if entry.body == comment.body {
                bodyEqualIndex = index
                break
            }
            if anchorOnlyIndex == nil { anchorOnlyIndex = index }
        }
        if let index = bodyEqualIndex {
            entries.remove(at: index)
        } else if let index = anchorOnlyIndex {
            let stale = entries[index]
            entries[index] = CodePaneBridge.ReviewCommentEntryPayload(
                id: comment.id, provisional: false, filePath: stale.filePath, side: stale.side, lineNumber: stale.lineNumber,
                lineText: stale.lineText, body: stale.body)
        } else {
            return
        }
        // Deliberately not touched: this corrects the content already stored under the current
        // generation, it does not answer a new teardown flush, so bumping it would be wrong (see
        // `pendingReviewCommentStateGeneration`'s doc comment).
        pendingReviewCommentState = entries
    }

    /// The delete-side counterpart of `reconcilePendingReviewCommentStateAfterCreate` corrects a
    /// stale `pendingReviewCommentState` snapshot after a delete commits server-side. The race: a
    /// deleted comment's entry is still present in a teardown-flushed snapshot taken before the delete
    /// RPC replied (the page looked like it still had the row at that instant), the pane hibernates, and
    /// the delete then lands. Left uncorrected, the replacement page's `spaces:init` would restore that
    /// stale entry even though `loadInitial()` finds no server row for it — reviving an explicitly
    /// deleted comment as a fresh provisional draft (the same create-side reconciliation in
    /// `commentsController.ts` that a live page uses to keep unsaved local text alive across a reload),
    /// silently undoing the user's deletion.
    ///
    /// Matches only a non-provisional entry whose `id` equals `commentID`: a non-provisional entry's
    /// `id` is the server-assigned id (see `reconcilePendingReviewCommentStateAfterCreate`, which writes
    /// it in when converting a match), so it is the only field a delete's server-issued `commentID` can
    /// legitimately be compared against. A provisional entry's `id` is a client-generated placeholder,
    /// never a real server id, so it is excluded even on a coincidental match.
    private func reconcilePendingReviewCommentStateAfterDelete(commentID: String) {
        guard var entries = pendingReviewCommentState else { return }
        guard let index = entries.firstIndex(where: { !$0.provisional && $0.id == commentID }) else { return }
        entries.remove(at: index)
        // Deliberately not touched: mirrors `reconcilePendingReviewCommentStateAfterCreate`'s own
        // generation rationale — this corrects content already stored under the current generation, it
        // does not answer a new teardown flush.
        pendingReviewCommentState = entries.isEmpty ? nil : entries
    }

    private func performReviewCommentDelete(commentID: String, id: String, generation: Int, hosting: any CodePaneHosting) {
        guard let device = hosting.codePaneDevice(workspaceID: workspaceID) else {
            reply(
                id: id, generation: generation,
                error: CodePaneBridge.BridgeError(code: .unavailable, message: "This workspace's device is not available."))
            return
        }
        let workspaceID = workspaceID
        let deviceGateway = deviceGateway
        outstandingReviewCommentMutationCount += 1
        Task { [weak self] in
            do {
                _ = try await deviceGateway.workspaceReviewCommentDelete(workspaceID: workspaceID, id: commentID, device: device)
                self?.reply(id: id, generation: generation, result: CodePaneBridge.AckPayload())
                self?.reconcilePendingReviewCommentStateAfterDelete(commentID: commentID)
                self?.settleReviewCommentMutation()
            } catch {
                self?.reply(id: id, generation: generation, error: CodePaneBridge.mapClientError(error))
                self?.settleReviewCommentMutation()
            }
        }
    }

    private func performReviewCommentsSend(
        sessionID: String, text: String, comments: [SpacesDeviceReviewCommentSendEntry], id: String, generation: Int, hosting: any CodePaneHosting
    ) {
        guard let device = hosting.codePaneDevice(workspaceID: workspaceID) else {
            reply(
                id: id, generation: generation,
                error: CodePaneBridge.BridgeError(code: .unavailable, message: "This workspace's device is not available."))
            return
        }
        let workspaceID = workspaceID
        let deviceGateway = deviceGateway
        // A send held up by this counter can hold `ready` for as long as the send's
        // own terminal-write timeout (~5s), if teardown happens right after the user hits send. Accepted:
        // the alternative — answering `ready` (and thus letting a `reviewCommentList` race it) before
        // the send lands — would show the just-sent draft as still present/unsent in the rehydrated
        // page, which is worse than a bounded delay.
        outstandingReviewCommentMutationCount += 1
        Task { [weak self] in
            do {
                _ = try await deviceGateway.workspaceReviewCommentsSend(
                    workspaceID: workspaceID, sessionID: sessionID, text: text, comments: comments, device: device)
                self?.reply(id: id, generation: generation, result: CodePaneBridge.AckPayload())
                self?.settleReviewCommentMutation()
            } catch {
                self?.reply(id: id, generation: generation, error: CodePaneBridge.mapClientError(error))
                self?.settleReviewCommentMutation()
            }
        }
    }

    private func performStartWorkspaceCommand(command: String, id: String, generation: Int, hosting: any CodePaneHosting) {
        guard let device = hosting.codePaneDevice(workspaceID: workspaceID) else {
            reply(
                id: id, generation: generation,
                error: CodePaneBridge.BridgeError(code: .unavailable, message: "This workspace's device is not available."))
            return
        }
        let workspaceID = workspaceID
        let deviceGateway = deviceGateway
        outstandingStartWorkspaceCommandCount += 1
        Task { [weak self] in
            do {
                let response = try await deviceGateway.startWorkspaceCommand(workspaceID: workspaceID, command: command, device: device)
                guard let self else { return }
                guard response.ok, let sessionID = response.sessionID else {
                    throw SpacesDeviceClientError.requestRejected(message: response.message, code: response.errorCode)
                }
                let deadlineEpochMilliseconds = self.nextAgentStartDeadlineEpochMilliseconds()
                self.pendingAgentLaunch = .init(
                    sessionId: sessionID, command: command, status: "starting", message: nil,
                    deadlineEpochMilliseconds: deadlineEpochMilliseconds)
                self.persistWorkspaceState()
                // Establish the pending association before inserting the terminal. Inserting it can
                // synchronously apply an overview whose hooks have already registered this session;
                // `applyRunningAgents` uses the association to keep that session out of assignment
                // until the keyed readiness observer confirms it.
                hosting.codePaneInstallBackgroundCommandSession(workspaceID: workspaceID, deviceID: device.id, response: response)
                self.reply(
                    id: id, generation: generation,
                    result: CodePaneBridge.StartWorkspaceCommandPayload(
                        sessionId: sessionID, status: "starting", deadlineEpochMilliseconds: deadlineEpochMilliseconds))
                // A hidden or closing pane persists this association through its handoff; only the
                // live, ready page may own the observer. A returned page resumes it after installing
                // its event listener, keeping one tracking lifetime instead of a hidden poller.
                if self.isReady, !self.closeStarted {
                    self.trackStartedWorkspaceCommand(
                        sessionID: sessionID, device: device, deadlineEpochMilliseconds: deadlineEpochMilliseconds)
                }
                self.settleStartWorkspaceCommand()
            } catch {
                self?.reply(id: id, generation: generation, error: CodePaneBridge.mapClientError(error))
                self?.settleStartWorkspaceCommand()
            }
        }
    }

    /// Reattaches a recovery document's still-running Start Agent command after a page/controller/app
    /// restart. The session id is accepted only when the current device overview proves it belongs to
    /// this workspace; a stale document must not watch or assign some other workspace's terminal.
    private func performResumeWorkspaceCommandTracking(
        sessionID: String, id: String, generation: Int, hosting: any CodePaneHosting
    ) {
        guard let pending = pendingAgentLaunch, pending.sessionId == sessionID, pending.status == "starting" else {
            reply(
                id: id, generation: generation,
                error: CodePaneBridge.BridgeError(code: .invalidArgument, message: "There is no pending Start Agent command for this session."))
            return
        }
        guard let deadlineEpochMilliseconds = pending.deadlineEpochMilliseconds else {
            reply(
                id: id, generation: generation,
                error: CodePaneBridge.BridgeError(code: .invalidArgument, message: "The pending Start Agent command has no readiness deadline."))
            return
        }
        guard let device = hosting.codePaneDevice(workspaceID: workspaceID) else {
            reply(
                id: id, generation: generation,
                error: CodePaneBridge.BridgeError(code: .unavailable, message: "This workspace's device is not available."))
            return
        }
        let workspaceID = workspaceID
        let deviceGateway = deviceGateway
        Task { [weak self] in
            do {
                let snapshot = try await deviceGateway.workspaceCommandStartSnapshot(
                    workspaceID: workspaceID, sessionID: sessionID, device: device)
                guard let self else { return }
                guard snapshot.sessionFound else {
                    self.reply(
                        id: id, generation: generation,
                        result: CodePaneBridge.StartWorkspaceCommandPayload(
                            sessionId: sessionID, status: "starting", deadlineEpochMilliseconds: deadlineEpochMilliseconds))
                    self.finishAgentStartTracking(
                        sessionID: sessionID, taskGeneration: nil, status: "exited", agent: nil,
                        message: "The command's terminal session is no longer running.")
                    return
                }
                guard snapshot.belongsToWorkspace else {
                    self.reply(
                        id: id, generation: generation,
                        error: CodePaneBridge.BridgeError(code: .invalidArgument, message: "That terminal session does not belong to this workspace."))
                    return
                }
                self.reply(
                    id: id, generation: generation,
                    result: CodePaneBridge.StartWorkspaceCommandPayload(
                        sessionId: sessionID, status: "starting", deadlineEpochMilliseconds: deadlineEpochMilliseconds))
                let deadline = Date(timeIntervalSince1970: TimeInterval(deadlineEpochMilliseconds) / 1_000)
                // A resumed page gets one exact-session reconciliation even after the original
                // deadline. A hook-backed row for that terminal is conclusive evidence that the
                // launch succeeded while the Editor was hibernated or retargeted; without this,
                // restarting the ordinary readiness tracker at an already-expired deadline would
                // falsely report a timeout before it could assign the session.
                if self.agentStartNow() >= deadline {
                    if let agent = snapshot.agent, agent.sessionID == sessionID {
                        self.finishAgentStartTracking(
                            sessionID: sessionID, taskGeneration: nil, status: "detected", agent: agent, message: nil)
                    } else {
                        self.finishAgentStartTracking(
                            sessionID: sessionID, taskGeneration: nil, status: "timedOut", agent: nil,
                            message: "The command did not become a ready agent within 90 seconds.")
                    }
                    return
                }
                // Before its original deadline, the snapshot only proves ownership. It must pass
                // through the same stable readiness gate as a freshly launched command before its
                // hook-backed agent may be assigned.
                self.trackStartedWorkspaceCommand(
                    sessionID: sessionID, device: device, deadlineEpochMilliseconds: deadlineEpochMilliseconds, initialSnapshot: snapshot)
            } catch {
                self?.reply(id: id, generation: generation, error: CodePaneBridge.mapClientError(error))
            }
        }
    }

    /// Watches the one terminal created by Start Agent without ever inferring an agent from its command
    /// text. A terminal must first pass the stable foreground/readiness gate shared with `spaces agent
    /// spawn`, then have a hook-backed agent row for this exact session before the web surface can assign
    /// it. The observer is local to this pane and session, so simultaneous starts cannot cross-assign.
    private func nextAgentStartDeadlineEpochMilliseconds() -> Int64 {
        Int64((agentStartNow().timeIntervalSince1970 * 1_000).rounded(.down)) + Int64(agentStartReadinessTimeout * 1_000)
    }

    private func trackStartedWorkspaceCommand(
        sessionID: String, device: SpacesPairedDeviceRecord, deadlineEpochMilliseconds: Int64, initialSnapshot: CodePaneAgentStartSnapshot? = nil
    ) {
        agentStartTasks[sessionID]?.cancel()
        nextAgentStartTaskGeneration += 1
        let taskGeneration = nextAgentStartTaskGeneration
        agentStartTaskGenerations[sessionID] = taskGeneration
        let deadline = Date(timeIntervalSince1970: TimeInterval(deadlineEpochMilliseconds) / 1_000)
        let pollInterval = agentStartPollInterval
        let workspaceID = workspaceID
        let deviceGateway = deviceGateway
        agentStartTasks[sessionID] = Task { [weak self] in
            var readiness = AgentSpawnReadiness.PollTracker(deadline: deadline)
            var reachedStableReadiness = false
            var nextSample = initialSnapshot
            while !Task.isCancelled {
                do {
                    let sample: CodePaneAgentStartSnapshot
                    if let initial = nextSample {
                        nextSample = nil
                        sample = initial
                    } else {
                        sample = try await deviceGateway.workspaceCommandStartSnapshot(
                            workspaceID: workspaceID, sessionID: sessionID, device: device)
                    }
                    guard let self, self.agentStartTaskGenerations[sessionID] == taskGeneration else { return }
                    let snapshot = AgentSpawnReadiness.SessionSnapshot(
                        detectedKind: sample.detectedKind, bracketedPasteActive: sample.bracketedPasteActive, state: sample.state)

                    if !reachedStableReadiness {
                        if let outcome = readiness.observe(snapshot, at: self.agentStartNow()) {
                            switch outcome {
                            case .ready:
                                reachedStableReadiness = true
                            case .ended(let state):
                                self.finishAgentStartTracking(
                                    sessionID: sessionID, taskGeneration: taskGeneration, status: "exited", agent: nil,
                                    message: "The command exited (\(state.rawValue)) before an agent was detected.")
                                return
                            case .timedOut:
                                self.finishAgentStartTracking(
                                    sessionID: sessionID, taskGeneration: taskGeneration, status: "timedOut", agent: nil,
                                    message: "The command did not become a ready agent within 90 seconds.")
                                return
                            }
                        }
                    }

                    if reachedStableReadiness, let agent = sample.agent, agent.sessionID == sessionID {
                        self.finishAgentStartTracking(
                            sessionID: sessionID, taskGeneration: taskGeneration, status: "detected", agent: agent, message: nil)
                        return
                    }

                    // A hook can arrive just after the stable foreground sample. Keep checking the
                    // session state during that narrow period: a command that exits after becoming
                    // stable still needs to report a concrete failure rather than waiting out 90s.
                    if let state = sample.state, !state.isInteractive {
                        self.finishAgentStartTracking(
                            sessionID: sessionID, taskGeneration: taskGeneration, status: "exited", agent: nil,
                            message: "The command exited (\(state.rawValue)) before its agent hooks registered.")
                        return
                    }
                    if self.agentStartNow() >= deadline {
                        self.finishAgentStartTracking(
                            sessionID: sessionID, taskGeneration: taskGeneration, status: "timedOut", agent: nil,
                            message: "The command became ready but its agent hooks did not register within 90 seconds.")
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // A temporary device failure must not turn a still-running command into a false
                    // "exited" result. Continue until the same fixed readiness deadline; the next
                    // ordinary overview poll may have recovered the local or remote device.
                    guard let self, self.agentStartTaskGenerations[sessionID] == taskGeneration else { return }
                    if self.agentStartNow() >= deadline {
                        self.finishAgentStartTracking(
                            sessionID: sessionID, taskGeneration: taskGeneration, status: "timedOut", agent: nil,
                            message: "Could not confirm that the command became an agent within 90 seconds.")
                        return
                    }
                }
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    private func finishAgentStartTracking(
        sessionID: String, taskGeneration: Int?, status: String, agent: CodePaneRunningAgent?, message: String?
    ) {
        if let taskGeneration, agentStartTaskGenerations[sessionID] != taskGeneration { return }
        agentStartTasks.removeValue(forKey: sessionID)
        agentStartTaskGenerations.removeValue(forKey: sessionID)
        if status == "detected", let agent {
            selectedAgentSessionId = agent.sessionID
            pendingAgentLaunch = nil
        } else if let pendingAgentLaunch, pendingAgentLaunch.sessionId == sessionID {
            self.pendingAgentLaunch = .init(
                sessionId: sessionID, command: pendingAgentLaunch.command, status: "failed", message: message,
                deadlineEpochMilliseconds: nil)
        }
        // Persist before checking page liveness. A command can resolve while its Editor is hibernated;
        // its recovered page must still see the final status and typed command after restart.
        persistWorkspaceState()
        guard isReady, let scriptEvaluator else { return }
        let payload = CodePaneBridge.AgentStartStatusPayload(
            sessionId: sessionID, status: status,
            agent: agent.map { CodePaneBridge.AgentPayload(id: $0.id, label: $0.label, sessionId: $0.sessionID) }, message: message)
        guard let script = CodePaneBridge.dispatchEventScript(name: Self.agentStartStatusEventName, detail: payload) else { return }
        scriptEvaluator.evaluateCodePaneScript(script)
    }

    /// (Re)points the live diff-signature stream at `refName` if it isn't already there. A repeat
    /// `workspaceDiffManifestChunk` call for the same resolved scope is a no-op here — only an actual
    /// scope change tears down and reopens the stream.
    private func resubscribeDiffSignature(refName: String?, lastCommit: Bool, device: SpacesPairedDeviceRecord) {
        guard subscribedScope != .scope(refName: refName, lastCommit: lastCommit) else { return }
        // Defensive: in the normal flow `lastActedScopeSignature` is already refreshed for `refName`
        // before this runs (`performWorkspaceDiffManifestChunk` sets it, then calls this), including for a
        // disconnect-driven reconnect to the SAME scope (nothing here touches it, so a connect frame
        // repeating an unchanged signature is still correctly suppressed — see
        // `handleDiffSignatureFrame`). This only guards a hypothetical future caller that resubscribes
        // without having freshened it first.
        if lastActedScope != .scope(refName: refName, lastCommit: lastCommit) {
            lastActedScopeSignature = nil
            lastActedScope = .none
        }
        diffSignatureStream?.stop()
        diffSignatureStream = nil
        subscribedScope = .scope(refName: refName, lastCommit: lastCommit)
        diffSignatureSubscriptionGeneration += 1
        let subscriptionGeneration = diffSignatureSubscriptionGeneration
        let workspaceID = workspaceID
        let deviceGateway = deviceGateway
        // Built here, at MainActor isolation, rather than inside the task below: a weak-self capture
        // formed outside a `@Sendable` context and then merely *passed into* one as an already-built
        // `@Sendable` closure value is fine; re-deriving it from `self` from inside a non-isolated
        // closure is what the concurrency checker rejects.
        // `client.stop()` (called by the success-arm guard below, or by a later resubscribe) cannot
        // retract a frame that is already queued as a `Task { @MainActor in ... }` closure — the guard
        // here is what stops a stale A frame from being forwarded/recorded after B has taken over.
        // Mirrors `resubscribeFileSignature`'s `onFrame` guard exactly (see its doc comment for the
        // fuller stakes, which are worse on the file-signature side).
        let onFrame: @Sendable (SpacesDeviceWorkspaceDiffSignatureFrame) -> Void = { [weak self] frame in
            Task { @MainActor in
                guard let self, self.diffSignatureSubscriptionGeneration == subscriptionGeneration else { return }
                self.handleDiffSignatureFrame(frame)
            }
        }
        let onDisconnect: @Sendable ((any Error)?) -> Void = { [weak self] _ in
            Task { @MainActor in self?.handleDiffSignatureDisconnect(subscriptionGeneration: subscriptionGeneration) }
        }
        Task { [weak self] in
            do {
                let client = try await deviceGateway.subscribeWorkspaceDiffSignature(
                    workspaceID: workspaceID, refName: refName, lastCommit: lastCommit, device: device, onFrame: onFrame, onDisconnect: onDisconnect)
                // The pane may have deactivated, or resubscribed to a different scope, while this was
                // in flight; only keep the client if it's still the one this scope wants. Scope alone
                // is not enough: a rapid A → B → A scope-change sequence can land a STALE A attempt's
                // completion here after a newer A attempt has already taken over — `subscribedScope ==
                // .scope(refName: refName, lastCommit: lastCommit)` would read true again even though this in-flight `Task` belongs to a
                // completely different (superseded) subscription attempt than the one that's actually
                // current. `subscriptionGeneration` is the identity of this one ATTEMPT, not just its
                // target scope, so it's what actually tells a stale A from the current A apart. Without
                // it, a stale success either bare-assigns over the current client with no `.stop()`
                // (leaking the stream the current attempt installed), or installs itself as the live
                // client while carrying an `onDisconnect` that closed over its own now-dead generation —
                // when that stale client eventually disconnects, `handleDiffSignatureDisconnect`'s own
                // generation guard correctly refuses to act on it, so the pane silently stops
                // reconnecting until something else forces a fresh resubscribe.
                guard let self, self.subscribedScope == .scope(refName: refName, lastCommit: lastCommit),
                    self.diffSignatureSubscriptionGeneration == subscriptionGeneration, self.webView != nil
                else {
                    client.stop()
                    return
                }
                self.diffSignatureStream = client
                self.diffSignatureReconnectFailures = 0
            } catch {
                // Subscribing is a best-effort live-refresh add-on; a failure here doesn't affect
                // the diff result already delivered, so nothing more is surfaced to the web app
                // beyond scheduling a retry (below) — this arm runs both for a first-attempt
                // subscribe failure and for a backoff retry's own subscribe call failing, since both
                // go through this same code path.
                //
                // Same staleness concern as the success arm above, and the same fix: a stale attempt's
                // failure must not clear `subscribedScope`/schedule a reconnect for a newer, still-live
                // subscription that has nothing to do with this failure — `subscriptionGeneration` (not
                // just scope) is what tells them apart.
                guard let self, self.subscribedScope == .scope(refName: refName, lastCommit: lastCommit),
                    self.diffSignatureSubscriptionGeneration == subscriptionGeneration
                else { return }
                self.subscribedScope = .none
                self.scheduleDiffSignatureReconnect(refName: refName, lastCommit: lastCommit, generation: subscriptionGeneration)
            }
        }
    }

    /// Clears `subscribedScope`/`diffSignatureStream` after a real disconnect (daemon restart,
    /// network drop) so the next same-scope `workspaceDiffManifestChunk` call resubscribes instead of skipping
    /// forever via `resubscribeDiffSignature`'s `guard subscribedScope != .scope(refName:lastCommit:)`, and starts
    /// a bounded-backoff retry loop (see `scheduleDiffSignatureReconnect`) so a pane's live updates
    /// recover on their own instead of staying dead until the user happens to change scope (see
    /// docs/spec.md's "live-updates as the working tree changes" promise). Guarded by
    /// `subscriptionGeneration` (see its doc comment) so a disconnect belonging to an already-
    /// superseded subscription can't clobber a newer one's state.
    ///
    /// A successful retry needs no explicit nudge to the web app: `DeviceOverviewStreamServer`
    /// sends the subscription's current signature as the very first frame on connect (before its
    /// periodic broadcast timer ever fires — confirmed in `acceptReadyConnections`), which flows
    /// through `handleDiffSignatureFrame` → `spaces:diffSignature` → the web app's refresh exactly
    /// like any later frame. That connect-time frame is what makes reconnect self-healing for any
    /// changes missed during the outage.
    private func handleDiffSignatureDisconnect(subscriptionGeneration: Int) {
        guard subscriptionGeneration == diffSignatureSubscriptionGeneration else { return }
        diffSignatureStream = nil
        // Capture before clearing: the scheduled retry below needs the dropped subscription's scope
        // to retarget the same (ref, lastCommit) pair once the backoff elapses.
        let refName: String?
        let lastCommit: Bool
        if case .scope(let capturedRefName, let capturedLastCommit) = subscribedScope {
            refName = capturedRefName
            lastCommit = capturedLastCommit
        } else {
            refName = nil
            lastCommit = false
        }
        subscribedScope = .none
        scheduleDiffSignatureReconnect(refName: refName, lastCommit: lastCommit, generation: subscriptionGeneration)
    }

    /// Schedules the next reconnect attempt for the diff-signature stream on a bounded-exponential
    /// curve from `diffSignatureReconnectFloor` to `diffSignatureReconnectCap` (1s, 2s, 4s, 8s… capped
    /// at 30s by default), retrying indefinitely while the pane stays activated. No jitter: unlike
    /// `TerminalStateStreamReconnectBackoff` (which paces many terminal sessions reconnecting to the
    /// same daemon), a code pane's diff-signature stream is a single subscriber, so there's no
    /// thundering-herd problem to spread out.
    ///
    /// `generation` is the subscription generation that just failed/disconnected. When the delay
    /// elapses, the attempt only proceeds if nothing newer has taken over in the meantime —
    /// `deactivate()`/`close()` (via `teardownWebView` bumping the generation), a user-triggered
    /// `workspaceDiffManifestChunk` for a different scope, or an earlier retry already succeeding all bump
    /// `diffSignatureSubscriptionGeneration`, which makes this check fail and the attempt a no-op.
    private func scheduleDiffSignatureReconnect(refName: String?, lastCommit: Bool, generation: Int) {
        diffSignatureReconnectFailures += 1
        let delay = RemoteConnectionBackoff.delay(
            consecutiveFailures: diffSignatureReconnectFailures, floor: diffSignatureReconnectFloor, cap: diffSignatureReconnectCap, jitterFraction: 0
        )
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.diffSignatureSubscriptionGeneration == generation else { return }
            // The device is nil by contract for exactly the window a daemon restart's disconnect
            // fires retries into (`deviceForMutation`/`deviceAcceptsDaemonActions` refuse it while the
            // device can't take daemon actions) — treating that as a dead end would make the very
            // first retry after a restart-triggered disconnect always fail permanently. Reschedule
            // instead: this is just another failed attempt, same as a subscribe throwing below.
            guard let hosting = self.hosting, let device = hosting.codePaneDevice(workspaceID: self.workspaceID) else {
                self.scheduleDiffSignatureReconnect(refName: refName, lastCommit: lastCommit, generation: generation)
                return
            }
            self.resubscribeDiffSignature(refName: refName, lastCommit: lastCommit, device: device)
        }
    }

    /// Invariant: a frame is forwarded iff its `scopeSignature` differs from the last diff the web
    /// app is known to have fetched for the current scope (`lastActedScopeSignature`). Every scope
    /// change (an ordinary `workspaceDiffManifestChunk` fetch, or a stream reconnect after an outage — see
    /// `resubscribeDiffSignature`'s doc comment) opens with a connect-time frame carrying that scope's
    /// current signature; forwarding it unconditionally would trigger a second, redundant metadata
    /// manifest fetch plus its separately scheduled file-patch chunks the web app just performed a
    /// moment ago (a scope switch) or doesn't need (a reconnect where nothing changed while disconnected).
    /// Err toward forwarding: any
    /// doubt must forward, since a spurious refetch is cheap but a wrongly suppressed real change
    /// leaves the view stale until the next signature change.
    private func handleDiffSignatureFrame(_ frame: SpacesDeviceWorkspaceDiffSignatureFrame) {
        guard frame.scopeSignature != lastActedScopeSignature else { return }
        guard isReady, let scriptEvaluator else { return }
        guard
            let script = CodePaneBridge.dispatchEventScript(
                name: Self.diffSignatureEventName, detail: CodePaneBridge.DiffSignaturePayload(scopeSignature: frame.scopeSignature))
        else { return }
        // Only recorded once the frame is actually about to be forwarded: if the page isn't ready
        // (below) the web app never saw this signature, so a later identical frame must still forward
        // once it is.
        lastActedScopeSignature = frame.scopeSignature
        scriptEvaluator.evaluateCodePaneScript(script)
    }

    /// (Re)points the live file-signature stream at `path` if it isn't already there. A repeat
    /// `workspaceFileRead` call for the same path (e.g. a save's own read-back, or a redundant refetch)
    /// is a no-op here — only actually opening a different file tears down and reopens the stream.
    /// Mirrors `resubscribeDiffSignature` exactly.
    private func resubscribeFileSignature(path: String, device: SpacesPairedDeviceRecord) {
        guard subscribedFilePath != path else { return }
        if lastActedFilePath != path {
            lastActedFileSignatureValue = nil
            lastActedFilePath = nil
        }
        fileSignatureStream?.stop()
        fileSignatureStream = nil
        subscribedFilePath = path
        fileSignatureSubscriptionGeneration += 1
        let subscriptionGeneration = fileSignatureSubscriptionGeneration
        let workspaceID = workspaceID
        let deviceGateway = deviceGateway
        // `client.stop()` (called by the success-arm guard below, or by a later resubscribe) cannot
        // retract a frame that is already queued as a `Task { @MainActor in ... }` closure: without this
        // guard, a stale frame from a superseded subscription (e.g. file A's stream, still delivering
        // after the pane retargeted to file B) would reach `handleFileSignatureFrame` and get forwarded
        // to the web app AND recorded into `lastActedFileSignatureValue`. That's deadly specifically for
        // "missing" frames, since every path's missing-frame carries the identical `(sha256: nil, missing:
        // true)` value — a stale missing-frame left over from A would poison the dedupe state such that
        // B's later REAL deletion frame gets wrongly suppressed as a duplicate. A deletion has no
        // follow-up frame to self-heal from, so the editor pane would show stale content indefinitely
        // until some unrelated event forced a fresh open. Mirrors `resubscribeDiffSignature`'s `onFrame`
        // guard exactly.
        let onFrame: @Sendable (SpacesDeviceWorkspaceFileSignatureFrame) -> Void = { [weak self] frame in
            Task { @MainActor in
                guard let self, self.fileSignatureSubscriptionGeneration == subscriptionGeneration else { return }
                self.handleFileSignatureFrame(frame)
            }
        }
        let onDisconnect: @Sendable ((any Error)?) -> Void = { [weak self] _ in
            Task { @MainActor in self?.handleFileSignatureDisconnect(subscriptionGeneration: subscriptionGeneration) }
        }
        Task { [weak self] in
            do {
                let client = try await deviceGateway.subscribeWorkspaceFileSignature(
                    workspaceID: workspaceID, relativePath: path, device: device, onFrame: onFrame, onDisconnect: onDisconnect)
                // Same staleness concern `resubscribeDiffSignature`'s success arm guards against: a
                // rapid A → B → A path-change sequence can land a stale A attempt's completion after a
                // newer A attempt has already taken over, so `subscriptionGeneration` (identity of this
                // one ATTEMPT), not just the target path, is what tells them apart.
                guard let self, self.subscribedFilePath == path, self.fileSignatureSubscriptionGeneration == subscriptionGeneration,
                    self.webView != nil
                else {
                    client.stop()
                    return
                }
                self.fileSignatureStream = client
                self.fileSignatureReconnectFailures = 0
            } catch {
                // Subscribing is a best-effort live-refresh add-on; a failure here doesn't affect the
                // read result already delivered, so nothing more is surfaced to the web app beyond
                // scheduling a retry (below) — mirrors `resubscribeDiffSignature`'s failure arm exactly.
                guard let self, self.subscribedFilePath == path, self.fileSignatureSubscriptionGeneration == subscriptionGeneration else { return }
                self.subscribedFilePath = nil
                self.scheduleFileSignatureReconnect(path: path, generation: subscriptionGeneration)
            }
        }
    }

    /// Clears `subscribedFilePath`/`fileSignatureStream` after a real disconnect and starts a
    /// bounded-backoff retry loop. Mirrors `handleDiffSignatureDisconnect` exactly.
    private func handleFileSignatureDisconnect(subscriptionGeneration: Int) {
        guard subscriptionGeneration == fileSignatureSubscriptionGeneration else { return }
        fileSignatureStream = nil
        // Capture before clearing: the scheduled retry below needs the dropped subscription's path to
        // retarget the same file once the backoff elapses.
        let path = subscribedFilePath
        subscribedFilePath = nil
        guard let path else { return }
        scheduleFileSignatureReconnect(path: path, generation: subscriptionGeneration)
    }

    /// Schedules the next reconnect attempt for the file-signature stream on the same bounded-
    /// exponential curve `scheduleDiffSignatureReconnect` uses (see its doc comment), against this
    /// stream's own floor/cap/failure-count fields.
    private func scheduleFileSignatureReconnect(path: String, generation: Int) {
        fileSignatureReconnectFailures += 1
        let delay = RemoteConnectionBackoff.delay(
            consecutiveFailures: fileSignatureReconnectFailures, floor: fileSignatureReconnectFloor, cap: fileSignatureReconnectCap, jitterFraction: 0
        )
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.fileSignatureSubscriptionGeneration == generation else { return }
            // Mirrors `scheduleDiffSignatureReconnect`'s device-unavailable reschedule: the device is
            // nil by contract for exactly the window a daemon restart's disconnect fires retries into.
            guard let hosting = self.hosting, let device = hosting.codePaneDevice(workspaceID: self.workspaceID) else {
                self.scheduleFileSignatureReconnect(path: path, generation: generation)
                return
            }
            self.resubscribeFileSignature(path: path, device: device)
        }
    }

    /// Invariant: a frame is forwarded iff its `(sha256, missing)` pair differs from the last file read
    /// the web app is known to have fetched for the current path (`lastActedFileSignatureValue`).
    /// Mirrors `handleDiffSignatureFrame` exactly.
    private func handleFileSignatureFrame(_ frame: SpacesDeviceWorkspaceFileSignatureFrame) {
        let value = FileSignatureValue(sha256: frame.sha256, missing: frame.missing)
        guard value != lastActedFileSignatureValue else { return }
        guard isReady, let scriptEvaluator else { return }
        guard
            let script = CodePaneBridge.dispatchEventScript(
                name: Self.fileSignatureEventName,
                detail: CodePaneBridge.FileSignaturePayload(path: frame.path, sha256: frame.sha256, missing: frame.missing))
        else { return }
        // Only recorded once the frame is actually about to be forwarded: if the page isn't ready
        // (above) the web app never saw this value, so a later identical frame must still forward once
        // it is.
        lastActedFileSignatureValue = value
        scriptEvaluator.evaluateCodePaneScript(script)
    }

    // MARK: - Replies

    private func reply(id: String, generation: Int, result: some Encodable) {
        guard generation == pageGeneration, let scriptEvaluator else { return }
        guard let script = CodePaneBridge.resolveScript(id: id, result: result) else {
            reply(id: id, generation: generation, error: CodePaneBridge.BridgeError(code: .internalError, message: "Failed to encode the result."))
            return
        }
        scriptEvaluator.evaluateCodePaneScript(script)
    }

    private func reply(id: String, generation: Int, error: CodePaneBridge.BridgeError) {
        guard generation == pageGeneration, let scriptEvaluator else { return }
        scriptEvaluator.evaluateCodePaneScript(CodePaneBridge.rejectScript(id: id, error: error))
    }
}

extension CodePaneContentController: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { handleScriptMessage(name: message.name, body: message.body, senderWebView: message.webView) }
    }
}

extension CodePaneMode {
    var wireValue: String {
        switch self {
        case .diff: "diff"
        case .editor: "editor"
        }
    }

    /// Inverse of `wireValue` — decodes a complete workspace state's mode string. The web contract
    /// restricts this to `"diff"`/`"editor"`, so the default arm is only defensive.
    init(wireValue: String) { self = wireValue == "editor" ? .editor : .diff }
}
