import { createBridge } from "../bridge";
import {
  CodePaneAgentsChangedEvent,
  CodePaneEditorUIState,
  CodePaneInitPayload,
  CodePaneSetModeEvent,
  CodePaneThemeChangedEvent,
  DiffFileEntry,
  SpacesBridgeError,
  WorkspaceDiffResult,
} from "../bridge/types";
import { CommentsController, CommentsToolbarState } from "./commentsController";
import { DiffView } from "./diffView";
import { EditorSidebar } from "./editorSidebar";
import { EditorView } from "./editorView";
import { renderFileList } from "./fileList";
import { attachFileListDivider } from "./fileListDivider";
import { QuickOpen } from "./quickOpen";
import { RefSearchDialog } from "./refSearchDialog";
import { afterBrowserPaint, aggregateContentUnits } from "./renderMetrics";
import { selectDefaultAgentId } from "./reviewComments";
import { CodePaneAction, CodePaneState, codePaneReducer, initialState } from "./state";
import { renderToolbar } from "./toolbar";
import { WorkspaceFileListCache } from "./workspaceFileListCache";

/** Most-recently-opened first, deduped, capped here — see `CodePaneEditorUIState.recentPaths`'s
 *  doc comment for the contract every successful open (⌘P overlay, Files tree, Changes list in
 *  editor mode) must satisfy. */
const RECENT_PATHS_CAP = 12;

const INIT_EVENT = "spaces:init";
const THEME_EVENT = "spaces:theme";
const AGENTS_EVENT = "spaces:agents";
const SET_MODE_EVENT = "spaces:setMode";

/**
 * Wires the bridge, toolbar, file list, and diff/editor views together.
 * The only entry point besides `main.ts`, which just calls this once the
 * highlighter is preloaded.
 *
 * Startup sequencing: the `spaces:init` listener is attached before
 * `notifyReady()` is called, so a host that dispatches the event
 * synchronously in response to "ready" can never race past a listener that
 * isn't there yet.
 */
