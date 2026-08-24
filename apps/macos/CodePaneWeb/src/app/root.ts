import { createBridge } from "../bridge";
import {
  CodePaneAgentsChangedEvent,
  CodePaneInitPayload,
  CodePaneThemeChangedEvent,
  DiffFileEntry,
  SpacesBridgeError,
  WorkspaceDiffResult,
} from "../bridge/types";
import { CommentsController, CommentsToolbarState } from "./commentsController";
import { DiffView } from "./diffView";
import { EditorView } from "./editorView";
import { renderFileList } from "./fileList";
import { selectDefaultAgentId } from "./reviewComments";
import { CodePaneAction, CodePaneState, codePaneReducer, initialState } from "./state";
import { renderToolbar } from "./toolbar";

const INIT_EVENT = "spaces:init";
const THEME_EVENT = "spaces:theme";
const AGENTS_EVENT = "spaces:agents";

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
  const editorView = new EditorView(editorContainerEl, bridge);
  // Wired here (not inside EditorView itself) so the global always reaches this exact instance's
  // live state — see Window.__spacesCollectEditorState's doc comment in bridge/types.ts and
  // EditorView.collectStateForFlush.
  window.__spacesCollectEditorState = () => editorView.collectStateForFlush();
  // round-16 Fix 1a: mirrors the wiring above, for the comment surface — see
  // Window.__spacesCollectReviewCommentState's doc comment in bridge/types.ts and
  // CommentsController.collectStateForFlush.
  window.__spacesCollectReviewCommentState = () => comments.collectStateForFlush();

  // A running agent set changes independently of any diff refresh or user action in this pane
  // (an agent can start or exit from elsewhere in the app), so this listens for the whole
  // lifetime of the pane rather than being read once at startup like `initPayload.agents`.
  window.addEventListener(AGENTS_EVENT, (event) => {
    comments.onAgentsChanged((event as CustomEvent<CodePaneAgentsChangedEvent>).detail.agents);
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
    onScopeChange: (scope) => {
      // Belt-and-suspenders alongside the toolbar's own disabled control (see segButton's doc
      // comment): a "vs base branch" scope is unreachable for a workspace with none, so refuse it
      // here too rather than trusting every future caller of onScopeChange to check first.
      if (scope.kind === "baseBranch" && initPayload.baseBranch === undefined) return;
      dispatch({ type: "setScope", scope });
    },
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

  function renderBody(): void {
    body.replaceChildren();
    if (state.mode === "diff") {
      body.appendChild(fileListEl);
      body.appendChild(diffAreaEl);
    } else {
      body.appendChild(editorContainerEl);
    }
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
  async function doRefreshDiff(preserveScroll: boolean): Promise<void> {
    const token = ++diffRequestToken;
    clearTimeout(diffRetryTimer);
    let result: WorkspaceDiffResult;
    try {
      result = await bridge.workspaceDiff(state.scope);
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
          renderFileList(fileListEl, files, undefined, {
            onSelect: (path) => diffView.scrollToFile(path),
          });
          diffView.setError(err.message);
          scheduleDiffRetry(preserveScroll, token);
          return;
        }
        // Reset here (not just on a normal success) so a later transient failure — once this
        // scope's state changes and a fresh refreshDiff runs — starts its own backoff at the
        // floor instead of inheriting whatever count this permanently-failing run left behind.
        diffRetryFailures = 0;
        files = [];
        renderFileList(fileListEl, files, undefined, {
          onSelect: (path) => diffView.scrollToFile(path),
        });
        diffView.setError(err.message);
        return;
      }
      scheduleDiffRetry(preserveScroll, token);
      return;
    }
    if (token !== diffRequestToken) return; // superseded: a newer refresh already applied its result
    diffRetryFailures = 0;
    files = result.files;
    diffLoaded = true;
    renderFileList(fileListEl, files, undefined, {
      onSelect: (path) => diffView.scrollToFile(path),
    });
    diffView.setFiles(files, preserveScroll);
    comments.setFiles(files);
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
  async function refreshDiff(preserveScroll: boolean): Promise<void> {
    if (diffPullInFlight) {
      diffRequestToken += 1;
      clearTimeout(diffRetryTimer);
      trailingDiffRefreshQueued = true;
      // A single non-preserving caller (a scope switch) must win over any number of
      // scroll-preserving signature events coalesced into the same trailing pull.
      trailingPreserveScroll = trailingPreserveScroll && preserveScroll;
      return;
    }
    diffPullInFlight = true;
    try {
      await doRefreshDiff(preserveScroll);
    } finally {
      diffPullInFlight = false;
      if (trailingDiffRefreshQueued) {
        trailingDiffRefreshQueued = false;
        const preserve = trailingPreserveScroll;
        trailingPreserveScroll = true;
        void refreshDiff(preserve);
      }
    }
  }

  /** Schedules the next attempt for a failed refreshDiff pull: floor 1s, doubling, capped at 30s,
   *  reset to the floor by refreshDiff's own `diffRetryFailures = 0` on the next success. Guarded by
   *  `token` at fire time (not just at schedule time) so a scope switch that happens while this
   *  timer is pending makes it a no-op instead of retrying a pull for a scope nobody is viewing
   *  anymore — the scope switch's own `refreshDiff` call already starts a fresh attempt (and a
   *  fresh retry loop of its own, if that one also fails). */
  function scheduleDiffRetry(preserveScroll: boolean, token: number): void {
    const delay = Math.min(DIFF_RETRY_FLOOR_MS * 2 ** diffRetryFailures, DIFF_RETRY_CAP_MS);
    diffRetryFailures += 1;
    clearTimeout(diffRetryTimer);
    diffRetryTimer = setTimeout(() => {
      if (token !== diffRequestToken) return; // superseded while this retry was pending
      void refreshDiff(preserveScroll);
    }, delay);
  }

  function resubscribeDiffSignature(): void {
    // Only one scope is observed at a time (see SpacesBridge.subscribeDiffSignature's
    // doc comment): replace the previous subscription rather than layering another.
    unsubscribeSignature?.();
    unsubscribeSignature = bridge.subscribeDiffSignature(state.scope, () => {
      void refreshDiff(true);
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
      renderFileList(fileListEl, files, undefined, {
        onSelect: (path) => diffView.scrollToFile(path),
      });
      diffView.setLoading();
      comments.setFiles([]);
      void refreshDiff(false);
      resubscribeDiffSignature();
    } else if (action.type === "setMode") {
      // Pushed so a hibernated pane comes back in whichever mode the user last left it in,
      // rather than resetting to the mode it first loaded with — see CodePaneEditorState's
      // sibling `notifyModeChanged` doc comment in bridge/types.ts.
      bridge.notifyModeChanged(state.mode);
      if (state.mode === "diff" && !diffLoaded) {
        void refreshDiff(false);
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
  if (state.mode === "diff") {
    await refreshDiff(false);
  }
  resubscribeDiffSignature();
  // Workspace-scoped, independent of `state.scope`: fetched once here regardless of which scope
  // or mode the pane happens to open in, not re-fetched on every scope switch (see
  // `CommentsController.loadInitial`'s doc comment).
  await comments.loadInitial();
}
