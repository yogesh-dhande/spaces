import AppKit
import WebKit
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import spacesterminalghostty

/// The Editor pane's current view: reviewing working-tree changes, or editing a file. Every pane opens
/// in `.diff` (see `PanelCoordinator.openOrFocusGlobalEditorWindow`); `.editor` is reached only by
/// switching views from inside the pane itself (`spaces:setMode`). The mode is carried purely as a
/// runtime hint to the controller and is never persisted — a restored pane always rebuilds as `.diff`,
/// since the `.codePane` descriptor alone cannot say which view was showing.
enum CodePaneMode: Equatable {
    case diff
    case editor
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
    private static let messageHandlerName = "spacesBridge"
    private static let initEventName = "spaces:init"
    private static let themeEventName = "spaces:theme"
    private static let diffSignatureEventName = "spaces:diffSignature"
    private static let fileSignatureEventName = "spaces:fileSignature"
    private static let agentsEventName = "spaces:agents"
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

    /// Bumped every time `installWebView()` creates a fresh page. The web app's own JS request-id
    /// counter (`realBridge.ts`) restarts at 1 on every page load, so an id alone can't disambiguate a
    /// reply meant for a hibernation cycle's torn-down page from one meant for the page that replaced
    /// it. `dispatch(_:)` captures the generation live at the moment a request arrives and threads it
    /// through to `reply(id:generation:...)`, which drops the reply once the page has moved on.
    private var pageGeneration = 0

    /// Bumped on every `workspaceDiff` call; the captured value only lets `performWorkspaceDiff`'s
    /// completion retarget the live diff-signature stream (`resubscribeDiffSignature`) if it is still
    /// the latest one handed out. This is a different concern from `pageGeneration` above: a stale
    /// diff response's JS reply must still always go out (the web side matches replies by id and
    /// doesn't care which scope is "current"), but pointing the shared stream at a scope the user has
    /// already navigated away from would visibly regress the live view even on the very same page.
    private var latestDiffRequestToken = 0

    /// The (workspace, ref) scope the live diff-signature stream is pointed at. Every `workspaceDiff`
    /// call is the signal to (re)point this: `realBridge.ts`'s `subscribeDiffSignature` never messages
    /// Swift at all (see its doc comment), so the resolved scope of each diff fetch is the only place
    /// scope changes are observable from the host side. Also cleared by an actual stream disconnect
    /// (see `handleDiffSignatureDisconnect`), so a same-scope `workspaceDiff` after a daemon restart
    /// resubscribes instead of silently no-op'ing forever.
    private enum DiffSignatureScope: Equatable {
        case none
        case scope(String?)
    }
    private var subscribedScope: DiffSignatureScope = .none
    /// The `scopeSignature` of the last diff the web app is known to have fetched for the current
    /// scope — set the moment a `workspaceDiff` reply for the still-current request is delivered (see
    /// `performWorkspaceDiff`), paired with the scope it was recorded for so a resubscribe that
    /// targets a different scope can tell it's stale (defensive: in practice `performWorkspaceDiff`
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

    /// The web app's last-known open-editor snapshot, pushed via the `editorStateChanged`
    /// notification (see `CodePaneBridge.EditorState`). Lives on the controller — which survives
    /// hibernation — rather than the `WKWebView` — which does not — so an editor's unsaved buffer
    /// and CAS baseline are restored, not lost, when a tab or workspace switch tears the page down
    /// and later rebuilds it: `handleReady()` below hands this back through `spaces:init`'s
    /// `editorState` field. Cleared by `close()` (the pane itself is gone) but not by
    /// `deactivate()` (hibernation only). No disk persistence, so an app restart starts clean —
    /// an accepted boundary (see docs/implementation.md's hibernation section).
    private var editorState: CodePaneBridge.EditorState?
    /// The page generation that most recently wrote `editorState` — via either a debounced push
    /// (`handleEditorStateChanged`) or a teardown flush (`flushPendingEditorState`'s completion). A
    /// flush only applies its result when its captured generation is `>=` this value: within one page
    /// generation a flush always reads state at least as fresh as any of that page's own prior pushes
    /// (it queries the editor's live fields directly, bypassing the debounce timer), so `>=` — not the
    /// stricter `==` — is what lets a same-generation flush still (re)apply, while a flush from an
    /// older generation a newer page has since written over is correctly rejected. Bumped by `close()`
    /// too, so a flush already in flight when the pane closes for good can't resurrect the snapshot
    /// `close()` just discarded.
    private var editorStateGeneration = 0