export async function mountRoot(container: HTMLElement): Promise<void> {
  const bridge = await createBridge();

  const initPayload = await new Promise<CodePaneInitPayload>((resolve) => {
    window.addEventListener(INIT_EVENT, (event) => resolve((event as CustomEvent<CodePaneInitPayload>).detail), {
      once: true,
    });
    bridge.notifyReady();
  });

  // The Swift host reports the theme explicitly; this never reads
  // prefers-color-scheme (see styles/tokens.css's doc comment).
  document.documentElement.dataset.theme = initPayload.theme;
  window.spaces = bridge;

  // Kept separate from the one-shot `spaces:init` listener above: appearance changes after
  // startup arrive on `spaces:theme` instead (see README.md), since a `{once: true}` listener
  // has nothing left attached to receive a second `spaces:init`.
  window.addEventListener(THEME_EVENT, (event) => {
    document.documentElement.dataset.theme = (event as CustomEvent<CodePaneThemeChangedEvent>).detail.theme;
  });

  let state: CodePaneState = initialState(initPayload.initialMode, initPayload.initialScope);
  let files: DiffFileEntry[] = [];
  let diffLoaded = false;
  // Editor mode's sidebar-toggle/recent-files snapshot (Design K/O) — see notifyEditorUIStateChanged's
  // doc comment in bridge/types.ts for why root.ts, not EditorView, owns this state.
  let editorUIState: CodePaneEditorUIState = initPayload.editorUIState ?? { sidebarMode: "files", recentPaths: [] };
  let unsubscribeSignature: (() => void) | undefined;
  // Bumped at the start of every refreshDiff call; a call only applies its result (or lets its
  // error propagate) if its token is still the current one once the awaited call settles. This
  // is what makes a scope switch (or another refresh) latest-wins: a slower, superseded request
  // can otherwise resolve after a newer one and overwrite what the newer one already applied,
  // regardless of which one actually finishes first. Scope equality can't stand in for this — an
  // A→B→A sequence would wrongly treat a stale A reply as still matching the current scope.
  let diffRequestToken = 0;
  // Bounded-backoff retry state for a failed refreshDiff pull (see refreshDiff's doc comment):
  // consecutive failures for the *current* token drive the delay, reset to 0 on any success.
  let diffRetryTimer: ReturnType<typeof setTimeout> | undefined;
  let diffRetryFailures = 0;
  const DIFF_RETRY_FLOOR_MS = 1000;
  const DIFF_RETRY_CAP_MS = 30000;
  // round-16 Fix 1: coalescing state for refreshDiff's public gate (see its doc comment below).
  let diffPullInFlight = false;
  let trailingDiffRefreshQueued = false;
  let trailingPreserveScroll = true;
  let trailingDiffTrigger: DiffRenderTrigger = "workspaceChange";

  const pane = document.createElement("div");
  pane.className = "pane";
  container.appendChild(pane);

  const toolbarHost = document.createElement("div");
  pane.appendChild(toolbarHost);

  const body = document.createElement("div");
  body.className = "code-body";
  pane.appendChild(body);

  const fileListEl = document.createElement("div");
  fileListEl.className = "file-list";

  // Diff mode's changed-files list — the sole target of every `renderFileList` call below,
  // regardless of which mode is live (a diff-signature push fires in either mode). Diff mode
  // parents it directly under `fileListEl`; Editor mode's Changes tab reparents this SAME node
  // into `editorSidebar`'s list host instead of re-rendering it — see `EditorSidebar`'s doc
  // comment for why reparenting (not re-rendering) is what keeps its rows' click behavior intact
  // across a mode switch.
  const changesListEl = document.createElement("div");

  const fileListDividerEl = document.createElement("div");
  fileListDividerEl.className = "file-list-divider";

  const diffAreaEl = document.createElement("div");
  diffAreaEl.className = "diff-area";
  diffAreaEl.style.position = "relative"; // hosts the comments controller's absolutely-positioned error banner

  const editorContainerEl = document.createElement("div");
  editorContainerEl.className = "diff-area";

  // Seeded synchronously to match `CommentsController`'s own constructor logic exactly (see
  // `selectDefaultAgentId`), so the toolbar's very first paint already reflects the real
  // auto-default rather than an `undefined` placeholder that only self-corrects once the
  // controller's first `onToolbarStateChange` callback fires.
  let lastCommentsToolbarState: CommentsToolbarState = {
    agents: initPayload.agents,
    selectedAgentId: selectDefaultAgentId(initPayload.agents, undefined),
    draftCount: 0,
  };

  const comments = new CommentsController(bridge, initPayload.agents, {
    onToolbarStateChange: (commentsState) => {
      lastCommentsToolbarState = commentsState;
      toolbar.update(buildToolbarState());
    },
  });
  const diffView = new DiffView(diffAreaEl, state.layout, comments.hooks);
  comments.attachDiffView(diffView);
  comments.mount(diffAreaEl);
  const editorView = new EditorView(editorContainerEl, bridge, {
    // The success-only seam (see `EditorViewCallbacks.onFileOpened`'s doc comment): fires only once
    // `loadFile()` actually replaces the buffer with `path`'s content, so a refused open (the
    // discard-consent banner) or a failed read never records a recent or moves the Files tree's
    // selection (Finding C) — `openInEditor` below stops doing either of those itself. Restoring a
    // hibernated buffer never fires this either (see `EditorView.restoreState`'s doc comment), so a
    // pane that reopens straight into its last file doesn't re-record it as a fresh open.
    onFileOpened: (path) => {
      recordRecentPath(path);
      editorSidebar.setSelectedPath(path);
    },
    onFileRendered: (_path, elapsedMs, contentUnits) => {
      bridge.notifyRenderMetric({
        kind: "editor",
        trigger: "fileOpen",
        elapsedMs: Math.round(elapsedMs),
        fileCount: 1,
        contentBytes: contentUnits,
      });
    },
  });
  // Wired here (not inside EditorView itself) so the global always reaches this exact instance's
  // live state — see Window.__spacesCollectEditorState's doc comment in bridge/types.ts and
  // EditorView.collectStateForFlush.
  window.__spacesCollectEditorState = () => editorView.collectStateForFlush();
  // round-16 Fix 1a: mirrors the wiring above, for the comment surface — see
  // Window.__spacesCollectReviewCommentState's doc comment in bridge/types.ts and
  // CommentsController.collectStateForFlush.
  window.__spacesCollectReviewCommentState = () => comments.collectStateForFlush();
  // Root.ts's own state (editorUIState) is read synchronously — no debounce, no async teardown
  // race to close (see __spacesCollectEditorUIState's doc comment in bridge/types.ts for why this
  // is simpler than the two flush callbacks above).
  window.__spacesCollectEditorUIState = () => JSON.stringify(editorUIState);

  // Shared by Editor mode's Files tree (`editorSidebar`) and the ⌘P quick-open overlay
  // (`quickOpen`) — see WorkspaceFileListCache's doc comment for why one lazily-fetched instance is
  // shared rather than each owning its own.
  const fileListCache = new WorkspaceFileListCache(bridge);

  const editorSidebar = new EditorSidebar(
    changesListEl,
    fileListCache,
    // `initPayload.editorState?.path` (not anything EditorView reports back) is the source for the
    // initial selected row: it's available synchronously at construction time, before
    // `editorView.restoreState` below has even run.
    { sidebarMode: editorUIState.sidebarMode, selectedPath: initPayload.editorState?.path },
    openInEditor,
    {
      onModeChange: (mode) => {
        editorUIState = { ...editorUIState, sidebarMode: mode };
        pushEditorUIState();
        // The Changes tab can be reached without ever having visited Diff mode in this session
        // (e.g. a pane that opens straight into Editor mode); make sure there's an actual diff to
        // show rather than leaving the tab on the still-empty list `changesListEl` started with.
        if (mode === "changes" && !diffLoaded) void refreshDiff(false, "initial");
      },
    },
  );

  const quickOpen = new QuickOpen(pane, fileListCache, () => editorUIState.recentPaths, {
    getMode: () => state.mode,
    isInDiff: (path) => files.some((file) => file.path === path),
    openInDiff: (path) => {
      diffView.scrollToFile(path);
      // Recorded inline, unlike `openInEditor`'s success-callback seam (Finding C): a diff jump is
      // synchronous and has no refusal/failure path to guard against, so there's nothing to wait on
      // before it's safe to call this a successful open.
      recordRecentPath(path);
    },
    openInEditor,
  });

  const refSearchDialog = new RefSearchDialog(
    pane,
    () => bridge.workspaceRefList(),
    initPayload.baseBranch,
    {
      onSelect: (refName) => dispatch({ type: "setScope", scope: { kind: "ref", refName } }),
    },
  );

  /** Records `path` as most-recently-opened (dedupe, cap `RECENT_PATHS_CAP`) and pushes the
   *  updated `editorUIState` to the host. Called by every successful open, from any of the three
   *  entry points (⌘P overlay, Files tree, Changes list in editor mode) — see `openInEditor`. */
  function recordRecentPath(path: string): void {
    const recentPaths = [path, ...editorUIState.recentPaths.filter((p) => p !== path)].slice(0, RECENT_PATHS_CAP);
    editorUIState = { ...editorUIState, recentPaths };
    pushEditorUIState();
  }

  function pushEditorUIState(): void {
    bridge.notifyEditorUIStateChanged(editorUIState);
  }

  /** Opens `path` in Editor mode, switching modes first if the pane isn't already there — the
   *  common landing point for all three entry points Design O/K define (see this file's imports'
   *  doc comments): the ⌘P overlay (outside the diff), the Files tree, and the Changes list's own
   *  click handler while already in Editor mode (`changesOnSelect` below). */
  function openInEditor(path: string): void {
    // `editorView.open` can refuse (a dirty buffer's discard-consent banner) or fail (an async read
    // error) instead of actually opening `path` — recording the recent / moving the tree selection
    // here unconditionally would do so even then. Both are handled by `EditorView`'s `onFileOpened`
    // success callback instead (see this file's `EditorView` construction above), which only fires
    // once the open has actually completed (Finding C).
    //
    // Called BEFORE the `setMode` dispatch below, not after: `open()` starts (at most) one
    // `workspaceFileRead` and returns synchronously — the read itself only awaits — while dispatching
    // "editor" mode first would, for a pane not already in editor mode, run `editorSidebar.reattach()`
    // synchronously inside `dispatch`, which fires a `workspaceFileList` revalidation. Both requests
    // share the daemon's per-workspace SERIAL git queue, so whichever call is MADE first is served
    // first; queuing a full-workspace listing ahead of the one file the user just picked (often via
    // ⌘P, which already has a fresh listing — that's how the user found this path) makes the pick
    // wait behind it for no benefit. `open()` has no dependency on the pane already being in editor
    // mode — it only touches `editorContainerEl`'s children, and does so after its `await`, by which
    // point the synchronous `dispatch` call below has already mounted it.
    editorView.open(path);
    if (state.mode !== "editor") dispatch({ type: "setMode", mode: "editor" });
  }

  /** Shared `onSelect` for every `renderFileList(changesListEl, ...)` call below: reads `state.mode`
   *  LIVE, at click time, not at render time — `changesListEl`'s rows are rendered once and then
   *  reparented (not re-rendered) between Diff mode's direct placement and Editor mode's Changes
   *  tab (see `changesListEl`'s own doc comment), so this is what makes the same row correctly
   *  jump-scroll in Diff mode but open in the editor in Editor mode, without needing a re-render on
   *  every mode toggle. */
  function changesOnSelect(path: string): void {
    if (state.mode === "diff") {
      diffView.scrollToFile(path);
    } else {
      openInEditor(path);
    }
  }

  // A running agent set changes independently of any diff refresh or user action in this pane
  // (an agent can start or exit from elsewhere in the app), so this listens for the whole
  // lifetime of the pane rather than being read once at startup like `initPayload.agents`.
  window.addEventListener(AGENTS_EVENT, (event) => {
    comments.onAgentsChanged((event as CustomEvent<CodePaneAgentsChangedEvent>).detail.agents);
  });

  window.addEventListener(SET_MODE_EVENT, (event) => {
    const { mode } = (event as CustomEvent<CodePaneSetModeEvent>).detail;
    // The host doesn't know this pane's live JS state before pushing (see `currentMode`'s doc
    // comment in the Swift host); redundantly dispatching the mode it's already in would still
    // fire `bridge.notifyModeChanged` and possibly `refreshDiff` for nothing (see `dispatch`'s
    // `setMode` branch below), so bail here rather than there.
    if (mode === state.mode) return;
    dispatch({ type: "setMode", mode });
  });

  /** Folds the toolbar's own mode/scope/layout state together with the comments controller's
   *  agent/draft-count state — kept as one function so every call site building a `ToolbarState`
   *  (the initial render, every `dispatch`, and every comments-controller change) builds it the
   *  same way and can't drift apart. */
  function buildToolbarState() {
    return {
      mode: state.mode,
      scope: state.scope,
      layout: state.layout,
      baseBranch: initPayload.baseBranch,
      agents: lastCommentsToolbarState.agents,
      selectedAgentId: lastCommentsToolbarState.selectedAgentId,
      draftCount: lastCommentsToolbarState.draftCount,
    };
  }

  const toolbar = renderToolbar(toolbarHost, buildToolbarState(), {
    onModeChange: (mode) => dispatch({ type: "setMode", mode }),
    onScopeChange: (scope) => dispatch({ type: "setScope", scope }),
    onOpenRefSearch: (mode) => refSearchDialog.show(mode),
    onLayoutChange: (layout) => dispatch({ type: "setLayout", layout }),
    onAgentSelect: (id) => comments.onAgentSelected(id),
    onSendBatch: () => void comments.sendBatch(),
  });

  // Seeded here, synchronously and as early as possible (before any yielding `await` below can let
  // a teardown race this pane's own startup) — mirrors `editorView.restoreState`'s ordering rule
  // below, but this seeding is pure synchronous local-state mutation (no network round trip), so
  // there is no reason to defer it as far as that call. Seeding before `loadInitial()`'s network
  // call specifically matters (see `restorePendingState`'s doc comment): a teardown mid-`loadInitial`
  // would otherwise flush an empty comment-state snapshot, discarding this seeded text for good.
  //
  // This can't run any earlier than right here, immediately after `toolbar` is constructed: when
  // `entries` is non-empty, `restorePendingState` synchronously calls `refresh()`, which invokes
  // the `onToolbarStateChange` callback wired above (in `comments`'s constructor), and that
  // callback closes over `toolbar`. `toolbar` is a `const` initialized by the `renderToolbar(...)`
  // call directly above; calling this any earlier — e.g. back where `comments` itself is
  // constructed — would reach that callback before `toolbar`'s initializer has run, throwing
  // "Cannot access 'toolbar' before initialization" and taking down the whole pane. Every existing
  // test happened to pass an empty `pendingReviewComments`, which short-circuits before `refresh()`
  // is ever called, which is why this TDZ hazard went uncaught until round-16 Fix 1a's test seeded
  // a non-empty one.
  comments.restorePendingState(initPayload.pendingReviewComments ?? []);

  // Wired once against `body` (the flex row both panels live in), independent of `renderBody`'s
  // repeated `replaceChildren()` calls — `attachFileListDivider` only ever touches
  // `fileListDividerEl`/`fileListEl`'s own listeners/inline style, not `body`'s children, so it
  // stays correctly wired across every diff<->editor mode switch. It owns the file list's width
  // end to end: restore-on-attach, drag, persist, and re-clamp on pane resize.
  attachFileListDivider(fileListDividerEl, fileListEl, body);

  /** Both modes share one physical `fileListEl`/`fileListDividerEl` pair (Design K: "same left tree
   *  area as diff mode"), so the resizable divider stays wired in either mode — only `fileListEl`'s
   *  single child and the main content pane change. Diff mode's child is `changesListEl` directly
   *  (no header, unchanged from before Design K); Editor mode's is `editorSidebar.el`, whose own
   *  Files/Changes toggle either shows the full workspace listing or reparents this same
   *  `changesListEl` node into its own list host (see `EditorSidebar`'s doc comment). */
  function renderBody(): void {
    body.replaceChildren();
    fileListEl.replaceChildren(state.mode === "diff" ? changesListEl : editorSidebar.el);
    body.appendChild(fileListEl);
    body.appendChild(fileListDividerEl);
    body.appendChild(state.mode === "diff" ? diffAreaEl : editorContainerEl);
  }

  /**
   * Pulls the diff for the current scope. A failed pull is classified before deciding what to do
   * with it (see the `catch` block below): a *transient* failure is swallowed and retried with a
   * bounded exponential backoff (`scheduleDiffRetry`) rather than thrown — the diff-signature push
   * stream dedupes repeat frames end-to-end (both the Swift host's `lastDeliveredSignature` and
   * this app's own `subscribeDiffSignature` listener never re-announce a signature it already told
   * this pane about), so a transient fetch failure here is never retried by anything upstream — if
   * this loop didn't retry, a pull that failed once would never be attempted again until the
   * scope's git state changed again. A *permanent* failure is rendered instead: retrying an
   * identical request the daemon has already rejected for a durable reason would just fail the
   * same way forever, leaving the previous scope's stale files on screen with no indication
   * anything is wrong. `token` makes retries latest-wins the same way regular refreshes are: a
   * scope switch (or another refresh) bumps `diffRequestToken`, so a stale retry silently no-ops
   * instead of clobbering whatever the newer attempt already applied.
   *
   * Two typed codes join the render-AND-retry class rather than the durable-rejection class — see
   * the `catch` block below for why `unavailable` and `internalError` both belong there: a bad ref
   * is a durable `invalidArgument` rejection (retrying buys nothing), while a transient git failure
   * on the daemon side now surfaces as `internalError` specifically so this loop can retry it — see
   * `SpacesDeviceWorkspaceDiffEngine.assertRefIsResolvable`'s doc comment (Swift host) for the
   * daemon-side split this depends on.
   */
  type DiffRenderTrigger = "initial" | "scope" | "workspaceChange";

  async function doRefreshDiff(preserveScroll: boolean, trigger: DiffRenderTrigger): Promise<void> {
    const renderStartedAt = performance.now();
    const token = ++diffRequestToken;
    clearTimeout(diffRetryTimer);
    let result: WorkspaceDiffResult;
    let fetchElapsedMs: number;
    try {
      result = await bridge.workspaceDiff(state.scope);
      fetchElapsedMs = Math.round(Math.max(performance.now() - renderStartedAt, 0));
    } catch (err) {
      if (token !== diffRequestToken) return; // superseded: a newer refresh already won, so this failure is moot
      // A typed `SpacesBridgeError` means the daemon decoded the request and rejected it for a
      // durable reason (e.g. a bad/deleted ref for a "vs chosen ref" scope, or the workspace itself
      // is gone) — the exact same request will fail the exact same way on every retry, so retrying
      // buys nothing and only leaves stale files on screen. Anything else (a thrown plain error,
      // e.g. from a socket failure) never even got a decodable answer — that's a transport-level
      // hiccup, which is what the retry loop below exists for.
      //
      // `unavailable` and `internalError` are the two typed codes that are an exception to "typed =
      // durable rejection":
      //
      // `unavailable`: CodePaneBridge.mapClientError (Swift host) collapses every not-reachable/not-ready
      // client failure — the device offline, the daemon mid-restart, the connection not yet
      // established — into this single code, and realBridge.ts wraps it in a SpacesBridgeError like
      // any other decoded reply. That's a transient condition that heals on its own once the
      // daemon/device comes back, not a rejection of this specific request, so it must retry like an
      // untyped transport failure.
      //
      // `internalError`: the daemon's own git work can fail transiently (a wedged process, a timeout)
      // in a way that is indistinguishable, at the git-command level, from a caller-supplied ref that
      // simply doesn't resolve — `SpacesDeviceWorkspaceDiffEngine.assertRefIsResolvable` (Swift host)
      // probes ref resolvability up front specifically so the two can be told apart on the wire: a bad
      // ref is rejected as `invalidArgument` (durable, no retry — see the fallthrough below), while
      // `internalError` is reserved for the daemon's own transient trouble and is safe to retry here.
      //
      // Both still render the error (rather than staying silent like the untyped path) so the user
      // sees why the pane is empty while the retry runs in the background — the only cheap recovery
      // signal here (diff-signature subscription) doesn't exist yet this early.
      if (SpacesBridgeError.isSpacesBridgeError(err)) {
        if (err.code === "unavailable" || err.code === "internalError") {
          files = [];
          renderFileList(changesListEl, files, undefined, { onSelect: changesOnSelect });
          diffView.setError(err.message);
          // The comments controller re-anchors drafts against whatever file list it was last
          // given; since the rendered diff is being cleared for this typed error, its anchor
          // input must clear too, or a batch sent while the error is showing would carry line
          // numbers from a diff the UI no longer displays. (The untyped/transport branch below
          // deliberately does NOT do this — it keeps the old diff rendered while it silently
          // retries, so the old anchors are still correct.)
          comments.setFiles([]);
          scheduleDiffRetry(preserveScroll, token, trigger);
          return;
        }
        // Reset here (not just on a normal success) so a later transient failure — once this
        // scope's state changes and a fresh refreshDiff runs — starts its own backoff at the
        // floor instead of inheriting whatever count this permanently-failing run left behind.
        diffRetryFailures = 0;
        files = [];
        renderFileList(changesListEl, files, undefined, { onSelect: changesOnSelect });
        diffView.setError(err.message);
        // Same re-anchor reasoning as the retryable branch above: this is a durable rejection
        // (e.g. a bad ref), so the diff stays cleared indefinitely and comments' anchor state
        // must match what's on screen (nothing).
        comments.setFiles([]);
        return;
      }
      scheduleDiffRetry(preserveScroll, token, trigger);
      return;
    }
    if (token !== diffRequestToken) return; // superseded: a newer refresh already applied its result
    diffRetryFailures = 0;
    files = result.files;
    diffLoaded = true;
    renderFileList(changesListEl, files, undefined, { onSelect: changesOnSelect });
    diffView.setFiles(files, preserveScroll);
    comments.setFiles(files);
    afterBrowserPaint(() => {
      if (token !== diffRequestToken) return;
      // Editor mode keeps the diff model warm for its Changes sidebar, but `renderBody()` detaches
      // `diffAreaEl`. Reporting that background refresh as a render would make agent churn look as
      // though an invisible diff was painted and would invalidate visible-vs-hidden profiling.
      if (state.mode !== "diff") return;
      bridge.notifyRenderMetric({
        kind: "diff",
        trigger,
        elapsedMs: Math.round(Math.max(performance.now() - renderStartedAt, 0)),
        fetchElapsedMs,
        fileCount: files.length,
        contentBytes: aggregateContentUnits(files.map((file) => file.patch)),
      });
    });
  }

  /**
   * Public-facing gate every caller below keeps calling unchanged: at most one `doRefreshDiff`
   * pull is ever in flight, with at most one more coalesced trailing pull queued behind it. The
   * daemon serializes `workspaceFileRead`/`workspaceFileWrite`/`workspaceDiff` on one per-workspace
   * queue (round-16 Fix 1), so issuing a fresh request for every signature event during an active
   * agent's churn just piles up pulls nobody will see rendered — each one delays the next, and
   * delays any editor save queued behind them too.
   *
   * When a call arrives while a pull is already in flight, it does NOT issue a second request.
   * Instead it bumps `diffRequestToken` right away — the exact same supersede a direct
   * `doRefreshDiff` call would perform — so the in-flight pull's own `token !== diffRequestToken`
   * checks discard its result or failure when it eventually settles, and clears any pending retry
   * timer for it. The request itself collapses into a single trailing pull, queued to run the
   * instant the in-flight one finishes; `doRefreshDiff` re-reads `state.scope` at that later time,
   * so the trailing pull always targets whatever scope is current then, never whatever scope was
   * selected when it was queued. This does not cost any wall-clock time to a fresh diff: those
   * extra requests already had to wait on the same daemon serial queue today, so the trailing pull
   * still lands no later than the last of today's piled-up pulls would have — the daemon just stops
   * spending time computing diffs nobody will ever see. Any UI state a caller needs to show
   * immediately (e.g. `setScope`'s synchronous `files = []` / `diffView.setLoading()`) still runs
   * before this gate is even called, so a deferred pull never leaves the user looking at stale UI.
   */
  async function refreshDiff(preserveScroll: boolean, trigger: DiffRenderTrigger): Promise<void> {
    if (diffPullInFlight) {
      diffRequestToken += 1;
      clearTimeout(diffRetryTimer);
      trailingDiffRefreshQueued = true;
      trailingDiffTrigger = trigger;
      // A single non-preserving caller (a scope switch) must win over any number of
      // scroll-preserving signature events coalesced into the same trailing pull.
      trailingPreserveScroll = trailingPreserveScroll && preserveScroll;
      return;
    }
    diffPullInFlight = true;
    try {
      await doRefreshDiff(preserveScroll, trigger);
    } finally {
      diffPullInFlight = false;
      if (trailingDiffRefreshQueued) {
        trailingDiffRefreshQueued = false;
        const preserve = trailingPreserveScroll;
        const trailingTrigger = trailingDiffTrigger;
        trailingPreserveScroll = true;
        trailingDiffTrigger = "workspaceChange";
        void refreshDiff(preserve, trailingTrigger);
      }
    }
  }

  /** Schedules the next attempt for a failed refreshDiff pull: floor 1s, doubling, capped at 30s,
   *  reset to the floor by refreshDiff's own `diffRetryFailures = 0` on the next success. Guarded by
   *  `token` at fire time (not just at schedule time) so a scope switch that happens while this
   *  timer is pending makes it a no-op instead of retrying a pull for a scope nobody is viewing
   *  anymore — the scope switch's own `refreshDiff` call already starts a fresh attempt (and a
   *  fresh retry loop of its own, if that one also fails). */
  function scheduleDiffRetry(preserveScroll: boolean, token: number, trigger: DiffRenderTrigger): void {
    const delay = Math.min(DIFF_RETRY_FLOOR_MS * 2 ** diffRetryFailures, DIFF_RETRY_CAP_MS);
    diffRetryFailures += 1;
    clearTimeout(diffRetryTimer);
    diffRetryTimer = setTimeout(() => {
      if (token !== diffRequestToken) return; // superseded while this retry was pending
      void refreshDiff(preserveScroll, trigger);
    }, delay);
  }

  function resubscribeDiffSignature(): void {
    // Only one scope is observed at a time (see SpacesBridge.subscribeDiffSignature's
    // doc comment): replace the previous subscription rather than layering another.
    unsubscribeSignature?.();
    unsubscribeSignature = bridge.subscribeDiffSignature(state.scope, () => {
      void refreshDiff(true, "workspaceChange");
      // A push that changed the diff may equally have added or removed files elsewhere in the
      // workspace — the same underlying git/agent activity both the diff and the full listing
      // reflect. Invalidate the shared cache unconditionally so the Files tree and ⌘P overlay pick
      // up the change instead of only the Changes list doing so — but only ask the sidebar to
      // re-fetch RIGHT NOW when the PANE itself is in editor mode. The sidebar's own default mode
      // is "files" while the pane's default top-level mode is "diff", so an ungated call here would
      // fire a full `workspaceFileList` RPC (up to 50,000 paths, serialized on the daemon's
      // per-workspace git queue) on every diff-signature push even while the sidebar isn't in the
      // DOM. A pane that later returns to editor mode re-renders the sidebar's current tab against
      // the already-invalidated cache (see `dispatch`'s `setMode` branch, which calls
      // `editorSidebar.reattach()`), and the Files tab's own `renderList()` re-fetches on demand
      // whenever it's shown regardless.
      fileListCache.invalidate();
      // Unlike the sidebar refresh above, NOT gated on `state.mode`: the ⌘P overlay is reachable
      // from both Diff and Editor mode, and (unlike the sidebar) `refreshListing()` is a no-op
      // unless the overlay is actually open, so there's no equivalent DOM-visibility cost to gate
      // against.
      quickOpen.refreshListing();
      if (state.mode === "editor") editorSidebar.refreshFilesListing();
    });
  }

  function dispatch(action: CodePaneAction): void {
    state = codePaneReducer(state, action);
    toolbar.update(buildToolbarState());
    renderBody();

    if (action.type === "setLayout") {
      diffView.setLayout(state.layout);
    } else if (action.type === "setScope") {
      diffLoaded = false;
      // round-14 fix: a scope change is a new retry context — `diffRetryFailures`'s climb belongs to
      // the PREVIOUS scope's failure streak. Left unreset, a new scope whose first pull also fails
      // transiently would inherit that climbed count and its first retry could wait up to the 30s cap
      // instead of the 1s floor. Mirrors the Swift host's own reset of its reconnect-failure counters
      // on a scope/path change (CodePaneContentController.swift's diffSignatureReconnectFailures /
      // fileSignatureReconnectFailures), and EditorView.open()'s own reset of externalChangeRetryFailures
      // on a successful open.
      diffRetryFailures = 0;
      // round-13 Fix 2: clear synchronously, before refreshDiff's await can yield control, so the
      // diff area never shows files from a scope other than the toolbar's current pick — a stale
      // diff labeled as the new scope is worse than a loading gap while the fetch is in flight.
      files = [];
      renderFileList(changesListEl, files, undefined, { onSelect: changesOnSelect });
      diffView.setLoading();
      comments.setFiles([]);
      void refreshDiff(false, "scope");
      resubscribeDiffSignature();
    } else if (action.type === "setMode") {
      // Pushed so a hibernated pane comes back in whichever mode the user last left it in,
      // rather than resetting to the mode it first loaded with — see CodePaneEditorState's
      // sibling `notifyModeChanged` doc comment in bridge/types.ts.
      bridge.notifyModeChanged(state.mode);
      if (state.mode === "diff" && !diffLoaded) {
        void refreshDiff(false, "initial");
      } else if (state.mode === "editor") {
        // Diff mode's own `renderBody()` reparents `changesListEl` OUT of the sidebar's list host
        // (`fileListEl.replaceChildren(changesListEl)`) for as long as the pane is in diff mode —
        // the sidebar itself never re-renders on that reparent (it isn't even attached to the DOM
        // meanwhile), so a pane that leaves the Changes tab showing, switches to diff, then back to
        // editor would show a blank Changes tab until the user manually toggled tabs. Re-running the
        // sidebar's current-mode render on every transition INTO editor mode fixes that, and also
        // picks up a fresh Files listing if the shared cache was invalidated while the sidebar was
        // off-screen (see `resubscribeDiffSignature`'s gating above). This dispatch is reached both
        // by a toolbar click and by the host's `spaces:setMode` push, so it covers every diff→editor
        // transition, not just a live user click.
        editorSidebar.reattach();
      }
    }
  }

  renderBody();
  // Rehydrate the editor from the host's post-hibernation snapshot BEFORE any of the awaits below
  // that can yield to a teardown. `window.__spacesCollectEditorState` (wired to
  // `editorView.collectStateForFlush` above) can be called by the Swift host at any moment this
  // pane is torn down — including mid-init, if the user switches away again immediately — and its
  // result is written back under the new page-generation number, which the host's `>=`
  // generation-ordering rule accepts unconditionally. Until this line runs, `EditorView` is still
  // empty, so that flush would return `undefined` and silently overwrite whatever dirty hibernated
  // snapshot the host was holding: a permanent loss of an unsaved edit. `restoreState`'s
  // dirty-restoration branch is pure synchronous computation over the snapshot (no network round
  // trip); only the clean-restoration branch does one `workspaceFileRead` call, an accepted extra
  // cost of moving this earlier. `initPayload.initialMode` already carries the host's live (not
  // original) mode — see the Swift host's `currentMode` — so a pane that hibernated in Editor mode
  // has already loaded back into Editor mode above; this call is what puts its buffer back too,
  // regardless of which mode ends up on screen.
  await editorView.restoreState(initPayload.editorState);
  // Every OTHER path into editor mode reaches `editorSidebar.reattach()` through dispatch's
  // "setMode" branch, which is what makes the Files tab's first listing fetch happen lazily on
  // "show" rather than in EditorSidebar's own constructor (see its doc comment: a diff-only pane
  // must not pay for a hidden `workspaceFileList` on the daemon's shared per-workspace git queue).
  // A pane that starts, or is rehydrated, directly into editor mode never goes through that
  // dispatch — `renderBody()` above already mounted the sidebar straight from `state.mode`, not via
  // a `setMode` action — so this is the one call site that has to trigger that first fetch itself.
  // This runs AFTER `restoreState` above so the restored buffer's `workspaceFileRead` enters the
  // daemon's serial per-workspace git queue ahead of the sidebar's potentially 50,000-path listing
  // scan, keeping external-change reconciliation of the open file from stalling behind it — the
  // same serial-queue ordering rule `openInEditor` applies (read before the mode dispatch that
  // triggers the listing).
  if (state.mode === "editor") editorSidebar.reattach();
  if (state.mode === "diff") {
    await refreshDiff(false, "initial");
  } else if (editorUIState.sidebarMode === "changes") {
    // Mirrors `EditorSidebar`'s own `onModeChange` handling: a pane that hibernated straight into
    // Editor mode with the Changes tab active needs the same catch-up fetch a live toggle-to-Changes
    // gets, or that tab would sit on the still-empty list `changesListEl` started with. Not awaited,
    // for the same reason `onModeChange`'s isn't: this only feeds a sidebar list, not the visible
    // main content this startup sequence is otherwise ordering around.
    void refreshDiff(false, "initial");
  }
  resubscribeDiffSignature();
  // Workspace-scoped, independent of `state.scope`: fetched once here regardless of which scope
  // or mode the pane happens to open in, not re-fetched on every scope switch (see
  // `CommentsController.loadInitial`'s doc comment).
  await comments.loadInitial();
}
