import AppKit
import WebKit
import spacesclientcore
import spacesdevicecore
import spacesterminalcore
import spacesterminalghostty

/// Which entry point created a code pane. Both the "Diff" and "Open file…" picker rows produce the
/// same `.codePane` descriptor — the mode is carried purely as a runtime hint to the controller and
/// is never persisted. A restored pane always rebuilds as `.diff`, since the descriptor alone
/// cannot say which entry point created it.
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
    private var isReady = false
    private var currentTheme: ThemeAppearance?

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
    var displayTitle: String { "Code" }

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
    func close() {
        teardownWebView()
        editorState = nil
        // Invalidates a flush already in flight from the teardown just above: without this, its
        // completion would still satisfy `flushGeneration >= editorStateGeneration` (neither moves on
        // its own between the two calls) and could resurrect the snapshot this line just discarded.
        editorStateGeneration += 1
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
        let webView = WKWebView(frame: rootView.bounds, configuration: configuration)
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
        // present in a built app, so there is nothing to fall back to if it's missing — the page just
        // stays blank.
        if let indexURL = Self.codePaneIndexURL() {
            webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        }
    }

    private func teardownWebView() {
        flushPendingEditorState()
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
        // Strongly captured (not `[weak webView]`): `webView` is about to be removed from `rootView`
        // and have its message handler stripped by the rest of `teardownWebView()`, but its web
        // process must stay alive long enough for this in-flight `evaluateJavaScript` call to actually
        // finish and answer — an unretained `webView` here could be deallocated before that happens.
        scriptEvaluator.evaluateCodePaneScript(CodePaneBridge.collectEditorStateScript) { [weak self] result in
            withExtendedLifetime(webView) {
                self?.storeFlushedEditorState(CodePaneBridge.decodeCollectedEditorState(result), generation: flushGeneration)
            }
        }
    }

    /// Applies a teardown flush's result under the same ordering rule `handleEditorStateChanged`
    /// writes under — see `editorStateGeneration`'s doc comment for the `>=` rule this enforces.
    private func storeFlushedEditorState(_ collected: CodePaneBridge.CollectedEditorState, generation: Int) {
        guard generation >= editorStateGeneration else { return }
        switch collected {
        case .noFile: editorState = nil
        case .file(let state): editorState = state
        }
        editorStateGeneration = generation
    }

    // MARK: - Bridge dispatch

    /// Not `private`: `WKScriptMessage` has no public initializer a test can construct, so a test
    /// simulates the web app's `ready` handshake by calling this directly instead of going through
    /// `WKScriptMessageHandler` — matching the pattern `scriptEvaluator`/`diffSignatureReconnectFloor`
    /// already use to give tests a seam without adding any new product-facing surface.
    func handleReady() {
        guard !isReady, let scriptEvaluator, let hosting else { return }
        isReady = true
        let appearance = currentTheme ?? hosting.codePaneCurrentAppearance()
        currentTheme = appearance
        let workspaceInfo = hosting.codePaneWorkspaceInfo(workspaceID: workspaceID)
        let workspaceName = workspaceInfo?.name ?? workspaceID
        // Same emptiness rule as `refName(for:)`'s `.baseBranch` case: an empty string reads as "no
        // base branch configured", not a literal branch named "".
        let baseBranch = workspaceInfo?.baseBranch.flatMap { $0.isEmpty ? nil : $0 }
        let payload = CodePaneBridge.InitPayload(
            workspaceId: workspaceID, workspaceName: workspaceName,
            // `currentMode`, not `initialMode`: after a hibernation cycle this is wherever the user
            // last left the in-page toolbar (see `currentMode`'s doc comment), so a pane hibernated
            // in Editor mode restores to Editor mode rather than resetting to its original entry point.
            initialMode: currentMode.wireValue,
            // Every code pane opens on the uncommitted-vs-HEAD scope; the toolbar's scope control
            // (see CodePaneWeb's toolbar.ts) is what moves it from there.
            initialScope: .init(kind: "uncommitted", refName: nil), theme: appearance.rawValue, baseBranch: baseBranch,
            editorState: editorState)
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
                error: CodePaneBridge.BridgeError(code: .unavailable, message: "The code pane's host is no longer available."))
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
            // Accepted edge: a scope change dispatched over a healthy OLD-scope stream leaves that
            // stream's `onDisconnect` closure stale for this fetch's window (its generation was just
            // bumped out from under it here). If the old stream also happens to die inside that same
            // window, its disconnect is silently dropped and nothing reconnects on its own — recovery
            // then rides the web app's own bounded-backoff `refreshDiff` retry (see root.ts) until a
            // later successful fetch calls `resubscribeDiffSignature` for the new scope. Narrow and
            // self-healing, so left as-is rather than adding a second invalidation path for it.
            if subscribedScope != .scope(refName) {
                diffSignatureSubscriptionGeneration += 1
                diffSignatureReconnectFailures = 0
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
        let workspaceID = workspaceID
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<SpacesDeviceWorkspaceFileReadResult, Error> in
                do { return .success(try SpacesDeviceClient.workspaceFileRead(workspaceID: workspaceID, relativePath: path, device: device)) }
                catch { return .failure(error) }
            }.value
            guard let self else { return }
            switch outcome {
            case .success(let result):
                switch CodePaneBridge.fileReadPayload(result) {
                case .success(let payload): self.reply(id: id, generation: generation, result: payload)
                case .failure(let error): self.reply(id: id, generation: generation, error: error)
                }
            case .failure(let error):
                self.reply(id: id, generation: generation, error: CodePaneBridge.mapClientError(error))
            }
        }
    }

    private func performFileWrite(path: String, content: String, baseSHA256: String, id: String, generation: Int, hosting: any CodePaneHosting) {
        guard let device = hosting.codePaneDevice(workspaceID: workspaceID) else {
            reply(
                id: id, generation: generation,
                error: CodePaneBridge.BridgeError(code: .unavailable, message: "This workspace's device is not available."))
            return
        }
        let base64Data = Data(content.utf8).base64EncodedString()
        let workspaceID = workspaceID
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<SpacesDeviceWorkspaceFileWriteResult, Error> in
                do {
                    return .success(
                        try SpacesDeviceClient.workspaceFileWrite(
                            workspaceID: workspaceID, relativePath: path, base64Data: base64Data, expectedSHA256: baseSHA256, device: device))
                } catch { return .failure(error) }
            }.value
            guard let self else { return }
            switch outcome {
            case .success(let result):
                switch CodePaneBridge.fileWritePayload(result) {
                case .success(let payload): self.reply(id: id, generation: generation, result: payload)
                case .failure(let error): self.reply(id: id, generation: generation, error: error)
                }
            case .failure(let error):
                self.reply(id: id, generation: generation, error: CodePaneBridge.mapClientError(error))
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
        let onFrame: @Sendable (SpacesDeviceWorkspaceDiffSignatureFrame) -> Void = { [weak self] frame in
            Task { @MainActor in self?.handleDiffSignatureFrame(frame) }
        }
        let onDisconnect: @Sendable ((any Error)?) -> Void = { [weak self] _ in
            Task { @MainActor in self?.handleDiffSignatureDisconnect(subscriptionGeneration: subscriptionGeneration) }
        }
        Task { [weak self] in
            do {
                let client = try await deviceGateway.subscribeWorkspaceDiffSignature(
                    workspaceID: workspaceID, refName: refName, device: device, onFrame: onFrame, onDisconnect: onDisconnect)
                // The pane may have deactivated, or resubscribed to a different scope, while this was
                // in flight; only keep the client if it's still the one this scope wants.
                guard let self, self.subscribedScope == .scope(refName), self.webView != nil else {
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
                guard let self, self.subscribedScope == .scope(refName) else { return }
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
            guard message.name == Self.messageHandlerName else { return }
            if CodePaneBridge.isReady(body: message.body) {
                handleReady()
                return
            }
            switch CodePaneBridge.decodeEditorStateChanged(body: message.body) {
            case .file(let state):
                handleEditorStateChanged(state, senderWebView: message.webView)
                return
            case .noFile:
                handleEditorStateChanged(nil, senderWebView: message.webView)
                return
            case .notThisMessage:
                break
            }
            if let mode = CodePaneBridge.decodeModeChanged(body: message.body) {
                handleModeChanged(CodePaneMode(wireValue: mode), senderWebView: message.webView)
                return
            }
            guard let request = CodePaneBridge.decodeRequest(body: message.body) else { return }
            dispatch(request)
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