    /// round-10: the most recently committed `workspaceFileWrite`'s outcome, used to fold that write
    /// into a teardown-flushed `editorState` snapshot that still carries the pre-write baseline — see
    /// `adoptCommittedWriteIntoEditorState`. round-12: lives only for the duration of the write/flush
    /// race it bridges — cleared by `clearCommittedFileWriteIfSettled()` once both
    /// `outstandingFileWriteCount` and `outstandingTeardownFlushCount` are back at zero. The CAS-chain
    /// guard inside `adoptCommittedWriteIntoEditorState` is not sufficient on its own across time:
    /// hashes can recur (an ABA hazard — see `clearCommittedFileWriteIfSettled`'s doc comment for the
    /// full scenario), so the record must not survive past the race window it exists to bridge.
    private var lastCommittedFileWrite: (path: String, expectedBase: String?, sha256: String, content: String)?

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
        if outstandingFileWriteCount == 0, outstandingTeardownFlushCount == 0 {
            lastCommittedFileWrite = nil
        }
    }

    /// round-16 Fix 1a: the web app's last-known teardown snapshot of comment text typed but not yet
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
    /// The page generation that most recently wrote `pendingReviewCommentState` — mirrors
    /// `editorStateGeneration` exactly, but kept as an independent counter (not reused) since the two
    /// snapshots are written by unrelated flushes and gating one against the other's generation would
    /// let an editor-only (or comment-only) flush incorrectly block the other's apply.
    private var pendingReviewCommentStateGeneration = 0

    /// Count of teardown flushes (`flushPendingEditorState` AND, since round-16 Fix 1a,
    /// `flushPendingReviewCommentState`) started but not yet answered. Bumped when a flush actually
    /// kicks off, decremented once its completion applies (or discards) its result. `handleReady()`
    /// reads this to know whether a flush from the just-torn-down page could still overwrite
    /// `editorState`/`pendingReviewCommentState` with fresher content than whatever is on hand right
    /// now — see `deferredReadyGeneration` below for why that matters. A counter, not a flag, because a
    /// pane can in principle rack up more than one outstanding flush (teardown → reactivate → teardown
    /// again, all before the first flush's `evaluateJavaScript` round trip returns, or the editor and
    /// comment-state flushes from the very same teardown both still in flight); `handleReady()` must
    /// wait for all of them, not just the most recent. `evaluateJavaScript` (what `evaluateCodePaneScript`
    /// wraps) always calls its completion, success or failure, so this is guaranteed to return to zero
    /// and never strands a deferred `ready` forever. Folded into one counter (renamed from
    /// `outstandingEditorFlushCount`) rather than tracked separately per flush kind: both flushes gate
    /// the exact same `ready` decision, so one shared count is the cleaner mirror and there is nothing
    /// either flush kind needs to know about the other's count.
    private var outstandingTeardownFlushCount = 0
    /// round-16 Fix 1b: count of in-flight review-comment mutation RPCs (`reviewCommentUpsert`/
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
    /// round-10: count of in-flight `workspaceFileWrite` RPCs. A write outstanding at `ready` time can
    /// still change what `editorState` should read once it completes — its completion adopts the
    /// committed baseline into the flushed snapshot (see `adoptCommittedWriteIntoEditorState`), and
    /// answering `ready` first would rehydrate the page against the pre-save baseline, making it treat
    /// its own save as an external change (a false diff3 merge or conflict banner — the fresh page has
    /// no `pendingSaveSubmitted` to recognize its own just-landed save). Mirrors
    /// `outstandingReviewCommentMutationCount` exactly: bumped right before the RPC's `Task` starts,
    /// decremented — unconditionally, success or failure — in its completion.
    private var outstandingFileWriteCount = 0
    /// The page generation `handleReady()` was called for when it deferred sending `spaces:init`
    /// because `outstandingTeardownFlushCount`/`outstandingReviewCommentMutationCount`/
    /// `outstandingFileWriteCount` was nonzero —
    /// `nil` when nothing is deferred. Sending init immediately in that state would ship the stale
    /// pre-flush `editorState`/`pendingReviewCommentState`, and once the flush's completion did land,
    /// `storeFlushedEditorState`'s `generation >= editorStateGeneration` guard (and its
    /// `storeFlushedReviewCommentState` sibling) would silently drop it (this page's own activity can
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
    /// they left it (via the `modeChanged` push — see `handleModeChanged`). Survives hibernation
    /// like `editorState` above (cleared only by `close()`), so a pane hibernated in Editor mode
    /// comes back in Editor mode instead of resetting to whichever mode originally created it.
    private var currentMode: CodePaneMode

    var onTitleChanged: ((String) -> Void)?

    init(
        paneID: String, deviceID: String, workspaceID: String, initialMode: CodePaneMode, hosting: any CodePaneHosting,
        deviceGateway: any CodePaneDeviceGateway = LiveCodePaneDeviceGateway()
    ) {
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.descriptor = .codePane(deviceID: deviceID, workspaceID: workspaceID)
        self.initialMode = initialMode
        self.currentMode = initialMode
        self.hosting = hosting
        self.deviceGateway = deviceGateway
        super.init()
        rootView.wantsLayer = true
        rootView.setAccessibilityIdentifier("code-pane-\(paneID)")
        bindAppearanceReactiveLayer(rootView) { view in view.layer?.backgroundColor = NSColor.activeTheme(\.terminal.background).cgColor }
    }

    var contentView: NSView { rootView }
    /// "Code — <workspace name>" for every code pane, not only ones in a global panel window's
    /// retargeting monitor: a workspace panel's code pane already reads unambiguously from its tab
    /// bar's own workspace context, but a uniform title is simpler than a scope-conditional one and
    /// still correct there, and it is what a monitor's retarget needs to actually change when it
    /// swaps workspaces (see `PanelCoordinator.retargetGlobalWindowCodePanes`). Falls back to the raw
    /// workspace id, mirroring `sendInitPayload`'s `workspaceName` resolution, for the brief window
    /// before the workspace's overview data has loaded.
    var displayTitle: String {
        let workspaceName = hosting?.codePaneWorkspaceInfo(workspaceID: workspaceID)?.name ?? workspaceID
        return "Code — \(workspaceName)"
    }

    func activate(focus: Bool) {
        if webView == nil { installWebView() }
        if focus { _ = makeContentFirstResponder() }
    }

    /// Tears the web view down; `rootView` is left in place so the pane tree keeps a stable view to
    /// re-parent the next time this pane becomes visible. `editorState`/`currentMode` are left
    /// untouched — hibernation must not lose them (see their doc comments).
    func deactivate() { teardownWebView() }

    /// The pane itself is going away for good, not just hibernating: on top of `deactivate()`'s web
    /// view teardown, discard the in-memory editor snapshot and live-mode tracking too, since there
    /// is no pane left for a future `spaces:init` to ever rehydrate them into.
    ///
    /// Both callers of `close()` (an ordinary pane close and
    /// `PanelCoordinator.retargetGlobalWindowCodePanes`'s close-and-reinstall) discard this instance
    /// afterward rather than ever reactivating it, so the generation bumps below only need to hold for
    /// as long as this instance keeps existing — they do not need to protect a hypothetical later
    /// `activate()` on the same, already-closed instance (a scenario that does not occur in the
    /// product: a controller that has been closed is never handed a new lease on life, it is replaced).
    func close() {
        teardownWebView()
        editorState = nil
        // Invalidates a flush already in flight from the teardown just above: without this, its
        // completion would still satisfy `flushGeneration >= editorStateGeneration` (neither moves on
        // its own between the two calls) and could resurrect the snapshot this line just discarded.
        editorStateGeneration += 1
        // round-16 Fix 1a: mirrors the editorState treatment immediately above, for the same reason —
        // a comment-state flush already in flight from the teardown just above must not resurrect this
        // snapshot after close() just discarded it.
        pendingReviewCommentState = nil
        pendingReviewCommentStateGeneration += 1
        currentMode = initialMode
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
        guard let script = CodePaneBridge.dispatchEventScript(name: Self.themeEventName, detail: CodePaneBridge.ThemePayload(theme: appearance.rawValue))
        else { return }
        scriptEvaluator.evaluateCodePaneScript(script)
    }

    /// Called by `PanelCoordinator.updateCodePaneAgents` whenever the host reprocesses an overview
    /// for this pane's device — the same overview-apply call sites that already call
    /// `pruneOpenCodePanes`. Dedupes on the full running-agent set (array equality) so a routine
    /// overview refresh that didn't touch this workspace's agents doesn't spam the page with a
    /// no-op push, mirroring `applyAppearance`'s `currentTheme` guard above.
    func applyRunningAgents(_ agents: [CodePaneRunningAgent]) {
        guard currentAgents != agents else { return }
        currentAgents = agents
        guard isReady, let scriptEvaluator else { return }
        let payload = CodePaneBridge.AgentsPayload(agents: agents.map { CodePaneBridge.AgentPayload(id: $0.id, label: $0.label, sessionId: $0.sessionID) })
        guard let script = CodePaneBridge.dispatchEventScript(name: Self.agentsEventName, detail: payload) else { return }
        scriptEvaluator.evaluateCodePaneScript(script)
    }

    /// Pushes a mode switch into the page, or — if the page isn't live to receive a push — arranges
    /// for the pane's next load to open directly in `mode`. Called by `PanelCoordinator`'s navigation
    /// resolver to apply a reused/focused pane's requested mode (see docs/implementation.md).
    ///
    /// Deliberately does not set `currentMode` on the live-push path: `currentMode` is a
    /// single-source-of-truth mirror of the page's own live state (see its doc comment), fed only by
    /// `handleModeChanged`'s `modeChanged` echo — this method just asks the page to switch, the same
    /// way a toolbar click does, and waits for that same echo to confirm it landed. The not-live path
    /// (page torn down, or never loaded yet) has no page to echo back from, so it sets `currentMode`
    /// directly — exactly what `close()` already does when resetting to `initialMode`, and what
    /// `sendInitPayload` already reads (`currentMode`, not `initialMode`) to seed the next load.
    func requestMode(_ mode: CodePaneMode) {
        guard currentMode != mode else { return }
        guard isReady, let scriptEvaluator else {
            currentMode = mode
            return
        }
        guard let script = CodePaneBridge.dispatchEventScript(name: Self.setModeEventName, detail: CodePaneBridge.SetModePayload(mode: mode.wireValue))
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
    static func codePaneIndexURL() -> URL? {
        Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "CodePane")
    }

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
            webView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            webView.topAnchor.constraint(equalTo: rootView.topAnchor),
            webView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])
        self.webView = webView
        scriptEvaluator = webView
        isReady = false
        pageGeneration += 1
        // The built web bundle is checked into the package as a `.copy` resource; it must always be
        // present in a built app, so there is nothing to fall back to if it's missing, and the page
        // just stays blank.
        if baseDirectory != nil {
            webView.load(URLRequest(url: CodePaneSchemeHandler.entryURL))
        }
    }

    private func teardownWebView() {
        flushPendingEditorState()
        // round-16 Fix 1a: mirrors the editor-state flush immediately above — both are counted by the
        // same `outstandingTeardownFlushCount` (see its doc comment), so `handleReady()` waits for
        // whichever of the two is slower to answer.
        flushPendingReviewCommentState()
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
        // deactivate() still owns its token (the guard in `performWorkspaceDiff`'s completion would
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

    /// Pulls the web app's live editor snapshot before the page underneath it disappears, closing the
    /// race where a buffer edit inside `scheduleEditorStatePush`'s trailing debounce window is still
    /// unsent when the user switches away: unlike that debounced push, this asks the page directly and
    /// waits for its answer via `evaluateCodePaneScript(_:completion:)`'s return-value seam rather than
    /// the message channel — a message posted by JS right as its `WKUserContentController` is about to
    /// have its handler removed has no ordering guarantee against that removal, but a return value does
    /// not depend on the handler at all.
    private func flushPendingEditorState() {
        guard let webView, let scriptEvaluator else { return }
        let flushGeneration = pageGeneration
        outstandingTeardownFlushCount += 1
        // Strongly captured (not `[weak webView]`): `webView` is about to be removed from `rootView`
        // and have its message handler stripped by the rest of `teardownWebView()`, but its web
        // process must stay alive long enough for this in-flight `evaluateJavaScript` call to actually
        // finish and answer — an unretained `webView` here could be deallocated before that happens.
        scriptEvaluator.evaluateCodePaneScript(CodePaneBridge.collectEditorStateScript) { [weak self] result in
            withExtendedLifetime(webView) {
                self?.storeFlushedEditorState(CodePaneBridge.decodeCollectedEditorState(result), generation: flushGeneration)
                self?.outstandingTeardownFlushCount -= 1
                self?.clearCommittedFileWriteIfSettled()
                // A `handleReady()` deferred behind this flush (see `deferredReadyGeneration`) can now
                // go out — `editorState` above has just been settled for this flush's generation, so a
                // now-built `spaces:init` payload reads whatever it actually was, not a stale pre-flush
                // value.
                self?.resumeDeferredReadyIfNeeded()
            }
        }
    }

    /// round-16 Fix 1a: mirrors `flushPendingEditorState` exactly (see its doc comment for the
    /// return-value-vs-message-channel reasoning), but pulls the web app's live comment-draft snapshot
    /// instead — closes the same race for text typed into a comment textarea that hasn't blurred yet.
    private func flushPendingReviewCommentState() {
        guard let webView, let scriptEvaluator else { return }
        let flushGeneration = pageGeneration
        outstandingTeardownFlushCount += 1
        scriptEvaluator.evaluateCodePaneScript(CodePaneBridge.collectReviewCommentStateScript) { [weak self] result in
            withExtendedLifetime(webView) {
                self?.storeFlushedReviewCommentState(
                    CodePaneBridge.decodeCollectedReviewCommentState(result), generation: flushGeneration)
                self?.outstandingTeardownFlushCount -= 1
                self?.clearCommittedFileWriteIfSettled()
                self?.resumeDeferredReadyIfNeeded()
            }
        }
    }

    /// Applies a teardown flush's result under the same ordering rule `handleEditorStateChanged`
    /// writes under — see `editorStateGeneration`'s doc comment for the `>=` rule this enforces.
    /// `.notReported` returns immediately without touching `editorState` or `editorStateGeneration`:
    /// it carries no information (the page never got far enough to answer, or the evaluate call
    /// itself failed — see `CollectedEditorState`'s doc comment), so it must not consume or advance
    /// the generation-ordering slot — a later flush that DOES report something for the same or an
    /// earlier generation must still be accepted.
    private func storeFlushedEditorState(_ collected: CodePaneBridge.CollectedEditorState, generation: Int) {
        guard generation >= editorStateGeneration else { return }
        switch collected {
        case .notReported: return
        case .noFile: editorState = nil
        case .file(let state): editorState = state
        }
        editorStateGeneration = generation
        // round-10: a write can commit AFTER this flush already stored a snapshot at exactly the
        // pre-write baseline — see `adoptCommittedWriteIntoEditorState`'s doc comment for why this call
        // site, not just the write completion's own, is needed. A no-op when `editorState` is `nil`
        // (the `.noFile` case above) or when nothing committed matches: the method's own guard handles
        // both.
        adoptCommittedWriteIntoEditorState()
    }

    /// round-10: folds a committed write into the flushed editor snapshot so a page rehydrated after
    /// hibernation starts from the baseline its own save established, instead of treating that save as
    /// an external change. CAS-chain guard: the snapshot is patched only when its `baseSHA256` equals
    /// the base the write was issued against — a snapshot at that baseline provably predates the
    /// write's landing, while any other baseline already reflects the write or something newer and must
    /// be left alone. round-12: the record's lifetime is bounded separately by
    /// `clearCommittedFileWriteIfSettled()` (see its doc comment for why the CAS-chain guard alone is
    /// not enough across time). Called from both the write completion and `storeFlushedEditorState`,
    /// because the flush and the write settle in either order — patching only at completion would be overwritten by
    /// a later-arriving flush that stored the pre-write snapshot; patching only at flush time would miss
    /// a write that completes and commits its baseline AFTER the flush already stored a snapshot at
    /// that exact pre-write baseline.
    ///
    /// Known accepted gap: a write issued while the file was missing on disk sends a nil
    /// `expectedSHA256` (see `editorView.ts`'s `diskMissing` handling) while the snapshot still carries
    /// the old (non-nil) `baseSHA256` — the guard below then never matches, so a recreate-during-
    /// hibernation is not adopted here; that compound case falls back to the ordinary
    /// `handleExternalChange` reconcile on the rehydrated page.
    private func adoptCommittedWriteIntoEditorState() {
        guard let write = lastCommittedFileWrite, let state = editorState,
            state.path == write.path, state.baseSHA256 == write.expectedBase
        else { return }
        var newDirty = state.dirty
        var newConflict = state.conflict
        if state.content == write.content {
            // Nothing was typed after the save click: the buffer is exactly the committed content — a
            // clean file at the new baseline (this also covers a Keep-mine write that was in flight at
            // teardown: its snapshot's content IS the mine buffer it wrote).
            newDirty = false
            newConflict = false
        }
        // else: post-click typing stays dirty against the adopted baseline; `conflict` is left
        // untouched (a conflicted snapshot's buffer is not editable, so content always equals the
        // Keep-mine write's content and lands in the branch above).
        editorState = CodePaneBridge.EditorState(
            path: state.path, baseSHA256: write.sha256, baseContent: write.content, content: state.content, dirty: newDirty, conflict: newConflict)
    }

    /// round-16 Fix 1a: mirrors `storeFlushedEditorState` exactly, against the independent
    /// `pendingReviewCommentStateGeneration` guard (see its doc comment for why it is not shared with
    /// `editorStateGeneration`). `.none` (the `'__none__'` sentinel) clears the stored snapshot, the
    /// same way `.noFile` clears `editorState`.
    private func storeFlushedReviewCommentState(_ collected: CodePaneBridge.CollectedReviewCommentState, generation: Int) {
        guard generation >= pendingReviewCommentStateGeneration else { return }
        switch collected {
        case .notReported: return
        case .none: pendingReviewCommentState = nil
        case .entries(let entries): pendingReviewCommentState = entries
        }
        pendingReviewCommentStateGeneration = generation
    }

    // MARK: - Bridge dispatch

    /// The actual body of `WKScriptMessageHandler.userContentController(_:didReceive:)`, split out
    /// because `WKScriptMessage` has no public initializer a test can construct (see below) — this
    /// takes its three relevant fields directly so a test can drive the sender-identity guard without
    /// needing a real `WKScriptMessage`.
    ///
    /// `senderWebView === webView` is checked once here, ahead of every kind of message (`ready`, an
    /// editor-state/mode push, or an RPC request): WebKit can deliver a message a page queued before
    /// it was itself torn down (a rapid deactivate→reactivate hibernation cycle is the case that
    /// matters — see the class doc comment) *after* its replacement page is already installed, and
    /// message ordering across that transition is not guaranteed. Sender identity is the only reliable
    /// way to tell that stale message apart from a live one — a `ready` from the old page marking the
    /// new page ready before its own JS listener even exists would hang the pane, and a stale RPC
    /// executing under the replacement's generation would reply to a request nobody sent. `webView`
    /// being `nil` (no live page installed at all) also fails this comparison, correctly — there is
    /// nothing live to process for.
    ///
    /// This makes the `senderWebView` checks inside `handleEditorStateChanged`/`handleModeChanged`
    /// redundant for anything that arrives through this method — deliberately left in place rather
    /// than removed, since those two are also driven directly by tests (and, in principle, could be
    /// driven by other callers) that don't go through this guard at all; the overlap is intentional
    /// defense-in-depth, not an oversight.
    func handleScriptMessage(name: String, body: Any, senderWebView: WKWebView?) {
        guard name == Self.messageHandlerName else { return }
        guard senderWebView != nil, senderWebView === webView else { return }
        if CodePaneBridge.isReady(body: body) {
            handleReady()
            return
        }
        switch CodePaneBridge.decodeEditorStateChanged(body: body) {
        case .file(let state):
            handleEditorStateChanged(state, senderWebView: senderWebView)
            return
        case .noFile:
            handleEditorStateChanged(nil, senderWebView: senderWebView)
            return
        case .notThisMessage:
            break
        }
        if let mode = CodePaneBridge.decodeModeChanged(body: body) {
            handleModeChanged(CodePaneMode(wireValue: mode), senderWebView: senderWebView)
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
        guard outstandingTeardownFlushCount == 0, outstandingReviewCommentMutationCount == 0, outstandingFileWriteCount == 0 else {
            // A flush kicked off by tearing down the page before this one (see
            // `flushPendingEditorState`/`flushPendingReviewCommentState`), a review-comment mutation
            // RPC still in flight from before that (round-16 Fix 1b — see
            // `outstandingReviewCommentMutationCount`'s doc comment), or a `workspaceFileWrite` RPC
            // still in flight (round-10 — see `outstandingFileWriteCount`'s doc comment), may still be
            // outstanding and could still change what `editorState`/`pendingReviewCommentState` should
            // read right now. See `deferredReadyGeneration`'s doc comment for why sending `spaces:init`
            // before that lands would lose content for good rather than merely delay it. Capture the
            // generation this `ready` belongs to and let the outstanding work's completion resume this
            // once settled (`resumeDeferredReadyIfNeeded`).
            deferredReadyGeneration = pageGeneration
            return
        }
        sendInitPayload(scriptEvaluator: scriptEvaluator, hosting: hosting)
    }

    /// Fires the `handleReady()` continuation deferred while a teardown flush, review-comment mutation
    /// RPC, or file-write RPC was outstanding (see `deferredReadyGeneration`), once every such
    /// flush/RPC has settled (`outstandingTeardownFlushCount`, `outstandingReviewCommentMutationCount`,
    /// and `outstandingFileWriteCount` all back at zero — see their doc comments for why counts, not
    /// flags). Re-verifies the deferred generation
    /// is still the live page: the page that was waiting can itself have been torn down again (a second
    /// `deactivate()`/`activate()` cycle) before this flush's completion landed, in which case there is
    /// nothing to resume — that page is gone, `scriptEvaluator` no longer points at it, and whichever
    /// page is current now will get its own `ready` → `handleReady()` call in due course.
    private func resumeDeferredReadyIfNeeded() {
        guard outstandingTeardownFlushCount == 0, outstandingReviewCommentMutationCount == 0, outstandingFileWriteCount == 0,
            let generation = deferredReadyGeneration
        else { return }
        deferredReadyGeneration = nil
        guard generation == pageGeneration, let scriptEvaluator, let hosting else { return }
        sendInitPayload(scriptEvaluator: scriptEvaluator, hosting: hosting)
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
        // Same emptiness rule as `refName(for:)`'s `.baseBranch` case: an empty string reads as "no
        // base branch configured", not a literal branch named "".
        let baseBranch = workspaceInfo?.baseBranch.flatMap { $0.isEmpty ? nil : $0 }
        // Reuses whatever `applyRunningAgents` already recorded (e.g. from an overview that landed
        // while this pane was still loading) instead of re-querying, so init and the dedupe guard
        // agree on the same value — matches `currentTheme`'s `??` fallback just above.
        let agents = currentAgents ?? hosting.codePaneRunningAgents(workspaceID: workspaceID)
        currentAgents = agents
        let payload = CodePaneBridge.InitPayload(
            workspaceId: workspaceID, workspaceName: workspaceName,
            // `currentMode`, not `initialMode`: after a hibernation cycle this is wherever the user
            // last left the in-page toolbar (see `currentMode`'s doc comment), so a pane hibernated
            // in Editor mode restores to Editor mode rather than resetting to its original entry point.
            initialMode: currentMode.wireValue,
            // Every code pane opens on the uncommitted-vs-HEAD scope; the toolbar's scope control
            // (see CodePaneWeb's toolbar.ts) is what moves it from there.
            initialScope: .init(kind: "uncommitted", refName: nil), theme: appearance.rawValue, baseBranch: baseBranch,
            editorState: editorState,
            // round-16 Fix 1a: only present when a teardown flush actually captured something (mirrors
            // `editorState`'s own nil-when-empty handling above) — `InitPayload`'s doc comment on this
            // field explains why an omitted key, not an empty array, is the "nothing pending" wire shape.
            pendingReviewComments: pendingReviewCommentState,
            agents: agents.map { CodePaneBridge.AgentPayload(id: $0.id, label: $0.label, sessionId: $0.sessionID) })
        guard let script = CodePaneBridge.dispatchEventScript(name: Self.initEventName, detail: payload) else { return }
        scriptEvaluator.evaluateCodePaneScript(script)
    }

    /// Stores the web app's latest editor snapshot (see `editorState`'s doc comment), or clears it
    /// when the editor has no open file. Not `private`: a test drives this directly the same way it
    /// drives `dispatch(_:)`, for the same reason (no public `WKScriptMessage` initializer to
    /// construct a real message from).
    ///
    /// Guarded by `message.webView` identity rather than `pageGeneration`: unlike an RPC reply (an
    /// async host completion that can land after a *later* generation without being tied to any one
    /// `WKWebView` instance), this is a synchronous push from a specific page's own JS, and
    /// `installWebView()` allocates a brand-new `WKWebViewConfiguration`/`WKWebView` on every fresh
    /// load. So a debounced push still in flight when a tab switch tears its sender down (see
    /// `teardownWebView()`) — and, rarely, still gets delivered afterward — always names that
    /// now-defunct `WKWebView` as `senderWebView`, never the fresh one a reactivate may have already
    /// installed; comparing it against the live `webView` catches exactly that case, with no
    /// separate counter needed.
    func handleEditorStateChanged(_ state: CodePaneBridge.EditorState?, senderWebView: WKWebView?) {
        guard senderWebView != nil, senderWebView === webView else { return }
        editorState = state
        editorStateGeneration = pageGeneration
    }

    /// Updates `currentMode` from the web app's `modeChanged` push (see `currentMode`'s doc
    /// comment). Not `private`, and guarded identically to `handleEditorStateChanged` above — same
    /// staleness concern, same fix.
    func handleModeChanged(_ mode: CodePaneMode, senderWebView: WKWebView?) {
        guard senderWebView != nil, senderWebView === webView else { return }
        currentMode = mode
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
        case .workspaceFileList:
            // No daemon endpoint yet (see CodePaneWeb/README.md "Open items"); the web app already
            // tolerates this rejection.
            reply(id: id, generation: generation, error: CodePaneBridge.BridgeError(code: .unavailable, message: "File search is not available yet."))
        case .workspaceDiff(let scope):
            performWorkspaceDiff(scope: scope, id: id, generation: generation, hosting: hosting)
        case .workspaceFileRead(let path):
            performFileRead(path: path, id: id, generation: generation, hosting: hosting)
        case .workspaceFileWrite(let path, let content, let baseSHA256):
            performFileWrite(path: path, content: content, baseSHA256: baseSHA256, id: id, generation: generation, hosting: hosting)
        case .reviewCommentList:
            performReviewCommentList(id: id, generation: generation, hosting: hosting)
        case .reviewCommentUpsert(let commentID, let filePath, let side, let lineNumber, let lineText, let body):
            performReviewCommentUpsert(
                commentID: commentID, filePath: filePath, side: side, lineNumber: lineNumber, lineText: lineText, body: body, id: id,
                generation: generation, hosting: hosting)
        case .reviewCommentDelete(let commentID):
            performReviewCommentDelete(commentID: commentID, id: id, generation: generation, hosting: hosting)
        case .reviewCommentsSend(let sessionID, let text, let comments):
            performReviewCommentsSend(sessionID: sessionID, text: text, comments: comments, id: id, generation: generation, hosting: hosting)
        }
    }

    private func performWorkspaceDiff(scope: CodePaneBridge.DiffScope, id: String, generation: Int, hosting: any CodePaneHosting) {
        guard let device = hosting.codePaneDevice(workspaceID: workspaceID) else {
            reply(
                id: id, generation: generation,
                error: CodePaneBridge.BridgeError(code: .unavailable, message: "This workspace's device is not available."))
            return
        }
        let baseBranch = hosting.codePaneWorkspaceInfo(workspaceID: workspaceID)?.baseBranch
        switch CodePaneBridge.refName(for: scope, workspaceBaseBranch: baseBranch) {
        case .failure(let error):
            reply(id: id, generation: generation, error: error)
        case .success(let refName):
            // Every workspaceDiff call claims "latest scope"; a completion that isn't the latest one
            // anymore must not retarget the live diff-signature stream below (see
            // `latestDiffRequestToken`'s doc comment) even though its reply still always goes out.
            latestDiffRequestToken += 1
            let requestToken = latestDiffRequestToken
            // Invalidate a pending old-scope backoff retry HERE, at dispatch time, rather than
            // waiting for `resubscribeDiffSignature` to bump the same generation on this fetch's
            // completion below: a retry already scheduled for the scope this call is superseding
            // captured its generation before this dispatch, so without this it stays generation-
            // valid for the ENTIRE fetch window and is free to wake mid-fetch and resubscribe the
            // now-stale ref — this was the real, deterministic cause of the intermittent
            // `aScopeChangeDuringBackoffSupersedesThePendingRetryForTheOldScope` failure, not a
            // parallel-load flake.
            //
            // Conditional on an actual scope change, not unconditional: bumping on every dispatch
            // would also stale the LIVE stream's own `onDisconnect` handler (it closed over the
            // generation current when that stream opened) on every same-scope refetch — e.g. the
            // ordinary `refreshDiff` a `spaces:diffSignature` frame triggers — so a later real
            // disconnect on a healthy, unchanged-scope stream would be silently ignored and never
            // reconnect. `subscribedScope != .scope(refName)` only trips for a genuine scope change,
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
            // there's no "previous scope's stream" worth reinstalling here, so instead of restoring it
            // tears down at dispatch and simply relies on the next `workspaceDiff` call — same scope or
            // different — to resubscribe from a clean `.none` state.
            if subscribedScope != .scope(refName) {
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
                    let result = try await deviceGateway.workspaceDiff(workspaceID: workspaceID, refName: refName, device: device)
                    guard let self else { return }
                    self.reply(id: id, generation: generation, result: result)
                    guard self.latestDiffRequestToken == requestToken else { return }
                    // Recorded before resubscribing, and only for a still-current request (a
                    // superseded fetch's result is not what the web app is actually showing, so it
                    // must not poison the dedupe baseline for whatever scope is current now).
                    self.lastActedScopeSignature = result.scopeSignature
                    self.lastActedScope = .scope(refName)
                    self.resubscribeDiffSignature(refName: refName, device: device)
                } catch {
                    guard let self else { return }
                    self.reply(id: id, generation: generation, error: CodePaneBridge.mapClientError(error))
                }
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
        if pathChanged {
            latestFileNavigationToken += 1
        }
        let navToken = latestFileNavigationToken
        // Mirrors `performWorkspaceDiff`'s `diffSignatureSubscriptionGeneration` bump: invalidate a
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
                    // Recorded before resubscribing, mirroring `performWorkspaceDiff`'s
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
    /// Deliberately asymmetric with `performWorkspaceDiff`'s twin scope-change bump, which tears down
    /// the old subscription at dispatch time instead of restoring it (see the comment there): the diff
    /// side has no "previous scope's stream" worth reinstalling, so it simply relies on the next
    /// `workspaceDiff` call to resubscribe from a clean `.none` state. The editor has no equivalent
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
            // The daemon's signature poll handles a missing path by design (that's how a
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
        // round-10: bumped before the RPC starts, decremented — unconditionally, success or failure —
        // in its completion below. See `outstandingFileWriteCount`'s doc comment for why a deferred
        // `ready` also waits on this.
        outstandingFileWriteCount += 1
        Task { [weak self] in
            do {
                let result = try await deviceGateway.workspaceFileWrite(
                    workspaceID: workspaceID, relativePath: path, base64Data: base64Data, expectedSHA256: baseSHA256, device: device)
                switch CodePaneBridge.fileWritePayload(result) {
                case .success(let payload):
                    // round-10: only an actually-committed write (never a CAS conflict, which wrote
                    // nothing to disk) has a baseline worth adopting into a flushed snapshot. `sha256`
                    // is documented to be populated whenever `didWrite == true`, but the type is
                    // Optional — skip adoption defensively if it somehow isn't.
                    if result.didWrite, let sha = result.sha256 {
                        self?.lastCommittedFileWrite = (path: path, expectedBase: baseSHA256, sha256: sha, content: content)
                        self?.adoptCommittedWriteIntoEditorState()
                    }
                    self?.reply(id: id, generation: generation, result: payload)
                case .failure(let error):
                    self?.reply(id: id, generation: generation, error: error)
                }
                self?.outstandingFileWriteCount -= 1
                self?.clearCommittedFileWriteIfSettled()
                self?.resumeDeferredReadyIfNeeded()
            } catch {
                self?.reply(id: id, generation: generation, error: CodePaneBridge.mapClientError(error))
                self?.outstandingFileWriteCount -= 1
                self?.clearCommittedFileWriteIfSettled()
                self?.resumeDeferredReadyIfNeeded()
            }
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
            } catch {
                self?.reply(id: id, generation: generation, error: CodePaneBridge.mapClientError(error))
            }
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
        // round-16 Fix 1b: bumped before the RPC starts, decremented — unconditionally, success or
        // failure — in its completion below. See `outstandingReviewCommentMutationCount`'s doc comment
        // for why a deferred `ready` also waits on this, not just on `outstandingTeardownFlushCount`.
        outstandingReviewCommentMutationCount += 1
        Task { [weak self] in
            do {
                let comment = try await deviceGateway.workspaceReviewCommentUpsert(
                    workspaceID: workspaceID, id: commentID, filePath: filePath, side: side, lineNumber: lineNumber, lineText: lineText,
                    body: body, device: device)
                self?.reply(id: id, generation: generation, result: comment)
                // Only a CREATE (`commentID == nil` on the call this Task is completing) can have raced a
                // teardown flush that snapshotted this same draft while it was still provisional — an
                // UPDATE's snapshot entry, if any, was already non-provisional and needs no correction.
                if commentID == nil {
                    self?.reconcilePendingReviewCommentStateAfterCreate(comment: comment)
                }
                self?.outstandingReviewCommentMutationCount -= 1
                self?.resumeDeferredReadyIfNeeded()
            } catch {
                self?.reply(id: id, generation: generation, error: CodePaneBridge.mapClientError(error))
                self?.outstandingReviewCommentMutationCount -= 1
                self?.resumeDeferredReadyIfNeeded()
            }
        }
    }

    /// Corrects a stale `pendingReviewCommentState` snapshot after a CREATE upsert (never an UPDATE —
    /// see the call site) commits server-side, closing the race described on `pendingReviewCommentState`'s
    /// doc comment: a blur fires this CREATE, the same gesture (or an unrelated race) hibernates the pane
    /// before the RPC replies, and `flushPendingReviewCommentState()` snapshots the still-provisional
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

    /// round-12: the DELETE-side analog of `reconcilePendingReviewCommentStateAfterCreate` — corrects a
    /// stale `pendingReviewCommentState` snapshot after a delete commits server-side. The race: a
    /// deleted comment's entry is still present in a teardown-flushed snapshot taken before the delete
    /// RPC replied (the page looked like it still had the row at that instant), the pane hibernates, and
    /// the delete then lands. Left uncorrected, the replacement page's `spaces:init` would restore that
    /// stale entry even though `loadInitial()` finds no server row for it — reviving an explicitly
    /// deleted comment as a fresh provisional draft (the same round-10 Fix 1 path in
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
                self?.outstandingReviewCommentMutationCount -= 1
                self?.resumeDeferredReadyIfNeeded()
            } catch {
                self?.reply(id: id, generation: generation, error: CodePaneBridge.mapClientError(error))
                self?.outstandingReviewCommentMutationCount -= 1
                self?.resumeDeferredReadyIfNeeded()
            }
        }
    }

    private func performReviewCommentsSend(
        sessionID: String, text: String, comments: [SpacesDeviceReviewCommentSendEntry], id: String, generation: Int,
        hosting: any CodePaneHosting
    ) {
        guard let device = hosting.codePaneDevice(workspaceID: workspaceID) else {
            reply(
                id: id, generation: generation,
                error: CodePaneBridge.BridgeError(code: .unavailable, message: "This workspace's device is not available."))
            return
        }
        let workspaceID = workspaceID
        let deviceGateway = deviceGateway
        // round-16 Fix 1b: a send held up by this counter can hold `ready` for as long as the send's
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
                self?.outstandingReviewCommentMutationCount -= 1
                self?.resumeDeferredReadyIfNeeded()
            } catch {
                self?.reply(id: id, generation: generation, error: CodePaneBridge.mapClientError(error))
                self?.outstandingReviewCommentMutationCount -= 1
                self?.resumeDeferredReadyIfNeeded()
            }
        }
    }

    /// (Re)points the live diff-signature stream at `refName` if it isn't already there. A repeat
    /// `workspaceDiff` call for the same resolved scope is a no-op here — only an actual scope
    /// change tears down and reopens the stream.
    private func resubscribeDiffSignature(refName: String?, device: SpacesPairedDeviceRecord) {
        guard subscribedScope != .scope(refName) else { return }
        // Defensive: in the normal flow `lastActedScopeSignature` is already refreshed for `refName`
        // before this runs (`performWorkspaceDiff` sets it, then calls this), including for a
        // disconnect-driven reconnect to the SAME scope (nothing here touches it, so a connect frame
        // repeating an unchanged signature is still correctly suppressed — see
        // `handleDiffSignatureFrame`). This only guards a hypothetical future caller that resubscribes
        // without having freshened it first.
        if lastActedScope != .scope(refName) {
            lastActedScopeSignature = nil
            lastActedScope = .none
        }
        diffSignatureStream?.stop()
        diffSignatureStream = nil
        subscribedScope = .scope(refName)
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
                    workspaceID: workspaceID, refName: refName, device: device, onFrame: onFrame, onDisconnect: onDisconnect)
                // The pane may have deactivated, or resubscribed to a different scope, while this was
                // in flight; only keep the client if it's still the one this scope wants. Scope alone
                // is not enough: a rapid A → B → A scope-change sequence can land a STALE A attempt's
                // completion here after a newer A attempt has already taken over — `subscribedScope ==
                // .scope(refName)` would read true again even though this in-flight `Task` belongs to a
                // completely different (superseded) subscription attempt than the one that's actually
                // current. `subscriptionGeneration` is the identity of this one ATTEMPT, not just its
                // target scope, so it's what actually tells a stale A from the current A apart. Without
                // it, a stale success either bare-assigns over the current client with no `.stop()`
                // (leaking the stream the current attempt installed), or installs itself as the live
                // client while carrying an `onDisconnect` that closed over its own now-dead generation —
                // when that stale client eventually disconnects, `handleDiffSignatureDisconnect`'s own
                // generation guard correctly refuses to act on it, so the pane silently stops
                // reconnecting until something else forces a fresh resubscribe.
                guard let self, self.subscribedScope == .scope(refName), self.diffSignatureSubscriptionGeneration == subscriptionGeneration,
                    self.webView != nil
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
                guard let self, self.subscribedScope == .scope(refName), self.diffSignatureSubscriptionGeneration == subscriptionGeneration
                else { return }
                self.subscribedScope = .none
                self.scheduleDiffSignatureReconnect(refName: refName, generation: subscriptionGeneration)
            }
        }
    }

    /// Clears `subscribedScope`/`diffSignatureStream` after a real disconnect (daemon restart,
    /// network drop) so the next same-scope `workspaceDiff` call resubscribes instead of skipping
    /// forever via `resubscribeDiffSignature`'s `guard subscribedScope != .scope(refName)`, and starts
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
        // Capture before clearing: the scheduled retry below needs the dropped subscription's ref
        // name to retarget the same scope once the backoff elapses.
        let refName: String?
        if case .scope(let capturedRefName) = subscribedScope { refName = capturedRefName } else { refName = nil }
        subscribedScope = .none
        scheduleDiffSignatureReconnect(refName: refName, generation: subscriptionGeneration)
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
    /// `workspaceDiff` for a different scope, or an earlier retry already succeeding all bump
    /// `diffSignatureSubscriptionGeneration`, which makes this check fail and the attempt a no-op.
    private func scheduleDiffSignatureReconnect(refName: String?, generation: Int) {
        diffSignatureReconnectFailures += 1
        let delay = RemoteConnectionBackoff.delay(
            consecutiveFailures: diffSignatureReconnectFailures, floor: diffSignatureReconnectFloor, cap: diffSignatureReconnectCap,
            jitterFraction: 0)
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, self.diffSignatureSubscriptionGeneration == generation else { return }
            // The device is nil by contract for exactly the window a daemon restart's disconnect
            // fires retries into (`deviceForMutation`/`deviceAcceptsDaemonActions` refuse it while the
            // device can't take daemon actions) — treating that as a dead end would make the very
            // first retry after a restart-triggered disconnect always fail permanently. Reschedule
            // instead: this is just another failed attempt, same as a subscribe throwing below.
            guard let hosting = self.hosting, let device = hosting.codePaneDevice(workspaceID: self.workspaceID) else {
                self.scheduleDiffSignatureReconnect(refName: refName, generation: generation)
                return
            }
            self.resubscribeDiffSignature(refName: refName, device: device)
        }
    }

    /// Invariant: a frame is forwarded iff its `scopeSignature` differs from the last diff the web
    /// app is known to have fetched for the current scope (`lastActedScopeSignature`). Every scope
    /// change (an ordinary `workspaceDiff` fetch, or a stream reconnect after an outage — see
    /// `resubscribeDiffSignature`'s doc comment) opens with a connect-time frame carrying that scope's
    /// current signature; forwarding it unconditionally would trigger a second, redundant full
    /// `workspaceDiff` fetch (up to 8 MiB) the web app just performed a moment ago (a scope switch) or
    /// doesn't need (a reconnect where nothing changed while disconnected). Err toward forwarding: any
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
                guard let self, self.subscribedFilePath == path, self.fileSignatureSubscriptionGeneration == subscriptionGeneration else {
                    return
                }
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
            consecutiveFailures: fileSignatureReconnectFailures, floor: fileSignatureReconnectFloor, cap: fileSignatureReconnectCap,
            jitterFraction: 0)
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
        MainActor.assumeIsolated {
            handleScriptMessage(name: message.name, body: message.body, senderWebView: message.webView)
        }
    }
}

private extension CodePaneMode {
    var wireValue: String {
        switch self {
        case .diff: "diff"
        case .editor: "editor"
        }
    }

    /// Inverse of `wireValue` — decodes a `modeChanged` push's `mode` string. `decodeModeChanged`
    /// already restricts this to `"diff"`/`"editor"`, so the default arm is unreachable in practice.
    init(wireValue: String) {
        self = wireValue == "editor" ? .editor : .diff
    }
}
